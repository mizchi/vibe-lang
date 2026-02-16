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
    Corrected labels: arity errors reverted to `Unsupported` (internal, not
    backend constraints); shared codegen paths now use dynamic backend label
    based on `ctx.use_js_strings` (operator/if/try kind mismatch,
    `resolve_numeric_kind`).
- Done (2026-02-15): Implement explicit Text/Object conversion builtins:
  `string_join`, `from_lines`/`to_lines`, `from_json`/`to_json`,
  `from_jsonl`/`to_jsonl`, and JSON accessors (`json_type`, `json_get`,
  `json_index`, `json_string`, `json_number`, `json_bool`, `json_is_null`,
  `json_length`, `json_keys`) with opaque `Json` builtin type, typecheck,
  eval, and fixture tests.
- Done (2026-02-15): Measure graph-index gains against current search path and
  remote transfer. Benchmark results (`just bench-advanced-graph`, 21 cases):

  | Scenario | Time | Speedup vs baseline |
  |----------|------|---------------------|
  | `current_cli_like` (baseline) | 330.73 ms | 1x |
  | `graph_snapshot_query` | 132.73 µs | **2492x** |
  | `graph_json_load_query` | 1.49 ms | **222x** |

  | Format | Full Snapshot | Delta | Delta speedup |
  |--------|--------------|-------|---------------|
  | JSON | 1.47 ms | 1.21 ms | 1.2x |
  | CBOR | 2.53 ms | 1.83 ms | 1.4x |
  | Flexbuffer | 4.25 ms | 3.75 ms | 1.1x |

- Done (2026-02-15): Generalize symbol/type/signature indexing beyond vibe:
  added `language_id` to `AdvancedGraphDef`, `language_ids` to manifest,
  language-aware index keys (`"vibe::symbol::foo"`), `language_id?` query
  filtering, `build_advanced_graph_index_from_ir` builder, and updated
  JSON/Flatbuffer codecs with mixed-language test.
- Add multi-language frontend adapters:
  implement a tree-sitter-based extractor as baseline and layer optional
  semantic providers (compiler/LSP) for type-resolution gaps; keep
  `vibe ide`/`vibe lsif` on the shared backend API.
- Expand object pipeline operators on typed rows:
  add first-class `where/select` contracts over record-like objects and align
  parser/desugar/typecheck behavior for `|>` chains.
- Done (2026-02-15): Harden PosixMode compatibility guardrails:
  added 7 regression tests (bare command desugar, echo pipeline, nested scope
  shadows, builtin names preserved, unknown command error, multiple desugars,
  let binding prevents desugar).
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
  - Done (2026-02-15): Removed `.vibe` fallback-to-cwd behavior on root mkdir
    failure. Now aborts with clear error message instead of silently diverging
    lock root and storage root.

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

## vibe/http 残課題 (2026-02-16)

- [ ] WASM codegen: HTTP builtins は現在 `unreachable` trap を emit。WASI P3 HTTP (`wasi:http@0.3.0-draft`) が安定したら実装する
  - Client: `wasi:http/handler.handle` で outgoing-request 送信
  - Server: `wasi:http/handler` export で incoming-request 受信 (wasmtime serve 連携)
- [ ] WASM server (http_listen/accept/respond): Phase 2。インタプリタのみ動作
- [ ] HTTPS/TLS 非対応: HTTP のみ (port 80 デフォルト)
- [ ] IPv4 のみ: DNS 解決・IPv6 未対応。`inet_pton` でリテラル IP のみ
- [ ] `moon info` で mbti 自動再生成ができない (手動で `pkg.generated.mbti` を編集した)
  - 原因: `--deny-warn` が `unused_constructor` を error にするため `moon info` が失敗する循環依存
  - 回避: mbti を先に手動更新してから check を通す

## Deferred

- none
