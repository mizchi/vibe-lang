# vibe Language Tour

vibe is an ML-like statically typed scripting language with shell integration, targeting WASM/wasip3.

## CLI

```bash
vibe run file.vibex      # Run an executable root (executes `fn main`)
vibe test file.vibe      # Run tests in a file
vibe shell               # Interactive shell (PosixMode)
vibe bench file.vibe     # Run benchmarks
vibe check file.vibe     # Type check
```

## Hello World

```vibe
import ./lib/@vibe/prelude/io.vibe { stdout_write }

let greeting: (String) -> String = (name) -> {
  "hello \{name}"
}

fn main with Stdout {
  stdout_write(greeting("world"))
}

test "greeting" {
  assert(String::equals(greeting("world"), "hello world"))
}
```

## Entry Point

A `.vibex` executable root contains exactly one non-exported
`fn main with ... { ... }`. It takes no parameters, returns `Unit`, and its
closed effect row is explicit (`with ()` for a pure entry). The top level is
declarations-only, and statements/side effects live in `main`. A `.vibex` file
cannot be imported. When you `vibe build`, `main` is lowered to the generated
WASM `_start` ABI entry point.

```vibe
import ./lib/@vibe/prelude/io.vibe { stdout_write }

fn main with Stdout {
  stdout_write("1 + 2 = \{1 + 2}\n")
}
```

## Guide

- [basics.vibe.md](basics.vibe.md) -- Types, variables, functions, control flow, type definitions
- [collections.vibe.md](collections.vibe.md) -- Array, Map, Record, Tuple, JSON
- [shell.vibe.md](shell.vibe.md) -- sh/sh_lines, PosixMode, pipes
- [effects.vibe.md](effects.vibe.md) -- Error handling, algebraic effects, effect polymorphism
- [modules.vibe.md](modules.vibe.md) -- export, import, module blocks, extern
- [builtins.md](builtins.md) -- Built-in function reference
- [syntax-reference.vibe.md](syntax-reference.vibe.md) -- Complete syntax reference (operators, patterns, effects, modules)
