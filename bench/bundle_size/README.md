# Product Bundle Size (Examples + Importers)

`bench/bundle_size/` is the **product-level bundle-size monitor**.
It measures live `examples/` plus use-case importer benchmarks.

## Case Set

Case entries are defined in `bench/bundle_size/cases.txt`.
Only files listed there are measured for `bench/importers`.

## Golden Rule

- Budget source: `bench/golden/bundle_size_budget.tsv` (product monitor)
- Rule: mode/bytes for each active case must not regress
- Mode change (e.g. `wasm` → `wasm-no-dce`) is treated as a budget change

## Syntax Migration vs Size Regression

Budget tracks two orthogonal axes:

| Axis | Trigger | Action |
|------|---------|--------|
| **Syntax migration** | Case moves from `unsupported` to a compilable mode | Update budget with actual bytes; commit as migration |
| **Size regression** | Compiled bytes increase beyond budget | Investigate cause; update budget only if justified |

When migrating a case from old syntax (e.g. `import` → `use`), commit the
syntax fix and budget update together as a migration, not as a size change.

## Examples Budget Rules

`examples/*.vibe` files are measured in `wasm-no-dce` mode (fallback chain).

| Change | Budget impact | Required action |
|--------|---------------|-----------------|
| New example file | New budget entry | Run `just bench-bundle-size-product-update` |
| Add test block to existing example | Size may grow | Accept if pedagogically motivated |
| Add function to existing example | Size grows | Accept if demonstrates new feature |
| Refactor without feature change | Size should not grow | Investigate if regression |
| Remove code from example | Size shrinks | Update budget to lock in improvement |

Principles:

1. **Examples are pedagogical, not minimal** — size growth is acceptable when it
   demonstrates a language feature or improves documentation value
2. **Budget is a ratchet** — size decreases should be locked in; increases need justification
3. **No silent drift** — every budget change must be an explicit commit

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
- `@vibe/builtin` surface scan is opt-in:
  `VIBE_BUNDLE_BENCH_INCLUDE_STD_SURFACES=1 just bench-bundle-size`
- Compiler-only fixed-fixture guard is separate:
  `just bench-bundle-size-compiler`
- Combined monitor runner (compiler strict + product non-fatal):
  `just bench-bundle-size-monitor`

## Std Baseline Snapshot

- `just bench-std-baseline-update` updates:
  - `bench/golden/bundle_size_budget.tsv` (with `@vibe/builtin` + importer no-dce groups)
  - `bench/golden/kpi_wasm.tsv`
