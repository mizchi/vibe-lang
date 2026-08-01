import VibeFormal.Typing.Core

set_option autoImplicit false

/-
#951 / #1238: an or-pattern's alternatives must agree on what they bind.

`Some(x) | Wrapped(x)` is legal; `Some(x) | None` is not, and neither is
`IntCase(x) | StrCase(x)` where the two `x`s have different types. The rule
matters twice over: the checker needs one type per binder to check the arm
body, and codegen needs one slot per binder to write into whichever
alternative matched. When the two disagree, an arm body reads a binder the
matched alternative never wrote -- which is why this is a soundness rule and
not a convenience.

**In scope.** The binder environment an alternative contributes, agreement
between alternatives, and that agreement is what lets a single environment
describe the whole or-pattern. Nesting is included: an or-pattern inside an
or-pattern composes by the same rule.

**Out of scope.** Exhaustiveness and usefulness (#940 -- a separate slice; a
well-formed or-pattern can still be non-exhaustive, and the rules do not
interact), the order alternatives are tried, and the runtime representation
of a binder slot. Types come from `Typing/Core.lean`'s `Ty` and are compared
by equality: no subtyping, which is deliberate -- the live checker requires
the same type, not merely compatible ones, precisely because there is one
slot.
-/

namespace VibeFormal.Typing

/-- What a pattern binds: names paired with the type each is given. Order is
part of the value here but not part of the RULE -- `Agree` below is stated
extensionally so `Some(x) as (a, b) | Other(x) as (b, a)` is still legal. -/
abbrev Binders := List (String × Ty)

/-- The type `binders` gives `name`, if it binds it at all. -/
def Binders.lookup (binders : Binders) (name : String) : Option Ty :=
  match binders with
  | [] => none
  | (n, t) :: rest => if n = name then some t else Binders.lookup rest name

/--
Two alternatives agree when they bind exactly the same names at exactly the
same types -- stated as agreement of the two lookup functions, so it is
independent of the order the binders happen to be listed in.
-/
def Binders.Agree (left right : Binders) : Prop :=
  ∀ name, left.lookup name = right.lookup name

namespace Binders.Agree

theorem refl (binders : Binders) : Binders.Agree binders binders :=
  fun _ => rfl

theorem symm {left right : Binders} (agree : Binders.Agree left right) :
    Binders.Agree right left :=
  fun name => (agree name).symm

theorem trans {a b c : Binders} (ab : Binders.Agree a b) (bc : Binders.Agree b c) :
    Binders.Agree a c :=
  fun name => (ab name).trans (bc name)

end Binders.Agree

/--
An or-pattern, reduced to what this slice is about: each alternative is
summarized by the binders it contributes. A single (non-or) pattern is the
one-alternative case, so the rules below cover it without a separate form.
-/
inductive OrPattern where
  | alt (binders : Binders)
  | or (left right : OrPattern)
  deriving Repr

namespace OrPattern

/-- The binders of the FIRST alternative -- the representative environment the
checker would use for the arm body. It is only meaningful when `WellFormed`
holds, which is exactly what makes every alternative agree with it. -/
def representative : OrPattern → Binders
  | .alt binders => binders
  | .or left _ => representative left

/--
An or-pattern is well formed when every alternative agrees with every other.
Written as "both sides well formed AND their representatives agree", which is
equivalent (proved by `agree_representative` below) and lets the definition
stay structural.
-/
def WellFormed : OrPattern → Prop
  | .alt _ => True
  | .or left right =>
      WellFormed left ∧ WellFormed right
        ∧ Binders.Agree left.representative right.representative

end OrPattern

/-- `sub` is one of the alternatives reachable inside `pattern`. -/
inductive Subalternative : OrPattern → OrPattern → Prop where
  | here {pattern : OrPattern} : Subalternative pattern pattern
  | left {sub left right : OrPattern} :
      Subalternative sub left → Subalternative sub (.or left right)
  | right {sub left right : OrPattern} :
      Subalternative sub right → Subalternative sub (.or left right)

namespace OrPattern

/--
The point of the rule: in a well-formed or-pattern, EVERY alternative -- not
just the two immediately joined by an `|` -- agrees with the representative
environment. This is what licenses checking the arm body once, against one
environment, and writing one slot per binder in codegen.
-/
theorem agree_representative {sub pattern : OrPattern} (member : Subalternative sub pattern) :
    WellFormed pattern → Binders.Agree sub.representative pattern.representative := by
  induction member with
  | here => intro _; exact Binders.Agree.refl _
  | left _ ih => intro wf; exact ih wf.1
  | right _ ih => intro wf; exact Binders.Agree.trans (ih wf.2.1) (Binders.Agree.symm wf.2.2)

/--
**Negative witness 1: a missing binder.** `Some(x) | None` is rejected --
one alternative binds `x`, the other binds nothing, so the arm body would
read a slot the second alternative never wrote.
-/
theorem not_wellFormed_missing_binder (name : String) (ty : Ty) :
    ¬ WellFormed (.or (.alt [(name, ty)]) (.alt [])) := by
  intro wf
  have agree := wf.2.2 name
  simp [representative, Binders.lookup] at agree

/--
**Negative witness 2: a binder at two types.** `IntCase(x) | StrCase(x)`
where the payloads differ is rejected even though both alternatives bind the
same NAME -- one slot cannot hold both, and the arm body was checked against
only one of them.
-/
theorem not_wellFormed_conflicting_type (name : String) :
    ¬ WellFormed (.or (.alt [(name, Ty.int)]) (.alt [(name, Ty.string)])) := by
  intro wf
  have agree := wf.2.2 name
  simp [representative, Binders.lookup, Ty.int, Ty.string] at agree

/--
Positive counterpart: alternatives that bind the same name at the same type
are well formed however they are nested, so the rule rejects disagreement
rather than rejecting or-patterns with binders.
-/
theorem wellFormed_matching_binders (name : String) (ty : Ty) :
    WellFormed (.or (.alt [(name, ty)]) (.or (.alt [(name, ty)]) (.alt [(name, ty)]))) := by
  refine ⟨trivial, ⟨trivial, trivial, ?_⟩, ?_⟩
  · intro _
    rfl
  · intro _
    rfl

end OrPattern

end VibeFormal.Typing
