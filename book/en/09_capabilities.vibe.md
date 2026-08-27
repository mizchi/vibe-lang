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

fn main with Console {
  greet("vibe")
}
```

```output
hi vibe
```

`greet` writes to the terminal, so it says `with Console`. `main` calls
`greet`, so `main` says it too. The capability does not appear at `main`
by magic — it is inferred from the calls and then checked against what
you wrote. A function whose signature omits it will not compile.

`Console` is the terminal capability. `Stdin` / `Stdout` / `Stderr` are
older labels for parts of it that are still accepted; `with Console`
covers them, and they do not cover `Console`. Ask for the narrow one and
you get the narrow one:

```vibe skip
// skip: `with Stdout` does not reach a `Console::` operation
fn main with Stdout {
  Console::write_stream("x")
}
```

```
effect row mismatch for 'main': missing { Console::write_stream }
(declared { Stdout }, requires { Console::write_stream, Stdout })
hint: add 'with Console::write_stream + Stdout' to 'main'
```

## `with` and `allows` are different clauses

A signature can split into what it *emits* and what it is *authorized*
for:

```vibe run
fn main with () allows Console {
  println("authority is a separate clause")
}
```

```output
authority is a separate clause
```

`with ()` is the empty row: nothing algebraic. `allows Console` is the
authority. The bare `fn main with Console` from chapter 1 is the short
form of the same thing.

Once you write the split form, a capability has to be in `allows`. Put
one in `with` and you are told which clause it belongs to:

```vibe skip
// skip: a capability in `with` on a split signature
fn main() -> Int with Console allows Fs::read_file? {
  0
}
```

```
`Console` is a capability effect and must appear in the `allows` clause,
not `with` (ADR-0088, #1345)
```

Authority stays per-operation. `allows Console::write_stream` does not
grant `Console::read_stream` — a program that may print does not thereby
acquire the right to read the terminal.

## Optional capability: `perform?`

A `?` on an `allows` item marks it optional — the program can run whether
or not the host granted it. The matching `perform? Fs::read_file("p")`
gives back an `Attempt`: `Granted`, `NotGranted`, or `Errored`.

The non-interactive compiler has no build/apply grant fact, so it freezes an
unresolved optional capability to `NotGranted` before code generation. The
operation and its arguments are not evaluated:

```vibe run
fn main() -> Int with () allows Console + Fs::read_file? {
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
