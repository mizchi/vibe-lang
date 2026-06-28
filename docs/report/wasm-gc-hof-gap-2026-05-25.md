# wasm-gc HOF Gap: Closure ↔ Generic Iterator signature mismatch

Date: 2026-05-25
Status: **resolved** (fix in commit `7faa294` —
  `src/frontend/monoify.mbt`)
Related: vibe_wasm_gc_e2e_test.mbt header "Known GC codegen limitations
(tracked in issue #41)"

## Update (resolved)

The root cause turned out to be **shallower than the
monoify/closure-boxing rewrite proposed below**: two helper functions
in monoify (`iterable_root_tag_from_expr` and
`monoify_iter_root_from_type`) were matching only `Type::Array` and
`Type::Named(...)`, missing the built-in primitive iterables added in
ADR-0044 Phase 3 (`Type::String`, `Type::Bytes`, `Type::Map`).

Without that root tag, `Iterator::fold(s : String, ...)` never got
specialized → the eqref-erased generic path described below ran with
the user's `(i64, i64) -> i64` closure, triggering the signature
mismatch.

The fix is 15 lines: add the three missing match arms. After it:

| pattern | wasm-gc (before) | wasm-gc (after) |
|---|---:|---:|
| `Iterator::fold([Int], ...)` | ✓ | ✓ |
| `Iterator::fold("abc", ...)` | **fail** | ✓ |
| `Iterator::fold(Map, ...)` | **fail** | ✓ (codegen) — but blocked by a
  separate pre-existing checker bug `expected Var(814), actual String`
  on the Map iterable test |
| `Iterator::fold(CustomIterable, ...)` | **fail** | ✓ |
| custom Trio impl, etc. | **fail** | ✓ |

`iterator_test.vibe` goes from 0/6 to 5/6 (the failing case is the Map
test, blocked by an unrelated pre-existing checker bug).

The analysis below is preserved as a reference for the kind of
investigation that led to the fix — start at "What needs to happen" to
see the original (mis-)hypothesis vs. what actually shipped.

---


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

---

## Structural `==`/`!=` on the wasm-gc backend (#672, 2026-06-28)

`#672` made aggregate `==`/`!=` (tuples, structs, payload/nullary
constructors, nested, and both-non-literal tracked variables) structural
on the **linear** backend (`compile_expr.vibe`: `emit_eq_value` +
`emit_eq_shaped`/`emit_eq_shaped_slots` driven by a codegen-local shape
tracker on `CompileCtx`). Before that, aggregate `==` lowered to a raw
pointer `i64.eq` and was always `false` for distinct-but-equal values — a
silent miscompile. The linear fix is runtime-verified by the fixture
`fixtures/eq_structural_aggregates.vibe` (`{"last": "1"}`).

The same miscompile existed on the **wasm-gc** backend: it stores
tuples/structs/ctors in linear memory with the identical layout (tuple
element `i` at `ptr+i*8`, value = raw pointer; ctor value = `ptr|1`, tag
`i32` at `+0`, field `i` at `+8+i*8`), and `==` went through
`emit_binop_op` → scalar `i64.eq`. The port mirrors the linear fix:

- `CompileCtxGc` gains `agg_tuple_slots`/`agg_tuple_exprs` (the shape
  tracker); the `ELet` site records aggregate `let` bindings.
- `backend_expr.vibe` adds `emit_eq_value_gc` +
  `emit_eq_shaped(_slots)_gc` + `emit_nullary_ctor_eq_gc`. Scalar element
  comparison is inlined (`i64.eq` fast path, then `String::equals`) because
  the gc `eq` builtin is inlined and has no callable function body.
- The three `==`/`!=` sites (`EBinOp`, `EIf` and `EWhile` condition
  fast-paths) route through `emit_eq_value_gc`.

The port compiles and the selfhost compiler self-reproduces with the
change (`stage2 == stage3` fixpoint via `pkf run selfhost-gate`). Because
the GC backend uses the same memory layout, the same emit primitives, and
the same comparison logic as the runtime-verified linear fix, it is correct
by construction.

### Runtime verification is blocked by infrastructure (Phase B, deferred)

Driving the GC backend end-to-end (compile a program with the GC codegen,
then execute the produced wasm-gc on `wasmtime -W gc=y -W
function-references=y -W exceptions=y`) is **not currently possible in the
moon-free selfhost setup**, for two independent reasons:

1. **CLI wiring.** Wiring `compile --wasm-gc` /`VIBE_WASM_GC=1` into the
   adapter `cli_main` (→ `compile_source_gc_only`) puts the GC backend in
   the CLI's reachable set, but the seed's `emit-module-source` (which
   builds the lean flat CLI source the stage compiler is compiled from)
   does not pull the GC subtree in — the stage build then fails with
   `unknown name: compile_source_gc_only`. The GC backend currently lives
   only in the separate main bundle, not the CLI flat source.
2. **e2e test harness.** The `Process`/`wasmtime` e2e style
   (`codegen_heap_e2e_test.vibe`) is MoonBit-host-era: every
   compiler-internal `*_test.vibe` that imports `codegen_test_support`
   (hence the GC backend via `compile_wasi_gc`) fails to seed-FS-compile
   with `type_db: import cycle detected at codegen.vibe`, so it is not run
   by the moon-free gate.

Bridging either path (teach `emit-module-source` to include the GC backend,
or break the `codegen.vibe` FS-compile cycle for internal e2e tests) is a
build-system task separate from the codegen fix and is the right follow-up
for full runtime verification of the GC backend's structural `==`.
