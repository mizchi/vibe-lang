import VibeFormal.Capability.Thread
import VibeFormal.Proofs.SubsetCorrect

set_option autoImplicit false

namespace VibeFormal.Capability

theorem bindingsSatisfy_correct
    (claims : List ResourceClaim)
    (bindings : List ResourceBinding) :
    bindingsSatisfy claims bindings = true ↔ BindingsSatisfy claims bindings := by
  simp [bindingsSatisfy, BindingsSatisfy, ResourceBinding.matches,
    ResourceBinding.Matches, List.all_eq_true]

theorem runnable_correct (contract : EntryContract) (host : HostProfile) :
    contract.runnable host = true ↔ Runnable contract host := by
  simp only [EntryContract.runnable, Runnable, EntryContract.valid,
    EntryContract.Valid, HostProfile.valid, HostProfile.Valid,
    Bool.and_eq_true, EffectRow.subset_correct, bindingsSatisfy_correct]
  constructor
  · rintro ⟨⟨⟨⟨contractValid, hostValid⟩, requirements⟩, forkRequirements⟩,
      resources⟩
    exact ⟨contractValid, hostValid, requirements, forkRequirements, resources⟩
  · rintro ⟨contractValid, hostValid, requirements, forkRequirements, resources⟩
    exact ⟨⟨⟨⟨contractValid, hostValid⟩, requirements⟩, forkRequirements⟩,
      resources⟩

theorem canSpawn_correct
    (host : HostProfile)
    (parent child : Authority) :
    canSpawn host parent child = true ↔ CanSpawn host parent child := by
  simp [canSpawn, CanSpawn, EffectRow.subset_correct]

theorem subset_trans
    {first second third : Authority}
    (firstSecond : EffectRow.Subset first second)
    (secondThird : EffectRow.Subset second third) :
    EffectRow.Subset first third := by
  intro operation membership
  exact secondThird operation (firstSecond operation membership)

/-- Successful preflight accounts for every semantic operation before `main`. -/
theorem runnable_requirements_provided
    {contract : EntryContract}
    {host : HostProfile}
    (runnable : Runnable contract host) :
    EffectRow.Subset contract.requires host.provides :=
  runnable.2.2.1

/-- An absent semantic operation makes the executable non-runnable. -/
theorem missing_requirement_prevents_start
    {contract : EntryContract}
    {host : HostProfile}
    {operation : OperationRef}
    (required : operation ∈ contract.requires)
    (missing : operation ∉ host.provides) :
    ¬Runnable contract host := by
  intro runnable
  exact missing (runnable_requirements_provided runnable operation required)

/-- A missing or wrong-kind logical resource binding also prevents `main`. -/
theorem missing_resource_prevents_start
    {contract : EntryContract}
    {host : HostProfile}
    {claim : ResourceClaim}
    (required : claim ∈ contract.resources)
    (missing :
      ∀ binding, binding ∈ host.bindings → ¬binding.Matches claim) :
    ¬Runnable contract host := by
  intro runnable
  obtain ⟨binding, present, bindingMatches⟩ :=
    runnable.2.2.2.2 claim required
  exact missing binding present bindingMatches

/-- Child authority cannot exceed the host through transitive delegation. -/
theorem spawned_child_within_host
    {host : HostProfile}
    {parent child : Authority}
    (parentWithinHost : EffectRow.Subset parent host.provides)
    (spawnable : CanSpawn host parent child) :
    EffectRow.Subset child host.provides :=
  subset_trans spawnable.1 parentWithinHost

/-- A child cannot acquire an operation absent from its parent. -/
theorem spawn_cannot_amplify_parent
    {host : HostProfile}
    {parent child : Authority}
    {operation : OperationRef}
    (spawnable : CanSpawn host parent child)
    (childUses : operation ∈ child) :
    operation ∈ parent :=
  spawnable.1 operation childUses

/-- Provider lowering accounts for either an unhandled source op or a dependency. -/
theorem Provider.mem_lower_iff
    (provider : Provider)
    (outstanding : Authority)
    (operation : OperationRef) :
    operation ∈ provider.lower outstanding ↔
      (operation ∈ outstanding ∧ operation ∉ provider.handles) ∨
        operation ∈ provider.requires := by
  simp [Provider.lower, EffectRow.normalizeList]

/-- Any operation exercised by a physical worker is provided by the root host. -/
theorem worker_permission_within_host
    {WorkerId TaskId NurseryId WaitKey Failure : Type}
    {machine : Parallel.Machine WorkerId TaskId NurseryId WaitKey Failure}
    {taskAuthority : TaskId → Authority}
    {host : HostProfile}
    {worker : WorkerId}
    {operation : OperationRef}
    (authorityWithinHost :
      ∀ task, EffectRow.Subset (taskAuthority task) host.provides)
    (allowed : WorkerMayPerform machine taskAuthority worker operation) :
    operation ∈ host.provides := by
  obtain ⟨task, _owned, permitted⟩ := allowed
  exact authorityWithinHost task operation permitted

end VibeFormal.Capability
