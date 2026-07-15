# ADR-0068 companion: selfhost compiler parallelism

Status: proposed

Date: 2026-07-16

Related: ADR-0040, ADR-0059, ADR-0063, ADR-0068, ADR-0071, #488, #806,
#906

## Position

The selfhost compiler is the reference CPU-bound workload for ADR-0068. It
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
`lib/@vibe/compiler/entry/compiler/file_compile/index.vibe`.

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

The proof is conditional: workers must satisfy `JobCorrect`, and both schedules
must reach `Complete`. It proves neither fairness nor that the current selfhost
compiler implements the worker contract. Those are locked by runtime tests and
differential compilation, not asserted by the Lean model.

## TDD implementation sequence

### Phase 0: oracle and measurement

- Record cold/warm `load/type/bundle/parse/compile/total` timings and peak heap.
- Add a sequential randomized-ready-order executor with no real parallelism.
- Red: different ready orders, worker counts, or repeated runs must produce
  byte-identical Wasm and identical canonical diagnostics/cache values.

### Phase 1: module job extraction

- Extract pure header parse and `check_module` functions.
- Replace recursive accumulator threading with `ModuleOutcome` plus a single
  coordinator commit path.
- Differentially compare the new `--jobs 1` path with the old compiler.

### Phase 2: bounded parallel frontend

- Run ready module jobs through the ADR-0068 nursery/channel implementation.
- Start with a conservative worker bound because a full selfhost compile has a
  high heap watermark; measure throughput and peak RSS together.
- Keep filesystem and persistent-cache writes in the driver.

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
- `--jobs 1/2/4` produce byte-identical Wasm on the selfhost compiler corpus;
- cold and warm compile time, peak guest heap, and host RSS are reported before
  raising the default worker count;
- `cd formal && lake build --wfail` remains green without `sorry`.
