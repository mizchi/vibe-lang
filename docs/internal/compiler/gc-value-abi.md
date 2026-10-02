# wasm-gc lane: carrying references across the value ABI

ADR-0095 states the decision; this document is its detail. It concerns only
the experimental wasm-gc backend (`VIBE_BACKEND=gc`). The linear backend — the
stable surface — is unaffected by everything below.

Lineage: #1329 (non-escaping local arrays as native references), #1332 (the
same inside lambda bodies), #1331 (references across the value ABI), then
#1541 / #1542 / #1701 / #1722 for the boundaries listed in §4.

## 1. The constraint

Every value slot on the gc lane is an `i64` unless it has been proved onto the
reference lane (§4). An `Int` there is an untagged i64 holding a 63-bit value
(ADR-0105); strings, bytes, and records and arrays that are not on the
reference lane live in linear memory and are referred to by i64 addresses.

A wasm reference cannot be packed into a scalar. There is no way to store a
`(ref $array)` in an i64 and no `i64.reinterpret`-like escape hatch, by design:
the GC could no longer trace it.

> **So "one uniform i64 value representation" and "GC references" cannot
> coexist.** Letting references cross a boundary is a change to the value
> representation, not an optimization.

Every decision below follows from that sentence.

### 1.1 The wasm-gc types the lane emits

| type index | contents | used for |
|---|---|---|
| 10 | `(struct (mut i64))` | RC cell for a captured `let mut` (#1416) |
| 11 | `(array (mut i64))` | the allocation probe; its reference is dropped before user code |
| 12 | `(array (mut i64))` (`$native_i64_array`) | reference-lane arrays |
| 13 | `(func (result (ref null 12)))` | not callable: the blocktype of a reference-lane `if` join (§4.3) |
| 14 … | one struct per declared struct | non-escaping local records (#1702); a field declared `Array[Int]` is `(mut (ref null 12))`, every other field `(mut i64)` (#1542) |
| after those | closure types | one per closure arity |

The fixed indices exist because function bodies are generated before the type
section is laid out, so any index a body names has to be a constant.

## 2. Host and component boundaries

References do not cross the host boundary, and the lane uses no `externref`:

1. The gc lane's host imports use the raw i64 ABI. Strings and bytes cross as
   linear-memory addresses; the host never holds an opaque reference.
2. Host-side state is held by integer tokens: `Fs::stat_token` and friends
   return an i64 whose object lives in a host table. That handle pattern needs
   no `externref`.
3. The compiler's codegen emits no `externref`, `anyref` or `eqref`.

`externref` would be needed only to hold **host-owned opaque objects** as vibe
values (a JS object, a DOM node, a host resource), or for a host function to
receive a GC reference itself. Both are separate problems from vibe's own
references crossing vibe's own function boundaries.

At a **component (WIT) boundary** `externref` is not the answer either: the
canonical ABI is linear-memory based, and `list<u8>` lowers to `(ptr, len)`. A
GC array crosses such a boundary by being **copied** at the boundary.

What the two share is the constraint of §1: neither an `externref` nor a
`(ref $array)` fits in an i64. The reference lane is therefore defined as
"value slots whose ref type is decided statically", not as something hard-wired
to `$array`, so adding `externref` later would not mean rebuilding the ABI.
It is not implemented: there is no demand, and nothing could test it.

## 3. Rejected designs

### 3.1 A uniform `anyref` representation (not now)

Make every value an `anyref`: scalars as `i31ref`, everything else boxed in a
struct or array — what the OCaml, Java and Scheme wasm-gc backends do.

**Rejected because `Int` is 63-bit and `i31ref` holds 31 bits.** Every Int above
`2^30` would be boxed, and integer-heavy code such as the compiler itself would
allocate far more. It is also a wholesale change of the value representation.
It remains the right long-term direction, under the conditions in §6.

### 3.2 An i64 handle registry

Put GC objects in a table and refer to them by i64 index.

**Rejected:** it roots every registered object permanently, so the GC can no
longer collect them and wasm-gc buys nothing. #1331's acceptance criteria ruled
it out explicitly.

### 3.3 Switching representation at run time

Tell a GC reference from a linear pointer by a run-time tag.

**Rejected as unsound.** If one program point can hold a value in two
representations, the declared-versus-actual mismatch #1427 hit comes back at
scale. **A representation must be statically unique** — the central invariant
of this design.

## 4. The design: a type-directed reference lane

### 4.1 The invariant

> **At every program point, each value's representation is statically
> determined. Wherever the representation changes, there is an explicit
> conversion point.**

Within that invariant, the set of boundaries a reference may cross is widened
step by step, each step sound on its own: stopping half-way still produces
correct wasm.

### 4.2 Choosing a representation

The checker's static type decides the representation of each slot (parameter,
result, local, field):

| static type | representation |
|---|---|
| `Array[Int]` / `Array[String]` / `Array[Bool]`, non-generic context | `(ref null $native_i64_array)` — the reference lane |
| anything else | i64 — the existing lane |

A generic `fn id[T](x: T) -> T` cannot know statically whether `T` is an array,
so **generic functions always use the i64 lane**. Passing an array to a generic
function is a conversion point.

The element types are an allowlist, and the reason is recognition, not fit:
a native array's cells are `(mut i64)` holding the same i64 the element has
everywhere else on the lane, so the element type does not change the
representation. But after `strip_generic_type_params`, the element of
`fn f[T](xs: Array[T])` is spelled `TyName("T")`, indistinguishable from a
concrete type of that name, so only spellings that cannot be a type variable —
the builtin scalars — are admitted (`fixtures/gc_direct_array_element_types_test.vibe`).
Nested arrays are excluded for a different reason: an `Array[Array[Int]]` cell
would have to hold a reference, and an i64 cell cannot (§1).

### 4.3 Boundaries

| step | boundary a reference crosses | state |
|---|---|---|
| A | **results and arguments** of non-generic direct calls; function types derived from static types, with caller and callee checked to agree | landed (#1541) |
| B | **aliases and local bindings**: private concrete arrays, one-level immutable local aliases, self- and mutual recursion, returning a local array, `if` joins whose arms are both on the reference lane | landed (#1541) |
| — | **exported declarations**, by boundary monomorphization (§7) | landed (#1722) |
| C | **aggregate fields**: records as real wasm-gc structs, `Array[Int]` fields held by reference | landed for struct fields (#1702, #1542) |
| D | **closure captures** | not planned (#1543): closures stay i64; see §7 |

Imports, indirect calls, closure capture, globals, and joins with a bare array
literal in an arm are not supported crossings; they fail closed to the i64 lane.

What each boundary needed:

**Generics coexist with the lane.** The lane's candidates are computed with the
names of generic declarations collected **before** erasure
(`gc_direct_abi_pre_erasure_generic_names`), plus the post-strip `type_params`,
because `inject_method_generics` re-attaches binders to impl methods after
`strip_generic_type_params` (`dai_is_generic`). A generic declaration whose
signature mentions a reference-lane type (`Array[Int]`) still switches the whole
component to i64, because it would need a conversion point that does not
exist. A generic declaration that never touches reference-lane values simply is
not a candidate, and the rest of the component keeps the lane; passing a
reference into it is refused by `gc_direct_abi_expr_kind` as before. The pair:
`fixtures/gc_direct_array_generic_coexist_test.vibe` (the lane survives) and
`fixtures/gc_direct_array_argument_fallback_test.vibe` (the generic carries
`Array[Int]` itself, so the component falls back).

**Acceptance and the escape gate ask the same question.** The pass that accepts
a `let` onto the reference lane (`gc_direct_abi_expr_kind`) consults the same
predicate that decides whether a local actually becomes native
(`gc_native_array_escape_gate`). When they decided separately, a binding could
be accepted as a reference that the gate then refused to make native; the
caller then demanded a reference that did not exist, and a correct program
failed to compile with `gc direct ABI proof mismatch`:

```vibe skip
// doctest-skip: shape of the former compile failure, kept for the explanation
fn mutate_first(values: Array[Int]) -> Unit { Array::set(values, 0, 7) }

test "..." {
  let xs = [1, 2]
  let peek = () -> Array::get(xs, 0)   // captured: the escape gate refuses native
  mutate_first(xs)                      // the acceptance side assumed a reference
  inspect(peek(), "7")
}
```

When the gate refuses, the binding stays an ordinary i64 local, and a call
that would need a reference makes the component fall back (fail-closed). The
gate reads the evidence table directly, so both sides see one predicate.

**Control-flow joins.** An `if` whose arms are both already on the reference
lane yields `(ref null $native_i64_array)` itself, in two positions: the tail
of a function returning a reference, and a proved reference argument. A typed
reference has no one-byte value type, so the blocktype names type index 13.
An arm that is a bare array literal still falls back: a literal does not choose
its own representation (its consumer does), and an `if` gives it no consumer
proof to lean on. The pair: `fixtures/gc_direct_array_join_test.vibe` /
`fixtures/gc_direct_array_join_fallback_test.vibe`.

**Exported declarations.** An exported declaration crosses the host boundary,
whose ABI is i64, so its own signature never carries a reference. Since #1722 it
gets a **private reference twin**: the export keeps the i64 signature a host
needs, internal calls resolve to the twin, and the two share one body, so there
is exactly one array (`fixtures/gc_direct_array_export_twin_test.vibe` mutates
through the boundary twice and reads both writes through the original binding;
a copying conversion would pass the first assertion and fail the second). Both
export spellings get a twin — `export let f = …` and `let f = …` followed by
`export { f }` (`fixtures/gc_direct_array_export_list_twin_test.vibe`) — and
piping a private reference through an export keeps the lane up
(`fixtures/gc_direct_array_export_monomorph_test.vibe`). A **self-recursive**
export gets no twin: its i64 copy's self-call would resolve to the twin with an
i64 argument. It stays on the i64 lane alone, without switching off its
neighbours (`fixtures/gc_direct_array_export_recursive_test.vibe`, #1750). An
exported declaration beside private crossings no longer takes the component
down with it (`fixtures/gc_direct_array_export_coexist_test.vibe`).

A user declaration spelled like a routed builtin (`Array::get` and the like)
still switches the whole component to i64 even without references in its
signature: the backend intercepts that spelling to reach a native receiver, so
a user declaration of the same name would make the interception wrong — for
#1329's local lane too.

**Aggregate fields.** Non-escaping local records live in real wasm-gc structs
(#1702), registered per declared struct rather than per field count, because
two structs of one arity no longer share a shape once some fields hold
references. A field declared `Array[Int]` holds the array by reference
(`fixtures/gc_native_struct_ref_field_test.vibe`, where a mutation through the
field must be seen through every read). Reading such a field produces a
reference, so it is allowed only in the receiver position of a native array
operation; storing into it consumes a reference whose acceptance path cannot
be proved, so those records keep the linear layout
(`fixtures/gc_native_struct_ref_field_fallback_test.vibe`). Not covered: enum
payload fields, records local to a lambda or module-initializer frame, and
nested reference fields (`Array[Array[Int]]`, §4.2).

### 4.4 Verification

A representation mismatch shows up as **wasm that fails validation**, which
makes `wasm-tools validate --features all` a strong net. The gc gate
(`scripts/test_gc_heap_accounting.sh`) is where it is installed. Each boundary
requires:

1. a pair of fixtures — the case that now crosses and the case that still may
   not — with the gate pinning the number of native allocation sites, which is
   the proof of the boundary (the shape #1332 established; the accepted and
   refused fixtures above are those pairs);
2. a clean `wasm-tools validate --features all`;
3. no increase in `VIBE_MEM=1` allocation over the previous state.

### 4.5 Effect on the linear backend

**None.** The representation choice is internal to gc-lane codegen. The checker
only supplies static types, which `Array[T]` already has. The gate also checks
that reference-lane fixtures compiled on the linear lane contain no wasm-gc
instruction at all.

## 5. wasm proposal levels

Per [feature-levels.md](../../user/reference/feature-levels.md), generated wasm
may depend only on proposals that run without flags.

- The `gc` proposal is **safe** at both the `v8` and `web-baseline` levels
  (2026-07-27 snapshot). The boundaries in §4.3 add no new proposal dependency.
- Typed per-closure funcref tables (§7) would need `function-references`;
  check the feature matrix before taking that route.
- `externref` (reference types) is core wasm 2.0 and safe on every engine. The
  obstacle to adding it is design need (§2), not proposal level.

## 6. Long term: a full wasm-gc heap

The uniform `anyref` representation (§3.1) does not pay for itself **while the
gc lane is an experimental parity lane**. Revisit it when all of these hold:

- there is a decision to make the gc lane the production default (today it is
  linear);
- `Int`'s 63 bits are given up, or the cost of i31 plus boxing is measured and
  acceptable;
- the work to move every linear-memory string and record into wasm-gc can be
  scheduled.

The type-directed lane is the foundation for that too: the invariant of §4.1 is
needed by a uniform representation as much as by this one.

## 6.5 `Bytes` stays in linear memory (measured)

This design covers `Array[T]`. **`Bytes` is out of scope**, for two reasons.

**1. SIMD does not work on wasm-gc arrays.** `v128.load` takes a memory
address, and a GC array is not addressable memory. wasm-gc has no instruction
that bulk-loads a v128 from an `(array i8)` (`array.copy` / `array.fill` /
`array.new_data` move between arrays or from data segments only). **Moving
`Bytes` to GC would lose SIMD, not gain it.** Since `Bytes` is in linear memory
on both lanes, `simd_skip_ws` / `simd_scan_alnum` are registered on both.

**2. The byte path is already cheap.** Self time from `node --cpu-prof` on a
real compile (2026-08-04, the `codegen_lexer_test.vibe` full closure, 7.6 s):

| runtime function | self |
|---|---:|
| `__rt_arr_slice` | 8.8% |
| `__rt_arr_new` | 8.3% |
| `__rt_arr_push` | 6.4% |
| `__rt_arr_get` | 3.7% |
| **Array total** | **27.2%** |
| `__rt_bytes_push` | 1.0% |
| `__rt_bytes_append` | 0.9% |
| **Bytes total** | **1.9%** |

The wasm output buffer is `Bytes`: `bytebuf_push_buf` is `Bytes::append` (one
`memory.copy`) and `Bytes::push` grows by doubling from 64, amortized O(1).
**What is left to win in byte assembly is under 2% of the total**, so routing it
through `Bytes::blit` would gain little. Array functions are 27%, and the
largest callers were Perceus context copies (`pctx_new` 361 ms + `copy_ints`
225 ms = 7.7% of the total). **The performance lever is how working arrays are
held, not the byte path** — #1262's subject, outside this design.

## 7. Conversion points and what remains open

### 7.1 The conversion point is boundary monomorphization (#1701)

§4.1 says a representation change needs an explicit conversion point; #1701
decided **what that point does**, by measurement. A materializing **copy** — the
obvious reading — breaks identity for a mutable `Array[T]`: a callee's
mutation stops being visible to the caller, the silently-wrong shape triage
ranks highest.

Three candidates, measured once Phase A made crossings measurable
(`bench/regression/gc_boundary_bench.vibe` / `gc_boundary_copy_bench.vibe`,
400 iterations, p50; the reference lane confirmed present with
`VIBE_BENCH_EMIT_WASM`):

| | run time | size | identity |
|---|---|---|---|
| **boundary monomorphization (adopted)** | **±0** | +1–6% (lower-bound estimate) | **preserved** |
| materializing copy | **+76%** (slower than no lane) | ±0 | **broken (P0)** |
| keep crossings off the lane (status quo) | ±0 | ±0 | preserved |

The lane itself is worth **−22% with zero guest bump allocation** (linear
91 ns → gc 71 ns). The copy costs 160 ns, slower than having no lane at all, so
it loses on cost even before identity.

**Adopted: monomorphize the boundary.** A crossing function is duplicated into a
reference version and an i64 version, and each caller picks by its own
representation. Nothing is copied, so identity holds trivially, and the
crossing costs nothing at run time. Implemented for exported declarations by
#1722 (§4.3). The size estimate is a lower bound: about 43 B per duplicated
function, multiplied by `lib/`'s 485 functions that take and return an
`Array[..]` (3,166 that mention one in their signature), **without** transitive
duplication (a duplicated function's callees needing both versions). If size
blows up anywhere, it is there, so the transitive factor is measured as
duplication widens.

### 7.2 Open

1. **Closure capture (step D).** `call_indirect` traps unless the type matches
   exactly, and closure types are chosen by arity alone (`num_closure_types`).
   Adding an element-type dimension multiplies the table types. The deliberate
   boundary is **i64-fixed closures with a fail-closed fallback**: the safety
   predicate refuses a native array that a closure captures (`EFn => false`),
   so a captured array stays on the i64 lane. #1543 is closed as not planned;
   reopen it when the boundary measurements show closure-boundary conversions
   dominate, or when a concrete workload needs native capture and comes with a
   typed-table size/performance proposal.
2. **`Array[Double]` as `(array (mut f64))`.** Out of scope: cells stay
   `(mut i64)`, and the element type does not change the representation (§4.2).
3. **The remaining aggregate positions** of §4.3: enum payload fields, records
   in lambda or module-initializer frames, and nested reference fields.
