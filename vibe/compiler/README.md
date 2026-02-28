# vibe/compiler (experimental)

An experimental self-hosted compiler/interpreter for vibe-lang, written in vibe itself.

## Status (2026-02-28)

- Core pipeline is implemented: `lex -> parse -> typecheck -> eval`.
- Multi-file `import` / `export` resolution works in the interpreter.
- Self-host smoke suites (`eval_selfhost*`) pass.
- Full self-host goal is not reached yet: running `vibe/compiler` itself end-to-end (`parse + eval`) is still in progress.

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

### Evaluation

- AST interpreter (functions, recursion, match, handle/throw, while, for-in)
- Multi-file module loading with import cycle detection
- `array_builder` runtime path used by self-host smoke scenarios

### Incremental Typecheck Experiment

- `type_db` + `ripple` prototype exists and has dedicated tests
- Caches fingerprints and import-dependency-based invalidation

## Known Gaps Before Full Self-Hosting

- Loop control semantics are incomplete end-to-end:
  - `break` / `continue` are parsed, but runtime loop control is not fully wired
- `return` is not supported (parser rejects it)
- `raise` is deprecated (must use `throw(expr)`)
- Postfix feature mismatch (`arr[i]`, tuple/index ergonomics, member/index consistency)
- Type annotation contract mismatch (`TyApp` / `TyFn` / `TyTuple` paths still lose precision in parts)
- Builtin type contracts and evaluator implementations are not fully aligned
- `type_db` dependency extraction is token-scan based (temporary); AST-based extraction is pending
- `type_db` is still experimental and not integrated into the main checker pipeline
- Root import constraint prevents direct `vibe/compiler -> vibe/x` imports; duplicate ripple implementation remains
- Some deeper recursive self-host scenarios can still hit WASM stack limits

See [`TODO.md`](../../TODO.md) for the tracked source-of-truth checklist.

## Quick Verification

Run full project checks:

```bash
just release-check
```

Run focused compiler suites:

```bash
_build/native/debug/build/cmd/vibe/vibe.exe test \
  vibe/compiler/lexer_test.vibe \
  vibe/compiler/parser_test.vibe \
  vibe/compiler/printer_test.vibe \
  vibe/compiler/checker_test.vibe \
  vibe/compiler/checker_stmt_test.vibe \
  vibe/compiler/eval_test.vibe \
  vibe/compiler/eval_stmt_test.vibe \
  vibe/compiler/eval_import_test.vibe \
  vibe/compiler/eval_selfhost_test.vibe \
  vibe/compiler/eval_selfhost2_test.vibe \
  vibe/compiler/eval_selfhost3_test.vibe
```
