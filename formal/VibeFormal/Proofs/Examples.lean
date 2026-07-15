import VibeFormal.Proofs.NormalizeCorrect
import VibeFormal.Proofs.SubsetCorrect
import VibeFormal.Proofs.HandlerCorrect
import VibeFormal.Proofs.AliasEquivalent

set_option autoImplicit false

namespace VibeFormal.Examples

private def envEffect : EffectDefId := ⟨"vibe/std", "env", 0⟩
private def envGet : OperationRef := ⟨⟨envEffect, 0⟩, []⟩
private def envSet : OperationRef := ⟨⟨envEffect, 3⟩, []⟩

example : EffectRow.subset [envGet] [envGet, envSet] = true := by
  decide

example : EffectRow.subset [envSet] [envGet] = false := by
  decide

example : envGet ∉ EffectRow.handleResult envEffect [envGet, envSet] [] := by
  decide

example : envSet ∈ EffectRow.handleResult envEffect [envGet, envSet] [envSet] := by
  decide

private def stateEffect : EffectDefId := ⟨"app", "state", 0⟩
private def stateGetInt : OperationRef :=
  ⟨⟨stateEffect, 0⟩, [.typeId 0]⟩
private def stateGetString : OperationRef :=
  ⟨⟨stateEffect, 0⟩, [.typeId 1]⟩

example : stateGetInt ≠ stateGetString := by
  decide

private def otherEnvGet : OperationRef :=
  ⟨⟨⟨"other/package", "env", 0⟩, 0⟩, []⟩

example : envGet ≠ otherEnvGet := by
  decide

end VibeFormal.Examples
