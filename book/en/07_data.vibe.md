# 03 — Data and pattern matching

Previous: [02 Control flow](04_control_flow.vibe.md)

日本語版: [07_data.vibe.md](../ja/07_data.vibe.md)

## tuple / array / record

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
  // destructuring is also available for pulling several fields into local names
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

An anonymous record reads its fields the same way, `r.name`. Destructuring is an
option when you want several fields under local names; it is not a workaround
for a missing accessor.

## struct and derive

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
  // derive(Ord): -1 / 0 / 1
  println("to_string(p) = \{Point::to_string(p)}")
  // derive(Show)
}
```

```output
p.x = 1
compare(p, {x:1,y:3}) = -1
to_string(p) = Point { x: 1, y: 2 }
```

## enum and match

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

## The match toolbox: guards, or-patterns, literals

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

## Destructuring and the `is` expression

### Irrefutable patterns at the top level

A pattern that always matches can bind at the top level too
([#1281](https://github.com/mizchi/vibe-lang/issues/1281)). However many names
it introduces, the right-hand side is evaluated **exactly once** and each name
is a projection out of that. Refutable patterns — an enum variant, a literal, an
or-pattern — can fail, so they are rejected; use `match` inside a function for
those. Type annotations and `export let <pattern>` are also not allowed: the
first has no single binding to annotate, and the second belongs in a separate
`export { .. }`.

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

### Binding inside a function body

The same shapes work in a function body, and combine with narrowing via the `is`
expression.

```vibe run
fn main with Console {
  let (a, b) = (1, 2)
  println("a + b = \{a + b}")
  let opt = Some(41)
  if opt is Some(w) {
    println("w = \{w}")
    // w is bound here
  }
  println("opt is Some(_) = \{opt is Some(_)}")
  // -> Bool
}
```

```output
a + b = 3
w = 41
opt is Some(_) = true
```

## Accumulate with ArrayBuilder

`ArrayBuilder` is the accumulation type — push, then freeze — and it is the
default when you are building something in one go. `Array::push` is available
too: it grows a raw `Array` in place, and the growth is visible through every
reference to that `Array` (aliases, arguments, struct fields, captures). This
behaves identically on the linear, RC and wasm-gc backends, and is pinned in the
compiler tests as the contract from
[#1285](https://github.com/mizchi/vibe-lang/issues/1285). The rule of thumb:
`ArrayBuilder` when you build once and only read afterwards, `Array::push` when
you are growing an `Array` that already exists.

```vibe run
fn main with Console {
  let arr = {
    let bld = ArrayBuilder::new()
    ArrayBuilder::push(bld, 1)
    ArrayBuilder::push(bld, 2)
    ArrayBuilder::freeze(bld)
    // -> Array[Int]
  }
  println("length = \{Array::length(arr)}")
  println("arr[1] = \{Array::get(arr, 1)}")
}
```

```output
length = 2
arr[1] = 2
```

Next: [04 Option](08_option.vibe.md)
