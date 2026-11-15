# Checker TaskGroup boundary on current main, 2026-11-15

Part of #2507. This measures the existing isolated checker worker and its
actual consumer: the ordinary filesystem compiler reading the checked
environment and lowering rows published by the frontend. The worker product
excludes the complete checked AST and final substitution measured in the
[earlier checked-module cache experiment](compiler-unit-boundaries-2026-11-09.md).
The coordinator dispatches module jobs through `TaskGroup` and each worker
runs as a fresh process.

## Whole-build cost

Medians of three cold/warm pairs per corpus and lane.

| Corpus | Cache | Wall, ordinary → 4 workers | Aggregate peak RSS, ordinary → 4 workers | Final guest frontier, ordinary → 4 workers |
|---|---|---:|---:|---:|
| Compiler closure | Cold | 11.79 → 19.52 s (+65.5%) | 1,505 → 937 MiB (−37.8%) | 1,379 → 816 MiB |
| Compiler closure | Warm | 6.88 → 8.87 s (+29.0%) | 917 → 905 MiB (−1.3%) | 809 → 808 MiB |
| Split CLI | Cold | 23.58 → 35.48 s (+50.5%) | 2,891 → 1,773 MiB (−38.7%) | 2,796 → 1,686 MiB |
| Split CLI | Warm | 14.12 → 17.48 s (+23.8%) | 1,747 → 1,765 MiB (+1.0%) | 1,676 → 1,675 MiB |

The lower cold peak includes the complete process tree, including workers.
The final compiler's cold heap reaches roughly its ordinary warm frontier.
The frontend has already exited when that compiler starts. Warm builds run no
worker processes and still incur discovery, product lookup and republication
before the final build.

### Clock discrepancy

The harness recorded elapsed time from `CLOCK_MONOTONIC` (`wall_s`) and
`CLOCK_REALTIME` (`realtime_elapsed_s`) over the same interval. Several
runs across all three series differ by about 2.8–3.0 s. For example, the
initial split CLI warm comparison has medians of 17.32 → 16.55 s on the
monotonic clock and 14.35 → 16.54 s on realtime, so the comparison reverses.
A later four-clock probe on the same WSL host observed two steps during
which realtime moved backwards by 2.9257 s and 2.9255 s, respectively.
Across those same sample intervals, `CLOCK_MONOTONIC` advanced by
26.8 ms and 27.5 ms, while `CLOCK_MONOTONIC_RAW` advanced by 24.3 ms and
25.0 ms. This reproduces the size and direction of the disagreement.
The trigger for the realtime steps is unverified. Use the monotonic
readings for elapsed time and retain both readings in the raw data.
Differences under 5% remain inconclusive for rollout.
Output hashes, checker counters, and the observed process-tree RSS peaks
are separate observations.

## What limits scaling

| Corpus | Cache | Discovery | Job preparation | Coordinator | Product reads | Publication | Frontend total |
|---|---|---:|---:|---:|---:|---:|---:|
| Compiler closure | Cold | 1.28 s | 1.43 s | 7.46 s | 0.55 s | 1.17 s | 11.98 s |
| Compiler closure | Warm | 0.54 s | 0.27 s | <0.01 s | <0.01 s | 0.70 s | 1.57 s |
| Split CLI | Cold | 2.28 s | 2.82 s | 11.80 s | 1.02 s | 2.00 s | 20.03 s |
| Split CLI | Warm | 0.88 s | 0.52 s | <0.01 s | <0.01 s | 1.13 s | 2.61 s |

Phase medians are taken independently. The total includes frontend overhead
outside the five named spans. Coordinator timing includes runner startup,
worker checking, product emission and process completion. Attribution to
individual CPU or I/O costs requires a separate profile.

- The 395-module compiler closure schedules 97 waves and launches 241 worker
  processes. Its 38 singleton waves contribute 2.42 s of coordinator time.
  The 750-module split CLI schedules 126 waves and launches 351 worker
  processes. Its 28 singleton waves contribute 2.13 s. The slowest wave in
  all six cold runs checks one module,
  `linked_compile_wasi_module_linked_impl_with_split_grants.vibe`, in
  0.35–0.37 s. The reconstructed compiler module plan matches the observed
  wave widths in every cold run.
- The compiler closure publishes 2.91 MiB of exported environments and
  2.34 MiB of lowering rows before framing. The split CLI publishes
  5.41 MiB and 4.56 MiB. The current checked product repeats the environment
  verbatim under its own version header, and replay stores both copies.
  These totals count serialized output. A live-set measurement also needs
  the input copies, decoded heap and overlapping lifetimes.
- Subtracting each sample's entire cold coordinator duration leaves medians
  of 12.06 s for the compiler and 23.76 s for the CLI. A 5% win over ordinary
  cold needs 11.20 s and 22.40 s respectively. Under the existing pipeline,
  the 5% target also requires reducing time outside the coordinator.

For #3484, compare fresh processes against fresh Stores sharing a compiled
Wasmtime module with the same job inputs and checked outputs. Measure that
change within the existing schedule before testing completion-driven
dispatch. For #2507, measure passing the existing environment and lowering
rows directly to the filesystem compiler as it walks the graph. That
experiment should account for the discovery and publication time that
persists even with an entirely warm checker cache.

## Protocol

- Main `f8c6aeda0` and its exact-tree PR head `ce1da1cbb` were verified
  equal with `git diff --exit-code`. Stage2 and stage3 built from that
  tree are byte-identical. The compiler SHA-256 is
  `7a20ec9e72f1c75e9ed91512fe19aa70da1d2d4dc267c7c74416ba17cddaf042`.
  The worker and coordinator images were built from main with that stage2.
- Linux WSL2, AMD Ryzen 7 7700 (16 logical CPUs), Node v24.7.0. Both builds
  invoke the same stage2 Node host runner for final compilation, using the
  raw ABI and target RC1. The worker uses the default bump heap and the
  TaskGroup coordinator uses RC.
- The compiler closure is `lib/@vibe/compiler/tests/codegen_lexer_test.vibe`
  (`__no_entry__`). The CLI is `lib/@vibe/cli/entry.vibe` (`cli_main`). These
  are filesystem builds, separate from the merged-source RC0 bootstrap.
- Three rounds alternate lane order. Each corpus, lane and round starts
  with a fresh Vibe build cache. Its warm build reuses only that cache.
  The native Wasmtime code cache is shared and was exercised by an
  untimed smoke run. Linked output, AST and body caches are off.
- RSS is the maximum summed process-tree RSS sampled every 20 ms. Shared
  pages count once per process and peaks shorter than the sample interval
  may be missed. The reported guest frontier comes from the final compiler
  alone.
- Telemetry verifies that ordinary cold checks every planned module, the
  TaskGroup cold frontend checks every module in workers and the TaskGroup
  warm frontend replays every product. Final TaskGroup compiles perform
  zero checks. Every sample emits byte-identical Wasm within its corpus.

The [raw samples](../../../bench/perf/analysis/checker-taskgroup-boundary-2026-11-15.json)
retain image hashes, per-build timings and memory, compiler telemetry and the
TaskGroup wave and product summaries.

The matching images pass `scripts/test_parallel_frontend_warm.sh` with
TaskGroup and replay enabled and `scripts/test_taskgroup_public_replay.py`.
Those tests exercise the installed launcher, runtime outputs, diagnostics and
cache invalidation alongside the filesystem benchmark.

## Reproduce

Build a matching stage2 and worker images from the checkout under test.

```sh
bash scripts/ensure_generated.sh
bash scripts/generations.sh build --out-dir _build/checker-boundary-seed
compiler="$PWD/_build/checker-boundary-seed/stage2.wasm"
images="$PWD/_build/checker-boundary-images"
bash scripts/build_taskgroup_checker.sh "$compiler" "$images"
```

Use a fresh cache directory per lane and corpus. Run one cold build followed
by the same warm build in that cache, removing the output between invocations.
Alternate the two lane pairs across rounds. Replace `src` and `entry` with
the CLI input and entry function to repeat the second corpus. For aggregate
RSS, run each command under the `measure` function in
`bench/perf/selfbuild_baseline.py`, which samples descendants by parent PID.

```sh
export VIBE_LIB="$PWD/lib" VIBE_PREOPEN_DIR="$PWD" VIBE_IMPORT_ABI=raw
export VIBE_RC=1 VIBE_UNSTABLE=1 VIBE_WASM_NAMES=0 VIBE_WASM_MEMORY_STATS=1
export VIBE_LINKED_OUTPUT_MEMO=off VIBE_CODEGEN_BODY_CACHE=off
export VIBE_CHECKED_MODULE_CACHE=off VIBE_EXPERIMENTAL_AST_CACHE=0
src=lib/@vibe/compiler/tests/codegen_lexer_test.vibe
entry=__no_entry__
ordinary_cache="$(mktemp -d)"
taskgroup_cache="$(mktemp -d)"

VIBE_BUILD_CACHE_DIR="$ordinary_cache" VIBE_FS_COMPILE=1 \
  VIBE_RUNNER_EXIT_WITH_RESULT=1 VIBE_INCREMENTAL_TELEMETRY_OUT="$PWD/ordinary.json" \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main \
    "$compiler" "$src" "$PWD/ordinary.wasm" "$entry"

VIBE_BUILD_CACHE_DIR="$taskgroup_cache" VIBE_TASKGROUP_JOB_CACHE=1 \
  VIBE_TASKGROUP_TRACE_OUT="$PWD/waves.json" VIBE_INCREMENTAL_TELEMETRY_OUT="$PWD/taskgroup.json" \
  bash scripts/build_taskgroup_project.sh \
    "$compiler" "$src" "$PWD/taskgroup.wasm" "$entry" 4 "$images"

cmp ordinary.wasm taskgroup.wasm
```

## Initial direct checked-product handoff

`VIBE_TASKGROUP_DIRECT=1` selects the direct route for `vibe build --jobs 4`
and `scripts/build_taskgroup_project.sh`. The host stages one combined
environment/lowering product per module in its private work directory.
The final compiler reads each product at the corresponding step of its
own import walk. It checks the current typing fingerprint and canonical
encoding before hydrating the ordinary environment and lowering memos.
Missing, malformed and stale products stop the build. Projects with
diagnosed modules retain the established diagnostic route.

Three alternating cold/warm pairs per workload used the same candidate
stage2, checker and coordinator images in both lanes. Both lanes used
four process workers and successful-product replay. Cache isolation,
corpora, target RC1 and process-tree RSS sampling match the protocol
above. The measured command is the filesystem build helper. The
installed launcher was validated separately.

| Corpus | Cache | Wall, published → direct | Aggregate peak RSS, published → direct |
|---|---|---:|---:|
| Compiler closure | Cold | 19.53 → 19.21 s (−1.6%) | 920 → 1,092 MiB (+18.7%) |
| Compiler closure | Warm | 8.81 → 8.32 s (−5.5%) | 920 → 1,092 MiB (+18.7%) |
| Split CLI | Cold | 35.48 → 34.91 s (−1.6%) | 1,768 → 2,033 MiB (+14.9%) |
| Split CLI | Warm | 17.32 → 16.55 s (−4.5%) | 1,751 → 1,995 MiB (+13.9%) |

The separate publisher invocation disappears. The final compiler's
allocator frontier rises by 13 MiB for the compiler closure and 23 MiB
for the split CLI, where it now validates canonical products. In this first version, the Node frontend waited for the final compiler's
acceptance receipt before caching fresh replay products. The frontend
remained live during final compilation and peaked at 160–189 MiB for the
compiler closure and 219–274 MiB for the split CLI. Those process peaks
are separate observations from the aggregate peak.

All 24 Wasm outputs matched byte-for-byte within each corpus. Final compiler
telemetry recorded zero rechecks. Cold ran every worker job and warm
replayed every product with zero workers. The candidate stage2/stage3
fixpoint and the checkout and installed public replay tests passed for
both routes, including direct rejection of missing, malformed and stale
products.

To reproduce, run the TaskGroup build command above with
`VIBE_TASKGROUP_DIRECT=0` and `VIBE_TASKGROUP_DIRECT=1` in separate caches
on the same images. Inspect `handoff` in `VIBE_TASKGROUP_TRACE_OUT` and the
final compiler's reuse counters. Whole wall time includes final validation
and replay writes. In the trace, the direct publication span measures
staging and image verification, while the persistent publication span also
includes the auxiliary compiler and cold replay writes. The
[24 direct-comparison samples](../../../bench/perf/analysis/checker-taskgroup-direct-2026-11-15.json)
retain hashes, counters, per-build wall times and peaks.

## Exit the frontend before final compilation

The launcher now waits for the Node frontend to exit after staging the
checked products, then starts the final compiler. A separate replay commit
runs after a successful final build with an acceptance receipt and fresh
products. The commit uses the captured cache keys and verifies the producer
images again. A fully warm build needs no replay commit process.

The follow-up is a second three-round series on the same host, corpora,
stage2, worker and coordinator images. Process samples show the frontend
exiting before the final compiler started in all 12 runs. Outputs match
both previous lanes byte for byte and final compiler rechecks remain zero.

| Corpus | Cache | Wall, first direct → sequential | Peak RSS, first direct → sequential | Earlier published RSS |
|---|---|---:|---:|---:|
| Compiler closure | Cold | 19.21 → 19.32 s | 1,092 → 945 MiB (−13.4%) | 920 MiB |
| Compiler closure | Warm | 8.32 → 8.31 s | 1,092 → 927 MiB (−15.0%) | 920 MiB |
| Split CLI | Cold | 34.91 → 34.97 s | 2,033 → 1,791 MiB (−11.9%) | 1,768 MiB |
| Split CLI | Warm | 16.55 → 16.46 s | 1,995 → 1,780 MiB (−10.8%) | 1,751 MiB |

The final compiler's guest frontier changes by less than 0.1 MiB between
the two direct implementations. Peak RSS after exiting the frontend comes
within 8–29 MiB of the published route, with the remaining canonical
product validation in the final compiler. The
[12 follow-up samples](../../../bench/perf/analysis/checker-taskgroup-direct-lifetime-2026-11-15.json)
include the sampled phase boundaries and the older comparison medians.

## Native checker threads with the existing schedule

`VIBE_CHECKER_WORKER_BACKEND=thread` selects the experimental native thread
transport. The coordinator loads the compiled checker module once per
dependency wave. Each worker batch owns a fresh Wasmtime Store, Instance,
heap and snapshot of the worker environment. The existing four-slot limit,
16 jobs per batch, input files, product validation and wave order apply to
both transports. The launcher still starts one coordinator process for
each wave with a miss.

Medians of three alternating cold/warm pairs per corpus and transport,
with the same fixed-point compiler, runner and checked-product handoff in
both lanes. Each pair has its own Vibe cache. Both transports used the
same native code cache after priming it with an untimed smoke run.
Collection used the process-tree sampling protocol above.

| Corpus | Cache | Wall, process → thread | Aggregate peak RSS, process → thread |
|---|---|---:|---:|
| Compiler closure | Cold | 19.35 → 20.13 s (+4.1%) | 940 → 936 MiB |
| Compiler closure | Warm | 8.35 → 8.35 s | 928 → 940 MiB |
| Split CLI | Cold | 35.04 → 36.42 s (+4.0%) | 1,787 → 1,792 MiB |
| Split CLI | Warm | 16.71 → 16.71 s | 1,780 → 1,778 MiB |

Cold coordinator time rose from 7.62 to 8.41 s for the compiler and from
11.90 to 13.35 s for the CLI. Both monotonic clocks give the same cold
direction and relative change. Warm replay started zero worker batches.
Cold used the same module schedule in both lanes, with 97 waves and 241
batches for the compiler and 126 waves and 351 batches for the CLI. All
24 outputs match byte-for-byte within each corpus, with zero rechecks by
the final compiler. The last CLI pair was repeated after repository gate
planning overlapped the original run.

The WIT tests match serial products and check bounded batches, CFG
isolation and failed-batch cancellation and joining. The two-worker
case spent 1.82 CPU seconds across batches with about 1 second of common
overlap. The four-worker case spent 3.88 CPU seconds with about
1.05 seconds of common overlap. Each worker ran on a distinct OS thread
within one process.

The cold comparisons show no speedup with the current wave schedule.
The coordinator still pays for startup at every wave, still waits for
the whole wave to finish, and still instantiates fresh workers per batch.
The timing here measures their combined cost. To measure persistent
coordinator reuse, keep the current schedule while loading the checker
module once for the build. That supplies the comparison for dispatching
each dependent as soon as its own prerequisites finish.

To reproduce, use the TaskGroup build command above with
`VIBE_TASKGROUP_DIRECT=1`. Alternate `VIBE_CHECKER_WORKER_BACKEND=process`
and `VIBE_CHECKER_WORKER_BACKEND=thread` with separate cold/warm cache
directories and a common warm `VIBE_NATIVE_CACHE_DIR`. The
[24 native-thread comparison samples](../../../bench/perf/analysis/checker-taskgroup-native-threads-2026-11-15.json)
record the artifact hashes, checker counters and coordinator time by wave.

## Reusing the checker coordinator for the build

`VIBE_CHECKER_COORDINATOR=session` uses one coordinator process for a
build with checker misses. Set `VIBE_CHECKER_WORKER_BACKEND=thread` to
select the threaded checker. The process starts on the first miss wave
and loads both the coordinator component and the checker module once.
Each request gets fresh wave queues and a coordinator Store. Each
worker batch still gets its own Store and guest heap. The frontend
closes the coordinator and waits for exit before publishing checked
products or launching the final compiler.

Both lanes use four native worker slots, a 16-job batch limit, direct
checked-product handoff and the same wave schedule. They use the same
runner and images, a fresh Vibe cache for each of three alternating
cold/warm pairs per workload, and an already exercised native code
cache. The measurement covers the complete filesystem build, including
coordinator shutdown. RSS sums the process tree every 20 ms.

| Corpus | Cache | Wall, wave → session | Aggregate peak RSS, wave → session |
|---|---|---:|---:|
| Compiler closure | Cold | 20.50 → 16.44 s (−19.8%) | 942 → 948 MiB |
| Compiler closure | Warm | 8.47 → 8.51 s (+0.5%) | 915 → 947 MiB |
| Split CLI | Cold | 36.46 → 31.21 s (−14.4%) | 1,791 → 1,788 MiB |
| Split CLI | Warm | 16.66 → 16.63 s (−0.1%) | 1,784 → 1,772 MiB |

Cold coordinator time, including session shutdown, fell from 8.67 to
4.74 s for the compiler and from 13.65 to 8.37 s for the CLI. Both
monotonic clocks give the same relative changes. Cold coordinator starts
fell from 97 to 1 for the compiler and from 126 to 1 for the CLI, with
the same 241 and 351 worker batches. In all six cold session runs,
process samples show the coordinator exiting before the final compiler
started.

Compiler warm peak RSS was 32 MiB higher in the session lane. The sampled
final compiler process accounts for the observed difference. Its Wasm
heap frontier is identical across all six warm runs, and both lanes skip
coordinator startup. The cause of the final process RSS variation remains
unverified.

The warm replay path starts no workers or coordinator. The 24 outputs
match byte-for-byte within each workload and the final compiler performs
zero rechecks. The WIT oracle checks consecutive waves in the same
process, fresh wave inputs, cancellation of a failed wave's sibling
and rejection of subsequent requests after the failure. The public
launcher tests cover both the checkout and installed toolchain,
including cache replay and diagnostics.

To reproduce, use the TaskGroup build command above with
`VIBE_TASKGROUP_DIRECT=1 VIBE_CHECKER_WORKER_BACKEND=thread`. Alternate
`VIBE_CHECKER_COORDINATOR=wave` and `VIBE_CHECKER_COORDINATOR=session`
with separate Vibe caches and a common primed `VIBE_NATIVE_CACHE_DIR`.
The [24 coordinator comparison samples](../../../bench/perf/analysis/checker-taskgroup-coordinator-session-2026-11-15.json)
record the artifact hashes, process counts, timings and peak RSS.

## Dispatch as dependencies finish

`VIBE_CHECKER_SCHEDULE=ready` selects completion-driven dispatch with
`VIBE_CHECKER_COORDINATOR=session VIBE_CHECKER_WORKER_BACKEND=thread`.
The frontend indexes each module's remaining dependencies and consumers.
A checked product is eligible to unblock consumers after the worker
batch has joined and the frontend validates the product. Replay hits
also unblock their consumers. A diagnosed dependency blocks its
transitive consumers while independent checks can finish. The launcher
still publishes the final products in canonical module order.

One Vibe TaskGroup owns the session's slot loops. Up to four native worker
batches, each with at most 16 modules and its own Store, can be active.
Slots accept the next bounded batch while other slots continue checking.
The frontend closes input and waits for the coordinator before final
compilation. The WIT oracle keeps a real slow batch active during a
worker trap and checks that the slow batch leaves no committed outcome.
A launcher control starts a consumer of a fast module while an independent
slow module is still running and compares its final Wasm to wave dispatch.

Both lanes use the same compiler, worker, coordinator and native runner
with four slots and direct checked-product handoff. Three alternating
cold/warm pairs per workload use isolated Vibe caches and a common
primed native code cache. Batch shapes can change as modules become ready.
The scheduler interval includes job preparation, worker waits, product
reads and session shutdown. Individual batch durations can overlap.

| Corpus | Cache | Wall, waves → ready | Aggregate peak RSS, waves → ready |
|---|---|---:|---:|
| Compiler closure | Cold | 16.43 → 14.70 s (−10.5%) | 938 → 928 MiB |
| Compiler closure | Warm | 8.36 → 8.29 s (−0.7%) | 929 → 936 MiB |
| Split CLI | Cold | 31.40 → 26.48 s (−15.7%) | 1,778 → 1,789 MiB |
| Split CLI | Warm | 16.89 → 16.55 s (−2.0%) | 1,794 → 1,780 MiB |

Both monotonic clocks show the same cold changes. The cold dispatch
interval fell from 6.69 to 4.99 s for the compiler and from 12.15 to
7.39 s for the split CLI, with less than 1% change in total child CPU
time in both workloads. Ready dispatch used 236–243 batches for the
compiler and 361–367 for the CLI. The wave control used 241 and 351.
Both started one coordinator per cold build and zero on warm replay.
All 24 outputs matched within each workload, with zero final compiler
rechecks. Aggregate peak RSS moved by no more than 11 MiB on cold runs
when comparing the lane medians.

To reproduce, run the TaskGroup build command above with
`VIBE_TASKGROUP_DIRECT=1 VIBE_CHECKER_WORKER_BACKEND=thread VIBE_CHECKER_COORDINATOR=session`.
Alternate `VIBE_CHECKER_SCHEDULE=waves` and `VIBE_CHECKER_SCHEDULE=ready` with
separate cold/warm cache directories. The
[24 ready-dispatch comparison samples](../../../bench/perf/analysis/checker-taskgroup-ready-dispatch-2026-11-15.json)
contain runner and image digests, execution counters, wall times and RSS.

## Flat RC0 bootstrap stage3

The production compiler generation uses one trusted, generated flat source
with `VIBE_RC=0`. Passing that source to `VIBE_MODULE_PLAN=1` refused its
reserved `@vibe/compiler/internal/iterator_boundary` import. The
filesystem plan accepts the split CLI and finds 750 modules there. That
plan describes a different input and emission path.

The flat bump compiler and the function-phase preparation now share the
same source checking, desugaring and linked-module preparation. The
function coordinator uses the existing bounded TaskGroup process workers,
with the bump target carried in the validated context. The preparation
Store exits before workers begin. The fresh finisher reads only worker
products and owned assembly state.

`VIBE_GENERATION_STAGE3_FUNCTION_JOBS=4 bash scripts/generations.sh build --stage3`
selects the experiment for the native stage2 to stage3 hop. It builds
producer-bound helper images, requires byte identity with stage2 before
publishing stage3 and records the worker count in the generation receipt.
The opt-in accepts 1, 2 or 4 jobs on the trusted flat RC0 `cli_main` lane.

### Fixed-input stage measurement

Three fresh process runs per mode in rotating order used the actual
flat source and fixed-point stage2 from the preceding compiler generation.
The mode labeled native serial uses the same phase image and runner with
`VIBE_LOWERING_MODE=serial`. The native code cache was primed, persistent
build caches were disabled, and helper production is outside this table.
All nine outputs match the selected stage2 byte for byte.

| Mode | Monotonic wall, median | Aggregate peak RSS, median |
|---|---:|---:|
| Ordinary Node compiler | 32.07 s | 3,544 MiB |
| Native serial control | 33.31 s | 3,405 MiB |
| Four function workers | 33.47 s | 3,394 MiB |

Median native preparation was 32.19 s, followed by 0.56 s of worker
execution and 0.46 s of finalization. The worker plan covered 13,335
functions and 354 lambdas. The preparation guest ended at 3.39 GiB of
bump heap. Most of the RSS difference from the Node compiler already
appears in the native serial control.

### Complete compiler generation

One complete run per mode in separate output directories reproduced
stage2 == stage3. All four artifacts matched each other. The worker run
recorded four completed ranges and zero finisher source reads.

| Mode | Full monotonic wall | Peak RSS | Sampled stage3 compilation |
|---|---:|---:|---:|
| Ordinary generation | 184.18 s | 3,611 MiB | 31.93 s |
| Four stage3 function workers | 163.60 s | 3,607 MiB | 62.16 s |

Stage3 in the worker run includes 26.62 s to produce the matching
helper images. The earlier flat-source generator was observed for
117.22 s in the ordinary run and 66.15 s in the worker run. That
difference accounts for the shorter observed total. The one-shot full
generation pair establishes artifact parity and the cost of the tested
integration. Repeated fixed-input stage runs are the basis for the
wall/RSS comparison above.

The [measurement samples](../../../bench/perf/analysis/rc0-flat-bootstrap-function-workers-2026-11-15.json)
include per-run timings, digests, aggregate RSS and phase receipts.
