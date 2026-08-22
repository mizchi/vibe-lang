# 20 — Pitfalls (measured)

Previous: [Targeting wasm](19_wasm.vibe.md)

日本語版: [20_pitfalls.vibe.md](../ja/20_pitfalls.vibe.md)

These are rules that cost people an afternoon. Each one was measured on
the current compiler. The full list lives in
[docs/cheatsheet.md](../../docs/cheatsheet.md). This chapter is the
ones that bite first.

## `handle` eligibility is not the type system

A program can type-check and still fail to compile if a `handle` cannot
see every `perform` it covers. The body may only: perform directly, call
a **named top-level `fn`**, or call a closure *literal* with an effect
row. A call through a local binding hides the perform.

```vibe skip
// skip: eligibility rejection — the point is the diagnostic, not a run
effect Ask {
  Get() -> Int
}

fn main with Exception {
  let bump = (x: Int) -> Int {
    x + 1
  }
  let n = handle {
    bump(perform Ask::Get())
  } with Ask {
    Get() => resume(0)
  }
  ()
}
```

```
handle of effect 'Ask' cannot be compiled here: this handle cannot see what
one call in its body performs (here: the call to 'bump'). Make that call
visible -- declare 'bump' as a top-level `fn`, give the binding or parameter
it arrives through an effect row (`with Ask`), or move its `let` inside the
handled body. Moving the `handle` into the function that performs works too.
(ADR-0076 evidence-passing migration.)
```

Note that `bump` carries **no** effect row. Giving its literal
`with Ask` is one of the four repairs the message lists, so that version
compiles — which is the point: the row on the binding is what makes the
perform visible. Lifting `bump` to a top-level `fn` works too.

## `Int` width follows the tag bit

`Int` is **63-bit** (one tag bit, ADR-0105). Literal max is
`4611686018427387903`. `max + 1` wraps to `-4611686018427387904` on
every backend. Text that still says `2^61-1` / 62-bit is stale.

## `perform?` is rejected by the checker

`perform? Fs::read_file(p)` is typed as `Attempt[T, String]` on
`allows Fs::read_file?`, but codegen cannot lower it, so the checker
rejects it (#2145): *"`perform?` is not lowered yet"*, naming the edit —
drop the `?` from the `allows` item and call `Fs::read_file(..)` the ordinary
way. `allows` only ever holds capabilities, and a capability is never
performed.

`vibe check` reports it too, so you see it before you build. Until #2145
lands it ICE'd instead, after a clean check.

## Interpolation needs a renderer

A user struct interpolated with `\{x}` needs `derive(Show)` or
`fn T::to_string(v) -> String`. Scalars, `Option`, tuples, and arrays
already render. Missing Show used to print a pointer; it is now an
error (#1445).

## `s[i]` is a byte, not a String

`String` is a byte string. `s[i]` is an `Int` character code. `'A' == 65`.
A one-character String is `String::from_char_code(s[i])` or a slice.

## Top-level is declarations only

A bare expression at the top level is rejected (ADR-0069). Put it in
`fn main` or a `test` block.

```vibe skip
// skip: ADR-0069 — a file is a list of declarations
1 + 2
```

```
top-level expressions are not allowed; move it into fn main (ADR-0069)
```

## `test` / `bench` take a string or nothing

`test { }` and `test "name" { }` work. `test foo { }` (a bare identifier)
does not.

## `Error` vs `Exception`

`Exception` is the effect. `Error` as an effect spelling is deprecated
(ADR-0085). You will still see `Error` as an *operation qualifier* in
older rows; do not add new ones.

## `==` on arrays

`==` compares by value, including arrays with non-scalar elements,
arrays returned from a function, and empty literals — annotated or not.
An unannotated `let xs = []` takes its element type from the
`Array::push` calls that fill it (#2157), **as long as the pushed value
says what it is**: a literal, an array / tuple / struct of literals, or
an `if` whose branches agree.

Push a name or a call result and the binding gets no element type, and
comparing two such arrays once both are non-empty fails at run time
rather than answering. `let xs: Array[Int] = []` is the fix. A struct
that takes type parameters counts as saying what it is only when the
type arguments at the literal are scalars — `Box[Int]::{ value: 1 }`
resolves, `Box[Array[Int]]::{ ... }` does not.

A generic `T` with no `Eq` witness is the boundary worth knowing, and it
is a compile error rather than a surprise — `no impl `Eq` for
`Array[Int]``. See [Equality](16_equality.vibe.md).

## `fn` is a keyword

`let fn = 1` is a parse error. `r#fn` is not an escape hatch. Rename
the binding.

## `for` does not always collect

`let xs = for x in arr { x * 2 }` works for `Array`. A pull iterator in
the same position is a located error. Accumulate with `ArrayBuilder`.

Next: [Appendix](99_appendix.md).
