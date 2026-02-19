# Product Bundle Size (Examples + Importers)

`bench/bundle_size/` is the **product-level bundle-size monitor**.
It measures live `examples/` plus use-case importer benchmarks.

## Case Set

Case entries are defined in `bench/bundle_size/cases.txt`.
Only files listed there are measured for `bench/importers`.

## Golden Rule

- Budget source: `bench/golden/bundle_size_budget.tsv` (product monitor)
- Rule: mode/bytes for each active case must not regress
- `unsupported` is an explicit baseline (mode change is treated as a budget change)

## Update Flow

1. Edit a case or add/remove case paths in `cases.txt`
2. Run `just bench-bundle-size-product-update` (or `just bench-bundle-size-update`)
3. Re-run `just bench-bundle-size-product` (or `just bench-bundle-size`) and ensure green

## Notes

- Default groups: `examples`, `bench/importers`
- `bench/importers` is measured in **runtime mode first**
  (`wasm` -> `wasm-js-string` -> `wasm-no-dce` fallback)
- Optional no-dce diagnostic group:
  `VIBE_BUNDLE_BENCH_INCLUDE_IMPORTER_NO_DCE=1 just bench-bundle-size`
- `vibe/std` surface scan is opt-in:
  `VIBE_BUNDLE_BENCH_INCLUDE_STD_SURFACES=1 just bench-bundle-size`
- Compiler-only fixed-fixture guard is separate:
  `just bench-bundle-size-compiler`
- Combined monitor runner (compiler strict + product non-fatal):
  `just bench-bundle-size-monitor`

## Std Baseline Snapshot

- `just bench-std-baseline-update` updates:
  - `bench/golden/bundle_size_budget.tsv` (with `vibe/std` + importer no-dce groups)
  - `bench/golden/kpi_wasm.tsv`
  - `bench/golden/kpi_interpreter.tsv`
