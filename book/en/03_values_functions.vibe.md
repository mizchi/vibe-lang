# 03 — Values and functions

Previous: [A small program](02_a_small_program.vibe.md)

日本語版: [03_values_functions.vibe.md](../ja/03_values_functions.vibe.md)

The tour starts here. This chapter is `let`, the primitive types, and
every way to write a function.

## Binding values

`let` binds a name. The type annotation is optional — it is inferred —
and bindings do not change once made.

```vibe run
fn main with Console {
  let x = 42
  let name = "vibe"
  let ratio = 0.5
  let ready = true
  println("\{name} \{x} \{ratio} \{ready}")
}
```

```output
vibe 42 0.5 true
```

The primitives are `Int`, `Double`, `Bool`, `String` and `Char`. Write
the annotation when you want it documented or when inference has no
opinion:

```vibe run
fn main with Console {
  let x: Int = 42
  let d: Double = 3.14
  let b: Bool = true
  let c = 'A'
  println("x = \{x}")
  println("d = \{d}, rounded = \{Double::to_int(d * 100.0)}")
  println("b = \{b}")
  println("c = \{c}")
}
```

```output
x = 42
d = 3.14, rounded = 314
b = true
c = 65
```

Two things to notice. `\{...}` inside a string is interpolation — any
expression goes in there. And `'A'` printed `65`: a character literal
*is* its code point, an `Int`. Indexing a string also gives a number —
`s[0]` is the **byte** at that offset, not a one-character string. For
ASCII the code point and the byte are the same number; beyond ASCII they
are not, and [Types and strings](05_types_strings.vibe.md) covers that.
When you want that byte back as its own one-byte `String`, use
`String::from_byte(s[0])` — for ASCII that byte is the whole
character, and only there.

The exact ranges and representations — `Int` is 63 bits wide, `String`
is bytes — are in [Types and strings](05_types_strings.vibe.md). You can
write a lot of vibe before they matter.

## Local mutation, in a block

vibe is immutable by default. When an algorithm wants a counter, `let
mut` gives you one, and the block it lives in evaluates to a value:

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

The mutable binding does not leave the block; `y` is an ordinary
immutable `Int`. [Mutation, regions, and escape](06_mutation.vibe.md) is
where this gets interesting.

## Writing functions

`fn` declares one. Top-level functions annotate their parameters and
return type; recursion needs no keyword.

```vibe run
fn add(x: Int, y: Int) -> Int {
  x + y
}

fn fact(n: Int) -> Int {
  if n < 2 {
    1
  } else {
    n * fact(n - 1)
  }
}

fn identity[T](x: T) -> T {
  x
}

let inc: (Int) -> Int = (x) -> {
  x + 1
}

let scaled: (x~: Int, y~: Int) -> Int = (x~, y~) -> {
  x * 10 + y
}

fn main with Console {
  println("add(1, 2) = \{add(1, 2)}")
  println("fact(5) = \{fact(5)}")
  println("identity(7) = \{identity(7)}")
  println("inc(41) = \{inc(41)}")
  println("scaled(x=4, y=2) = \{scaled(x=4, y=2)}")
}
```

```output
add(1, 2) = 3
fact(5) = 120
identity(7) = 7
inc(41) = 42
scaled(x=4, y=2) = 42
```

That block shows four things worth naming:

- **Generics.** `fn identity[T](x: T) -> T` works for any `T`.
  [Generics, traits, and derive](15_generics.vibe.md) adds bounds.
- **The `let` form.** A function is a value; `let inc: (Int) -> Int =
  (x) -> { ... }` is the same function written as a binding.
- **Labelled parameters.** `x~: Int` means callers write `x=4`, in any
  order, which is what you want once a function takes three `Int`s.
- **The body is an expression.** No `return` needed — the last
  expression is the result.

## Optional arguments

A trailing `name?: T` may be omitted by the caller. Inside the body it
arrives as `Option[T]`, so you say what the default is by matching:

```vibe run
fn greet(name: String, times?: Int) -> String {
  let n = match times {
    Some(v) => v,
    None => 1
  }
  "\{name} x\{n}"
}

fn main with Console {
  println(greet("hi"))
  println(greet("hi", 3))
}
```

```output
hi x1
hi x3
```

Because the body sees an `Option`, an optional `Bool` is not directly a
condition: `if flag` where `flag?: Bool` is a type error, and you match
it like any other `Option`. [Option and the railway](10_option.vibe.md)
covers the type properly.

## Shorthand for small lambdas

`_` stands in for an argument, which reads well when the lambda is one
operator wide:

```vibe run
fn main with Console {
  let xs = [
    1,
    2,
    3
  ]
  let doubled = Array::map(xs, _ * 2)
  let total = Array::fold(xs, 0, _ + _)
  println("doubled = [\{Array::get(doubled, 0)}, \{Array::get(doubled, 1)}, \{Array::get(doubled, 2)}]")
  println("fold sum = \{total}")
}
```

```output
doubled = [2, 4, 6]
fold sum = 6
```

`_ * 2` is `(v) -> v * 2`, and `_ + _` is `(acc, v) -> acc + v` — each
`_` takes the next argument.

## Comments

`//` starts a line comment; there is no block comment form, so a comment
between the tokens of an expression goes on its own line. `///`
immediately above a declaration is a doc comment, which hover and
`vibe doc-at` will show you.

## Names that are taken

Keywords cannot be used as names, but most can be escaped with a `r#`
prefix — `let r#test = 1` is fine even though `test` opens a test block.
`fn` is the exception and cannot be escaped; rename the binding instead.
The diagnostic tells you which case you are in.

Next: [Control flow](04_control_flow.vibe.md).
