# 08 — Option and the railway

Previous: [Structs, enums, and match](07_data.vibe.md)

日本語版: [08_option.vibe.md](../ja/08_option.vibe.md)

A value that might not be there has type `Option[T]`: either `Some(v)`
or `None`. It is an ordinary enum — nothing about it is built into the
compiler — but it is common enough that the language has three
shorthands for the thing you always want to do with it, which is *stop
early when there is nothing*.

## The type

```vibe run
fn half(n: Int) -> Option[Int] {
  if n % 2 == 0 {
    Some(n / 2)
  } else {
    None
  }
}

fn main with Console {
  let a = match half(10) {
    Some(v) => v,
    None => 0 - 1
  }
  let b = match half(3) {
    Some(v) => v,
    None => 0 - 1
  }
  println("half(10) = \{a}")
  println("half(3)  = \{b}")
}
```

```output
half(10) = 5
half(3)  = -1
```

`match` is always available and always works. The rest of this chapter
is about not writing it four times in a row.

## `?` — unwrap, or return `None` now

Put `?` after an expression of type `Option[T]` and you get the `T`. If
it was `None`, the enclosing function returns `None` immediately:

```vibe run
fn half(n: Int) -> Option[Int] {
  if n % 2 == 0 {
    Some(n / 2)
  } else {
    None
  }
}

fn sum_halves(a: Int, b: Int) -> Option[Int] {
  let x = half(a)?
  let y = half(b)?
  Some(x + y)
}

fn main with Console {
  println("sum_halves(4, 6) = \{sum_halves(4, 6)}")
  println("sum_halves(4, 3) = \{sum_halves(4, 3)}")
}
```

```output
sum_halves(4, 6) = Some(5)
sum_halves(4, 3) = None
```

The function has to return an `Option` itself, which is the honest part
of the deal: `?` does not make the absence disappear, it passes it to
your caller.

## `let*` — the same idea for a whole block

`let* x = e` binds the contents of a `Some`, and on `None` the block it
sits in evaluates to `None`:

```vibe run
fn half(n: Int) -> Option[Int] {
  if n % 2 == 0 {
    Some(n / 2)
  } else {
    None
  }
}

fn sum_halves(a: Int, b: Int) -> Option[Int] {
  let* x = half(a)
  let* y = half(b)
  Some(x + y)
}

fn main with Console {
  println("sum_halves(4, 6) = \{sum_halves(4, 6)}")
  println("sum_halves(4, 3) = \{sum_halves(4, 3)}")
}
```

```output
sum_halves(4, 6) = Some(5)
sum_halves(4, 3) = None
```

`?` and `let*` do the same job here; `?` suits one expression in the
middle of a line, `let*` suits a run of steps that all have to succeed.

## `guard` — bind, or leave

Sometimes you do not want to propagate the `None` — you want to handle
it and carry on with an unwrapped value. `guard` binds for the **rest of
the scope**, and its `else` must leave:

```vibe run
fn double_or_zero(o: Option[Int]) -> Int {
  guard o is Some(v) else {
    return 0
  }
  v * 2
}

fn main with Console {
  println("double_or_zero(Some(21)) = \{double_or_zero(Some(21))}")
  println("double_or_zero(None) = \{double_or_zero(None)}")
}
```

```output
double_or_zero(Some(21)) = 42
double_or_zero(None) = 0
```

Note that `v` is in scope on the last line, with no nesting — that is
the whole point of `guard` over `match`.

The `else` must actually leave the function, by `return` or by
`throw(...)`. It has to, because everything after the `guard` is written
assuming `v` exists. When the fallback is a *value* rather than an exit,
use `if o is Some(v) { ... } else { ... }` instead.

## Asking without unwrapping

When you only want to know, `is` gives you a `Bool`:

```vibe run
fn half(n: Int) -> Option[Int] {
  if n % 2 == 0 {
    Some(n / 2)
  } else {
    None
  }
}

fn main with Console {
  println("half(10) is Some(_) = \{half(10) is Some(_)}")
  println("half(3) is None = \{half(3) is None}")
}
```

```output
half(10) is Some(_) = true
half(3) is None = true
```

## When absence is not the story

`Option` says a value is missing. It does not say *why*, and sometimes
why is the point — a parse failed, a file was malformed. For that, a
function declares `with Exception` and throws a message, which the next
chapters cover. Reach for `Option` when "not there" is the whole story,
and for `Exception` when the caller deserves a reason.

Next: [Modules and packages](09_modules_packages.vibe.md).
