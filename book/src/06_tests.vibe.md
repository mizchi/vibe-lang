# 06 — Tests and tooling

Previous: [05 Effects](05_effects.vibe.md)

日本語版: [06_tests.vibe.md](../ja/06_tests.vibe.md)

## The test block

A test is just a `test "name" { ... }` written in a source file. The convention
is to collect them in `*_test.vibe`.

```vibe
test "assert_eq for numbers, assert for booleans" {
  assert_eq(1 + 1, 2)
  assert(2 < 3)
}
```

`assert_eq(actual, expected)` is the standard equality assertion whatever the
type. Strings compare by content, so `assert_eq` works directly on
concatenations, function results, and values reached through a variable.

```bash
vibe test file_test.vibe             # one file
vibe test a_test.vibe b_test.vibe    # several files
vibe test tests/                     # every *_test.vibe under a directory
```

## CLI tooling

```bash
vibe run app.vibex           # compile, then run fn main
vibe check app.vibe          # type check only
vibe compile app.vibex -o app.wasm
vibe bench file.vibe         # measure bench {} blocks (ns/op, ops/sec)

# editor-grade queries (the same AST analysis the LSP uses)
vibe symbols file.vibe               # declaration outline
vibe type-at file.vibe <line> <col>  # the type at the cursor
vibe check file.vibe                 # all diagnostics (empty output = clean)
vibe lsp                             # LSP server (stdio)

# a package's content hash (what a require pin uses)
vibe hash lib/@vibe/core
```

## This tutorial is itself an executable document

Every chapter under `book/src/`, this one included, is in the `.vibe.md`
format from #1142: the ` ```vibe run ` blocks really are compiled and run, and
the ` ```output ` right after each one is the real result. To verify or
regenerate them locally:

```bash
bash scripts/vibe_md.sh check book/src/*.vibe.md   # verify (FAILs if the embedded output is stale)
bash scripts/vibe_md.sh write book/src/*.vibe.md   # run and rewrite the output blocks
pkf run vibe-md-tutorial                           # the same check as a task
```

Next: [07 Modules and packages](07_modules_packages.vibe.md)
