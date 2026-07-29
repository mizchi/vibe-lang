import VibeFormal.Effect.Taxonomy

set_option autoImplicit false

namespace VibeFormal.EffectTaxonomy

namespace CapabilityRef

/-- Project the taxonomy marker to ADR-0075's separate resource claim. -/
def claim (capabilityRef : CapabilityRef) : Capability.ResourceClaim :=
  { resource := capabilityRef.resource
    kind := capabilityRef.resourceKind }

/-- A provided exact capability carries the matching deployment binding. -/
def binding (capabilityRef : CapabilityRef) : Capability.ResourceBinding :=
  { resource := capabilityRef.resource
    kind := capabilityRef.resourceKind }

end CapabilityRef

namespace Bridge

/--
Project only host-resolved capability operations to ADR-0075 authority.
Algebraic effects must be rejected before this intentionally lossy boundary;
core exceptions remain owned by the language runtime.
-/
def projectAuthority (row : Row) : Capability.Authority :=
  (Row.capabilities row).map fun capabilityRef => capabilityRef.operation

def projectClaims (row : Row) : List Capability.ResourceClaim :=
  (Row.capabilities row).map fun capabilityRef => capabilityRef.claim

def toEntryContract
    (row forkRow : Row) : Capability.EntryContract :=
  { requires := projectAuthority row
    forkRequires := projectAuthority forkRow
    resources := projectClaims row }

def toHostProfile
    (host : HostProfile) : Capability.HostProfile :=
  { provides := host.provides.map fun capabilityRef => capabilityRef.operation
    forkable := host.forkable.map fun capabilityRef => capabilityRef.operation
    bindings := host.provides.map fun capabilityRef => capabilityRef.binding }

end Bridge

end VibeFormal.EffectTaxonomy
