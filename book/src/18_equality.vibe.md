# 18 — Equality

`==` is supposed to mean structural equality everywhere (ADR-0097).
Most of the surface already does. A few paths still compare by
reference; those are listed at the end so you do not have to discover
them as a silent wrong answer.

## What already compares by value

Scalars, tuples, structs/enums with `derive(Eq)`, `Bytes` (by content),
and `Array[T]` when the element type is known.

```vibe run
import @vibe/prelude {
  stdout_write
}

struct Point {
  x: Int; y: Int
} derive (Eq)

fn same_ints(a: Array[Int], b: Array[Int]) -> Bool {
  a == b
}

fn main with Stdout {
  stdout_write("lits = \{[1, 2] == [1, 2]}\n")
  let a = [
    1,
    2
  ]
  let b = [
    1,
    2
  ]
  stdout_write("lets = \{a == b}\n")
  stdout_write("fn   = \{same_ints(a, b)}\n")
  stdout_write("tuple = \{([1, 2], 0) == ([1, 2], 0)}\n")
  stdout_write("struct = \{Point::{ x: 1, y: 2 } == Point::{ x: 1, y: 2 }}\n")
}
```

```output
lits = true
lets = true
fn   = true
tuple = true
struct = true
```

`Bytes` is content equality too, including as a tuple element or a
`derive(Eq)` field.

## Empty arrays need an element type

`let xs = []` does not pick an element type. Two such bindings compare
equal while they stay empty. If you later push into them and then
compare, the compiler refuses to silently fall back to reference
equality — annotate: `let xs: Array[Int] = []`.

## What is still reference equality

- An erased type variable (`[T: Eq]`'s `T`) — there is no element type
  left to rewrite `==`.
- Some function-return paths and empty-literal bindings that never
  grew a type.
- A named array whose element type is not a scalar.

When in doubt, write the comparison you mean (`Array::length` plus a
loop, or a `derive(Eq)` type you control). Do not assume `==` on a
generic `T` is structural.

Next: [A small program](19_a_small_program.vibe.md).
