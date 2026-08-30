# Selfhost uniform value representation — design for runtime pointer discrimination

Status: **accepted, in progress** (ADR-0055). Stages 1–3 implemented, Stage 2
float heap-boxing implemented (#509; NaN-box deferred), Stage 4 partial (the
safety-critical slice + most leak fixes landed), Stage 5 measured. The only
remaining implementation work is the **residual Stage 4 escape leaks**
(container-owning-escape, and the narrow case of an unannotated owned param
passed through whole rather than projected/matched) — all *safe* leaks (no
use-after-free), and the gate that blocks RC cutover to the linear
default. Prerequisite
for *recursive field drop* in the Perceus RC port
(`docs/spec/rc-port.md`). The canonical implementation target is
the compiler under `lib/@vibe/compiler/`; the MoonBit `src/` backend was
removed in #594 and is referenced here only as historical context for the
design rationale. This documents the design the
compiler needs before the RC vertical can reclaim **nested** heap
(a dropped container freeing its heap fields) and **container/call escapes**.

## Why this is needed

The linear backend's RC port reclaims the common scope-local and alias
cases at 0 bytes/iteration (tuple / record / enum / closure-body / alias / array
literal — `rc-port.md`). The remaining leak sources are:

1. **Nested heap**: dropping `((1,2),(3,4))` frees the outer tuple block but not
   the two inner tuple blocks — recursive field drop is needed.
2. **Container / call escapes**: a heap value stored into a container or passed
   as an owned argument (other than a `let`-alias) is not dup'd, so it leaks.

Both need a generic `rc_drop` that, given a field value, can **decide at runtime
whether it is a heap pointer** (to recurse / decrement). `src/` does exactly this
(`wasm_codegen_rc.mbt::emit_rc_drop` → `(val & tag_mask) == tag_obj`, then
`ptr = val & ~tag_mask`). The compiler's backend **cannot**, because:

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
default bootstrap path keeps raw `i64` (no perf/representation change,
no bootstrap risk):

| value kind        | representation (low bits) | notes |
|-------------------|---------------------------|-------|
| integer           | `n << 1` (…0, **even**)   | tag bit 0 = scalar |
| heap pointer      | `(block+8) \| 1` (**odd**)| tuple/array/record/enum/closure-with-captures |
| float             | **boxed** on the heap → a heap pointer (odd) under RC; inline f64-bits non-RC. (NaN-box deferred — see below) |
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

> **Float status (2026-06).** Floats were broken in the selfhost linear backend
> at three layers; all three are now fixed (heap-boxing, below, is the next step):
> 1. ✅ **Numeric conversions were no-ops** (`Int::to_double` / `Double::to_int`
>    / `Float::*` were intercepted by an identity fast-path in
>    `compile_call.vibe`, shadowing `gen_double_to_int_body` etc.). Fixed in
>    #505 (and `expr_is_floatish` extended to the float-producing aliases).
>    `Double::to_int(Int::to_double(7))` = 7.
> 2. ✅ **Float literals (Blocker-2) — FIXED.** `EFloat` used
>    `emit_f64_const_bits(buf, Double::to_i64_bits(v))`, but a normal f64 bit
>    pattern (e.g. `4.0` = `0x4010000000000000`) exceeds `2^61-1`, so it was
>    truncated when forced into a tagged `Int` → corrupted `f64.const` → every
>    literal decoded to ≈0. Fix: split the pattern into two 32-bit halves (each
>    `≤ 2^32-1`, fits the 62-bit Int) via new `Double::to_i64_bits_lo` /
>    `Double::to_i64_bits_hi : (Double) -> Int` builtins, and emit the
>    `f64.const` from the halves (`emit_f64_const_lohi`). Implemented in both
>    compilers:
>    - **`src/`** (floats heap-boxed): `wasm_codegen_builtin_numeric.mbt` loads
>      the f64 bits directly from the box (`i64.load` at offset 4), masks /
>      shifts the half, and tags it as a normal Int (`<< 2`, `tag_int = 0`);
>      declared in `typecheck_call_builtin_handler_runtime_memory.mbt`,
>      `purity.mbt`, `address.mbt`, `wasm_codegen_sig.mbt` (`needs_heap`).
>    - **selfhost** (floats inline f64-bits): `compile_call.vibe` masks
>      (`shr_s` + `& 0xFFFFFFFF`, no `shr_u` needed) and tags per `enable_rc`
>      (`<< 1`); declared in `checker/builtins_misc.vibe`. `EFloat`
>      (`compile_expr.vibe`) now calls `emit_f64_const_lohi`.
>    - Verified: float literals (`4.0`→4, `7.9`→7, `1.5+2.5`→4, `10.0/4.0`→2,
>      mixed) in `codegen_heap_e2e_test` default **and** RC; byte-parity 74/74;
>      selfbuild/bootstrap deterministic.
>    - ⚠️ **The wasm-gc backend was left behind until #1262 (2026-08).** This
>      entry read "FIXED" for over a year while `codegen/gc/backend_expr.vibe`
>      still ran the original `emit_f64_const_bits(buf, Double::to_i64_bits(v))`.
>      Nothing caught it because the divergence needs the **compiler itself** to
>      be RC-built — the default self-build is `VIBE_RC=0`, and a bump-built
>      compiler computes the full pattern correctly. Flipping the gate to
>      `VIBE_RC=1` surfaced it as gate 40h reading 91527 instead of 101557
>      (`Double::to_int` saturating to 0 for every input, float interpolation
>      stringifying to one character): under RC the builtin returns the pattern
>      HALVED, so all 8 emitted `f64.const` bytes are `true_byte >> 1`. Now
>      fixed, and locked statically by compiler-gate §89 (no codegen site may
>      call `emit_f64_const_bits` / `Double::to_i64_bits`) — a static lock
>      because the default gate has no RC-built compiler to ask.
>    - `Double::to_i64_bits` itself remains **unsound by signature** and is a
>      trap for user code too, not just codegen: under the production default
>      (`VIBE_RC=1`) it returns exactly half the true pattern for every double
>      (`2.0` → 2305843009213693952 = `Int::max_value + 1`, not
>      4611686018427387904). Callers must use the `_lo` / `_hi` pair.
>      `lib/@vibex/wasm_wat_encoder` no longer converts decimal WAT literals
>      through a `Double` at all: it keeps an exact BigInt ratio, rounds once
>      to nearest-even, and returns the two 32-bit halves directly (#1737).
> 3. ✅ **Float-ness through `let` bindings (Blocker-3) — FIXED.** The AST is
>    untyped, so `expr_is_floatish` was purely syntactic and could not see that
>    a *variable* held a float (`let x = 1.5; x + y` took the integer `+`).
>    Fix: track binding float-ness by *local slot* in `ctx.float_local_slots`
>    (mirroring `heap_binding_names`) — a `let` / `let mut` whose initializer is
>    floatish registers its slot, and `expr_is_floatish` (shared in
>    `compile_expr_tail.vibe`, taking `local_names` + `ctx`) resolves an `EIdent`
>    to its slot (most-recent binding wins, like the codegen) and reports
>    float-ness by slot membership. Slots are truncated alongside `local_names`
>    at scope boundaries (if-branches, match arms), so a shadowing same-name
>    binding of a different type, and slots reused across sibling scopes, are not
>    misclassified (codex review on #507). Propagates transitively (`let b = a +
>    1.5`) and covers conversion-bound vars (`let x = Int::to_double(n)`).
>    Verified default + RC incl. shadow/branch-reuse regressions; byte-parity
>    74/74; selfbuild deterministic. Remaining limits (no AST types): `Double`
>    function *parameters* and lambda-captured floats are not tracked. Full
>    generality needs threaded inference; the common local-binding cases work.
>
> With literals (Blocker-2) and `let`-bound float variables (Blocker-3) working,
> **heap-box** (below) can now proceed.

Two options; **box-on-heap** is the conservative first cut:

- ✅ **Heap-box (IMPLEMENTED)** — every `enable_rc` float is a 1-payload heap
  block `[alloc_size@0][rc_count@4][f64_bits@8]`, value `= (block+8)|1`. Writing
  `rc_count = 1` as a full i32 zeroes the drop-class byte at block+7 → **class 0
  (leaf)**, so the existing recursive `__rc_drop` frees it without following
  fields (no drop-helper change needed) and a float in a heap field is reclaimed
  by its container's drop. Floats become odd pointers, uniformly classified —
  closing the soundness hole where an inline f64 bit pattern (possibly odd) was
  misread as a pointer. Helpers `emit_box_float` / `emit_unbox_float`
  (`common_base`). Producers box (`EFloat`, float `+ - * /`, `Int::to_double` /
  `Int::to_float`); consumers unbox (float binop operands, `Double::to_int` /
  `Float::to_int`, `Double::to_i64_bits[_lo/_hi]`); `Float<->Double` is identity
  (pointer pass-through). Float `let`/`let mut` bindings are registered in
  `heap_binding_names`, so the existing Perceus dup/drop machinery retains a
  multiply-used float (no double-free) and drops it at scope end. A float
  *comparison* yields an even (tagged) bool — dup/drop are guarded no-ops on it.
  Non-RC keeps the inline f64-bits representation. Verified default + RC:
  float-in-tuple drop, multiply-used dup, alloc/free loop churn, comparison,
  and float through a user function (heap-e2e); byte-parity 74/74; wasm-gc 7/7;
  selfbuild deterministic. Cost: an allocation per float (opt-in RC path).
- **NaN-box** (follow-up) — **DEFERRED (decision 2026-06; not a localized
  optimization).** The idea is to keep doubles inline as native `f64` and encode
  every *non*-float value (ints, pointers, bools) into the ~2^51 quiet-NaN
  payloads, avoiding a per-float allocation. The blocker is that this is
  **all-or-nothing and incompatible with the current low-bit-tagged i64
  representation**: a full `f64` needs all 64 bits, so a value cannot be both an
  inline double *and* carry a low tag bit. Making floats inline therefore forces
  the *whole* value world to become f64-centric, which:
  - **shrinks the `Int` range from 2^61−1 to ~2^50−2^51** (NaN payload width),
    breaking the documented Int contract (CLAUDE.md, 62-bit tagged), and
  - touches **every** numeric op, pointer encoding, and comparison in *both*
    compilers — far larger and riskier than heap-boxing.

  Meanwhile the cost NaN-boxing would save is already small: the heap-box path
  (implemented above) allocates float blocks through `__rc_alloc`, whose
  **free-list does exact-fit reuse**, so a float-heavy RC loop recycles the same
  16-byte block (O(1) pop/push) rather than allocating fresh — and RC is opt-in
  (correctness-first), so float-heavy RC code is the rare case. Revisit only with
  a **measured** float-heavy RC bottleneck that the free-list does not absorb;
  even then a representation change of this magnitude needs explicit sign-off on
  the Int-range tradeoff.

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
  tagged-0 and `a` tagged), `!` (needs result re-tag, see table), `~` (#2344 —
  lowers to `x ^ -1`, and the constant is where the tagging shows: complementing
  a tagged `n<<1` needs tagged(-1) = `-2`, so xoring with a raw `-1` sets the tag
  bit and yields a malformed `Int`. The untagged lanes use `-1`).
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

Each stage keeps the **bootstrap** green (default path unchanged) and is
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
     `scripts/verify_rc.sh`: gate 41/41 (incl. array get/set/length/
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
   > `measure_heap.mjs` probes for *correctness*: the test sandbox
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
   Verified (`scripts/verify_rc.sh`): the heap-e2e gate is 45/45
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

   **Call-result drop (leak fix, landed).** The escaping-projection dup gives the
   result rc 1, and its owner is typically a `let p = f(...)` bound to a call
   result. The Perceus analysis *already* plans `PaDrop(p)` (every binding gets
   `remaining >= 1` in `pe_declare`); codegen simply never classified an `ECall`
   value as a heap binding. Now it does: a call result is an **owned** heap value
   (the callee returns its reference — fresh allocation, an arg whose ownership
   transferred in under the owning-argument convention, or an escaping projection
   the callee already dup'd), so `let p = f(...)` is droppable. The `pick`-loop
   now reclaims at **0 B/iter** (was 32). Two safety carve-outs make this sound:
   - **Borrow-returning builtins** (`Array::get` / `__index`) return an element
     the container still owns; their results are *excluded* from the drop (else
     the container's recursive drop would double-free). Pinned by an
     array-of-tuples `Array::get`-in-a-loop case.
   - **String/bytes fat pointers** (`(offset<<32)|length`) can be *odd* yet are
     **not** RC blocks. Both `__rc_drop` and the guarded dup now skip any odd
     value whose **high 32 bits are non-zero** (the data offset ≥ 64) — every
     heap block address is `< 2^32`. This also closes the Stage 2 string-in-a
     -heap-field gap (a string field is skipped by the recursive drop). Pinned by
     a string-returning-call-in-a-loop case.

   **Let-bound projection (landed).** `let a = t.0` is now classified as a heap
   binding and gets a **guarded dup at the binding** (the Perceus analysis
   already plans its scope-end drop, assuming it owns one reference, but `t.0`
   does not take one — the dup makes that assumption true). If `a` escapes it
   survives `t`'s recursive drop; if it does not, the analysis-planned drop
   balances the dup. Pinned by a let-bound-escaping-projection case (three calls,
   read after reuse). A projection stored into a fresh escaping container
   (`(t.1, t.0)`) is verified correct under RC by a gate case as well.

   **Non-alias `PaDup` for shared owned values (landed; codex review #499).**
   `let u = (t, t)` uses `t` in two owning positions, so the analysis plans one
   `PaDup(t)`; codegen previously discarded it, leaving `t` at rc 1 while `u`
   holds two references — the recursive `__rc_drop` then visited the shared child
   twice. Now the per-name `PaDup` budget is threaded (`CompileCtx::rc_dup_names`,
   one entry per dup) and emitted as that many **guarded rc_dups at the binding
   site** of the multiply-used value. Placement is occurrence-agnostic (all uses
   share one block, so only the dup *count* matters) and capped at the budget, so
   it can only raise the refcount — at worst a leak, never a premature free. With
   it, `let u = (t, t)` gives `t` rc 2, `u`'s recursive drop decrements it cleanly
   to 0 (no underflow), and the `(t,t)` loop reclaims at a bounded 64 B. Pinned by
   two gate cases (shared tuple in a loop; shared value escaping in a returned
   container, read after reuse). (Owning uses that are neither container elements
   nor calls — rare — may still under-dup, the original latent/non-reproducing
   case, which is safe.)

   **Free-list search allocator `__rc_alloc` (landed).** Diagnosis of an
   apparent "container owning escape" leak (`let t = (..); let a = [t]` in a loop
   leaking 32 B/iter) showed the refcounting was already *correct* — `t` was
   freed every iteration (verified: 2 frees/iter, results identical to default).
   The growth was **free-list fragmentation**, not a missing dup. The single LIFO
   free-list (global 2) was only matched at its **head** by each inline
   allocator: a head-only exact-size check. Per iteration the program allocates
   two sizes (tuple 32 B, then container 84/56 B); the container's recursive drop
   frees the element *then* the container, so the LIFO head becomes the container,
   and the next iteration's tuple request (32 B) misses it — bump-allocating a
   fresh block while a perfectly sized free block sits one node deeper. (The
   inline-literal form `[(i,i+1)]` happened to allocate in the reverse order, so
   its head always matched — which is why only the *by-name* move leaked.) Fix: a
   generated `__rc_alloc(size) -> block_start` helper (type `(i64)->(i64)`, the
   slot after `__rc_drop`) that **walks the free-list for an exact-fit block and
   unlinks it**, falling back to a bump only when none exists. All four inline
   object allocators (tuple, array literal, record, ctor payload) now call it via
   `CompileCtx::rc_alloc_func_idx`. The array / enum-payload / record-field moves
   now reclaim at a bounded heap (0 B/iter); pinned by three reclaim cases
   (`owned_in_array/enum/record`) and three heap-e2e result-parity cases. Exact-fit
   only (no splitting), so it stays drop-in compatible with the recursive
   `rc_drop` free path, and it is `enable_rc`-only (the default bootstrap path
   never allocates from the free-list, so it is structurally unaffected).

   **Heap `mut` reassignment drops the old value (landed).** A heap `mut`
   binding reassigned in a loop (`let mut b = (0,0); … b = t`) leaked the
   *previous* block every iteration (32 B/iter, confirmed; result correct) — the
   Perceus assignment rule "drop the old owner before storing the new value" was
   unimplemented for `mut` bindings (they were never classified as heap, never
   dropped). Fix: `ELetMut` now classifies a heap initializer
   (tuple/array/record/ctor) into `heap_binding_names`, and `EAssign` emits a
   guarded `__rc_drop` of the binding's current value *before* storing the new
   one (mirrors `src/`'s `wasm_codegen_stmt.mbt` assignment path). The drop is a
   guarded **dec** (no-op on a scalar/string, decrements not frees), so an
   aliased old value — rc > 1 via `PaAliasDup` — is safe. **Safety carve-out:**
   when the RHS references the assigned name (`b = b.0`, `b = f(b)`,
   `b = (b.0+i, b.1)`) the drop is *suppressed* — dropping first would free a
   block the new value derives from (use-after-free); these keep the old, safe
   leak. The `b = t` loop now reclaims at a bounded 64 B (two blocks cycling
   through the free-list). Pinned by two heap-e2e result-parity cases
   (reassign-drops-old; reassign-reads-old stays correct) and the `mut_reassign`
   reclaim case.

   **Closures with captures are RC-managed (landed).** A capturing closure's env
   block is now a headered, drop-class-1 (field-vector) block allocated via
   `__rc_alloc`: the value points at `block_start+8` (past the 8-byte header), so
   the call path's value-relative offsets (slot@value+0, captures@value+8) and the
   `& -4` / `& -2` untags line up exactly as in the unheadered default layout —
   the calling convention is unchanged. Capturing a value consumes it (the env
   takes its reference, no dup), the closure `let` binding is classified heap, and
   its scope-end drop runs `__rc_drop` (drop-class 1 → recurse the captures, free
   the env). A capture-less closure stays an immediate (`(slot<<2)|2`, even → the
   drop skips it). So a closure capturing a heap value, called once or many times
   (the call borrows it), or returned (escaping — captures survive until the
   caller drops the closure), reclaims fully. Capture-less and the recursive drop
   are `enable_rc`-only; the default path keeps the raw bump-allocated env. Pinned
   by `closure_capture` / `closure_two` (reclaim) and two heap-e2e parity cases.

   **Container-owning-escape via assignment (landed).** Assigning a container
   projection to an outer mut binding (`keep = box.0`) made `keep` co-own a field
   of the still-live local `box` without taking a reference: when `box`'s
   scope-end recursive drop frees the field, `keep` dangles and the next
   reassign-drop double-frees it (observed as a 16 B/iter leak). Mirroring the
   let-bound projection (`let a = box.0`), the assignment now emits a **guarded
   dup of the projected value** (`compile_expr_tail.vibe`, `EAssign`), so `keep`
   owns its own reference and its reassign / scope-end drop balances it. Limited
   to the clean `!is_self` case (`keep = keep.0` keeps the reassign-reads-target
   carve-out). Pinned by `escape_assign_proj` (reclaim, 0 B/iter) and a heap-e2e
   parity case.

   **Still remaining (leaks, safe):**
   - An owned value stored into a container that *outlives* the current scope
     without a matching drop site (e.g. pushed into a builder kept by the caller,
     or the reassign-reads-target carve-out above) is not dup'd/dropped → leak
     (safe).
   - A heap value captured by a closure that is then stored into a longer-lived
     container (closure escapes via a container, not a return) follows the same
     container-owning-escape gap.

   **Heap `mut` final-value scope-end drop (landed).** The reassignment drop only
   reclaims *overwritten* values; the binding's last value still owns a reference
   at scope end. `ELetMut` now emits a scope-end drop of the final value (same
   projection-rooted-at-name tail guard as `let`), so `let mut b = ...; … ; b.0`
   reclaims fully. Pinned by `mut_final`.

   **Owned parameters (owned-vs-borrowed; landed).** A function parameter is
   *owned*: the caller transfers its reference in under the owning-argument
   convention (a call argument is a consuming use). So a heap param used only by
   borrows (or unused) is never dropped — it leaked. `build_perceus_plan_with
   _params` now declares the parameters as bindings (count + emit in lockstep, so
   the existing machinery emits a `PaDrop` for a borrow-only/unused heap param and
   a `PaDup` for one used in multiple owning positions), and the codegen
   (compile_lambda + the top-level fn path in linked_compile) classifies the heap
   params, emits the owning-use dup budget at entry, and drops the owned params at
   the body tail. The tail drop carries the same projection-escape guard (dup the
   result first when it is a projection rooted at a dropped param — `fst(p) → p.0`).
   Heap-ness is read from the param's type (`type_expr_is_heap`): tuple / array /
   record / enum / concrete struct, but **never** a type containing a function
   (closures are unheadered — the recursive `__rc_drop` would misread one) nor a
   type variable / unannotated param (may be a closure → safe, no drop). A
   top-level fn's param types live on its *signature* (`let f: (A,B) → R`), not on
   the lambda params, so they are read from the SLet annotation; a single tuple
   param prints `((A,B)) → R` but parses as multiple args (the outer parens are
   the param list), so a 1-param lambda with a multi-arg signature reconstructs
   the param type as the tuple of all args. Pinned by `owned_param`,
   `owned_param_proj` (reclaim) and three heap-e2e parity cases.

   **Unannotated nested-closure owned params (landed).** A nested closure's
   params carry no type annotation (the signature lives on an outer binding the
   lambda does not see), so they were classified non-heap and never dropped —
   leaking the owned argument (32 B/iter). `param_is_heap_in_body`
   (`perceus/index.vibe`) now recovers heap-ness *from the body*: a param that is
   **projected (`p.0`) or used as a match scrutinee** is necessarily a
   tuple/record/enum — a closure value or a scalar can be neither — so it is
   classified heap and the callee drops it. The signal is **sound by
   construction** (it never classifies a function-typed param, so the recursive
   `__rc_drop` is never run on an unheadered closure) and **under-detection is
   safe** (a param that is neither projected nor matched keeps the prior safe
   leak, never a premature free). Threaded through `build_perceus_plan_with
   _params`, `compile_lambda`, and the top-level fn path in `linked_compile` so
   plan and codegen share one decision. Pinned by `nested_closure_param` /
   `nested_closure_match` (reclaim, 0 B/iter) and a heap-e2e parity case.

   **Local heap-type inference from call sites (landed).** An unannotated param
   that is **unused or borrow-only** (e.g. `(p) -> { 42 }`) cannot be proven heap
   from the body, so it leaked the caller-transferred value. The RC-only AST pass
   `elaborate_heap_params` (`perceus/index.vibe`, run at the head of
   `compile_wasi_module_rc_impl`) recovers its heap-ness from the **call sites**:
   for a locally-bound lambda that **does not escape** (only ever appears as a
   call callee), if **every** call passes a provably follow-able-heap argument (a
   tuple/array/record literal, or a `let` bound to one) at a position, that param
   is filled with a synthetic heap type so the existing classification drops it.
   The arg-heap test is **lexically scoped** — `analyze_calls` threads a per-scope
   env so each call's args resolve against the bindings in scope *there*, and a
   same-named binding in a sibling branch can never leak in. Heap-ness of an
   **opaque arg** is also recovered interprocedurally: a constructor call carrying
   a payload (`Wrap((..))` → a headered block) and a call to a top-level function
   whose *annotated* return type is heap (`let mk: (..) -> (Int,Int)`) both count
   (`HeapInferCtx` collects ctor names from enum/suberror decls and heap-returning
   fn names from signatures). **Sound by construction:** the call/escape scan is
   exhaustive over the AST, a param is filled only when *all* visible call sites
   agree, and a string/scalar/closure/nullary-ctor arg is never classified heap
   (so `__rc_drop` never misreads one) — under-filling is a retained safe leak,
   never a wrong drop. Pinned by `unused_param_callsite` / `opaque_ctor_arg` /
   `opaque_fncall_arg` (reclaim, 0 B/iter) and heap-e2e cases (unused param
   dropped from a tuple/ctor/heap-call arg; string-arg, nullary-ctor, and
   shadowed-string-branch params *not* mis-inferred). (A param consumed by an
   owning call — `(p) -> { g(p) }` — already balanced without this: the call
   moves it.)

   **Still remaining (smaller, safe):** a lambda that **escapes** (returned or
   stored, so not all call sites are visible — e.g. `let f = mk(); f(t)`, where
   the lambda is not `let`-bound where it is called) keeps its safe leak; so do
   args whose heap-ness is opaque *and* not a ctor/heap-return call (a deep
   projection, a borrow-returning builtin), container-outlives-scope stores, and
   the reassign-reads-target carve-out. Closing the escape case needs
   whole-program points-to (aggregating call sites across aliases); the others
   need field/element-type heap-ness — both larger than this local pass.
5. **Stage 5 — verification & throughput. ◐ MEASURED.** The RC e2e gate (47/47,
   default vs RC identical on wasmtime) is the correctness signal;
   `scripts/bench_rc.mjs` measures the payoff: each benchmark
   `main` runs an N-iteration allocating loop and is compiled both ways, then
   timed (median, fresh instance per run) with peak heap read from `__heap_ptr`.

   **Result (N = 1,000,000, median of 7):**

   | benchmark      | default time | default heap | RC time  | RC heap | RC time | heap |
   |----------------|--------------|--------------|----------|---------|---------|------|
   | flat_tuple     | 7.7 ms       | 15.3 MB      | 16.3 ms  | 96 B    | ×2.11   | 500000× smaller |
   | nested_tuple   | 24.1 ms      | 45.8 MB      | 41.4 ms  | 96 B    | ×1.72   | 500000× |
   | record_tuples  | 26.3 ms      | 53.4 MB      | 42.3 ms  | 96 B    | ×1.61   | 583333× |
   | enum_tuple     | 16.2 ms      | 30.5 MB      | 25.6 ms  | 96 B    | ×1.58   | 571429× |

   The classic RC trade-off: **the heap stays bounded (one block-set, reused via
   the free-list) instead of growing linearly with the iteration count**, at a
   ~1.6–2.1× constant-factor time cost (rc inc/dec + recursive drop + free-list).
   The relative cost shrinks as per-iteration work grows (×1.58 for enum vs ×2.11
   for the flat tuple), since the rc ops amortize against the allocation work.
   The default bump allocator never reclaims, so it OOMs the (bounded) wasm
   linear memory at large N where RC runs indefinitely. Cutover (RC as the
   selfhost linear default when wasm-gc is unavailable, #493 C/F) is gated on
   completing Stage 4 leak elimination (owned/borrowed typing).

   **wasm-gc vs Perceus-RC (`scripts/bench_gc_vs_rc.sh`).** The same four loops,
   compiled three ways — selfhost linear (bump), selfhost linear+RC, and the
   `src/` wasm-gc backend (`vibe compile --wasm-gc`, `struct.new` + engine GC) —
   and timed under a *single* runtime, **wasmtime**. wasmtime (not node) is the
   fair judge: V8 escape-analyzes the non-escaping loop tuple away and reports a
   misleadingly fast wasm-gc time, while wasmtime treats `struct.new` + tracing
   GC as real work. Each backend must reproduce the linear checksum or it is
   marked a failure (loop-only ms, trivial-twin subtracted; N = 1e6, min of 7):

   | benchmark      | linear | Perceus-RC | wasm-gc          | gc / rc |
   |----------------|--------|------------|------------------|---------|
   | flat_tuple     | 12 ms  | 18 ms      | 201 ms           | ×11.2   |
   | nested_tuple   | 40 ms  | 55 ms      | 652 ms           | ×11.9   |
   | record_tuples  | 51 ms  | 44 ms      | **FAIL (trap)**  | —       |
   | enum_tuple     | 27 ms  | 28 ms      | **FAIL (nocompile)** | —   |

   Two findings. (1) **Throughput:** where wasm-gc runs, Perceus-RC is ~11–12×
   *faster* — inline dup/drop + a free-list (no tracing, no GC pauses) beats
   `struct.new` + a tracing collector on allocation-heavy code, and RC adds only
   ~10–40 % over the leak-everything bump baseline. (2) **Maturity:** the `src/`
   wasm-gc backend runs only 2 of the 4 — `record_tuples` compiles but **traps at
   runtime with a GC cast-failure** (the documented struct-field-ordering class,
   CLAUDE.md / `record_field_name_lt`), and `enum_tuple` does not compile (the
   `src/` parser rejects `match` as a `+` operand, which the selfhost parser
   accepts — a parser-parity gap; a let-bound rewrite then hits a gc type error
   `unknown function: Wrap`). So on this workload Perceus-RC is both faster and
   more complete than wasm-gc; wasm-gc remains the option for GC-capable runtimes
   where its codegen gaps don't bite (see CLAUDE.md `VIBE_TEST_BACKEND=gc`).

## Risk & scope

- **Large blast radius** (the whole numeric path) but **contained to `enable_rc`**
  — the bootstrap (default path) is structurally unaffected, so a tagging bug can
  only break opt-in RC programs, caught by the e2e/leak suite.
- **No user-visible payoff until Stage 3+** — Stages 1–2 are pure infrastructure;
  recursive drop (Stage 3) and escape ownership (Stage 4) deliver the actual
  reclamation. This is multi-session work.
- **`src/` is no longer the implementation target**. It remains useful as a
  historical tagged-value reference, but the canonical work happens in the
  selfhost backend, adapted to the 8-byte-slot layout and the `n<<1`/odd-pointer
  scheme chosen here.

## Alternative considered: static pointer bitmap (rejected as primary)

Computing a per-object pointer bitmap at construction (from `heap_binding_names`
+ literal detection) avoids tagging arithmetic, but: (a) needs header space
without shifting payload, (b) only covers statically-known-heap fields
(call-returned heap fields are missed → leak), and critically (c) does **not**
solve Blocker 4 (escaping projections) — that ownership work is required either
way. Tagging is the general, `src/`-aligned mechanism; the bitmap is at best a
partial optimization layered on top later.
