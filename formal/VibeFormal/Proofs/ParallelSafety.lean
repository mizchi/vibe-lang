import VibeFormal.Parallel.Trace

set_option autoImplicit false

namespace VibeFormal.Parallel

universe uWorker uTask uNursery uWait uFailure uLocation

variable {WorkerId : Type uWorker}
variable {TaskId : Type uTask}
variable {NurseryId : Type uNursery}
variable {WaitKey : Type uWait}
variable {Failure : Type uFailure}
variable {Location : Type uLocation}

private theorem assigned_after_claim
    [DecidableEq WorkerId]
    {machine : Machine WorkerId TaskId NurseryId WaitKey Failure}
    {worker : WorkerId}
    {taskId candidate : TaskId}
    (idle : machine.workers worker = .idle) :
    (machine.setWorker worker (.running taskId)).Assigned candidate ↔
      candidate = taskId ∨ machine.Assigned candidate := by
  constructor
  · rintro ⟨owner, owned⟩
    by_cases sameOwner : owner = worker
    · subst owner
      left
      simp [Machine.Owns] at owned
      exact owned.symm
    · right
      refine ⟨owner, ?_⟩
      simpa [Machine.Owns, Machine.setWorker, sameOwner] using owned
  · intro assigned
    rcases assigned with sameTask | previous
    · subst candidate
      exact ⟨worker, by simp [Machine.Owns]⟩
    · obtain ⟨owner, owned⟩ := previous
      by_cases sameOwner : owner = worker
      · subst owner
        unfold Machine.Owns at owned
        rw [idle] at owned
        contradiction
      · exact ⟨owner, by
          simpa [Machine.Owns, Machine.setWorker, sameOwner] using owned⟩

private theorem assigned_after_release
    [DecidableEq WorkerId]
    {machine : Machine WorkerId TaskId NurseryId WaitKey Failure}
    {worker : WorkerId}
    {taskId candidate : TaskId}
    (wellFormed : machine.WellFormed)
    (owned : machine.Owns worker taskId) :
    (machine.setWorker worker .idle).Assigned candidate ↔
      machine.Assigned candidate ∧ candidate ≠ taskId := by
  constructor
  · rintro ⟨owner, afterOwned⟩
    have differentOwner : owner ≠ worker := by
      intro sameOwner
      subst owner
      simp [Machine.Owns] at afterOwned
    have beforeOwned : machine.Owns owner candidate := by
      simpa [Machine.Owns, Machine.setWorker, differentOwner] using afterOwned
    refine ⟨⟨owner, beforeOwned⟩, ?_⟩
    intro sameTask
    subst candidate
    have sameOwner := wellFormed.uniqueOwner worker owner taskId owned beforeOwned
    exact differentOwner sameOwner.symm
  · rintro ⟨⟨owner, beforeOwned⟩, differentTask⟩
    have differentOwner : owner ≠ worker := by
      intro sameOwner
      subst owner
      have sameTask : taskId = candidate :=
        WorkerSlot.running.inj (owned.symm.trans beforeOwned)
      exact differentTask sameTask.symm
    exact ⟨owner, by
      simpa [Machine.Owns, Machine.setWorker, differentOwner] using beforeOwned⟩

private theorem control_preserves_well_formed
    {before : Machine WorkerId TaskId NurseryId WaitKey Failure}
    {afterWorld : Async.World TaskId NurseryId WaitKey Failure}
    (wellFormed : before.WellFormed)
    (stable : SameRunningSet before.world afterWorld) :
    (before.withWorld afterWorld).WellFormed := by
  refine {
    assignmentRunning := ?_
    runningAssigned := ?_
    uniqueOwner := ?_
  }
  · intro worker taskId owned
    exact (stable taskId).mp
      (wellFormed.assignmentRunning worker taskId owned)
  · intro taskId running
    exact wellFormed.runningAssigned taskId ((stable taskId).mpr running)
  · intro worker₁ worker₂ taskId owned₁ owned₂
    exact wellFormed.uniqueOwner worker₁ worker₂ taskId owned₁ owned₂

private theorem claim_preserves_well_formed
    [DecidableEq WorkerId]
    {before : Machine WorkerId TaskId NurseryId WaitKey Failure}
    {worker : WorkerId}
    {taskId : TaskId}
    {afterWorld : Async.World TaskId NurseryId WaitKey Failure}
    (wellFormed : before.WellFormed)
    (idle : before.workers worker = .idle)
    (adds : AddsRunning before.world afterWorld taskId) :
    ((before.setWorker worker (.running taskId)).withWorld afterWorld).WellFormed := by
  refine {
    assignmentRunning := ?_
    runningAssigned := ?_
    uniqueOwner := ?_
  }
  · intro owner candidate ownedAfter
    change (before.setWorker worker (.running taskId)).Owns owner candidate at ownedAfter
    have assignedAfter :
        (before.setWorker worker (.running taskId)).Assigned candidate :=
      ⟨owner, ownedAfter⟩
    rcases (assigned_after_claim idle).mp assignedAfter with sameTask | previous
    · subst candidate
      exact adds.runningAfter
    · obtain ⟨previousOwner, previousOwned⟩ := previous
      have runningBefore :=
        wellFormed.assignmentRunning previousOwner candidate previousOwned
      by_cases sameTask : candidate = taskId
      · subst candidate
        exact (adds.notRunningBefore runningBefore).elim
      · exact (adds.other candidate sameTask).mp runningBefore
  · intro candidate runningAfter
    change (before.setWorker worker (.running taskId)).Assigned candidate
    by_cases sameTask : candidate = taskId
    · exact (assigned_after_claim idle).mpr (Or.inl sameTask)
    · have runningBefore := (adds.other candidate sameTask).mpr runningAfter
      exact (assigned_after_claim idle).mpr
        (Or.inr (wellFormed.runningAssigned candidate runningBefore))
  · intro owner₁ owner₂ candidate owned₁ owned₂
    change (before.setWorker worker (.running taskId)).Owns owner₁ candidate at owned₁
    change (before.setWorker worker (.running taskId)).Owns owner₂ candidate at owned₂
    by_cases firstClaim : owner₁ = worker
    · subst owner₁
      by_cases secondClaim : owner₂ = worker
      · exact secondClaim.symm
      · have sameTask : taskId = candidate := by
          simpa [Machine.Owns] using owned₁
        subst candidate
        have previousOwned : before.Owns owner₂ taskId := by
          simpa [Machine.Owns, Machine.setWorker, secondClaim] using owned₂
        have runningBefore :=
          wellFormed.assignmentRunning owner₂ taskId previousOwned
        exact (adds.notRunningBefore runningBefore).elim
    · by_cases secondClaim : owner₂ = worker
      · subst owner₂
        have sameTask : taskId = candidate := by
          simpa [Machine.Owns] using owned₂
        subst candidate
        have previousOwned : before.Owns owner₁ taskId := by
          simpa [Machine.Owns, Machine.setWorker, firstClaim] using owned₁
        have runningBefore :=
          wellFormed.assignmentRunning owner₁ taskId previousOwned
        exact (adds.notRunningBefore runningBefore).elim
      · have previousOwned₁ : before.Owns owner₁ candidate := by
          simpa [Machine.Owns, Machine.setWorker, firstClaim] using owned₁
        have previousOwned₂ : before.Owns owner₂ candidate := by
          simpa [Machine.Owns, Machine.setWorker, secondClaim] using owned₂
        exact wellFormed.uniqueOwner owner₁ owner₂ candidate
          previousOwned₁ previousOwned₂

private theorem release_preserves_well_formed
    [DecidableEq WorkerId]
    {before : Machine WorkerId TaskId NurseryId WaitKey Failure}
    {worker : WorkerId}
    {taskId : TaskId}
    {afterWorld : Async.World TaskId NurseryId WaitKey Failure}
    (wellFormed : before.WellFormed)
    (owned : before.Owns worker taskId)
    (removes : RemovesRunning before.world afterWorld taskId) :
    ((before.setWorker worker .idle).withWorld afterWorld).WellFormed := by
  refine {
    assignmentRunning := ?_
    runningAssigned := ?_
    uniqueOwner := ?_
  }
  · intro owner candidate ownedAfter
    change (before.setWorker worker .idle).Owns owner candidate at ownedAfter
    have assignedAfter : (before.setWorker worker .idle).Assigned candidate :=
      ⟨owner, ownedAfter⟩
    obtain ⟨⟨previousOwner, previousOwned⟩, differentTask⟩ :=
      (assigned_after_release wellFormed owned).mp assignedAfter
    have runningBefore :=
      wellFormed.assignmentRunning previousOwner candidate previousOwned
    exact (removes.other candidate differentTask).mp runningBefore
  · intro candidate runningAfter
    have differentTask : candidate ≠ taskId := by
      intro sameTask
      subst candidate
      exact removes.notRunningAfter runningAfter
    have runningBefore := (removes.other candidate differentTask).mpr runningAfter
    change (before.setWorker worker .idle).Assigned candidate
    exact (assigned_after_release wellFormed owned).mpr
      ⟨wellFormed.runningAssigned candidate runningBefore, differentTask⟩
  · intro owner₁ owner₂ candidate owned₁ owned₂
    change (before.setWorker worker .idle).Owns owner₁ candidate at owned₁
    change (before.setWorker worker .idle).Owns owner₂ candidate at owned₂
    have differentOwner₁ : owner₁ ≠ worker := by
      intro sameOwner
      subst owner₁
      simp [Machine.Owns] at owned₁
    have differentOwner₂ : owner₂ ≠ worker := by
      intro sameOwner
      subst owner₂
      simp [Machine.Owns] at owned₂
    have previousOwned₁ : before.Owns owner₁ candidate := by
      simpa [Machine.Owns, Machine.setWorker, differentOwner₁] using owned₁
    have previousOwned₂ : before.Owns owner₂ candidate := by
      simpa [Machine.Owns, Machine.setWorker, differentOwner₂] using owned₂
    exact wellFormed.uniqueOwner owner₁ owner₂ candidate
      previousOwned₁ previousOwned₂

/-- Worker ownership remains a bijection with logical running tasks. -/
theorem step_preserves_well_formed
    [DecidableEq WorkerId]
    [DecidableEq TaskId]
    [DecidableEq NurseryId]
    {before after : Machine WorkerId TaskId NurseryId WaitKey Failure}
    {event : Event WorkerId TaskId NurseryId WaitKey Failure}
    (transition : Step before event after)
    (wellFormed : before.WellFormed) :
    after.WellFormed := by
  cases transition with
  | control event afterWorld async stable =>
      exact control_preserves_well_formed wellFormed stable
  | claim worker taskId afterWorld idle async adds =>
      exact claim_preserves_well_formed wellFormed idle adds
  | releaseSuspend worker taskId reason afterWorld owned async removes =>
      exact release_preserves_well_formed wellFormed owned removes
  | releaseCancel worker taskId afterWorld owned async removes =>
      exact release_preserves_well_formed wellFormed owned removes
  | releaseComplete worker taskId outcome afterWorld owned async removes =>
      exact release_preserves_well_formed wellFormed owned removes

/-- Worker ownership stays well formed over every finite parallel execution. -/
theorem execution_preserves_well_formed
    [DecidableEq WorkerId]
    [DecidableEq TaskId]
    [DecidableEq NurseryId]
    {start finish : Machine WorkerId TaskId NurseryId WaitKey Failure}
    {events : List (Event WorkerId TaskId NurseryId WaitKey Failure)}
    (execution : Execution start events finish)
    (wellFormed : start.WellFormed) :
    finish.WellFormed := by
  induction execution with
  | refl => exact wellFormed
  | step transition rest inductionHypothesis =>
      exact inductionHypothesis
        (step_preserves_well_formed transition wellFormed)

/-- A worker can claim only an idle slot. -/
theorem claim_requires_idle
    [DecidableEq WorkerId]
    [DecidableEq TaskId]
    [DecidableEq NurseryId]
    {before after : Machine WorkerId TaskId NurseryId WaitKey Failure}
    {worker : WorkerId}
    {taskId : TaskId}
    (transition : Step before (.claim worker taskId) after) :
    before.workers worker = .idle := by
  cases transition with
  | claim _ _ _ idle _ _ => exact idle

/-- A worker can claim only a ready, non-cancelled logical task. -/
theorem claim_requires_ready
    [DecidableEq WorkerId]
    [DecidableEq TaskId]
    [DecidableEq NurseryId]
    {before after : Machine WorkerId TaskId NurseryId WaitKey Failure}
    {worker : WorkerId}
    {taskId : TaskId}
    (transition : Step before (.claim worker taskId) after) :
    ∃ task,
      before.world.tasks taskId = some task ∧
      task.status = .live .ready false := by
  cases transition with
  | claim _ _ _ _ async _ =>
      cases async with
      | dispatch _ task present ready => exact ⟨task, present, ready⟩

/-- Every physical worker step is an accepted step of the async oracle. -/
theorem step_projects_to_async
    [DecidableEq WorkerId]
    [DecidableEq TaskId]
    [DecidableEq NurseryId]
    {before after : Machine WorkerId TaskId NurseryId WaitKey Failure}
    {event : Event WorkerId TaskId NurseryId WaitKey Failure}
    (transition : Step before event after) :
    Async.Step before.world event.project after.world := by
  cases transition <;> assumption

/-- Every finite parallel execution refines an accepted async execution. -/
theorem execution_projects_to_async
    [DecidableEq WorkerId]
    [DecidableEq TaskId]
    [DecidableEq NurseryId]
    {start finish : Machine WorkerId TaskId NurseryId WaitKey Failure}
    {events : List (Event WorkerId TaskId NurseryId WaitKey Failure)}
    (execution : Execution start events finish) :
    Async.Execution start.world (projectEvents events) finish.world := by
  induction execution with
  | refl => exact Async.Execution.refl _
  | step transition rest inductionHypothesis =>
      exact Async.Execution.step
        (step_projects_to_async transition) inductionHypothesis

/-- Two physical workers cannot own tasks that access the same owned location. -/
theorem distinct_workers_have_disjoint_task_heaps
    {machine : Machine WorkerId TaskId NurseryId WaitKey Failure}
    (wellFormed : machine.WellFormed)
    (ownership : HeapOwnership TaskId Location)
    {worker₁ worker₂ : WorkerId}
    {task₁ task₂ : TaskId}
    {location : Location}
    (owns₁ : machine.Owns worker₁ task₁)
    (owns₂ : machine.Owns worker₂ task₂)
    (differentWorkers : worker₁ ≠ worker₂)
    (access₁ : ownership.MayAccess task₁ location)
    (access₂ : ownership.MayAccess task₂ location) : False := by
  have sameTask : task₁ = task₂ := by
    exact Option.some.inj (access₁.symm.trans access₂)
  subst task₂
  exact differentWorkers (wellFormed.uniqueOwner worker₁ worker₂ task₁ owns₁ owns₂)

end VibeFormal.Parallel
