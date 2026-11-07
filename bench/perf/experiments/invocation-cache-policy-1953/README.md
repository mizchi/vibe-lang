# Scoped persistent-cache policies (#1953)

Baseline: `f2b20db7b` (after merged #3908). Immutable, opaque `AstCachePolicy` and `IngestionStampPolicy` values separate enable decisions from cached contents. Distinct `AstCacheConfig::Active` and `IngestionStampConfig::Enabled` effects capture one decision each. They grant no target-flag, checked-artifact, source-trust, tracing or filesystem authority.

Shared FS parse/prefetch accept policy with `TargetCfg`; load, store and prefetch use the same decision. Fingerprinting accepts stamp policy with a retained namespace. Legacy APIs delegate to the same implementation while preserving lazy environment memos and the checked-module `on` suppression of persistent AST use. The explicit AST value is the effective decision chosen by its caller. In-process parse/fingerprint memos, cache formats, namespace recipes and source/stat validation stay unchanged. Checked-module mode, typing reuse, cache roots, full CLI orchestration and mutable cache ownership remain separate migrations.

## Controlled compiler/CLI measurements

N=3 per lane/corpus/temperature, isolated cold caches followed by fresh-process warm compiles, in AB/BA/AB order. Each A/B pair uses identical literal root/compiler/cache/output paths. There are three matrices: own source with both policies off; the same candidate source with both off; and the same candidate source with both on. Own/off and same/off reuse the exact original work path, moving completed receipts aside before the extra matrix.

| Source / AST+stamp | Corpus | Cache | Heap pointer baseline → candidate | Change | Wall baseline → candidate |
| --- | --- | --- | --- | --- | --- |
| Own source / off+off | kpi | cold | 1,182,304,392 → 1,182,348,248 B | +0.003709% | 8.598 → 8.385 s |
| Own source / off+off | kpi | warm | 659,315,016 → 659,327,832 B | +0.001944% | 4.518 → 4.465 s |
| Own source / off+off | cli | cold | 2,556,007,520 → 2,559,145,776 B | +0.122780% | 17.808 → 17.978 s |
| Own source / off+off | cli | warm | 1,402,658,392 → 1,403,799,432 B | +0.081348% | 10.082 → 10.076 s |
| Same candidate / off+off | kpi | cold | 1,182,308,776 → 1,182,348,248 B | +0.003339% | 8.803 → 8.466 s |
| Same candidate / off+off | kpi | warm | 659,315,016 → 659,327,832 B | +0.001944% | 4.504 → 4.480 s |
| Same candidate / off+off | cli | cold | 2,559,075,536 → 2,559,145,776 B | +0.002745% | 17.976 → 17.871 s |
| Same candidate / off+off | cli | warm | 1,403,778,272 → 1,403,799,432 B | +0.001507% | 10.095 → 10.094 s |
| Same candidate / on+on | kpi | cold | 1,220,829,264 → 1,220,889,152 B | +0.004906% | 8.736 → 8.515 s |
| Same candidate / on+on | kpi | warm | 634,008,000 → 634,026,400 B | +0.002902% | 4.643 → 4.638 s |
| Same candidate / on+on | cli | cold | 2,634,500,904 → 2,634,580,008 B | +0.003003% | 18.213 → 18.279 s |
| Same candidate / on+on | cli | warm | 1,368,772,104 → 1,368,794,552 B | +0.001640% | 10.674 → 10.696 s |

The own-source CLI delta is +3,138,256 B cold /+1,141,040 B warm. With the same candidate input and the same off/off configuration it is +70,240 B /+21,160 B. The source-growth contribution is therefore separated from the implementation comparison under matching settings. Both same-source matrices stay below +0.005%; all 48 same-source outputs are byte-identical. Own-source outputs remain stable within each revision. Wall differences are advisory; no speedup is claimed.

Heap pointers include the static base and cumulative bump allocation. They measure neither live memory/RSS nor the CI selfcompile peak. The [integration driver](measure_integration.py) records all raw samples. Compiler artifacts: 5,688,275 → 5,688,715 B. Candidate stage2/stage3 match (`8fa40d7c49a08c4a8b2b853702b246fc2b72372d3103caa7566db3a7c930d8ff`) and validate as Wasm. Production and SDKs were frozen before measurements. After measurement, the checked-program contract gained the policy dependency required by the contract scan. Regeneration changes only the flattened compiler's codegen fingerprint literal; the measurements above retain the earlier artifact identity. The final compiler is validated separately below.

## Correctness

The new suites contain eight source cases /29 harness exports, including dependency inspections. Six exact-candidate runs pass: off/off plus related FS/codec tests (41); on/on plus related FS tests (38); mixed off/on (29); mixed on/off (29); RC with both on plus related FS tests (38); RC-shadow with both on (29). Totals overlap. The bootstrap gate also exercises the default and independent enable-switch combinations.

Coverage includes retained values, separate-effect capture counts, nested success/exception unwinding, real memo eviction before AST disk hits, disabled disk caching, prefetch, malformed AST fallback, a changed legacy checked-module mode, stamp publication, source edits, captured namespaces and legacy flag selection. Nine faults compile and validate but fail at runtime: ambient AST selection at capture/use; ignored AST disable/prefetch policy; double AST/stamp capture; ambient stamp selection; unconditional stamping; and ambient namespace publication. Sources are restored byte-for-byte. Missing AST or stamp configuration authority is refused at compile time with a row edit.

The [fresh-process probe](cache_probe.vibe) and [driver](check_policy.py) run eight scenarios. Cold, warm, off despite warm files, malformed caches, edited source, edited warm source, a second namespace, and its warm run all pass. A warm stamp avoids the fingerprint helper read/hash; ordinary source reads remain authoritative. Disabled stamping performs no stamp probes/publications; disabled persistent AST use runs the parser after real memo eviction. Valid output never comes from a malformed entry.

[results.json](results.json) retains all 72 process measurements, output digests, source/index identities, fault receipts, static refusals and the eight functional scenarios.

## Reproduction

```sh
python3 bench/perf/experiments/invocation-cache-policy-1953/check_policy.py \
  CANDIDATE_ROOT CANDIDATE_STAGE2 OUTPUT_POLICY
python3 bench/perf/experiments/invocation-cache-policy-1953/measure_integration.py \
  BASE_ROOT CANDIDATE_ROOT BASE_STAGE2 CANDIDATE_STAGE2 OUTPUT_OWN \
  --ast-cache 0 --ingestion-stamp 0
python3 bench/perf/experiments/invocation-cache-policy-1953/measure_integration.py \
  BASE_ROOT CANDIDATE_ROOT BASE_STAGE2 CANDIDATE_STAGE2 OUTPUT_SAME_OFF \
  --same-source --ast-cache 0 --ingestion-stamp 0
python3 bench/perf/experiments/invocation-cache-policy-1953/measure_integration.py \
  BASE_ROOT CANDIDATE_ROOT BASE_STAGE2 CANDIDATE_STAGE2 OUTPUT_SAME_ON \
  --same-source --ast-cache 1 --ingestion-stamp 1
```

Stage each source snapshot and regenerate its SDK first. Pass explicit artifacts, use new output directories, and run serially. To repeat the exact own/off vs same/off attribution, move the completed own output aside and reuse its literal output path for the same/off matrix.

## Final contract-dependency correction

The checked-program contract imports the cache contract, whose configured APIs now expose policy types. Its dependency declarations include the policy package. The final stage2/stage3 match (`f9612da08243a100e815550c4d8e6a26058300b9940542a335025a975637f7b4`, 5688715 B). Comparing the measured and final flattened compiler sources shows exactly one changed declaration: the cache codegen fingerprint literal. The measurements above are for the explicitly identified measured artifact, before this metadata correction.
The final artifact also passes all eight fresh-process policy scenarios. The normal bootstrap gate reruns the policy suites against its own rebuilt artifact.
