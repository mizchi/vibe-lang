# 17 — Iteration

vibe keeps two layers (ADR-0099):

1. **Eager `Array::*`** — `map`, `fold`, `filter`, `for x in xs`. The
   result is an array, immediately.
2. **Pull `AsyncIter`** — a `next` that can suspend. Used when the
   producer is a stream, not a collection you already hold.

There is no lazy iterator combinator chain in the prelude. If you want
one pass over an array, write the `Array::*` call or a `for`. If you
want to pull, use the pull type, not `for await` (`for await` was
removed; suspend lives on the effect row).

## Eager array tools

```vibe run
import @vibe/prelude {
  stdout_write
}

fn main with Stdout {
  let xs = [
    1,
    2,
    3,
    4
  ]
  let evens = Array::filter(xs, (n) -> {
    n % 2 == 0
  })
  let sum = Array::fold(xs, 0, _ + _)
  let doubled = for x in xs {
    x * 2
  }
  stdout_write("evens length = \{Array::length(evens)}\n")
  stdout_write("sum = \{sum}\n")
  stdout_write("doubled[3] = \{Array::get(doubled, 3)}\n")
}
```

```output
evens length = 2
sum = 10
doubled[3] = 8
```

`for x in xs { body }` **collects** when `xs` is an `Array` (or another
builtin collection). The value of the loop is `Array[T]`. A pull
closure or a trait iterator is statement-shaped: you cannot write
`let xs = for ...` on it. Accumulate into an `ArrayBuilder` yourself.

`for i, x in xs` binds the index too.

## Pipe

`|>` prepends the piped value as the first argument, unless a bare `_`
marks the slot.

```vibe run
import @vibe/prelude {
  stdout_write
}

fn main with Stdout {
  let n = "  vibe  " |> String::trim |> String::length
  let xs = [
    1,
    2,
    3
  ]
  let ys = xs |> Array::map(_, _ * 10)
  stdout_write("trimmed length = \{n}\n")
  stdout_write("ys[1] = \{Array::get(ys, 1)}\n")
}
```

```output
trimmed length = 4
ys[1] = 20
```

`xs |> Array::map(_, _ * 10)` reads as `Array::map(xs, (v) -> v * 10)` —
the first `_` is a pipe slot, the second is a section.

Method-style `xs.length()` is legal to type. Committed source prefers
`Type::method(recv, args)` (`vibe normalize` rewrites the recoverable
cases). Builtin receivers keep the `Type::method` spelling; there is no
bare-method sugar for `Array` / `String`.

Next: [Equality](18_equality.vibe.md).
