# 16 — Equality

Previous: [Generics, traits, and derive](15_generics.vibe.md)

日本語版: [16_equality.vibe.md](../ja/16_equality.vibe.md)

`==` compares by value. Two arrays with equal contents are equal, two
structs with equal fields are equal, and nothing here quietly compares
addresses instead.

One edge is worth knowing, and it does not answer wrongly either: a
generic `T` with no `Eq` witness is a **compile error**. It is below.

## The ordinary cases

Scalars, tuples, structs and enums with `derive(Eq)`, `Bytes` by
content, and arrays.

```vibe run
struct Point {
  x: Int; y: Int
} derive (Eq)

fn same_ints(a: Array[Int], b: Array[Int]) -> Bool {
  a == b
}

fn main allows Console {
  println("lits = \{[1, 2] == [1, 2]}")
  let a = [
    1,
    2
  ]
  let b = [
    1,
    2
  ]
  println("lets = \{a == b}")
  println("fn   = \{same_ints(a, b)}")
  println("tuple = \{([1, 2], 0) == ([1, 2], 0)}")
  println("struct = \{Point::{ x: 1, y: 2 } == Point::{ x: 1, y: 2 }}")
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

## The cases people expect to be exceptions

Arrays whose elements are not scalars, arrays that arrive as a function's
return value, and arrays that started out empty are compared by value
too. The last one is worth running: pushing into one of two empty arrays
gives the right answer, not a stale one.

```vibe run
fn mk() -> Array[Int] {
  [
    1,
    2
  ]
}

fn main allows Console {
  let pairs: Array[(Int, Int)] = [(1, 2)]
  let same: Array[(Int, Int)] = [(1, 2)]
  let other: Array[(Int, Int)] = [(1, 3)]
  println("non-scalar elements = \{pairs == same}, differ = \{pairs == other}")
  println("function returns    = \{mk() == mk()}")
  let xs: Array[Int] = []
  let ys: Array[Int] = []
  println("empty and empty     = \{xs == ys}")
  Array::push(xs, 1)
  println("after one push      = \{xs == ys}")
  Array::push(ys, 1)
  println("after both          = \{xs == ys}")
  let us = []
  let vs = []
  Array::push(us, 1)
  Array::push(vs, 2)
  println("no annotation       = \{us == vs}")
}
```

```output
non-scalar elements = true, differ = false
function returns    = true
empty and empty     = true
after one push      = false
after both          = true
no annotation       = false
```

`us` and `vs` carry no annotation, and they compare by content all the
same: an unannotated `let xs = []` takes its element type from the
`Array::push` calls that fill it (#2157) — as long as the pushed value
says what it is. A literal does, and so does an array, tuple or struct
of literals, or an `if` whose branches agree.

Push a **name** or a **call result** instead and that binding's syntax
does not say the element type. `vibe run` and `vibe test` still type it,
and the comparison answers by content when the element is one `==` can
compare: `Int`, `String`, `Double`, `Bytes`, an array, an option, a
tuple, or a declared struct. What does not compare is an element with no
structural comparator, such as a closure field. That comparison is a
build error that names the edit, not an address comparison and not a
trap you meet at run time. `vibe check` does not run this pass. The
annotation on `xs` and `ys` above states the element type in the
binding itself.

A generic struct is compared at each concrete instantiation.
`Box[Double]`, `Box[Bytes]` and `Box[Array[Int]]` compare by content,
the same as `Box[Int]`. What still fails closed is an instantiation
whose argument is a type parameter of an enclosing function, and a
recursion that never closes, such as `Nest[T]` holding `Nest[Array[T]]`.

## The compile-time edge: a generic `T` with no witness

Inside `fn f[T: Eq](a: T, b: T)`, the element type is gone by the time
code is generated, so `==` is answered by the `Eq` witness the caller
passes. For a type that has one, that works and gives the structural
answer:

```vibe run
fn eq2[T: Eq](a: T, b: T) -> Bool {
  a == b
}

fn main allows Console {
  println("Int    same = \{eq2(1, 1)}, differ = \{eq2(1, 2)}")
  println("String same = \{eq2("x", "x")}, differ = \{eq2("x", "y")}")
}
```

```output
Int    same = true, differ = false
String same = true, differ = false
```

For a type that has no `Eq` witness, there is nothing to pass, and the
call is **rejected**:

```vibe skip
// skip: this is a compile error, shown for the message it produces
fn eq2[T: Eq](a: T, b: T) -> Bool { a == b }

fn main allows Console {
  println("\{eq2([1], [1])}")
}
```

```
no impl `Eq` for `Array[Int]`
```

That is the whole of it. A missing `Eq` witness is a compile error. A
comparison the language cannot answer is a build error that names the
edit. Neither one silently answers by address.

Next: [Concurrency](17_concurrency.vibe.md).
