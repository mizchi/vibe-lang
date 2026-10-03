# TaskGroup checker dogfood, 2026-10-03

The experimental frontend now runs real checker processes through a Vibe
`TaskGroup`. Compiler and CLI builds preserve ordinary-build Wasm bytes and
perform zero final checker executions after checked-product publication.
It is **still slower than the ordinary build**; this is an opt-in dogfood path,
not the default implementation of `vibe build --jobs`.

## Ownership and build units

`@vibe/checker/worker` produces a standalone core Wasm. Each process checks up
to 16 prepared immutable module snapshots, then exits. Four slots bound live
workers; every host future owns its process, kills and reaps it on cancellation,
and releases its slot. A diagnostic is a value; a missing commit or process
failure is an infrastructure error, with bounded child stderr preserved.

`@vibe/checker/coordinator` is an RC-built component. Its `spawn_suspend`
closures capture only immutable slot/count integers and await the requestful
`vibe:checker/worker@0.0.1` WIT interface. TaskGroup owns the tasks, waits and
failure lifetimes. No Process/Fs effect is silently erased or Send weakened.
The Node host still discovers and freezes the graph, prepares dependency
occurrences, schedules **ready-wave barriers**, and publishes products in
canonical order. CPU checking happens in independent native processes, not
cooperative timers or Node worker threads. Worker completion currently uses
10ms process polling; startup and this polling are included in the measurements.

Compiler CFG initialization moved to `@vibe/compiler/config`, shared with the
CLI. Worker checked/unchecked error-row and CFG modes match CLI products.
The worker still imports the broad `@vibe/compiler/runtime` facade. This is an
artifact boundary, **not a completed pure checker/codegen responsibility split**.
Independent codegen units and completion-driven DAG scheduling remain future work.

The current named public artifacts are 4,996,762 bytes for the core worker and
46,237 bytes for the coordinator component. Their build receipt binds them to
the supplied compiler. Artifact size alone does not establish startup cost or
resident memory; the worker's broad runtime dependency still needs narrowing.

## Measured costs

Compiler `9f6bb3478032826d040580c530d9ef38cad333a5b98e3f2589c15a816198203d`
has a stage2/stage3 fixpoint. Both experiments use the same frozen 5,447-file
input, raw ABI and RC user-program output, isolated Vibe caches, equal-length
variant paths, three alternating rounds, and an idle host. Compiler/runtime/
input hash guards pass. Every output agrees within its workload.

The initial 36 builds compare serial (`s`), the existing Node prewarm (`n`),
and TaskGroup with an RC worker (`t`). Native compiled-code caching is shared;
the first TaskGroup cold sample includes its initially empty native cache.
Vibe cold/warm cache states are isolated and matched in every trial.

| Workload/cache | Ordinary | Node prewarm, jobs=4 | TaskGroup RC worker, jobs=4 |
| --- | ---: | ---: | ---: |
| Compiler cold | 14.169s | 16.620s | 25.758s |
| Compiler warm | 10.979s | 15.762s | 24.745s |
| CLI cold | 19.002s | 20.371s | 30.094s |
| CLI warm | 13.439s | 19.212s | 29.176s |

Compiler has 560 modules/114 waves; CLI has 611 modules/118 waves. The compiler
path starts 299 worker processes. One measured warm compiler run spends 9.730s
inside coordinators; the sum of each wave's longest slot totals is 8.762s.
That slot time includes worker startup, checking, transport and polling. These
phase observations do **not** by themselves identify a named CPU hotspot.

### Profile-guided worker policy

Six retained Wasmtime profiles sample a real eight-module batch from the first
ready wave of the frozen CLI graph, at 250us with function names. Across three
RC captures, `__rt_rc_dup` and `__rt_rc_drop` account for 1,112/2,363 self
samples (47.1%). The bump control has neither hotspot and has 1,412 total
samples across three captures. Epoch sampling changes execution cost; sample
counts are hotspot evidence, not the end-to-end speed claim.

The worker now follows the ordinary compiler's bump build policy. The
coordinator keeps RC ownership. Fresh processes still cap a batch at 16 jobs.
All batch products, CFG/error modes, cancellation, actual CPU overlap and
whole-build outputs pass with the bump worker.

A separate 24-build RC/bump comparison primes native code before measurement,
alternates order for three rounds, and includes discovery, preparation,
coordinators, publication and final compilation:

| Workload/cache | RC worker | Bump worker | Wall change | Aggregate tree RSS, RC → bump (KiB) |
| --- | ---: | ---: | ---: | ---: |
| Compiler cold | 25.504s | 23.854s | -6.47% | 1,302,812 → 1,309,832 |
| Compiler warm | 24.715s | 23.307s | -5.70% | 1,224,336 → 1,225,672 |
| CLI cold | 30.289s | 28.634s | -5.46% | 2,102,736 → 2,098,364 |
| CLI warm | 29.233s | 27.666s | -5.36% | 2,177,720 → 2,178,664 |

The improvement is to the experimental TaskGroup path. Ordinary builds remain
faster. Warm eligibility still needs to avoid rechecking all modules in workers.

### Memory limits of these results

RSS is a 25ms Linux **complete process-tree** sum, including detached coordinator
groups and all live workers. Shared pages are counted repeatedly and short
peaks may be missed. It is not an allocation-volume or unique-live-heap metric.
Final guest high-water alone is not reported as total memory.

Native reports retain each worker's heap base/high-water and committed pages.
The largest observed worker guest heap grows from 21.8 to 28.6MiB for compiler
and 269.6 to 297.3MiB for CLI. The profiled batch grows from 282,736,656 to
311,751,544 bytes. RC's free-list reuse means `heap_peak - heap_base` is **not**
its allocation volume; summing worker high-water marks is not a concurrent peak.
There is no total allocation-volume reduction claim. The count bound is not a
source-byte or memory budget. A byte budget and the broad runtime closure are
remaining concerns before promoting this backend.

## Dogfood and reproduction

Use a current stage2, then build the two units and an actual project:

```bash
C="$PWD/_build/taskgroup-worker-generation/stage2.wasm"
bash scripts/build_taskgroup_checker.sh "$C"
VIBE_BUILD_CACHE_DIR="$PWD/_build/taskgroup-dogfood-cache" \
  bash scripts/build_taskgroup_project.sh "$C" lib/@vibe/compiler/cli_adapter.vibe \
  "$PWD/_build/taskgroup-compiler.wasm" cli_main 4
VIBE_BUILD_CACHE_DIR="$PWD/_build/taskgroup-cli-cache" \
  bash scripts/build_taskgroup_project.sh "$C" lib/@vibe/cli/main.vibex \
  "$PWD/_build/taskgroup-cli.wasm" main 4
```

`build.json` binds checker artifacts to the supplied compiler. A changed
compiler/artifact is rejected before warming. `VIBE_TASKGROUP_WORKER_RC=1`
selects the RC control when building units; default is bump. The project helper
accepts jobs 1/2/4. This does not change the existing public CLI backend.

`VIBE_TASKGROUP_TRACE_OUT` retains phase/wave/worker events;
`VIBE_CHECKER_WORKER_MEM=1` adds native heap observations;
`VIBE_TASKGROUP_KEEP_JOBS=1` retains owned job snapshots for a named profile.
Warm once in a distinct cache, copy a prepared batch, and run the worker with
`VIBE_CHECKER_BATCH=1 VIBE_GUEST_PROFILE=<file> VIBE_GUEST_PROFILE_INTERVAL_US=250`.
Profiling must remain separate from controlled wall/RSS trials.

For a whole-build comparison, freeze generated compiler inputs as well as
tracked sources (the fingerprint and bundle files are required), isolate
per-variant Vibe caches, prime both native worker images, and alternate three
cold/warm trials. Include preparation and publication in total time. Sample
descendants by PPID/start time; process-group-only sampling misses this driver's
detached native coordinators. Compare Wasm and strict checker counters each run.

The adjacent samples contain all 60 builds with hash receipts; the summary
contains medians, artifact hashes and named-profile tables. The gzip is NDJSON
with six complete Firefox-format Wasmtime profiles, capture names and hashes.
The recorded coordinator is held constant across RC/bump comparisons. The
public coordinator was rebuilt after source formatting and has a different
image hash; the public worker remains byte-identical to the measured bump
worker. The retained measurements describe their recorded images; the public
build oracles exercise the rebuilt coordinator.

## Validation

`bash scripts/test_taskgroup_checker.sh <current-stage2.wasm>` rebuilds both
units and runs real CPU/process and WIT batch oracles plus final-build parity.
It is registered as `test-taskgroup-checker` and runs in the existing native
runner CI job, reusing its Rust cache and current stage2.

Observed positive and negative cases include: jobs 1/2/4 and repeated slots;
simultaneous CPU progress; nonempty Double lowering; exact serial products;
checked/unchecked effects and CFG; 17 jobs requiring fresh second batches;
mixed diagnosed/checked outcomes; malformed job/plan versions; slot
oversubscription; failure sibling cancellation and reaping; cold/warm diamond
and reexport/typed equality execution; source edits; diagnostic parity; relative
paths; whole compiler/CLI byte identity and zero final checks. The existing 17
host scheduler/project tests and original Node frontend oracle also pass.

The final public-helper check uses the release generation and rebuilt public
artifacts: eight actual compiler/CLI builds cover serial and TaskGroup,
cold and warm. Compiler has 560 modules and CLI has 611; all outputs agree
byte-for-byte within their workload. Both serial cold controls perform real
checks; serial warm controls and all four TaskGroup final builds perform zero
checker executions. This is functional verification, separate from timing trials.

Full `pkf run release-check` passed: 122 tasks (55 cached, 67 executed),
including the stage2/stage3 fixpoint and self-test working-tree invariants.
AST-required pre-commit, Rust formatting and shell syntax checks also passed.
