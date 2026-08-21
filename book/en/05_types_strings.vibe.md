# 05 — Types and strings

Previous: [Control flow](04_control_flow.vibe.md)

日本語版: [05_types_strings.vibe.md](../ja/05_types_strings.vibe.md)

You have been using `Int`, `Double`, `Bool`, `String` and `Char`
without being told much about them, and mostly that has been fine.
This chapter covers the two places where it stops being fine: text is
bytes, and printing a value needs a way to print it.

The exact numeric ranges are at the end of the chapter, where you can
find them when a number surprises you.

## `String` is a string of bytes

This is the one that surprises people. `s[i]` is an `Int` — the byte at
that offset — not a one-character `String`. Indices and lengths are
byte counts.

```vibe run
fn main with Console {
  let s = "hello"
  println("s[0] = \{s[0]}")
  println("from_char_code = \{String::from_char_code(s[0])}")
  println("s[:] = \{s[:]}")
  println("s[:2] = \{s[:2]}")
  println("s[2:] = \{s[2:]}")
  println("s[1:4] = \{s[1:4]}")
  println("length = \{String::length(s)}")
}
```

```output
s[0] = 104
from_char_code = h
s[:] = hello
s[:2] = he
s[2:] = llo
s[1:4] = ell
length = 5
```

`String::from_char_code` turns a code back into a `String`. The four
slice forms — `s[:]`, `s[:n]`, `s[n:]`, `s[a:b]` — work the same on
`Bytes` and on `Array[T]`.

Because indices are bytes, slicing does not respect Unicode code point
boundaries. Slicing ASCII is safe; slicing arbitrary text at an
arbitrary index is not, and that is a deliberate choice — the memory is
bytes, so the type says bytes rather than pretending otherwise.

## Interpolation

`"hello \{x}"` is the only interpolation syntax, and any expression fits
in the braces. A value can be interpolated when the compiler can find a
`to_string` for its type: scalars, `Option`, tuples and arrays already
have one, and your own types get one from `derive (Show)`.

```vibe run
struct Point {
  x: Int; y: Int
} derive (Show)

fn main with Console {
  let p = Point::{
    x: 3, y: 4
  }
  println("p = \{Point::to_string(p)}")
  println("opt = \{Some(1)}")
  println("pair = \{(2, 3)}")
}
```

```output
p = Point { x: 3, y: 4 }
opt = Some(1)
pair = (2, 3)
```

Leave `derive (Show)` off and interpolating a `Point` is a compile
error, which is the intended answer — printing an address instead would
be a wrong one.

## Decimals

A decimal literal is a `Double` — 64-bit. A 32-bit `Float` takes an `f`
suffix: `1.5f`. Both interpolate as the decimal you wrote.

## How far `Int` goes

Reach for this section when a number does something you did not expect;
until then the short version is that `Int` holds whole numbers and
overflow does not trap.

`Int` is 63 bits wide, not 64. The range is `-2^62 .. 2^62-1`, and a
literal above `4611686018427387903` is rejected rather than truncated.
Arithmetic that goes out of range **wraps**, as 63-bit two's complement,
identically on every backend — so `max + 1` is `min`:

```vibe run
fn main with Console {
  let max = 4611686018427387903
  println("max = \{max}")
  println("max + 1 = \{max + 1}")
  println("hex 0xFF = \{0xFF}")
  println("1 << 4 = \{1 << 4}")
  let neg = 0 - 8
  println("(-8) >> 1 = \{neg >> 1}")
}
```

```output
max = 4611686018427387903
max + 1 = -4611686018427387904
hex 0xFF = 255
1 << 4 = 16
(-8) >> 1 = -4
```

Three things that differ from C-family languages:

- `>>` is arithmetic — it sign-extends. There is no `>>>`; for a logical
  shift, mask afterwards.
- There is no `~`. Write `x ^ mask`.
- Nothing is promoted silently. When you need more than 63 bits, reach
  for `BigInt` in `@vibe/core` deliberately.

Next: [Mutation, regions, and escape](06_mutation.vibe.md).
