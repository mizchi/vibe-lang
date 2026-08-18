# 04 — Option

Previous: [03 Data](03_data.vibe.md)

日本語版: [04_option.vibe.md](../ja/04_option.vibe.md)

## Option

A value that might not be there is an `Option[T]` — `Some(v)` or `None`.

```vibe run
import @vibe/prelude {
  stdout_write
}

fn half(n: Int) -> Option[Int] {
  if n % 2 == 0 {
    Some(n / 2)
  } else {
    None
  }
}

fn unwrap_or(o: Option[Int], fallback: Int) -> Int {
  match o {
    Some(v) => v,
    None => fallback
  }
}

fn main with Stdout {
  stdout_write("half(10) unwrap_or -1 = \{unwrap_or(half(10), -1)}\n")
  stdout_write("half(3)  unwrap_or -1 = \{unwrap_or(half(3), -1)}\n")
}
```

```output
half(10) unwrap_or -1 = 5
half(3)  unwrap_or -1 = -1
```

## `let*` — bind and short-circuit

`let* x = e` unwraps a `Some(x)` and binds it; on `None` the whole block
short-circuits to `None`. The enclosing function has to return the matching
`Option[...]`.

```vibe run
import @vibe/prelude {
  stdout_write
}

fn half(n: Int) -> Option[Int] {
  if n % 2 == 0 {
    Some(n / 2)
  } else {
    None
  }
}

fn unwrap_or(o: Option[Int], fallback: Int) -> Int {
  match o {
    Some(v) => v,
    None => fallback
  }
}

fn sum_halves(a: Int, b: Int) -> Option[Int] {
  let* x = half(a)
  // a None ends it right here
  let* y = half(b)
  Some(x + y)
}

fn main with Stdout {
  stdout_write("sum_halves(4, 6) unwrap_or -1 = \{unwrap_or(sum_halves(4, 6), -1)}\n")
  stdout_write("sum_halves(4, 3) unwrap_or -1 = \{unwrap_or(sum_halves(4, 3), -1)}\n")
}
```

```output
sum_halves(4, 6) unwrap_or -1 = 5
sum_halves(4, 3) unwrap_or -1 = -1
```

## `?` — unwrap or return early

`e?` evaluates to the contents of a `Some(v)`, and on `None` early-returns
`None` from the enclosing function.

```vibe run
import @vibe/prelude {
  stdout_write
}

fn half(n: Int) -> Option[Int] {
  if n % 2 == 0 {
    Some(n / 2)
  } else {
    None
  }
}

fn unwrap_or(o: Option[Int], fallback: Int) -> Int {
  match o {
    Some(v) => v,
    None => fallback
  }
}

fn first_half(a: Int, b: Int) -> Option[Int] {
  let x = half(a)?
  let _unused = half(b)?
  Some(x)
}

fn main with Stdout {
  stdout_write("first_half(4, 6) unwrap_or -1 = \{unwrap_or(first_half(4, 6), -1)}\n")
  stdout_write("first_half(4, 3) unwrap_or -1 = \{unwrap_or(first_half(4, 3), -1)}\n")
}
```

```output
first_half(4, 6) unwrap_or -1 = 2
first_half(4, 3) unwrap_or -1 = -1
```

## `guard` — bind or bail out

`guard e is PAT else { ... }` unwraps a `Some(v)` and binds `v` **for the rest
of the scope**; if it does not match, control enters the `else`. It writes
"unwrap and carry on" without the rightward nesting of a `match`.

The `else` **must** bail out. The construct desugars to
`match e { PAT => <the rest>, _ => else }`, so the `else` arm sits where the
remainder of the block would be evaluated — if it did not bail out there would
be a path that goes on to use an unbound `v`. The accepted exits are `return`
and a direct `throw(...)` (measured: `guard o is Some(v) else { throw("no value") }`
is accepted as long as the function's row carries `Exception`, and the caller
can catch it with `handle` — see [05 Effects](05_effects.vibe.md#the-exception-boundary--perform--handle)).
Any other `perform` might resume, so it does not count as an exit.

When the fallback is a *value* rather than an exit, use
`if e is PAT { .. } else { .. }`.

> The older spelling `let PAT = e else { ... }` (#760(1)) is gone and now
> produces a parse error that says so by name. It was never a synonym: in the
> old form the `else` became the value of **the entire rest of the block**, so
> `let Some(v) = o else { 0 }` could silently replace the remainder of the
> function with `0`. Requiring `guard` to bail out is what removed that shape.

```vibe run
import @vibe/prelude {
  stdout_write
}

fn double_or_zero(o: Option[Int]) -> Int {
  guard o is Some(v) else {
    return 0
  }
  v * 2
  // v is available here
}

fn main with Stdout {
  stdout_write("double_or_zero(Some(21)) = \{double_or_zero(Some(21))}\n")
  stdout_write("double_or_zero(None) = \{double_or_zero(None)}\n")
}
```

```output
double_or_zero(Some(21)) = 42
double_or_zero(None) = 0
```

## Quick checks use the `is` expression

```vibe run
import @vibe/prelude {
  stdout_write
}

fn half(n: Int) -> Option[Int] {
  if n % 2 == 0 {
    Some(n / 2)
  } else {
    None
  }
}

fn main with Stdout {
  stdout_write("half(10) is Some(_) = \{half(10) is Some(_)}\n")
  // true
  stdout_write("half(3) is None = \{half(3) is None}\n")
  // true
}
```

```output
half(10) is Some(_) = true
half(3) is None = true
```

Aborting *with a reason* is the next chapter's
[Exception boundary](05_effects.vibe.md#the-exception-boundary--perform--handle).

Next: [05 Effects](05_effects.vibe.md)
