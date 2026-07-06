# lib/@vibe/compiler (experimental)

An experimental self-hosted compiler/tooling package for vibe-lang, written in vibe itself.

## Status

- Frontend and typecheck stages are implemented in vibe.
- Multi-file `import` / `export` resolution is part of the active selfhost pipeline.
- Mainline validation is now centered on compiled/selfhost fixture and CLI gates.
- Current gates and remaining work are tracked in [`TODO.md`](../../TODO.md).

## Implemented

### Frontend

- Lexer: source string -> token array
- Parser: token array -> AST (expr/stmt/type/pattern)
- Printer: AST -> normalized source
- `|>` is desugared in parser:
  - `x |> f(a, b)` -> `f(x, a, b)`
  - mixing `|>` with other infix operators at top-level parse scope is rejected
- `use` syntax is removed; `import` is the only supported module syntax

### Type Checking

- Expression + statement checker (HM-like inference baseline)
- Trait/type-def environment plumbing
- Import surface checks in statement pass

### Selfhost / Fixture Support

- Multi-file module loading with import cycle detection
- Fixture parsing / roundtrip / typecheck helpers used by selfhost suites
- Runtime fixture smoke coverage via the compiled backend

### Incremental Typecheck Experiment

- `type_db` + `ripple` prototype exists and has dedicated tests
- Caches fingerprints and import-dependency-based invalidation

## Known Gaps Before Full Self-Hosting

- `return` is not supported (parser rejects it)
- `raise` is deprecated (must use `throw(expr)`)
- `type_db` is still experimental and not integrated into the main checker pipeline
- Some deeper recursive self-host scenarios can still hit WASM stack limits

See [`TODO.md`](../../TODO.md) for the tracked source-of-truth checklist and release gates.

## Quick Verification

Run full project checks:

```bash
just release-check
```

Run focused compiler suites:

```bash
just test-selfhost-typecheck-fixtures
just test-selfhost-runtime-fixtures
just test-selfhost-cli-core
```
