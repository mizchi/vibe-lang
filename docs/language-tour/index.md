# vibe Language Tour

vibe is an ML-like statically typed scripting language with shell integration, targeting WASM/wasip3.

## CLI

```bash
vibe run file.vibe       # Run a script (calls _start)
vibe test file.vibe      # Run tests in a file
vibe shell               # Interactive REPL (PosixMode)
vibe bench file.vibe     # Run benchmarks
vibe check file.vibe     # Type check
```

## Hello World

```vibe
let greeting = (name: String) -> String {
  "hello \(name)"
}

export let _start = () -> String {
  greeting("world")
}

test "greeting" {
  assert(String::equals(greeting("world"), "hello world"))
}
```

## Entry Point

Every runnable `.vibe` file defines an `export let _start` function as its entry point.
Top-level function calls are not allowed — all execution starts from `_start`.

```vibe
export let _start = () -> Int {
  1 + 2
}
```

## Guide

- [basics.md](basics.md) -- Types, variables, functions, control flow, type definitions
- [collections.md](collections.md) -- Array, Map, Record, Tuple, JSON
- [shell.md](shell.md) -- sh/sh_lines, PosixMode, pipes
- [effects.md](effects.md) -- Error handling, algebraic effects, effect polymorphism
- [modules.md](modules.md) -- export, import, module blocks, extern
- [builtins.md](builtins.md) -- Built-in function reference
- [syntax-reference.md](syntax-reference.md) -- Complete syntax reference (operators, patterns, effects, modules)
