import VibeFormal.Capability.TaxonomyBridge
import VibeFormal.Proofs.CapabilityContractCorrect
import VibeFormal.Proofs.EffectTaxonomyCorrect

set_option autoImplicit false

namespace VibeFormal.EffectTaxonomy.Bridge

theorem mem_capabilities
    {row : EffectTaxonomy.Row}
    {capabilityRef : EffectTaxonomy.CapabilityRef} :
    capabilityRef ∈ EffectTaxonomy.Row.capabilities row ↔
      .capability capabilityRef ∈ row := by
  constructor
  · intro membership
    rw [EffectTaxonomy.Row.capabilities, List.mem_filterMap] at membership
    obtain ⟨requirement, present, mapped⟩ := membership
    cases requirement with
    | capability candidate =>
        cases mapped
        exact present
    | algebraic operation =>
        simp at mapped
    | exception kind =>
        simp at mapped
  · intro membership
    rw [EffectTaxonomy.Row.capabilities, List.mem_filterMap]
    exact ⟨.capability capabilityRef, membership, rfl⟩

theorem mem_projectAuthority
    {row : EffectTaxonomy.Row}
    {operation : OperationRef} :
    operation ∈ projectAuthority row ↔
      ∃ capabilityRef,
        .capability capabilityRef ∈ row ∧
          capabilityRef.operation = operation := by
  simp [projectAuthority, mem_capabilities]

theorem mem_projectClaims
    {row : EffectTaxonomy.Row}
    {claim : Capability.ResourceClaim} :
    claim ∈ projectClaims row ↔
      ∃ capabilityRef,
        .capability capabilityRef ∈ row ∧
          capabilityRef.claim = claim := by
  simp [projectClaims, mem_capabilities]

/--
Taxonomy admission is checked before capability projection. Once the complete
row and its child delegation pass, the projected ADR-0075 entry contract and
host profile pass their existing preflight relation.
-/
theorem runnable_refines_capability_contract
    {row forkRow : EffectTaxonomy.Row}
    {host : EffectTaxonomy.HostProfile}
    (runnable : EffectTaxonomy.Runnable row host)
    (spawnable : EffectTaxonomy.CanSpawn host row forkRow) :
    Capability.Runnable
      (toEntryContract row forkRow)
      (toHostProfile host) := by
  refine ⟨?_, ?_, ?_, ?_, ?_⟩
  · change EffectRow.Subset
      (projectAuthority forkRow)
      (projectAuthority row)
    intro operation membership
    obtain ⟨capabilityRef, present, rfl⟩ :=
      mem_projectAuthority.mp membership
    exact mem_projectAuthority.mpr
      ⟨capabilityRef, spawnable.1 (.capability capabilityRef) present, rfl⟩
  · change EffectRow.Subset
      (host.forkable.map fun capabilityRef => capabilityRef.operation)
      (host.provides.map fun capabilityRef => capabilityRef.operation)
    intro operation membership
    obtain ⟨capabilityRef, present, rfl⟩ := List.mem_map.mp membership
    exact List.mem_map.mpr
      ⟨capabilityRef, runnable.2.1 capabilityRef present, rfl⟩
  · change EffectRow.Subset
      (projectAuthority row)
      (host.provides.map fun capabilityRef => capabilityRef.operation)
    intro operation membership
    obtain ⟨capabilityRef, present, rfl⟩ :=
      mem_projectAuthority.mp membership
    exact List.mem_map.mpr
      ⟨capabilityRef,
        runnable.2.2.1 (.capability capabilityRef) present,
        rfl⟩
  · change EffectRow.Subset
      (projectAuthority forkRow)
      (host.forkable.map fun capabilityRef => capabilityRef.operation)
    intro operation membership
    obtain ⟨capabilityRef, present, rfl⟩ :=
      mem_projectAuthority.mp membership
    exact List.mem_map.mpr
      ⟨capabilityRef,
        spawnable.2 (.capability capabilityRef) present,
        rfl⟩
  · change Capability.BindingsSatisfy
      (projectClaims row)
      (host.provides.map fun capabilityRef => capabilityRef.binding)
    intro claim membership
    obtain ⟨capabilityRef, present, rfl⟩ :=
      mem_projectClaims.mp membership
    have provided : capabilityRef ∈ host.provides :=
      runnable.2.2.1 (.capability capabilityRef) present
    refine ⟨capabilityRef.binding, ?_, ?_⟩
    · exact List.mem_map.mpr ⟨capabilityRef, provided, rfl⟩
    · simp [CapabilityRef.binding, CapabilityRef.claim,
        Capability.ResourceBinding.Matches]

/-- The same refinement holds for the executable checker composition. -/
theorem runnableB_refines_capability_contract
    {row forkRow : EffectTaxonomy.Row}
    {host : EffectTaxonomy.HostProfile}
    (runnable : EffectTaxonomy.runnableB row host = true)
    (spawnable : EffectTaxonomy.canSpawnB host row forkRow = true) :
    (toEntryContract row forkRow).runnable (toHostProfile host) = true := by
  apply (Capability.runnable_correct
    (toEntryContract row forkRow)
    (toHostProfile host)).mpr
  apply runnable_refines_capability_contract
  · exact (EffectTaxonomy.runnableB_correct row host).mp runnable
  · exact (EffectTaxonomy.canSpawnB_correct host row forkRow).mp spawnable

end VibeFormal.EffectTaxonomy.Bridge
