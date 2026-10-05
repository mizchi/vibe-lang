# ADR-0068 companion: compiler parallelism

Status: the worker contract, the canonical order, the determinism contract and
the oracles that check them are implemented. Phases 0 and 1 are done. The public
`vibe build --jobs 1|2|4` launcher runs the TaskGroup checker transport before
the final serial build. It validates the worker and coordinator images against
the selected compiler's build receipt. On `vibe test`, `--jobs N` runs N test
files at once. Function-body codegen fan-out remains unimplemented. The original
owning issues (#906, #1239, #1259) are closed.

The TaskGroup dogfood path is also available through scripts:
`scripts/build_taskgroup_checker.sh` builds a core checker worker and an RC
coordinator component; `scripts/build_taskgroup_project.sh` runs checks through
the native `vibe:checker/worker@0.0.1` WIT bridge before the final serial build.
It supports jobs 1/2/4, ready-wave barriers, bounded fresh worker batches, and
canonical publication of complete lowering products. The worker calls
`@vibe/checker/engine` rather than the compiler/runtime facade. The engine and
environment transport are separate packages; this does not complete the
checker/codegen responsibility split. Initial compiler/CLI parity, costs and memory limits are recorded
in [the TaskGroup dogfood report](../reports/taskgroup-checker-2026-10-03.md).
That report measures the initial experimental path, which was slower than
ordinary builds; it is not a measurement of every later launcher revision.

Successful products for an identical job snapshot can optionally replay with
`VIBE_TASKGROUP_JOB_CACHE=1`. Lookup binds the source, ordered dependency
occurrences and Env bytes, producer images and execution environment; misses
still run real TaskGroup CPU workers. Diagnostics are checked again. The
compiler validates canonical publication before new entries are stored.
This avoids warm worker checks and input-directory writes, while adding a cold
cost. It remains opt-in; [the replay report](../reports/taskgroup-checker-replay-2026-10-04.md)
records complete-build timings, memory limits and the exact measurement basis.

Related: ADR-0040, ADR-0059, ADR-0068, ADR-0071.

## Position

The compiler is the reference CPU-bound workload for ADR-0068. It uses the
same shared-nothing contract a vibe program gets from a task group: a worker
receives an immutable job and returns a value, and one coordinator commits the
values in a canonical order. There is no second, compiler-only concurrency model
built on shared mutable memory.

The original prewarm prototype uses host workers. The opt-in dogfood coordinator
uses `@vibe/concurrent/experimental` TaskGroup to own task waits and cancellation.
Its requestful WIT calls run independent native checker processes, each with its
own heap. The language scheduler remains cooperative; the CPU parallelism comes
from those host processes. No shared mutable compiler state is introduced.

The first parallel unit is a module's parse and typecheck over the import DAG.
Function-body codegen comes later, if at all (see [Codegen split](#codegen-split)).
Whole-program planning, the canonical commit, linking and cache publication
stay coordinator operations.

This document is the design of compiler parallelism.
[concurrency.md](concurrency.md) is the source of truth for the language
semantics it borrows.

## Pipeline and barriers

`compile_file_fs_mode_rc` (`lib/@vibe/compiler/entry/compiler/file_compile/file_compile.vibe`)
runs four phases: collect (read and parse every reachable file), typecheck,
merge, and codegen with link and emit. The profiled path in the same file
times load, typecheck, bundle fingerprint, parse/merge and final compile
separately.

| Phase | First parallel unit | Barrier |
| --- | --- | --- |
| source and header load | one file | the filesystem snapshot is fixed before any worker starts |
| lex / parse | one source file | collection runs in one process |
| dependency fingerprint and typecheck | a ready module of the import DAG | the walk runs one module at a time; `TypeDb`, `RippleDb` and the environment cache are coordinator state |
| export rename / merged source | none | the rename plan spans every source group, because collisions cross groups |
| whole-program codegen planning | none | function, type, constructor, string, effect and import indices are global |
| function-body codegen | one top-level function | only after global indices and per-function id ranges are frozen |
| Wasm link and artifact publication | coordinator | section order, diagnostics and cache writes are canonical |

Parallelizing must not put a lock around the existing mutable state and call
that the model.

## State and worker contract

The coordinator owns every piece of changing build state:

```text
CompilerDriverState
  source snapshot
  import DAG and rank (topological) order
  ready / running module ids
  canonical ModuleOutcome store
  TypeDb / RippleDb commit state
  cache publication queue
```

A worker receives an immutable job and returns one terminal value. The job is
`ModuleJob` in `lib/@vibe/compiler/runtime/index.vpkg`:

```text
ModuleJob
  path       the module's logical path
  source     its source text
  deps       its direct dependencies, in declaration order
  dep_fps    each dependency's fingerprint, in the same order
  dep_envs   each dependency's checked environment, in the same order

ModuleOutcome            (opaque)
  Checked(ModuleArtifact)
  Diagnosed(diagnostics)

ModuleArtifact           (conceptual)
  module id and fingerprint
  public type and effect interface
  typed or normalized IR later stages need
```

`check_module(job: ModuleJob) -> ModuleOutcome with Env + Exception` takes no
`Fs`: every environment it needs is a value in the job. It cannot read the
result store, update `TypeDb`, write the cache, or observe which unrelated job
finished first. That is what makes a schedule unobservable.

`dep_envs` is exactly the coordinator's resolved direct-dependency projection,
not its whole accumulated cache, so rows a module does not import cannot
affect how its imports resolve. The module's fingerprint is an output of the
job, computed by `check_module` from `source` and `dep_fps`
(`build_fingerprint`), never a value the caller supplies; that is what makes a
worker's result land at the same persistent-cache key the serial walk looks
under.

### FrozenArray

Moving large values between workers must not degrade into a serialization
benchmark, so the contract needs an immutable bulk container that is `Send`.
`FrozenArray[T]` is that container: a checker-level distinction over
`Array[T]`'s runtime layout. Its surface is `FrozenArray::from_array`,
`FrozenArray::get`, `FrozenArray::length` and `FrozenArray::to_array`, with no
mutation. `Send`'s structural judgement (`send_ok_rec` in
`lib/@vibe/compiler/checker/checker_trait.vibe`) treats `FrozenArray[T]` as
`Send` exactly when `T` is, while `Array[T]` is never `Send`.

Both conversions copy (#1733): with an identity cast, a retained `Array`
handle on either side could change the value after it became `Send`.
`ArrayBuilder::freeze` stays an identity cast, so build-then-freeze code pays
nothing. Pinned by `fixtures/frozen_array_copies_test.vibe`,
`fixtures/region_ok_frozen_array_basic.vibe`,
`fixtures/send_bound_frozen_array.vibe`,
`fixtures/err_type_send_frozen_array_of_array_bound.vibe` and
`fixtures/region_ok_frozen_array_taskgroup_capture.vibe`.

Nothing in the module-job pipeline produces or carries a `FrozenArray` yet;
the `Diagnosed` payload above is a description, not a type.

Mutable `Array`, `Bytes`, handlers and continuations remain non-`Send`.

### Effect boundary

At the level of ADR-0071's operation rows, the driver needs selected
filesystem and timing operations; a worker needs neither ambient `Fs` nor a
coarse `Async`:

```text
driver:  Fs::read_file, Fs::write_bytes, Fs::rename, Profiler::now_us
worker:  check_module(job: ModuleJob) -> ModuleOutcome   (no Fs)
```

## Scheduling and commit

1. The driver reads source and module headers and freezes a source snapshot.
2. It rejects import cycles and assigns every module a rank: 0 for a leaf,
   otherwise one more than its highest-ranked dependency.
3. Every unpublished module whose direct dependencies have terminal outcomes
   is ready. A whole rank is ready at once.
4. Ready jobs run on a bounded pool. Completion order is not compiler output.
5. Outcomes are stored by module id, and everything derived from them --
   arrays, diagnostics, persistent artifacts -- is committed in canonical
   order.
6. A module whose dependency failed gets no diagnostic of its own; it is
   blocked, and reporting one would be a cascade.
7. When every reachable module is terminal, the driver emits the canonical
   diagnostics or proceeds to whole-program planning.

Steps 1 and 2 are implemented. The serial walk (`ensure_fingerprint_fs_impl`)
collects the import edges first (`plan_import_graph_fs`) and passes them to
`plan_module_order` (`lib/@vibe/compiler/module_graph/module_graph.vibe`)
before checking anything, so a cyclic graph is rejected before any module is
checked, committed or cached. The order is rank ascending, then module path
ascending, so it does not depend on the order dependencies were visited, and
the walk is a loop over ranks, one module at a time. Out of process, the
`VIBE_MODULE_PLAN=1` adapter mode (`module_plan_manifest_fs`) returns the same
plan from one compiler invocation: every reachable module with its
dependencies, ingested source and rank.

Expected type and check errors are values in `ModuleOutcome`; they do not
leave a worker as a task failure. Parse errors are still thrown by
`check_module` and become values at the job-directory boundary (below). A
trap, an unexpected runtime failure or a violated compiler invariant is a task
failure: it fails the whole compile.

Diagnostics are ordered by normalized module path, then source start and end,
then diagnostic code, then message, and never by task id or completion time.
The implemented comparator (`module_diag_lt`) uses path, then message: there
are no diagnostic codes, and the source span is not consulted. It is total,
so the order never depends on how diagnostics were collected.

Collection is behind `VIBE_DIAGNOSTICS_ALL=1` (`set_collect_module_diagnostics`).
The walk diagnoses a module, marks it failed, keeps checking its siblings in
the same rank -- they cannot depend on it -- and skips only the modules that
depend on a failure. The collected set is byte-identical across
`VIBE_DEP_ORDER_SEED` values, the within-rank permutation a parallel
coordinator would vary (`tests/gates/late/adr_0068_taskgroup_g_body_syntax_sugar.sh`,
"cross-module diagnostics collected in canonical order"). The default stays
fail-fast: collecting changes the error text and checks and caches modules a
fail-fast walk never reaches, so changing the default is its own decision.

## Codegen split

Function codegen may run in parallel only after a serial `WholeProgramPlan`
is frozen:

```text
WholeProgramPlan
  canonical function and import indices
  type / constructor / struct tables
  string and effect tables
  per-function lambda / coverage / debug id ranges
  immutable call and capture lookup tables
```

A function worker receives the plan and one normalized body, and produces a
body buffer and metadata inside its preassigned ranges. It may not append to a
shared `LambdaTable`, allocate global ids, mutate the merged AST, or publish
Wasm sections. The linker concatenates bodies and metadata in the plan's
function order.

Trait-dictionary rewriting, export renaming, DCE roots, global index
assignment and section emission stay serial. They can be split later only by
refining the plan, without changing a byte of output.

What exists:

- **Body product transport** (`@vibe/codegen/transport`). The single
  `CodegenBodyCache` definition, constructors and VBC6 codec compile without
  compiler, AST or parser imports. The existing common-base facade re-exports
  the same product and API. Record/replay still uses `LambdaTable` and
  `LineMapState` in common-base. This separates the exchange representation;
  it does not freeze a whole-program plan, make its mutable arrays `Send`, or
  implement function-body workers.
- **Reusable function preparation** (`LinkedFunctionPlan`). The serial
  preparation entry normalizes every function and thunk in canonical order,
  preserves its original type annotation, and assigns lambda bases. Body
  emission can consume the same plan for multiple slices instead of drawing
  fresh names and recounting lambdas per slice. The ordinary entry also uses
  this path. The record's AST arrays are read-only by calling convention,
  not a `Send` transport. Context tables and coverage/debug ranges still need
  a complete whole-program plan before body workers can run concurrently.
- **Planned lambda indices** (#1277). A lambda's function index, which is
  baked into its enclosing body as a table-slot immediate, comes from a
  counting pass that gives each function a base in canonical order, not from
  the live length of the shared lambda table. The live length is still
  computed and must agree with the plan (`compile_lambda.vibe`), so a drift is
  a compile error rather than different bytes.
- **Slice compilation** (#1305): `slice_lo` / `slice_hi` compile only a range
  of function bodies, padding the lambda table for the bodies skipped, with
  record/replay/merge plumbing for a body cache.

What does not: a `--jobs N` fan-out over slices. Measured with the slice
mechanism itself -- compile once with every body and once with none, and the
difference is the parallelizable share -- function bodies are about a tenth
of codegen (0.017 ms per function against 0.165 ms of serial work per
function, on synthetic programs of 400 to 3,000 functions). Four-way body
codegen would save about 3% of a cold compile before paying for workers. The
serial share is where the time is. Slicing stays as the measurement
instrument; measure the same way again before building a fan-out on it.

## Cache publication

Cache keys and fingerprints are derived from content, so they do not depend on
the schedule. A worker may compute bytes but does not publish them.

Readers must see either the previous complete value or the new complete value,
never partial bytes. Both runners implement a guest's `Fs::write_file` and
`Fs::write_bytes` as a write to a unique temporary file in the destination
directory followed by an atomic rename (`atomicWriteFileSync` in
`scripts/wasm_vibe_host_runtime.js`, `vibe_atomic_write` in
`runtime/viberun/src/host_imports.rs`; #1173). Two writers of one key both
produce complete files and the last rename wins, which is safe because a key
already names its content. A per-key single-flight table would only be an
optimization. Automatic mid-build garbage collection stays forbidden
(ADR-0059).

## Determinism contract

For a fixed source snapshot, compiler version, target, flags and entry point:

```text
module_outcomes(jobs = 1) = module_outcomes(jobs = N)
diagnostics(jobs = 1)     = diagnostics(jobs = N)
wasm_bytes(jobs = 1)      = wasm_bytes(jobs = N)
cache_values(jobs = 1)    = cache_values(jobs = N)
```

Byte identity is required, not behavioural equivalence: debug and name
sections, generated ids and diagnostics use planned canonical indices, never
scheduler order.

`--jobs 1` is the reference implementation and the debugging oracle. `--jobs
N` is a compiler CLI control, not a language-level thread or CPU-count API,
and the worker count is host policy that cannot change output.

Checked by:

- `scripts/dep_order_oracle.sh`: byte-identical Wasm across
  `VIBE_DEP_ORDER_SEED` values, each with a cold cache. It refuses a compiler
  that does not contain the `VIBE_DEP_ORDER_SEED` literal, because against such
  a compiler every seed passes;
- `scripts/scheduler_trace_oracle.sh` (`pkf run test-scheduler-oracle`), below;
- `scripts/compiler_differential.sh`: two compiler builds emit identical
  bytes, each compile with its own cold cache;
- `scripts/bench_module_job_pool.sh` (`pkf run bench-module-job-pool`) and
  `scripts/test_parallel_warm_pool_gate.sh` (`pkf run test-warm-pool`):
  identical outcomes at every pool size.

These run on demand; none is a dependency of `pkf run test` or the CI gates.
What the compiler gate does run is the synthetic scheduler prototype (a
dependency of `pkf run test`) and, in its late lane, the module job directory
contract, the plan-versus-per-file graph comparison, cycle rejection before
any commit, and seed-invariant diagnostic collection.

## Lean model

The design's claims are modeled under `formal/`:

| Design concept | Lean object |
| --- | --- |
| acyclic import graph | `Compiler.Project.dependencies` / `rank` / `dependencyRankLt` |
| coordinator result map | `Compiler.BuildState.results` |
| ready rule | `Compiler.Ready` |
| worker isolation | `dependencySnapshot` and `CompileJob` |
| canonical sequential oracle | `expected : ModuleId -> JobResult` |
| worker obligation | `JobCorrect` |
| nondeterministic completion | `Step` / `Runs` |
| schedule-independent final state | `complete_schedules_are_deterministic` |
| byte and output determinism | `emitted_output_is_deterministic` |

The definitions are in `formal/VibeFormal/Compiler/Scheduler.lean` and the
theorems in `formal/VibeFormal/Proofs/SchedulerCorrect.lean`.

Physical worker ownership is modeled separately by `Parallel.Machine` and
`Parallel.Step`, whose traces refine the async lifecycle oracle and keep one
running task per worker ([concurrency.md](concurrency.md#parallel-refinement-oracle)).
The compiler scheduler treats a job's completion as one atomic step; proving
that a parallel task's completion publishes exactly its `ModuleOutcome` is a
composition proof nobody has written.

The proof is conditional: workers must satisfy `JobCorrect`, and both
schedules must reach `Complete`. It proves neither fairness nor that this
compiler implements the worker contract; runtime tests and differential
compilation check that.

### The real compile path, against the Lean model

`VIBE_SCHEDULER_TRACE=<path>` (`set_scheduler_trace_path`) makes the serial
walk record what it planned and what it did:

```text
project<TAB><path><TAB><rank>[<TAB><dep>...]   Project.dependencies / .rank
step<TAB><path><TAB><fingerprint>              the Step.run sequence, in
                                               execution order
```

`scripts/scheduler_trace_oracle.sh` (`pkf run test-scheduler-oracle`) turns
each Lean definition into a check over those rows:

| Lean | Check on the trace |
|---|---|
| `Project.dependencyRankLt` | every dependency of a module has a strictly smaller rank |
| `Ready` (a) | each module is stepped exactly once |
| `Ready` (b) | every dependency of a stepped module is stepped strictly earlier |
| `Complete` | every planned module was stepped |
| `StoreCorrect` / `JobCorrect` | permuting the schedule reaches the same store |

A `step` row is written where the result is published, the point
`BuildState.finish` occupies in the model, so a trace cannot claim a module
that then failed. Two guards keep the checks from passing vacuously: a trace
with fewer than two steps fails, and so does a seed set in which no seed
changed the step order.

This is evidence that the compiler meets the model's premises on real input,
not a machine-checked link between the compiler and the model: the proofs
still assume `JobCorrect` rather than derive it.

## Runtime backend

The production multi-worker shape is a host that owns the workers, each with
its own instance, linear heap and host context, exchanging jobs and outcomes
as immutable values. No `SharedMemory` is required, which matches the
language's shared-nothing contract more directly than guest-side WASI threads,
whose instances share linear memory.

An ordinary OS process pool over the AOT-compiled compiler image already has
that shape and scales. `viberun --precompile` produces a `.cwasm`, which a
fresh process loads in about 8 ms against about 485 ms to JIT the `.wasm`. On
32 module jobs from the compiler's own sources and 4 cores, the pool ran in
290 ms serially, 155 ms at `-P 2` and 86 ms at `-P 4` (3.37x), with identical
outcome, fingerprint and environment bytes at every level
(`scripts/bench_module_job_pool.sh`, #1248). Separate processes isolate more
strictly than threads, and a reused per-thread instance would not help: the
compiler's bump allocator never frees, so each unit of work gets a fresh
instance anyway.

A Wasmtime embedder with several instances in one process may still be worth
building for in-process dispatch or finer cancellation. It is not a
prerequisite for a parallel frontend. Thread ids, stores and Wasmtime flags
never become vibe values.

## Host multi-worker prototype

The executable bridge:

- `scripts/parallel_scheduler_prototype.mjs`: coordinator-owned scheduling,
  outcome publication and canonical commit;
- `scripts/parallel_scheduler_worker.mjs`: persistent `node:worker_threads`
  workers that receive only a structured-cloned job;
- `scripts/parallel_selfhost_checker.mjs`: a stage2 compiler daemon per
  worker, and validation of its answers;
- `scripts/parallel_scheduler_trace.mjs`: a pure trace validator;
- `scripts/parallel_scheduler_prototype.test.mjs`: `jobs=1/2/4`, dependency,
  diagnostic, double-claim and worker-failure regressions
  (`pkf run test-parallel-scheduler-prototype`);
- `scripts/parallel_scheduler_selfhost.test.mjs`: differential checks
  against the selfhost compiler (`pkf run test-parallel-selfhost-scheduler`,
  which builds a current stage2 unless `VIBE_PARALLEL_COMPILER_WASM` names
  one).

The prototype's trace names the bridge points:

| Prototype event | Model / contract point |
| --- | --- |
| `ready` | `Compiler.Ready`: every direct dependency is terminal |
| `claim` | `Parallel.Event.claim`, projecting to `Async.Event.dispatch` |
| `releaseComplete` | `Parallel.Event.releaseComplete`, projecting to task completion |
| `publish` | the coordinator's `Compiler.BuildState.finish` |
| `commit` | canonical module-id order, independent of completion order |

Workers share no memory with the coordinator: sources and dependency outcomes
cross by structured clone, and a worker cannot see the result map. The
`synthetic` worker hashes the job and injects test diagnostics; the
`selfhost-check` worker runs the real parse and typecheck in a compiler daemon
it owns.

### The module job directory

The job directory is the in-memory `ModuleJob -> ModuleArtifact` API this
design needs, in a form a separate process can use. `VIBE_MODULE_JOB_DIR=1`
(`run_module_job_dir`) makes the compiler read a job directory, which is also
its whole filesystem sandbox, and answer with a value:

```text
<dir>/job.txt          `version 1`, `path <logical path>`, one `dep <path> <fingerprint>` row per dependency (tab-separated)
<dir>/source.vibe      the module source, verbatim
<dir>/dep<i>.env       dependency i's serialized public environment
<dir>/outcome.txt      "ok" or "diag", written LAST as the commit marker
<dir>/env.out          on ok: the checked environment
<dir>/cache.out        on ok: the fingerprint-bound environment + actual lowering product
<dir>/fingerprint.out  on ok: the module's own fingerprint, as check_module computed it
<dir>/diag.txt         on diag: one diagnostic per line
```

A parse error, which `check_module` throws, becomes a `diag` outcome at this
boundary; a `dep<i>.env` that exists but does not decode is an infrastructure
failure, not a missing interface.

A worker cannot look its dependencies up -- the environment cache key derives
from the whole transitive source snapshot, which is exactly what it may not
see -- so the driver serializes each dependency's environment
(`persistent_type_env_cache_text`) and the worker decodes it
(`parse_persistent_type_env`). The `path` row is the module's logical path:
never opened, but the directory every import resolves against.

The successful check also populates the typed-lowering memo. `cache.out`
freezes that result, including legitimately empty tables; absence is an
infrastructure failure. Its first line is
`checked-worker-cache<TAB>1<TAB><fingerprint>`, followed by a complete v11
persistent module record with a v8 lowering table. The coordinator retains
this product separately from the v10 `env.out` used by dependent checks.

Three-column publication rows (`fingerprint<TAB>envfile<TAB>cachefile`) require
that exact fingerprint/version header, a readable complete lowering table,
and canonical bytes whose environment agrees with `envfile`. The existing
lowering decoder validates counts, digest and end marker. The compiler writes
the record only after validation. Legacy two-column rows still publish
`lowering<TAB>missing`, which the serial compiler rechecks; they never become
an authorized empty table.

`scripts/module_job_dir_test.sh` pins the contract in the late compiler gate.
Its discriminator is not "a module with an import checks clean" -- an
unresolved import is lenient, so that passes even when the environment is
dropped. It asserts that calling an imported function with the wrong argument
type is diagnosed, and is lenient once the environment is withheld; and that
changing only a dependency's fingerprint changes the importer's.
It also publishes a real nonempty Double-call lowering product and rejects
missing/truncated products, mismatched fingerprints/environments, old
versions, invalid counts/digests, unavailable lowering and noncanonical bytes.
`parallel_scheduler_selfhost.test.mjs` runs a two-module DAG through real
workers at `jobs=1/2/4` with identical output, and
`scripts/parallel_project_driver.mjs` discovers a real on-disk project's DAG
(including a diamond, `scripts/fixtures/parallel_project_sample/`) and checks
it end to end, two hops deep.

An unexpected worker exception, compiler trap, daemon exit or protocol
violation fails the whole run and stops the pool; it is never turned into a
diagnostic. The selfhost bridge materializes the job's source only inside a
worker-private directory, which is an adapter detail, not permission to read
the project tree.

## Implementation phases

### Phase 0: oracle and measurement -- done

- Cold and warm timings and peak heap (`scripts/selfcompile_kpi.sh`).
- A sequential executor with a randomized ready order and no real
  parallelism: `VIBE_DEP_ORDER_SEED` permutes each node's dependency visit
  order (0 is the production order). The recorded dependency order stays
  declaration order, because `build_fingerprint` folds it as a sequence.
- Red: different ready orders and repeated runs must give byte-identical Wasm
  and identical diagnostics and cache values (`scripts/dep_order_oracle.sh`).

### Phase 1: module job extraction -- done

`ModuleJob`, `ModuleOutcome`, `check_module` and `commit_module_outcome`
exist, and `commit_module_outcome` is the only place a module's filesystem and
accumulator writes happen. The walk is a loop over ranks from the upfront
plan. `scripts/compiler_differential.sh` holds the byte-identity comparison.

Remaining:

- Parse errors are thrown, not returned as `Diagnosed` (`check_module` keeps
  an `Exception` row). Making them values would relabel every parse
  diagnostic.
- The default is fail-fast; collection is opt-in (above).
- The walk still checks one module at a time in one process. Dispatching a
  rank out of process is a change to that inner loop, not to the walk's
  structure.

### Phase 2: bounded parallel frontend -- built as a cache pre-warm, not wired

The pieces:

1. **Discovery.** One `VIBE_MODULE_PLAN=1` call returns the whole graph in
   canonical order (#1239 step 4(D)). `VIBE_LIST_DEPS`, the per-file mode it
   replaced, remains as the oracle it is diffed against: the two must
   describe the same graph (late gate, "VIBE_MODULE_PLAN agrees with the
   per-file VIBE_LIST_DEPS graph").
2. **Checking.** Every module runs through a module job directory, on
   `worker_threads` (`scripts/parallel_frontend_warm.mjs`) or on a bash
   process pool that needs no node (`scripts/parallel_warm_pool.sh`, which
   the installer still copies into the toolchain).
3. **Publication.** `VIBE_PUBLISH_ENV_CACHE=1` (`run_publish_env_cache_dir`)
   writes each checked module's complete product to the real persistent-cache path
   the serial walk looks under. The path is read out of the compiler rather
   than re-derived on the host, because it folds in the build's own codegen
   fingerprint. The Node bridge carries the worker's actual lowering table
   and uses the three-column publication contract above. Environment-only
   legacy callers still publish unavailable lowering and require a recheck.
4. **The serial compile then runs unchanged.** A `Diagnosed` module is absent
   from the publish manifest, so the serial walk re-checks it and reports the
   identical diagnostic. Checked products must preserve all lowering facts;
   an invented empty table would silently change generated code.

`scripts/test_parallel_frontend_warm.sh` (`pkf run test-parallel-frontend-warm`)
asserts zero serial checker executions after publication at jobs=1/2/4,
identical diagnostics and byte-identical Wasm, with isolated cold/warm caches.
It executes Double calls, imported/re-exported Show wrappers and typed
structural equality, and checks a same-signature dependency body edit and the
relative-path adapter. `scripts/jobs_kpi.sh` (`pkf run jobs-kpi`) reports cold and warm
wall time, peak guest heap and host RSS for it. Neither is part of `test` or
`full-gate`.

No CLI verb runs the pre-warm. Since #2858 moved argument handling into
`lib/@vibe/cli`, `--jobs N` on `vibe build`, `compile` and `check` is
validated (a positive integer) and has no effect on what is built
(`parse_jobs_value`). `vibe test --jobs N` with several files runs N
dispatcher processes, each compiling and running a contiguous share of the
files, and replays their output in file order; `--update` stays serial.

Measured on the compiler's own manifest of about 218 modules with discovery
done per file (#1168): the pre-warm cut the final compile's peak guest heap by
about 47%, but wall time at `jobs=2/4` was 2.3 to 3 times the serial baseline,
because every module cost a compiler process launch just to learn its
dependencies. `VIBE_MODULE_PLAN` removed that cost (17.4 s serially and 5.1 s
at 4-way for per-file discovery, against 0.8 s for the single plan call, on a
166-module graph), and the default worker count was never raised. No
end-to-end measurement of the pre-warm after that change is recorded; measure
before wiring it into a command again.

### Phase 3: immutable whole-program plan -- partial, not scheduled

- Split global discovery and index allocation from body emission: the lambda
  index plan and slice compilation exist ([Codegen split](#codegen-split)).
- Preassign every function, lambda, coverage and debug range.
- Red: shuffling body completion order must not change any Wasm byte.

Parallel body codegen is not planned at the measured body share.

### Phase 4: backend differential -- not scheduled

- Run the same suite on the cooperative, Worker/host-task and WASI backends.
- #488's shared-everything backend stays opt-in and must pass the same result
  and trace oracles before use.

## Completion gates

Before a parallel path becomes the source of truth for a build:

- no module starts before every direct dependency has a terminal outcome --
  checked on the real walk by the scheduler trace oracle;
- no worker can observe an unrelated job's completion or mutate driver
  state -- the job-directory sandbox and `dep_envs` projection;
- expected diagnostics are values and are stable across schedules --
  collection plus the canonical order, opt-in;
- an unexpected task failure cancels the run and leaves no partial cache
  artifact -- a failed worker publishes nothing and writes are atomic; the
  advisory pre-warm deliberately does not cancel (below);
- `--jobs 1/2/4` produce byte-identical Wasm on the compiler corpus -- today
  asserted only on the sample project (serial against pre-warmed at 4 jobs,
  `test_parallel_frontend_warm.sh`) and for published environments at every
  pool size (`test_parallel_warm_pool_gate.sh`);
- cold and warm compile time, peak guest heap and host RSS are reported
  before the default worker count is raised (`pkf run jobs-kpi`). The report
  does not decide the default; that stays a separate, deliberate decision,
  and the default is 1;
- `cd formal && lake build --wfail` stays green without `sorry`.

### Cancellation and backpressure in the warm pool

The pre-warm is advisory: the serial compile always runs after it, and a
module that fails to check is simply absent from the publish manifest. So
nothing in the pool needs cancelling, and stopping on the first failure would
only give up warming siblings that would succeed. `build_and_run_job`'s
`|| true` in `parallel_warm_pool.sh` is right for that contract and would be
a bug in a dispatcher whose output a build depends on.

Bounded parallelism and backpressure are measured. `xargs -P N` reads the next
module only when a slot frees, so at most N jobs run plus one rank of pending
paths, and it reaps every child before a rank returns.
`test_parallel_warm_pool_gate.sh` pins this on a fan-out fixture (eight
independent leaves under one root) through `VIBE_WARM_POOL_TRACE`, which makes
each job append `+` on entry and `-` on exit:

| Run | Peak workers in flight |
|---|---|
| `-P 1` | exactly 1 |
| `-P 4` | at least 2, at most 4 |

`-P 1 == 1` guards against an empty trace, and `-P 4 >= 2` against a pool
that silently went serial. The gate also asserts that no runner outlives the
coordinator.

If a dispatcher ever becomes the source of truth -- parallel codegen would
make it one, because its output is the artifact -- the cancellation criterion
applies in full.

## Shared-everything migration note

Everything above is shared-nothing: each worker owns its instance and heap,
and jobs and outcomes cross as copied values. This note records what a move
to shared-everything threads (#488) would require, so that today's choice
does not close that door by accident. It is not planned work.

It is not available today. Wasmtime accepts the shared-everything-threads flag
but does not wire it into its validator or text parser; only core Wasm
atomics and shared memory work, and WASI threads were removed in Wasmtime
47.0.0 ([wasm_threads_requirements.md §4](../compiler/wasm_threads_requirements.md)).

What would have to change:

- **Runtime and build.** Workers would import one shared memory instead of
  owning one each. Both runners would need a second instantiation mode.
- **Allocator and GC.** The allocators assume they own their heap; a shared
  heap needs at least an atomic allocator. The wasm-gc backend would need a
  concurrent collector, a project of a different size, so shared-everything
  would be linear-memory only for a long time.
- **The language.** `Send` means "safe to move across a task boundary", which
  is free to grant while the cooperative scheduler never runs two task bodies
  at once. Real parallel execution needs a second notion -- safe for two
  threads to hold at once, Rust's `Sync` -- and the language has no lock,
  mutex or atomic type for a value to meet it with. The region-escape check
  ([concurrency.md](concurrency.md)) proves a value does not outlive its
  group; it says nothing about two running tasks touching one value, which is
  a different defect (a data race) needing a different analysis. `TaskCell`,
  `ResCell` and `Ring` in `lib/@vibe/concurrent/experimental/concurrent.vibe`
  are plain non-atomic cells built on "one task body runs at a time", the
  invariant threads remove.
- **The formal model.** The proofs target schedule independence when one task
  runs at a time. Shared-everything needs linearizability or
  data-race-freedom, a different technique.
- **The trace validator.** `parallel_scheduler_trace.mjs` checks a total order
  of events seen by one coordinator; concurrent shared writes need a
  happens-before check.

A narrower middle path is likely to come first: share only data published
once and read-only afterwards -- an interned symbol table, or a checked
module's `TypeEnv` -- by reference, after it is frozen. It needs no allocator
change beyond "this region is never freed", no collector, no `Sync` beyond
"an immutable value is trivially `Sync`", and no race-freedom proof beyond
"written once before any reader saw it". It fits the job/outcome publish step
the pre-warm already uses: hand out a reference to the frozen environment
instead of copying its text.
