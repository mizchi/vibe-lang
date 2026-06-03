# Selfhost uniform value representation — design for runtime pointer discrimination

Status: **proposed** (ADR-0055). Prerequisite for *recursive field drop* in the
selfhost Perceus RC port (`docs/spec/selfhost-rc-port.md`). `src/` stays
authoritative; this documents the design the selfhost backend needs before the
RC vertical can reclaim **nested** heap (a dropped container freeing its heap
fields) and **container/call escapes**.

## Why this is needed

The selfhost linear backend's RC port reclaims the common scope-local and alias
cases at 0 bytes/iteration (tuple / record / enum / closure-body / alias / array
literal — `selfhost-rc-port.md`). The remaining leak sources are:

1. **Nested heap**: dropping `((1,2),(3,4))` frees the outer tuple block but not
   the two inner tuple blocks — recursive field drop is needed.
2. **Container / call escapes**: a heap value stored into a container or passed
   as an owned argument (other than a `let`-alias) is not dup'd, so it leaks.

Both need a generic `rc_drop` that, given a field value, can **decide at runtime
whether it is a heap pointer** (to recurse / decrement). `src/` does exactly this
(`wasm_codegen_rc.mbt::emit_rc_drop` → `(val & tag_mask) == tag_obj`, then
`ptr = val & ~tag_mask`). The selfhost backend **cannot**, because:

### Blocker 1 — integers are raw `i64`

`EInt(n)` emits `i64.const n` (`compile_expr.vibe`), and arithmetic is plain
(`add` → `i64.add` in `compile_call.vibe`). There is no tag, so an integer `16`
is indistinguishable from a pointer to address `16`. A generic drop scanning a
field cannot tell scalars from pointers.

### Blocker 2 — floats are raw `i64` too

`EFloat` stores `Double::to_i64_bits` reinterpreted (`compile_expr.vibe`); the
int-vs-float decision is **static** (`expr_is_floatish`), not tagged. A float in
a heap field has an arbitrary bit pattern that can collide with any pointer tag.

### Blocker 3 — the AST carries no types

`ETuple(Array[Expr])` / `ERecord(Array[(String, Expr)])` (`core/ast.vibe`) have
no element types, so a static per-object **pointer bitmap** can't be computed at
construction either — the other way `src/`-free precise GCs identify pointers.

### Blocker 4 (separate, analysis-side) — escaping field projections

Even with perfect pointer identification, recursive drop is unsafe when an
extracted field escapes: `let t = ((1,2),3); t.0` returns the inner tuple, but
`t` is then dropped — recursively freeing the returned inner block (use-after
-free). Full Perceus dups an escaping projection. This is an **ownership-analysis**
requirement, independent of value representation, and must land together with
recursive drop. (Tracked here so the value-repr work is not mistaken for
sufficient on its own.)

## Decision: a uniform value representation (low-bit tagging)

Make every runtime `i64` value **self-describing** so a generic drop can classify
it. Chosen scheme (low-bit tagging), applied **only under `enable_rc`** so the
default selfhost bootstrap path keeps raw `i64` (no perf/representation change,
no bootstrap risk):

| value kind        | representation (low bits) | notes |
|-------------------|---------------------------|-------|
| integer           | `n << 1` (…0, **even**)   | tag bit 0 = scalar |
| heap pointer      | `(block+8) \| 1` (**odd**)| tuple/array/record/enum/closure-with-captures |
| float             | **boxed** on the heap → a heap pointer (odd), or NaN-boxed (see below) |
| bool              | `0` / `1` kept as small even ints, or `n<<1` like Int |
| string fat ptr    | special-cased (see below) |

### Why int = `n<<1` (even) and pointers = odd

- **Arithmetic stays cheap.** With `n<<1`: `+`, `-`, signed `<`/`>`/`<=`/`>=`,
  `==`, `!=`, and `& | ^` all operate directly on the tagged form (the result's
  low bit stays 0). Only `*`, `/`, `%`, and right shift need a correction
  (one `>>1` / `<<1`). `+`/`-` need none. (Int = `n<<1|1` would force a `-1`
  correction on every `+`.)
- **Pointers already trend odd.** Under `enable_rc` today records/enums/closures
  are `(block+8)|1` (odd) — *unchanged*. Only tuples and array literals (today
  raw/even `block+8`) flip to `|1` (odd). Their field-access / drop sites already
  have the `& -2` untag helper (`emit_rc_value_ptr_i32`); switching them from
  `tagged=false` to `tagged=true` is mechanical, and `& -2` is the correct untag.
- The header `type_id` (already written: tuple=3, record=0, array could take a
  distinct id, enum tag) lets the recursive drop dispatch on object shape once it
  knows the value is a pointer.

### Floats

Two options; **box-on-heap** is the conservative first cut:

- **Heap-box** every `enable_rc` float as a 1-field heap object (`type_id=float`,
  payload = the f64 bits). Floats become odd pointers, uniformly classified, and
  recursively dropped like any leaf. Cost: an allocation per float; acceptable
  for the RC path (opt-in, correctness-first). Field access / arithmetic unbox.
- **NaN-box** (follow-up): pack pointers into the payload of a quiet-NaN `f64`
  and keep non-NaN doubles inline. No per-float allocation but a more intricate
  scheme touching every float op. Deferred unless float-heavy RC code matters.

### Strings, bytes, closures

- String / bytes fat pointers (`(offset<<32)|length`) are **leaf, non-heap-block**
  values — they don't point at an RC block. The drop must skip them. Simplest:
  give them an even low bit (they already do — `offset<<32` has low bits 0 when
  length is even…) — **insufficient**, so instead the recursive drop only follows
  fields whose object `type_id` marks them as RC-managed, OR strings get a
  reserved tag. Resolve during Stage 2 (see plan); conservative default: do not
  follow string/bytes-typed fields (leak, safe).
- Closures with captures are `|1` heap blocks but use a **different header**
  (`[table_slot@0][num_captures@4]`, no `alloc_size`/`rc_count`). They must gain
  the RC header (or be excluded from recursive following) before a generic drop
  touches them. Closures without captures are immediates (`(slot<<2)|2`) — never
  followed.

## Codegen surface (sites to make tag-aware, all under `enable_rc`)

From the investigation, the integer/value surface is the whole numeric path:

- **Literals**: `EInt` (`compile_expr.vibe` tag 0), `EBool` (tag 1), `EFloat`
  (tag 2, boxing).
- **`EBinOp`** (`compile_expr.vibe` tag 5 + `emit_binop_op`): `+ - * / % < > <= >=`
  and bitops `& | ^ << >>`; plus `==`/`!=` via the `eq` builtin (tagged operands).
- **`EUnaryOp`** (tag 6): unary `-`, `!`.
- **Inline `if`-condition comparisons** (`compile_expr.vibe` tag 7) — a second,
  duplicated comparison path.
- **`match` `PInt`** literal comparison (`compile_match.vibe`).
- **Builtin bodies** consuming/producing ints: `eq`, `Array::get`/`set` index
  args, `print_i64`, fs/host boundaries — untag at the boundary.
- **Pointer tag flip**: tuple construction (`compile_expr_tail2.vibe`), array
  inline alloc (same), tuple field access (`compile_expr_tail4.vibe` EDot numeric
  + `compile_match.vibe` tuple loads) → switch to `tagged=true` / `|1`.

The non-`enable_rc` path is untouched; every site gets an `if ctx.enable_rc`
branch (mechanical but broad).

## Staged migration plan

Each stage keeps the **selfhost bootstrap** green (default path unchanged) and is
verified by the RC e2e + leak suite, which must be **expanded** to exercise every
arithmetic / comparison / bitop / shift / float / nested-data case under
`enable_rc` (current coverage is too thin to catch a tagging bug).

1. **Stage 1 — tagged integers.** `EInt`, all int `EBinOp`/`EUnaryOp`,
   if-condition comparisons, `PInt`, and the `eq` builtin, under `enable_rc`.
   Add exhaustive RC arithmetic e2e tests first (the safety net). No behavior
   change expected (results identical); the leak figures are unchanged.
2. **Stage 2 — uniform pointer tags.** Flip tuples/arrays to `|1`; reserve a
   classification for string/bytes/closure-without-RC-header so the drop can skip
   them. Give floats a representation (heap-box). Header `type_id` finalized per
   kind (tuple/array/record/enum/closure/float/string).
3. **Stage 3 — generic recursive `rc_drop`.** Port `emit_rc_drop_fields` adapted
   to the selfhost 8-byte-slot layout: `(val & 1)==1 && classify(type_id)` → for
   each RC-managed field, recurse. Now nested heap is freed.
4. **Stage 4 — escape ownership (analysis).** Dup on escaping field projections
   and container/call owning escapes (the general dup-placement work the
   `PaAliasDup` slice started). Only then are container/call escapes leak-free
   and recursive drop fully safe.
5. **Stage 5 — verification & cutover.** Wasmtime RC e2e gate, parity gates with
   RC on, then consider RC as the selfhost linear default when wasm-gc is
   unavailable (issue #493 C/F).

## Risk & scope

- **Large blast radius** (the whole numeric path) but **contained to `enable_rc`**
  — the bootstrap (default path) is structurally unaffected, so a tagging bug can
  only break opt-in RC programs, caught by the e2e/leak suite.
- **No user-visible payoff until Stage 3+** — Stages 1–2 are pure infrastructure;
  recursive drop (Stage 3) and escape ownership (Stage 4) deliver the actual
  reclamation. This is multi-session work.
- **`src/` is authoritative** and already does all of this with tagged values;
  the selfhost port mirrors it, adapted to the 8-byte-slot layout and the
  `n<<1`/odd-pointer scheme chosen here.

## Alternative considered: static pointer bitmap (rejected as primary)

Computing a per-object pointer bitmap at construction (from `heap_binding_names`
+ literal detection) avoids tagging arithmetic, but: (a) needs header space
without shifting payload, (b) only covers statically-known-heap fields
(call-returned heap fields are missed → leak), and critically (c) does **not**
solve Blocker 4 (escaping projections) — that ownership work is required either
way. Tagging is the general, `src/`-aligned mechanism; the bitmap is at best a
partial optimization layered on top later.
