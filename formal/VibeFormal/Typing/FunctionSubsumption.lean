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
iff every effect it may perform is authorized by `target`'s declared row --
the static core of #939's soundness requirement. (Parameter/return-type
variance is out of scope here, per the module docstring above; this
isolates just the effect-row half of assignability.)
-/
def FnType.Subsumes (source target : FnType) : Prop :=
  EffectRow.Subset source.effects target.effects

namespace FnType.Subsumes

/-- Assignability is reflexive: a function value can always be used at its own type. -/
theorem refl (t : FnType) : FnType.Subsumes t t :=
  EffectRow.Subset.refl t.effects

/-- Assignability composes. -/
theorem trans {a b c : FnType}
    (ab : FnType.Subsumes a b) (bc : FnType.Subsumes b c) : FnType.Subsumes a c :=
  EffectRow.Subset.trans ab bc

/-- Assignability is preserved by replacing either side with an equivalent
(same-meaning) row -- lets a future normalization pass rewrite a `FnType`
without invalidating an already-established `Subsumes` fact. -/
theorem congr_left {source source' target : FnType}
    (equiv : EffectRow.Equivalent source.effects source'.effects)
    (subsumes : FnType.Subsumes source target) : FnType.Subsumes source' target :=
  EffectRow.Subset.congr_left equiv subsumes

theorem congr_right {source target target' : FnType}
    (equiv : EffectRow.Equivalent target.effects target'.effects)
    (subsumes : FnType.Subsumes source target) : FnType.Subsumes source target' :=
  EffectRow.Subset.congr_right equiv subsumes

end FnType.Subsumes

/--
**#939's soundness statement.** A function value that actually performs some
operation can never be subsumed to the pure function type: passing an
effectful function where a pure one is declared is unsound and must be
rejected, regardless of which operation it is or what the rest of its row
looks like. This is the formal counterpart of the bug report's crash --
the live checker previously accepted this assignment unconditionally.
-/
theorem FnType.not_subsumes_pure_of_performs
    {source : FnType} {operation : VibeFormal.OperationRef}
    (performs : operation ∈ source.effects) :
    ¬ FnType.Subsumes source FnType.pure := by
  intro subsumes
  exact absurd (subsumes operation performs) (by simp [FnType.pure])

/--
Converse sanity check: a function that performs nothing IS assignable to
the pure function type (the empty row trivially authorizes nothing, so
requiring nothing is exactly satisfied). Confirms `not_subsumes_pure_of_performs`
is about genuine effectfulness, not an overly strong statement that would
also reject legitimately pure functions.
-/
theorem FnType.subsumes_pure_of_no_performs
    {source : FnType} (noPerforms : source.effects = []) :
    FnType.Subsumes source FnType.pure := by
  intro operation membership
  rw [noPerforms] at membership
  exact absurd membership (by simp)

end VibeFormal.Typing
