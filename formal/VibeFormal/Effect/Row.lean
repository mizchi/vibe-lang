import VibeFormal.Effect.Id

set_option autoImplicit false

namespace VibeFormal

/--
A resolved, closed row expression. `effectset` is deliberately structural at
this layer: name resolution and cycle rejection happen before this model.
-/
inductive ClosedRow where
  | empty
  | operation (operation : OperationRef)
  | effect (operations : List OperationRef)
  | union (left right : ClosedRow)
  | effectset (body : ClosedRow)
  deriving Repr

namespace ClosedRow

/-- Expand whole-effect shorthand and transparent effectset aliases. -/
def expand : ClosedRow → List OperationRef
  | .empty => []
  | .operation op => [op]
  | .effect operations => operations
  | .union left right => expand left ++ expand right
  | .effectset body => expand body

/-- Build a direct operation row from a list. -/
def ofOperations : List OperationRef → ClosedRow
  | [] => .empty
  | op :: operations => .union (.operation op) (ofOperations operations)

/-- Relational meaning of a resolved row expression. -/
def Denotes (row : ClosedRow) (operation : OperationRef) : Prop :=
  operation ∈ row.expand

end ClosedRow

namespace EffectRow

/-- Executable set representation used by the Phase 1 algorithms. -/
abbrev Normalized := List OperationRef

/-- Remove duplicate operation identities. Order is not semantically relevant. -/
def normalizeList (operations : List OperationRef) : Normalized :=
  operations.eraseDups

/-- Normalize a resolved row expression to its operation set representation. -/
def normalize (row : ClosedRow) : Normalized :=
  normalizeList row.expand

/-- Extensional equality for rows represented as lists. -/
def Equivalent (left right : Normalized) : Prop :=
  ∀ operation, operation ∈ left ↔ operation ∈ right

/-- Mathematical subset relation between operation rows. -/
def Subset (required declared : Normalized) : Prop :=
  ∀ operation, operation ∈ required → operation ∈ declared

/-- Executable checker for `required ⊆ declared`. -/
def subset (required declared : Normalized) : Bool :=
  required.all fun operation => decide (operation ∈ declared)

end EffectRow

end VibeFormal
