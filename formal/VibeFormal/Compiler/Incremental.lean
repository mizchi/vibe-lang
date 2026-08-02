import Std

set_option autoImplicit false

namespace VibeFormal.Compiler

universe u v

variable {ModuleId : Type u}
variable {Fingerprint : Type v}

/--
An abstract compiler snapshot with independent public-interface and
implementation identities. Dependencies point from a consumer to its direct
imports. Fingerprint soundness is an assumption of this model, not proved here.
-/
structure IncrementalSnapshot (ModuleId : Type u) (Fingerprint : Type v) where
  interfaceIdentity : ModuleId → Fingerprint
  implementationIdentity : ModuleId → Fingerprint
  dependencies : ModuleId → List ModuleId

/-- A public contract changed between two snapshots. -/
def InterfaceChanged
    (before after : IncrementalSnapshot ModuleId Fingerprint)
    (moduleId : ModuleId) : Prop :=
  before.interfaceIdentity moduleId ≠ after.interfaceIdentity moduleId

/-- An implementation changed while its public contract remained stable. -/
def ImplementationOnlyChanged
    (before after : IncrementalSnapshot ModuleId Fingerprint)
    (moduleId : ModuleId) : Prop :=
  before.implementationIdentity moduleId ≠ after.implementationIdentity moduleId ∧
    before.interfaceIdentity moduleId = after.interfaceIdentity moduleId

/-- Import resolution or the direct dependency plan changed for this owner. -/
def DependencyPlanChanged
    (before after : IncrementalSnapshot ModuleId Fingerprint)
    (moduleId : ModuleId) : Prop :=
  before.dependencies moduleId ≠ after.dependencies moduleId

/--
An edge present in either snapshot. Using the union is conservative for both
added and removed imports while moving from `before` to `after`.
-/
def DependencyEdge
    (before after : IncrementalSnapshot ModuleId Fingerprint)
    (consumer dependency : ModuleId) : Prop :=
  dependency ∈ before.dependencies consumer ∨
    dependency ∈ after.dependencies consumer

/-- The reverse transitive closure through the union dependency graph. -/
inductive ReverseClosure
    (before after : IncrementalSnapshot ModuleId Fingerprint)
    (changed : ModuleId) : ModuleId → Prop where
  | owner : ReverseClosure before after changed changed
  | consumer {dependency consumer : ModuleId} :
      ReverseClosure before after changed dependency →
      DependencyEdge before after consumer dependency →
      ReverseClosure before after changed consumer

/-- Interface changes invalidate the owner and every reverse-dependent consumer. -/
def InterfaceInvalidated
    (before after : IncrementalSnapshot ModuleId Fingerprint)
    (moduleId : ModuleId) : Prop :=
  ∃ changed, InterfaceChanged before after changed ∧
    ReverseClosure before after changed moduleId

/--
A local typing assumption changed: the owner's import plan, its own interface,
or one of its direct imported interfaces differs.
-/
def TypingAssumptionChanged
    (before after : IncrementalSnapshot ModuleId Fingerprint)
    (moduleId : ModuleId) : Prop :=
  DependencyPlanChanged before after moduleId ∨
    InterfaceChanged before after moduleId ∨
    ∃ dependency,
      DependencyEdge before after moduleId dependency ∧
      InterfaceChanged before after dependency

/--
Relational specification for typing invalidation. Interface changes propagate
through the complete reverse closure; implementation-only and import-plan
changes invalidate their owner. This is not yet an executable planner.
-/
def TypingInvalidated
    (before after : IncrementalSnapshot ModuleId Fingerprint)
    (moduleId : ModuleId) : Prop :=
  InterfaceInvalidated before after moduleId ∨
    ImplementationOnlyChanged before after moduleId ∨
    DependencyPlanChanged before after moduleId

/--
The fingerprint assumptions recorded by a typing cache entry. This model does
not contain a typing derivation; matching these values is cache-key eligibility,
not by itself a proof of language-level type soundness.
-/
structure TypingCacheEntry (ModuleId : Type u) (Fingerprint : Type v) where
  owner : ModuleId
  ownerInterface : Fingerprint
  ownerDependencies : List ModuleId
  dependencyInterfaces : ModuleId → Fingerprint

/-- Every interface/import assumption recorded by the cache entry still matches. -/
def TypingCacheAssumptionsMatch
    (snapshot : IncrementalSnapshot ModuleId Fingerprint)
    (entry : TypingCacheEntry ModuleId Fingerprint) : Prop :=
  entry.ownerInterface = snapshot.interfaceIdentity entry.owner ∧
    entry.ownerDependencies = snapshot.dependencies entry.owner ∧
    ∀ dependency, dependency ∈ entry.ownerDependencies →
      entry.dependencyInterfaces dependency = snapshot.interfaceIdentity dependency

/--
A final artifact records only the implementation identities it embeds or links.
Unrelated modules are represented by `none` and do not affect freshness.
-/
structure ArtifactCacheEntry (ModuleId : Type u) (Fingerprint : Type v) where
  recordedImplementations : ModuleId → Option Fingerprint

/-- Every implementation identity recorded by this artifact matches the snapshot. -/
def ArtifactFresh
    (snapshot : IncrementalSnapshot ModuleId Fingerprint)
    (entry : ArtifactCacheEntry ModuleId Fingerprint) : Prop :=
  ∀ moduleId fingerprint,
    entry.recordedImplementations moduleId = some fingerprint →
    snapshot.implementationIdentity moduleId = fingerprint

end VibeFormal.Compiler
