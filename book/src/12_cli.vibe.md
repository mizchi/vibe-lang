# 12 — The CLI as an IDE

vibe's command line is the same semantic surface an editor gets over LSP.
The first reader is an LLM. That forces a few rules:

- one record per line, fixed field order
- empty output means clean
- a message names the edit, not a pass

## Questions the CLI can answer

```bash
vibe check file.vibe              # empty = this file compiles (imports resolved)
vibe check --single-file file.vibe  # buffer-only; imports are not followed
vibe symbols file.vibe            # outline
vibe type-at file.vibe 12 4       # hover
vibe binding-at file.vibe 12 4    # rename / refs
vibe escapes file.vibe            # which let mut is boxed
vibe deps file.vibe               # resolved import closure
vibe grep --pattern 'f($(x:exp))' --where '$x : Array[_]' lib
```

`vibe lsp` speaks LSP on stdin/stdout for editors that want a server.

`--single-file` is not a lesser `check`. It is the un-saved-buffer tool:
it will report `unknown name` for imported constructors even when the
project is fine. To know whether the file compiles, omit the flag.

## Tests

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

`vibe test file.vibe` compiles every `test { }` / `test "name" { }` block.
`inspect(value, "expected")` is the snapshot form; `vibe test --update`
rewrites the literal.

See [Tests](06_tests.vibe.md) for the language-level tour.
