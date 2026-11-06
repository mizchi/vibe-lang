# Invocation-scoped filesystem checking (#1953)

Baseline: `ba4a85d30` (including merged #3841). This slice carries one immutable `TargetCfg` through collection, dependency planning, module checking, semantic-use observations and cache identities. A changed flag set invalidates resident derived `TypeDb` results while retaining its sources and cumulative counters. Storage receives a namespace only; compatibility cache APIs keep the legacy cache setter. CLI orchestration, memory-only checking, merge/codegen, final artifacts and other configuration families remain subsequent work.

Compatibility logical fingerprint and alias-key APIs retain their original declared inputs and framing. Only the explicit configuration variants bind target flags; no new ambient flag dependency is added to those compatibility calculations. The legacy in-memory coordinator uses the checker's flag-aware result key for warm lookups, with a regression test that observes parse work rather than only unchanged fingerprint counts.

Each table cell is a median of three fresh Node processes. Runs were serial, isolated from other compiler/test jobs, AB/BA/AB, cold then warm with isolated cache directories. Both lanes used the same literal root, compiler, output and cache paths. RC=0, raw ABI, trusted compiler sources; Node 24.7.0 with the local exnref shim on WSL/Linux. Wall time includes startup.

`heap_ptr` includes the static heap base and cumulative bump allocation; it is not live heap, RSS or the CI selfcompile peak-memory metric. This measures migration cost and does not establish a speed improvement.

| Protocol | Corpus | Cache | heap_ptr baseline → candidate | Change | Wall baseline → candidate |
| --- | --- | --- | --- | --- | --- |
| Own source, AST off | kpi | cold | 1,142,358,664 → 1,142,241,120 B | -0.0103% | 7.735 → 7.726 s |
| Own source, AST off | kpi | warm | 645,657,296 → 645,642,312 B | -0.0023% | 4.593 → 4.682 s |
| Own source, AST off | cli | cold | 2,521,273,512 → 2,530,694,920 B | +0.3737% | 17.274 → 17.125 s |
| Own source, AST off | cli | warm | 1,425,862,088 → 1,429,227,744 B | +0.2360% | 10.755 → 10.896 s |
| Same candidate source, AST on | kpi | cold | 1,172,259,152 → 1,172,100,344 B | -0.0135% | 7.676 → 7.707 s |
| Same candidate source, AST on | kpi | warm | 619,853,016 → 619,820,184 B | -0.0053% | 4.820 → 4.741 s |
| Same candidate source, AST on | cli | cold | 2,588,816,272 → 2,588,502,880 B | -0.0121% | 17.463 → 17.409 s |
| Same candidate source, AST on | cli | warm | 1,392,563,792 → 1,392,496,584 B | -0.0048% | 11.395 → 11.302 s |

Compiler artifact: 5,609,091 → 5,610,905 bytes. Stage2 and stage3 are identical (`d25b4a295582094ed059a1dc583dca9579bcfd39be2c27eecda606cca88066e8`).

The own-source protocol builds each compiler’s own checkout, so input trees and output images differ across those lanes; every lane is stable across its cold/warm repetitions. The same-source protocol gives both compilers the final candidate snapshot and requires byte identity across all 12 runs per corpus. All 24 same-source outputs passed. Together the two final protocols total 48 samples; intermediate artifacts and measurements are excluded.

Same-source `heap_ptr` deltas range from -0.0135% to -0.0048%. The own-source results include the cost of additional compiler source.

Raw receipts retain measured index trees, compiler hashes and every sample in [results.json](results.json). Report-only additions after measurement do not change the generated production-input fingerprint. Both worktrees had SDK inputs generated from their respective production snapshots. The parameterized driver is [the earlier experiment’s script](../invocation-config-1953/measure_own_source.py).

```sh
python3 bench/perf/experiments/invocation-config-1953/measure_own_source.py \
  BASE_ROOT CANDIDATE_ROOT BASE_STAGE2 CANDIDATE_STAGE2 OUTPUT_DEFAULT
python3 bench/perf/experiments/invocation-config-1953/measure_own_source.py \
  BASE_ROOT CANDIDATE_ROOT BASE_STAGE2 CANDIDATE_STAGE2 OUTPUT_AST \
  --same-source --ast-cache 1
```

Stage candidate inputs before measuring; output directories must not exist. The exact candidate passed 183 targeted tests with AST caching off, 38 configuration tests with it on, and 23 configuration/reset tests with reference counting and AST caching on. The bootstrap gate runs the configuration suites against its own freshly built stage2 with AST caching on.

Behavioral tests cover resident flag switches and unchanged warm reuse, dependency plans and disk namespaces, checked-module warm hits and semantic use, successful/failing inner checks, scoped fingerprints/alias encodings, and refusal then repair of a valid checked-module payload moved into another configuration’s valid outer envelope. Compatibility tests retain cache-setter identity changes while logical keys remain independent of both ambient flag cells.

Eight negative controls fail at runtime, not at compilation: ambient checker parsing, resident results surviving a flag switch, global dependency-list publication, unscoped conservative fingerprints or segmented alias keys, a global checked-module input context, an ambient dependency in a compatibility logical key, and a drifting in-memory warm-lookup key. Every mutated source is restored byte-for-byte. Results record each failing test and original source hash.
