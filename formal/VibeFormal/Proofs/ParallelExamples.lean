import VibeFormal.Proofs.ParallelSafety

set_option autoImplicit false

namespace VibeFormal.Parallel.Examples

abbrev DemoWorld := Async.World Bool Unit Unit String
abbrev DemoMachine := Machine Bool Bool Unit Unit String
abbrev DemoTaskState := Async.TaskState Bool Unit Unit String

private def readyTask : DemoTaskState := Async.TaskState.ready ()
private def runningTask : DemoTaskState := Async.TaskState.running ()

private def initialWorld : DemoWorld :=
  { tasks := fun _ => some readyTask
    nurseries := fun _ => some .open }

private def initialMachine : DemoMachine :=
  { world := initialWorld
    workers := fun _ => .idle }

private def afterFirstWorld : DemoWorld :=
  initialWorld.setTask false runningTask

private def afterFirst : DemoMachine :=
  (initialMachine.setWorker false (.running false)).withWorld afterFirstWorld

private def afterSecondWorld : DemoWorld :=
  afterFirstWorld.setTask true runningTask

private def afterSecond : DemoMachine :=
  (afterFirst.setWorker true (.running true)).withWorld afterSecondWorld

private def afterCompleteWorld : DemoWorld :=
  afterFirstWorld.setTask false
    { runningTask with status := .terminal .succeeded }

private def afterComplete : DemoMachine :=
  (afterFirst.setWorker false .idle).withWorld afterCompleteWorld

private theorem initial_not_running (taskId : Bool) :
    ¬WorldRunning initialWorld taskId := by
  intro running
  obtain ⟨task, requested, present, status⟩ := running
  have taskIsReady : task = readyTask := by
    exact Option.some.inj (by simpa [initialWorld] using present.symm)
  subst task
  simp [readyTask, Async.TaskState.ready] at status

private theorem first_running_false :
    WorldRunning afterFirstWorld false := by
  exact ⟨runningTask, false, by simp [afterFirstWorld], rfl⟩

private theorem first_true_not_running :
    ¬WorldRunning afterFirstWorld true := by
  intro running
  obtain ⟨task, requested, present, status⟩ := running
  have taskIsReady : task = readyTask := by
    exact Option.some.inj (by
      simpa [afterFirstWorld, initialWorld, Async.World.setTask] using present.symm)
  subst task
  simp [readyTask, Async.TaskState.ready] at status

private theorem second_running_true :
    WorldRunning afterSecondWorld true := by
  exact ⟨runningTask, false, by simp [afterSecondWorld], rfl⟩

private theorem second_false_stays_running :
    WorldRunning afterSecondWorld false := by
  exact ⟨runningTask, false, by
    simp [afterSecondWorld, afterFirstWorld], rfl⟩

private theorem completed_false_not_running :
    ¬WorldRunning afterCompleteWorld false := by
  intro running
  obtain ⟨task, requested, present, status⟩ := running
  have taskIsTerminal :
      task = { runningTask with status := .terminal .succeeded } := by
    exact Option.some.inj (by
      simpa [afterCompleteWorld] using present.symm)
  subst task
  simp at status

private theorem completed_true_not_running :
    ¬WorldRunning afterCompleteWorld true := by
  intro running
  obtain ⟨task, requested, present, status⟩ := running
  have taskIsReady : task = readyTask := by
    exact Option.some.inj (by
      simpa [afterCompleteWorld, afterFirstWorld, initialWorld,
        Async.World.setTask] using present.symm)
  subst task
  simp [readyTask, Async.TaskState.ready] at status

private theorem first_adds :
    AddsRunning initialWorld afterFirstWorld false := by
  refine {
    notRunningBefore := initial_not_running false
    runningAfter := first_running_false
    other := ?_
  }
  intro candidate different
  cases candidate
  · contradiction
  · exact ⟨fun before => (initial_not_running true before).elim,
      fun after => (first_true_not_running after).elim⟩

private theorem second_adds :
    AddsRunning afterFirstWorld afterSecondWorld true := by
  refine {
    notRunningBefore := first_true_not_running
    runningAfter := second_running_true
    other := ?_
  }
  intro candidate different
  cases candidate
  · exact ⟨fun _ => second_false_stays_running,
      fun _ => first_running_false⟩
  · contradiction

private theorem first_completion_removes :
    RemovesRunning afterFirstWorld afterCompleteWorld false := by
  refine {
    runningBefore := first_running_false
    notRunningAfter := completed_false_not_running
    other := ?_
  }
  intro candidate different
  cases candidate
  · contradiction
  · exact ⟨fun before => (first_true_not_running before).elim,
      fun after => (completed_true_not_running after).elim⟩

private theorem initial_well_formed : initialMachine.WellFormed := by
  refine {
    assignmentRunning := ?_
    runningAssigned := ?_
    uniqueOwner := ?_
  }
  · intro worker taskId owned
    simp [initialMachine, Machine.Owns] at owned
  · intro taskId running
    exact (initial_not_running taskId running).elim
  · intro worker₁ worker₂ taskId owned₁ owned₂
    simp [initialMachine, Machine.Owns] at owned₁

private theorem first_claim :
    Step initialMachine (.claim false false) afterFirst := by
  apply Step.claim initialMachine false false afterFirstWorld
  · rfl
  · apply Async.Step.dispatch initialWorld false readyTask
    · rfl
    · rfl
  · exact first_adds

private theorem second_claim :
    Step afterFirst (.claim true true) afterSecond := by
  apply Step.claim afterFirst true true afterSecondWorld
  · rfl
  · apply Async.Step.dispatch afterFirstWorld true readyTask
    · simp [afterFirstWorld, initialWorld, Async.World.setTask]
    · rfl
  · exact second_adds

private theorem first_completion :
    Step afterFirst (.releaseComplete false false .succeeded)
      afterComplete := by
  apply Step.releaseComplete afterFirst false false .succeeded afterCompleteWorld
  · rfl
  · apply Async.Step.completeSucceeded afterFirstWorld false runningTask false
    · simp [afterFirstWorld]
    · rfl
  · exact first_completion_removes

/-- Two independent ready tasks may run on two distinct workers. -/
private theorem two_worker_execution :
    Execution initialMachine
      [ .claim false false, .claim true true ] afterSecond := by
  apply Execution.step first_claim
  apply Execution.step second_claim
  exact Execution.refl _

example : afterSecond.Owns false false ∧ afterSecond.Owns true true := by
  constructor <;> rfl

example : afterSecond.WellFormed := by
  exact execution_preserves_well_formed two_worker_execution initial_well_formed

/-- Completion releases the worker while preserving the terminal task. -/
example :
    Execution initialMachine
      [ .claim false false,
        .releaseComplete false false .succeeded ]
      afterComplete := by
  apply Execution.step first_claim
  apply Execution.step first_completion
  exact Execution.refl _

example : afterComplete.workers false = .idle := by
  rfl

/-- The physical execution projects to the public async dispatch trace. -/
example :
    Async.Execution initialWorld
      [ .dispatch false, .dispatch true ] afterSecondWorld := by
  exact execution_projects_to_async two_worker_execution

/-- A running task cannot be claimed a second time by another worker. -/
example : ¬∃ after, Step afterFirst (.claim true false) after := by
  intro witness
  obtain ⟨after, transition⟩ := witness
  obtain ⟨task, present, ready⟩ := claim_requires_ready transition
  have taskIsRunning : task = runningTask := by
    have runningPresent :
        afterFirst.world.tasks false = some runningTask := by
      simp [afterFirst, afterFirstWorld, Machine.withWorld,
        Machine.setWorker, Async.World.setTask]
    exact Option.some.inj (present.symm.trans runningPresent)
  subst task
  simp [runningTask, Async.TaskState.running] at ready

private def demoHeap : HeapOwnership Bool Bool :=
  { owner := fun location => some location }

/-- Copy-on-send ownership forbids two workers from accessing one location. -/
example :
    ¬∃ location,
      demoHeap.MayAccess false location ∧
      demoHeap.MayAccess true location := by
  intro witness
  obtain ⟨location, leftAccess, rightAccess⟩ := witness
  exact distinct_workers_have_disjoint_task_heaps
    (execution_preserves_well_formed two_worker_execution initial_well_formed)
    demoHeap
    (worker₁ := false) (worker₂ := true)
    (task₁ := false) (task₂ := true)
    (location := location)
    (by rfl) (by rfl) (by decide) leftAccess rightAccess

end VibeFormal.Parallel.Examples
