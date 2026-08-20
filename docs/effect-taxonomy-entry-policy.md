# ADR-0084: Effect classification and the `.vibex` entry-row admission rule

Status: proposed

Date: 2026-07-30

Related: #1218, ADR-0071 (effectset), ADR-0075 (`.vibex` runtime contract),
ADR-0073 (checked `Error`), ADR-0068 (concurrency). Background and the
alternatives considered are in
[effect-taxonomy-review.md](effect-taxonomy-review.md).

> **Implementation boundary (#1496, #1683):** The full resource-qualified
> taxonomy in the formal model remains prospective. The current compiler uses
> the narrower `core/standard_effect_policy.vibe` registry as an executable
> entry-admission boundary: a row label is admitted when a standard host
> provider or the entry/runtime policy owns it; every other source effect must
> be handled before `main` / `_start`.

## Context

vibe's effect rows currently keep `Fs`, `Env`, `Error`, `Async`, and a
user-defined `Logger` as the same kind of string label. But they differ in
whether the host can resolve them or whether a handler inside the program has
to.

ADR-0075 requires a closed/exact row on a `.vibex` `main`. Allowing an
ordinary algebraic effect the host cannot resolve to remain on `main` would
make the host contract unsatisfiable; conversely, banning a capability like
`Fs` from `main` would contradict the purpose of the execution contract.

## Decision

Effect operations are treated under the following four classes (`runtime
effect` was added by #1458).

| class | who discharges it | permission-sensitive? | members |
|---|---|---|---|
| **capability effect** | host / provider (outside the wasm boundary) | yes | Fs, Http, Socket, Env, Console (current tty; Stdin/Stdout/Stderr are legacy labels for the same host imports), Process, Profiler |
| **algebraic effect** | a `handle` inside the program | no | Log, State, Ask, ParseRecur, … (every name not in this table) |
| **core ambient effect** | nobody (the entry treats it abortively) | no | Exception[E] / Error |
| **runtime effect** | the runtime itself | no | Async |

1. A **capability effect** is an effect carrying a resource kind parameter.
   The host/provider resolves its binding and projects it into the residual
   WIT contract — e.g. `Fs[Root]::read_file` and `S3[Posts]::get_object`.
2. An **algebraic effect** is an ordinary effect with no resource kind
   parameter. It exists for in-process handlers/DI and must be discharged by
   `handle` before reaching a `.vibex` `main`.
3. A **core ambient effect** is one of a small language-reserved set.
   ADR-0085's typed `Exception[E]` (`Error` is a transitional alias)
   qualifies. The entry boundary's runtime handler converts it into a
   diagnosed failure, so it is allowed to remain on `main`'s row.
4. A **runtime effect** (#1458) is an effect the runtime drives. Its only
   member today is `Async`, which per ADR-0089 Decision 5 is **a backend
   choice, not a permission**. It is allowed to remain on `main`'s row.

   Separating it from core ambient is not just taxonomic tidiness. Both
   "pass through the row", but **for opposite reasons** — a core ambient
   effect may remain because nobody discharges it, a runtime effect because
   the runtime discharges it. While `Async` was lumped in with core ambient,
   both the checker and wit_gen carried comments readable as "`Error` and
   `Async` are here for the same reason".

   This is prospective admission-model terminology. In the current compiler,
   checker row filtering and WIT import filtering instead use the narrow
   `is_entry_runtime_managed_effect` execution-policy predicate.

The residual row on a `.vibex` `main` may contain capability effects, core
ambient effects, and runtime effects. A program whose row still carries an
algebraic effect is a type error before WIT generation or host preflight.
This does not restrict the rows of ordinary functions.

Source compatibility for existing builtins is preserved. In Phase 1, existing
`with Fs` and `Fs::read_file(...)` lower internally to the implicit singleton
resource `Fs[Process::Root]`. Explicit resource syntax is a Phase 2+ addition;
this ADR does not decide its surface syntax.

## Consequences

- The row `main` leaves behind becomes a contract the host can preflight. A
  `Logger` or `State[T]` the host cannot resolve cannot remain.
- User-defined algebraic effects stay usable as before in ordinary functions,
  higher-order functions, and inside handlers; they just have to be
  discharged before the entry.
- `Error`'s existing entry-boundary treatment is kept. Since the rename is
  not done first, no mass source change or bootstrap bump is needed.
- The current entry-row check admits the existing providers in the standard
  policy registry plus the entry/runtime owners, and fails closed on
  everything else (#1683). Explicit resource kinds and metadata-driven
  classification remain follow-up phases. A user operation on a same-named
  effect gains no provider authority; conversely, a same-named effect in a
  linked module does not cost a registry-owned operation its authority. An
  open row containing a row variable is also rejected as an entry contract.

## Non-goals

- Deciding the surface syntax for resource kind parameters or kind bounds.
- Implementing the `resource` plan/apply/bind lifecycle, optional
  capabilities, or the WIT ABI — those are follow-up phases of ADR-0075.
- Renaming `Error` to `Exception[E]`. The rename, typed identity, and the
  relationship with Wasm EH are defined by [ADR-0085](exception-effect.md).
- Making `TaskGroup::spawn` row-polymorphic or implementing fork-safe
  evidence transfer; those are individual pieces of ADR-0068 / ADR-0075.

## Implementation sequence

1. Introduce resource kind and effect class into `OperationRef` / builtin
   metadata, lowering builtins to the implicit `Process::Root`. Confirm the
   existing fixtures pass unchanged.
2. Let the checker distinguish capabilities with an explicit resource kind
   from algebraic effects without one.
3. Classify the row remaining on a `.vibex` `main` / `_start` under the
   current standard policy: reject user effects, accept host providers /
   Exception / Async. **The current-policy slice landed in #1683.** Replacing
   it with the resource-qualified taxonomy comes after the Phase 1/2 metadata
   work.
4. Pass only that residual row to WIT / `Entry.requires` / host preflight.

## Formal contract

A taxonomy-level contract ahead of the implementation is defined in
[`Effect/Taxonomy.lean`](../formal/VibeFormal/Effect/Taxonomy.lean), with
[`EffectTaxonomyCorrect.lean`](../formal/VibeFormal/Proofs/EffectTaxonomyCorrect.lean)
proving the executable checker agrees with the propositions. The model fixes:

- capability / algebraic / typed Exception are disjoint requirements.
- An entry row admits only capability/core-ambient members, and a capability
  keeps an exact logical resource marker on its `OperationRef`.
- A host can provide an exact capability identity but cannot resolve an
  algebraic effect.
- A handler discharges only the same algebraic effect, or exactly its
  Exception kind, preserving other categories and other kinds.
- A spawn child row is a subset of the parent row; capabilities need
  fork-safe host evidence, and algebraic handler evidence is not inherited by
  default.

[`EffectTaxonomyExamples.lean`](../formal/VibeFormal/Proofs/EffectTaxonomyExamples.lean)
holds accept/reject examples plus a counterexample: a broken preflight that
projects only capabilities out of the row wrongly accepts an unhandled
`Logger`.

The boundary that builds the three-way classification from a resolved
`OperationRef` and declaration metadata is defined in
[`Effect/TaxonomyClassifier.lean`](../formal/VibeFormal/Effect/TaxonomyClassifier.lean).
A catalog lookup succeeds only when exactly one metadata entry exists for the
`EffectDefId`. A capability must carry exactly one logical resource id, an
algebraic effect zero resource arguments, and a core Exception exactly one
normalized type argument. Unknown ids, duplicate metadata, and malformed
arguments reject the complete row — no element is silently dropped.

[`TaxonomyClassifierCorrect.lean`](../formal/VibeFormal/Proofs/TaxonomyClassifierCorrect.lean)
proves the executable classifier agrees with the declarative `Classifies`
relation, plus well-formedness and input/output length preservation on
successful row classification.
[`TaxonomyClassifierExamples.lean`](../formal/VibeFormal/Proofs/TaxonomyClassifierExamples.lean)
holds counterexamples for a broken classifier that guesses the class from
argument shape alone, and a broken row conversion that discards failing
elements via `filterMap`.

The 15 positive/negative cases of this classification boundary are fixed as a
machine-readable Oracle in
[`effect-taxonomy.tsv`](../formal/oracle/effect-taxonomy.tsv). Catalog
metadata, resolved operation rows, accept/reject verdicts, and the normalized
requirement rows are generated from the Lean model by
[`TaxonomyOracleMain.lean`](../formal/TaxonomyOracleMain.lean), and
`formal-check` rejects a stale snapshot. For now this is a contract-level
Oracle; once the selfhost checker exposes declaration metadata, the same
corpus connects as a differential fixture.

The connection from the taxonomy check to the ADR-0075 contract is defined in
[`Capability/TaxonomyBridge.lean`](../formal/VibeFormal/Capability/TaxonomyBridge.lean),
with
[`TaxonomyBridgeCorrect.lean`](../formal/VibeFormal/Proofs/TaxonomyBridgeCorrect.lean)
proving a one-way refinement. An exact `CapabilityRef` projects onto a
semantic `OperationRef` and `ResourceClaim`; a host provider projects onto an
authority and `ResourceBinding`. If the complete row passes the entry/spawn
judgement, the projected form also passes the existing ADR-0075 preflight.

The converse implication does not hold. Skipping the taxonomy check before
projection makes algebraic effects vanish from a capability-only contract,
and skipping resource claims wrongly accepts a different resource kind with
the same operation/resource identity.
[`TaxonomyBridgeExamples.lean`](../formal/VibeFormal/Proofs/TaxonomyBridgeExamples.lean)
fixes both negative examples.

Path scope for resource-qualified capabilities is defined as a separate layer
in ADR-0075's
[`Capability/PathScope.lean`](../formal/VibeFormal/Capability/PathScope.lean).
Globs that can intersect within the same logical/physical scope domain are
allowed only under the same authority; a scope-aware preflight rejects
overlaps across different authorities.
[`PathScopeCorrect.lean`](../formal/VibeFormal/Proofs/PathScopeCorrect.lean)
proves the overlap judgement equivalent to the existence of a common path,
and the uniqueness of the authority among grants matching the same path. The
executable checker returns a canonical common-path witness, and `none` is
likewise equivalent to the semantic intersection being empty.

This is a machine-checked model of the ADR's semantics, not a correspondence
proof against the current string-label checker, builtin metadata, or WIT
generation. Implementation sequence 1–4 and the compiler fixtures remain
necessary.

## Reconciliation ledger

| item | evidence / observation | conclusion |
| --- | --- | --- |
| expected contract | ADR-0075 requires a closed/exact row on `main` and host preflight | the entry row must be host-resolvable |
| implementation observation | `checker_effects.vibe` checks the `main` / `_start` row via `is_entry_admitted_effect` (#1683) | user effects with no host/runtime owner are rejected before WIT/codegen |
| implementation observation | `checker_effects.vibe` tracks effects as string labels and special-cases `Error` / `Async` | effect class / resource kind metadata is the prerequisite |
| regression guard | `main with Ask` / `_start with Ask` reject; `main with Fs + Exception + Async` accepts | pinned in checker tests (#1683) |
| formal model | taxonomy-level requirements, entry/host/spawn judgements, and handler discharge are defined in Lean | the ADR's semantics are machine-checked; checker correspondence is unproven |
| metadata classifier | classifies a complete row from exactly-one metadata lookups and argument shapes, failing closed on unknown/duplicate/malformed | the implementation metadata is to be brought into correspondence with this contract |
| Oracle corpus | 15 positive/negative cases generated from Lean into TSV, with `formal-check` rejecting stale snapshots | contract regression guarding is automated; the selfhost differential waits on the metadata API |
| contract refinement | exact capabilities project onto operations/claims/bindings, and the implication from taxonomy admission to the ADR-0075 preflight is proven in Lean | the taxonomy check is mandatory before WIT/host projection |
| path-scope policy | overlap of restricted globs is equivalent to the existence of a common path, with sound diagnostic witnesses and authority uniqueness proven | overlaps under different authorities reject exactly, across the logical/physical layers, reporting the common path |

Phase 3's current-policy slice is pinned by #1683's checker tests. Full
correspondence between the resource-qualified classifier and the Lean
contract remains work that follows the metadata API.
