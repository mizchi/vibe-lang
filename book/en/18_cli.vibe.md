# 18 — The CLI as an IDE

Previous: [Concurrency](17_concurrency.vibe.md)

日本語版: [18_cli.vibe.md](../ja/18_cli.vibe.md)

Everything an editor gets from the language server, you can ask for from
the shell. The answers are shaped so you can pipe them: one record per
line, fixed field order, and **empty output means nothing is wrong**.

That last one is worth internalising. `vibe check` printing nothing is
the success case.

## Questions you can ask

```bash
vibe check file.vibe                # empty = this file compiles (imports resolved)
vibe check --single-file file.vibe  # buffer-only; imports are not followed
vibe symbols file.vibe              # outline: NAME KIND START END [DOC]
vibe type-at file.vibe 12 4         # hover at 1-based line,col
vibe binding-at file.vibe 12 4      # rename / refs
vibe escapes file.vibe              # which let mut is boxed
vibe deps file.vibe                 # resolved import closure
vibe deps --direct file.vibe        # one hop; cache-friendly
vibe grep --pattern 'f($(x:exp))' --where '$x : Array[_]' lib
```

`vibe lsp` speaks LSP on stdin/stdout for editors that want a server.

`--single-file` is not a lesser `check`. It is the un-saved-buffer tool:
it will report `unknown name` for imported constructors even when the
project is fine. To know whether the file compiles, omit the flag.

`vibe grep` matches an AST pattern, not text. Filters can ask the
checker (`--where '$x : Array[_]'`, `--where-row '$f with Async'`,
`--only-ill-typed`). Those filters take the same import-resolving lane
as `vibe check`.

## A program the queries can see

```vibe run
fn add(x: Int, y: Int) -> Int {
  x + y
}

fn main with Console {
  println("\{add(2, 40)}")
}
```

```output
42
```

On a file containing that `add`:

```bash
vibe symbols hello.vibe          # add 12 3 6 / main 12 46 50
vibe type-at hello.vibe 1 4      # (Int, Int) -> Int  (on the name `add`)
vibe type-at hello.vibe 5 4      # () -> () with Console  (on `main`)
vibe check hello.vibe            # empty
```

The `12` in the symbols lines is the LSP SymbolKind for a function, and
the two numbers after it are byte offsets of the name —
`vibe symbols --legend` prints the kind table. `type-at` takes a 1-based
line and byte column and answers for the identifier there; on a position
with no identifier it prints nothing and exits 0, the same empty-is-clean
convention as everything else.

`vibe test file.vibe` compiles every `test { }` / `test "name" { }` block.
`inspect(value, "expected")` is the snapshot form; `vibe test --update`
rewrites the literal. `inspect` does not need an import — the compiler
desugars it before checking.

See [Tests](12_tests.vibe.md) for the language-level tour.

Next: [Targeting wasm](19_wasm.vibe.md).
