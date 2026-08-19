# Locked Decisions

Status: accepted and moved from `TODO.md`.

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
  `-2305843009213693952` is rejected as parse-time overflow
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
  `VersionRef` / `SymbolRef` are documented in `docs/vibe.md`.
- Path object schema and lock key format are fixed in spec:
  `PathObj(raw/base/normalized)` and lock keys (`__hash__/...`,
  `__ref__/version/...`, `__ref__/symbol/...`) are documented in
  `docs/vibe.md`.
- Spec authority is fixed:
  `docs/vibe.md` is normative; proposal/draft content lives in dedicated design
  docs.
- Module syntax documentation is aligned with implementation:
  named import + explicit export forms are canonical; legacy bare import forms
  are non-spec.
- Import keyword policy is fixed:
  `use` is removed from surface syntax; canonical import form is
  `import <module-ref> { ... }` only.
- Parser dispatch policy is fixed in spec and CLI behavior:
  parser-consuming public CLI commands use explicit `--syntax vibe`
  (default `vibe`) with no automatic fallback.
  Posix parser mode remains internal/runtime-only and is not exposed on the
  public CLI surface.
- Internal PosixMode preprocessing/desugar semantics are fixed:
  unresolved command-like bare identifiers are rewritten to
  `sh_lines("<name>")`, while preserving bound identifiers
  (`let`/params/pattern/import names).
- Docs index references are fixed:
  `README.md` now points to existing language/design documents with status.
- Effects semantics are fixed in spec:
  effect-set requirement and `do` boundary requirement are independent checks;
  `do` does not grant missing effects, while declared function effects can allow
  direct effectful calls under current implementation rules.
- Local mutation semantics are fixed for deterministic hashing:
  `let mut` is treated as lexical-scope local state (not externally observable
  side effects), `Ref[T]` is introduced with no-escape constraints
  (no return/export/persistent store, no crossing `await`/`spawn`,
  no function-parameter declaration in Phase 1),
  user-facing local mutation defaults to `let mut` in Phase 1,
  and lightweight effect tiering (`pure` / `state_local` / `impure`) is adopted
  as the policy direction without requiring Rust-grade ownership types.
- Hashing and IR documentation is fixed to current implementation:
  module content hash is Git blob `sha1` over canonical S-expression output, and
  IR schema/examples are aligned to `module_to_sexp` serializer output.
- Missing language chapters for implemented features are fixed in spec:
  `docs/vibe.md` now documents trait/impl rules, struct/enum details,
  placeholder lambda shorthand, `while`/`yield`, and member/index/pipe call
  forms.
- Historical builtin contract table is retained:
  `docs/builtin_contract_table.generated.md` was generated from the retired MoonBit
  host sources. Its generator/task no longer exists after the selfhost cutover; the
  current compiler's builtin definitions and accepted/proposed ADRs are authoritative.
- Import cycle reporting is implemented for path imports:
  import graph cycles are diagnosed in `stage: "import"` with `import cycle:`
  messages.
- Lock workflow is implemented in CLI/runtime flow:
  `vibe fetch`/`vibe update-lock` maintain `index.lock`
  (`path`/`version`/`symbol`/`module`/`annotation` maps), path imports are
  validated against lock entries when enabled, and import diagnostics are
  compile-fatal.
  `index.vibe` root registry now requires
  `export let version = "<semver>"` (simple `x.y.z` form).
- Scratch workflow alias resolution is fixed for local registry usage:
  persisted sources containing `import @vibe/builtin@<version>.vdb` resolve
  aliases from `VIBE_LIB_DIR` (fallback `$HOME/.vibe/lib`), and `.vdb` can
  point to object content via `hash:<sha1>` / `{ "hash": "<sha1>" }`.
- Advanced graph distributed refs workflow is introduced:
  snapshot/delta payloads can be stored as git/bit objects and addressed by
  refs under `refs/bit/index/<scope>/graph/(head|wal_head)`.
- SyntaxKind token id uniqueness is fixed for parser stability:
  keyword and operator token kinds must not share raw ids
  (guarded by parser tests for `await`/`yield` vs `%`/`+=`).
- Loop control semantics are implemented end-to-end:
  `break` / `continue` parse as dedicated expressions, are type-checked
  as while-only controls, and are supported in evaluator + canonical IR/docs.
- vibe shell object pipeline compatibility model is fixed:
  `|` is text-lane only, `|>` is object-lane only, and text/object boundary
  crossing must be explicit conversion calls.
  Design memo is tracked in `archive/spec/vibe-shell.md`.
- Pipe-first call desugaring policy is fixed (ADR-0020):
  `x |> f` is shorthand of `x |> f()`, and `x |> f(a, b)` desugars to
  `f(x, a, b)`.
- Pipe lowering phase policy is fixed:
  `|>` desugaring is performed in parser (AST construction) rather than in
  evaluator/codegen fallback layers.
- Pipeline ambiguity policy is fixed (ADR-0020):
  expressions that mix `|>` with other infix operators without explicit
  parentheses are parse errors
  (for example `1 + 1 |> double`).
- Dot access policy is fixed (ADR-0020):
  `.` is limited to data member access (struct/record/tuple index), method-call
  sugar (`recv.method(...)`) is removed, and function-value field calls must use
  `(obj.method)(...)`.
- Namespace symbol identity policy is fixed (ADR-0020):
  canonical names use `Type::symbol`,
  fully qualified symbols use `/pkg@version/module/Type::symbol`,
  and internal address refs use `<canonical-symbol>#<addr-hash>`.
- Name resolution priority is fixed (ADR-0020):
  `local > lexical > explicit import > prelude`.
- Namespace member declaration policy is fixed (ADR-0020):
  namespace functions are declared by `let Type::symbol = ...` (or equivalent),
  while `impl` is reserved for `impl Trait for Type`.
- Railway-style error boundary policy is fixed (ADR-0020):
  application pipelines prefer Result composition, and exception/handle
  boundaries must be explicit in the pipeline.
- Result-first error surface policy is fixed for 0.1.0:
  public/library APIs use `Result[T, E]` as canonical error transport,
  while `throw` / `handle { ... } with Exception { ... }` remain boundary syntax for
  adapters (CLI/HTTP/FFI/tests). `?` remains boundary sugar in 0.1.0 and is
  not promoted to the primary library surface.
- Symbol/type/signature indexing backend is implemented and shared:
  `vibe ide` (`outline`/`peek-def`/`search`) and `vibe lsif` consume the same
  module-level symbol index (`src/frontend/symbol_index.mbt`).
- Scratch-first workflow design:
  default namespace-backed scratch/shell flow, symbol listing with index
  inclusion status, and history reset policy.
- Advanced graph extension PoC is implemented on vibe side:
  `vibe index` (`build`/`query`/`verify`) provides a sidecar JSON index
  (`src/x/module_graph/advanced_graph_poc.mbt`) that models manifest + def graph +
  symbol/type lookup tables.
- Advanced graph diff/apply path is implemented for remote sync PoC:
  delta payload (`AdvancedGraphDelta`) can be computed/applied and
  serialized as JSON for transfer simulation.
- Bundle-size guardrail workflow is implemented:
  `scripts/bench_bundle_size.sh` compiles `examples/*.vibe` and
  `bench/bundle_size/cases.txt` importer cases by default
  (`bench/importers` is runtime-first:
  `wasm` -> `wasm-js-string` -> no-dce fallback),
  supports optional `bench/importers-no-dce` diagnostics via
  `VIBE_BUNDLE_BENCH_INCLUDE_IMPORTER_NO_DCE=1`,
  supports opt-in `@vibe/builtin/*.vibe` surfaces via
  `VIBE_BUNDLE_BENCH_INCLUDE_STD_SURFACES=1`,
  stores current metrics in `dist/bundle_size/current.tsv`,
  and enforces per-entry golden budgets from
  `bench/golden/bundle_size_budget.tsv`.
- `export use` re-export syntax is implemented for facade modules:
  `export use <module-ref> { name1, name2 }` desugars to `Stmt::ReExport`
  (existing AST node). Named items are imported from the source module and
  re-exported in a single statement. `as` rename is not supported (Phase 1).
  Braces are required (no wildcard re-export).
