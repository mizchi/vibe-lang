# Scalar replacement of local mutable structs (#1934)

The fixture exercises fresh Int/Bool records without whole-object aliases.
`loop.vibe` reproduces the 10,000-object allocation check. The runtime harness
scales that same input to 50 million iterations and validates both the sum and
allocation count on every run. It includes runner startup in its walltime.

`results.json` records artifact/source identities, controlled compilation
measurements, runtime measurements, and verification. Compiler distribution
size and same-input generated Wasm size are separate measurements.

Run these commands from the repository root with `BASE_STAGE2` and
`CANDIDATE_STAGE2` pointing to explicit built artifacts. Each label must be new.
The baseline source commit is `548060725`.

```sh
python3 bench/perf/experiments/scalar-locals-1934/measure_compile.py "$PWD" "$BASE_STAGE2" "$CANDIDATE_STAGE2" lib/@vibe/compiler/cli_adapter.vibe --label sroa-compiler
python3 bench/perf/experiments/scalar-locals-1934/measure_compile.py "$PWD" "$BASE_STAGE2" "$CANDIDATE_STAGE2" lib/@vibe/compiler/tests/codegen_lexer_test.vibe --entry __no_entry__ --label sroa-kpi
python3 bench/perf/experiments/scalar-locals-1934/measure_runtime.py "$PWD" "$BASE_STAGE2" "$CANDIDATE_STAGE2" --label sroa-runtime
```

Both compilation comparisons use the same input checkout, isolated caches,
equal-length artifact/cache/output paths, and alternating A/B then B/A order.
The runtime comparison uses four runs per artifact after one untimed validation.
The commands require the repository's Node runner and Python 3.

## Measured result and adoption status

The implementation is limited to fresh, checker-proved non-capturing records whose declared fields are all Int or Bool and include a mutable field. A separate lexically scoped proof rejects whole-object uses. Missing typed rows, aliases, passing/returning the record, capture, whole-binding replacement, aggregate fields, and other scalar representations retain their existing heap behavior.

| Measurement | Baseline | Candidate |
| --- | ---: | ---: |
| Application wall median (4 runs, including startup) | 0.808 s | 0.258 s |
| 10,000-record allocation | 240,000 B | 0 B |
| 50-million-record allocation | 1,200,000,000 B | 0 B |
| Standard KPI cold heap_ptr | 1,125,311,312 B | 1,123,513,584 B |
| Standard KPI warm heap_ptr | 642,917,872 B | 643,134,272 B |
| CLI cold heap_ptr | 2,455,517,704 B | 2,451,736,736 B |
| CLI warm heap_ptr | 1,391,824,000 B | 1,391,820,888 B |
| Target application Wasm | 8,676 B | 8,581 B |
| Compiler distribution Wasm | 5,495,121 B | 5,513,007 B |

Both compilation corpora produce byte-identical Wasm across all 12 compiles each: standard KPI 4,331,499 B, CLI 6,238,876 B. Compiler distribution size and same-input generated Wasm size are separate measurements.

Standard KPI wall medians are 7.209 -> 7.351 s cold and 4.499 -> 4.552 s warm. No compiler-speed improvement is established. Both compilation comparisons and application runtime timing were isolated from other compiler/test runs.

Stage2 equals stage3. All 18 semantic/allocation tests pass with RC=0, RC=1, and RC=shadow, cold and warm. Fallback controls produce byte-identical Wasm in all three modes, and five rejection diagnostics are unchanged. The documented-declarations check passes.

**Draft: the no-regression adoption criterion in #1934 is not met.** Warm standard-KPI allocation grows by 216,400 B (0.034%), CLI warm allocation changes by -3,112 B (-0.00022%), and compiler distribution size grows by 17,886 B (0.325%). Those costs must be resolved or explicitly accepted before merging or closing #1934.
