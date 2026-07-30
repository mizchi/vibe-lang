import VibeFormal.Capability.Contract
import VibeFormal.Effect.ExceptionPolicy

set_option autoImplicit false

namespace VibeFormal

namespace OperationRef

def ResourceFree (operation : OperationRef) : Prop :=
  ∀ argument, argument ∈ operation.arguments →
    match argument with
    | .resourceId _ => False
    | .typeId _ => True
    | .regionId _ => True

def resourceFreeB (operation : OperationRef) : Bool :=
  operation.arguments.all fun argument =>
    match argument with
    | .resourceId _ => false
    | .typeId _ => true
    | .regionId _ => true

end OperationRef

namespace EffectTaxonomy

/--
A capability operation carries both a logical resource identity and its kind.
The marker is structural: algebraic operations have no such fields.
-/
structure CapabilityRef where
  operation : OperationRef
  resourceKind : Capability.ResourceKind
  resource : Capability.ResourceId
  deriving DecidableEq, Repr

/-- The logical resource marker is retained in the normalized operation. -/
def CapabilityRef.Valid (capabilityRef : CapabilityRef) : Prop :=
  .resourceId capabilityRef.resource.value ∈ capabilityRef.operation.arguments

def CapabilityRef.validB (capabilityRef : CapabilityRef) : Bool :=
  decide (.resourceId capabilityRef.resource.value ∈
    capabilityRef.operation.arguments)

/--
The three semantic categories from ADR-0084. Keeping them as a disjoint sum
prevents a host capability from being mistaken for an in-process handler and
prevents either from being mistaken for a language-reserved exception.
-/
inductive Requirement where
  | capability (capability : CapabilityRef)
  | algebraic (operation : OperationRef)
  | exception (kind : ExceptionPolicy.ExceptionKind)
  deriving DecidableEq, Repr

/-- A normalized semantic row at the taxonomy layer. -/
abbrev Row := List Requirement

namespace Row

def normalize (row : Row) : Row :=
  row.eraseDups

def RequirementValid : Requirement → Prop
  | .capability capabilityRef => capabilityRef.Valid
  | .algebraic operation => operation.ResourceFree
  | .exception _ => True

def requirementValidB : Requirement → Bool
  | .capability capabilityRef => capabilityRef.validB
  | .algebraic operation => operation.resourceFreeB
  | .exception _ => true

def WellFormed (row : Row) : Prop :=
  ∀ requirement, requirement ∈ row → RequirementValid requirement

def wellFormedB (row : Row) : Bool :=
  row.all requirementValidB

def Subset (required declared : Row) : Prop :=
  ∀ requirement, requirement ∈ required → requirement ∈ declared

def subsetB (required declared : Row) : Bool :=
  required.all fun requirement => decide (requirement ∈ declared)

/--
Only capability and core ambient requirements may remain at `.vibex main`.
Ordinary algebraic effects must have been discharged in-process.
-/
def EntryAdmissible (row : Row) : Prop :=
  ∀ requirement, requirement ∈ row →
    match requirement with
    | .capability _ => True
    | .algebraic _ => False
    | .exception _ => True

def entryAdmissibleB (row : Row) : Bool :=
  row.all fun requirement =>
    match requirement with
    | .capability _ => true
    | .algebraic _ => false
    | .exception _ => true

/-- Discharge only algebraic operations from the named effect declaration. -/
def dischargeAlgebraic (effectDef : EffectDefId) (row : Row) : Row :=
  row.filter fun requirement =>
    match requirement with
    | .algebraic operation => decide (operation.id.effectDef ≠ effectDef)
    | .capability _ => true
    | .exception _ => true

/-- Discharge only the exact typed exception kind named by the handler. -/
def dischargeException
    (handledKind : ExceptionPolicy.ExceptionKind)
    (row : Row) : Row :=
  row.filter fun requirement =>
    match requirement with
    | .exception raisedKind => decide (raisedKind ≠ handledKind)
    | .capability _ => true
    | .algebraic _ => true

def capabilities (row : Row) : List CapabilityRef :=
  row.filterMap fun requirement =>
    match requirement with
    | .capability capabilityRef => some capabilityRef
    | .algebraic _ => none
    | .exception _ => none

end Row

/-- Runtime/provider capabilities available after composition. -/
structure HostProfile where
  provides : List CapabilityRef
  forkable : List CapabilityRef
  deriving Repr

def HostProfile.Valid (host : HostProfile) : Prop :=
  ∀ capability, capability ∈ host.forkable → capability ∈ host.provides

def HostProfile.validB (host : HostProfile) : Bool :=
  host.forkable.all fun capability => decide (capability ∈ host.provides)

/--
Host resolution is category-sensitive. Core exceptions are handled by the
language runtime, capabilities require an exact provider, and algebraic
effects cannot be resolved by host provisioning.
-/
def Requirement.ResolvedBy
    (requirement : Requirement)
    (host : HostProfile) : Prop :=
  match requirement with
  | .capability capabilityRef => capabilityRef ∈ host.provides
  | .algebraic _ => False
  | .exception _ => True

def Requirement.resolvedB
    (requirement : Requirement)
    (host : HostProfile) : Bool :=
  match requirement with
  | .capability capabilityRef => decide (capabilityRef ∈ host.provides)
  | .algebraic _ => false
  | .exception _ => true

def Runnable (row : Row) (host : HostProfile) : Prop :=
  Row.EntryAdmissible row ∧
    host.Valid ∧
    (∀ requirement, requirement ∈ row → requirement.ResolvedBy host) ∧
    Row.WellFormed row

def runnableB (row : Row) (host : HostProfile) : Bool :=
  Row.entryAdmissibleB row &&
    host.validB &&
    (row.all fun requirement => requirement.resolvedB host) &&
    Row.wellFormedB row

/--
Spawn is narrowing over the complete semantic row. Capability evidence must
also be fork-safe; core exceptions are runtime-owned; algebraic evidence is
task-local and therefore rejected by the default transfer rule.
-/
def Requirement.ForkableBy
    (requirement : Requirement)
    (host : HostProfile) : Prop :=
  match requirement with
  | .capability capabilityRef => capabilityRef ∈ host.forkable
  | .algebraic _ => False
  | .exception _ => True

def Requirement.forkableB
    (requirement : Requirement)
    (host : HostProfile) : Bool :=
  match requirement with
  | .capability capabilityRef => decide (capabilityRef ∈ host.forkable)
  | .algebraic _ => false
  | .exception _ => true

def CanSpawn
    (host : HostProfile)
    (parent child : Row) : Prop :=
  Row.Subset child parent ∧
    ∀ requirement, requirement ∈ child → requirement.ForkableBy host

def canSpawnB
    (host : HostProfile)
    (parent child : Row) : Bool :=
  Row.subsetB child parent &&
    child.all fun requirement => requirement.forkableB host

end VibeFormal.EffectTaxonomy
