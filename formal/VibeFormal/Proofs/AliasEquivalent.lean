import VibeFormal.Proofs.NormalizeCorrect

set_option autoImplicit false

namespace VibeFormal

/-- A resolved effectset is a transparent alias, not a nominal capability. -/
theorem ClosedRow.effectset_transparent (body : ClosedRow) :
    EffectRow.normalize (.effectset body) = EffectRow.normalize body := by
  rfl

/-- Direct operation syntax and an effectset containing it normalize equally. -/
theorem ClosedRow.direct_alias_equivalent (operations : List OperationRef) :
    EffectRow.normalize (.effectset (.ofOperations operations)) =
      EffectRow.normalize (.ofOperations operations) := by
  rfl

/-- Whole-effect shorthand and direct enumeration of its operations agree. -/
theorem ClosedRow.effect_shorthand_equivalent (operations : List OperationRef) :
    EffectRow.normalize (.effect operations) =
      EffectRow.normalize (.ofOperations operations) := by
  simp [EffectRow.normalize, ClosedRow.expand, ClosedRow.expand_ofOperations]

end VibeFormal
