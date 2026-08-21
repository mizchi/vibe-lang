# 01 — Installation and Hello, vibe

Previous: [Introduction](00_introduction.md)

日本語版: [01_getting_started.vibe.md](../ja/01_getting_started.vibe.md)

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/mizchi/vibe-lang/main/install/install.sh | bash
. "$HOME/.vibe/env"
vibe version
```

From a checkout of this repository, `bash install/install.sh` does the
same thing. You get the `vibe` command, a `viberun` host, and the
standard library. The compiler itself is a wasm module.

## Hello

Put this in `hello.vibex`:

```vibe run
fn main with Console {
  println("hello, vibe")
}
```

```output
hello, vibe
```

```bash
vibe run hello.vibex
```

`println` is built in, so there is nothing to import.

The interesting part is `with Console`. It is the program's permission
to write to the terminal, and it is required: delete it and the program
does not compile. That is the language's one big idea, showing up in the
smallest program it has — a function states what it is allowed to do,
and the compiler holds it to that.

You will meet the same shape again for failure (`with Exception`) and
for reading files (`allows Fs::read_file`).
[Capabilities](14_capabilities.vibe.md) is where it is finished.

## Ask the compiler questions

vibe's CLI is built to be queried, not just run. The convention
throughout is **empty output means clean**.

```bash
vibe check hello.vibex     # typecheck; prints nothing if it compiles
vibe run   hello.vibex     # compile and execute
vibe test  hello_test.vibe # run its test { } blocks
```

`vibe check` is the one to reach for while writing. It answers "does
this compile" on its own, one diagnostic per line, and exits non-zero if
there is anything to say.

There are more of these — `vibe symbols`, `vibe type-at`, `vibe deps` —
and they exist so an editor, or you, or a script can ask the compiler
what it knows. [The CLI as an IDE](18_cli.vibe.md) covers them.

## A project, when you want one

```bash
vibe new myapp
cd myapp
vibe run main.vibex
```

`vibe new` writes two files: `main.vibex`, the entry point, and
`vibe.deps`, where dependencies go. That is the whole scaffold — a
package contract (`index.vpkg`) is something you add when you have
something to publish, and [Modules and packages](09_modules_packages.vibe.md)
picks that up. You do not need any of it for a single file, which is why
this chapter did not start there.

Next: [A small program](02_a_small_program.vibe.md).
