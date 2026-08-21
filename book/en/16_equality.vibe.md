# 16 — Equality

Previous: [Generics, traits, and derive](15_generics.vibe.md)

日本語版: [16_equality.vibe.md](../ja/16_equality.vibe.md)

`==` compares by value. Two arrays with equal contents are equal, two
structs with equal fields are equal, and nothing here quietly compares
addresses instead.

There is exactly one boundary, and it is a compile error rather than a
wrong answer — see the end of the chapter.

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

fn main with Console {
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

fn main with Console {
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
}
```

```output
non-scalar elements = true, differ = false
function returns    = true
empty and empty     = true
after one push      = false
after both          = true
```

Annotate an empty literal, as `xs` and `ys` are above. `let xs = []` with
no annotation has no element type to compare by: two such bindings
compare equal while both stay empty, but pushing into one and then
comparing **traps at run time** rather than answering (#2157). The
annotation is the fix, and it is the only reason this chapter asks you
to write one.

## The one boundary: a generic `T` with no witness

Inside `fn f[T: Eq](a: T, b: T)`, the element type is gone by the time
code is generated, so `==` is answered by the `Eq` witness the caller
passes. For a type that has one, that works and gives the structural
answer:

```vibe run
fn eq2[T: Eq](a: T, b: T) -> Bool {
  a == b
}

fn main with Console {
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

fn main with Console {
  println("\{eq2([1], [1])}")
}
```

```
no impl `Eq` for `Array[Int]`
```

That is the whole of it. You are told at compile time; you never get a
comparison that silently answers by address.

Next: [Concurrency](17_concurrency.vibe.md).
