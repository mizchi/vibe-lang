# wasm-gc HOF Gap: Closure ↔ Generic Iterator signature mismatch

Date: 2026-05-25
Status: investigation (no fix in this report)
Related: vibe_wasm_gc_e2e_test.mbt header "Known GC codegen limitations
(tracked in issue #41)"

## Symptom

`VIBE_TEST_BACKEND=gc vibe test vibe/prelude/iterator_test.vibe` → 0/6.

Most failures look like compile errors or "out of bounds" traps, but the
underlying issue is the **same**: when a closure with concrete types
(e.g. `(acc: Int, x: Int) -> Int`) is passed to a generic combinator
like `Iterator::fold[C: Iterable, A, B]`, the wasm-gc backend ends up
with **mismatched function signatures at the `call_ref` site**.

Reproducer (`/tmp/test_str_fold.vibe`):

```vibe
import /vibe/prelude/iterator.vibe { Iterator::fold }
let main: () -> Int = () -> {
  Iterator::fold("abc", 0, (acc: Int, c: Int) -> Int { acc + c })
}
main()
```

- `vibe compile --wasm-gc` + `wasmtime --invoke _start` → returns **0**
  (should be 294 = `'a' + 'b' + 'c'`). No trap; the loop body simply
  never updates the accumulator.
- Manual hand-written equivalent loop (`while i < String::length(s) {
  acc = acc + String::char_code_at(s, i); i = i + 1 }`) returns 294 ✓
- After my recent fixes (sha1 unblocking, etc.) the `String` itself is
  iterable correctly via `String::iter_length` / `String::iter_get`.

## Root cause

Inspecting the emitted wasm:

```wat
(type 6 (func (param anyref eqref eqref) (result eqref)))   ;; what fold's call_ref expects
(type 10 (func (param anyref i64 i64) (result i64)))         ;; what the user's closure actually is

(func ;; 0 = Iterator::fold (generic, eqref-erased)
  (param eqref eqref (ref null 7)) (result eqref)
  ...
  local.get 2                       ;; closure ref
  struct.get 7 1                    ;; closure.fn_ref
  local.get 5                       ;; acc as eqref
  local.get 0  ref.cast (ref null 8)
  local.get 4                       ;; i (i64)
  call 2                            ;; iter_get → eqref
  local.get 2  struct.get 7 0       ;; closure.env (anyref)
  call_ref 6                        ;; expects (anyref, eqref, eqref) → eqref
  ...

(func ;; 5 = user lambda
  (param anyref i64 i64) (result i64)
  local.get 1 local.get 2 i64.add
)
```

The wasm validates (the cast succeeds because the closure struct types
nest the fn_ref), but at runtime `call_ref` invokes function 5 — and
i64 / eqref are different value types, so either:
- wasmtime traps with "indirect call type mismatch" (compile failures
  in some tests), or
- the call silently uses the wrong stack values (returns 0 instead of
  the fold result)

Depending on the host's strictness.

## Why it doesn't reproduce in simpler tests

Earlier tests pass:
- `apply : ((Int) -> Int, Int) -> Int = (f, x) -> f(x)` — fn-as-value
  with NO generic type params (no eqref erasure)
- `let f = inc; f(41)` — same, no generics
- `Iterator::fold([1,2,3], 0, lambda)` — works because Array's
  generic params ARE specialized somewhere upstream (probably during
  monoify because Array is "more concrete" than C: Iterable)

The mismatch only triggers when the iterable is a NON-Array type
(`String`, `Map[K,V]`, user enum with `impl Iterable`) AND the closure
has concrete types. The Array case happens to bypass the eqref-erased
dispatch by going through a different specialization path.

## What needs to happen

The proper fix is monomorphization-by-type-param. `Iterator::fold[C, A,
B]` invoked with `(C=String, A=Int, B=Int)` should produce a specialized
function with the i64 / Ref(string) types throughout instead of eqref.

The monoify pass already exists (`src/frontend/monoify.mbt`), but it
doesn't appear to specialize per-type-arg combinations through the
`xs|>iter_length` / `xs|>iter_get` pipe-call dispatch points. Possibly
the trait-bound `C: Iterable` blocks specialization because the call
target is resolved through trait dispatch rather than name resolution.

Alternative fix: **synthesize an i64↔eqref boxing wrapper** for the
closure. When a `(i64, i64) -> i64` closure is passed where a
`(eqref, eqref) -> eqref` is expected, emit a wrapper that
`ref.i31`-boxes / unboxes at the call boundary.

Either approach is multi-day work. Out of scope for the current
ADR-0052 / dogfood cycle.

## Current behavior (what works / what doesn't)

| HOF pattern | wasm-gc | linear |
|---|---:|---:|
| Function-as-value (`let f = inc; f(x)`) | ✓ | ✓ |
| HOF param (`apply(f, x)`) — concrete types | ✓ | ✓ |
| `Iterator::fold([Int], 0, lambda)` | ✓ | ✓ |
| `Iterator::fold("abc", 0, lambda)` | **fail** | ✓ |
| `Iterator::fold(Map, 0, lambda)` | **fail** | ✓ |
| `Iterator::fold(CustomIterable, ...)` | **fail** | ✓ |

5 of 6 `iterator_test.vibe` tests sit in the failing rows.

## Recommendation

File a tracked issue (use the test header's "issue #41" handle even
though the original #41 is now closed) and link this report. The fix
should be planned as its own PR with the monoify approach — it touches
core trait-bound specialization logic.

In the meantime, users that hit this can:
- Stay on linear backend (`VIBE_TEST_BACKEND` unset / `=wasm`)
- Or hand-roll the iteration as `while i < len { ... }` — the bench
  numbers and basic loop operations work fine on wasm-gc
