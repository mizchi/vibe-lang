# 07 — Structs, enums, and match

Previous: [Mutation, regions, and escape](06_mutation.vibe.md)

日本語版: [07_data.vibe.md](../ja/07_data.vibe.md)

Data in vibe has one of two shapes, and the distinction runs through the
whole language:

- a value that has **all** of several things — a point has an `x` *and*
  a `y` — is a **struct**;
- a value that is **one** of several things — a shape is a circle *or* a
  rectangle — is an **enum**.

`match` is how you take either apart, and the compiler checks that you
covered the cases.

## Quick shapes: tuple, array, record

Before the named forms, three lightweight ones. A tuple groups a fixed
number of values positionally, an array holds many of one type, and a
record is a struct you did not bother to name:

```vibe run
fn main with Console {
  let t = (1, "two", true)
  println("t.0 = \{t.0}")
  let a = [
    1,
    2,
    3
  ]
  println("a[0] = \{a[0]}")
  println("Array::length(a) = \{Array::length(a)}")
  let r = record {
    name: "vibe",
    ver: 1
  }
  println("r.name = \{r.name}, r.ver = \{r.ver}")
  let record {
    name: n,
    ver: v
  } = r
  println("n = \{n}, v = \{v}")
}
```

```output
t.0 = 1
a[0] = 1
Array::length(a) = 3
r.name = vibe, r.ver = 1
n = vibe, v = 1
```

The last two lines destructure: pulling several fields out under local
names, which reads better than repeating `r.` when you want most of them.

## Structs

A `struct` names the shape, and `derive` asks the compiler to write the
obvious operations for it:

```vibe run
struct Point {
  x: Int; y: Int
} derive (Eq, Ord, Show)

fn main with Console {
  let p = Point::{
    x: 1, y: 2
  }
  println("p.x = \{p.x}")
  println("compare(p, {x:1,y:3}) = \{Point::compare(p, Point::{ x: 1, y: 3 })}")
  println("to_string(p) = \{Point::to_string(p)}")
}
```

```output
p.x = 1
compare(p, {x:1,y:3}) = -1
to_string(p) = Point { x: 1, y: 2 }
```

`Eq` gives `==`, `Ord` gives `compare` (returning -1, 0 or 1), and
`Show` gives `to_string` and therefore interpolation. Write them out by
hand only when the derived meaning is not the one you want.
[Generics, traits, and derive](15_generics.vibe.md) goes further.

## Enums

An `enum` lists the alternatives, each carrying its own data, and
`match` dispatches on which one you have:

```vibe run
enum Shape {
  Circle(Int);
  Rect(Int, Int)
}

fn area(s: Shape) -> Int {
  match s {
    Circle(r) => 3 * r * r,
    Rect(w, h) => w * h
  }
}

fn main with Console {
  println("area(Circle(2)) = \{area(Circle(2))}")
  println("area(Rect(6, 7)) = \{area(Rect(6, 7))}")
}
```

```output
area(Circle(2)) = 12
area(Rect(6, 7)) = 42
```

Add a `Triangle` to that enum and `area` stops compiling until you say
what its area is. That is the property worth having: the compiler finds
the places that need updating, so adding a case is a mechanical job
rather than a hunt.

## What `match` can express

Patterns are not limited to variants. You can match literals, offer
alternatives with `|`, add a condition with `if`, and catch the rest
with `_`:

```vibe run
fn classify(n: Int) -> String {
  match n {
    0 => "zero",
    1|2 => "small",
    x if x < 0 => "negative",
    _ => "big"
  }
}

fn main with Console {
  println("classify(0) = \{classify(0)}")
  println("classify(2) = \{classify(2)}")
  println("classify(-5) = \{classify(-5)}")
  println("classify(99) = \{classify(99)}")
}
```

```output
classify(0) = zero
classify(2) = small
classify(-5) = negative
classify(99) = big
```

Arms are tried in order, so `x if x < 0` is reached only for values that
were not `0`, `1` or `2`.

## Binding by shape

A pattern that cannot fail can bind directly, without `match` — at the
top level of a file as well as inside a function. The right-hand side is
evaluated once and each name is a projection out of it:

```vibe run
struct Version {
  major: Int; minor: Int
}

let (left, right) = (20, 22)

let record {
  name
} = record {
  name: "vibe"
}

let Version::{
  major, minor
} = Version::{
  major: 0, minor: 3
}

fn main with Console {
  println("sum = \{left + right}, \{name} \{major}.\{minor}")
}
```

```output
sum = 42, vibe 0.3
```

A pattern that *can* fail — an enum variant, a literal — needs `match`,
or the `is` expression, which tests a pattern and binds its names for
the branch that follows:

```vibe run
fn main with Console {
  let (a, b) = (1, 2)
  println("a + b = \{a + b}")
  let opt = Some(41)
  if opt is Some(w) {
    println("w = \{w}")
  }
  println("opt is Some(_) = \{opt is Some(_)}")
}
```

```output
a + b = 3
w = 41
opt is Some(_) = true
```

`opt is Some(_)` on its own is just a `Bool`, which is often all you
need.

Next: [Option and the railway](08_option.vibe.md).
