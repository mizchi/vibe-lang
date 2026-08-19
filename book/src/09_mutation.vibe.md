# 09 — Mutation, regions, and escape

vibe is pure by default. Mutation exists, but it is local and it does not
show up on a function's public effect row. There is no builtin `Mut`
effect and no `Ref[T]`.

## Pick the smallest mutation that fits

- Local counter or accumulator: `let mut x = ...`. Block-scoped. Cannot
  escape the function through `async` / `spawn`.
- Growable bytes or text: `Bytes` / `StringBuilder`.
- Growable array: `ArrayBuilder` then `freeze`, or `Array::push` on an
  array you already hold.
- A mutable cursor on a heap value: `struct S { mut field: T }` — wasm-gc
  only (ADR-0052). Linear-memory builds do not have this.
- Cross-call or handler-mediated state: declare an effect and `handle`
  it. A `perform` *directly* in the handler body is inline-eliminated.

## `let mut` stays in the block

A `let mut` binding is writable until the block ends. The block itself is
still an expression: it produces a value.

```vibe run
fn main with Console {
  let y = {
    let mut v = 0
    v += 1
    v + 1
  }
  println("y = \{y}")
}
```

```output
y = 2
```

That is the ordinary case. Codegen keeps the binding as a wasm local.

`Array::push` is the other ordinary case: the *binding* is immutable, the
*interior* grows, and every alias sees it.

```vibe run
fn grow(xs: Array[Int]) -> Unit {
  Array::push(xs, 9)
}

fn main with Console {
  let xs = [
    1
  ]
  grow(xs)
  println("length = \{Array::length(xs)}, last = \{Array::get(xs, 1)}")
}
```

```output
length = 2, last = 9
```

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

Next: [Generics](16_generics.vibe.md).
