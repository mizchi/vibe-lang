import VibeFormal.Effect.Taxonomy

set_option autoImplicit false

namespace VibeFormal.EffectTaxonomy

theorem entryAdmissibleB_correct (row : Row) :
    Row.entryAdmissibleB row = true ↔ Row.EntryAdmissible row := by
  constructor
  · intro checked requirement membership
    have admitted := List.all_eq_true.mp checked requirement membership
    cases requirement <;> simp_all [Row.entryAdmissibleB]
  · intro admitted
    apply List.all_eq_true.mpr
    intro requirement membership
    cases requirement with
    | capability capabilityRef => rfl
    | algebraic operation =>
        exact False.elim (admitted (.algebraic operation) membership)
    | exception kind => rfl

theorem hostValidB_correct (host : HostProfile) :
    host.validB = true ↔ host.Valid := by
  simp [HostProfile.validB, HostProfile.Valid, List.all_eq_true]

theorem rowSubsetB_correct (required declared : Row) :
    Row.subsetB required declared = true ↔ Row.Subset required declared := by
  simp [Row.subsetB, Row.Subset, List.all_eq_true]

theorem operationResourceFreeB_correct (operation : OperationRef) :
    operation.resourceFreeB = true ↔ operation.ResourceFree := by
  simp only [OperationRef.resourceFreeB, OperationRef.ResourceFree,
    List.all_eq_true]
  constructor
  · intro checked argument membership
    have valid := checked argument membership
    cases argument <;> simp_all
  · intro valid argument membership
    have checked := valid argument membership
    cases argument <;> simp_all

theorem requirementValidB_correct (requirement : Requirement) :
    Row.requirementValidB requirement = true ↔
      Row.RequirementValid requirement := by
  cases requirement with
  | capability capabilityRef =>
      simp [Row.requirementValidB, Row.RequirementValid,
        CapabilityRef.validB, CapabilityRef.Valid]
  | algebraic operation =>
      simpa [Row.requirementValidB, Row.RequirementValid] using
        operationResourceFreeB_correct operation
  | exception kind =>
      simp [Row.requirementValidB, Row.RequirementValid]

theorem wellFormedB_correct (row : Row) :
    Row.wellFormedB row = true ↔ Row.WellFormed row := by
  simp [Row.wellFormedB, Row.WellFormed, List.all_eq_true,
    requirementValidB_correct]

theorem resolvedB_correct
    (requirement : Requirement)
    (host : HostProfile) :
    requirement.resolvedB host = true ↔ requirement.ResolvedBy host := by
  cases requirement <;>
    simp [Requirement.resolvedB, Requirement.ResolvedBy]

theorem forkableB_correct
    (requirement : Requirement)
    (host : HostProfile) :
    requirement.forkableB host = true ↔ requirement.ForkableBy host := by
  cases requirement <;>
    simp [Requirement.forkableB, Requirement.ForkableBy]

theorem runnableB_correct (row : Row) (host : HostProfile) :
    runnableB row host = true ↔ Runnable row host := by
  simp only [runnableB, Runnable, Bool.and_eq_true, entryAdmissibleB_correct,
    hostValidB_correct, List.all_eq_true, resolvedB_correct,
    wellFormedB_correct]
  constructor
  · rintro ⟨⟨⟨admissible, valid⟩, resolved⟩, wellFormed⟩
    exact ⟨admissible, valid, resolved, wellFormed⟩
  · rintro ⟨admissible, valid, resolved, wellFormed⟩
    exact ⟨⟨⟨admissible, valid⟩, resolved⟩, wellFormed⟩

theorem canSpawnB_correct
    (host : HostProfile)
    (parent child : Row) :
    canSpawnB host parent child = true ↔ CanSpawn host parent child := by
  simp only [canSpawnB, CanSpawn, Bool.and_eq_true, rowSubsetB_correct,
    List.all_eq_true, forkableB_correct]

/-- No amount of host provisioning makes an undischarged algebraic effect runnable. -/
theorem runnable_excludes_algebraic
    {row : Row}
    {host : HostProfile}
    {operation : OperationRef}
    (runnable : Runnable row host)
    (present : .algebraic operation ∈ row) :
    False := by
  exact runnable.1 (.algebraic operation) present

/-- Every capability in a runnable entry has an exact host provider. -/
theorem runnable_capability_is_provided
    {row : Row}
    {host : HostProfile}
    {capability : CapabilityRef}
    (runnable : Runnable row host)
    (present : .capability capability ∈ row) :
    capability ∈ host.provides := by
  exact runnable.2.2.1 (.capability capability) present

/-- Every runnable capability carries its logical resource in OperationRef. -/
theorem runnable_capability_has_resource_marker
    {row : Row}
    {host : HostProfile}
    {capability : CapabilityRef}
    (runnable : Runnable row host)
    (present : .capability capability ∈ row) :
    capability.Valid := by
  exact runnable.2.2.2 (.capability capability) present

/-- A well-formed algebraic requirement cannot carry a logical resource marker. -/
theorem wellFormed_algebraic_is_resource_free
    {row : Row}
    {operation : OperationRef}
    (wellFormed : Row.WellFormed row)
    (present : .algebraic operation ∈ row) :
    operation.ResourceFree := by
  exact wellFormed (.algebraic operation) present

/-- An algebraic handler cannot accidentally remove a capability operation. -/
theorem algebraic_discharge_preserves_capability
    (effectDef : EffectDefId)
    (row : Row)
    (capability : CapabilityRef) :
    .capability capability ∈ Row.dischargeAlgebraic effectDef row ↔
      .capability capability ∈ row := by
  simp [Row.dischargeAlgebraic]

/-- An algebraic handler cannot accidentally remove a core exception. -/
theorem algebraic_discharge_preserves_exception
    (effectDef : EffectDefId)
    (row : Row)
    (kind : ExceptionPolicy.ExceptionKind) :
    .exception kind ∈ Row.dischargeAlgebraic effectDef row ↔
      .exception kind ∈ row := by
  simp [Row.dischargeAlgebraic]

/-- An algebraic handler preserves operations from every other effect. -/
theorem algebraic_discharge_preserves_other_effect
    (handledEffect : EffectDefId)
    (operation : OperationRef)
    (different : operation.id.effectDef ≠ handledEffect)
    (row : Row) :
    .algebraic operation ∈ Row.dischargeAlgebraic handledEffect row ↔
      .algebraic operation ∈ row := by
  simp [Row.dischargeAlgebraic, different]

/-- A typed exception handler preserves every different exception kind. -/
theorem exception_discharge_preserves_other_kind
    (handled raised : ExceptionPolicy.ExceptionKind)
    (different : raised ≠ handled)
    (row : Row) :
    .exception raised ∈ Row.dischargeException handled row ↔
      .exception raised ∈ row := by
  simp [Row.dischargeException, different]

/-- A typed exception handler cannot accidentally remove a capability. -/
theorem exception_discharge_preserves_capability
    (handledKind : ExceptionPolicy.ExceptionKind)
    (row : Row)
    (capability : CapabilityRef) :
    .capability capability ∈ Row.dischargeException handledKind row ↔
      .capability capability ∈ row := by
  simp [Row.dischargeException]

/-- A typed exception handler cannot accidentally remove an algebraic effect. -/
theorem exception_discharge_preserves_algebraic
    (handledKind : ExceptionPolicy.ExceptionKind)
    (row : Row)
    (operation : OperationRef) :
    .algebraic operation ∈ Row.dischargeException handledKind row ↔
      .algebraic operation ∈ row := by
  simp [Row.dischargeException]

/-- Spawn authority is always a subset of the parent semantic row. -/
theorem spawn_cannot_amplify_parent
    {host : HostProfile}
    {parent child : Row}
    {requirement : Requirement}
    (spawnable : CanSpawn host parent child)
    (present : requirement ∈ child) :
    requirement ∈ parent :=
  spawnable.1 requirement present

/-- A capability used by a child needs fork-safe host evidence. -/
theorem spawn_capability_is_forkable
    {host : HostProfile}
    {parent child : Row}
    {capability : CapabilityRef}
    (spawnable : CanSpawn host parent child)
    (present : .capability capability ∈ child) :
    capability ∈ host.forkable := by
  exact spawnable.2 (.capability capability) present

/-- Algebraic handler evidence is task-local and is not inherited by default. -/
theorem spawn_rejects_algebraic
    {host : HostProfile}
    {parent child : Row}
    {operation : OperationRef}
    (spawnable : CanSpawn host parent child)
    (present : .algebraic operation ∈ child) :
    False := by
  exact spawnable.2 (.algebraic operation) present

end VibeFormal.EffectTaxonomy
