# TODO

Spec-locked decisions are tracked in `spec/decisions.md`.

## Next Up (Priority Order)

- Language improvement roadmap from `vibe/x/args` + `vibe/std` review (2026-02-14):
  - [x] 1. Stabilize cross-module trait import/export resolution. (Done: 2026-02-14)
    Remove caller-side trait re-declaration requirements for trait-bounded APIs.
  - [x] 2. Add reserved-keyword escape/raw identifier support. (Done: 2026-02-14)
    Enable canonical API names like `map` without `map_opt` / `map_ok` detours.
  - [x] 3. Reduce function-to-type-member forwarding boilerplate. (Done: 2026-02-14)
    Provide language-level sugar or auto-forwarding for `Type::method` wrappers.
  - [x] 4. Add linear-time array construction primitives. (Done: 2026-02-14)
    Introduce `ArrayBuilder`/`push`-style APIs to avoid repeated `array_concat`.
  - [x] 5. Introduce first-class `Char` and char literals. (Done: 2026-02-14)
    Reduce single-character `String`/`Int` ambiguity in parser/std code.
  - [x] 6. Add `String` / `Bytes` builder APIs. (Done: 2026-02-14)
    Avoid repeated `string_concat` patterns in loops and parsers.
  - [x] 7. Improve pattern-match ergonomics for sequence-heavy tests. (Done: 2026-02-15)
    Add `let Pat = expr else { body }` for flat pattern unwrapping.
  - [x] 8. Add `loop` expression with explicit tail-call optimization guarantees. (Done: 2026-02-15)
    Add `loop (x = init, ...) { break val; continue(args) }` compiling to WASM block/loop/br.
  - [x] 9. Revisit Int model portability (backend-independent integer surface). (Done: 2026-02-15)
    Expanded tagged Int range to 62-bit (-2^61 .. 2^61-1), added hex literal support (0xFF).
  - [x] 10. Add import/re-export simplification for forwarding modules. (Done: 2026-02-15)
    Support `export use`-style re-export to shrink facade boilerplate.

- Language UX hard-point triage (spec/examples review):
  - Done (2026-02-13): Add desugar ambiguity diagnostics for postfix/property
    access.
    When `expr.prop` can resolve as function-call desugar vs field access
    fallback, emit candidate-aware diagnostics and suggested disambiguation.
  - Done (2026-02-13): Add `vibe explain-import <entry>` to visualize
    `PathRef/HashRef/VersionRef/SymbolRef -> HashRef` normalization and lock
    lookups (`index.lock` hit/miss reasons).
  - Done (2026-02-13): Improve trait openness diagnostics.
    Distinguish sealed-trait, non-exported trait, and overlapping-impl failures
    with dedicated error codes/messages (`[TROP001]`/`[TROP002]`/`[TROP003]`).
  - Done (2026-02-14): Add formatter/lint quickfixes for grammar sharp edges.
    Auto-fix declaration separators (`;`), placeholder misuse context hints, and
    labeled-argument mistakes (`x~`/`y?`) where deterministic rewrites exist.
  - Done (2026-02-15): Split backend capability errors from language-level errors.
    Added `BackendLimit(backend~, feature~)` variant to `WasmGenError`,
    structured `user_message()` on `WasmCompileError`, and migrated ~30 codegen
    sites from `Unsupported` to `BackendLimit`.
- Done (2026-02-15): Implement explicit Text/Object conversion builtins:
  `string_join`, `from_lines`/`to_lines`, `from_json`/`to_json`,
  `from_jsonl`/`to_jsonl`, and JSON accessors (`json_type`, `json_get`,
  `json_index`, `json_string`, `json_number`, `json_bool`, `json_is_null`,
  `json_length`, `json_keys`) with opaque `Json` builtin type, typecheck,
  eval, and fixture tests.
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
- Runtime/Workspace stability follow-ups from 2026-02 review:
  - Done (2026-02-13): `eval` persistence mkdir behavior for nested DB paths.
  - Done (2026-02-13): `eval --export` mkdir behavior for nested output paths.
  - Done (2026-02-13): `vibe new` seeds `vibe/std` + `vibe/encoding` from the
    nearest ancestor `vibe/` and works immediately with std imports in that
    layout.
  - Done (2026-02-13): unknown namespace diagnostics in import resolution.
  - P3: Revisit `.vibe` fallback-to-cwd behavior on root mkdir failure.
    This can diverge lock root and storage root and should be validated or
    removed.

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
  Progress (2026-02-15): fixed importer namespace import resolution
  (`use std/option.vibe` via `index.vibe` + symlink) and codegen bug
  (match arm pattern binding kind `I32` → `I64` for non-js-string backend).
  `consumer_option_core` `unsupported -> wasm 1662`,
  `consumer_option_extra` `unsupported -> wasm 1792` (both with DCE).
  Progress (2026-02-15): fixed wasm backend Double/closure support for
  62-bit tagged values. Seven codegen bugs repaired: `value_kind_key_char`
  sig-key collision, closure env i32→i64 storage, `int_to_double`/
  `double_to_int` i32 truncation, `emit_unbox_f64/f32` temp local type,
  Block handler timing for `declare export let` wrappers, capture kind
  fallbacks.
  `consumer_double_core` `unsupported -> wasm 3251`,
  `consumer_double_rounding` `unsupported -> wasm 7521`.
  Importer totals: 14226 bytes (4/4 compiling).
  Examples totals: 41495 bytes (no-dce baseline unchanged).

### KPI Benchmark (2026-02-15)

| case | per_us | wasm_bytes | size_x_latency |
|------|--------|------------|----------------|
| pipeline_a | 0.528 | 1446 | 764 |
| pipeline_b | 0.539 | 1450 | 782 |
| pair_mix_ab | 0.579 | 1525 | 884 |
| cross_mix | 0.565 | 1571 | 887 |
| **avg** | **0.553** | **1498** | **829** |

### Bundle Size Snapshot (2026-02-15)

**Importers (wasm with DCE):**

| file | mode | bytes |
|------|------|-------|
| consumer_option_core | wasm | 1662 |
| consumer_option_extra | wasm | 1792 |
| consumer_double_core | wasm | 3251 |
| consumer_double_rounding | wasm | 7521 |

**Examples top 5 (wasm-no-dce):**

| file | bytes |
|------|-------|
| json.vibe | 28654 |
| base64.vibe | 6038 |
| basics.vibe | 1479 |
| module_import.vibe | 1383 |
| effects.vibe | 1051 |

## Deferred

- none
