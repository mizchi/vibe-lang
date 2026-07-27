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

end VibeFormal.EffectRow
