import VibeFormal.Async.Trace

set_option autoImplicit false

namespace VibeFormal.Async

universe uTask uNursery uWait uFailure

variable {TaskId : Type uTask}
variable {NurseryId : Type uNursery}
variable {WaitKey : Type uWait}
variable {Failure : Type uFailure}

private theorem task_id_ne_of_some_none
    {world : World TaskId NurseryId WaitKey Failure}
    {presentId freshId : TaskId}
    {task : TaskState TaskId NurseryId WaitKey Failure}
    (present : world.tasks presentId = some task)
    (fresh : world.tasks freshId = none) :
    presentId ≠ freshId := by
  intro same
  subst freshId
  rw [present] at fresh
  contradiction

private theorem task_id_ne_of_terminal_live
    {world : World TaskId NurseryId WaitKey Failure}
    {terminalId liveId : TaskId}
    {terminalTask liveTask : TaskState TaskId NurseryId WaitKey Failure}
    {outcome : TaskOutcome Failure}
    {phase : LivePhase TaskId WaitKey}
    {requested : Bool}
    (terminalPresent : world.tasks terminalId = some terminalTask)
    (livePresent : world.tasks liveId = some liveTask)
    (terminal : terminalTask.status = .terminal outcome)
    (live : liveTask.status = .live phase requested) :
    terminalId ≠ liveId := by
  intro same
  subst liveId
  rw [terminalPresent] at livePresent
  have tasksEqual : terminalTask = liveTask := Option.some.inj livePresent
  subst liveTask
  rw [terminal] at live
  contradiction

private theorem request_children_preserves_terminal
    [DecidableEq NurseryId]
    {world : World TaskId NurseryId WaitKey Failure}
    {taskId : TaskId}
    {task : TaskState TaskId NurseryId WaitKey Failure}
    {outcome : TaskOutcome Failure}
    (nursery : NurseryId)
    (present : world.tasks taskId = some task)
    (terminal : task.status = .terminal outcome) :
    (world.requestCancelChildren nursery).tasks taskId = some task := by
  simp [World.requestCancelChildren, present, TaskState.requestCancel, terminal]

/-- A completed task is immutable under every later machine transition. -/
theorem step_preserves_terminal_task
    [DecidableEq TaskId]
    [DecidableEq NurseryId]
    {before after : World TaskId NurseryId WaitKey Failure}
    {event : Event TaskId NurseryId WaitKey Failure}
    {taskId : TaskId}
    {task : TaskState TaskId NurseryId WaitKey Failure}
    {outcome : TaskOutcome Failure}
    (transition : Step before event after)
    (present : before.tasks taskId = some task)
    (terminal : task.status = .terminal outcome) :
    after.tasks taskId = some task := by
  cases transition with
  | spawn nursery child nurseryOpen fresh =>
      exact (World.setTask_other before child taskId _
        (task_id_ne_of_some_none present fresh)).trans present
  | dispatch runningId runningTask runningPresent ready =>
      exact (World.setTask_other before runningId taskId _
        (task_id_ne_of_terminal_live present runningPresent terminal ready)).trans present
  | suspend runningId runningTask reason runningPresent running =>
      exact (World.setTask_other before runningId taskId _
        (task_id_ne_of_terminal_live present runningPresent terminal running)).trans present
  | wake blockedId blockedTask reason blockedPresent blocked wakeable =>
      exact (World.setTask_other before blockedId taskId _
        (task_id_ne_of_terminal_live present blockedPresent terminal blocked)).trans present
  | requestCancel requestedId requestedTask requestedPresent =>
      by_cases same : taskId = requestedId
      · subst requestedId
        rw [present] at requestedPresent
        have tasksEqual : task = requestedTask := Option.some.inj requestedPresent
        subst requestedTask
        simp [TaskState.requestCancel, terminal]
      · exact (World.setTask_other before requestedId taskId _ same).trans present
  | observeCancel cancelledId cancelledTask phase point cancelledPresent requested atPoint =>
      exact (World.setTask_other before cancelledId taskId _
        (task_id_ne_of_terminal_live present cancelledPresent terminal requested)).trans present
  | completeSucceeded completedId completedTask requested completedPresent running =>
      exact (World.setTask_other before completedId taskId _
        (task_id_ne_of_terminal_live present completedPresent terminal running)).trans present
  | completeFailed failedId failedTask requested phase failure failedPresent running nurseryPresent notClosed =>
      have different : taskId ≠ failedId :=
        task_id_ne_of_terminal_live present failedPresent terminal running
      unfold World.failTask
      dsimp
      split <;>
        simp [World.setTask, World.setNursery, World.requestCancelChildren,
          TaskState.requestCancel, different, present, terminal]
  | beginClose => exact present
  | beginCancel nursery phase cause nurseryPresent accepted cancellation =>
      exact request_children_preserves_terminal nursery present terminal
  | settleCancellation => exact present
  | close => exact present

/-- Terminal stability extends from one step to every accepted trace. -/
theorem execution_preserves_terminal_task
    [DecidableEq TaskId]
    [DecidableEq NurseryId]
    {start finish : World TaskId NurseryId WaitKey Failure}
    {events : List (Event TaskId NurseryId WaitKey Failure)}
    {taskId : TaskId}
    {task : TaskState TaskId NurseryId WaitKey Failure}
    {outcome : TaskOutcome Failure}
    (execution : Execution start events finish)
    (present : start.tasks taskId = some task)
    (terminal : task.status = .terminal outcome) :
    finish.tasks taskId = some task := by
  induction execution with
  | refl => exact present
  | step transition rest inductionHypothesis =>
      exact inductionHypothesis
        (step_preserves_terminal_task transition present terminal)

/-- Repeated joins observe the same immutable terminal outcome. -/
theorem execution_preserves_join_result
    [DecidableEq TaskId]
    [DecidableEq NurseryId]
    {start finish : World TaskId NurseryId WaitKey Failure}
    {events : List (Event TaskId NurseryId WaitKey Failure)}
    {taskId : TaskId}
    {task : TaskState TaskId NurseryId WaitKey Failure}
    {outcome : TaskOutcome Failure}
    (execution : Execution start events finish)
    (present : start.tasks taskId = some task)
    (terminal : task.status = .terminal outcome) :
    ∃ finalTask,
      finish.tasks taskId = some finalTask ∧
      finalTask.joinResult = some outcome := by
  refine ⟨task, execution_preserves_terminal_task execution present terminal, ?_⟩
  simp [TaskState.joinResult, terminal]

/-- Every cancellation terminal transition carries an explicit cancel point. -/
theorem observed_cancellation_has_cancel_point
    [DecidableEq TaskId]
    [DecidableEq NurseryId]
    {before after : World TaskId NurseryId WaitKey Failure}
    {taskId : TaskId}
    {point : CancelPoint}
    (transition : Step before (.observeCancel taskId point) after) :
    ∃ task phase,
      before.tasks taskId = some task ∧
      task.status = .live phase true ∧
      AtCancelPoint phase point := by
  cases transition with
  | observeCancel _ task phase _ present requested atPoint =>
      exact ⟨task, phase, present, requested, atPoint⟩

end VibeFormal.Async
