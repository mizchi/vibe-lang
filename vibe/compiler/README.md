# vibe/compiler (experimental)

An experimental self-hosted compiler for vibe-lang, written in vibe itself.

Currently implements **lexer + parser + printer** only. Passes all 6 normalize fixtures with roundtrip stability (126 tests).

## Implemented

- **Lexer**: source string → token array
- **Parser**: token array → AST (expressions, statements, types, patterns)
- **Printer**: AST → source string (normalized output)

## Not Yet Implemented

### Parsing (cannot parse its own source yet)

| Syntax | Description |
|--------|-------------|
| `while` | While loop expression |
| `do { ... }` | Do block (explicit side-effect boundary) |
| `handle { ... } { Error(msg) => ... }` | Effect handler |
| `throw(msg)` / `raise` | Effect invocation |
| `for ... in` | For loop |
| `break` / `continue` / `return` | Control flow |

### Semantic Analysis

- Type inference (Hindley-Milner)
- Effect checking (`with { Error }` propagation tracking)
- Import resolution (`use ./foo.vibe { ... }` file loading)
- Export verification
- Scope management (forward references, mutual recursion)

### Evaluation / Code Generation

- Builtin functions (`string_concat`, `array_get`, etc. ~30 functions)
- AST interpreter or code generator
- Runtime for closures, pattern matching, effect handling

## Observations from Self-Hosting

Writing a ~3000-line compiler in vibe revealed several language pain points:

### No forward references or mutual recursion

Top-level functions cannot reference functions defined later in the file. This forced the entire parser into a single `let rec parse_impl(tokens, pos, mode)` function with ~6 nested helpers. The `mode` parameter (0-9 for binop precedence, 10 for unary/postfix, 20-22 for block/if/match) acts as a manual dispatch table — a workaround that would be unnecessary with forward references.

### Verbose string building

No string interpolation or `+` operator for strings. The printer is filled with deeply nested `string_concat` calls like:

```vibe
string_concat("(", string_concat(print_expr(left),
  string_concat(" ", string_concat(op,
    string_concat(" ", string_concat(print_expr(right), ")"))))))
```

A string interpolation or overloaded `+` would dramatically improve readability.

### No iteration helpers

No `map`, `filter`, `fold` for arrays. Every transformation requires a manual `while` loop with `array_builder`:

```vibe
do {
  let b = array_builder()
  let mut i = 0
  while i < len {
    array_builder_push(b, f(array_get(arr, i)))
    i += 1
  }
  array_builder_freeze(b)
}
```

This 7-line pattern appears ~20 times in the codebase. A `map` function or for-in loop would eliminate most of it.

### Cascading type errors

Any type error in a file makes ALL its exports invisible to importers, producing misleading "unknown function" / "unknown type" errors. During development, a single typo in parser.vibe would cause printer.vibe to fail with "unknown type: Expr" — hiding the real error entirely.

### No multiline string literals

Test fixtures had to be written as single-line strings with `\n`:

```vibe
let src = "let dead = () -> Int { 0 }\nimport ./dep.vibe { dep }\ntrait Eq\nimpl Eq for Int"
```

Multiline strings or heredocs would make test data much more readable.

### `do { }` required for imperative blocks

Any code using `array_builder()` or mutable state must be wrapped in `do { ... }` to satisfy the purity boundary. This adds syntactic noise to what is already verbose imperative code.
