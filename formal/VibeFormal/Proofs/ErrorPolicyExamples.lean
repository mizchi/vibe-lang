import VibeFormal.Proofs.ErrorPolicyCorrect

set_option autoImplicit false

namespace VibeFormal.ErrorPolicy.Examples

private def fsRead : OperationRef :=
  ⟨⟨⟨"vibe/std", "fs", 0⟩, 0⟩, []⟩

private def ambientCounterexample : Term := .call .throwError

private def checkedMain : Term := .call .throwError

example : Allowed .ambient [] ambientCounterexample := by
  simp [Allowed, requirements, ambientCounterexample]

example : ¬Allowed .checked [] ambientCounterexample := by
  simp [Allowed, requirements, ambientCounterexample]

example : run ambientCounterexample = .raised := by
  rfl

example : ¬Allowed .ambient [] (.perform fsRead) := by
  simp [Allowed, requirements]

example : run (.perform fsRead) = .performed fsRead := by
  rfl

example : Allowed .checked [] (.handleError .throwError) := by
  simp [Allowed, requirements]

example : run (.handleError .throwError) = .returned := by
  rfl

example : Allowed .checked [.error] checkedMain := by
  simp [Allowed, requirements, checkedMain]

example : runEntry checkedMain = .failedWithError := by
  rfl

example : runEntry .returned = .succeeded := by
  rfl

example : BrokenAllowed [] (.perform fsRead) := by
  simp [BrokenAllowed, brokenRequirements]

end VibeFormal.ErrorPolicy.Examples
