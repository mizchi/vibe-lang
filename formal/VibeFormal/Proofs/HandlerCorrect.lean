import VibeFormal.Effect.Handler

set_option autoImplicit false

namespace VibeFormal.EffectRow

/-- Discharge removes an operation iff it belongs to the handled effect. -/
theorem mem_discharge_iff
    (effectDef : EffectDefId)
    (body : Normalized)
    (operation : OperationRef) :
    operation ∈ discharge effectDef body ↔
      operation ∈ body ∧ ¬operation.belongsTo effectDef := by
  simp [discharge, OperationRef.belongsTo]

/--
A handler removes matching body requirements and preserves all arm
requirements, including requirements for the same effect.
-/
theorem handleResult_correct
    (effectDef : EffectDefId)
    (body armRequirements : Normalized)
    (operation : OperationRef) :
    operation ∈ handleResult effectDef body armRequirements ↔
      (operation ∈ body ∧ ¬operation.belongsTo effectDef) ∨
        operation ∈ armRequirements := by
  simp [handleResult, normalizeList, discharge, OperationRef.belongsTo]

end VibeFormal.EffectRow
