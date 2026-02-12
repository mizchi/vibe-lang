# TODO

Spec-locked decisions are tracked in `spec/decisions.md`.

## Next Up (Priority Order)

- Language UX hard-point triage (spec/examples review):
  - P1: Add desugar ambiguity diagnostics for postfix/property access.
    When `expr.prop` can resolve as function-call desugar vs field access
    fallback, emit candidate-aware diagnostics and suggested disambiguation.
  - P1: Add `vibe explain-import <entry>` to visualize
    `PathRef/HashRef/VersionRef/SymbolRef -> HashRef` normalization and lock
    lookups (`index.lock` hit/miss reasons).
  - P1: Improve trait openness diagnostics.
    Distinguish sealed-trait, non-exported trait, and overlapping-impl failures
    with dedicated error codes/messages.
  - P2: Add formatter/lint quickfixes for grammar sharp edges.
    Auto-fix declaration separators (`;`), placeholder misuse context hints, and
    labeled-argument mistakes (`x~`/`y?`) where deterministic rewrites exist.
  - P2: Split backend capability errors from language-level errors.
    `compile` diagnostics should clearly classify unsupported backend features
    (for example wasm-js-string storage limits) vs invalid vibe programs.
- Implement explicit Text/Object conversion builtins:
  `from_lines` / `to_lines` and JSON-oriented variants (`from_json[l]`,
  `to_json[l]`) with typecheck + eval + docs + fixtures.
- Measure graph-index gains against current search path and remote transfer:
  run `just bench-advanced-graph`, collect
  `current_cli_like` vs `graph_snapshot/json_load`, and
  `apply_full_snapshot` vs `apply_delta` ratios on CI fixture sizes.
- Generalize symbol/type/signature indexing beyond vibe:
  extract language-agnostic graph IR (`symbol/type/signature/ref/call/import`),
  add `language_id`-aware storage keys, and define stable hash/id contracts for
  incremental updates.
- Add multi-language frontend adapters:
  implement a tree-sitter-based extractor as baseline and layer optional
  semantic providers (compiler/LSP) for type-resolution gaps; keep
  `vibe ide`/`vibe lsif` on the shared backend API.
- Expand object pipeline operators on typed rows:
  add first-class `where/select` contracts over record-like objects and align
  parser/desugar/typecheck behavior for `|>` chains.
- Harden PosixMode compatibility guardrails:
  add regression fixture set for POSIX-text behavior (`|`, quoting, redirects),
  and ensure object ops require explicit `|>` + conversion boundaries.
- Replace `sh_lines` preview backend with host-backed execution strategy:
  native target uses real process output capture; non-native targets keep
  deterministic fallback semantics with explicit capability diagnostics.
- Add syntax profile controls:
  evaluate `--syntax posix-strict` vs `posix-ext` split and wire diagnostics so
  teams can enforce strict compatibility in CI.

## Bundle Size Plan (In Progress)

- Reduce top offenders further without semantic regression:
  `examples/json.vibe`, `vibe/std/option.vibe`, `vibe/std/double.vibe`.
  Progress (2026-02-09): `examples/json.vibe` `10747 -> 10279`,
  `vibe/std/option.vibe` `4201 -> 3014`, `vibe/std/double.vibe` `2685 -> 2382`
  (`wasm-no-dce` / `wasm-js-string-no-dce`).
  Progress (2026-02-10): split JSON parser tests into `examples/json_test.vibe`
  and keep `examples/json.vibe` parser-only runtime surface;
  bundle-size bench now excludes `*_test.vibe` entries in `examples/` and
  `vibe/std/` so regressions track runtime surfaces only;
  `examples/json.vibe` `10279 -> 10227`, `vibe/std/option.vibe` `3014 -> 3014`,
  `vibe/std/double.vibe` `2278 -> 2271`.
  Progress (2026-02-10): reverted API-level extra split and restored
  single-module surfaces (`option.vibe` / `double.vibe`) to avoid
  superficial "module size only" optimization.
  Progress (2026-02-10): importer-level measurements (new
  `bench/bundle_size/*.vibe`) are now the primary benchmark focus:
  current baseline is
  `consumer_option_core` `850`,
  `consumer_option_extra` `1111`,
  `consumer_double_core` `unsupported(call local: abs)`,
  `consumer_double_rounding` `unsupported(call local: floor)`.
  `scripts/bench_bundle_size.sh` now prioritizes `bench/importers` with
  runtime-first mode (`wasm` -> `wasm-js-string` -> no-dce fallback);
  no-dce importer diagnostics are opt-in via
  `VIBE_BUNDLE_BENCH_INCLUDE_IMPORTER_NO_DCE=1`;
  module-surface scan for `vibe/std/*.vibe` is opt-in via
  `VIBE_BUNDLE_BENCH_INCLUDE_STD_SURFACES=1`.
  Case set / golden rules are now explicit via
  `bench/bundle_size/cases.txt` + `bench/bundle_size/README.md`.

## Deferred

- none
