# Selfhost Perceus RC port — design & staged plan

Status: planning (issue #493 direction C / item **D**). Tracks porting the
Perceus reference-counting memory management from the authoritative MoonBit
`src/` implementation into the vibe-written selfhost compiler
(`vibe/compiler/`). `src/` stays authoritative; selfhost follows via the
parity gates (per CLAUDE.md).

## Why this is not a straight code port

The `src/` linear backend and the selfhost linear backend use **different
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

### selfhost linear layout (no headers)

The selfhost backend is a pure bump allocator with **no type-id / length
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

The first real domino is **adding a uniform object header to every selfhost
linear allocation** and updating every field-access offset accordingly. This
is large and touches every allocation/access site, so it must land behind a
flag and be proven output-equivalent by the parity gates before any RC code
is added.

## Staged plan

### Phase 1 — uniform object header (prerequisite, no RC yet) — *started*

- **Verification harness in place** (the safety net for the layout change): the
  selfhost codegen unit tests only check wasm magic bytes (`assert_wasm`), which
  is too weak to catch a layout regression. `vibe/compiler/codegen_heap_e2e_test.vibe`
  (task `test-selfhost-heap-e2e`, 9/9) compiles heap-object source programs with
  the selfhost backend, runs them on wasmtime (`sh_lines("wasmtime run --invoke
  main …")`), and checks the *result* — covering tuple, nested tuple, array get,
  array builder, struct field, enum ctor + match payload, closure capture,
  returned closure, and a tuple-allocating loop. The header rewrite must keep
  these green.
- **Memory-leak profiling in place**: the selfhost backend exports its
  bump-allocator cursor as the `__heap_ptr` global. `scripts/measure_selfhost_heap.mjs`
  reads it before/after invoking a function (on a minimal wasm host) to report
  bytes allocated; `scripts/measure_selfhost_heap_leak.sh` compiles the same
  allocating loop at two iteration counts and reports per-iteration heap growth.
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
  (`scripts/test_selfhost_*`) must show identical compiled output / runtime
  results. This phase is purely structural.
- Risk: high (every offset moves). Mitigation: land incrementally per object
  kind, each guarded by the parity gate.

### Phase 2 — port the Perceus analysis pass — *complete (bar branch balancing)*

- Ported the analysis to `vibe/compiler/perceus/index.vibe`
  (`build_perceus_plan : (Expr) -> Array[PerceusAction]`), pattern-matching the
  selfhost `Expr` enum directly. Because the selfhost AST is
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
  (`vibe/compiler/perceus_rc_test.vibe`, task `test-selfhost-perceus`, 14/14):
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
- Known limitations of this first vertical (all leak conservatively — they
  never corrupt — and only matter under `enable_rc`):
  - **Closures**: lambda bodies are analysed with an empty drop set, so a tuple
    allocated per iteration inside a callback / returned closure is not yet
    reclaimed (each lambda needs its own `build_perceus_plan`).
  - **Mixed tuple sizes**: the free list is head-only exact-fit (as in `src/`),
    so after a size-3 tuple is freed, later size-2 allocations bump rather than
    reuse the stuck size-2 block until the head matches. Same-size loops (the
    common case) are fully reused.
- Remaining: `rc_dup` for shared (multiply-used) bindings; recursive field drop
  (needs the uniform `type_id` so a dropped tuple frees nested heap); the same
  treatment for record / array / enum / closure bindings; per-lambda drop
  plans; and a segregated / coalescing free list.
- Everything stays gated behind `enable_rc`, default off.

### Phase 4 — verification & cutover

- Add a wasmtime e2e gate for the selfhost RC backend, mirroring
  `src/tests/vibe_wasm_rc_e2e_test.mbt` (the `test-wasm-rc-e2e` task).
- Run the selfhost parity / cutover gates with RC on.
- Only then consider making RC the selfhost linear default, in lockstep with
  the `src/` default decision (issue #493 C/F).

## Sequencing note

Phases 2 and 3 can reuse the now-validated `src/` design directly (including
the B-1 wasm-validity fix and the A-1/A-1b/A-2 analysis fixes). Phase 1 is the
unavoidable, selfhost-specific prerequisite and is where most of the risk and
effort sits. Until Phase 1 lands, the analysis pass (Phase 2) is the only part
that can be built and tested without destabilizing the selfhost backend.
