# Checked source-group codegen (#1953)

Baseline: `3a8b2b965d057fe70f51e1cedaa21c9a2099d318` (after merged #3895). The new `compile_checked_source_groups_wasi_with_config` emits a caller-supplied checked closure with its immutable `TargetCfg` and retained `CheckedLoweringInputs`. It needs only `Exception`. The capturing entry adds `Config` and reads flags once. Both `mvp` and `no-dce` share mode decoding/emission with the compatibility checked closure-source driver.

The data entry validates the supplied source/target witnesses through the owned merger before changing merge metadata. Source discovery, rechecking, final-artifact caching and launcher grants stay with callers. Full filesystem/CLI/RC orchestration, workers and other authority families remain later slices. Namespace/location metadata and codegen scratch remain serial phase-owned.

## Regional measurements

The [workload](checked_codegen.vibe) checks 128 virtual integer providers plus an entry that calls all of them. Each fresh process captures once, primes both compile paths, then times one compatibility and one owned full MVP compile. Both orders have three samples. Checking, priming, byte comparisons, output writing, validation and child execution are outside the timed regions. This is a small default-flag graph; full compiler-closure capture and the Config effect boundary are outside this measurement.

| Region | Median allocated | Median wall |
| --- | --- | --- |
| Snapshot capture | 59,388 B | 479.0 µs |
| Compatibility compile | 6,587,426 B | 16,595.0 µs |
| Owned compile | 6,584,694 B | 16,217.5 µs |

Capture adds 59,388 B once. The owned compile allocates 2,732 B less per call in this fixture. Four-byte order-dependent bookkeeping remains in both compile regions and cancels in their allocation difference. Regional allocation is a cumulative bump-heap delta excluding the static base; wall medians are advisory. No speed improvement or full-compiler memory reduction is claimed.

Every emitted image is byte-identical across both paths and all six processes, validates as Wasm, and returns `8256` when executed. The [driver](measure_codegen.py) retains image/output digests and raw samples.

## Filesystem integration

Each checkout compiles its own compiler KPI and CLI sources with AST caching off. A second matrix has both compilers consume the same candidate source with AST caching on and requires cross-compiler byte identity. N=3 fresh isolated cache pairs per lane/corpus; each cold compile is followed by a fresh-process warm compile, in AB/BA/AB order. Compiler, root, cache and output use the same literal guest paths across lanes.

| Source / AST cache | Corpus | Cache | Heap pointer baseline → candidate | Change | Wall baseline → candidate |
| --- | --- | --- | --- | --- | --- |
| Own source / off | kpi | cold | 1,179,868,536 → 1,179,865,920 B | -0.000222% | 9.182 → 9.118 s |
| Own source / off | kpi | warm | 658,617,808 → 658,614,792 B | -0.000458% | 4.926 → 4.880 s |
| Own source / off | cli | cold | 2,551,140,728 → 2,551,137,080 B | -0.000143% | 19.459 → 19.408 s |
| Own source / off | cli | warm | 1,401,201,520 → 1,401,195,072 B | -0.000460% | 10.944 → 11.073 s |
| Same candidate / on | kpi | cold | 1,210,941,576 → 1,210,938,816 B | -0.000228% | 9.036 → 9.168 s |
| Same candidate / on | kpi | warm | 630,559,824 → 630,556,872 B | -0.000468% | 5.069 → 5.117 s |
| Same candidate / on | cli | cold | 2,610,864,408 → 2,610,857,472 B | -0.000266% | 19.661 → 19.543 s |
| Same candidate / on | cli | warm | 1,361,073,248 → 1,361,065,792 B | -0.000548% | 11.628 → 11.580 s |

All 24 same-source outputs are byte-identical across compilers. Own-source outputs remain stable within each revision; the CLI images differ because their compiler sources differ. The filesystem measurements exercise the common compatibility pipeline; the regional workload directly exercises the new data API. Heap pointers include the static heap base and cumulative bump allocation. These values measure neither live memory/RSS nor the CI selfcompile peak metric. Timing is advisory; no speed improvement is claimed.

Compiler artifact: 5,683,135 → 5,683,135 bytes. Candidate stage2 and stage3 match (`426f1df94f1911b151e073e3ce1ac26b130b2dbc43b95c4aa5989eb2a4b2d6df`), and both validate as Wasm. All 54 samples, output hashes, measured index trees and raw correctness receipts are in [results.json](results.json). Production sources and both SDKs were frozen before sampling, with no compiler/test jobs alongside measurements. Later test/doc/report changes leave the production fingerprint (`23fb7fd04254a4ec8325a8a49983e492f3f2c464b54942cce7c21155ccc34b12`) and measured compiler unchanged.

## Correctness

The final suite has eight source cases and thirteen harness exports, passing with AST caching off, on, and RC plus AST caching on. Related AST-on and RC runs pass 54 and 27 harness tests respectively; these totals overlap the new suite. Generated Wasm is executed for both modes. Coverage includes compatibility byte parity, retained Alpha/Beta products after another check and memo reset, a same-source Float64/Int record-field switch, wide Int/Bool rendering, structural equality, argument placement and builtin identity, nested successful/refused emits inside an outer flag request, and input/mode refusal before metadata changes.

Seven injected faults compile successfully, validate as Wasm, and fail at runtime: ambient flags at the capturing boundary; two Config reads; omitted Int, Bool or equality channels; wrong MVP selection; and a default for unsupported modes. All production source bytes are restored. The float-hint deletion control survives this suite. Numeric runtime/byte checks are smoke coverage; independent float-hint consumption is unproven.

A caller declaring only `Exception` when calling the capturing entry is refused at compile time with the concrete edit `with Config + Exception`. The data wrapper in the suite admits neither Env nor Fs. The bootstrap gate runs the final suite with its own fresh stage2 and AST caching enabled.

## Reproduction

```sh
python3 bench/perf/experiments/invocation-config-codegen-1953/measure_codegen.py \
  CANDIDATE_ROOT CANDIDATE_STAGE2 OUTPUT_REGION
python3 bench/perf/experiments/invocation-config-1953/measure_own_source.py \
  BASE_ROOT CANDIDATE_ROOT BASE_STAGE2 CANDIDATE_STAGE2 OUTPUT_OWN
python3 bench/perf/experiments/invocation-config-1953/measure_own_source.py \
  BASE_ROOT CANDIDATE_ROOT BASE_STAGE2 CANDIDATE_STAGE2 OUTPUT_SAME \
  --same-source --ast-cache 1
```

Stage inputs before using the filesystem driver; output directories must not exist. Regenerate each checkout's SDK, pass explicit stage2 artifacts and keep runs serial. Full compiler memory reduction and arbitrary concurrent compiler invocations remain outside this slice.
