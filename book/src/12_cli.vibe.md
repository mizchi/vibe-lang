# 12 — The CLI as an IDE

vibe's command line is the same semantic surface an editor gets over LSP.
The first reader is an LLM. That forces a few rules:

- one record per line, fixed field order
- empty output means clean
- a message names the edit, not a pass

If a command cannot answer the question, that is a compiler bug, not a
workflow problem. Do not memorize a workaround — fix the command or
file an issue.

## Questions the CLI can answer

```bash
vibe check file.vibe                # empty = this file compiles (imports resolved)
vibe check --single-file file.vibe  # buffer-only; imports are not followed
vibe symbols file.vibe              # outline: NAME KIND START END
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
import @vibe/prelude {
  stdout_write
}

fn add(x: Int, y: Int) -> Int {
  x + y
}

fn main with Stdout {
  stdout_write("\{add(2, 40)}\n")
}
```

```output
42
```

On a file containing that `add`:

```bash
vibe symbols hello.vibe          # includes add and main
vibe type-at hello.vibe 5 4      # (Int, Int) -> Int  (on the name `add`)
vibe check hello.vibe            # empty
```

`vibe test file.vibe` compiles every `test { }` / `test "name" { }` block.
`inspect(value, "expected")` is the snapshot form; `vibe test --update`
rewrites the literal. `inspect` does not need an import — the compiler
desugars it before checking.

See [Tests](06_tests.vibe.md) for the language-level tour.

Next: [Targeting wasm](13_wasm.vibe.md).
