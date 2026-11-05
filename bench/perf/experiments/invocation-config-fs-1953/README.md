# Invocation-scoped FS parse and AST cache flags (#1953)

Baseline: `e7d9153bd` (including merged #3818). This slice adds the Config entry for shared FS parsing and pairs parser flags with both in-process and persistent AST identities. Whole-file orchestration and its other cache families still use compatibility settings.

Each table cell is a median of three fresh Node processes. Runs were serial and isolated from other compiler/test jobs, in AB/BA/AB order, cold then warm with separate cache directories. Snapshots moved through the same literal root, compiler, output and cache paths. RC=0, raw ABI, trusted compiler sources; Node 24.7.0 with the local exnref shim on WSL/Linux. Wall time includes startup.

`heap_ptr` includes the static heap base and cumulative bump allocation; it is not live heap, RSS, or the CI selfcompile peak-memory metric. These measurements check migration cost; they do not establish a speed improvement.

| Protocol | Corpus | Cache | heap_ptr baseline → candidate | Change | Wall baseline → candidate |
| --- | --- | --- | --- | --- | --- |
| Own source, AST off | kpi | cold | 1,126,113,336 → 1,126,392,856 B | +0.0248% | 6.980 → 6.987 s |
| Own source, AST off | kpi | warm | 643,825,200 → 643,934,392 B | +0.0170% | 4.290 → 4.359 s |
| Own source, AST off | cli | cold | 2,489,312,936 → 2,489,195,720 B | -0.0047% | 15.732 → 15.809 s |
| Own source, AST off | cli | warm | 1,418,762,992 → 1,419,317,720 B | +0.0391% | 10.210 → 10.239 s |
| Same candidate source, AST on | kpi | cold | 1,155,796,736 → 1,156,009,512 B | +0.0184% | 7.015 → 7.070 s |
| Same candidate source, AST on | kpi | warm | 618,033,912 → 618,105,584 B | +0.0116% | 4.397 → 4.434 s |
| Same candidate source, AST on | cli | cold | 2,545,921,800 → 2,546,253,672 B | +0.0130% | 15.902 → 15.848 s |
| Same candidate source, AST on | cli | warm | 1,381,977,536 → 1,382,109,712 B | +0.0096% | 10.617 → 10.618 s |

Compiler artifact: 5,587,259 → 5,587,810 bytes. Stage2 and stage3 are identical (`1bb9f846089b48006c7d01f07e663c2abb705d6fa4bba03175dcc3f2c82def31`).

The own-source protocol compares each compiler building its own checkout; the source trees differ, so output identity across those two lanes is not expected. Each lane produced stable output over all cold/warm repetitions. The same-source protocol uses the candidate snapshot for both compilers and requires byte identity across all 12 runs per corpus. All 24 same-source outputs passed that check. Both protocols total 48 measured runs.

The receipts preserve the measured index trees and artifact hashes. Report/gate/test-only additions after measurement do not change the generated production-input fingerprint. The test file is also run with AST caching enabled by the bootstrap gate against that gate's freshly built stage2, so disk-warm coverage is not confined to the local benchmark.

Three negative controls were observed as runtime test failures, not compile errors: selecting the ambient parser flags instead of the captured array; selecting the legacy persistent namespace instead of the supplied flags; and allowing a comma-containing compatibility array element to use the ambiguous CSV cache key. Sources were restored before the final generation. The tests also cover successful/failing nested Config calls, exact raw compatibility arrays, distinct on-disk flag namespaces, malformed AST decoding, and real memo eviction before disk-warm reuse.

Reproduce with the parameterized driver in [the earlier experiment](../invocation-config-1953/measure_own_source.py):

```sh
python3 bench/perf/experiments/invocation-config-1953/measure_own_source.py \
  BASE_ROOT CANDIDATE_ROOT BASE_STAGE2 CANDIDATE_STAGE2 OUTPUT_DEFAULT
python3 bench/perf/experiments/invocation-config-1953/measure_own_source.py \
  BASE_ROOT CANDIDATE_ROOT BASE_STAGE2 CANDIDATE_STAGE2 OUTPUT_AST \
  --same-source --ast-cache 1
```

Both worktrees must have generated SDK inputs matching their respective production source snapshots; stage source changes in the candidate before measuring. Output directories must not exist. [results.json](results.json) contains every run and the medians.
