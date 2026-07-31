import VibeFormal.Typing.Core
import VibeFormal.Typing.FunctionSubsumption

set_option autoImplicit false

/-
#939 / #1238, second slice: **variance**.

`Typing/FunctionSubsumption.lean` (the first slice) isolated the *effect-row*
half of #939 -- an effectful function value must not be assignable to a pure
function type -- on a `FnType` that carried a latent row and nothing else. Its
scope note says so explicitly: "Full parameter/return-type variance is still
future work under #939." This file is that future work.

**Why a separate shape type.** `Typing/Core.lean`'s `Ty` has no function
constructor, and adding one would ripple through `Call.lean`'s
`instantiate`/`render`/`sameHead` and `Oracle.lean`'s differential testing
against `oracle/call-typing.tsv` -- the blast radius the first slice declined
to take on. `FnShape` below is a standalone recursive type that uses `Ty` only
at its leaves, so higher-order nesting becomes expressible without touching the
shared model or the oracle data set.

**In scope**: parameter contravariance, result covariance, latent effect rows
at every arrow, and their interaction -- specifically, that an effectful
function hidden inside a parameter or a result position cannot be laundered
into a pure one. That interaction is the part a row-only model cannot state,
and it is where the #939 bug generalizes: the checker's original mistake
(dropping a latent row on assignment) re-admits itself one level up if the
parameter position is treated covariantly.

**Out of scope, unchanged from the first slice**: type variables and
instantiation (the `Ty` leaves are compared by equality here, which
`Typing/Core.lean` and `Proofs/CallTypingCorrect.lean` already model on their
own), row polymorphism (an open row variable has no representation in
`EffectRow.Normalized`, ADR-0071 Phase 1), and any claim about the live
checker's implementation -- this is a specification oracle, and correspondence
to `checker.vibe` is a differential-test question per #1238's ground rules.

**Exemptions.** `exempt` is threaded exactly as in the first slice, and for the
same reason: `checker.vibe`'s `effect_label_is_exempt` carves out `Error` and
`Async`, and `OperationRef` (`Effect/Id.lean`) is an opaque resolved identity
with no recoverable source-level name at this layer. Every statement below is
therefore parameterized by the exemption predicate rather than hardcoding one.
-/

namespace VibeFormal.Typing

/--
A type as seen by the variance rules: either an opaque value type (a `Ty`
leaf -- compared by equality, since nothing here depends on its structure) or
an arrow carrying a parameter, a result, and the latent effect row the function
may perform when applied.

One parameter per arrow is not a restriction on what can be said: an n-ary
function is the curried nesting, and the variance rules compose through it.
-/
inductive FnShape where
  | base (value : Ty)
  | arrow (parameter : FnShape) (result : FnShape) (effects : EffectRow.Normalized)
  deriving Repr

/--
Row subsumption, factored out of `FnType.Subsumes` so it can be applied at
every arrow in a nested shape: every non-exempt operation the source may
perform must be authorized by the target's declared row.
-/
def RowSubsumes (exempt : OperationRef → Prop)
    (source target : EffectRow.Normalized) : Prop :=
  ∀ operation, operation ∈ source → exempt operation ∨ operation ∈ target

namespace RowSubsumes

theorem refl (exempt : OperationRef → Prop) (row : EffectRow.Normalized) :
    RowSubsumes exempt row row :=
  fun _ membership => Or.inr membership

theorem trans {exempt : OperationRef → Prop} {a b c : EffectRow.Normalized}
    (ab : RowSubsumes exempt a b) (bc : RowSubsumes exempt b c) :
    RowSubsumes exempt a c :=
  fun operation membership =>
    match ab operation membership with
    | Or.inl isExempt => Or.inl isExempt
    | Or.inr inB => bc operation inB

end RowSubsumes

/-- The first slice's `FnType.Subsumes` IS row subsumption on the latent rows;
the two models agree by definition, so nothing proved there is invalidated. -/
theorem FnType.subsumes_eq_rowSubsumes (exempt : OperationRef → Prop)
    (source target : FnType) :
    FnType.Subsumes exempt source target
      = RowSubsumes exempt source.effects target.effects :=
  rfl

/--
Assignability for function shapes: a value of type `source` may be used where
`target` is expected.

- **Parameters are contravariant.** `Sub exempt p' p` (note the direction): a
  function that accepts *more* can stand in for one that accepts less. Reading
  it the other way -- covariantly -- is exactly what re-admits #939's bug at
  higher order, and `not_sub_of_covariant_parameter` below is the witness.
- **Results are covariant.** Whatever comes back must already be usable at the
  expected result type.
- **Latent rows subsume.** Every non-exempt operation the source may perform is
  authorized by the target's row. With `target`'s row empty this is the first
  slice's statement, now applicable at any depth.
-/
inductive FnShape.Sub (exempt : OperationRef → Prop) : FnShape → FnShape → Prop where
  | base {value : Ty} : FnShape.Sub exempt (.base value) (.base value)
  | arrow {sourceParam targetParam sourceResult targetResult : FnShape}
      {sourceEffects targetEffects : EffectRow.Normalized} :
      FnShape.Sub exempt targetParam sourceParam →
      FnShape.Sub exempt sourceResult targetResult →
      RowSubsumes exempt sourceEffects targetEffects →
      FnShape.Sub exempt
        (.arrow sourceParam sourceResult sourceEffects)
        (.arrow targetParam targetResult targetEffects)

namespace FnShape.Sub

/-- Assignability is reflexive at every shape. -/
theorem refl (exempt : OperationRef → Prop) : ∀ shape : FnShape, FnShape.Sub exempt shape shape
  | .base _ => .base
  | .arrow parameter result effects =>
      .arrow (refl exempt parameter) (refl exempt result) (RowSubsumes.refl exempt effects)

/--
Assignability composes. The induction runs on the MIDDLE shape rather than on
either derivation: contravariance flips the parameter obligation to the other
side, so the induction hypothesis needed there is the one indexed by the shape
sitting between the two parameter types, not by a sub-derivation of the first
premise.
-/
theorem trans {exempt : OperationRef → Prop} :
    ∀ {middle source target : FnShape},
      FnShape.Sub exempt source middle → FnShape.Sub exempt middle target →
      FnShape.Sub exempt source target := by
  intro middle
  induction middle with
  | base value =>
      intro source target sourceMiddle middleTarget
      cases sourceMiddle
      cases middleTarget
      exact .base
  | arrow parameter result _ parameterIH resultIH =>
      intro source target sourceMiddle middleTarget
      cases sourceMiddle with
      | arrow paramLower resultUpper rowUpper =>
          cases middleTarget with
          | arrow paramLower' resultUpper' rowUpper' =>
              exact .arrow (parameterIH paramLower' paramLower)
                (resultIH resultUpper resultUpper')
                (RowSubsumes.trans rowUpper rowUpper')

end FnShape.Sub

/-- The pure arrow: performs nothing when applied. -/
def FnShape.pureArrow (parameter result : FnShape) : FnShape :=
  .arrow parameter result []

/--
**#939's statement, restated on the nested model.** A function that may perform
a non-exempt operation is not assignable to the otherwise identical pure
function type. With `FnShape` this now holds at any depth, not only at the top
level of an assignment.
-/
theorem FnShape.not_sub_pureArrow_of_nonexempt {exempt : OperationRef → Prop}
    {parameter result : FnShape} {effects : EffectRow.Normalized} {operation : OperationRef}
    (performs : operation ∈ effects) (notExempt : ¬ exempt operation) :
    ¬ FnShape.Sub exempt (.arrow parameter result effects)
        (FnShape.pureArrow parameter result) := by
  intro subsumes
  cases subsumes with
  | arrow _ _ row =>
      match row operation performs with
      | Or.inl isExempt => exact notExempt isExempt
      | Or.inr inPure => exact absurd inPure (by simp)

/--
**The higher-order negative witness.** A function whose parameter is a PURE
callback cannot be used where a function whose parameter is an EFFECTFUL
callback is expected: accepting the substitution would let the caller hand an
effectful callback to something that promised to receive a pure one -- #939's
crash, reintroduced one level down.

This is precisely what a covariant reading of the parameter position would
allow, so it is the property that pins the direction of the rule rather than
merely exercising it.
-/
theorem FnShape.not_sub_of_covariant_parameter {exempt : OperationRef → Prop}
    {value : Ty} {effects : EffectRow.Normalized} {operation : OperationRef}
    (performs : operation ∈ effects) (notExempt : ¬ exempt operation) :
    ¬ FnShape.Sub exempt
        (.arrow (FnShape.pureArrow (.base value) (.base value)) (.base value) [])
        (.arrow (.arrow (.base value) (.base value) effects) (.base value) []) := by
  intro subsumes
  cases subsumes with
  | arrow parameterObligation _ _ =>
      exact FnShape.not_sub_pureArrow_of_nonexempt performs notExempt parameterObligation

/--
Positive counterpart, in the direction contravariance DOES allow: a function
that accepts an effectful callback can stand in where one accepting a pure
callback is expected. Confirms the rule above rejects a direction rather than
rejecting parameter-nested arrows outright.
-/
theorem FnShape.sub_of_contravariant_parameter (exempt : OperationRef → Prop)
    {value : Ty} {effects : EffectRow.Normalized} :
    FnShape.Sub exempt
      (.arrow (.arrow (.base value) (.base value) effects) (.base value) [])
      (.arrow (FnShape.pureArrow (.base value) (.base value)) (.base value) []) :=
  .arrow (.arrow .base .base (fun _ membership => absurd membership (by simp)))
    .base (RowSubsumes.refl exempt [])

/--
**The result-position witness.** A function that RETURNS an effectful function
cannot be used where one returning a pure function is expected -- the latent
row cannot be laundered by hiding it behind a return type either.
-/
theorem FnShape.not_sub_of_effectful_result {exempt : OperationRef → Prop}
    {value : Ty} {effects : EffectRow.Normalized} {operation : OperationRef}
    (performs : operation ∈ effects) (notExempt : ¬ exempt operation) :
    ¬ FnShape.Sub exempt
        (.arrow (.base value) (.arrow (.base value) (.base value) effects) [])
        (.arrow (.base value) (FnShape.pureArrow (.base value) (.base value)) []) := by
  intro subsumes
  cases subsumes with
  | arrow _ resultObligation _ =>
      exact FnShape.not_sub_pureArrow_of_nonexempt performs notExempt resultObligation

/--
Bridge to the first slice: when the parameter and result types coincide, the
nested rule degenerates to exactly the row subsumption
`Typing/FunctionSubsumption.lean` already proved things about. The variance
extension is conservative -- it adds obligations at nested positions and
changes nothing at the top level.
-/
theorem FnShape.sub_arrow_iff_row (exempt : OperationRef → Prop)
    {parameter result : FnShape} {sourceEffects targetEffects : EffectRow.Normalized} :
    FnShape.Sub exempt (.arrow parameter result sourceEffects)
        (.arrow parameter result targetEffects)
      ↔ RowSubsumes exempt sourceEffects targetEffects := by
  constructor
  · intro subsumes
    cases subsumes with
    | arrow _ _ row => exact row
  · intro row
    exact .arrow (FnShape.Sub.refl exempt parameter) (FnShape.Sub.refl exempt result) row

/--
Sanity check that the exemption parameter is load-bearing rather than
decorative: with everything exempt, the assignment
`not_sub_pureArrow_of_nonexempt` rejects is accepted. This mirrors the live
checker's `Error`/`Async` carve-outs at nested positions too.
-/
theorem FnShape.sub_pureArrow_of_all_exempt {parameter result : FnShape}
    {effects : EffectRow.Normalized} :
    FnShape.Sub (fun _ => True) (.arrow parameter result effects)
      (FnShape.pureArrow parameter result) :=
  .arrow (FnShape.Sub.refl _ parameter) (FnShape.Sub.refl _ result)
    (fun _ _ => Or.inl trivial)

end VibeFormal.Typing
