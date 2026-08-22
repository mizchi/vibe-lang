# 06 — Mutation, regions, and escape

Previous: [Types and strings](05_types_strings.vibe.md)

日本語版: [06_mutation.vibe.md](../ja/06_mutation.vibe.md)

vibe is immutable by default, and mutation is deliberately small: it is
local, and it never appears on a function's effect row. A function that
uses a counter internally has the same signature as one that does not,
because from the outside there is no difference.

## A counter

`let mut` gives you a writable binding for the rest of its block:

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

`y` is an ordinary immutable `Int`. The mutable binding existed only
inside the braces, and the compiler keeps it in a plain wasm local —
no allocation happens for it.

## Growing an array

Here the *binding* is immutable and the *contents* grow. `Array::push`
appends in place, so every name for that array sees the new element —
including a function you passed it to:

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

This is worth being deliberate about: `xs` is shared, not copied. If you
want a private copy, make one.

## A field you can write through

When the thing that changes is part of a value, declare the field `mut`.
Every alias observes the write, including one taken before it:

```vibe run
struct Counter {
  mut n: Int
} derive (Show)

fn bump(c: Counter) -> Unit {
  c.n = c.n + 1
}

fn main with Console {
  let c = Counter::{
    n: 10
  }
  let alias = c
  bump(c)
  bump(c)
  println("c.n = \{c.n}, alias.n = \{alias.n}")
}
```

```output
c.n = 12, alias.n = 12
```

Prefer a `let mut` local when a local is what you mean. A `mut` field is
a cell that anybody holding the value can write, which is a much larger
claim than a counter.

## Escape is capture

There is one rule that decides whether a `let mut` is really local: if a
closure that can outlive the binding captures it, it is not. The
compiler then puts it on the heap so the closure can still reach it.

You do not have to guess which of your bindings that happened to:

```bash
vibe escapes file.vibe
```

It prints one line per escaping `let mut`, and empty output means every
`let mut` in the file is a plain local. There is a second form:

```bash
vibe escapes --strict file.vibe
```

The default answers "what does codegen do" — and when in doubt codegen
boxes, so the default over-reports. `--strict` answers "can that closure
actually reach this binding", subtracting cases where a name is merely
shadowed. Ask the default when you care about cost, `--strict` when you
care about who can write what.

## Regions

Concurrency needs a stronger version of the same idea: a scratch value
belonging to a task group must not outlive the group. `TaskGroup::run`
mints a fresh region tag for that purpose and rejects a value escaping
through the body's return. [Concurrency](17_concurrency.vibe.md) covers
it where the machinery makes sense.

## Which one to reach for

Now that you have seen them:

| you want | use |
|---|---|
| a counter or accumulator in one function | `let mut` |
| to build an array, then read it | `ArrayBuilder`, then freeze it |
| to build text | `StringBuilder` |
| a value whose field changes over time | `struct S { mut f: T }` |
| state shared across calls, mediated | an effect and a `handle` |

The first row covers most code. [Collections](13_collections.vibe.md)
covers the builders.

Next: [Structs, enums, and match](07_data.vibe.md).
