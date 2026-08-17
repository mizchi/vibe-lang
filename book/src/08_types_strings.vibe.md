# 08 — Types and strings

Chapter 1 showed `Int`, `Double`, `Bool`, `String`, and `Char` as values.
This chapter is the contract those types actually keep — the places people
silently get a wrong answer if they guess from another language.

## `Int` is 63-bit, not "a machine i64"

ADR-0105 (#1877): the shipped representation uses **one** tag bit, so the
honest width is 63. The range is `-2^62 .. 2^62-1`. A literal larger than
`4611686018427387903` (`2^62-1`) is rejected as `IntLiteralOverflow`.
Arithmetic overflow wraps as 63-bit two's complement on **every** backend
— `max + 1` is `min`. Older text that said "62-bit / `2^61-1`" was
describing a tag layout the compiler no longer uses.

```vibe run
import @vibe/prelude {
  stdout_write
}

fn main with Stdout {
  let max = 4611686018427387903
  stdout_write("max = \{max}\n")
  stdout_write("max + 1 = \{max + 1}\n")
  stdout_write("hex 0xFF = \{0xFF}\n")
  stdout_write("1 << 4 = \{1 << 4}\n")
  let neg = 0 - 8
  stdout_write("(-8) >> 1 = \{neg >> 1}\n")
}
```

```output
max = 4611686018427387903
max + 1 = -4611686018427387904
hex 0xFF = 255
1 << 4 = 16
(-8) >> 1 = -4
```

`>>` is an *arithmetic* shift (sign-extending). There is no `>>>`. There is
no `~` either — write `x ^ mask`. Bigger integers belong in
`@vibe/core`'s `BigInt`, not in a silent promotion.

## `Float` and `Double`

A bare decimal is a `Double` (64-bit). A `Float` (32-bit) needs the `f`
suffix: `1.5f`. Interpolation of a `Double` only prints the decimal you
expect when the checker can see that the value is floatish (a literal, a
float-tracked local, float arithmetic, or an annotated parameter). Pipe an
unannotated helper result through `* 1.0` or a `Double` parameter if the
printout looks like an integer bit pattern.

## `String` is a byte string

`s[i]` is an `Int` character code, not a one-character `String`. `'A'` is
`65`. Indexing is a byte offset. That is the honest meaning: the memory
is bytes, so the type is bytes (ADR-0098).

```vibe run
import @vibe/prelude {
  stdout_write
}

fn main with Stdout {
  let s = "hello"
  stdout_write("s[0] = \{s[0]}\n")
  stdout_write("from_char_code = \{String::from_char_code(s[0])}\n")
  stdout_write("s[:] = \{s[:]}\n")
  stdout_write("s[:2] = \{s[:2]}\n")
  stdout_write("s[2:] = \{s[2:]}\n")
  stdout_write("s[1:4] = \{s[1:4]}\n")
  stdout_write("length = \{String::length(s)}\n")
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

The four slice spellings — `s[:]`, `s[:n]`, `s[n:]`, `s[a:b]` — also work
on `Bytes` and `Array[T]`. They do not walk Unicode code points.

## Interpolation

`"hello \{x}"` is the only interpolation spelling. A value interpolates
when the checker can find `T::to_string` (`derive(Show)`, a hand-written
method, or a builtin renderer). Scalars, `Option`, tuples, and arrays
already render. A user struct without Show used to print a pointer; that
is now a compile error.

```vibe run
import @vibe/prelude {
  stdout_write
}

struct Point {
  x: Int; y: Int
} derive (Show)

fn main with Stdout {
  let p = Point::{
    x: 3, y: 4
  }
  stdout_write("p = \{Point::to_string(p)}\n")
  stdout_write("opt = \{Some(1)}\n")
  stdout_write("pair = \{(2, 3)}\n")
}
```

```output
p = Point { x: 3, y: 4 }
opt = Some(1)
pair = (2, 3)
```

Next: [Collections](15_collections.vibe.md).
