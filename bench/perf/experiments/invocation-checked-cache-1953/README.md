# Scoped checked-module cache modes (#1953)

Baseline: `425c7b918`, after merged #3913. `CheckedModuleCachePolicy` is an opaque immutable choice of `off`, `verify` or `on`. A dedicated `CheckedModuleCacheConfig::Mode` effect captures and validates it once, without granting target-flag, source-trust, tracing or filesystem authority.

Explicit load, commit and statement-handoff entries consume policy plus a retained namespace. Only on reuses disk artifacts. Off loads, publishes and hands out nothing. Verify requires a fresh result, rejects a valid byte mismatch, repairs malformed entries and avoids rewriting canonical bytes. Legacy APIs retain their existing low-level behavior, including direct loads and fresh publication with mode off. Mutable cache reset/contents and full walk/CLI policy propagation remain separate work.

## Controlled measurements

96 serial process samples: own-source/off, same-candidate-source/off, same-source/on and same-source/verify. N=3 for compiler KPI and CLI, cold then fresh-process warm, AB/BA/AB. A/B use exactly the same literal root, compiler, cache and output paths. Own/off and same/off reuse the original work path by moving completed receipts aside.

| Source / mode | Corpus | Cache | Heap pointer baseline → candidate | Change | Wall baseline → candidate |
| --- | --- | --- | --- | --- | --- |
| Own / off | kpi | cold | 1,176,376,224 → 1,176,394,152 B | +0.001524% | 8.990 → 9.053 s |
| Own / off | kpi | warm | 652,921,672 → 652,930,696 B | +0.001382% | 4.760 → 4.744 s |
| Own / off | cli | cold | 2,548,491,224 → 2,551,419,824 B | +0.114915% | 19.124 → 19.029 s |
| Own / off | cli | warm | 1,391,915,312 → 1,393,989,136 B | +0.148991% | 10.625 → 10.764 s |
| Same / off | kpi | cold | 1,176,376,224 → 1,176,394,152 B | +0.001524% | 8.938 → 9.113 s |
| Same / off | kpi | warm | 652,921,672 → 652,930,696 B | +0.001382% | 4.826 → 4.804 s |
| Same / off | cli | cold | 2,551,402,056 → 2,551,419,824 B | +0.000696% | 19.032 → 19.175 s |
| Same / off | cli | warm | 1,393,981,640 → 1,393,989,136 B | +0.000538% | 10.699 → 10.674 s |
| Same / on | kpi | cold | 1,580,092,704 → 1,580,105,648 B | +0.000819% | 10.433 → 10.469 s |
| Same / on | kpi | warm | 1,596,676,624 → 1,596,683,648 B | +0.000440% | 8.180 → 8.059 s |
| Same / on | cli | cold | 3,495,931,240 → 3,495,945,744 B | +0.000415% | 22.266 → 22.476 s |
| Same / on | cli | warm | 3,438,455,392 → 3,438,461,720 B | +0.000184% | 18.899 → 18.774 s |
| Same / verify | kpi | cold | 1,580,122,328 → 1,580,135,504 B | +0.000834% | 10.160 → 10.083 s |
| Same / verify | kpi | warm | 1,614,721,576 → 1,614,728,496 B | +0.000429% | 10.092 → 10.202 s |
| Same / verify | cli | cold | 3,495,966,568 → 3,495,981,160 B | +0.000417% | 21.823 → 21.964 s |
| Same / verify | cli | warm | 3,447,380,432 → 3,447,386,648 B | +0.000180% | 22.140 → 22.269 s |

Own-source CLI allocation increases by 2,928,600 B cold / 2,073,824 B warm. With the same input and matching off settings/paths those differences are 17,768 B / 7,496 B. The source-growth cost is therefore separated from the implementation comparison. All 72 same-source samples produce byte-identical Wasm; heap changes stay below +0.002% in every same-source case. Own-source outputs are stable within each revision. Wall differences are small and advisory; no speedup is claimed.

Heap pointers include static base and cumulative bump allocation. They measure neither live memory/RSS nor the CI selfcompile peak. Mode rows compare the change within each mode; they are not a recommendation to enable a cache mode. Artifacts: 5,686,121 → 5,686,370 B. Candidate stage2/stage3 match (`d2d062d3c4f1a5dcfd6d1f3d687a51c767df9ad790371716154b77d36dba572d`) and validate as Wasm. Sources and SDKs were frozen before measurement.

## Correctness

The policy suites contain ten source cases / 37 harness exports including dependency inspections. Four exact-candidate matrices pass: default plus legacy and codec suites (45); AST/stamp enabled with the earlier policy suite (63); RC with legacy/codec suites (45); RC-shadow with codec coverage (41). Counts overlap. Bootstrap runs the new boundary suite against its own fresh stage2.

Twelve injected faults compile, validate as Wasm and fail at runtime: ambient mode capture; duplicate capture; verify reuse; off publication; ambient verify selection; commit without a fresh check under verify; rewriting canonical bytes; ambient handoff selection; foreign-source handoff; ambient namespace lookup; ignoring context validation; and aliasing the returned statement array. Production/test hashes verify restoration. A missing mode-effect row is refused at compile time with an actionable diagnostic. Positive handoff helpers require neither Env nor Fs.

The [fresh-process driver](check_policy.py) compiles [the probe](cache_probe.vibe) and runs fourteen scenarios: off cold, on cold/warm, off warm, verify warm, malformed on/verify, source edit and warm reuse, valid-artifact poisoning and verify refusal, recovery, and another namespace cold/warm. Compatibility mode and namespace deliberately disagree with the supplied policy/data. Canonical verify does not change the file timestamp; off leaves a warm file untouched. Valid mismatches leave disk bytes unchanged.

Nested handlers test exact capture counts and restoration after both successful and failing inner requests. Data tests preserve exact input/source/context validation, namespace separation, defensive handoff copies and reset invalidation. Policy isolates mode, not mutable cache ownership: callers still own/reset each serial walk. This does not complete #1953 or authorize concurrent compiler walks.

[results.json](results.json) retains all samples, output digests, fault changes and failures, source hashes, matrices, static refusal and functional receipts.

## Reproduction

```sh
python3 bench/perf/experiments/invocation-checked-cache-1953/check_policy.py \
  CANDIDATE_ROOT CANDIDATE_STAGE2 OUTPUT_PROBE
python3 bench/perf/experiments/invocation-checked-cache-1953/measure_integration.py \
  BASE_ROOT CANDIDATE_ROOT BASE_STAGE2 CANDIDATE_STAGE2 OUTPUT_OWN \
  --checked-module-cache off
python3 bench/perf/experiments/invocation-checked-cache-1953/measure_integration.py \
  BASE_ROOT CANDIDATE_ROOT BASE_STAGE2 CANDIDATE_STAGE2 OUTPUT_SAME \
  --same-source --checked-module-cache MODE
```

Stage each snapshot and regenerate its SDK first. Use new output directories, explicit artifacts and serial runs. Repeat the same-source command for off, on and verify. Reuse the literal own/off output path for same/off only after moving the completed receipts aside.
