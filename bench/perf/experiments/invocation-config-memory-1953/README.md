# Invocation-scoped in-memory checking (#1953)

Baseline: `f78dfb67de00217914d03d6af332f00f6de8dda4` (including merged #3854). This slice carries one immutable `TargetCfg` through virtual header parsing, dependency planning, raw module checking, semantic-use observations and warm fingerprints. The compatibility entries capture their legacy flag values once and delegate to these data kernels. `check_sources_memory_configured` captures `Config` once, owns its DB, checks the supplied virtual files and returns `Unit`; it refuses a missing entry while accepting supplied empty text. No new `Fs` authority is acquired.

CLI orchestration, merge/codegen, final artifacts, workers and other configuration/authority families remain later slices. Mutable cache contents still need ownership or synchronization for arbitrary concurrent calls. This is not completion of #1953.

Runs were serial and isolated from compiler/test jobs on WSL/Linux, Node 24.7.0 with the local exnref shim; RC=0 and raw ABI. Each table cell is a median of three fresh Node processes in AB/BA/AB order. Both SDK inputs were regenerated from their respective frozen production sources.

## Resident memory checking

The common [workload](memory_check.vibe) builds a chain of 128 virtual modules, performs one cold check and then 128 warm checks of the same resident DB. Every process checks the cold evaluation/parse counts, verifies unchanged warm parse/evaluation counts and compares the root environment before and after. The environment identity also agrees across compilers. Four additional baseline A/A controls verify identical allocation and environment results for each flag set. The 12 A/B samples and four A/A controls use one literal compile root and one literal runtime image path, without persistent disk caches.

This workload uses the compatibility `db_typecheck` entry shared by both revisions; the candidate delegates to the scoped memory kernel. It measures that kernel migration, not `Config` handler-dispatch overhead. Graph construction, process startup and final rendering are outside the guest regions. Warm values below are totals divided by 128; the measured region includes the per-iteration reuse assertion. Whole-process wall times remain in the raw receipts.

| Flags | Region | Allocated baseline → candidate | Change | Wall baseline → candidate |
| --- | --- | --- | --- | --- |
| default | cold | 7,693,224 → 7,628,728 B | -0.8383% | 51,739.00 → 51,657.00 µs |
| default | warm/check | 328,496 → 307,056 B | -6.5267% | 1,447.32 → 1,420.78 µs |
| alpha | cold | 7,884,352 → 7,794,248 B | -1.1428% | 53,010.00 → 50,353.00 µs |
| alpha | warm/check | 369,160 → 339,472 B | -8.0420% | 1,533.21 → 1,475.49 µs |

`Profiler::heap_bytes()` deltas measure regional cumulative bump allocation, excluding the static heap base. They are not live heap, RSS or the CI selfcompile peak-memory metric. The short wall measurements are recorded, but do not establish a speed improvement.

## Filesystem integration

The standard compiler KPI and CLI corpora each have cold/warm samples with a fresh isolated cache per pair. Both lanes use the same literal root, compiler, output and cache paths. The own-source protocol builds each compiler’s own checkout with AST caching off. The same-source protocol builds the candidate source with AST caching on using both compilers. All 24 same-source outputs are byte-identical; every own-source lane is stable across repetitions. These protocols total 48 samples.

| Protocol | Corpus | Cache | heap_ptr baseline → candidate | Change | Wall baseline → candidate |
| --- | --- | --- | --- | --- | --- |
| Own source, AST off | kpi | cold | 1,163,434,304 → 1,163,436,008 B | +0.0001% | 7.938 → 7.928 s |
| Own source, AST off | kpi | warm | 654,653,256 → 654,655,080 B | +0.0003% | 4.734 → 4.707 s |
| Own source, AST off | cli | cold | 2,565,065,720 → 2,566,019,040 B | +0.0372% | 17.697 → 17.855 s |
| Own source, AST off | cli | warm | 1,441,602,536 → 1,441,925,112 B | +0.0224% | 11.209 → 11.195 s |
| Same candidate source, AST on | kpi | cold | 1,193,544,904 → 1,193,546,552 B | +0.0001% | 7.943 → 8.026 s |
| Same candidate source, AST on | kpi | warm | 628,007,392 → 628,009,200 B | +0.0003% | 4.862 → 4.857 s |
| Same candidate source, AST on | cli | cold | 2,624,301,160 → 2,624,291,352 B | -0.0004% | 17.991 → 17.941 s |
| Same candidate source, AST on | cli | warm | 1,404,296,192 → 1,404,300,792 B | +0.0003% | 11.724 → 11.695 s |

Here `heap_ptr` includes the static heap base and cumulative bump allocation, unlike the regional deltas above. It is not RSS or CI peak memory. Own-source measurements include additional compiler source and can produce different images across revisions. No speed improvement is claimed.

Compiler artifact: 5,652,240 → 5,652,240 bytes. Candidate stage2 and stage3 are identical (`af042bbb3b14c5247aa45f380cd26de8c857a4833cd278266f2ba03582c5ea4d`); both validate as Wasm. Intermediate candidates and pilot measurements are excluded.

Raw receipts, measured index trees, compiler/image hashes and every sample are retained in [results.json](results.json). Report-only additions after measurement do not change the production-input fingerprint.

## Correctness and reproduction

The exact candidate passed 163 harness tests with AST caching off, 50 with it on and 39 with reference counting and AST caching on. The new memory suite contains six source cases; harness totals include generated/imported test exports and are not counts of unique source cases. Tests cover scoped virtual reexports, Alpha→Beta→Alpha resident reset, unchanged warm reuse, source-bound semantic identities, failed inner checks, one Config read despite nested checks, unchanged ambient compatibility behavior, raw diagnostic byte identity and missing/empty entries. The bootstrap gate also runs this suite against its own freshly built stage2.

Nine injected faults each compile successfully, pass Wasm validation, and then fail at runtime: ambient header parsing, ambient resident identity, ambient warm fingerprints, ambient raw checker configuration, skipped Config capture, a second Config read, rendered raw diagnostics, a coordinator routed through the legacy raw checker, and a missing-entry guard disabled. Every mutated source was restored byte-for-byte. The raw receipt records compile/validation/runtime exit codes, source/image hashes and failure excerpts.

```sh
python3 bench/perf/experiments/invocation-config-memory-1953/measure_memory.py \
  BASE_ROOT CANDIDATE_ROOT BASE_STAGE2 CANDIDATE_STAGE2 OUTPUT_MEMORY
python3 bench/perf/experiments/invocation-config-1953/measure_own_source.py \
  BASE_ROOT CANDIDATE_ROOT BASE_STAGE2 CANDIDATE_STAGE2 OUTPUT_DEFAULT
python3 bench/perf/experiments/invocation-config-1953/measure_own_source.py \
  BASE_ROOT CANDIDATE_ROOT BASE_STAGE2 CANDIDATE_STAGE2 OUTPUT_AST \
  --same-source --ast-cache 1
```

Stage candidate inputs before measuring; output directories must not exist. Run on an idle machine, regenerate each checkout’s SDK inputs, and keep all samples serial. See the [memory driver](measure_memory.py) and [filesystem driver](../invocation-config-1953/measure_own_source.py).
