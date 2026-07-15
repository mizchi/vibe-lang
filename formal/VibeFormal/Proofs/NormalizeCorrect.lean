import VibeFormal.Effect.Row

set_option autoImplicit false

namespace VibeFormal

/-- Executable normalization agrees with relational row expansion. -/
theorem ClosedRow.normalize_correct
    (row : ClosedRow)
    (operation : OperationRef) :
    operation ∈ EffectRow.normalize row ↔ row.Denotes operation := by
  simp [EffectRow.normalize, EffectRow.normalizeList, ClosedRow.Denotes]

/-- Converting direct operation syntax to a row preserves its list expansion. -/
theorem ClosedRow.expand_ofOperations (operations : List OperationRef) :
    (ClosedRow.ofOperations operations).expand = operations := by
  induction operations with
  | nil => rfl
  | cons operation operations inductionHypothesis =>
      simp [ClosedRow.ofOperations, ClosedRow.expand, inductionHypothesis]

/-- Rows with the same expansion are equal as operation sets. -/
theorem ClosedRow.normalize_extensional
    (left right : ClosedRow)
    (sameMeaning : ∀ operation, left.Denotes operation ↔ right.Denotes operation) :
    EffectRow.Equivalent (EffectRow.normalize left) (EffectRow.normalize right) := by
  intro operation
  rw [ClosedRow.normalize_correct, ClosedRow.normalize_correct]
  exact sameMeaning operation

/-- Duplicate removal preserves extensional equality, independently of order. -/
theorem EffectRow.normalizeList_extensional
    (left right : List OperationRef)
    (sameMembers : ∀ operation, operation ∈ left ↔ operation ∈ right) :
    EffectRow.Equivalent (EffectRow.normalizeList left) (EffectRow.normalizeList right) := by
  intro operation
  simp only [EffectRow.normalizeList, List.mem_eraseDups]
  exact sameMembers operation

/-- Repeating an operation does not change the meaning of a normalized row. -/
theorem EffectRow.normalizeList_duplicate
    (operation : OperationRef)
    (operations : List OperationRef) :
    EffectRow.Equivalent
      (EffectRow.normalizeList (operation :: operation :: operations))
      (EffectRow.normalizeList (operation :: operations)) := by
  apply EffectRow.normalizeList_extensional
  intro candidate
  simp

/-- Reordering operations does not change the meaning of a normalized row. -/
theorem EffectRow.normalizeList_swap
    (left right : OperationRef)
    (operations : List OperationRef) :
    EffectRow.Equivalent
      (EffectRow.normalizeList (left :: right :: operations))
      (EffectRow.normalizeList (right :: left :: operations)) := by
  apply EffectRow.normalizeList_extensional
  intro candidate
  simp only [List.mem_cons]
  constructor
  · intro membership
    rcases membership with equalLeft | equalRight | inOperations
    · exact Or.inr (Or.inl equalLeft)
    · exact Or.inl equalRight
    · exact Or.inr (Or.inr inOperations)
  · intro membership
    rcases membership with equalRight | equalLeft | inOperations
    · exact Or.inr (Or.inl equalRight)
    · exact Or.inl equalLeft
    · exact Or.inr (Or.inr inOperations)

end VibeFormal
