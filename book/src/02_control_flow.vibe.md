# 02 — Control flow

Previous: [01 Values and functions](01_values_functions.vibe.md)

日本語版: [02_control_flow.vibe.md](../ja/02_control_flow.vibe.md)

## `if` is an expression

```vibe run
fn main with Stdout {
  let v = if 1 < 2 {
    "yes"
  } else {
    "no"
  }
  println("v = \{v}")
}
```

```output
v = yes
```

## `while` and early `return` (current)

`return` leaves the whole function, not just the loop. This spelling was settled
as "keep it" in
[#1283](https://github.com/mizchi/vibe-lang/issues/1283) — the pattern-binding
early exit `guard ... else { ... }` added by that same issue is covered in
[04 Option](04_option.vibe.md#guard--bind-or-bail-out).

```vibe run
fn find_first_neg(arr: Array[Int]) -> Int {
  let mut i = 0
  while i < Array::length(arr) {
    if Array::get(arr, i) < 0 {
      return i
    }
    i = i + 1
  }
  // An early `return i` and the implicit value at the end of the function are
  // the same thing -- the function's result -- so this one is spelled
  // `return -1` to match (a bare `-1` as the last expression of the body
  // behaves identically: the while block closes as a Unit statement, which
  // leaves `-1` standing alone as the final expression).
  return -1
}

fn main with Stdout {
  println("find_first_neg([3, 1, -2, 5]) = \{find_first_neg([3, 1, -2, 5])}")
  println("find_first_neg([1, 2]) = \{find_first_neg([1, 2])}")
}
```

```output
find_first_neg([3, 1, -2, 5]) = 2
find_first_neg([1, 2]) = -1
```

## `loop` — tail recursion with parameters

`loop (arg = initial, ...)` plus `continue(next values...)` plus
`break result`. It writes a fold without any mutable variable.

```vibe run
fn main with Stdout {
  let sum = loop (i = 0, acc = 0) {
    if i >= 10 {
      break acc
    }
    continue (i + 1, acc + i)
  }
  println("sum = \{sum}")
}
```

```output
sum = 45
```

`continue(...)` and `break ...` look alike but are not symmetric, and
**[#1284](https://github.com/mizchi/vibe-lang/issues/1284) settled this as
"leave it as is"**. They count different things, so there is nothing to align:

- `continue(a, b)` passes **the loop's parameters**. You pass exactly as many as
  `loop (i = ..., acc = ...)` declared.
- `break e` passes **the loop's result**. A `loop` is one expression with one
  value, so there is always exactly one result. The parentheses in
  `break(a, b)` are ordinary expression parentheses passing **one tuple**
  `(a, b)`; there is no `break a, b` producing a two-valued loop result.

What we did instead was make the mix-up **a compile error**. If `continue` gets
a different number of arguments than the loop has parameters, it fails and says
which count is which:

```
continue: this loop declares 2 parameter(s) (i, acc), but continue was given
1 argument(s). `continue` passes a new value for EVERY loop parameter; use a
bare `continue` to repeat with the current values unchanged. `break` is NOT
symmetric with this — it takes the loop's single result value, so
`break (a, b)` is one tuple. (#1284)
```

A `continue` with no arguments at all means "go round again with every parameter
unchanged", and that still works.

```vibe run
fn main with Stdout {
  let r = loop (i = 0, acc = 0) {
    if i >= 3 {
      break (acc, i)
    }
    // break(acc, i) is the tuple (acc, i)
    continue (i + 1, acc + i)
  }
  println("r = (\{r.0}, \{r.1})")
  // r: (Int, Int) -- not `break acc, i`
}
```

```output
r = (3, 3)
```

## `for-in` returns an Array

```vibe run
fn main with Stdout {
  let doubled = for x in [
    1,
    2,
    3
  ] {
    x * 2
  }
  // [2, 4, 6]
  let with_index = for i, x in [
    10,
    20
  ] {
    i + x
  }
  // [10, 21]
  println("doubled = [\{Array::get(doubled, 0)}, \{Array::get(doubled, 1)}, \{Array::get(doubled, 2)}]")
  println("with_index = [\{Array::get(with_index, 0)}, \{Array::get(with_index, 1)}]")
}
```

```output
doubled = [2, 4, 6]
with_index = [10, 21]
```

## The pipe operator

`x |> f` is `f(x)`. If the call contains no **bare** `_`, the value goes in as
the first argument. A bare `_` is a pipe slot and the value lands there
(`x |> f(a, _)` is `f(a, x)`). The same slot may repeat, so `x |> f(_, _)` is
`f(x, x)`.

A **compound** expression containing `_`, like `_ * 2`, is not a slot but a
section lambda (`(v) -> v * 2`). So read `xs |> Array::map(_, _ * 2)` as
`Array::map(xs, (v) -> v * 2)`. Do not conflate these two roles of `_`.

A user-defined `Type::method` may be typed as `value.method(...)`, but this
tutorial always writes the canonical form `Type::method(value, ...)`.

```vibe run
fn pair(a: Int, b: Int) -> Int {
  a * 10 + b
}

fn main with Stdout {
  let trimmed_len = "  hi  " |> String::trim |> String::length
  let arr_len = [
    1,
    2,
    3
  ] |> Array::length
  let mapped = [
    1,
    2,
    3
  ] |> Array::map(_, _ * 2)
  let repeated = 7 |> pair(_, _)
  println("trimmed_len = \{trimmed_len}")
  println("arr_len = \{arr_len}")
  println("mapped = [\{Array::get(mapped, 0)}, \{Array::get(mapped, 1)}, \{Array::get(mapped, 2)}]")
  println("repeated = \{repeated}")
}
```

```output
trimmed_len = 2
arr_len = 3
mapped = [2, 4, 6]
repeated = 77
```

Next: [03 Data](03_data.vibe.md)
