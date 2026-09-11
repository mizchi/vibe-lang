# 09 — Capabilities

Previous: [Effects (the heart of vibe)](08_effects.vibe.md)

日本語版: [09_capabilities.vibe.md](../ja/09_capabilities.vibe.md)

The last chapter's effects were ones you implement, with a handler.
Reading a file is not like that: the host already knows how, and the
question is whether your program is *allowed* to.

That is a capability. It rides the same row, but what the row records is
permission, and the permission is decided when the program is built — not
checked again at every call. The call itself stays an ordinary call.

This is Deno's permission flags composed with Koka's effect system.

## Permission is part of the signature

```vibe run
fn greet(name: String) -> Unit with Console {
  println("hi \{name}")
}

fn main allows Console {
  greet("vibe")
}
```

```output
hi vibe
```

`greet` writes to the terminal, so it says `with Console`: it *requires*
the capability from whoever calls it. `main` calls `greet`, and nothing
calls `main` — it is where the program starts, so it *grants* the
capability: `allows Console`. The capability does not appear at `main` by
magic — it is inferred from the calls and then checked against what you
wrote. A function whose signature omits it will not compile.

`Console` is the terminal capability. `Stdin` / `Stdout` / `Stderr` are
older labels for parts of it that are still accepted; `allows Console`
covers them, and they do not cover `Console`. Ask for the narrow one and
you get the narrow one:

```vibe skip
// skip: `allows Stdout` does not reach a `Console::` operation
fn main allows Stdout {
  Console::write_stream("x")
}
```

```
effect row mismatch for 'main': missing { Console::write_stream }
(declared { Stdout }, requires { Console::write_stream, Stdout })
hint: add 'allows Console::write_stream + Stdout' to 'main'
```

## `with` requires, `allows` grants

Two keywords, one row. A called function has a caller, and the row is
what it asks that caller for — `with`. An entry point has no caller: the
run brings the authority in, and the row is what the run grants — `allows`.
The entry points are `fn main`, `fn _start`, and the `test`, `bench` and
`example` blocks of [chapter 12](12_tests.vibe.md).

So `allows` is written on an entry point and nowhere else. On a called
function the compiler names the edit:

```vibe skip
// skip: `allows` on a called function
fn greet(name: String) -> Unit allows Console {
  println("hi \{name}")
}
```

```
`allows` grants authority and is written on an entry point only (`fn main`,
`fn _start`, `test`, `example`, `bench`); `greet` requires its effects from
the caller -- write `with` here and grant the effect at the entry
```

The other direction is a spelling that older code carries: `fn main with
Console`. It still compiles, and `vibe check` reports it with the `allows`
edit as a warning; it stops compiling once the compiler's own sources have
moved off it.

Authority stays per-operation. `allows Console::write_stream` does not
grant `Console::read_stream` — a program that may print does not thereby
acquire the right to read the terminal.

## Naming a bundle of capabilities

A program that grants the same set at several entry points can name it
once. An `effectset` is a set of row items, and an entry grants it like any
other item:

```vibe run
effectset AppCaps = { Console, Fs::read_file }

fn main allows AppCaps {
  println("bundled")
}
```

```output
bundled
```

The set is expanded before anything is checked, so `allows AppCaps` is
exactly `allows Console + Fs::read_file` — no more, no less.

## Optional capability: `perform?`

A `?` on an `allows` item marks it optional — the program can run whether
or not the host granted it. The matching `perform? Fs::read_file("p")`
gives back an `Attempt`: `Granted`, `NotGranted`, or `Errored`.

The non-interactive compiler has no build/apply grant fact, so it freezes an
unresolved optional capability to `NotGranted` before code generation. The
operation and its arguments are not evaluated:

```vibe run
fn main() -> Int allows Console + Fs::read_file? {
  let a = perform? Fs::read_file("config.json")
  match a {
    NotGranted => 0,
    Errored(_) => 1,
    Granted(_) => 2
  }
}
```

```output
0
```

An optional grant never stands in for a required call: `Fs::read_file("p")`
under `allows Fs::read_file?` is rejected, and the message offers the two
edits — call it with `perform?`, or grant it without the `?`.

A called function can *require* the optional grade the same way, and then
`perform?` lives where the fallback logic lives. A caller satisfies
`with Fs::read_file?` with either grade of the grant — `allows Fs::read_file`
or `allows Fs::read_file?` — because a required grant is the stronger one:

```vibe run
import @vibe/core { Attempt }

fn cached() -> Attempt[String, String] with Fs::read_file? {
  perform? Fs::read_file("cache.json")
}

fn main allows Console + Fs::read_file? {
  match cached() {
    NotGranted => println("no cache"),
    Errored(_) => println("cache failed"),
    Granted(_) => println("cache hit")
  }
}
```

```output
no cache
```

The `?` marks a host capability and nothing else: `with Ask::Get?` on an
effect you declared, or `allows Exception?`, is refused — nobody outside the
program could withhold those, so the grade would be a claim about nothing.

The frozen-resolution lowering is shared by the linear and wasm-gc backends.
Wiring `--allow-*`, BindingLock, and interactive preflight into production is
tracked in #2332; until then production compilation does not select `Granted`
or `Errored`.

## Telling the two kinds apart

Both ride the row, and the spelling says which you are looking at:

| | example | you write | who implements it |
|---|---|---|---|
| algebraic effect | `Ask::Value` | `perform` + a `handle` | you |
| capability | `Fs::read_file` | an ordinary call | the host |

`Effect::CamelCase` is an operation you perform; `Effect::snake_case` is
a function you call. That is the rule, and it is why `Fs::read_file(p)`
reads like any other call even though it needs authority.

An entry grants only what the run can bring in: the host capabilities,
`Exception` (a failure the runtime boundary reports), and `Async`. An
effect you declared yourself has no host behind it, so it cannot be
granted — it is handled, with `handle`, before it reaches the entry.

## What denial actually does

`--allow-*` decides the grant set at build time, and a denied capability
is **const-folded and removed** from the artifact — the code that needed
it is not in the wasm, not merely unreachable. A program that never gets
`Http` does not ship networking code, and does not demand a runtime that
can do networking
([feature levels](../../docs/wasm/feature-levels.md)).

At startup, a required capability the host did not grant aborts before
`main` runs and names the flag that would have granted it.

Next: [Option and the railway](10_option.vibe.md).
