# 04 — Control flow

Previous: [Values and functions](03_values_functions.vibe.md)

日本語版: [04_control_flow.vibe.md](../ja/04_control_flow.vibe.md)

Everything here is an expression: `if` produces a value, and so does a
loop. That is worth getting used to early, because it removes most of
the reasons other languages need a mutable variable.

## `if`

```vibe run
fn main with Console {
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

Both branches must produce the same type, since the whole `if` is one
value.

## `while` and `return`

`while` is the loop you already know. `return` leaves the function — not
just the loop — which is what you want for a search:

```vibe run
fn find_first_neg(arr: Array[Int]) -> Int {
  let mut i = 0
  while i < Array::length(arr) {
    if Array::get(arr, i) < 0 {
      return i
    }
    i = i + 1
  }
  return -1
}

fn main with Console {
  println("find_first_neg([3, 1, -2, 5]) = \{find_first_neg([3, 1, -2, 5])}")
  println("find_first_neg([1, 2]) = \{find_first_neg([1, 2])}")
}
```

```output
find_first_neg([3, 1, -2, 5]) = 2
find_first_neg([1, 2]) = -1
```

## `loop` — a loop that carries values

`while` needs a mutable counter. `loop` does not: it declares
parameters, `continue` supplies the next round's values, and `break`
ends it with a result.

```vibe run
fn main with Console {
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

The rule to remember: **`continue` takes one value per loop parameter,
`break` takes one result.** A bare `continue` repeats with everything
unchanged. If you give `continue` the wrong number of values the
compiler says so and names both counts.

Since `break` takes a single result, returning two things means
returning a tuple:

```vibe run
fn main with Console {
  let r = loop (i = 0, acc = 0) {
    if i >= 3 {
      break (acc, i)
    }
    continue (i + 1, acc + i)
  }
  println("r = (\{r.0}, \{r.1})")
}
```

```output
r = (3, 3)
```

## `for ... in` collects

A `for-in` is an expression too, and it evaluates to the `Array` of its
body's results. Add a name before the element to get the index:

```vibe run
fn main with Console {
  let doubled = for x in [1, 2, 3] {
    x * 2
  }
  let with_index = for i, x in [10, 20] {
    i + x
  }
  println("doubled = [\{Array::get(doubled, 0)}, \{Array::get(doubled, 1)}, \{Array::get(doubled, 2)}]")
  println("with_index = [\{Array::get(with_index, 0)}, \{Array::get(with_index, 1)}]")
}
```

```output
doubled = [2, 4, 6]
with_index = [10, 21]
```

## `|>`

`x |> f` is `f(x)`, which lets a transformation read left to right
instead of inside out:

```vibe run
import @vibe/builtin {
  trait Iterator
}

fn pair(a: Int, b: Int) -> Int {
  a * 10 + b
}

fn main with Console {
  let trimmed_len = "  hi  " |> String::trim |> String::length
  let arr_len = [1, 2, 3] |> Array::length
  let mapped = [1, 2, 3] |> Iterator::map(_, _ * 2)
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

By default the piped value becomes the first argument. To put it
somewhere else, mark the position with a bare `_`: `x |> f(a, _)` is
`f(a, x)`, and a slot may repeat, so `7 |> pair(_, _)` is `pair(7, 7)`.

A `_` inside a larger expression is a different thing — the lambda
shorthand from the last chapter. That is why `Iterator::map(_, _ * 2)` has
two of them doing unrelated jobs: the first is the pipe slot, the second
is `(v) -> v * 2`.

Next: [Types and strings](05_types_strings.vibe.md).
