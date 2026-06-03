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
- Introduce the `src/`-compatible header `[type_id@0][length@4][payload@8...]`
  for tuple / array / record / enum / closure allocations in the selfhost
  linear backend (`codegen/expr/compile_expr_tail2.vibe`, `compile_lambda.vibe`,
  `compile_expr.vibe` ctor path, etc.).
- Shift every field read/write by the header size; keep string/bytes fat
  pointers as today (leaf objects).
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

### Phase 3 — port the RC codegen

- Port `src/codegen/wasm_codegen_rc.mbt`: refcount header (`[rc@-4]` in front of
  the Phase 1 header), `rc_dup` / `rc_drop` helpers (with the corrected
  `block`-before-condition ordering found in B-1), recursive field drop keyed
  by `type_id`, head-only free-list, and per-statement action injection in the
  selfhost statement/expression compilers.
- Gate behind a selfhost `enable_rc` flag, default off.

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
