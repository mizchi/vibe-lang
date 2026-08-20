# 10 — Capabilities

日本語版: [14_capabilities.vibe.md](../ja/14_capabilities.vibe.md)

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
fn greet(name: String) -> Unit with Console
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
fn greet(name: String) -> Unit with Console {
  println("hi \{name}")
}

fn main with Console {
  greet("vibe")
}
```

```output
hi vibe
```

A function that only calls `greet` must itself mention `Console`. The
capability does not appear by magic at `main` — it is inferred from
calls and then checked against what you wrote.

The `println` / `print` builtins still carry the **legacy** `Stdout`
label internally. `Console` is the current tty capability — the name a
grant prompt should say — and declaring it authorizes the legacy three,
which is why the row above reads `with Console` (#2102).

The containment is **one-way**, and deliberately so: `Console` owns six
operations and `Stdout` owns two of them, so a row declaring only
`Stdout` may not reach `Console::read_stream`. A write-only program does
not acquire read authority by way of a migration alias.

## The current tty name is `Console`

Six operations, one effect:

| operation | legacy label | host import |
|---|---|---|
| `Console::write_stream` | `Stdout::write_stream` | `vibe.stdout_write_stream` |
| `Console::write_char` | `Stdout::write_char` | `vibe.stdout_write_char` |
| `Console::write_err_stream` | `Stderr::write_stream` | `vibe.stderr_write_stream` |
| `Console::write_err_char` | `Stderr::write_char` | `vibe.stderr_write_char` |
| `Console::read_stream` | `Stdin::read_stream` | `vibe.stdin_read_stream` |
| `Console::read_char` | `Stdin::read_char` | `vibe.stdin_read_char` |

`Stdin` / `Stdout` / `Stderr` stay accepted until the seed bump retires
them, and `with Console` covers all three. The reverse does not hold:
`with Stdout { Console::write_stream(...) }` is a row mismatch.

`with Console` covers the six operations in the **row**. Instantiate
grants stay per-operation: `allows Console::write_stream` does not
grant `Console::read_stream` (#1496). Do not read the merge as one
authority for read+write+stderr.

```vibe run
fn main with Console {
  Console::write_stream("hello, console\n")
}
```

```output
hello, console
```

```vibe skip
// skip: legacy Stdout does not authorize Console::* (distinct labels)
fn main with Console {
  Console::write_stream("no")
}
```

## `with` vs `allows`

`with` is the row of **emitted operations** (algebraic / core ambient).
`allows` is **provider authority**. They are not two spellings of the
same set. `with Ask::Get allows Fs` does **not** authorize an unhandled
`Ask::Get` — you still need a `handle`, or you add the op to `allows`
(and then it is a capability, which `Ask::Get` is not).

The parser stores the split as the emitted row plus a `#allows` marker,
not as `with A + C`.

```vibe run
fn main with () allows Console {
  println("authority is a separate clause")
}
```

```output
authority is a separate clause
```

`Stdout` in a *split* signature belongs in `allows`. Writing
`fn main() -> Int with Console allows Fs::read_file?` is rejected:
"`Stdout` is a capability effect and must appear in the `allows`
clause, not `with`". The hello-world `fn main with Console` is the
**bare** form and stays legal.

## Optional capability and `perform?`

A trailing `?` on an `allows` item is the optional grade. A required
`Fs::read_file("p")` is not authorized by `allows Fs::read_file?`.
`perform? Fs::read_file("p")` is the optional perform: the checker
types it as `Attempt[T, String]` (`NotGranted` / `Errored` / `Granted`)
and only accepts it on an optional `allows`.

Codegen does **not** lower `perform?` yet, so **the compiler rejects it**
(#2145):

> \`perform?\` is not lowered yet (#2145): the checker types it as
> \`Attempt[T, String]\`, but code generation cannot emit it. Use a REQUIRED
> capability and plain \`perform\` — drop the \`?\` from both the \`allows\` item
> and the \`perform\` — and handle the failure with \`try\`/\`handle\` instead of
> matching \`Attempt\`.

`vibe check` says the same thing, so you learn it before you build. It used to
typecheck clean and then die at code generation with "this is a bug in the
compiler and not in your program", which is not something a reader of this
chapter could act on.

```vibe skip
// skip: rejected by the checker -- codegen does not lower perform? (#2145)
fn main() -> Int with () allows Console + Fs::read_file? {
  let a = perform? Fs::read_file("config.json")
  match a {
    NotGranted => 0,
    Errored(_) => 1,
    Granted(_) => 2
  }
}
```

Non-TTY instantiate uses `preflight_instantiate`: a required capability
missing from the host grant set aborts before `main` and names the
`--allow-fs` flag. The TTY grant prompt is still runner work.

## Algebraic effects vs capabilities

An `effect Ask { Get -> Int }` that you `perform` and `handle` is an
algebraic effect: the operation is a constructor. A capability builtin
(`Fs::read_file`, `Env::get`) is a function. Both ride on the row. The
spelling tells you which: `Effect::CamelCase` is performed;
`Effect::snake_case` is called. See the cheatsheet's "Effect classes"
table and [Effects](13_effects.vibe.md).

## Progressive wasm

The generated module declares the wasm feature level it actually needs
([docs/wasm/feature-levels.md](../../docs/wasm/feature-levels.md)). Denied
capabilities should not force a higher feature level than the remaining
code uses. A program that never reaches `Http` should not demand a
networking-capable runtime.

Next: [Concurrency](17_concurrency.vibe.md).
