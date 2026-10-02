# Controlling mutable state: Scala capture checking, Flix regions, OxCaml `[@zero_alloc]`

Research note. Not normative: what vibe decided is in the ADRs linked below.
The question was which of three external designs for controlling mutable
references and allocation fit vibe's model — Perceus RC, `let mut` as a
closure-shareable cell, effect rows that carry authority — and what each would
cost.

## The three designs

1. **Scala 3 capture checking** (experimental). Types carry a capture set
   (`T^{c1, c2}`), and the checker tracks how capabilities are reached, aliased
   and escape. The separation-checking extension adds read-only versus
   exclusive access (`cap.rd`), `consume` (a move) and hiding. The aim is to
   bring part of Rust's discipline into a garbage-collected language.
2. **Flix regions.** `region rc { ... }` makes every piece of mutable memory
   belong to a lexical region. Mutable collections are parameterised by it
   (`MutList[t, r]`), a function that touches region memory carries `\ r` in
   its effect row, and the type system forbids escape.
3. **OxCaml `[@zero_alloc]`.** Annotating a function makes the compiler verify
   that its whole call tree performs no heap allocation, and list every
   violation with its location. It comes with `local_` / `stack_` (stack
   allocation with escape inference), an `assume` escape hatch, and
   `[@@noalloc]` for foreign calls. The point is to invert the
   profile-fix-regress cycle: the compiler refuses the regression.

## What vibe took from each

| design | outcome in vibe | where |
| --- | --- | --- |
| Flix regions | Adopted for collection storage: `region r { ... }`, `MutList[T, r]`, `MutBytes[r]`, copy-out exits, escape checks, an arena on linear bump and Wasm-GC. Region variables in public effect rows (`with r`) are not implemented. Ordinary `let mut` is unchanged | ADR-0090, [region-mutable-state.md](../../internal/design/region-mutable-state.md) |
| OxCaml `[@zero_alloc]` | Adopted as a function annotation, not an effect-row atom: `#zero_alloc` (region storage permitted), `#zero_alloc(strict)` (counts it), `#zero_alloc(assume)` (a trusted boundary) | ADR-0091, [zero-alloc-check.md](../../internal/design/zero-alloc-check.md) |
| Scala capture checking | Not adopted. A capture set on every type would be a second annotation dimension across the whole checker, and the upstream design is still experimental | — |

Three parts of capture checking map onto smaller mechanisms vibe has or is
considering:

- **"This value does not escape"** is what Perceus cashes in as an omitted
  retain/release. vibe infers it per parameter position
  (`compute_borrow_param_user_fns`) rather than declaring it.
- **`consume`** as a parameter attribute, without the rest of capture checking,
  is part of the second-class borrow-mode proposal in
  [borrowing-and-vectorization.md](borrowing-and-vectorization.md).
- **A read-only view** of region storage could be expressed as an effect-set
  subset of the region's operations (ADR-0071 / ADR-0088) rather than as a new
  mechanism. Nothing implements it.

## How the pieces fit

- **Regions complement RC.** Region collection storage is reclaimed by
  resetting a watermark rather than by per-object counts. Only the collection
  buffers live there: ordinary heap values allocated inside a region keep their
  normal lifetime, so a region does not reclaim a cycle of ordinary objects.
  The dedicated arena is disabled on the RC lane today: an arena block must
  stay out of the RC free list, and the elements a buffer holds still need
  their releases (the requirements are in
  [region-mutable-state.md](../../internal/design/region-mutable-state.md#requirements-for-an-rc-arena-experiment)).
- **RC operations are not allocations.** A retain or release allocates
  nothing, so `#zero_alloc` does not count it. What it does count includes the
  implicit allocations: a capturing closure literal (its environment) and
  `Double` literals and arithmetic (heap-boxed on the linear backend).
- **Allocation is not an effect.** Nearly every function allocates, so an
  `Alloc` row atom would put an annotation on almost everything; OxCaml's
  attribute-plus-backend-check is the right place for it.
- **Reuse is not credited.** `#zero_alloc` checks statements before Perceus
  runs, and constructor reuse depends on a run-time uniqueness test, so a
  reuse candidate does not make a function allocation-free
  ([perceus-reuse.md](../../internal/design/perceus-reuse.md)).

The answer to "control mutable state with effects" that falls out: mutation
observable across a scope boundary is expressed through regions (and, in the
future, `with r` in the row); local `let mut` stays an implementation detail
with no row; whether a function allocates is an orthogonal axis carried by an
attribute; and per-object alias tracking waits until regions and the
attribute leave a measured need for it.
[side-effect-consolidation.md](../../internal/design/side-effect-consolidation.md)
records the measurements behind the mutation-authority rule.

## Sources

- The Scala 3 reference, "Capture Checking" (experimental), and its
  separation-checking extension.
- The Flix documentation on regions.
- The OxCaml documentation and announcement of `[@zero_alloc]`.
