# ADR-0068 companion: compiler parallelism

Status: proposed

Date: 2026-07-16

Related: ADR-0040, ADR-0059, ADR-0063, ADR-0068, ADR-0071, #488, #806,
#906

## Position

The compiler is the reference CPU-bound workload for ADR-0068. It
must use the same shared-nothing `Nursery` / `Task` / channel semantics exposed
to Vibe programs; compiler-only shared mutable memory is not a second
concurrency model.

The first target is parallel module parsing and checking over the import DAG.
Parallel function-body codegen is a later phase. Whole-program planning,
canonical result commit, linking, and cache publication remain coordinator
operations until their contracts are explicitly split.

This document is the implementation design for compiler parallelism.
[concurrency.md](concurrency.md) remains the public language semantics source
of truth.

## Current pipeline and barriers

The profiled file compile path already separates load, typecheck, bundle
fingerprint, parse/merge, and final compile timings in
`lib/@vibe/compiler/entry/compiler/file_compile/file_compile.vibe`.

| Current phase | First parallel unit | Current barrier |
| --- | --- | --- |
| source/header load | file header | filesystem snapshot must be fixed before workers start |
| lex / parse | source file | current loops append to shared arrays in source order |
| dependency fingerprint / typecheck | ready import-DAG module | `TypeDb`, `RippleDb`, env/cache arrays, parse counters, and cycle stack are threaded sequentially |
| export rename / merged source | none initially | rename plan spans every source group because collisions cross group boundaries |
| whole-program codegen planning | none initially | function/type/constructor/string/effect/import indices are global |
| function-body codegen | top-level function | only after global indices and per-function id ranges are frozen |
| Wasm link / artifact publish | coordinator | section order, diagnostics, and cache writes must be canonical |

The current `TypeDb` recursion is an implementation observation, not the
parallel contract. Parallelization must not put a lock around the existing
mutable arrays and call that the public model.

## State and worker contract

The coordinator owns all changing build state:

```text
CompilerDriverState
  source snapshot
  import DAG and rank/topological order
  ready / running module ids
  canonical ModuleOutcome store
  TypeDb / RippleDb commit state
  cache publication queue
```

A worker receives an immutable job and returns one terminal value:

```text
ModuleJob
  module id and path
  source fingerprint and immutable source snapshot
  ordered direct-dependency interfaces/results

ModuleOutcome
  Checked(ModuleArtifact)
  Diagnosed(FrozenArray[Diagnostic])

ModuleArtifact
  module id and fingerprint
  public type/effect interface
  typed or normalized IR needed by later stages
```

`check_module : ModuleJob -> ModuleOutcome` is pure after the source snapshot
has been constructed. It cannot read the whole result store, update `TypeDb`,
write the cache, or observe which unrelated job completed first. This is the
key contract needed for schedule independence.

`FrozenArray[T]` (or an equivalent immutable bulk container) is required before
the compiler multi-worker gate. Serializing every AST/interface through
`String` would satisfy the baseline deep-copy semantics but would turn the
compiler dogfood into a serialization benchmark. Mutable `Array`, `Bytes`,
handler evidence, and continuation values remain non-`Send`.

Conceptually, the operation-level effect boundary is:

```vibe skip
effectset CompileDriver[r] = {
  Fs::read_file,
  Fs::write_bytes,
  Fs::rename,
  Profiler::now_us,
  Spawn[r]::spawn,
  Spawn[r]::cancel,
  Async::suspend,
}

// No `with` clause: source and dependency snapshots are already values.
fn check_module(job: ModuleJob) -> ModuleOutcome { ... }
```

This is a motivating use of ADR-0071: the driver needs selected filesystem and
scheduler operations, while workers need neither ambient `Fs` nor all of a
coarse `Async` effect.

## Scheduling and commit

1. The driver reads source/module headers and freezes a source snapshot.
2. It rejects import cycles and assigns a rank/topological order.
3. Every unpublished module whose direct dependencies have terminal outcomes
   becomes ready.
4. Ready jobs are spawned in a bounded nursery. Completion order is not
   observable compiler output.
5. Outcomes are placed in a coordinator-owned store by module id. Any derived
   arrays, diagnostics, and persistent artifacts are committed in canonical
   module-path/topological order.
6. Modules with failed dependencies receive a deterministic dependency
   diagnostic outcome rather than reading partially built environments.
7. When all reachable modules have terminal outcomes, the driver either emits
   canonical diagnostics or proceeds to whole-program planning.

Expected parse/type/check errors are values inside `ModuleOutcome`; they must
not escape the worker as `TaskError`. This lets independent failing branches
finish and makes the diagnostic set independent of the nursery's
nondeterministic first-observed failure. An unexpected runtime failure, trap,
or violated compiler invariant is still a task failure: it cancels siblings
and fails the entire compilation.

Diagnostics are ordered by normalized module path, source start/end, diagnostic
code, then message. They are never ordered by task id or completion time.

## Codegen split

Function codegen is enabled only after a serial `WholeProgramPlan` freezes:

```text
WholeProgramPlan
  canonical function and import indices
  type / constructor / struct tables
  string and effect tables
  per-function lambda/coverage/debug id ranges
  immutable call and capture lookup tables
```

Each function worker receives this plan plus one normalized body and produces
a local body buffer and metadata restricted to its preassigned ranges. It may
not append to a shared `LambdaTable`, allocate global ids, mutate the merged
AST, or publish Wasm sections. The linker concatenates bodies and metadata in
the plan's canonical function order.

Whole-program trait-dictionary rewriting, export renaming, DCE roots, global
index assignment, and section emission remain serial barriers initially.
They can be parallelized later only by refining the immutable plan, without
changing observable output.

## Cache publication

Cache keys and fingerprints remain content-derived and schedule-independent.
Workers may compute bytes but do not publish them directly.

The current cache writes bytes directly to the final path. Before multi-worker
or concurrent-process publication is enabled, stores must use:

1. a unique temporary file in the destination directory;
2. a complete write and validation;
3. atomic rename to the final content-addressed key;
4. cleanup of the losing temporary file when another publisher won the same
   key race.

A per-key single-flight table is a performance optimization, not a correctness
requirement. Two jobs may compute the same key, but readers must observe either
the previous complete value or the new complete value, never partial bytes.
Automatic mid-build GC remains forbidden by ADR-0059.

## Determinism contract

For a fixed source snapshot, compiler version, target, flags, and entry point:

```text
module_outcomes(jobs = 1) = module_outcomes(jobs = N)
diagnostics(jobs = 1)     = diagnostics(jobs = N)
wasm_bytes(jobs = 1)      = wasm_bytes(jobs = N)
cache_values(jobs = 1)    = cache_values(jobs = N)
```

Byte identity is required, not merely behavioral Wasm equivalence. Debug/name
sections, generated ids, and diagnostics therefore use planned canonical
indices rather than scheduler order.

`--jobs 1` is the reference implementation and debugging oracle. `--jobs N`
is a compiler CLI control, not a language-level CPU-count or thread API. The
default worker count is host policy and does not affect output.

## Lean model

The executable design claims are represented under `formal/`:

| Design concept | Lean object |
| --- | --- |
| acyclic import graph | `Compiler.Project.dependencies/rank/dependencyRankLt` |
| coordinator result map | `Compiler.BuildState.results` |
| ready rule | `Compiler.Ready` |
| worker isolation | `dependencySnapshot` and `CompileJob` |
| canonical sequential oracle | `expected : ModuleId -> JobResult` |
| worker obligation | `JobCorrect` |
| nondeterministic completion | `Step` / `Runs` |
| schedule-independent final state | `complete_schedules_are_deterministic` |
| byte/output determinism | `emitted_output_is_deterministic` |

Physical worker ownership is modeled separately by `Parallel.Machine` and
`Parallel.Step`. Its traces refine the generic async oracle and preserve the
one-running-task/one-worker invariant. The compiler scheduler still treats one
job completion as an atomic step; mapping `ModuleId` jobs to task ids and proving
that a parallel task completion publishes exactly the corresponding
`ModuleOutcome` is a future composition/refinement proof.

The proof is conditional: workers must satisfy `JobCorrect`, and both schedules
must reach `Complete`. It proves neither fairness nor that the current
compiler implements the worker contract. Those are locked by runtime tests and
differential compilation, not asserted by the Lean model.

## Runtime backend decision

The production native/WASI target is a Wasmtime embedding host with a bounded
OS-thread pool. The host shares one `Engine` and compiled compiler `Module`, but
every worker owns a distinct `Store`, `Instance`, linear heap, and host context.
Jobs and outcomes cross host channels as immutable values; no `SharedMemory` is
required. This matches the language-level shared-nothing contract more directly
than guest-side WASI Threads, whose instances share linear memory.

The current Node.js worker/daemon implementation below is the accepted interim
transport. It must retain the same `ModuleJob -> ModuleOutcome`, readiness,
failure, trace, and canonical-commit contracts so that replacing it does not
change the Lean model or observable compiler result. Wasmtime thread ids,
stores, instances, and feature flags remain backend details rather than Vibe
language values.

## Host multi-worker prototype

The first executable bridge lives in:

- `scripts/parallel_scheduler_prototype.mjs`: coordinator-owned scheduling,
  outcome publication, and canonical commit;
- `scripts/parallel_scheduler_worker.mjs`: persistent `node:worker_threads`
  workers receiving only a structured-cloned `ModuleJob` snapshot;
- `scripts/parallel_selfhost_checker.mjs`: worker-private stage2 daemon
  transport and check-result validation;
- `scripts/parallel_scheduler_trace.mjs`: a pure trace validator;
- `scripts/parallel_scheduler_prototype.test.mjs`: `jobs=1/2/4`, dependency,
  diagnostic, double-claim, and worker-failure regressions;
- `scripts/parallel_scheduler_selfhost.test.mjs`: differential checks against
  the current selfhost compiler.

The fast synthetic contract runs with
`pkf run test-parallel-scheduler-prototype`. The real compiler bridge runs with
`pkf run test-parallel-selfhost-scheduler`; it reuses a current-commit stage2
artifact when available and otherwise builds one. Set
`VIBE_PARALLEL_COMPILER_WASM` to select an explicit artifact.

The prototype trace deliberately names the bridge points:

| Prototype event | Model / contract point |
| --- | --- |
| `ready` | `Compiler.Ready`; every direct dependency is terminal |
| `claim` | `Parallel.Event.claim`, projecting to `Async.Event.dispatch` |
| `releaseComplete` | `Parallel.Event.releaseComplete`, projecting to task completion |
| `publish` | coordinator-owned `Compiler.BuildState.finish` |
| `commit` | canonical module-id order, independent of completion order |

It uses real host threads but no `SharedArrayBuffer`: source text and dependency
outcomes cross the worker boundary by structured clone, and workers cannot see
the coordinator result map. There are two worker implementations behind the
same scheduler:

- `synthetic` hashes the immutable job and injects small test diagnostics;
- `selfhost-check` keeps one isolated stage2 compiler daemon per worker and
  invokes the production `VIBE_CHECK_ONLY` parse/typecheck path.

The selfhost transport materializes the received source value only inside a
worker-private temporary directory. This is an adapter detail, not permission
for the job to inspect the project tree. A successful check must return both
exit status zero and the canonical `ok` marker. A nonzero result is converted
to `Diagnosed` only when the compiler produced its `.diag` value; a missing or
malformed response is an infrastructure failure. All compiler daemons and
temporary directories are coordinator-cleaned when the run completes or
fails.

The real bridge originally checked source-only leaf snapshots: a dependency's
public interface was not installed into the worker's checker environment, so a
module source containing imports was outside the prototype contract.

That API now exists. `VIBE_MODULE_JOB_DIR=1` makes the compiler read a job
directory — which is also its whole preopen sandbox — and answer with a value:

```text
<dir>/job.txt      version / path / fingerprint / dep rows
<dir>/source.vibe  the module source, verbatim
<dir>/dep<i>.env   dependency i's serialized public environment
<dir>/outcome.txt  "ok" or "diag", written LAST as the commit marker
<dir>/env.out      on ok: the checked environment
<dir>/diag.txt     on diag: one diagnostic per line
```

A worker cannot look its own dependencies up — the type-env cache key derives
from the whole transitive source snapshot, which is exactly what it may not
see — so the driver serializes each dependency environment with
`persistent_type_env_cache_text` and the worker decodes it with
`parse_persistent_type_env`. The `path` row is the module's LOGICAL path; it
is never opened, but it is the base directory every import resolves against.

`scripts/module_job_dir_test.sh` (compiler gate 58) pins the contract. Its
assertion is not "a module with an import checks clean" — an unresolved import
is lenient, so that passes even when the environment is discarded, and the
first version of the test did exactly that. The assertion is that calling an
imported function with the WRONG argument type is diagnosed, and that the same
call is lenient once the environment is withheld.

Still missing before the prototype can drive a real import DAG: the
coordinator must order jobs by the dependency graph and thread each
`env.out` into its dependents' job directories.

Expected diagnostics are returned as values. An unexpected worker exception,
compiler trap, daemon exit, or protocol violation fails the whole prototype run
and terminates the pool; it is not converted into a recoverable compiler
diagnostic.

This is a bridge experiment, not the Vibe `Task` runtime and not evidence that
the selfhost compiler already refines the Lean model. It does not implement
`Nursery[r]`, cancellation/finalizers, channels, task-local heaps, `Send`, or
#817 evidence passing. The current stage2 is executed by a child daemon owned by
each host worker because the existing JavaScript host runner is process-shaped;
the synthetic path itself executes directly on `worker_threads`. This validates
the value/protocol seam and real parse/typecheck determinism, not yet a
same-process compiler thread implementation or OS security sandbox. The next
implementation step is the in-memory checker boundary above, followed by
passing immutable dependency interfaces instead of only terminal outcomes.

## TDD implementation sequence

### Phase 0: oracle and measurement — done

- Record cold/warm `load/type/bundle/parse/compile/total` timings and peak heap.
- Add a sequential randomized-ready-order executor with no real parallelism.
- Red: different ready orders, worker counts, or repeated runs must produce
  byte-identical Wasm and identical canonical diagnostics/cache values.

`VIBE_DEP_ORDER_SEED` permutes every node's dependency visit order in
`runtime/typecheck_fs.vibe` (0 = identity = the production walk), and
`scripts/dep_order_oracle.sh` asserts byte-identical wasm across seeds with a
cold cache per run. The recorded dep order stays declaration order —
`build_fingerprint` folds it in sequence, so permuting the record would change
every fingerprint and defeat the invariance being measured.

The oracle refuses to run against a compiler binary that contains no
`VIBE_DEP_ORDER_SEED` literal. Without that guard it passes vacuously, which
is not a hypothetical: a failed bundle regen once left the previous adapter in
place and five seeds "passed" against a compiler that could not read them.

### Phase 1: module job extraction — partial

- Extract pure header parse and `check_module` functions.
- Replace recursive accumulator threading with `ModuleOutcome` plus a single
  coordinator commit path.
- Differentially compare the new `--jobs 1` path with the old compiler.

`ModuleJob` / `ModuleOutcome` / `check_module` / `commit_module_outcome` exist
in `runtime/typecheck_fs.vibe`, and `scripts/compiler_differential.sh` holds
the byte-identity comparison against the previous compiler.

Three gaps remain before Phase 2 can rely on this seam:

- `check_module` still carries an `Error` row. Type errors are values inside
  `Diagnosed`, but parse errors are not — making them values would relabel
  every parse diagnostic, so it waits for the canonical diagnostic ordering.
- The driver still fails fast on the first `Diagnosed` rather than collecting
  a canonical set, so today's behaviour is preserved exactly.
- `ModuleJob.dep_envs` is the driver's whole resolved environment table, not
  the ordered direct-dependency interfaces the contract above calls for.
  `build_import_env` resolves import paths against it, so narrowing changes
  which entry an import binds to. A worker handed the superset still cannot
  observe the driver, but narrowing is a real prerequisite for isolation.

The accumulator threading in `ensure_fingerprint_fs_go` is unchanged — only
the per-module leaf work was lifted out. `FrozenArray[T]` is not implemented.

### Phase 2: bounded parallel frontend — transport only

- Run ready module jobs through the ADR-0068 nursery/channel implementation.
- Start with a conservative worker bound because a full compiler self-compile has a
  high heap watermark; measure throughput and peak RSS together.
- Keep filesystem and persistent-cache writes in the driver.

The worker-side half is done: `VIBE_MODULE_JOB_DIR=1` checks a module with
imports inside a job-directory sandbox and returns diagnostics as values
(see "Host multi-worker prototype" above).

Nothing runs in parallel yet. There is no `--jobs` flag, the production
compile path still walks the import DAG serially, and the coordinator does
not yet thread `env.out` between job directories. Wall-clock parallelism is
Phase 2's remaining work, not something this transport already delivers.

### Phase 3: immutable whole-program plan

- Split global discovery/index allocation from body emission.
- Preassign every function/lambda/coverage/debug range.
- Red: shuffled body completion order must not change any Wasm byte.

### Phase 4: backend differential

- Run the same suite on cooperative, Worker/host-task, and WASI backends.
- #488 shared-everything remains an opt-in backend and must pass the same
  result/trace oracle before use.

## Completion gates

- no module starts before every direct dependency has a terminal outcome;
- no worker can observe unrelated job completion or mutate driver state;
- expected diagnostics are values and remain stable across schedules;
- unexpected task failure cancels the nursery and leaves no published partial
  cache artifact;
- `--jobs 1/2/4` produce byte-identical Wasm on the compiler corpus;
- cold and warm compile time, peak guest heap, and host RSS are reported before
  raising the default worker count;
- `cd formal && lake build --wfail` remains green without `sorry`.
