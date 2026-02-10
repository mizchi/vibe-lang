# TODO

Spec-locked decisions are tracked in `spec/decisions.md`.

## Next Up (Priority Order)

- Language UX hard-point triage (spec/examples review):
  - P0 [done 2026-02-10]: Unify effect diagnostics for `effect-set` vs `do`
    boundary failures.
    `TypeError::EffectNotAllowed` was folded into
    `TypeError::EffectGuardNotSatisfied`, so effect-set failures and
    do-boundary failures now share one grouped diagnostic shape (hint/note with
    missing effect declaration + missing boundary when applicable). Updated
    related typecheck + fixture expectations.
  - P0 [done 2026-02-10]: Add a generics+effects fixture matrix (success/failure pairs).
    Added matrix fixtures covering higher-order wrappers with `with {e}`,
    localized `try/catch`, and mixed trait/effect call-shape mismatch cases:
    `generic_effect_matrix_ok_with_e_try_catch_localized`,
    `generic_effect_matrix_ok_trait_and_effect_bound`,
    `generic_effect_matrix_fail_missing_effect_at_caller`,
    `generic_effect_matrix_fail_trait_and_effect_mixed`.
  - P0 [done 2026-02-10]: Add PosixMode command-head desugar diagnostics.
    In `--syntax posix`, unresolved bare identifiers desugared to command heads
    now emit explicit runtime notes (`note: posix-mode command-head desugar: ...`)
    so migration behavior is visible in `run`/`repl` output.
  - P1: Add desugar ambiguity diagnostics for postfix/property access.
    When `expr.prop` can resolve as function-call desugar vs field access
    fallback, emit candidate-aware diagnostics and suggested disambiguation.
  - P1: Add `xsh explain-import <entry>` to visualize
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
    (for example wasm-js-string storage limits) vs invalid xsh programs.
- Implement explicit Text/Object conversion builtins:
  `from_lines` / `to_lines` and JSON-oriented variants (`from_json[l]`,
  `to_json[l]`) with typecheck + eval + docs + fixtures.
- Measure graph-index gains against current search path and remote transfer:
  run `just bench-advanced-graph`, collect
  `current_cli_like` vs `graph_snapshot/json_load`, and
  `apply_full_snapshot` vs `apply_delta` ratios on CI fixture sizes.
- Generalize symbol/type/signature indexing beyond xsh:
  extract language-agnostic graph IR (`symbol/type/signature/ref/call/import`),
  add `language_id`-aware storage keys, and define stable hash/id contracts for
  incremental updates.
- Add multi-language frontend adapters:
  implement a tree-sitter-based extractor as baseline and layer optional
  semantic providers (compiler/LSP) for type-resolution gaps; keep
  `xsh ide`/`xsh lsif` on the shared backend API.
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
- Grammar/language cleanup candidates (from std refactor & test split):
  - P0 [done 2026-02-09]: Fix `xsh fmt --write` parse-stability bugs for `*.xsh`.
    Formatter output is now parser-equivalent for the reproduced cases:
    `trait Eq` / `impl Eq for Int` spacing, quoted `test "name"`,
    string/char literal quote preservation, and import join spacing
    (`} from "./mod.xsh"`).
  - P0 [done 2026-02-09]: Add regression fixtures for formatter round-trip on xsh syntax forms:
    `import`, `trait/impl`, `test`, effect signatures (`with {..}`),
    and string-heavy assertions (see `src/parser/format_test.mbt`).
  - P1 [done 2026-02-09]: Allow trailing commas in import lists:
    `import { a, b, } from "./m.xsh"`.
    Parser now accepts trailing comma with trivia/newlines in named import lists.
  - P1 [done 2026-02-09]: Support local variable type annotations in bindings:
    `let x: T = expr`.
    Parser now accepts annotated local `let` bindings; fixtures cover both
    success and mismatch diagnostics.
  - P1 [done 2026-02-09]: Improve test-declaration UX:
    unquoted test names are now accepted (`test smoke_case { ... }`) while
    quoted names remain supported.
  - P1 [done 2026-02-09]: Reduce keyword collision friction (for `map`) via
    contextual keyword handling.
    `map { ... }` stays keyword syntax, while identifier positions
    (`let map = ...`, `map(...)`) now lex as `name`.
  - P2 [done 2026-02-09]: Improve import-parse diagnostics with targeted hints:
    import parser now distinguishes missing `from`, malformed list separators,
    and extra commas in import lists; trailing comma form is accepted.
  - P2 [done 2026-02-09]: Track existing syntax-adjacent gaps discovered during
    std port.
    `loop { ... }` expression is now implemented as `while true` desugar
    (`loop` is contextual keyword to avoid identifier collisions), mutable enum
    payload `mut` now emits a dedicated parse diagnostic, transitive
    cross-module trait import/export is covered by fixture regression
    (`trait_chain_base -> trait_chain_mid -> trait_import_chain`), and
    polymorphic recursion now emits a dedicated type diagnostic
    (`polymorphic_recursion_unsupported` fixture).
  - P2 [done 2026-02-09]: Revisit negative literal boundary UX for `Int`
    minimum value (`-2147483648`) with clearer parser error + optional future
    grammar design note.
    Parser now emits dedicated `IntMinLiteralBoundary` diagnostics with a
    focused rewrite hint and explanatory note.
- Show trait migration plan (prelude 常駐化):
  - P0 [done 2026-02-09]: Inventory/guardrail.
    fixture/std の `trait Show` / `impl Show` を棚卸しし、`show_to_string_method` と
    trait-bound 成功/失敗 fixture を prelude 前提で維持。
  - P0 [done 2026-02-09]: Compatibility period.
    `to_string` の prelude 提供を維持したまま、呼び出し側の移行を先行。
  - P1 [done 2026-02-09]: Source migration.
    `xsh/std/builtin_traits.xsh` と fixture 群から冗長な `trait Show` /
    primitive `impl Show` を削除し、unknown-bound 用 fixture は
    `MissingShow` に切り替え。
  - P1 [done 2026-02-09]: Prelude trait injection.
    checker prelude に `trait Show` + `Int/Float/Double/Bool/String` impl を追加し、
    `to_string` を `[T: Show]` へ戻した。
  - P2 [done 2026-02-09]: Cleanup/deprecation close.
    `index.lock` を更新し、`just check && just test` 緑を確認。

## Deferred

- none

## Bundle Size Plan (In Progress)

- [x] Add reproducible bundle-size measurement command:
  `just bench-bundle-size` / `just bench-bundle-size-update`.
- [x] Add compiler path for no-DCE wasm-js-string/gc emits and CLI `compile --no-dce`.
- [x] Add per-entry golden budget file:
  `bench/golden/bundle_size_budget.tsv`.
- [x] Reduce `xsh/std/test_import.xsh` transitive bundle size by importing
  smaller std surfaces (`int/option` -> `bool/float`).
  Current result: `4397 -> 1590` bytes (`wasm-no-dce` baseline).
- [ ] Reduce top offenders further without semantic regression:
  `examples/json.xsh`, `xsh/std/option.xsh`, `xsh/std/double.xsh`.
  Progress (2026-02-09): `examples/json.xsh` `10747 -> 10279`,
  `xsh/std/option.xsh` `4201 -> 3014`, `xsh/std/double.xsh` `2685 -> 2382`
  (`wasm-no-dce` / `wasm-js-string-no-dce`).
  Progress (2026-02-10): split JSON parser tests into `examples/json_test.xsh`
  and keep `examples/json.xsh` parser-only runtime surface;
  bundle-size bench now excludes `*_test.xsh` entries in `examples/` and
  `xsh/std/` so regressions track runtime surfaces only;
  `examples/json.xsh` `10279 -> 10227`, `xsh/std/option.xsh` `3014 -> 3014`,
  `xsh/std/double.xsh` `2278 -> 2271`.
  Progress (2026-02-10): reverted API-level extra split and restored
  single-module surfaces (`option.xsh` / `double.xsh`) to avoid
  superficial "module size only" optimization.
  Progress (2026-02-10): importer-level measurements (new
  `bench/bundle_size/*.xsh`) are now the primary benchmark focus:
  current baseline is
  `consumer_option_core` `850`,
  `consumer_option_extra` `1111`,
  `consumer_double_core` `unsupported(call local: abs)`,
  `consumer_double_rounding` `unsupported(call local: floor)`.
  `scripts/bench_bundle_size.sh` now prioritizes `bench/importers` with
  runtime-first mode (`wasm` -> `wasm-js-string` -> no-dce fallback);
  no-dce importer diagnostics are opt-in via
  `XSH_BUNDLE_BENCH_INCLUDE_IMPORTER_NO_DCE=1`;
  module-surface scan for `xsh/std/*.xsh` is opt-in via
  `XSH_BUNDLE_BENCH_INCLUDE_STD_SURFACES=1`.
  Case set / golden rules are now explicit via
  `bench/bundle_size/cases.txt` + `bench/bundle_size/README.md`.
- [x] Eliminate noisy abort-signal output in size benchmark fallback path
  (convert unsupported compile attempts to clean diagnostics).
  done 2026-02-10: `scripts/bench_bundle_size.sh` now captures failed compile
  probes via command substitution, so signal exits no longer emit shell
  `Abort trap` noise while unsupported entries remain visible in the report.
