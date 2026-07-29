import VibeFormal.Effect.Taxonomy

set_option autoImplicit false

namespace VibeFormal.OperationRef

def resourceIds (operation : OperationRef) : List Capability.ResourceId :=
  operation.arguments.filterMap fun argument =>
    match argument with
    | .resourceId id => some ⟨id⟩
    | .typeId _ => none
    | .regionId _ => none

/-- Classification accepts a capability operation with exactly one resource. -/
def uniqueResourceId? (operation : OperationRef) : Option Capability.ResourceId :=
  match operation.resourceIds with
  | [resource] => some resource
  | _ => none

/-- `Exception[E]` has exactly one normalized type argument in this model. -/
def exceptionKind? (operation : OperationRef) :
    Option ExceptionPolicy.ExceptionKind :=
  match operation.arguments with
  | [.typeId kind] => some kind
  | _ => none

end VibeFormal.OperationRef

namespace VibeFormal.EffectTaxonomy.Classifier

/-- Resolved declaration metadata introduced by ADR-0084. -/
inductive EffectClass where
  | capability (resourceKind : Capability.ResourceKind)
  | algebraic
  | coreException
  deriving DecidableEq, Repr

structure Metadata where
  effectDef : EffectDefId
  effectClass : EffectClass
  deriving DecidableEq, Repr

abbrev Catalog := List Metadata

namespace Catalog

/--
Unknown and duplicate declaration identities both fail closed. Name resolution
must produce exactly one class before an operation can enter a semantic row.
-/
def lookupUnique
    (catalog : Catalog)
    (effectDef : EffectDefId) : Option EffectClass :=
  match catalog.filter fun metadata => decide (metadata.effectDef = effectDef) with
  | [metadata] => some metadata.effectClass
  | _ => none

end Catalog

/--
Classify one fully-resolved operation. Resource-bearing algebraic operations,
capabilities without exactly one resource id, malformed core exceptions, and
unknown/ambiguous metadata are rejected.
-/
def classifyOperation
    (catalog : Catalog)
    (operation : OperationRef) : Option Requirement :=
  match catalog.lookupUnique operation.id.effectDef with
  | some (.capability resourceKind) =>
      match operation.uniqueResourceId? with
      | some resource =>
          some (.capability {
            operation
            resourceKind
            resource
          })
      | none => none
  | some .algebraic =>
      if operation.resourceFreeB then some (.algebraic operation) else none
  | some .coreException =>
      match operation.exceptionKind? with
      | some kind => some (.exception kind)
      | none => none
  | none => none

/-- Declarative meaning of one successful metadata-driven classification. -/
inductive Classifies
    (catalog : Catalog)
    (operation : OperationRef) : Requirement → Prop where
  | capability
      (resourceKind : Capability.ResourceKind)
      (resource : Capability.ResourceId)
      (classFound :
        catalog.lookupUnique operation.id.effectDef =
          some (.capability resourceKind))
      (resourceFound : operation.uniqueResourceId? = some resource) :
      Classifies catalog operation (.capability {
        operation
        resourceKind
        resource
      })
  | algebraic
      (classFound :
        catalog.lookupUnique operation.id.effectDef = some .algebraic)
      (resourceFree : operation.ResourceFree) :
      Classifies catalog operation (.algebraic operation)
  | coreException
      (kind : ExceptionPolicy.ExceptionKind)
      (classFound :
        catalog.lookupUnique operation.id.effectDef = some .coreException)
      (argumentShape : operation.arguments = [.typeId kind]) :
      Classifies catalog operation (.exception kind)

/--
All-or-nothing row classification. A missing or malformed metadata entry
rejects the complete row instead of silently dropping one operation.
-/
def classifyRow
    (catalog : Catalog) : List OperationRef → Option Row
  | [] => some []
  | operation :: operations =>
      match classifyOperation catalog operation with
      | none => none
      | some requirement =>
          match classifyRow catalog operations with
          | none => none
          | some row => some (requirement :: row)

end VibeFormal.EffectTaxonomy.Classifier
