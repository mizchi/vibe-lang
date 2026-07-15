import Std

set_option autoImplicit false

namespace VibeFormal

/--
The stable identity of an effect declaration. Names shown to users are not
identities: the package, module, and definition index all participate.
-/
structure EffectDefId where
  packageName : String
  moduleName : String
  definitionIndex : Nat
  deriving DecidableEq, Repr

/-- The identity of one operation within an effect declaration. -/
structure OperationId where
  effectDef : EffectDefId
  operationIndex : Nat
  deriving DecidableEq, Repr

/--
Normalized arguments retained by an instantiated generic effect. Phase 1
models resolved type and region identities as natural-number atoms.
-/
inductive EffectArgument where
  | typeId (id : Nat)
  | regionId (id : Nat)
  deriving DecidableEq, Repr

/-- A fully resolved operation reference, as specified by ADR-0071. -/
structure OperationRef where
  id : OperationId
  arguments : List EffectArgument
  deriving DecidableEq, Repr

instance : BEq OperationRef :=
  ⟨fun left right => decide (left = right)⟩

instance : LawfulBEq OperationRef where
  rfl := by
    intro operation
    simp
  eq_of_beq := by
    intro left right equal
    exact of_decide_eq_true equal

/-- Whether an operation belongs to a particular effect declaration. -/
def OperationRef.belongsTo (operation : OperationRef) (effectDef : EffectDefId) : Prop :=
  operation.id.effectDef = effectDef

end VibeFormal
