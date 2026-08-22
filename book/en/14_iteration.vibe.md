# 14 — Iteration

Previous: [Collections](13_collections.vibe.md)

日本語版: [14_iteration.vibe.md](../ja/14_iteration.vibe.md)

Almost all iteration in vibe is one eager pass over an array. This
chapter is that pass, the `|>` operator that chains it, and where to
look when the thing you are iterating is not a collection you already
hold.

## One pass over an array

```vibe run
fn main with Console {
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
  println("evens length = \{Array::length(evens)}")
  println("sum = \{sum}")
  println("doubled[3] = \{Array::get(doubled, 3)}")
}
```

```output
evens length = 2
sum = 10
doubled[3] = 8
```

`for x in xs { body }` **collects**. When `xs` is an `Array` or another
builtin collection, the loop is an expression whose value is `Array[T]` —
which is why `doubled` can be indexed. `for i, x in xs` binds the index
too.

`Array::map`, `Array::filter` and `Array::fold` do the same work as
plain functions. Pick whichever reads better at the call site; both are
the same single pass.

## Piping

`|>` passes the value on the left as the first argument on the right,
unless a bare `_` marks the slot:

```vibe run
fn main with Console {
  let n = "  vibe  " |> String::trim |> String::length
  let xs = [
    1,
    2,
    3
  ]
  let ys = xs |> Array::map(_, _ * 10)
  println("trimmed length = \{n}")
  println("ys[1] = \{Array::get(ys, 1)}")
}
```

```output
trimmed length = 4
ys[1] = 20
```

`xs |> Array::map(_, _ * 10)` reads as `Array::map(xs, (v) -> v * 10)`.
The two underscores are different things: the first is the pipe slot,
the second is a section — shorthand for a lambda over that argument.

## When it is not an array

There is no lazy combinator chain to assemble. An `Array::*` call and a
`for` are the eager layer, and they are the whole of it.

The second layer is for values that arrive over time — a stream, a
socket, a file read in pieces. There you are not holding a collection,
so you pull: an iterator whose `next` may suspend. Suspension rides on
the effect row rather than on a special loop keyword, which is why there
is no separate `for await` form. See
[Concurrency](17_concurrency.vibe.md).

Next: [Generics, traits, and derive](15_generics.vibe.md).
