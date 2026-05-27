# vibe Language Tour

vibe is an ML-like statically typed scripting language with shell integration, targeting WASM/wasip3.

## CLI

```bash
vibe run file.vibe       # Run a script (evaluates the final top-level pure expression)
vibe test file.vibe      # Run tests in a file
vibe shell               # Interactive shell (PosixMode)
vibe bench file.vibe     # Run benchmarks
vibe check file.vibe     # Type check
```

## Hello World

```vibe
let greeting: (String) -> String = (name) -> {
  "hello \(name)"
}

greeting("world")

test "greeting" {
  assert(String::equals(greeting("world"), "hello world"))
}
```

## Entry Point

Source-level scripts run the final top-level pure expression.
When you `vibe build`, the generated WASM exports `_start` as the ABI entry point.

```vibe
1 + 2
```

## Guide

- [basics.md](basics.md) -- Types, variables, functions, control flow, type definitions
- [collections.md](collections.md) -- Array, Map, Record, Tuple, JSON
- [shell.md](shell.md) -- sh/sh_lines, PosixMode, pipes
- [effects.md](effects.md) -- Error handling, algebraic effects, effect polymorphism
- [modules.md](modules.md) -- export, import, module blocks, extern
- [builtins.md](builtins.md) -- Built-in function reference
- [syntax-reference.md](syntax-reference.md) -- Complete syntax reference (operators, patterns, effects, modules)
