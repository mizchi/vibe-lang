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

- **Literals**: `EInt` (`compile_expr.vibe` tag 0 → `emit_i64_const(n<<1)`),
  `EBool` (tag 1 → `0`/`2`), `EFloat` (tag 2, boxing).
- **`EBinOp`** (`compile_expr.vibe` tag 5 + `common_base::emit_binop_op`).
- **`EUnaryOp`** (tag 6): unary `-` (`0 - a` — already tag-correct since `0` is
  tagged-0 and `a` tagged), `!` (needs result re-tag, see table).
- **Inline `if`-condition comparisons** (`compile_expr.vibe` tag 7) — a second,
  duplicated comparison path; conditions consume tagged bools (`true`=2 is
  non-zero → `i32_wrap` truthiness still works, no change needed there).
- **`match` `PInt`** literal comparison (`compile_match.vibe`) → compare scrutinee
  against `k<<1`.

### Per-operator tag correction (int = `n<<1`, bool = `0`/`2`)

Worked out from `emit_binop_op` (operands arrive tagged; `a=x<<1`, `b=y<<1`):

| op            | identity                                  | correction |
|---------------|-------------------------------------------|------------|
| `+` `-`       | `(x±y)<<1`                                 | **none** |
| `& \| ^`      | low bit stays 0                           | **none** |
| `%`           | `2x mod 2y = 2(x mod y)`                   | **none** |
| `&&` `\|\|`   | `{0,2}` closed under `and`/`or`           | **none** |
| `*`           | `a*b = xy<<2`                             | result `>> 1` (arith) |
| `/`           | `a/b = x/y` (trunc, both scaled)          | result `<< 1` |
| `<<`          | `(x<<1)<<y = (x<<y)<<1`                    | untag **shift amount** (`b>>1`) only |
| `>>`          | `(2x)>>y ≠ 2(x>>y)` when bit `y-1` set     | untag **both**, shift, **re-tag** result |
| `== != < > <= >=` | order/equality preserved by `<<1`     | result is a bool → `<< 1` (tag 0/2) |
| unary `!`     | `eqz`→0/1                                  | result `<< 1` |

So only `* / << >>` and the comparison/`!` **bool results** need touching;
`+ - & \| ^ % && \|\|` are free. Comparison results MUST be tagged or a `1`
(true) in a heap field would be misread as an odd pointer.

### Boundary inventory (untag tagged→raw / tag raw→tagged)

Discovered sites where an int is used as an **address/count** (must untag) or a
raw count enters the value world (must tag):

- **Export-return boundary**: `main`'s returned tagged int must be untagged
  (`>>1`) before the wasm return, else `--invoke main` prints `2n`.
- **`emit_i32_wrap_i64` index sites** (dozens in `compile_call.vibe`): any int
  used as an array index / offset / length needs `>>1` before the wrap.
- **Named runtime builtins** (generated functions, resolved via `resolve_func`):
  `Array::get`/`set`/`push`/`make`/`length` (index & length args/returns),
  `Bytes::*`, `String::length`/`char_code_at`/slice — untag index/length args,
  tag returned counts.
- **`eq` builtin body**: operands tagged (equal-tagged ⟺ equal), but it returns
  a bool → must yield `0`/`2`; pointer-structural path unaffected (pointers stay
  odd).
- **Host imports**: `print_i64` / `__to_string` / `Fs` writes — untag at the
  call boundary.

The safety net for all of the above is in `codegen_heap_e2e_test.vibe`
(Stage 1 tagging section): each operator, the int↔heap-field round-trip,
int-as-array-index, tagged-bool branching, loop counters, recursion, `PInt`,
and a near-cap large int are pinned to identical results on the default and RC
paths, so a wrong correction surfaces immediately.

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

1. **Stage 1 — tagged integers. ✅ IMPLEMENTED.** `EInt`/`EBool`/const-int
   literals, all int `EBinOp`/`EUnaryOp` (with the per-operator corrections
   above), `PInt`/`PBool` match literals, the `eq`/`!=` results, the `Array::get`/
   `set`/`length` index/length boundary (RC uses the editable `gen_*` bodies that
   untag the index / tag the length), and the exported Int entry return (untagged
   at the boundary) — all gated on `enable_rc`. The inline if/while-condition path
   needs **no** change: `n<<1` preserves signed order and `true=2` is truthy, so
   comparisons/conditions just work on tagged operands. Verified: the safety net
   (`codegen_heap_e2e_test.vibe`, 41/41) gives identical default/RC results, RC
   reclamation is still **0 bytes/iter** (constant 32 B), and no regressions.

   **Selfhost-specific finding:** tagging must shift at **runtime**
   (`i64.const n; i64.const 1; i64.shl`), not compute `n<<1` at compile time — the
   selfhost compiler's own Int is 62-bit, so `n<<1` for a near-cap literal would
   overflow the *host* Int. The runtime shift is computed in full wasm i64 and is
   correct for the entire `2^61-1` literal range. (The `src/` MoonBit host has a
   full 64-bit Int and does not hit this.)

   **Deferred from Stage 1 (no gate coverage, documented):** String/Bytes
   builtins (`String::length`/`char_code_at`/substring, `string_*`) still treat
   their int args/returns as raw — string-using RC programs are incorrect until a
   later stage wires the same untag/tag through the string boundary. No heap-e2e
   or arith-safety-net case exercises strings, so the gates stay green.
2. **Stage 2 — uniform pointer tags.** Flip tuples/arrays to `|1`; reserve a
   classification for string/bytes/closure-without-RC-header so the drop can skip
   them. Give floats a representation (heap-box). Header `type_id` finalized per
   kind (tuple/array/record/enum/closure/float/string).
   - **Stage 2a — tuples flipped to `|1`. ✅ IMPLEMENTED.** Construction
     (`compile_expr_tail2`) emits `(block+8)|1`; EDot numeric access
     (`compile_expr_tail4`) and the 4 tuple pattern-load sites (`compile_match`)
     untag with `& -2`; the drop classifies tuples as `rc_kind 2` (tagged) so
     `emit_rc_drop_local` untags to find the block. Gate-verified 41/41.
   - **Stage 2b — arrays flipped to `|1`. ✅ IMPLEMENTED.** Array literal
     construction (`compile_expr_tail2`) emits `(block+8)|1`; the array builtins
     untag the pointer (`& -2`) under RC by routing the RC path through the
     editable `gen_*` bodies — `gen_arr_get`/`set`/`len`/`push` untag `local 0`,
     `gen_arr_new` returns `|1`; drop classifies arrays as `rc_kind 2`. The
     `data_ptr` indirection and growable buffer are unaffected (only the *value*
     pointer is tagged; internal fields stay even). Verified by
     `scripts/verify_selfhost_rc.sh`: gate 41/41 (incl. array get/set/length/
     push/builder/grown) and array reclamation 0 B/iter. (An earlier attempt was
     reverted when the stale-cache trap hid that the array builtins are reached
     through `gen_*`; the reliable loop confirms it now.)

   > **Verification methodology (learned the hard way — Stage 2).** `vibe test`
   > **memoizes pure-test results**, and `--no-cache` does **not** invalidate that
   > memo — only changing the *test file's content* forces a real re-run. So
   > `vibe test codegen_heap_e2e_test.vibe` can report a stale `41/41` that does
   > not reflect edited codegen. **Always bust the cache by appending a unique
   > comment to the test file** (then `git checkout` it) when verifying codegen
   > changes. Do **not** rely on ad-hoc `compile_wasi_rc` → write-`/tmp` →
   > `measure_selfhost_heap.mjs` probes for *correctness*: the test sandbox
   > isolates `/tmp` and the entry takes a closure-`env` arg, so the `result`
   > field is unreliable (the `heap_used` field, read from the `__heap_ptr`
   > global, is fine for reclamation). The **authoritative** signal is the
   > genuinely-busted `codegen_heap_e2e_test.vibe` (default vs RC, identical
   > results on wasmtime).
3. **Stage 3 — generic recursive `rc_drop`. ✅ IMPLEMENTED.** Two parts landed:
   - **Stage 2c (uniform drop-class byte).** Every headered RC block carries a
     drop-class id in the **high byte of the rc_count word** (`block+7` =
     `value-1`), set at construction: tuple/record/ctor/closure = `1`
     (field-vector), array = `5`. rc lives in the low 24 bits, so `rc--`
     (full-word `-1`) preserves the byte and the zero-test becomes
     `(rc_word * 256) == 0` (the `*256` shifts the class byte out of the 32-bit
     word — chosen because the selfhost emitter has `i32.mul`/`load8_u`/`store8`
     but no `i32.and`/`i32.shr`). `array_new` was given the same
     `[alloc_size@0][rc_count@4][class@7]` header (value = `block+8`, total `84`
     == a cap-8 literal so the free-list reuses it) so **every** odd array
     pointer is self-describing.
   - **Stage 3 (recursive helper).** A generated `__rc_drop` wasm function
     (`gen_rc_drop_body`, registered only under `enable_rc` as the last
     generated builtin so the default path keeps byte-identical indices; its
     wasm index is threaded as `CompileCtx::rc_drop_func_idx`) decrements the
     value's rc and, at zero, reads the class byte and — for a field-vector —
     loops `count@value+4` fields at `value+8+i*8`, **recursing into itself**
     (`call self_idx`) to arbitrary depth; for an array it loops `length@value+4`
     elements behind `data_ptr@value+8`; then pushes the block to the free-list.
     Scope-end drops route through it (`local.get; call rc_drop_func_idx`).
   Verified (`scripts/verify_selfhost_rc.sh`): the heap-e2e gate is 45/45
   (default vs RC identical, incl. 4 new nested-drop-in-loop cases — 2/3-level
   tuples, record-of-tuples, enum-payload-tuple — that both recurse and reuse
   the freed blocks), and a per-iteration **nested** tuple
   `((i,i+1),(i+2,i+3))` reclaims at **0 B/iter** (heap 96→96: outer + both
   inner blocks freed each iteration; without recursion the 64 B/iter of inner
   blocks would leak).

   **Known gap (latent, opt-in RC only):** captured closures are odd pointers
   that share the heap tag but are **not** yet headered (value = block_start, no
   rc_count/class byte), so a captured closure stored in a *dropped* container
   would be misclassified by the recursion. No opt-in RC test/benchmark stores a
   closure in a dropped container, but this must be closed (header closures like
   `array_new`) before RC is sound for general higher-order programs — track
   with the Stage 4 escape work. Floats-in-heap-fields are likewise unsound
   until boxed.
4. **Stage 4 — escape ownership (analysis). ◐ PARTIAL (the safety-critical slice
   landed).** Stage 3's recursive drop turned an *escaping projection* from a
   benign leak into a **use-after-free**: `let pick = (i) -> { let t = ((i,i+1),
   (i+2,i+3)); t.0 }` returns the inner tuple while `t` is recursively dropped,
   so the returned block is freed; with free-list reuse in the caller the result
   corrupts (a confirmed `default=15` vs `rc=320`). **Fix (landed):** when a
   scope's tail expression is a projection chain rooted at the binding being
   dropped (`scope_tail_proj_root(body) == name`), the result is saved, **dup'd
   runtime-guarded** (`emit_rc_dup_guarded`: `if (v&1) inc rc` — a no-op on an
   even scalar, since the field's heap-ness is unknown — Blocker 3), then the
   drop runs, then the result is restored. The escaped reference now survives the
   container's recursive dec. Pinned by two heap-e2e cases (single escaped
   projection in a loop; three escaped projections read after reuse).

   **Remaining (leaks, safe; need owned-vs-borrowed typing):**
   - The dup gives the escaped value rc 1 but its eventual owner is often a
     `let p = pick(...)` bound to a **call** result, which is not classified as a
     droppable heap binding (dropping a general call result is unsafe — e.g.
     `Array::get` returns a *borrow*, dropping it would double-free). So the
     `pick`-in-a-loop pattern now **leaks 32 B/iter** (was: corrupt). Closing it
     needs the owned/borrowed distinction so owned call results can be dropped.
   - `let a = t.0; …; a` (projection bound to a *let* that then escapes) and a
     projection stored into a fresh container (`(t.0, t.1)`) are not yet handled.
   - Container/call **owning** escapes (storing/ passing an owned heap value) are
     still not dup'd → leak (safe), as before.
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
