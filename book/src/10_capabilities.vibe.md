# 10 — Capabilities

An effect row is not only "this can fail." Host I/O is a **capability**:
the function's type says which authorities it needs, the call site stays
an ordinary call, and authorization is decided once — at build / apply /
instantiate — then frozen for the run (ADR-0075 / 0084 / 0088).

This is Deno's permission flags composed with Koka's effect system. The
expression you write is still `Fs::read_file(path)`. The row is how the
permission got there.

## Rows, not wrappers

```vibe skip
// skip: signatures only — not a complete program
fn greet(name: String) -> Unit with Stdout
fn slurp(path: String) -> String with Exception + Fs
fn read_var(name: String) -> String with Exception + Env
```

There is no `Result` in the language prelude. Failure that is part of the
program's meaning is `Exception[E]` and `throw` / `handle`. WIT boundaries
are the one place a `result<T, E>` shape is projected (`@vibe/wit_runtime`).

The empty row has one spelling: `with ()`. The old braced
`with { A, B }` is a named parse error; `vibe fmt` rewrites it to
`with A + B`.

## What the type already said

`Stdout` in the hello-world program is the same mechanism as `Fs` or
`Env`. The difference is which host imports the generated wasm is allowed
to mention. `--allow-*` flags const-fold and DCE the denied capability
away: code that needed it is not in the artifact.

```vibe run
import @vibe/prelude {
  stdout_write
}

fn greet(name: String) -> Unit with Stdout {
  stdout_write("hi \{name}\n")
}

fn main with Stdout {
  greet("vibe")
}
```

```output
hi vibe
```

A function that only calls `greet` must itself mention `Stdout`. The
capability does not appear by magic at `main` — it is inferred from
calls and then checked against what you wrote.

## Algebraic effects vs capabilities

An `effect Ask { Get -> Int }` that you `perform` and `handle` is an
algebraic effect: the operation is a constructor. A capability builtin
(`Fs::read_file`, `Env::get`) is a function. Both ride on the row. The
spelling tells you which: `Effect::CamelCase` is performed;
`Effect::snake_case` is called. See the cheatsheet's "Effect classes"
table and [Effects](05_effects.vibe.md).

## Progressive wasm

The generated module declares the wasm feature level it actually needs
([docs/wasm/feature-levels.md](../../docs/wasm/feature-levels.md)). Denied
capabilities should not force a higher feature level than the remaining
code uses. A program that never reaches `Http` should not demand a
networking-capable runtime.

Next: [Concurrency](11_concurrency.vibe.md).
