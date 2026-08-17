# 01 — Getting started

Install vibe, write `hello`, and confirm the toolchain answers questions
about your source. Details live in [docs/install.md](../../docs/install.md);
this chapter is the short path.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/mizchi/vibe-lang/main/scripts/installer.sh | bash
. "$HOME/.vibe/env"
vibe version
```

From a checkout of this repository:

```bash
bash scripts/install.sh
```

You get a `vibe` dispatcher, a `viberun` host, and the stdlib under
`$VIBE_HOME/lib`. The compiler itself is a wasm module.

## Hello

A program is a `fn main` with an explicit effect row. `Stdout` is a
capability: the function says it will write, and the runtime must grant it.

```vibe run
import @vibe/prelude {
  stdout_write
}

fn main with Stdout {
  stdout_write("hello, vibe\n")
}
```

```output
hello, vibe
```

`stdout_write` is a prelude helper, not a builtin. Forget the import and the
checker reports `unknown function`. The same program as a script file is
usually named `hello.vibex` and run with `vibe run hello.vibex`.

## Check, then run

vibe treats the CLI as an editor-shaped query surface. Empty output means
clean.

```bash
vibe check hello.vibex     # empty = compiles
vibe run hello.vibex       # compile + execute
vibe test hello_test.vibe  # run test { } blocks
```

If you are in this repository, the chapters themselves are the test:

```bash
bash scripts/vibe_md.sh check book/src/01_getting_started.vibe.md
```

Next: [Values and functions](01_values_functions.vibe.md).
