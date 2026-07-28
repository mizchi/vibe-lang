import VibeFormal.Effect.Row

set_option autoImplicit false

namespace VibeFormal.EffectRow

/-- The executable row-subset checker decides mathematical set inclusion. -/
theorem subset_correct (required declared : Normalized) :
    subset required declared = true ↔ Subset required declared := by
  simp [subset, Subset, List.all_eq_true]

/-
Foundational preorder lemmas for `Subset`, not yet used by any Phase-1
checker but needed as building blocks by any future row-subsumption model
(#939's "effectful function value assigned to a pure function type" slice
requires lifting `Subset` through a function-type comparison, which needs
exactly this reflexivity/transitivity/union-monotonicity vocabulary).
-/

/-- `Subset` is reflexive: a row always authorizes itself. -/
theorem Subset.refl (row : Normalized) : Subset row row :=
  fun _ membership => membership

/-- `Subset` is transitive. -/
theorem Subset.trans {left middle right : Normalized}
    (leftMiddle : Subset left middle) (middleRight : Subset middle right) :
    Subset left right :=
  fun operation membership => middleRight operation (leftMiddle operation membership)

/-- Declaring additional operations never revokes an existing authorization. -/
theorem Subset.union_right_mono {required declared more : Normalized}
    (existing : Subset required declared) :
    Subset required (declared ++ more) :=
  fun operation membership => List.mem_append_left more (existing operation membership)

/-- A row is always authorized by any union containing it on the left. -/
theorem Subset.subset_union_left (left right : Normalized) :
    Subset left (left ++ right) :=
  fun _ membership => List.mem_append_left right membership

/-- A row is always authorized by any union containing it on the right. -/
theorem Subset.subset_union_right (left right : Normalized) :
    Subset right (left ++ right) :=
  fun _ membership => List.mem_append_right left membership

/--
The union of two required rows is authorized exactly when both halves are --
this is the algebraic shape of `make_row_mismatch`'s `required = declared ∪
missing` construction in the live checker (checker_effects.vibe), where
authorization of the combined requirement decomposes into authorization of
each contributing call site's own requirement.
-/
theorem Subset.union_left_iff {left right declared : Normalized} :
    Subset (left ++ right) declared ↔ Subset left declared ∧ Subset right declared := by
  constructor
  · intro combined
    exact ⟨fun operation membership => combined operation (List.mem_append_left right membership),
           fun operation membership => combined operation (List.mem_append_right left membership)⟩
  · intro ⟨subsetLeft, subsetRight⟩ operation membership
    rcases List.mem_append.mp membership with inLeft | inRight
    · exact subsetLeft operation inLeft
    · exact subsetRight operation inRight

/-
`Equivalent` (Row.lean) is used by `NormalizeCorrect.lean` to state that
`normalize` preserves meaning, but had no algebraic lemmas of its own --
this closes the same preorder-to-partial-order gap the `Subset` lemmas
above set up but didn't finish: `Subset.antisymm` is the standard
"mutual Subset implies Equivalent" fact, and needs `Equivalent` to
actually be an equivalence relation to be useful downstream.
-/

/-- `Equivalent` is reflexive: a row always denotes the same operations as itself. -/
theorem Equivalent.refl (row : Normalized) : Equivalent row row :=
  fun _ => Iff.rfl

/-- `Equivalent` is symmetric. -/
theorem Equivalent.symm {left right : Normalized} (h : Equivalent left right) :
    Equivalent right left :=
  fun operation => (h operation).symm

/-- `Equivalent` is transitive. -/
theorem Equivalent.trans {left middle right : Normalized}
    (leftMiddle : Equivalent left middle) (middleRight : Equivalent middle right) :
    Equivalent left right :=
  fun operation => (leftMiddle operation).trans (middleRight operation)

/--
`Subset` is antisymmetric up to `Equivalent`: two rows that each authorize
the other denote the same operation set. This is the standard closing
lemma that promotes the `Subset` preorder (`refl`/`trans` above) to a
partial order, and is exactly what a future row-subsumption proof needs
to conclude two effect rows are interchangeable rather than merely
mutually-authorizing.
-/
theorem Subset.antisymm {left right : Normalized}
    (leftRight : Subset left right) (rightLeft : Subset right left) :
    Equivalent left right :=
  fun operation => ⟨fun membership => leftRight operation membership,
                     fun membership => rightLeft operation membership⟩

/-
`Subset` and `Equivalent` were each closed as their own relations (preorder,
equivalence) by the lemmas above, but nothing connected them: substituting
an equivalent row on either side of a `Subset` fact was not yet provable.
This is exactly the operation a future row-subsumption proof needs when it
normalizes/simplifies one side of a `Subset` obligation (e.g. via
`ClosedRow.normalize_extensional` in `NormalizeCorrect.lean`) and must
carry an existing `Subset` fact across that rewrite.
-/

/-- `Subset`'s left (required) side can be replaced by an equivalent row. -/
theorem Subset.congr_left {left left' declared : Normalized}
    (equiv : Equivalent left left') (subset : Subset left declared) :
    Subset left' declared :=
  fun operation membership => subset operation ((equiv operation).mpr membership)

/-- `Subset`'s right (declared) side can be replaced by an equivalent row. -/
theorem Subset.congr_right {required declared declared' : Normalized}
    (equiv : Equivalent declared declared') (subset : Subset required declared) :
    Subset required declared' :=
  fun operation membership => (equiv operation).mp (subset operation membership)

/-
`Subset.union_left_iff` above already shows `++` decomposes a `Subset`
obligation; `Equivalent` had no matching congruence for `++` at all --
substituting an equivalent row into EITHER side of a union wasn't
provable. This is exactly what's needed to combine two independently-
normalized/simplified rows via union (the `declared = declared ∪ missing`
shape `Subset.union_left_iff`'s own docstring ties to the live checker's
`make_row_mismatch`): if each half is shown equivalent to some simplified
form, the whole union is equivalent to the union of the simplified forms.
-/

/-- `Equivalent` is a congruence for `++` on the left. -/
theorem Equivalent.union_left_congr {left left' right : Normalized}
    (equiv : Equivalent left left') : Equivalent (left ++ right) (left' ++ right) := by
  intro operation
  simp only [List.mem_append]
  constructor
  · rintro (membership | membership)
    · exact Or.inl ((equiv operation).mp membership)
    · exact Or.inr membership
  · rintro (membership | membership)
    · exact Or.inl ((equiv operation).mpr membership)
    · exact Or.inr membership

/-- `Equivalent` is a congruence for `++` on the right. -/
theorem Equivalent.union_right_congr {left right right' : Normalized}
    (equiv : Equivalent right right') : Equivalent (left ++ right) (left ++ right') := by
  intro operation
  simp only [List.mem_append]
  constructor
  · rintro (membership | membership)
    · exact Or.inl membership
    · exact Or.inr ((equiv operation).mp membership)
  · rintro (membership | membership)
    · exact Or.inl membership
    · exact Or.inr ((equiv operation).mpr membership)

/-- `Equivalent` is a congruence for `++` on both sides simultaneously. -/
theorem Equivalent.union_congr {left left' right right' : Normalized}
    (equivLeft : Equivalent left left') (equivRight : Equivalent right right') :
    Equivalent (left ++ right) (left' ++ right') :=
  Equivalent.trans (Equivalent.union_left_congr equivLeft) (Equivalent.union_right_congr equivRight)

end VibeFormal.EffectRow
