# 01 — Values and functions

This chapter *is* a `.vibe.md`: every ` ```vibe run ` block is really compiled
and run by `pkf run vibe-md-tutorial`
(`bash scripts/vibe_md.sh check book/en/*.vibe.md`), and the ` ```output `
block right after it is that run's output, pasted in (#1142). To refresh it
locally, run
`bash scripts/vibe_md.sh write book/en/01_values_functions.vibe.md`.

日本語版: [01_values_functions.vibe.md](../ja/01_values_functions.vibe.md)

## Values and primitive types

`let` binds. The type annotation is optional — it is inferred.

`println` is a builtin, so nothing is imported here. Printing costs a
`Stdout` row on every function that reaches it — see
[Capabilities](10_capabilities.vibe.md).

```vibe run
fn main with Console {
  let x: Int = 42
  // 63-bit tagged (#1877); literals go up to 2^62-1
  let d: Double = 3.14
  // 64-bit float (the default for a decimal literal)
  let b: Bool = true
  let s = "answer \{x}"
  // string interpolation is \{expr}
  let c = 'A'
  // a char literal is its character code (Int); 'A' == 65
  println("x = \{x}")
  println("d = \{d}, to_string = \{Double::to_string(d)}")
  // Double interpolates with \{expr} too, or use Double::to_string
  println("d*100 as int = \{Double::to_int(d * 100.0)}")
  // Double::to_int when you want it rounded to an integer
  println("b = \{b}")
  println("s = \{s}")
  println("c = \{c}")
}
```

```output
x = 42
d = 3.14, to_string = 3.14
d*100 as int = 314
b = true
s = answer 42
c = 65
```

Watch out: indexing a string, `s[i]`, gives you the **character code (Int)**.
For a one-character String use `String::from_char_code(s[i])` or a slice.

## `mut` is block-scoped

vibe is pure by default. Local mutable state goes in a `let mut`, and leaves the
block as a value.

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

## Functions

`fn` is a keyword ([#1280](https://github.com/mizchi/vibe-lang/issues/1280)
landed it). It spells a function declaration and cannot be used as a binding or
parameter name, and `fn` is the one reserved word a raw identifier does not
rescue: `r#fn` is rejected too. Rename a colliding name to something like `fn_`.

Every other reserved word DOES take `r#`, and the message says so wherever the
word appears -- a binding, a parameter, or a function name.

```vibe skip
// skip: how reserved words are rejected -- every fragment here is a parse error
let fn = 1
// error: `fn` is a reserved word and cannot be used as a binding name;
//        this keyword cannot be escaped, so choose a different name
let r#fn = 1
// error: the same -- a raw identifier is not an escape hatch for `fn`
let test = 1
// error: `test` is a reserved word and cannot be used as a binding name;
//        write `r#test` to use it as a name
```

```vibe run
fn main() -> Unit with Stdout {
  // `test` is reserved (it opens a `test { ... }` block), but `r#test` is a name.
  let r#test = 1
  println(Int::to_string(r#test))
}
```

```output
1
```

All of the declaration forms below are runnable. A top-level function must be
fully annotated, and recursion does not need `rec`. The `let` form, generics and
labelled arguments all mean the same thing.

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
// generics

let inc: (Int) -> Int = (x) -> {
  x + 1
}
// the let form

let scaled: (x~: Int, y~: Int) -> Int = (x~, y~) -> {
  x * 10 + y
}

fn main with Console {
  println("add(1, 2) = \{add(1, 2)}")
  println("fact(5) = \{fact(5)}")
  println("identity(7) = \{identity(7)}")
  println("inc(41) = \{inc(41)}")
  println("scaled(x=4, y=2) = \{scaled(x=4, y=2)}")
  // a labelled call
}
```

```output
add(1, 2) = 3
fact(5) = 120
identity(7) = 7
inc(41) = 42
scaled(x=4, y=2) = 42
```

## Comments

`//` starts a line comment. There is no `/* */` block comment. Put a
comment on its own line when you want it between tokens of an
expression. `///` immediately above a declaration is that declaration's
doc comment (hover / `vibe doc-at` pick it up). `//#` is a section
heading used in the compiler sources — it is not a doc comment.

## Optional arguments

A trailing `name?: T` is optional. The caller writes a bare `T` or
omits it. The body sees `Option[T]`. Measured: `if bang` when
`bang?: Bool` is a type error (`if condition must be Bool`) — match the
`Option`.

```vibe run
fn greet(name: String, times?: Int) -> String {
  let n = match times {
    Some(v) => v,
    None => 1
  }
  String::concat(name, String::concat(" x", __to_string(n)))
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

## Lambda shorthand and placeholders

```vibe run
fn main with Console {
  let xs = [
    1,
    2,
    3
  ]
  let doubled = Array::map(xs, _ * 2)
  // a section for (v) -> v * 2
  let total = Array::fold(xs, 0, _ + _)
  // (acc, v) -> acc + v
  println("doubled = [\{Array::get(doubled, 0)}, \{Array::get(doubled, 1)}, \{Array::get(doubled, 2)}]")
  println("fold sum = \{total}")
}
```

```output
doubled = [2, 4, 6]
fold sum = 6
```

Next: [Control flow](02_control_flow.vibe.md).
The contract those types keep is in [Types and strings](08_types_strings.vibe.md).
