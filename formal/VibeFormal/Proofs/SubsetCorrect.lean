import VibeFormal.Effect.Row

set_option autoImplicit false

namespace VibeFormal.EffectRow

/-- The executable row-subset checker decides mathematical set inclusion. -/
theorem subset_correct (required declared : Normalized) :
    subset required declared = true ↔ Subset required declared := by
  simp [subset, Subset, List.all_eq_true]

end VibeFormal.EffectRow
