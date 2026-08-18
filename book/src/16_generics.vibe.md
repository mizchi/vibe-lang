# 16 — Generics, traits, and derive

A type parameter is written `[T]`. A bound is written `[T: Eq + Ord]`.
The same `+` joins effect names on a row (`with Exception + Fs`) so a
comma never has to mean two things.

## Generic functions and structs

A top-level `fn` needs full annotations. Type arguments on a struct
literal can be inferred from the fields, or pinned with `Box[Int]::{ ... }`.

```vibe run
import @vibe/prelude {
  stdout_write
}

struct Box[T] {
  v: T
}

fn identity[T](x: T) -> T {
  x
}

fn main with Stdout {
  let b = Box::{
    v: 41
  }
  stdout_write("id = \{identity(b.v + 1)}\n")
}
```

```output
id = 42
```

## `derive`

`derive (Eq, Ord, Show, Hash, Default)` is the usual way to get the
operations a struct or enum is expected to have. `Eq` is a marker:
structural `==` is generated as `T::equals`. `Ord` gives
`T::compare -> Int` (`-1` / `0` / `1`). `Show` gives `T::to_string`,
which interpolation also uses.

```vibe run
import @vibe/prelude {
  stdout_write
}

enum Color {
  Red; Green; Blue
} derive (Eq, Show)

fn main with Stdout {
  stdout_write("eq = \{Color::Red == Color::Red}\n")
  stdout_write("neq = \{Color::Red == Color::Blue}\n")
  stdout_write("show = \{Color::Green}\n")
}
```

```output
eq = true
neq = false
show = Green
```

## Traits you write

A marker trait (no methods) is for bounds the compiler already
understands, like `Eq`. A method-bearing trait carries a witness
dictionary, and that is what you want for user code. Marker `impl`s on
`Array` / `Bytes` do **not** satisfy `[T: Eq]` — the element type has
been erased, so `==` would silently become reference equality.

```vibe run
import @vibe/prelude {
  stdout_write
}

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

fn main with Stdout {
  let xs = [
    1,
    2,
    3
  ]
  stdout_write("size_of = \{size_of(xs)}\n")
}
```

```output
size_of = 3
```

`Send` is not a user trait. The compiler judges it structurally
(primitives, tuples, `Option` of Send parts, immutable structs/enums).
`impl Send for X` is an error. See [Concurrency](11_concurrency.vibe.md).

`Default` is a builtin. `import @vibe/core { Default }` if generic code
needs to call `T::default()`. `derive(Default)` registers the impl.

Next: [Iteration](17_iteration.vibe.md).
