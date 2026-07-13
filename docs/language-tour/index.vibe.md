# vibe Language Tour

vibe is an ML-like statically typed scripting language with shell integration, targeting WASM/wasip3.

## CLI

```bash
vibe run file.vibe       # Run a script (executes `fn main`)
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

fn main with { Stdout } {
  stdout_write(greeting("world"))
}

test "greeting" {
  assert(String::equals(greeting("world"), "hello world"))
}
```

## Entry Point

The entry point is `fn main { ... }` (ADR-0069): the top level is
declarations-only, and statements/side effects live in `main`. Capabilities
are declared as `fn main with { Stdout, Fs } { ... }`. The legacy
`let main: () -> Int = ...` form still runs (its Int result is printed) but
`fn main` is the primary form going forward. When you `vibe build`, the
generated WASM exports `_start` as the ABI entry point.

```vibe
import ./lib/@vibe/prelude/io.vibe { stdout_write }

fn main with { Stdout } {
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
