import VibeFormal.Effect.Row

set_option autoImplicit false

namespace VibeFormal.Capability

/-- An authority is the normalized set of semantic operations it may perform. -/
abbrev Authority := EffectRow.Normalized

/-- A stable logical resource name from a `.vibex` source contract. -/
structure ResourceId where
  value : Nat
  deriving DecidableEq, Repr

/-- The nominal type of a logical resource, such as `S3::Bucket`. -/
structure ResourceKind where
  value : Nat
  deriving DecidableEq, Repr

/-- A source-level requirement for one logical resource instance. -/
structure ResourceClaim where
  resource : ResourceId
  kind : ResourceKind
  deriving DecidableEq, Repr

/-- A deployment-time binding from a logical resource to a matching host slot. -/
structure ResourceBinding where
  resource : ResourceId
  kind : ResourceKind
  deriving DecidableEq, Repr

def ResourceBinding.Matches
    (binding : ResourceBinding)
    (claim : ResourceClaim) : Prop :=
  binding.resource = claim.resource ∧ binding.kind = claim.kind

def ResourceBinding.matches
    (binding : ResourceBinding)
    (claim : ResourceClaim) : Bool :=
  decide (binding.resource = claim.resource) &&
    decide (binding.kind = claim.kind)

/-- Every logical resource claim has a binding of the same identity and kind. -/
def BindingsSatisfy
    (claims : List ResourceClaim)
    (bindings : List ResourceBinding) : Prop :=
  ∀ claim, claim ∈ claims → ∃ binding, binding ∈ bindings ∧ binding.Matches claim

/-- Executable deployment-binding check used by an Oracle or preflight. -/
def bindingsSatisfy
    (claims : List ResourceClaim)
    (bindings : List ResourceBinding) : Bool :=
  claims.all fun claim => bindings.any fun binding => binding.matches claim

/--
The source contract of an executable. `forkRequires` is the subset used from
spawned tasks or processes and therefore needs fork-safe evidence.
-/
structure EntryContract where
  requires : Authority
  forkRequires : Authority
  resources : List ResourceClaim
  deriving Repr

def EntryContract.Valid (contract : EntryContract) : Prop :=
  EffectRow.Subset contract.forkRequires contract.requires

def EntryContract.valid (contract : EntryContract) : Bool :=
  EffectRow.subset contract.forkRequires contract.requires

/--
Semantic capabilities available after provider composition. Primitive WIT
imports may be smaller or lower-level; they are a separate residual contract.
-/
structure HostProfile where
  provides : Authority
  forkable : Authority
  bindings : List ResourceBinding
  deriving Repr

def HostProfile.Valid (host : HostProfile) : Prop :=
  EffectRow.Subset host.forkable host.provides

def HostProfile.valid (host : HostProfile) : Bool :=
  EffectRow.subset host.forkable host.provides

def Runnable (contract : EntryContract) (host : HostProfile) : Prop :=
  contract.Valid ∧
    host.Valid ∧
    EffectRow.Subset contract.requires host.provides ∧
    EffectRow.Subset contract.forkRequires host.forkable ∧
    BindingsSatisfy contract.resources host.bindings

/-- `main` preflight: all authority and resource requirements must be present. -/
def EntryContract.runnable
    (contract : EntryContract)
    (host : HostProfile) : Bool :=
  contract.valid &&
    host.valid &&
    EffectRow.subset contract.requires host.provides &&
    EffectRow.subset contract.forkRequires host.forkable &&
    bindingsSatisfy contract.resources host.bindings

/--
A provider interprets high-level semantic operations using lower-level
operations. This is deliberately not an effect-subtyping declaration.
-/
structure Provider where
  handles : Authority
  requires : Authority
  deriving Repr

def Provider.lower
    (provider : Provider)
    (outstanding : Authority) : Authority :=
  EffectRow.normalizeList
    (outstanding.filter (fun operation => decide (operation ∉ provider.handles)) ++
      provider.requires)

def lowerAll (outstanding : Authority) : List Provider → Authority
  | [] => outstanding
  | provider :: providers => lowerAll (provider.lower outstanding) providers

/--
Spawn/process delegation is narrowing: a child may use only authority held by
its parent and backed by fork-safe host evidence.
-/
def CanSpawn
    (host : HostProfile)
    (parent child : Authority) : Prop :=
  EffectRow.Subset child parent ∧ EffectRow.Subset child host.forkable

def canSpawn
    (host : HostProfile)
    (parent child : Authority) : Bool :=
  EffectRow.subset child parent && EffectRow.subset child host.forkable

end VibeFormal.Capability
