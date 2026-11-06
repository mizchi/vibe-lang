# Invocation-scoped filesystem source collection (#1953)

Baseline: `974ba219c` (merged #3823). This slice captures target flags once in opaque `TargetCfg` data and carries them through complete source collection, manifest/header/contract ingestion, parse memos and parse-derived persistent cache identities. Whole-file checking, merge and final-artifact orchestration remain subsequent work.

The export-name memo still retains one entry per path: configuration is validated in the value, so additional flag sets replace an entry rather than grow the key space. Generated-type registry rows carry configuration identity; the contract re-export visiting stack belongs to its walk. Snapshot array access returns a copy.

Each table cell is a median of three fresh Node processes. Runs were serial, isolated from other compiler/test jobs, AB/BA/AB, cold then warm with isolated cache directories. Snapshots moved through identical literal root, compiler, output and cache paths. RC=0, raw ABI, trusted compiler sources; Node 24.7.0 with the local exnref shim on WSL/Linux. Wall time includes startup.

`heap_ptr` includes static heap base and cumulative bump allocation; it is not live heap, RSS or the CI selfcompile peak-memory metric. This checks migration cost and does not establish a speed improvement.

| Protocol | Corpus | Cache | heap_ptr baseline → candidate | Change | Wall baseline → candidate |
| --- | --- | --- | --- | --- | --- |
| Own source, AST off | kpi | cold | 1,138,914,616 → 1,138,896,728 B | -0.0016% | 7.301 → 7.365 s |
| Own source, AST off | kpi | warm | 643,988,024 → 644,178,512 B | +0.0296% | 4.394 → 4.418 s |
| Own source, AST off | cli | cold | 2,511,828,016 → 2,511,229,696 B | -0.0238% | 16.453 → 16.412 s |
| Own source, AST off | cli | warm | 1,419,398,256 → 1,421,653,664 B | +0.1589% | 10.452 → 10.514 s |
| Same candidate source, AST on | kpi | cold | 1,168,783,200 → 1,168,732,976 B | -0.0043% | 7.344 → 7.399 s |
| Same candidate source, AST on | kpi | warm | 618,460,824 → 618,431,640 B | -0.0047% | 4.574 → 4.537 s |
| Same candidate source, AST on | cli | cold | 2,568,711,520 → 2,568,750,936 B | +0.0015% | 16.562 → 16.771 s |
| Same candidate source, AST on | cli | warm | 1,384,792,848 → 1,384,752,624 B | -0.0029% | 11.016 → 11.030 s |

Compiler artifact: 5,587,785 → 5,590,008 bytes. Stage2 and stage3 are identical (`3e07018a5d957ae02eff7fbd0b3d9ba5a4386575a33e86506370f331ed74aae7`).

The own-source protocol compares each compiler building its own checkout, so source trees and output images differ across those two lanes. Every lane is stable across its cold/warm repetitions. The same-source protocol gives both compilers the candidate snapshot and requires byte identity across all 12 runs per corpus. All 24 same-source outputs passed. These two final protocols total 48 runs; intermediate artifacts and measurements are excluded.

Receipts retain the measured index trees, artifact hashes and every raw sample. Report-only additions after measurement do not change the generated production-input fingerprint. The parameterized driver lives in [the earlier experiment](../invocation-config-1953/measure_own_source.py).

```sh
python3 bench/perf/experiments/invocation-config-1953/measure_own_source.py \
  BASE_ROOT CANDIDATE_ROOT BASE_STAGE2 CANDIDATE_STAGE2 OUTPUT_DEFAULT
python3 bench/perf/experiments/invocation-config-1953/measure_own_source.py \
  BASE_ROOT CANDIDATE_ROOT BASE_STAGE2 CANDIDATE_STAGE2 OUTPUT_AST \
  --same-source --ast-cache 1
```

Both worktrees need generated SDK inputs matching their respective production snapshots. Stage candidate source changes before measuring; output directories must not exist.

Targeted tests run with AST caching off and on against the selected stage2. They cover exact identities for raw flag arrays, copied snapshot access, poisoned compatibility cells, recursive and manifest closure selection, source-list fallback, cold/warm flag switches, successful/failing nested calls, contract conformance, re-export type-parameter memo separation, and generated-type registry isolation. The bootstrap gate runs the snapshot, loader and AST tests with AST caching on using its own freshly built stage2.

Four negative controls fail at runtime rather than at compilation: ambient capture, a global source-list namespace, unfiltered generated-type registry rows and an ambient type-parameter memo identity. [results.json](results.json) records those controls and the measurements. The parser binder-context structural gate continues to pin explicit `None` authority through both compatibility and flag-only preserving entries.
