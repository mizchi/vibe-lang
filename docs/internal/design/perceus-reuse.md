# Perceus RC: plan actions, constructor reuse and release (ADR-0092)

Perceus RC is the default linear lane for user programs. This document is the
contract of its **plan** (where references are acquired, released and reused)
and of the codegen rules that realise the plan. Object layouts, drop classes
and the allocator are in [uniform-value-repr.md](uniform-value-repr.md); lane
selection is in [memory-contract.md](memory-contract.md). The remaining open
work is [#2827](https://github.com/mizchi/vibe-lang/issues/2827)
(path-release coverage after reuse), with exclusive-branch emission in #1980
and freeing-site provenance in #1987.

Everything here applies to the linear RC lane only. The bump and Wasm-GC lanes
ignore every plan action that is not a plain dup or drop, so a candidate that
the RC codegen declines degrades to the ordinary drop plus a fresh allocation.

## The plan

`build_perceus_plan_with_params_split` (`perceus/perceus_sf_derive.vibe`)
plans one function body. It runs a counting pass and an emitting pass over the
same tree in the same order, so a lexical binding id names the same binding in
both. The body has already been through `uniquify_shadowed_bindings_fresh`,
which is why the codegen's name-keyed bookkeeping is safe: two `let t` in
sibling branches arrive as `t` and `__shadow_0_t`
(`tests/perceus_path_release_plan_test.vibe` pins that invariant).

`vibe rc-plan file.vibe` prints the plan as `FN BINDING ACTION COUNT` rows,
planned on the same normalized body the RC codegen plans. The actions
(`PerceusActionKind`, `perceus/perceus_pctx.vibe`):

| action | `rc-plan` spelling | meaning |
| --- | --- | --- |
| `PaDup` | `dup` | the binding takes one more reference for an owning use |
| `PaDrop` | `drop` | the binding releases its reference at scope end |
| `PaAliasDup` | `alias_dup` | `let a = t` takes a duplicated reference; keyed by the alias, so the codegen dups exactly at `let a = …` |
| `PaReuseToken` / `PaReuseAlloc` | `reuse_token:<arity>` / `reuse_alloc:<arity>` | a constructor-reuse candidate (below) |
| `PaPathDrop` / `PaConsumeMark` | `path_drop` / `consume_mark:<offset>` | per-path release (below) |
| `PaTruncRelease` / `PaViewPin` | `truncate_release:<n>` / `view_pin:<n>` | `Array::truncate` on a proven-local array releases the removed elements; derived views pin a reference across it (#2837) |
| `PaFieldRelease` | `field_release` | `x.f = v` on a local struct releases the overwritten value (#3140) |
| `PaExitSite` / `PaExitDrop` | `exit_site:<n>:<kind>` / `exit_drop:<n>:<count>` | an early `return` / `break` / `continue` / `throw` releases what the scopes it leaves still hold (#3141) |
| `PaStoreDup` | `store_dup:<offset>` | a store inside a loop of a binding declared outside it takes its own reference (#3184, #3190) |

A **borrow** is a use that takes no reference. The per-parameter borrow mask
(`compute_borrow_param_user_fns`, one bit per parameter position) and the
borrow-returning / view-returning function sets are whole-program facts; the
planner, the call sites and the callee's own drop filter all read the same
mask. `pctx_apply_borrow_retention` adds one owning use to any binding that
also has a borrow occurrence, so a consuming use sequenced before a later read
dups instead of moving.

## Dead-alias elision (#1056)

`let a = t`, where `t` still has later owning uses, would dup `t`'s reference
into `a`, and `a` would get an unconditional scope-end drop. When `a` itself
has no occurrence at all in its body — no owning use and no borrow — that dup
and that drop are a no-op pair on the same block with no read between them.
The emitting pass (the `ELet` alias arm in `perceus/perceus_pc_emit.vibe`)
then emits neither: no `PaAliasDup`, and `a`'s remaining count is zeroed so no
scope-end drop is planned. `t`'s own bookkeeping is unchanged; the occurrence
still spends one of its owning uses, exactly as if the dup had fired.

The test reads the final use count the counting pass computed for `a`'s
binding id, so it is occurrence-local and needs no alias or escape analysis.
It is the narrow, local slice of what almide's `alias_safety.rs` does with a
function-wide fixpoint to elide `MakeUnique` checks. vibe has no static
uniqueness elision beyond this: arrays are mutated in place unconditionally,
and the only run-time uniqueness tests are the reuse and `Map` ones below.
`perceus_rc_test.vibe` pins both directions (the unused alias elides; a used
alias still dups all but the last).

## Drop-guided constructor reuse

A `match` arm that takes a uniquely referenced value apart and builds a
constructor of the same size can rebuild in place instead of releasing the
block and allocating a new one.

### Planner candidates

`plan_reuse_pairs` (`perceus/perceus_expr_projects_or_matches.vibe`) emits a
`PaReuseToken` / `PaReuseAlloc` pair, with the arity in `extra`, for a
`match <ident>` whose scrutinee has a planned drop and whose arm:

1. decomposes with a `PCtor` pattern whose arguments are all `PBind` / `PWild`,
   none of them alias-bound;
2. never mentions the scrutinee again;
3. contains no direct `return` / `break` / `continue` / `perform` / `throw`
   that could skip the arm end (`reuse_arm_has_blocker`; a lambda interior is
   exempt);
4. contains, outside lambda interiors, a call of a constructor-like name with
   the same arity (`reuse_ctor_like`: the last `::` segment is capitalised).

The planner has no constructor table, so a pair is a candidate, not a promise.
The plan row is keyed by `(scrutinee, arity)`, which cannot tell sibling arms
apart, so both codegen tiers re-run `reuse_arm_has_blocker` and
`reuse_bind_mode` on the exact arm they are about to fuse. A call whose callee
unwinds internally is not a blocker: every call can throw on this lane, and an
unwind between the claim and the arm end leaks the block without corrupting
it.

### Codegen

`compile_match.vibe` has two tiers that share one staging prelude: bind the
payload fields as raw loads, then test the scrutinee's rc word against exactly
`1 | (1 << 24)` (count 1, class 1; a saturated word fails the test).

- **Unique**: the block is kept as a reuse token and the payload binds own its
  children.
- **Shared**: each bind takes the references its accounting needs (below), the
  scrutinee's reference is released (it cannot reach zero here), and the
  token is zero.

The **narrow** tier (`mr_reuse_eligible`, `mr_compile_reuse_arm`) takes an arm
whose spine tail is the same-size constructor and whose binds are all raw
transfers. The **wide** tier (`mr_reuse_wide_eligible`,
`mr_compile_reuse_arm_wide`) takes the rest of the candidates: it arms the
token on the context and compiles the arm body through the ordinary
expression code. The constructor path (`compile_call_named_1.vibe`) takes the
innermost armed token of its field count at the first same-size site that
runs — a spine tail, a branch of an `if` / `match`, a site after a statement
prefix, an interior intermediate — and falls through to the ordinary fresh
allocation when the token is zero. A path on which no site ran reaches the arm
end with the token still armed, and `mr_emit_token_release` zeroes the
block's field count (its children already moved to the binds) and releases
the empty shell. The narrow tier keeps precedence.

The codegen also re-validates against the constructor table: neither the
source nor the target constructor may have a boxed-float field, because the
raw payload binds bypass the float-slot registration of an ordinary pattern
bind.

### Per-bind accounting

`reuse_bind_mode` classifies each bind:

- **raw transfer** (mode 1): consumed exactly once, and that consume is its
  only occurrence. It owns the child on the unique path and one dup on the
  shared path; its single consume releases it. This is what lets uniqueness
  cascade through a recursive rebuild.
- **borrow-only** (mode 0): never consumed. The child is released at arm end.
- **held** (mode -1): consumed once with further reads, or consumed twice or
  more. With `k` consumes it holds `k` references plus one base reference
  released at arm end, so a read sequenced after a consume never sees a freed
  child.

The narrow tier admits raw transfers only; the wide tier admits all three. A
scalar payload needs no special case: a tagged scalar moves like a pointer and
the shared-path dup of an even value is a no-op.

### What declines

An alias-bound bind, a boxed-float field, a nested sub-pattern, a direct
control transfer, and an arm with no same-size constructor site. A function
whose parameter is borrow-classified never fuses on that parameter, because a
borrowed parameter carries no plan drop and the scrutinee gate never opens on
a block the caller owns. `scripts/reuse_census.sh` classifies every
constructor arm of a flat source by this admission rule.

### Where it pays

Reuse needs a uniquely referenced input. A tree rebuilt by a recursive `match`
over values nobody else holds (`bench/exec/tree_rebuild.vibe`) rebuilds with
no allocation. A tree read out of a container the container still owns is
shared, so the uniqueness test fails, the shared path dups the children, and
the cascade below allocates fresh. The compiler's own passes mostly have that
second shape (`Array::get` on statement arrays they mutate in place), so reuse
reduces allocation traffic in user code of the first shape far more than it
reduces the compiler's self-compile time; the RC lane's cost there is retain
traffic.

## Per-path release (#2389)

A binding consumed on some branches of an `if` / `match` and not on others
keeps the merge's minimum remaining count (#705), which is what stops the
consuming path from double-freeing. On its own that plans the scope-end drop
away entirely, so the paths that did not consume the binding would release
nothing.

The planner records each occurrence that spends the binding's initial
reference as `PaConsumeMark` (keyed by its source offset) and emits one
`PaPathDrop` for the binding. The `let` lowering gives the drop back guarded by
a flag local that the marked occurrences set: flag set, the reference moved
out on this path; flag clear, this path still holds it. Both places that can
spend the initial reference — `pe_use` and the `ELet` alias arm — call
`pe_note_initial_ref_spent`, so neither can go unmarked.

The codegen admits a `PaPathDrop` only when the drop it gives back is certain
to be owed (`path_value_owned`, `compile_expr_tail_classify_let_value_heap.vibe`):

- the binding is a plain immutable `let` (not `let mut`, not a pattern bind or
  parameter);
- every leaf of the value's result spine (through `let` / `;` chains and
  conditional branches) is an allocation made at the site, or a call to a
  named, non-local function whose declared return type is heap and which
  neither returns a borrow nor may return a view. This is an allow-list:
  indirect calls, aliases, projections, literals, arithmetic, lambdas, loops
  and `handle` decline;
- every marked occurrence has a source offset (a lambda capture has none);
- the binding is not borrow-bound and not `Int`-valued.

`scripts/path_release_census.sh` classifies every `PaPathDrop` row of a flat
source by this rule.

## Ownership contracts of builtin lowerings

### Array higher-order builtins (#2671)

`Array::map`, `filter`, `fold`, `iter_eager`, `any`, `all`, `find`, `reverse`
and `concat` consume their array argument and hand each element to a callback
that owns its parameter. On the RC lane each lowering (`cc_hof_*`,
`compile_call*.vibe`) tests the array's rc word once:

- **unique**: elements are moved out with no retain, a rejected element is
  released by the lowering, and the shell is freed with its length zeroed;
- **shared**: each element is retained before it is handed over, and the array
  is released normally at the end.

The predicates (`any` / `all` / `find`) never move an element. `concat`
retains what it copies and releases both inputs. The callback reference is
released after the loop. A lowering owns an argument only where the planner
planned an owning position: when a program shadows an intrinsic with a source
definition that the planner reads as borrowing, `cc_hof_retain_arg` retains
the argument (`md_borrow_mask_of`), so the caller keeps its reference.

### Owned temporaries in borrowed positions (#2682)

A fresh value passed straight to a position that takes no ownership
(`Array::length(build_arr(3))`) has no binding to drop it. The resolved-call
path parks such a temporary (`cc_is_owned_temp`: a call to a callee that
returns no view, or an array / tuple / record / map literal) and releases it
after the call, unless the callee may return a view of that argument, in which
case the leak is the safe side.

### Unannotated lambda parameters (#2681)

Call-site heap inference fills unannotated parameters of local lambdas
(`fill_lambda_params`) and top-level lambdas (`fill_top_lambda_params`), and a
parameter the body consumes at an owning position is heap regardless of what
the calls pass (`md_consume_count`). The inferred parameter type is the
nominal `__rc_heap`: a name no type table knows, which `type_expr_is_heap`
recognises and the trait desugaring skips.

### `Map` and `MapBuilder` (#2683)

Both are RC blocks on this lane (classes 6 and 9). Keys and values copied from
one map into another are retained in both; a borrowed view stored into a map
literal is retained as the other literals do; a map's side-index slot is zeroed
at allocation.

`Map::set` and `Map::delete` **consume** their map (they are not in
`md_is_borrow_arg0_call`). The lowering tests the source's rc word against
`1 | (6 << 24)`: a unique map is updated in place (growing by moving entries
into a block of twice the capacity, maintaining or rebuilding the side index)
and becomes the result; a shared one is copied and the consumed reference is
released. `MapBuilder::freeze` moves the entries out of a uniquely held
builder and copies with retains otherwise. `Map::get` / `MapBuilder::get`
return views.

An accumulator `x = f(.., x, ..)` in which `x` appears at exactly one owning
position and nowhere else on the right-hand side **moves** that occurrence
(`pe_self_reassign_moves`, `md_self_reassign_move_arg`): the old value is
consumed and the binding takes the result. The move is withheld for a scalar,
for a binding that is itself a view, and while another binding still views it
(`view_src`).

## Captured `let mut` cells

On the RC lane every closure-captured `let mut` is a headered class-8 cell
(`compile_expr_tail_expr_tail.vibe`); `mut_needs_ref_cell` decides capture,
and the same decision puts the name in `ref_cell_names`, which the closure
code reads to treat the capture as RC-owned. Those must never be two
predicates: a capture treated as RC-owned while its box had no header once
incremented whatever preceded the box and pushed a headerless pointer onto the
free list. The cell owns one reference to its payload: every store is an owned
store that releases the value it replaces, and a read leaving for an owning
place is retained (#3113). The capturing closure dups the cell, and the
class-7 drop releases it. Section 88 of the compiler gate pins the header by
splicing an `alloc_size == 0` trap into `__rt_rc_drop`.

## The dup helper

Every dup site emits `local.get v; i64.const 1; i64.and` inline and calls the
out-of-line `__rt_rc_dup` only for an odd value (`emit_rc_dup_guarded`,
`emit_rc_dup_tagtest_call`). The helper's body is the inline emitter itself,
so the two forms cannot disagree. Both arms of `emit_rc_dup_guarded` use the
output buffer exactly once: the planner merges an `if`'s arms by their minimum
use count (#705), and an asymmetric pair was an over-release in the RC-built
compiler.

Full inlining of the guard was measured to cost several times the code size
for a wall gain the binary-size ratchet does not allow; inlining the drop fast
path (#1274) was reverted for the same reason. Choosing inline or out-of-line
per site is not implemented.

## Not part of this design

- **TRMC** and **copy-on-write / `MakeUnique` guards** for arrays.
- **Cycle collection**: plain RC never reclaims a cycle.
- **`#zero_alloc` credit for reuse**: the allocation check runs on statements
  before Perceus, and a reuse candidate is conditional on a run-time test, so
  it is not evidence that an allocation disappears (ADR-0091,
  [zero-alloc-check.md](zero-alloc-check.md)).
- **A source annotation** (`fip` / `fbip`).

## Debugging an RC accounting bug

An over-release corrupts the free list silently and traps much later in an
unrelated place, at a location that moves with the binary layout.

- Run the program under `VIBE_RC=shadow` (ADR-0062). The first dup or drop of
  a freed block traps at the faulting operation and names the freeing site.
- Instrument the built binary, not the source. Changing the compiler source
  changes the compiler's own allocations and can make a layout-sensitive crash
  disappear. `scripts/rc_patch_freelist_assert.py` splices free-list and
  watchpoint assertions into `__rt_rc_alloc` / `__rt_rc_drop`, and
  `scripts/rc_add_freelist_export.py` exports the free-list head; both edit the
  code and export sections only, so the heap layout is unchanged.
- Confirm that an assertion stays silent on a healthy build before treating
  its firing as evidence.
- A stage1 compiler's own runtime helpers were emitted by the seed, so a
  runtime-helper change in the source does not reach the stage1 binary.
- Codegen size changes are gated by `scripts/size_ratchet.sh`, which CI runs
  and `pkf run release-check` does not.

## Checks

- `lib/@vibe/compiler/tests/perceus_rc_test.vibe`,
  `perceus_reuse_plan_test.vibe` and `perceus_path_release_plan_test.vibe` pin
  plan rows.
- `perceus_reuse_e2e_test.vibe`, `hof_rc_ownership_test.vibe`,
  `lambda_param_consume_rc_test.vibe`, `borrowed_temp_release_rc_test.vibe`,
  `map_builder_rc_test.vibe` and `map_reuse_rc_test.vibe` (all under
  `lib/@vibe/compiler/tests/`) compare bump, RC and RC-shadow answers.
- [`rc_reclaim_leak_test.vibe`](../../../fixtures/rc_reclaim_leak_test.vibe)
  bounds the heap of loops over every shape above (`widen0`, `hold`,
  `only_then`, `move_through_wrapper`, the HOF and map shapes), and
  [`rc_shadow_regression_test.vibe`](../../../fixtures/rc_shadow_regression_test.vibe)
  runs the bug-shape corpus under shadow.
