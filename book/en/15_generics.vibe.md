# 15 — Generics, traits, and derive

Previous: [Iteration](14_iteration.vibe.md)

日本語版: [15_generics.vibe.md](../ja/15_generics.vibe.md)

Writing the same function once for every type is the problem generics
solve. A type parameter goes in `[T]`, and a constraint on it goes in
`[T: Eq]`.

## One definition, many types

```vibe run
struct Box[T] {
  v: T
}

fn identity[T](x: T) -> T {
  x
}

fn main with Console {
  let b = Box::{
    v: 41
  }
  println("id = \{identity(b.v + 1)}")
}
```

```output
id = 42
```

`identity` works for any `T`. `Box[T]` holds any `T`, and the literal
above did not need to say which — it was inferred from `v: 41`. Pin it
explicitly with `Box[Int]::{ ... }` when inference has nothing to go on.

A top-level `fn` annotates its parameters and return type in full,
generic or not; inference fills in the call site, not the declaration.

## `derive` gives you the usual operations

Most types want equality, ordering, and a printable form. Ask for them:

```vibe run
enum Color {
  Red; Green; Blue
} derive (Eq, Show)

fn main with Console {
  println("eq = \{Color::Red == Color::Red}")
  println("neq = \{Color::Red == Color::Blue}")
  println("show = \{Color::Green}")
}
```

```output
eq = true
neq = false
show = Green
```

`derive (Eq, Ord, Show, Hash, Default)` are the five. `Eq` makes `==`
structural for the type, `Ord` gives `T::compare` returning `-1` / `0` /
`1`, and `Show` gives `T::to_string`, which is also what string
interpolation calls.

## Traits you write

A trait with methods is a contract, and a bound on it means "the caller
passes an implementation":

```vibe run
trait Measured {
  measure(Self) -> Int
}

impl [T] Measured for Array[T] {
  measure(self) -> Int {
    Array::length(self)
  }
}

fn size_of[T: Measured](x: T) -> Int {
  T::measure(x)
}

fn main with Console {
  let xs = [
    1,
    2,
    3
  ]
  println("size_of = \{size_of(xs)}")
}
```

```output
size_of = 3
```

`size_of` has no idea what `T` is. `T::measure` reaches the
implementation through a witness the caller supplies, which is how the
bound turns into a working call.

That witness is also the limit. A bound like `[T: Eq]` needs one, and a
container whose element type has been erased has none — so passing an
`Array[Int]` to `fn eq2[T: Eq](a: T, b: T)` is **rejected**:

```
no impl `Eq` for `Array[Int]`
```

You are told, at compile time. [Equality](16_equality.vibe.md) has the
rest of that story.

## Two you do not implement

`Send` is judged structurally by the compiler — primitives, tuples,
`Option` of `Send` parts, immutable structs and enums — so `impl Send for
X` is an error rather than a way to promise something. See
[Concurrency](17_concurrency.vibe.md).

`Default` is a builtin; `derive(Default)` registers the implementation.
Generic code that calls `T::default()` needs
`import @vibe/core { Default }`.

Next: [Equality](16_equality.vibe.md).
