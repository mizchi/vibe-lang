# TODO

## Locked Decisions

- Trait model is nominal and marker-only in v0 (no trait methods, associated
  types, or trait objects yet).
- Trait bounds are conjunctive and explicit:
  `[T: A + B]` and inline `x: T: A + B`.
- Trait usage across modules is explicit import/export only.
  No implicit trait leakage.
- Openness syntax is fixed:
  `export trait` = sealed,
  `export open trait` = external impl allowed,
  `open trait` without `export` = syntax error.
- Trait hierarchy is enabled (`trait Ord: Eq`) and checked transitively.
- `derive(TraitA, TraitB)` on `struct`/`enum` is supported for core traits;
  unknown traits are rejected.
- Trait import rename keeps canonical source identity and preserves
  supertrait chains.
- Subtyping exists as an internal model for API compatibility checks
  (`Concrete <: Trait` relation + function variance/effects).
- Bound compatibility policy is fixed:
  tighter bounds = Major, looser bounds = Minor.
- Type naming policy is fixed:
  default user types are CamelCase; wasm builtin primitives may use
  lowercase (`i32`, `f32`, `f64`) and are reserved.
- Formatting policy is fixed:
  enum variant separator is canonicalized to `;`,
  struct literal style is canonicalized to `Type::{ ... }`,
  formatter must be idempotent.
- Declaration separator policy is fixed:
  `enum` variants and `struct` fields use `;`.
  Comma separators are parse errors (formatter may still normalize CST input).
- `Int` min-literal boundary policy is fixed:
  `-2147483648` is rejected as parse-time overflow
  (unary minus does not extend positive literal range).
- WASM stdio target policy is fixed:
  standard I/O APIs are defined against `wasi:io` (preview2/component path),
  not split across dual core/component profiles.
- API semver checks target exported symbols only.
- LSP provides trait import quickfixes for unresolved bounds
  (`Eq`/`Ord` and alias-like names mapped to them).
- Fixture runner supports import-based fixtures (no `"TODO": true` required
  for cross-module cases).
- Module identity model is fixed to Unison-style layered references:
  normalized code stores hash refs as source of truth, while version refs and
  symbols are user-facing aliases.
- Pure definition immutability is fixed:
  once a pure function is stored by content hash, it is never mutated in-place;
  updates are expressed as new hash + alias/version rebinding.
- Edit/readability policy is fixed:
  `edit` rehydrates human-readable symbols from namespace/lock metadata, and
  falls back to `name#hash` when disambiguation is required.
- Dependency source representation is fixed to Nix-like normalized `Path`
  objects:
  imports resolve through canonicalized path objects (not raw strings), then
  map to content hash/module refs.
- Canonical reference schema is fixed in spec:
  conversion and normalization rules among `PathRef` / `HashRef` /
  `VersionRef` / `SymbolRef` are documented in `docs/xsh.md`.
- Path object schema and lock key format are fixed in spec:
  `PathObj(raw/base/normalized)` and lock keys (`__hash__/...`,
  `__ref__/version/...`, `__ref__/symbol/...`) are documented in
  `docs/xsh.md`.
- Spec authority is fixed:
  `docs/xsh.md` is normative; proposal/draft content lives in dedicated design
  docs.
- Module syntax documentation is aligned with implementation:
  named import + explicit export forms are canonical; legacy bare import forms
  are non-spec.
- Parser dispatch policy is fixed in spec and CLI behavior:
  parser-consuming commands use explicit `--syntax xsh|posix` switch
  (default `xsh`) with no automatic fallback.
  `posix` is preview-enabled only for runtime-eval commands
  (`run`/`repl`/`repl-stdin`/`repl-wasi`/`bench`) and rejected on
  static/compile-oriented commands.
- PosixMode runtime preview semantics are fixed:
  `Runtime::eval_script_with_mode(..., PosixMode)` desugars unresolved
  command-like bare identifiers to `sh_lines("<name>")`, while preserving bound
  identifiers (`let`/params/pattern/import names).
- Docs index references are fixed:
  `README.md` now points to existing language/design documents with status.
- Effects semantics are fixed in spec:
  effect-set requirement and `do` boundary requirement are independent checks;
  `do` does not grant missing effects, while declared function effects can allow
  direct effectful calls under current implementation rules.
- Hashing and IR documentation is fixed to current implementation:
  module content hash is Git blob `sha1` over canonical S-expression output, and
  IR schema/examples are aligned to `module_to_sexp` serializer output.
- Missing language chapters for implemented features are fixed in spec:
  `docs/xsh.md` now documents trait/impl rules, struct/enum details,
  placeholder lambda shorthand, `while`/`yield`, and method-call desugaring.
- Generated builtin contract table is published:
  `docs/builtin_contract_table.generated.md` is generated from checker/eval/wasm
  sources by `scripts/gen_builtin_contract_table.mjs` (also exposed as
  `just gen-builtin-contract-table`).
- Import cycle reporting is implemented for path imports:
  import graph cycles are diagnosed in `stage: "import"` with `import cycle:`
  messages.
- Lock workflow is implemented in CLI/runtime flow:
  `xsh fetch`/`xsh update-lock` maintain `xsh.lock` (`path`/`version`/`symbol`
  maps), path imports are validated against lock entries when enabled, and
  import diagnostics are compile-fatal.
- SyntaxKind token id uniqueness is fixed for parser stability:
  keyword and operator token kinds must not share raw ids
  (guarded by parser tests for `await`/`yield` vs `%`/`+=`).
- Loop control semantics are implemented end-to-end:
  `break` / `continue` parse as dedicated expressions, are type-checked
  as while-only controls, and are supported in evaluator + canonical IR/docs.
- xshell object pipeline compatibility model is fixed:
  `|` is text-lane only, `|>` is object-lane only, and text/object boundary
  crossing must be explicit conversion calls.
  Design memo is tracked in `spec/xshell.md`.
- Symbol/type/signature indexing backend is implemented and shared:
  `xsh ide` (`outline`/`peek-def`/`search`) and `xsh lsif` consume the same
  module-level symbol index (`src/xsh/symbol_index.mbt`).
- Advanced graph extension PoC is implemented on xsh side:
  `xsh index` (`build`/`query`/`verify`) provides a sidecar JSON index
  (`src/xsh/advanced_graph_poc.mbt`) that models manifest + def graph +
  symbol/type lookup tables.
- Advanced graph diff/apply path is implemented for remote sync PoC:
  delta payload (`AdvancedGraphDelta`) can be computed/applied and
  serialized as JSON for transfer simulation.
- Bundle-size guardrail workflow is implemented:
  `scripts/bench_bundle_size.sh` compiles `examples/*.xsh` and
  `xsh/std/*.xsh` with mode precedence
  (`wasm-no-dce` -> `wasm-js-string-no-dce` -> `wasm` -> `wasm-js-string`),
  stores current metrics in `dist/bundle_size/current.tsv`, and enforces
  per-entry golden budgets from `bench/golden/bundle_size_budget.tsv`.

## Next Up (Priority Order)

- Language UX hard-point triage (spec/examples review):
  - P0: Unify effect diagnostics for `effect-set` vs `do` boundary failures.
    Emit a single grouped diagnostic that explains both missing declarations and
    missing effect-allowed context with one fix path.
    Coverage targets: `examples/effects.xsh` style wrappers and
    `docs/xsh.md` effect examples.
  - P0: Add a generics+effects fixture matrix (success/failure pairs).
    Include higher-order wrappers with `with {e}`, localized `try/catch`, and
    mixed trait-bound + effect-bound failures so users can see minimal patterns.
  - P0: Add PosixMode command-head desugar diagnostics.
    In `--syntax posix`, when an unresolved bare identifier is desugared to a
    command head (`sh_lines("<name>")`), surface an explicit note so behavior is
    predictable during migration.
  - P1: Add desugar ambiguity diagnostics for postfix/property access.
    When `expr.prop` can resolve as function-call desugar vs field access
    fallback, emit candidate-aware diagnostics and suggested disambiguation.
  - P1: Add `xsh explain-import <entry>` to visualize
    `PathRef/HashRef/VersionRef/SymbolRef -> HashRef` normalization and lock
    lookups (`xsh.lock` hit/miss reasons).
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
- [ ] Eliminate noisy abort-signal output in size benchmark fallback path
  (convert unsupported compile attempts to clean diagnostics).
