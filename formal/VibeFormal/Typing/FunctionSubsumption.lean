import VibeFormal.Effect.Row
import VibeFormal.Proofs.SubsetCorrect

set_option autoImplicit false

/-
#939 (checker: an effectful function VALUE is implicitly subsumed to a pure
function type -- struct fields, arrays, `let` annotations, and HOF
arguments all accepted this and crashed with an unhandled exception at
runtime; fixed in the live checker on 2026-07-18, tracked here per #955's
roadmap as the still-open Lean formalization of that fix).

#939's own scope note in the live call-typing model
(`Typing/Core.lean`'s `Ty` docstring) is explicit: "Function types,
variance, and row polymorphism belong to the higher-order extension
tracked by #939." Extending the SHARED `Ty`/`TyArgs` type with a function
constructor would ripple through `Call.lean`'s `instantiate`/`render`/
`sameHead` and `Oracle.lean`'s differential testing against
`oracle/call-typing.tsv` (a fixed real-world data set compared against the
live selfhost checker) -- a change with a much larger blast radius than
this slice, and risk that isn't proportionate to what #939's bug report
was actually about.

The bug report's actual content was narrower than "the full higher-order
type system": a function value's *latent effect row* silently disappearing
on assignment. This file isolates exactly that -- a standalone `FnType`
carrying only an effect row (no parameter/return types, no variance),
independent of the shared `Ty` model -- and states + proves the static
soundness property the bug violated: an effectful function value cannot be
assignable to a pure function type. Full parameter/return-type variance is
still future work under #939, unchanged from the existing scope note.

**Codex review correction (PR #1172):** the first version of this file
modeled subsumption as unconditional rejection of ANY performed operation.
That does not correspond to the live checker: `checker.vibe`'s
`effect_label_is_exempt` (used by the #939 fix itself) explicitly exempts
`Error` (pervasive un-annotated throw sites, #640) and `Async`
(composition-allowed) from this rule, and
`checker_effect_value_test.vibe`'s "`with { Error }` value into a pure
slot stays accepted (exempt)" test pins exactly that. `Subsumes` below
now takes an `exempt` predicate and the soundness theorem is stated for a
NON-exempt operation, so it actually matches what the checker accepts and
rejects instead of a strictly-stronger idealization.
-/

namespace VibeFormal.Typing

/-- A function type's latent effect row, in isolation from the shared `Ty`
value/nominal-argument model (`Typing/Core.lean`) that `Call.lean` and
`Oracle.lean` differentially test against the live compiler. -/
structure FnType where
  effects : EffectRow.Normalized
  deriving DecidableEq, Repr

/-- The pure function type: a function that performs no effects at all. -/
def FnType.pure : FnType := ⟨[]⟩

/--
A function value of type `source` may be used where `target` is expected
iff every NON-EXEMPT effect it may perform is authorized by `target`'s
declared row -- the static core of #939's soundness requirement, now
matching the live checker's actual rule rather than a strictly stronger
one. `exempt` is a predicate parameter rather than a hardcoded check
against `Error`/`Async` because Phase 1's `OperationRef` (`Effect/Id.lean`)
is an opaque resolved identity with no recoverable source-level name --
"is this literally the Error effect" cannot be decided at this layer
(`Row.lean`'s own design note: name resolution happens before this
model). A future phase threading effect names through would replace this
parameter with a concrete decidable check against Error/Async's
`EffectDefId`s; until then, callers instantiate `exempt` with whatever
predicate matches their needs (e.g. `fun _ => False` for the fully strict
rule, used by `not_subsumes_pure_of_performs_strict` below).
(Parameter/return-type variance is out of scope here, per the module
docstring above; this isolates just the effect-row half of assignability.)
-/
def FnType.Subsumes (exempt : OperationRef → Prop) (source target : FnType) : Prop :=
  ∀ operation, operation ∈ source.effects → exempt operation ∨ operation ∈ target.effects

namespace FnType.Subsumes

/-- Assignability is reflexive: a function value can always be used at its own type. -/
theorem refl (exempt : OperationRef → Prop) (t : FnType) : FnType.Subsumes exempt t t :=
  fun _ membership => Or.inr membership

/-- Assignability composes. -/
theorem trans {exempt : OperationRef → Prop} {a b c : FnType}
    (ab : FnType.Subsumes exempt a b) (bc : FnType.Subsumes exempt b c) :
    FnType.Subsumes exempt a c :=
  fun operation membership =>
    match ab operation membership with
    | Or.inl isExempt => Or.inl isExempt
    | Or.inr inB =>
        match bc operation inB with
        | Or.inl isExempt => Or.inl isExempt
        | Or.inr inC => Or.inr inC

/-- Assignability is preserved by replacing either side with an equivalent
(same-meaning) row -- lets a future normalization pass rewrite a `FnType`
without invalidating an already-established `Subsumes` fact. -/
theorem congr_left {exempt : OperationRef → Prop} {source source' target : FnType}
    (equiv : EffectRow.Equivalent source.effects source'.effects)
    (subsumes : FnType.Subsumes exempt source target) : FnType.Subsumes exempt source' target :=
  fun operation membership => subsumes operation ((equiv operation).mpr membership)

theorem congr_right {exempt : OperationRef → Prop} {source target target' : FnType}
    (equiv : EffectRow.Equivalent target.effects target'.effects)
    (subsumes : FnType.Subsumes exempt source target) : FnType.Subsumes exempt source target' :=
  fun operation membership =>
    match subsumes operation membership with
    | Or.inl isExempt => Or.inl isExempt
    | Or.inr inTarget => Or.inr ((equiv operation).mp inTarget)

end FnType.Subsumes

/--
**#939's soundness statement, matching the live checker exactly.** A
function value that performs a NON-EXEMPT operation can never be subsumed
to the pure function type: passing an effectful function where a pure one
is declared is unsound and must be rejected for that operation, unless
the operation is one of the checker's carve-outs (`Error`/`Async`). This
is the formal counterpart of the bug report's crash -- the live checker
previously accepted this assignment unconditionally, for exempt and
non-exempt operations alike.
-/
theorem FnType.not_subsumes_pure_of_performs_nonexempt
    {exempt : OperationRef → Prop} {source : FnType} {operation : OperationRef}
    (performs : operation ∈ source.effects) (notExempt : ¬ exempt operation) :
    ¬ FnType.Subsumes exempt source FnType.pure := by
  intro subsumes
  match subsumes operation performs with
  | Or.inl isExempt => exact notExempt isExempt
  | Or.inr inPure => exact absurd inPure (by simp [FnType.pure])

/--
Corollary: instantiating `exempt` with `fun _ => False` (nothing is
exempt) recovers the fully strict rule -- any performed operation blocks
subsumption to pure. This is NOT the live checker's actual rule (which
does exempt `Error`/`Async`, see `not_subsumes_pure_of_performs_nonexempt`
for the checker-corresponding statement); it exists as a sanity check
that the general statement doesn't accidentally degenerate to something
vacuous when exemptions are absent.
-/
theorem FnType.not_subsumes_pure_of_performs_strict
    {source : FnType} {operation : OperationRef}
    (performs : operation ∈ source.effects) :
    ¬ FnType.Subsumes (fun _ => False) source FnType.pure :=
  FnType.not_subsumes_pure_of_performs_nonexempt performs (fun exempt => exempt)

/--
Converse sanity check: a function that performs nothing IS assignable to
the pure function type regardless of `exempt` (the empty row trivially
authorizes nothing, so requiring nothing is exactly satisfied). Confirms
`not_subsumes_pure_of_performs_nonexempt` is about genuine effectfulness,
not an overly strong statement that would also reject legitimately pure
functions.
-/
theorem FnType.subsumes_pure_of_no_performs
    (exempt : OperationRef → Prop) {source : FnType} (noPerforms : source.effects = []) :
    FnType.Subsumes exempt source FnType.pure := by
  intro operation membership
  rw [noPerforms] at membership
  exact absurd membership (by simp)

end VibeFormal.Typing
