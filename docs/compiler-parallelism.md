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

**Status (#906):** `FrozenArray[T]` is implemented as a checker-only
phantom-type distinction over `Array[T]`'s exact same runtime layout — the
same technique `ArrayBuilder[T]` already uses (`ArrayBuilder::freeze` is a
pure identity cast; so are `FrozenArray::from_array`/`FrozenArray::to_array`).
Surface: `FrozenArray::from_array`, `FrozenArray::get`, `FrozenArray::length`,
`FrozenArray::to_array` — no mutation methods, deliberately. `Send`'s
structural judgment (`send_ok_rec`, checker/checker_trait.vibe) treats
`FrozenArray[T]` as `Send` exactly when `T` is, so a `FrozenArray[Diagnostic]`
(assuming `Diagnostic` is itself `Send`) can now cross a `TaskGroup::spawn`
boundary where the equivalent `Array[Diagnostic]` is rejected. Fixtures:
`fixtures/region_ok_frozen_array_basic.vibe`,
`fixtures/send_bound_frozen_array.vibe`,
`fixtures/err_type_send_frozen_array_of_array_bound.vibe`,
`fixtures/region_ok_frozen_array_taskgroup_capture.vibe` (compiler_gate.sh
gate 63). Not yet done: nothing in the module-job pipeline below actually
produces or threads a `FrozenArray[Diagnostic]` value yet — `Diagnosed`'s
payload above is still illustrative until a later phase wires it through.

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

**Status (#1259):** collection and the path-level ordering exist on the real fs
walk, behind `VIBE_DIAGNOSTICS_ALL=1`
(`set_collect_module_diagnostics`, `runtime/typecheck_fs.vibe`). The wave loop
diagnoses a module, marks it failed, and keeps stepping its wave siblings —
they are independent by construction, so one failure removes none of their
inputs — then skips only the modules that actually depend on a failure, so a
blocked importer contributes no cascade. The collected set is sorted by module
path and asserted byte-identical across `VIBE_DEP_ORDER_SEED` values, which is
the within-wave permutation a parallel coordinator varies between runs
(`compiler_gate.sh` section 74).

Two parts of the ordering above are not reachable yet: `check_module` emits at
most one diagnostic per module, so source start/end never breaks a tie, and
there are no diagnostic codes. The comparator is total anyway, so a
multi-diagnostic worker sorts deterministically the day it lands.

The default stays fail-fast. Collection changes two observable things at once —
the error text grows from one diagnostic to N, and modules a fail-fast walk
never reached get checked and committed to the persistent cache — so flipping
the default is a separate decision from having the mechanism.

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

> **Measured correction (2026-07-31, #1239 step 4(D)).** The motivation above
> for a *thread* pool — "the host shares one `Engine` and compiled `Module`" —
> is already paid for by AOT. `viberun --precompile` emits a `.cwasm`, and
> `runtime/vibe` already selects it with staleness guards. Per module job, in
> a **fresh process**:
>
> | compiler image | per-job cost |
> |---|---|
> | `.wasm` (Cranelift JIT every start) | ~485ms |
> | `.cwasm` (AOT image deserialize) | **~8ms** |
>
> 8ms amortizes away against real job work, so an ordinary **process** pool
> over the existing `.cwasm` already scales. Measured on 32 module jobs built
> from real compiler sources, 4 cores:
>
> | parallelism | elapsed | speedup |
> |---|---|---|
> | sequential | 290ms | — |
> | `-P 2` | 155ms | 1.87x |
> | `-P 4` | 86ms | **3.37x** |
> | `-P 8` | 85ms | 3.41x (saturated) |
>
> — with `outcome`, `fingerprint`, and `env` bytes **identical at every
> parallelism level**, which is this document's own acceptance criterion.
> Pinned by `scripts/bench_module_job_pool.sh`.
>
> Separate processes also satisfy the shared-nothing contract more strictly
> than threads do, and a warm per-thread instance would not help anyway: the
> compiler's bump allocator never frees, which is why even the bench path
> builds a fresh `Store`/`Instance` per unit of work.
>
> A Wasmtime multi-instance host may still be worth building for other
> reasons (in-process dispatch without job directories, finer cancellation),
> but it is **not** the prerequisite for wall-clock parallel typecheck that
> this section and #1239 previously described it as.

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

The coordinator now threads it. `SelfhostChecker.check` builds the job
directory, writes each dependency's environment as a positional `dep<i>.env`
in declaration order, and returns the module's own `env.out` in its artifact
so dependents receive it. Readiness already guaranteed a dependency was
terminal before a dependent was claimed; that terminal outcome now carries
the interface as well as the verdict.

`scripts/parallel_scheduler_selfhost.test.mjs` runs a two-module import DAG
through real `worker_threads` at `jobs=1/2/4` with identical output. It uses
the same discriminator as gate 58 — the wrong-argument-type case — because a
call to an imported name alone is lenient and would pass against a bridge
that discarded the environment.

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

`ModuleJob` no longer carries a `fingerprint` field. An earlier cut had the
caller supply one, and `check_module` simply echoed it back into `Checked`
without ever consulting it — a purely decorative field that made every
worker-computed cache key caller-chosen, so nothing a worker published could
land at the persistent-cache path (`persistent_type_env_cache_path`, keyed by
`build_fingerprint`) a serial compile would actually look under. Any future
coordinator step that tries to pre-warm that cache from parallel workers
would have silently done nothing. `ModuleJob.dep_fps` now carries each
dependency's own fingerprint (declaration order, matching `deps`/`dep_envs`),
and `check_module` computes the canonical fingerprint itself via
`build_fingerprint(job.source, job.dep_fps)` — an output of the job, never an
input trusted from the caller. `scripts/module_job_dir_test.sh` and
`parallel_scheduler_selfhost.test.mjs` both assert dependency-fingerprint
*sensitivity*: change only a dependency's fingerprint and the importer's own
computed fingerprint must change too, and it must match the
`build_fingerprint` shape (`<len>:<hash>:<hash>`) rather than the worker
transport's own synthetic hash.

Remaining gaps before Phase 2 can rely on this seam:

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
- No coordinator step publishes a worker's checked environment to the REAL
  persistent cache. `run_module_job_dir`'s writes are sandboxed to the job
  directory on purpose (a worker's whole filesystem IS the job dir), so even
  with the fingerprint now correct, nothing outside the job directory sees
  it. Publishing requires either a host-side "commit" step that writes
  `env.out` to `persistent_type_env_cache_path(fingerprint)` directly, or a
  vibe-side primitive that performs that write given a batch of
  (fingerprint, env-text) pairs — deliberately not decided here, since
  re-deriving the cache's path scheme on the host would be the same class of
  drift risk the fingerprint fix above just closed.

The accumulator threading in `ensure_fingerprint_fs_go` is unchanged — only
the per-module leaf work was lifted out. It is still a depth-first recursion
whose call stack, not an explicit ready/running/terminal set, is what
currently encodes "wait until dependencies are done". `FrozenArray[T]` is
now implemented (checker-only phantom type over `Array[T]`, see the Status
note above) but not yet threaded through this recursion.

Turning that recursion into a worklist a real dispatcher can drive does not
help by itself: vibe runs as one process per invocation, so bookkeeping
readiness explicitly inside that one process gains no wall-clock parallelism
on its own. The dispatcher that would actually gain something has to live in
a host driver, dispatching real OS-level work (the `worker_threads` +
per-worker `vibe --daemon` child process pattern already in
`parallel_scheduler_worker.mjs`/`parallel_selfhost_checker.mjs`) — which
means it needs a REAL project's import graph, not only the synthetic
in-memory module lists `parallel_scheduler_selfhost.test.mjs` builds by
hand.

`scripts/parallel_project_driver.mjs` is that discovery step.
`VIBE_MODULE_JOB_DIR` needs its dependencies' RESOLVED paths and each
dependency's checked interface; the compiler already resolves import paths
for the serial walk (`load_or_parse_module_header_fs`, the same primitive
`resolve_deps_for_source_fs` in `typecheck_fs.vibe` calls), so a new
`VIBE_LIST_DEPS=1` adapter mode exposes exactly that instead of
re-deriving import resolution on the host — the same drift risk the
fingerprint fix above closed for cache keys, applied to graph edges instead
of hashes: a second "how does an import resolve" implementation wouldn't
fail loudly, it would silently walk the wrong graph. The driver does a BFS
from one or more entry files, shelling `vibe` once per newly-discovered
file to list its deps, and dedupes by resolved path in one `seen` set
shared across the whole walk — real project graphs are routinely diamonds
(one leaf reached through two importers), not trees, and deduping by
"which importer mentioned it first" would double-schedule the shared leaf.

`scripts/fixtures/parallel_project_sample/` is a small on-disk fixture
project (`leaf.vibe` ← `mid.vibe` and `leaf.vibe` ← `main.vibe`, a genuine
diamond) that `scripts/parallel_project_driver.test.mjs` discovers and
checks end to end. Its `main_broken.vibe` variant is the first TWO-HOP
proof in this line of work: it calls `mid_value` with the wrong argument
type, and `mid_value`'s real signature only exists in the checker's
environment because `leaf.vibe`'s checked interface reached `mid.vibe`
first. Every earlier test proved one hop (a job directly importing a
checked dependency); this proves the chain holds when discovery, worker
dispatch, and environment threading all compose across more than one edge,
on files that live on disk rather than in a test's memory.

This is still discovery-and-check only, run by hand from a test. It is not
wired into `vibe build`, there is no `--jobs` flag, and no wall-clock
timing has been measured — the discovery walk itself pays one `vibe`
subprocess launch per file just to learn its dependencies, which nobody
has profiled against a project the size of the compiler's own ~260-module
manifest. Whether that overhead is negligible next to real typechecking
work, or needs to be parallelized itself before it's worth using, is
unmeasured.

### Phase 2: bounded parallel frontend — wired as a cache pre-warm

- Run ready module jobs through the ADR-0068 nursery/channel implementation.
- Start with a conservative worker bound because a full compiler self-compile has a
  high heap watermark; measure throughput and peak RSS together.
- Keep filesystem and persistent-cache writes in the driver.

The worker/coordinator bridge is done: `VIBE_MODULE_JOB_DIR=1` checks a
module with imports inside a job-directory sandbox and returns diagnostics as
values, and the host coordinator threads each dependency's interface into its
dependents' jobs, so a real import DAG runs across `worker_threads` at
`jobs=1/2/4` with identical output (see "Host multi-worker prototype" above).

**`vibe build|compile --jobs N` now reaches the real compile path**, but not
by replacing `ensure_fingerprint_fs_go`. That recursion still runs, serially,
on every compile — Phase 1's "remaining gaps" note above is still true: a
worklist inside one guest process gains nothing, since real parallelism only
comes from a host driving multiple wasm instances. Instead, `--jobs N`
(`runtime/vibe`'s `maybe_warm_frontend_cache`, N > 1) runs BEFORE the
existing serial `compile_to()`, as a pure cache pre-warm:

1. Discover the entry file's import DAG (`VIBE_LIST_DEPS`, batched through
   `scripts/parallel_frontend_warm.mjs`, a `projectRoot`-parameterized sibling
   of `scripts/parallel_project_driver.mjs`).
2. Check every module through the existing `worker_threads` +
   `VIBE_MODULE_JOB_DIR` coordinator/worker stack, unchanged.
3. Publish every `Checked` outcome's environment to the REAL persistent-cache
   path — not the job-dir sandbox — via a new adapter mode,
   `VIBE_PUBLISH_ENV_CACHE=1` (`run_publish_env_cache_dir`,
   `runtime/typecheck_fs.vibe`). This closes the exact gap Phase 1's
   "remaining gaps" section left open: a worker's checked environment now
   reaches `persistent_type_env_cache_path(fingerprint)`, the path the serial
   walk's `finish_typecheck_fs_impl` checks with a plain `Fs::exists` before
   ever calling `check_module` again. The publish step never re-derives that
   path itself — it reads it out of the compiler via one extra wasm
   invocation — because the path folds in this build's own
   `codegen_fingerprint`, which a host process has no reliable way to
   reproduce (the same drift risk the `ModuleJob.dep_fps` fingerprint fix
   above closed for cache keys, here applied to cache paths).
4. `compile_to()` then runs exactly as it always has, unconditionally.

The correctness argument this rests on: a `Diagnosed` module is simply
absent from the publish manifest, so the serial walk re-checks it from
scratch and reports the identical diagnostic (pinned by
`scripts/test_parallel_frontend_warm.sh`, which asserts byte-for-byte
diagnostic equality between a plain serial compile and a `--jobs`-prewarmed
one on the same failing input). Every prerequisite this needs — `node` on
`PATH`, the dev-repo driver scripts existing next to `TOOLCHAIN_DIR` — is
checked before anything runs; missing either just skips the pre-warm with a
stderr note and falls through to the unmodified serial path. This is why
`--jobs` needs no soundness argument of its own: it can only ever save the
serial walk redundant work or do nothing, never change what a build produces.
`scripts/test_parallel_frontend_warm.sh` (opt-in Taskfile task
`test-parallel-frontend-warm`, matching `test-parallel-selfhost-scheduler`'s
precedent — neither is wired into `test`/`full-gate` yet) asserts
byte-identical Wasm between `--jobs 1` and `--jobs 4` on the fixture diamond
project, in addition to the diagnostic-equality check above.

What that is still NOT: this only speeds up (or no-ops) the frontend
check — parse/typecheck — never codegen or linking. It is now wired into
`vibe build`/`compile` and `check` (each call site just parses its own
`--jobs N` and calls the same `maybe_warm_frontend_cache` before its
existing compile/check loop, unchanged) but not `diagnostics` (not wired
there yet, though the same helper would apply unchanged there too).

**`vibe test --jobs N` goes further than a pre-warm** (added alongside
#1173): unlike `build`/`compile`/`check`, `vibe test <files...>` runs
MULTIPLE independent compile-then-run cycles per invocation — one per test
file — and until now that per-file loop stayed fully serial regardless of
`--jobs` (only each file's own frontend cache got pre-warmed, the same as
the other verbs). `--jobs N > 1` now runs up to `N` files' compile+run
concurrently, in same-sized batches (`runtime/vibe`'s `test)` case), with
each batch's output buffered per-file and printed in original file order
so results stay byte-identical to the serial path regardless of which
file's `wasmtime` process finishes first. Per-file frontend pre-warm is
intentionally NOT nested under this outer pool (an inner N-way Node
worker pool per file, under N files already running as N host processes,
would oversubscribe the machine for no benefit — see the discovery-loop
KPI finding above). Running compiles/runs concurrently here is safe only
because #1173 made the persistent cache's write path atomic in both
runners, closing the exact partial-write race this exposes. Measured on
20 of the compiler's own `*_test.vibe` files, 4-core sandbox
(2026-07-28): `--jobs 1` (serial) 87.7s, `--jobs 2` 68.2s (-22%),
`--jobs 4` 51.4s (-41%) wall time, byte-identical output at every level.
It requires Node (the coordinator uses `worker_threads`) even when the
installed toolchain's own runner is the Rust `viberun`, so it is scoped to a
dev checkout of this repo — see the "Shared-everything migration note" below
and #1143 for the broader runtime-portability question this leaves open.
Discovery still pays one `vibe` subprocess launch per file (`VIBE_LIST_DEPS`),
but as of #1168 that discovery walk itself runs with up to `jobs` files in
flight at once (`mapWithConcurrency` in `scripts/parallel_frontend_warm.mjs`,
one BFS level/frontier at a time) rather than fully serially. Measured
against the compiler's own manifest (~209 modules, 4-core sandbox,
2026-07-28): parallelizing discovery alone cuts `--jobs 4` cold wall time
from 21601ms to 10977ms (-49%), and `--jobs 2` from 21072ms to 15627ms
(-26%); crucially, wall time now actually scales down as `jobs` increases
(10977ms at 4 workers vs 15627ms at 2), which the fully-serial discovery
loop never did (it cost the same regardless of `jobs`). It is still slower
than the plain serial baseline (~5.5s) at this project size — discovery-loop
parallelism narrows the gap, it does not close it — so this alone does not
change the "default worker count stays at 1" decision; see the KPI note
below for the fuller picture including the persistent-cache benefit. The
persistent-cache write itself is still a direct
`Fs::write_file`; `--jobs` does not add a temp-file+rename step, so two
concurrent `vibe build --jobs` invocations racing on the same fingerprint is
the same pre-existing hazard the Cache publication section above already
flags for the serial path, not a new one introduced here.

> **Update (2026-07-31, #1239 step 4(D)).** Discovery no longer spawns one
> `vibe` per file at all. `VIBE_MODULE_PLAN=1` (`module_plan_manifest_fs`,
> `compiler/runtime/typecheck_fs.vibe`) walks the whole import graph inside
> ONE compiler process and returns every reachable module — with its
> dependency list, its ingested source, and its rank — already in the
> canonical order `plan_module_order` assigns, which is the same ordering
> rule the serial walk's own upfront plan uses since step 4(A). Measured on
> this repo's `codegen_lexer_test.vibe` graph (166 modules, 4-core sandbox):
> the per-file `VIBE_LIST_DEPS` loop takes 17.4s serially and 5.1s at 4-way
> concurrency, against **0.8s** for the single plan call. End to end,
> `parallel_frontend_warm.mjs` at `--jobs 4` over the 201-module graph goes
> from **10.6s to 3.6s** wall (-66%) and 23.5s to 2.3s of host CPU, with
> identical results (201 modules, 201 checked, 0 diagnosed, 201 warmed).
>
> So the "discovery-loop tax" this section and the KPI note below both treat
> as a fixed cost is gone, and the numbers above that were dominated by it
> (the 21601ms/10977ms `--jobs 4` figures, the "slower than the plain serial
> baseline" conclusion) should be re-measured before being cited again. The
> `--jobs` default is still 1; that decision has not been revisited on the
> new numbers.
>
> `VIBE_LIST_DEPS` stays, as the per-file oracle the new mode is diffed
> against (`compiler_gate.sh` section 72): the two must describe the same
> graph, and a disagreement would not fail loudly — it would quietly warm a
> cache for the wrong one.
>
> **Both coordinators take this route.** `scripts/parallel_warm_pool.sh`, the
> bash process pool #1250 added for shipped toolchains, used to run the
> per-file `VIBE_LIST_DEPS` BFS and then `VIBE_PLAN_MODULE_ORDER` over the
> resulting edges; `VIBE_MODULE_PLAN` collapses both steps into the one call.
> Measured in the configuration that path actually uses — an AOT `.cwasm`
> loaded by `viberun`, the same 166-module graph:
>
> | discovery | wall |
> |---|---|
> | `VIBE_LIST_DEPS` ×166, `-P 1` | 2854ms |
> | `VIBE_LIST_DEPS` ×166, `-P 4` | 742ms |
> | `VIBE_MODULE_PLAN` ×1 | **222ms** |
>
> End to end the pool goes from **12.9s to 9.5s** (-26%) at `-P 4`, warming
> the same 166/166 modules across the same 48 ranks. Note the 742ms row is a
> LOWER bound on what the old script actually paid: its BFS is level-order,
> so on a 48-rank-deep graph it ran ~48 mostly-single-module frontiers rather
> than 166 jobs flat. The end-to-end delta (~3.4s) is the real saving.
>
> `VIBE_PLAN_MODULE_ORDER` now has no production consumer — only
> `test_parallel_warm_pool_gate.sh`, which still drives it directly for the
> diamond/cycle/empty-graph cases. Whether to keep it as a standalone
> ordering primitive or fold it into `VIBE_MODULE_PLAN` is left open.

**Measured against the compiler's own manifest (2026-07-28, #906): `--jobs`
is currently a net regression, not a speedup, at this scale.** Running
`scripts/jobs_kpi.sh` with `lib/@vibe/compiler/cli_support.vibe` (the real
`stage2`-self-compile entry, ~209 transitively-discovered modules) as input,
on a 4-core sandbox:

| jobs | mode | wall_ms | heap_ptr_bytes |
| --- | --- | --- | --- |
| 1 (serial, pre-warm skipped) | cold | 5167 | 1,096,576,476 |
| 1 (serial, pre-warm skipped) | warm | 2998 | 575,388,476 |
| 2 | cold | 21072 | 854,972,716 |
| 2 | warm | 18004 | 575,476,308 |
| 4 | cold | 21601 | 854,972,716 |
| 4 | warm | 18634 | 575,476,308 |

(Correction, Codex review on PR #1169: the first pass of this table was
measured before fixing a real bug in `scripts/jobs_kpi.sh` itself — the
pre-warm driver invocation didn't set `VIBE_BUILD_CACHE_DIR`, so
`publishCheckedOutcomes` wrote every checked module's environment to the
*ambient default* persistent-cache path instead of the isolated `$CACHE_DIR`
the measured compile actually reads from, silently discarding 100% of the
pre-warm's cache benefit rather than just the `diagnosed` share. Fixed by
passing the same `VIBE_BUILD_CACHE_DIR="$CACHE_DIR"` to both the driver and
the final compile step. The table above is the corrected, re-measured
result.)

`--jobs 2` and `--jobs 4` both still cost ~4x the plain serial baseline in
wall time, and going from 2 to 4 workers buys nothing (21601ms vs 21072ms
cold) — the extra time does not scale with worker count, which rules out
per-worker check cost as the driver and points at a fixed,
worker-count-independent cost instead. Root cause, confirmed by timing
`scripts/parallel_frontend_warm.mjs` in isolation: `discoverProject` walks
the import DAG with a **strictly serial** `while (queue.length > 0) { ...
await listDeps(...) }` BFS loop — one `vibe` subprocess spawn (bash + node +
wasmtime startup) per file, fully sequential, before any parallel checking
starts at all. At ~209 files and ~80ms/spawn this alone accounts for the
observed ~13-17s of overhead over the serial baseline, regardless of `jobs`
N — discovery is not parallelized today even though the checking phase that
follows it is.

With the cache-dir bug fixed, the pre-warm's benefit now *is* visible in
`heap_ptr_bytes`: the final compile's own bump-allocator high-water drops
~22% (1,096,576,476 → 854,972,716 bytes) at `jobs=2/4` versus `jobs=1`,
confirming published environments really do reach and get reused by the
measured compile now. It just isn't enough to close a ~13-17s
discovery-loop tax that dwarfs the heap/redundant-work savings at this
project size. (The same run's summary line —
`{"modules":209,"checked":34,"diagnosed":175,"warmed":34}` — still shows
175/209 modules, ~84%, come back `diagnosed` rather than `checked` when
checked standalone in a job-dir sandbox outside the full serial walk's
context, so there is further headroom beyond the 22% already realized once
that rate improves.) Both the serial discovery loop and the high
`diagnosed` rate are pre-existing gaps in the Phase 2 driver, not
regressions from this measurement; they were flagged as open ("unmeasured
against a project the size of the compiler's own manifest") since Phase 2
landed and are now measured.

**Update (2026-07-28, #1168): both (a) and (b) are now fixed.** (a)
`discoverProject`'s discovery loop is parallelized (#1170). (b) the
`diagnosed` cascade's root cause was a missing contract-desugar step:
`run_module_job_dir` handed a raw `.vpkg` contract file's on-disk bytes
straight to `check_module`, which parses source with the ordinary module
grammar — a `.vpkg` file (bodyless decls, top-level `export`) is never
valid input for that grammar, so every foundational package-index contract
failed to parse, and `parallel_scheduler_worker.mjs`'s dependency
short-circuit cascaded that failure to ~82% of the whole manifest. Fixed
by piggybacking the already-public `ingest_source_text_fs` (the exact
function `ensure_fingerprint_fs_go`'s serial recursion already runs before
ever calling `check_module`) onto the existing `VIBE_LIST_DEPS` subprocess
call — a new `.src` companion output alongside the plain deps list, so no
extra spawn is added per file. Re-measured against the same ~218-module
manifest: `checked=218 diagnosed=0` (was `checked=34 diagnosed=184`).

| jobs | mode | wall_ms | heap_ptr_bytes |
| --- | --- | --- | --- |
| 1 (serial) | cold | 5714 | 1,096,577,420 |
| 1 (serial) | warm | 3926 | 575,390,804 |
| 2 | cold | 17147 | 586,440,412 |
| 2 | warm | 15184 | 575,478,356 |
| 4 | cold | 13136 | 586,440,412 |
| 4 | warm | 12233 | 575,478,356 |

`heap_ptr_bytes` now drops ~47% at `jobs=2/4` (1,096,577,420 →
586,440,412), up from the ~22% the cache-dir fix alone gave — the near-full
`checked` rate means almost the whole manifest's cache is now genuinely
warmed and reused by the final compile, not just a third of it.

**Decision (per the Completion gates governance below): the default worker
count is still NOT raised.** Wall time at `jobs=2/4` is still ~2.3-3x the
serial baseline (13.1-17.1s vs 5.7s) — the per-file `vibe` subprocess-spawn
cost in the (now-parallel, but still real) discovery loop remains a fixed
tax that the cache/heap savings don't offset at this project size.
`--jobs N > 1` remains strictly opt-in; raising the default would need
either a cheaper discovery mechanism (batching multiple files into one
subprocess call, or a persistent discovery daemon) or a project large
enough that the now-substantial cache savings outweigh the spawn tax —
neither attempted here.

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
  raising the default worker count (`pkf run jobs-kpi` /
  `scripts/jobs_kpi.sh`, added #906 -- this reports the numbers, it does not
  itself decide the default worker count should change; that's still a
  separate, deliberate decision once the numbers exist). **Measured
  2026-07-28 against the compiler's own ~209-module manifest: `--jobs 2/4`
  cost ~4x the serial baseline, dominated by a serial per-file discovery
  loop — see the measured table in Phase 2 above. Decision: default worker
  count stays at 1 until discovery is parallelized/batched.**;
- `cd formal && lake build --wfail` remains green without `sorry`.

## Shared-everything migration note (2026-07-27)

The design above is shared-nothing throughout: every worker owns a distinct
`Store`/`Instance`/linear heap, and jobs/outcomes cross the host boundary as
copied values (job-directory text files today, an eventual channel/message
transport later). This section records what a later move to a
shared-everything design (#488) would actually require, so today's choice
isn't accidentally load-bearing in a way that closes that door. It is a
forward-looking note, not a plan — none of this is scheduled work.

**It isn't available to choose today.** `docs/wasm_threads_requirements.md`
§4's 47.0.2 probe found the `shared-everything-threads` proposal's CLI flag
accepted but not wired into Wasmtime's validator or WAT parser (`shared
composite types require the shared-everything-threads proposal`, upstream
tracking `bytecodealliance/wasmtime#9466`, still unimplemented). Only core
wasm atomics + shared memory (`-W threads=y -W shared-memory=y`) work today,
and WASI Threads (`-S threads=y`) was removed in Wasmtime 47.0.0. This note
exists so the constraints are on record before that changes, not because a
switch is imminent.

What would have to change, by layer:

- **Wasm runtime/build.** Workers would need to import one shared `Memory`
  instead of each owning an independent one — `wasmtime::SharedMemory`
  configured once and given to every `Instance`, or (once implemented)
  guest-side `thread.spawn_ref`. `runtime/viberun` and
  `scripts/wasm_vibe_host_runner.js` both gain a second instantiation mode.
- **Allocator and GC.** The current bump/free-list allocator assumes
  exclusive ownership of its heap; a shared heap needs an atomic-CAS-safe
  allocator at minimum. wasm-gc is much worse: today each worker's GC heap
  is independent by construction, so nothing needs a concurrent collector.
  A shared heap needs one, which is a different-sized project than
  anything else in this list. Realistically, shared-everything stays
  linear-memory-only for a long time — this matches which backend the
  47.0.2 probe above targeted.
- **Language level — this is the real gap, not a tuning problem.** `Send` in
  the checker today means "safe to move across a task boundary," which is
  free to grant because the cooperative scheduler never actually runs two
  task bodies at once — crossing a boundary is just a copy at a suspend
  point. Real parallel execution needs a second, stricter notion (Rust's
  `Send`/`Sync` split is the reference point): "safe for two threads to
  hold concurrently." Nothing in the checker today distinguishes these, and
  there is no lock/mutex/atomic type in the language to make a value
  legitimately meet the stricter bar. The `TaskGroup::run` region-escape
  check (this doc's sibling, `docs/concurrency.md`) only proves a value
  doesn't outlive its nursery scope — it says nothing about two concurrently
  running tasks touching the same value without synchronization, which is a
  different defect class (data races) that needs a different analysis.
  `TaskCell`/`ResCell`/`Ring` in `lib/@vibex/concurrent/concurrent.vibe` are
  plain non-atomic cells today, built on the "only one task body executes at
  an instant" invariant; that invariant is exactly what real threads remove.
- **Formal model.** `formal/`'s current proof target is schedule
  independence under a one-task-executes-at-a-time semantics
  (`Parallel.Machine`/`Parallel.Step` model physical worker ownership
  separately and are not yet composed with the compiler scheduler proof).
  Shared-everything's correctness target is closer to linearizability/
  data-race-freedom, which is a different proof technique, not an extension
  of the existing one.
- **Trace validator.** `parallel_scheduler_trace.mjs` checks a strict
  sequential `ready/claim/releaseComplete/publish/commit` event log against
  one coordinator's view. Real concurrent shared-memory writes need a
  happens-before-style check instead of a total order, since there may be no
  single coordinator serializing every state transition anymore.

**A narrower middle path exists and is worth remembering:** restrict sharing
to publish-once, read-only data — e.g. an interned string/symbol table or an
already-`Checked` module's `TypeEnv`, shared by reference only after it is
permanently frozen. That sidesteps most of the list above: no allocator
change beyond "this region is never freed," no GC problem (nothing in the
shared region is ever collected), no `Send`/`Sync` split needed beyond "an
immutable value is trivially `Sync`," and no race freedom proof beyond "this
was written exactly once before any reader observed it." If shared-everything
is ever pursued, this is the shape most likely to land first — it composes
naturally with the `ModuleJob`/`ModuleOutcome` publish step this document's
Phase 2 already uses, by replacing "copy the env text" with "hand out a
reference to the frozen env" without touching anything else in the pipeline.
