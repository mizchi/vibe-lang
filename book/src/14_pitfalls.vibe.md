# 14 — Pitfalls (measured)

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
  Get -> Int
}

fn main with Exception {
  let bump = (x: Int) -> Int with Ask {
    x + 1
  }
  handle {
    bump(perform Ask::Get)
  } with Ask {
    Get => resume(0)
  }
}
```

The diagnostic names the callee (`bump`) and its `line:col`. Fix: lift
`bump` to a top-level `fn`.

## `Int` width follows the tag bit

`Int` is **63-bit** (one tag bit, ADR-0105). Literal max is
`4611686018427387903`. `max + 1` wraps to `-4611686018427387904` on
every backend. Text that still says `2^61-1` / 62-bit is stale.

## `perform?` typechecks; codegen does not

`perform? Fs::read_file(p)` is typed as `Attempt[T, String]` on
`allows Fs::read_file?`. Compiling it ICE's:
`perform?` reached code generation unresolved. Do not put a
`` ```vibe run `` block around it until lowering exists.

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

## `test` / `bench` take a string or nothing

`test { }` and `test "name" { }` work. `test foo { }` (a bare identifier)
does not.

## `Error` vs `Exception`

`Exception` is the effect. `Error` as an effect spelling is deprecated
(ADR-0085). You will still see `Error` as an *operation qualifier* in
older rows; do not add new ones.

## `==` is not finished

Structural `==` is landing (ADR-0097). Scalars, tuples, and many structs
compare by value. Remaining reference equality: erased type variables
(`[T: Eq]`), some function-return paths, empty literal bindings, and
named arrays whose element type is not a scalar. When in doubt, write
the comparison you mean. See [Equality](18_equality.vibe.md).

## `fn` is a keyword

`let fn = 1` is a parse error. `r#fn` is not an escape hatch. Rename
the binding.

## `for` does not always collect

`let xs = for x in arr { x * 2 }` works for `Array`. A pull iterator in
the same position is a located error. Accumulate with `ArrayBuilder`.

## Double interpolation

`"\{d}"` for a `Double` is only trustworthy when the checker can see
the value is floatish. An unannotated helper result may print as an
integer bit pattern. Annotate the parameter or write `d * 1.0`.

Next: [Appendix](99_appendix.md).
