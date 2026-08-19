# 1 — Installation and Hello, vibe

Install vibe, write `hello`, and confirm the toolchain answers questions
about your source. This is the Rust book's Chapter 1 slot: install,
hello world, then the build tool. Details live in
[docs/install.md](../../docs/install.md).

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

A program is a `fn main` with an explicit effect row. The current tty
capability is **`Console`**, and that is what this hello declares. The
`println` builtin still carries the **legacy** `Stdout` label internally;
declaring `Console` authorizes it, because `Console` is the union of the
legacy three. The reverse does not hold — see
[Capabilities](10_capabilities.vibe.md).

Two spellings are legal. The **bare** `with Console` is the usual hello.
The **split** form `with () allows Console` says the same thing more
loudly: nothing algebraic, one capability. Mixing a
capability into `with` *after* you wrote `allows` is a parse error
(`Stdout` must appear in `allows`, not `with`).

```vibe run
fn main with Console {
  println("hello, vibe")
}
```

```output
hello, vibe
```

`println` is a builtin -- no import -- and its row is not optional: drop
`with Console` and the checker reports an effect row mismatch. It names
`Stdout`, the label the builtin carries internally; `Console` is the
current capability and authorizes it (#2107, #2102). The same program as a script file is usually named
`hello.vibex` and run with `vibe run hello.vibex`.

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

Next: [A small program](19_a_small_program.vibe.md).
The language tour continues at [Values and functions](01_values_functions.vibe.md).
