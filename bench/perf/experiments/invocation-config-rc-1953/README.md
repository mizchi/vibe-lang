# Checked RC codegen (#1953)

Baseline: `0e360c4d9` (merged #3901). Checked source-group codegen and the checked closure-source compatibility driver now accept `rc` and `rc-shadow`, alongside `mvp` and `no-dce`. The new modes forward every retained typed channel through the existing heap-parameter elaboration and RC kernels. The shadow mode also enables ownership instrumentation. All four modes share decoding/emission and use distinct typed artifact kinds in the cached driver.

The data API still requires only `Exception`; the Config boundary captures target flags once. The caller supplies a checked closure and its target-bound inputs. Launcher grants, full CLI/filesystem orchestration, body caches, final-artifact configuration, workers and other authority families remain separate. Merge/codegen scratch remains serial phase-owned.

## Regional measurements

The [workload](checked_codegen.vibe) checks 129 virtual modules. Each of the 128 providers allocates an integer array, and the entry calls every provider. A fresh bump-backed driver captures once, primes both merge/codegen paths, then measures one compatibility and one owned compile. Each order has three samples per target backend. Checking, priming, byte comparison, writing, validation and child execution are outside the timed regions.

| Target | Region | Median allocated | Median wall |
| --- | --- | --- | --- |
| rc | Snapshot capture | 71,676 B | 493.5 µs |
| rc | Compatibility compile | 7,361,330 B | 21,564.5 µs |
| rc | Owned compile | 7,370,886 B | 21,621.5 µs |
| rc-shadow | Snapshot capture | 71,676 B | 475.0 µs |
| rc-shadow | Compatibility compile | 7,237,720 B | 21,299.5 µs |
| rc-shadow | Owned compile | 7,247,272 B | 21,058.5 µs |

Owned compilation allocates 9,556 B more per call for RC and 9,552 B more for RC-shadow in this fixture, besides the one-time 71,676 B capture. These are cumulative bump-heap deltas, including regional bookkeeping, rather than live RC heap. Each emitted image validates and returns `8256`; outputs are byte-identical across both paths and all six processes within each backend. RC and RC-shadow have different images. Full compiler-closure capture and the Config effect boundary are outside this measurement. No speed improvement or full-compiler memory reduction is claimed.

## Filesystem integration

N=3 isolated cache pairs, cold then fresh-process warm, in AB/BA/AB order. Each compiler first builds its own source with AST caching off. A second matrix makes both compilers consume the same candidate source with AST caching on. Both lanes use the same literal compiler/root/cache/output paths. These filesystem samples exercise the existing compatibility pipeline; the regional workload directly exercises the new modes.

| Source / AST cache | Corpus | Cache | Heap pointer baseline → candidate | Change | Wall baseline → candidate |
| --- | --- | --- | --- | --- | --- |
| Own source / off | kpi | cold | 1,180,058,936 → 1,180,056,432 B | -0.000212% | 9.175 → 9.201 s |
| Own source / off | kpi | warm | 658,626,200 → 658,624,136 B | -0.000313% | 4.979 → 5.007 s |
| Own source / off | cli | cold | 2,551,689,472 → 2,551,681,008 B | -0.000332% | 19.450 → 19.538 s |
| Own source / off | cli | warm | 1,401,300,816 → 1,401,297,160 B | -0.000261% | 11.063 → 11.197 s |
| Same candidate / on | kpi | cold | 1,211,080,184 → 1,211,078,424 B | -0.000145% | 9.174 → 9.282 s |
| Same candidate / on | kpi | warm | 630,548,680 → 630,546,904 B | -0.000282% | 5.142 → 5.119 s |
| Same candidate / on | cli | cold | 2,611,318,152 → 2,611,310,128 B | -0.000307% | 20.019 → 19.842 s |
| Same candidate / on | cli | warm | 1,361,112,024 → 1,361,108,392 B | -0.000267% | 11.889 → 11.794 s |

All 24 same-source outputs are byte-identical across compilers. Own-source outputs are stable within each revision; CLI output differs across revisions because the sources differ. Heap pointers include the static base and cumulative bump allocation, not live memory/RSS or the CI selfcompile peak. Wall differences are advisory. Samples ran serially with no other compiler/test jobs.

Compiler artifacts are both 5,684,339 B. Candidate stage2/stage3 match (`2cae3391967914eb13e4b510eff40fddf881a04fe24bf19971ec87f367d9561a`) and validate as Wasm. [results.json](results.json) retains all 60 samples, output digests, measured index trees and correctness receipts. Production sources and SDKs were frozen before sampling; later report changes leave the production fingerprint and measured compiler unchanged.

## Correctness

The suite has ten source cases /15 harness exports. The exact candidate passes AST-off (15), related AST-on (56), related RC+AST-on (29), and RC-shadow+AST-on (15) runs; these totals overlap. Generated programs execute in all four output modes. Coverage includes Float64/Int record-field switches, wide Int/Bool rendering, equality, target-dependent parameter order and builtin shadows, nested successful/refused emits, source/target/mode refusal before merge metadata changes, and retained RC products after another target check and memo reset.

Independent calls to the existing RC and RC-shadow kernels pin backend selection and escaping owned captures. Repeated cached-mode calls match those independent images. Seven injected faults compile, validate, and fail at runtime: RC decoded as bump; shadow decoded as RC; missing RC Int/equality channels; missing shadow Bool channel; ambient boundary flags; and double Config capture. Production source bytes are restored. Float64 smoke coverage does not independently prove float-hint consumption.

## Reproduction

```sh
python3 bench/perf/experiments/invocation-config-rc-1953/measure_codegen.py \
  CANDIDATE_ROOT CANDIDATE_STAGE2 OUTPUT_RC --mode rc
python3 bench/perf/experiments/invocation-config-rc-1953/measure_codegen.py \
  CANDIDATE_ROOT CANDIDATE_STAGE2 OUTPUT_SHADOW --mode rc-shadow
python3 bench/perf/experiments/invocation-config-1953/measure_own_source.py \
  BASE_ROOT CANDIDATE_ROOT BASE_STAGE2 CANDIDATE_STAGE2 OUTPUT_OWN
python3 bench/perf/experiments/invocation-config-1953/measure_own_source.py \
  BASE_ROOT CANDIDATE_ROOT BASE_STAGE2 CANDIDATE_STAGE2 OUTPUT_SAME \
  --same-source --ast-cache 1
```

Regenerate each SDK, stage the inputs before using the filesystem driver, pass explicit stage2 artifacts, use new output directories, and keep the runs serial.
