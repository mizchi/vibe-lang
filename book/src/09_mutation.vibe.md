# 09 — Mutation, regions, and escape

vibe is pure by default. Mutation exists, but it is local and it does not
show up on a function's public effect row.

## `let mut` stays in the block

A `let mut` binding is writable until the block ends. The block itself is
still an expression: it produces a value.

```vibe run
import @vibe/prelude {
  stdout_write
}

fn main with Stdout {
  let y = {
    let mut v = 0
    v += 1
    v + 1
  }
  stdout_write("y = \{y}\n")
}
```

```output
y = 2
```

That is the ordinary case. Codegen keeps the binding as a wasm local.

## Escape is capture

If a `let mut` is captured by a closure that can outlive the binding, it is
no longer a local. The compiler boxes it. `vibe escapes file.vibe` lists
those names. Empty output means every `let mut` in the file is a plain
local.

`--strict` answers a different question: "does this closure actually reach
that binding?" The default is the lowering answer (when in doubt, box).
`--strict` is the enforcement answer (shadowing is subtracted). Use the
default when you care about cost; use `--strict` when you care about
authority.

```bash
vibe escapes file.vibe
vibe escapes --strict file.vibe
```

## Regions and `TaskGroup`

Structured concurrency uses a generative region tag. `TaskGroup::run` mints
a fresh region and rejects a nursery value escaping through the body's
**return**. That is the guarantee that is actually checked today. See
[Concurrency](11_concurrency.vibe.md).

## `mut` struct fields

wasm-gc can represent `mut` fields on a struct (ADR-0052). Linear-memory
builds do not. Prefer `let mut` locals unless you are on the gc backend
and you need a heap cell.
