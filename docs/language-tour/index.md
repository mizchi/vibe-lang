# vibe Language Tour

vibe is an ML-like statically typed scripting language with shell integration, targeting WASM/wasip3.

## CLI

```bash
vibe run file.vibe       # Run a script
vibe test file.vibe      # Run tests in a file
vibe shell               # Interactive REPL (PosixMode)
vibe bench file.vibe     # Run benchmarks
vibe check file.vibe     # Type check
```

## Hello World

```vibe
let name = "world"
let msg = "hello \(name)"

test "greeting" {
  assert(string_equals(msg, "hello world"))
}
```

## Guide

- [basics.md](basics.md) -- Types, variables, functions, control flow, type definitions
- [collections.md](collections.md) -- Array, Map, Record, Tuple, JSON
- [shell.md](shell.md) -- sh/sh_lines, PosixMode, pipes
- [builtins.md](builtins.md) -- Built-in function reference
