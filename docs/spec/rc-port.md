# Perceus RC — design record

Status: **the port is done and RC is the linear default** (`VIBE_RC` unset ==
`VIBE_RC=1`, byte-identical; pinned by `scripts/check_rc_default.sh`). Current
status and residual leaks live in
[rc-cutover-readiness.md](rc-cutover-readiness.md); the backend contract table
is in [memory-contract.md](memory-contract.md).

This file is kept for the **design**: why the port was not a straight code
port, the layout change it required, and the rc-check elision analysis
(Phase 3.5), which is what other documents still cite. The staged plan below
records the shape of the work, not a queue of remaining work — where a phase
heading says WIP or "first vertical", read it as the state at the time that
phase was written, not as today's.

The MoonBit `src/` backend referenced throughout was retired in #594; it is
historical context for the layout discussion, not a live fallback.

## Why this is not a straight code port

The `src/` linear backend and the compiler's linear backend use **different
heap object layouts**, and RC's correctness depends on the `src/` layout.

### `src/` linear layout (RC-ready)

Every heap object carries a header, and RC prepends a refcount:

```
[alloc_size@-8][rc_count@-4][type_id@0][length@4][payload@8...]
```

`type_id` (tuple=3, array=5, record=4, map=6, enum=10, closure=7, view=11/12/14,
string=1, bytes=13) lets the RC drop helper dispatch and **recursively drop the
right fields**; `length` bounds the field loop. This is what
`emit_rc_drop_fields` / `compile_rc_drop_function` rely on.

### Compiler linear layout (no headers)

The compiler's linear backend is a pure bump allocator with **no type-id / length
headers**:

- tuple: bare sequential `i64` slots (no header)
- closure (`obj_fn`-equivalent): `[table_slot@0][num_captures@4][captures@8...]`
- constructor: `[tag@0][pad@4][values...]`
- string: `(offset << 32) | length` fat pointer (no heap header)
- objects are tagged only by OR-ing the low bit; there is **no way at runtime
  to tell a tuple from a record from an enum**, nor how many fields it has.

Without a type-id + length header there is no way for a generic `drop` to know
how to recurse, so the RC drop helper cannot be ported as-is.

## Consequence: the prerequisite is a layout change

The first real domino is **adding a uniform object header to every compiler
linear allocation** and updating every field-access offset accordingly. This
is large and touches every allocation/access site, so it must land behind a
flag and be proven output-equivalent by the parity gates before any RC code
is added.

## Staged plan

### Phase 1 — uniform object header (prerequisite, no RC yet) — *started*

- **Verification harness in place** (the safety net for the layout change): the
  compiler's codegen unit tests only check wasm magic bytes (`assert_wasm`), which
  is too weak to catch a layout regression. `lib/@vibe/compiler/tests/codegen_heap_e2e_test.vibe`
  (9/9) compiles heap-object source programs with
  the compiler's linear backend, runs them on wasmtime (`sh_lines("wasmtime run --invoke
  main …")`), and checks the *result* — covering tuple, nested tuple, array get,
  array builder, struct field, enum ctor + match payload, closure capture,
  returned closure, and a tuple-allocating loop. The header rewrite must keep
  these green.
- **Memory-leak profiling in place**: the compiler's linear backend exports its
  bump-allocator cursor as the `__heap_ptr` global. `scripts/measure_heap.mjs`
  reads it before/after invoking a function (on a minimal wasm host) to report
  bytes allocated; running it against the same allocating loop at two iteration
  counts and diffing gives the per-iteration heap growth.
  Baseline (bump, no reclamation): **16 bytes/iteration** for a `(i, i+1)`
  tuple loop — i.e. it leaks linearly. The header change (Phase 1) only grows
  this by the header size (still leaking, as expected with no RC); once Perceus
  RC + a free-list land (Phase 3) this per-iteration figure must drop to ~0,
  which is the concrete leak-fixed acceptance criterion.
- Gating in place: `CompileCtx.enable_rc` (threaded as a parameter on the WASI
  path) + `compile_wasi_module_rc` / `compile_wasi_rc` entries. Default off, so
  the existing path is unchanged.
- **Records/structs already carry a `[type_id@0][length@4][payload@8...]`
  header; only tuples were headerless.** Tuples now take the same header under
  `enable_rc` (type_id 3 = tuple): construction (`compile_expr_tail2.vibe`),
  field access (`compile_expr_tail4.vibe` EDot), and the `compile_match.vibe`
  PTuple element loads all shift the payload by 8. Verified result-preserving
  (heap e2e 15/15 on both paths, incl. a discriminating tuple-inequality case)
  and the leak profiler shows the RC-mode tuple loop at **24 B/iteration**
  (16 element + 8 header) vs 16 default — bigger but still leaking, as expected
  with no RC drop yet.
- Remaining for arrays / enums / closures: the same header treatment. Keep
  string/bytes fat pointers as today (leaf objects).
- No refcount field yet, no behavior change: the parity gates
  (e.g. `scripts/rc_corpus_parity.sh`) must show identical compiled output /
  runtime results. This phase is purely structural.
- Risk: high (every offset moves). Mitigation: land incrementally per object
  kind, each guarded by the parity gate.

### Phase 2 — port the Perceus analysis pass — *complete (bar branch balancing)*

- Ported the analysis to `lib/@vibe/compiler/perceus/perceus.vibe`
  (`build_perceus_plan : (Expr) -> Array[PerceusAction]`), pattern-matching the
  compiler's `Expr` enum directly. Because the compiler's AST is
  expression-oriented, scope is structural: an `ELet(x, val, body)` scopes `x`
  to `body`, so per-iteration / per-branch bindings fall out of the tree shape
  (no statement-index bookkeeping). Two passes (`pc_count` then `pc_emit`)
  share binding ids assigned in tree order.
- Mirrors the validated `src/` semantics: call callee and field access
  (`EDot`, array `__index` arg0) are borrows; pure-borrow / unused non-scalar
  bindings get a scope-end drop; multiply-used owning references dup.
- `EFn` captures are accounted (free vars via `collect_free_vars` are owning
  uses of the outer binding; the body is analysed separately as its own
  function). `EForIn` binds its element per iteration (structural scope-end
  drop). `EMatch` does branch-max counting across arms and drops arm-local
  pattern bindings per arm. `ELoop` treats its parameters as body-scoped
  bindings. `ESeq` binds the discarded left value to a synthetic name so an
  owned heap temporary is reclaimed at scope end (A-1b).
- A binding with no owning uses (pure-borrow *or* entirely unused) keeps its
  one owned reference and is dropped at scope end; the scalar check skips
  known non-heap values.
- Unit-tested in isolation via the native vibe CLI
  (`lib/@vibe/compiler/tests/perceus_rc_test.vibe`, 14/14):
  pure-borrow drop, moved-out (no drop), scalar (no drop), dup on double use,
  closure-call borrow + drop, nested borrow, branch-local drop, while-body
  per-iteration drop, for-in element drop, closure capture as owning use,
  match arm pattern-binding drop, discarded sequenced heap value drop (A-1b),
  discarded scalar (no drop), loop-parameter drop, handle arm pattern-binding
  drop.
- `EHandle` is covered: the handled body is branch 0 and each handler arm is a
  further branch (branch-max counting + arm-local pattern bindings) — a
  conservative, safe approximation of effect control flow.
- **Remaining in Phase 2**: only cross-branch *balancing* of outer bindings
  consumed unevenly across `EIf` / `EMatch` / `EHandle` arms. Each balancing
  drop must be placed in a specific branch, which requires the action to carry
  placement (a site) — deferred to Phase 3, where the codegen wiring assigns
  sites (as the `src/` backend already does). Until then this is a safe no-op
  (never a wrong drop; at worst an outer binding consumed in only one arm is
  reclaimed slightly late or left to its enclosing scope's drop).

### Phase 3 — port the RC codegen — *first vertical landed (tuples)*

- **The tuple loop leak is fixed**: with `enable_rc`, a `let t = (i, i+1)` loop
  body drops `t` each iteration and the freed block is reused, so the heap is
  bounded. The leak profiler reports **0 bytes/iteration** (constant 32 B total
  for 1k and 11k iterations) vs 24 B/iteration without drops — and results are
  unchanged (heap e2e 15/15 on both paths).
- How it works: `rc_count` lives at `ptr-4`, `alloc_size` at `ptr-8` (Phase 1
  layout); allocation reuses an exact-fit free-list block (global 2 head);
  `compile_expr`'s `ELet` emits a non-recursive `rc_drop` (decrement; at zero,
  push the block onto the free list, reusing the rc slot as the next pointer)
  for a tuple binding whose name the per-function `build_perceus_plan`
  (the Phase 2 analysis, now imported by `linked_compile.vibe`) marks for a
  scope-end drop. Non-recursive drop needs no runtime `type_id` dispatch, so it
  sidesteps the type_id-uniformity work for enums/closures.
- Closures are covered: `compile_lambda` runs `build_perceus_plan` on the
  lambda body and gives the lambda ctx its own drop set, so a tuple allocated
  per iteration inside a callback / returned closure is reclaimed too
  (measured 0 bytes/iteration).
- **Records are covered**: under `enable_rc`, `ERecord` takes the same free-list
  RC layout as tuples (`compile_expr_tail4.vibe`), and the `ELet` drop
  (`compile_expr_tail.vibe`, now sharing the `emit_rc_drop_local` helper)
  fires for a record binding too. Records stay **tagged** (`(block_start+8) | 1`),
  so the drop untags before touching the rc header; field access is unchanged
  because the +8 pointer shift cancels the +8 header offset. A `let p = P::{…}`
  loop body is reclaimed (measured 0 bytes/iteration, constant 32 B for 1k and
  11k iterations); results unchanged (heap e2e 19/19 on both paths, incl. nested
  struct field access).
- **Enums (constructors) are covered**: `A(x)` takes the same tagged free-list
  RC layout (`compile_call.vibe`, `[tag@8][field_count@12][values@16…]`), and a
  ctor binding is dropped via `is_ctor_call`. The match tag / field reads are
  offset-invariant (the +8 pointer shift cancels the +8 header), so only
  construction + drop changed. **Analysis change**: a bare-identifier *match
  scrutinee* is now a **borrow** (like `EDot` / `__index` arg0) in
  `build_perceus_plan` — matching reads the tag/fields but frees nothing, so the
  binding keeps its owned reference and is reclaimed by its own scope-end drop.
  Without this an enum/record/tuple bound then matched in a loop leaked (it was
  "moved into" the match). A `let e = A(i); match e {…}` loop is now reclaimed
  (measured 0 bytes/iteration, constant 24 B); results unchanged (heap e2e 20/20
  on both paths, incl. an enum alloc+match loop).
- **`rc_dup` for aliased bindings is covered** (the shared-binding case): an
  alias `let a = t` where the source `t` is used in more than one owning
  position takes a *duplicated* reference. The Perceus emit pass attributes the
  dup to the **alias** binding (`PaAliasDup`, keyed by `a` not `t`), which is
  occurrence-precise without tree-order bookkeeping — the codegen dups the
  source exactly at `let a = …`. The non-last alias dups; the last takes the
  original; both aliases are dropped, the source is not, so the refcount reaches
  0 exactly once. The codegen tracks a per-function `heap_binding_names` set
  (bindings bound to a tuple/record/enum literal or an alias of one) so dup/drop
  never touch a non-heap binding the static `scalar` flag over-approximates;
  untag is uniform `& -2` (a no-op on 8-aligned tuple pointers, so it is correct
  for an alias of any heap kind). A `let a = t; let b = t` loop is now reclaimed
  (measured 0 bytes/iteration, constant 32 B); a returned alias is correctly
  *not* dropped (escape-safe); results unchanged (heap e2e 22/22 on both paths).
- **Array literals are covered**: under `enable_rc`, `EArray` is inline-allocated
  (`compile_expr_tail2.vibe`) with the tuple-style RC layout — value = `block+8`,
  header behind, the array object (`[capacity@0][length@4][data_ptr@8]
  [inline_data@12…]`) sized to hold the literal inline, `data_ptr = value+12`.
  Because the value pointer shifts with the object, the array runtime
  (`Array::get` / `length` / `push`, which read `value+0/+4/+8`) is unchanged.
  An array binding drops like a tuple (untagged). **Analysis change**: the
  array-arg of `Array::get` / `length` / `set` / `push` is now a *borrow* (like
  `__index`), so an array bound then only read/mutated-in-place is reclaimed by
  its own scope-end drop. A `let a = [i, …]` loop is now reclaimed (measured 0
  bytes/iteration, constant 84 B). Growth (`Array::push` past capacity) now
  allocates the larger data buffer as a HEADERED, free-list-backed block via
  `__rc_alloc` and frees the old buffer on regrow; `array_new` allocates via
  `__rc_alloc` too (not a raw bump); and the recursive `rc_drop` frees a grown
  (separate) data buffer when it drops an array (an inline buffer at `value+12`
  is still freed with the block). A build-and-discard loop that previously leaked
  ~one array block + its grown buffers per iteration now reclaims to 0 B/iter
  (Stage 4: array buffer reclamation). `ArrayBuilder::{new,push,freeze}` are
  aliases of `array_new` / `Array::push` / `identity`, so they ride the same
  reclamation: `ArrayBuilder::push` is now a borrow-arg0 call (the builder stays
  live, mutated in place) so the builder is reclaimed by its own scope-end drop,
  and `freeze` (identity) transfers ownership of the built array to its result
  (reclaimed at scope end, or by the caller when returned). An ArrayBuilder
  build-and-discard loop now reclaims to 0 B/iter (was ~one array block + grown
  buffers per iteration), and a frozen result that escapes survives correctly.
- **MapBuilder** (`MapBuilder::{new,set,freeze}` + `Map::{get,keys,has_key,set}`)
  is also reclaimed (Stage 4): `MapBuilder::new` allocates a headered, free-list-
  backed block via `__rc_alloc`, tagged as an odd pointer with drop-class 6 (map:
  `count@value+0`, then `count` entries of `key@+8`/`val@+16` on a 16-byte
  stride). The recursive `rc_drop` handles class 6 by dropping each key and val
  before freeing the block, so a build-and-discard loop reclaims to 0 B/iter even
  with heap-valued entries. `MapBuilder::set` / `Map::{get,keys,has_key,set}`
  borrow arg0 (the map stays live), `Map::get` returns a borrowed entry (like
  `Array::get`), and map readers untag (`& -2`, a no-op on the still-even
  `map { … }` literal pointer) before dereferencing. Map **literals** and
  `Map::set` **results** remain on the even/leaky path (and the compiler's map-
  literal string-key read has a pre-existing correctness bug, orthogonal to RC).
- Known limitations of this first vertical (all leak conservatively — they
  never corrupt — and only matter under `enable_rc`):
  - **Mixed tuple sizes**: the free list is head-only exact-fit (as in `src/`),
    so after a size-3 tuple is freed, later size-2 allocations bump rather than
    reuse the stuck size-2 block until the head matches. Same-size loops (the
    common case) are fully reused.
  - **Non-alias owning escapes** (a binding stored into a container or passed
    to a call without a balancing recursive drop) still leak conservatively:
    only alias (`let a = t`) owning uses are dup'd; container/call escapes are
    left to the future recursive-drop work.
  - **Name shadowing**: `heap_binding_names` is a flat per-function set, so a
    scalar binding that shadows a same-named heap binding in a sibling scope
    could in principle be mis-classified for an alias source. Pathological and
    not hit by the compiler's own sources; the immediate-value classification of the
    binding being dropped is precise, only the alias *source* lookup consults
    the set.
- Remaining: recursive field drop — blocked on the compiler's runtime representing
  **integers as raw `i64`** (no tag) and the **AST carrying no element types**,
  so neither `src/`-style runtime pointer-dispatch nor a static pointer-bitmap is
  available; and even a fresh-literal-only subset is unsafe because an extracted
  field (`t.0`) can escape while the container is dropped. It needs a foundational
  step first — a **uniform value representation** (integer/float tagging enabling
  `src/`-style runtime dispatch) plus escape-ownership analysis. Designed in
  [uniform-value-repr.md](uniform-value-repr.md) (ADR-0055).
  Also remaining: a segregated / coalescing free list. (Grown array data buffers
  and `ArrayBuilder`-built arrays are now reclaimed — Stage 4 array buffer
  reclamation.)
- Everything stays gated behind `enable_rc`, default off.

### Phase 3.5 — rc-check elision (almide comparison, #1056) — *narrow slice landed*

- `build_perceus_plan`'s `ELet` alias handling (`lib/@vibe/compiler/perceus/perceus.vibe`)
  now elides the dup+drop pair for an alias binding (`let a = t`) that would
  otherwise duplicate `t`'s reference but is never itself referenced in its
  body: the dup and the alias's own unconditional scope-end drop are a
  provable no-op on the same memory with no intervening read. Occurrence-local
  (uses the per-binding-id `uses`/`remaining` bookkeeping the analysis already
  computes), so it needs no whole-function alias/escape analysis and carries
  no new shadowing risk beyond what the existing name-keyed
  `rc_alias_dup_names`/`rc_drop_names` codegen sets already have. Tested in
  isolation (`perceus_rc_test.vibe`) and verified zero-regression: stage2==stage3
  self-host fixpoint, `scripts/verify_rc.sh` byte-identical whole-compiler-under-RC
  reproduction, and all `fixtures/rc_*_test.vibe` / shadow-liveness / reclaim-leak
  gates unaffected.
- This is the narrow, occurrence-local slice of what almide's
  `alias_safety.rs` does with a full function-local fixpoint dataflow (eliding
  redundant `MakeUnique`/COW rc-checks on provably-unaliased values) — see
  `docs/pl-survey-2026-07.md` and `docs/BENCHMARKS.md`. vibe's RC has no
  COW/`MakeUnique`-equivalent construct yet (arrays/maps are mutated in place
  unconditionally, never copy-on-write-guarded), so a literal port of the rest
  of almide's pass has no target to elide; this slice covers the one case
  vibe's existing per-binding-id bookkeeping already has the data to prove
  safe without new infrastructure.
- Measured impact on `bench/binary_size/`'s 5-program suite and on the
  compiler's own self-hosted source under RC: **none today** — neither
  contains the target pattern (see `docs/BENCHMARKS.md`). Kept as a
  zero-cost-when-unused safety net; broader rc-check elision (a real
  alias/escape fixpoint, or COW guards once arrays/maps grow them) remains
  future work.

### Phase 4 — verification & cutover

- Add a wasmtime e2e gate for the compiler's RC backend, mirroring
  `src/tests/vibe_wasm_rc_e2e_test.mbt` (the `test-wasm-rc-e2e` task).
- Run the compiler's parity / cutover gates with RC on.
- Only then consider making RC the compiler's linear default, in lockstep with
  the `src/` default decision (issue #493 C/F).

## Sequencing note

Phases 2 and 3 can reuse the now-validated `src/` design directly (including
the B-1 wasm-validity fix and the A-1/A-1b/A-2 analysis fixes). Phase 1 is the
unavoidable, compiler-specific prerequisite and is where most of the risk and
effort sits. Until Phase 1 lands, the analysis pass (Phase 2) is the only part
that can be built and tested without destabilizing the compiler's backend.
