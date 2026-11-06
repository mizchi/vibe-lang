# Invocation-scoped source merging (#1953)

Baseline: `1439607a56b08bcf72532fd8460f576df31cbf39` (including merged #3869). This slice carries one immutable `TargetCfg` through shared source merging and the ordinary/grouped `TypeDb` source mergers. Compatibility entries capture the legacy flags once. The plain shared merge needs only `Exception`; its Config boundary adds only `Config` and returns source text. No new `Fs` authority is acquired.

The DB validates its configuration before any resident-product lookup. Whole-program merge fingerprints bind non-empty flags, even when selected text is identical or groups are empty; empty flags keep their old fingerprint bytes. Per-group products keep their input-only key recipe inside that configuration-validated DB, avoiding a redundant flag hash for each group. Warm group reuse, rename metadata and overlap refusal stay on their existing paths.

Typed lowering, global rename/location metadata, module/final artifacts, codegen orchestration, CLI, workers and other configuration/authority families remain later work. No configured typed-codegen entry is exposed here, and this is not a claim that the entire compiler is reentrant.

Runs were serial and isolated from compiler/test jobs on WSL/Linux; Node 24.7.0 with the local exnref shim, raw ABI, RC=0. Both SDK inputs were generated from their respective frozen production snapshots. Each table cell is a median of three fresh Node processes in AB/BA/AB order.

## Shared and resident merge regions

The common [workload](merge_sources.vibe) has 128 virtual modules plus an entry, one source per group (129 groups). It measures the common compatibility APIs, so both revisions compile the same workload against their own runtime. Shared merges assert exact statement counts and identical printed text; resident DB merges assert 130 cold merge publications, unchanged warm merge counts, stable fingerprints and identical text. Both compilers agree on the output identity per case. Eight A/A controls additionally verify deterministic allocations and output identities. All 24 A/B samples use the same literal compile root and runtime image path, with no persistent runtime disk cache.

Each process performs one cold merge and 16 warm merges. Graph setup and benchmark output rendering are outside the guest regions; per-iteration assertions are included. The DB API’s own source serialization remains inside its measured calls, while the shared AST API’s text comparison is outside. Warm values below divide each measured total by 16. Whole-process wall times remain in the raw receipts. This measures kernel migration and resident reuse, not Config handler-dispatch overhead.

| API / flags | Region | Allocated baseline → candidate | Change | Wall baseline → candidate |
| --- | --- | --- | --- | --- |
| shared-default | cold | 2,543,960.00 → 2,522,960.00 B | -0.8255% | 12,736.00 → 12,938.00 µs |
| shared-default | warm/merge | 967,608.00 → 946,104.00 B | -2.2224% | 1,569.44 → 1,559.50 µs |
| shared-alpha | cold | 2,722,092.00 → 2,692,388.00 B | -1.0912% | 10,127.00 → 13,730.00 µs |
| shared-alpha | warm/merge | 1,139,576.25 → 1,109,880.25 B | -2.6059% | 2,012.81 → 1,916.00 µs |
| db-default | cold | 2,937,420.00 → 2,916,428.00 B | -0.7146% | 14,105.00 → 14,263.00 µs |
| db-default | warm/merge | 424,256.25 → 402,759.75 B | -5.0669% | 851.00 → 837.56 µs |
| db-alpha | cold | 3,241,916.00 → 3,308,980.00 B | +2.0687% | 11,456.00 → 11,547.00 µs |
| db-alpha | warm/merge | 545,328.25 → 515,783.75 B | -5.4177% | 1,091.50 → 1,047.00 µs |

Cold resident-alpha allocation is +2.0687% (67,064 B more); this remaining cost is reported alongside the warm reduction. No uniform allocation reduction is claimed.

`Profiler::heap_bytes()` deltas measure regional cumulative bump allocation, excluding the static heap base. They are not live heap, RSS or the CI selfcompile peak-memory metric. Short wall measurements are advisory; no speed improvement is claimed. Intermediate candidates and the earlier two-group workload are excluded.

## Filesystem integration

The standard compiler KPI and CLI corpora each have cold/warm samples using an isolated cache per pair. Both lanes use the same literal root, compiler, output and cache paths. Own-source builds use each revision’s source with AST caching off. Same-source builds give both compilers the final candidate snapshot with AST caching on. All 24 same-source outputs are byte-identical; every own-source lane is stable across repetitions. These protocols total 48 samples.

| Protocol | Corpus | Cache | heap_ptr baseline → candidate | Change | Wall baseline → candidate |
| --- | --- | --- | --- | --- | --- |
| Own source, AST off | kpi | cold | 1,163,482,856 → 1,163,420,664 B | -0.0053% | 7.949 → 7.978 s |
| Own source, AST off | kpi | warm | 653,855,568 → 653,792,192 B | -0.0097% | 4.742 → 4.826 s |
| Own source, AST off | cli | cold | 2,528,696,848 → 2,530,207,568 B | +0.0597% | 17.740 → 17.507 s |
| Own source, AST off | cli | warm | 1,402,193,480 → 1,402,376,424 B | +0.0130% | 11.061 → 11.039 s |
| Same candidate source, AST on | kpi | cold | 1,193,785,288 → 1,193,721,688 B | -0.0053% | 7.983 → 7.986 s |
| Same candidate source, AST on | kpi | warm | 627,223,864 → 627,160,176 B | -0.0102% | 4.851 → 4.821 s |
| Same candidate source, AST on | cli | cold | 2,589,123,088 → 2,589,011,240 B | -0.0043% | 17.699 → 17.769 s |
| Same candidate source, AST on | cli | warm | 1,364,989,240 → 1,364,869,304 B | -0.0088% | 11.425 → 11.376 s |

Here `heap_ptr` includes the static heap base and cumulative bump allocation, unlike the regional deltas above. It is not RSS or CI peak memory. Own-source measurements include additional compiler source and can produce different images across revisions. No speed improvement is claimed.

Compiler artifact: 5,661,664 → 5,661,711 bytes. Candidate stage2 and stage3 are identical (`353361ab0a8f29672cefe10d438712759d17afeefcbc4fe09fd5635a46253a06`); both validate as Wasm.

Raw receipts, measured index trees, compiler/image hashes and every sample are retained in [results.json](results.json). Report-only additions after measurement do not change the production-input fingerprint. Final evidence totals 80 samples: 24 focused A/B, eight A/A controls and 48 filesystem A/B.

## Correctness and reproduction

The exact candidate passed 52 harness tests with AST caching off, 51 with it on, and 32 with RC and AST caching on. The new merge suite has eight source cases; harness totals include generated/imported test exports and are not counts of unique source cases. The bootstrap gate also runs it against its own fresh stage2.

Tests cover poisoned ambient flags, one Config read despite successful/failing inner merges, Alpha→Beta→Alpha resident switching, unchanged warm reuse, discarded checker/artifact products, collision-provider reparsing, failed-merge recovery, scoped identities for identical text/empty groups and compatibility flag changes before cache lookup. A standalone legacy-API flag-switch repro compiles and validates on the baseline, then fails at runtime; the same repro compiles, validates and succeeds with the candidate.

Nine fault injections each compile successfully, validate as Wasm, and fail at runtime: ambient shared parsing, ambient DB parsing, ambient collision-provider reparsing, skipped Config capture, a second Config read, omitted ordinary/grouped DB configuration validation, unscoped merge fingerprints and an unscoped whole-program seed. Every mutated source is restored byte-for-byte; receipts include compiler/image/source hashes and failure excerpts.

```sh
python3 bench/perf/experiments/invocation-config-merge-1953/measure_merge.py \
  BASE_ROOT CANDIDATE_ROOT BASE_STAGE2 CANDIDATE_STAGE2 OUTPUT_MERGE
python3 bench/perf/experiments/invocation-config-1953/measure_own_source.py \
  BASE_ROOT CANDIDATE_ROOT BASE_STAGE2 CANDIDATE_STAGE2 OUTPUT_DEFAULT
python3 bench/perf/experiments/invocation-config-1953/measure_own_source.py \
  BASE_ROOT CANDIDATE_ROOT BASE_STAGE2 CANDIDATE_STAGE2 OUTPUT_AST \
  --same-source --ast-cache 1
```

Stage inputs before measuring; output directories must not exist. Run on an idle machine, regenerate each checkout’s SDK inputs, and keep samples serial. See the [merge driver](measure_merge.py) and [filesystem driver](../invocation-config-1953/measure_own_source.py).
