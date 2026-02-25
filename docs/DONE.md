# Done

Completed items archived from `TODO.md`.

## 2026-02-18

- Remove `try/catch` and `await` syntax from the compiler.
  `handle` expression replaces try/catch; `await` removed (async fn uses implicit await).
  All 30+ files updated across parser, core, checker, runtime, codegen, frontend, CLI.

## 2026-02-15

- Split backend capability errors from language-level errors.
  Added `BackendLimit(backend~, feature~)` to `WasmGenError`, structured `user_message()`,
  migrated ~30 codegen sites.
- Implement Text/Object conversion builtins:
  `string_join`, `from_lines`/`to_lines`, `from_json`/`to_json`, `from_jsonl`/`to_jsonl`,
  JSON accessors with opaque `Json` builtin type.
- Generalize symbol/type/signature indexing beyond vibe:
  `language_id` in `AdvancedGraphDef`, language-aware index keys, multi-language test.
- Harden PosixMode compatibility guardrails: 7 regression tests.
- Graph-index benchmarks: snapshot query **2492x** faster than CLI-like baseline.
- `loop` expression with explicit tail-call optimization (WASM block/loop/br).
- Pattern-match ergonomics: `let Pat = expr else { body }`.
- Int model: 62-bit tagged range, hex literal support (0xFF).
- Import/re-export simplification: source-qualified re-export (`export <module-ref> { ... }`).
- Removed `.vibe` fallback-to-cwd on root mkdir failure.
- Bundle size: fixed importer namespace import resolution, 7 codegen bugs for
  Double/closure/62-bit tagged values. Importer totals: 14226 bytes (4/4 compiling).

## 2026-02-14

- Cross-module trait import/export resolution stabilized.
- Reserved-keyword escape/raw identifier support.
- Function-to-type-member forwarding boilerplate reduction.
- Linear-time array construction primitives (`ArrayBuilder`/`push`).
- First-class `Char` and char literals.
- `String` / `Bytes` builder APIs.
- Formatter/lint quickfixes for grammar sharp edges.

## 2026-02-13

- Desugar ambiguity diagnostics for postfix/property access.
- `vibe explain-import <entry>` for lock lookup visualization.
- Trait openness diagnostics (`[TROP001]`/`[TROP002]`/`[TROP003]`).
- `eval` persistence mkdir for nested DB/export paths.
- `vibe new` seeds `vibe/prelude` + `vibe/json` + `vibe/base64` + `vibe/sha1` from nearest ancestor.
- Unknown namespace diagnostics in import resolution.
