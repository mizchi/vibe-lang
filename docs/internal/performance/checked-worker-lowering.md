# Checked worker lowering: duplicate-check measurement

Measured on 2026-10-03 in WSL with Node 24.7.0 (exnref enabled), Rust
1.98.1 and Wasmtime 47.0.2. This change repairs the existing Node pre-warm
prototype's checked-product transport. It does not implement a TaskGroup CPU
backend or make the default Vibe CLI build parallel.

The old publisher preserved the public environment but wrote a module-cache
record with `lowering\tmissing`. Consequently, a final compiler build rechecked
all 558 modules after workers had already checked them; the CLI build repeated
609 checks. This happened on a warm cache too. The new worker exports the actual
check-derived v8 lowering table with its computed fingerprint. Publication
validates the canonical environment, product identity and complete lowering
section before preserving the v11 record. No cache codec version changes.
Legacy two-column publication remains accepted with missing lowering and must
still recheck; it cannot masquerade as a fully checked product.

## Controlled whole-build comparison

Each cell below is the median of three complete builds. A/B order and jobs
order alternate between rounds. Each variant and round has an isolated cold
cache followed by a warm build. Both compilers build the *same* immutable
5,434-file input snapshot, including the five generated compiler source files.
Runtime, compiler, output and cache paths have equal lengths between variants.
Input, script and compiler hashes are checked before and after every build.
No other heavy work ran during this measurement; release-check started after
all 48 measured builds completed. Every output hash agrees within its workload.

Wall time includes discovery, worker execution, publication and final compile.
Guards are outside the timed region. `VIBE_IMPORT_ABI=raw`, `VIBE_RC=1`, the
experimental AST cache, checked-module artifact cache and codegen body cache
are off. Normal persistent module environments are enabled. Jobs=1 runs only
the serial FS compile; jobs=4 runs the pre-warm prototype plus that compile.
All final compile processes are fresh. Worker JIT/startup costs are included.

| Workload | Jobs | Cache | Before (s) | After (s) | Change |
| --- | ---: | --- | ---: | ---: | ---: |
| compiler | 1 | cold | 15.131 | 14.802 | -2.18% |
| compiler | 1 | warm | 11.520 | 11.361 | -1.38% |
| compiler | 4 | cold | 19.499 | 17.201 | -11.78% |
| compiler | 4 | warm | 18.452 | 16.307 | -11.63% |
| CLI | 1 | cold | 19.779 | 19.407 | -1.88% |
| CLI | 1 | warm | 14.040 | 13.766 | -1.95% |
| CLI | 4 | cold | 23.343 | 21.136 | -9.45% |
| CLI | 4 | warm | 22.162 | 19.969 | -9.90% |

The small serial wall changes are not evidence of a serial speedup. The
prototype remains slower than ordinary serial compilation: candidate jobs=4
is about 16% slower cold and 43–45% slower warm. Workers still check every
module on a warm pre-warm run. Separate worker artifacts, actual TaskGroup
CPU workers, warm-hit eligibility, transport cost and total worker memory are
next steps, not outcomes claimed here.

Compiler-owned `checker_executions` is the final compiler's observed work:

| Workload | Jobs | Cold, before → after | Warm, before → after |
| --- | ---: | ---: | ---: |
| compiler | 1 | 558 → 558 | 0 → 0 |
| compiler | 4 | 558 → 0 | 558 → 0 |
| CLI | 1 | 609 → 609 | 0 → 0 |
| CLI | 4 | 609 → 0 | 609 → 0 |

## Memory and scope

Host RSS is the 25 ms sampled sum of Linux process-group `VmRSS`, including
coordinator and worker processes. It can double-count shared pages and miss
short peaks. These are aggregate process observations, not a live-heap or
allocation-volume metric. The final guest heap is the final compile's bump
high-water mark; worker guest heaps are **not** measured or included in it.
No total guest-memory reduction is claimed.

| Workload, jobs=4 | Cache | Aggregate RSS before → after (KiB) | Change | Final guest heap before → after (bytes) |
| --- | --- | ---: | ---: | ---: |
| compiler | cold | 2,160,052 → 2,229,236 | **+3.20%** | 1,903,333,416 → 1,271,121,024 |
| compiler | warm | 2,170,232 → 2,224,988 | **+2.52%** | 1,812,886,392 → 1,180,185,448 |
| CLI | cold | 2,770,876 → 2,701,428 | -2.51% | 3,258,406,984 → 2,577,030,432 |
| CLI | warm | 2,854,144 → 2,635,368 | -7.67% | 3,419,953,888 → 2,738,031,952 |

Serial guest-heap changes are only 3,888–7,480 bytes; there is no material
serial memory regression in this run. Compiler aggregate RSS **does rise**,
despite eliminating duplicate checks. Retaining/transporting real products
has a cost and the prototype remains opt-in. This is not evidence for changing
the default build path. Child user/system CPU totals are retained per phase;
there is no named-function CPU profile or CPU hotspot claim in this report.

## Receipts and reproduction

- Parent input tree: `ecccc14a1bc5f973955b129dd824cf7a5c9f1d27`,
  commit `356adfd78b3846a52adb405af85e2232a0ebfd4a`, tree-identical to merged
  main `9869c666738091a971b405dca2967352d355cfd6`.
- Parent compiler: `87df48a987017f4e09edb5cb172f2e00a3db5bb6b4ae640545d7df869d5a3087`.
- Candidate compiler, stage2 = stage3:
  `578e8da6339039ae59a8287287fda01fd3f70296ea3bfc1bf4728aef7025fe12`.
- Input receipt SHA-256:
  `157769eefd514d3aeba298899ae461c769fd28d30f37e39ef395acb89db231a4`.
- Original raw JSON SHA-256:
  `5f8fb0500d7bfaeffa7202a981cfcd9cb16ba9c11c8ddec8b9595a893a0a83a5`.
- [Raw results](checked-worker-lowering.samples.ndjson) preserve that JSON's
  metadata and all 48 complete sample objects, one JSON object per line.
  The first line is metadata; the rest retain observed phase times, CPU,
  aggregate RSS, compiler telemetry, guest heap and emitted Wasm hash.
- [Median summary](checked-worker-lowering.summary.json) includes the serial
  memory controls as well as jobs=4.

Build the parent and candidate with `scripts/generations.sh` from the pinned
seed and verify stage2/stage3 equality. Freeze the parent tracked source tree
and its generated source files *before* generating the candidate. Use equal
length paths for copies of both compiler images and both script runtimes.
For each round, workload and variant, allocate a fresh external cache directory
and use it twice (cold then warm). Remove inherited VIBE selectors; set only
the selectors above and explicit input/library/home/cache roots. Workloads are
`lib/@vibe/compiler/cli_adapter.vibe` / `cli_main` and
`lib/@vibe/cli/main.vibex` / `main`.

For jobs=4, first run `scripts/parallel_frontend_warm.mjs` with positional
arguments `compiler-wasm entry-path 4 immutable-project-root runner-script`.
For both jobs values, run `scripts/run_wasm_vibe_host_runner.sh --invoke
cli_main compiler-wasm entry-path output-wasm entry-function` with
`VIBE_FS_COMPILE=1`, `VIBE_WASM_MEMORY_STATS=1` and an isolated
`VIBE_INCREMENTAL_TELEMETRY_OUT`. Parse telemetry using
`scripts/edit_cycle_kpi.mjs`'s strict schema reader. Require the exact checker
counts above and output SHA equality. Time the combined pre-warm/final compile
and each phase with a monotonic clock, sum process-group RSS every 25 ms and
retain reaped-child OS CPU usage. Repeat three alternating A/B rounds on an
idle host; inspect raw samples before reporting medians.

## Correctness and sign-off

- `pkf run release-check`: **122 tasks, 10 cached, 112 ran, 43m47s**;
  staged implementation hashes unchanged throughout. Includes a fresh
  seed→stage3 fixpoint and production compile/run checks.
- AST-required pre-commit review lint passed on the implementation.
- Real module-job oracle validates actual nonempty Double lowering and 12
  corrupted-product controls. The old compiler fails the new positive case.
- Real frontend oracle covers jobs=1/2/4, cold/warm, a diamond and reexports,
  Bool/Double/Array Show, typed structural equality, actual execution,
  same-interface source edits and exact diagnostic parity. Pre-warmed final
  compiles execute zero checker calls while producing byte-identical Wasm.
- Host/project/selfhost scheduler tests: 17 passed. Products use actual
  checked fingerprints and contain v11/v8 lowering, never a fabricated empty
  table. All 48 controlled compiler/CLI builds pass output and source guards.
