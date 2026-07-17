import VibeFormal.Proofs.AsyncSafety

set_option autoImplicit false

namespace VibeFormal.Async

universe uTask uNursery uWait uFailure

variable {TaskId : Type uTask}
variable {NurseryId : Type uNursery}
variable {WaitKey : Type uWait}
variable {Failure : Type uFailure}

/-- The first failure selects the cause and requests cancellation. -/
theorem first_failure_starts_cancellation (failure : Failure) :
    (NurseryPhase.open.observeFailure failure =
      .cancelling (.failed failure)) ∧
    (NurseryPhase.open : NurseryPhase Failure).failureStartsCancellation =
      true := by
  exact ⟨rfl, rfl⟩

/-- Later failures cannot overwrite an already selected failure cause. -/
theorem later_failure_preserves_selected_cause
    (selected later : Failure) :
    ((NurseryPhase.cancelling (.failed selected)).observeFailure later =
      .cancelling (.failed selected)) ∧
    ((NurseryPhase.closing (.failed selected)).observeFailure later =
      .closing (.failed selected)) := by
  exact ⟨rfl, rfl⟩

/-- Spawning is possible only while the target nursery is open. -/
theorem spawn_requires_open
    [DecidableEq TaskId]
    [DecidableEq NurseryId]
    {world after : World TaskId NurseryId WaitKey Failure}
    {nursery : NurseryId}
    {child : TaskId}
    (transition : Step world (.spawn nursery child) after) :
  world.nurseries nursery = some .open := by
  cases transition with
  | spawn _ _ nurseryOpen _ => exact nurseryOpen

theorem spawn_rejected_unless_open
    [DecidableEq TaskId]
    [DecidableEq NurseryId]
    {world : World TaskId NurseryId WaitKey Failure}
    {nursery : NurseryId}
    {child : TaskId}
    (notOpen : world.nurseries nursery ≠ some .open) :
    ¬∃ after, Step world (.spawn nursery child) after := by
  intro witness
  obtain ⟨after, transition⟩ := witness
  exact notOpen (spawn_requires_open transition)

/-- Closing is enabled only after every child has reached a terminal state. -/
theorem close_requires_all_children_terminal
    [DecidableEq TaskId]
    [DecidableEq NurseryId]
    {world after : World TaskId NurseryId WaitKey Failure}
    {nursery : NurseryId}
    {cause : NurseryCause Failure}
    (transition : Step world (.close nursery cause) after) :
  world.AllChildrenTerminal nursery := by
  cases transition with
  | close _ _ _ childrenTerminal => exact childrenTerminal

theorem close_rejected_with_live_child
    [DecidableEq TaskId]
    [DecidableEq NurseryId]
    {world : World TaskId NurseryId WaitKey Failure}
    {nursery : NurseryId}
    {cause : NurseryCause Failure}
    {taskId : TaskId}
    {task : TaskState TaskId NurseryId WaitKey Failure}
    {phase : LivePhase TaskId WaitKey}
    {requested : Bool}
    (present : world.tasks taskId = some task)
    (owned : task.nursery = nursery)
    (live : task.status = .live phase requested) :
    ¬∃ after, Step world (.close nursery cause) after := by
  intro witness
  obtain ⟨after, transition⟩ := witness
  obtain ⟨outcome, terminal⟩ :=
    close_requires_all_children_terminal transition taskId task present owned
  rw [live] at terminal
  contradiction

/-- A close transition publishes the selected cause without changing tasks. -/
theorem close_publishes_cause
    [DecidableEq TaskId]
    [DecidableEq NurseryId]
    {world after : World TaskId NurseryId WaitKey Failure}
    {nursery : NurseryId}
    {cause : NurseryCause Failure}
    (transition : Step world (.close nursery cause) after) :
    after.nurseries nursery = some (.closed cause) ∧
      after.tasks = world.tasks := by
  cases transition with
  | close =>
      constructor
      · simp
      · rfl

/-- Once closed, a nursery's phase is immutable under every later step. -/
theorem step_preserves_closed_nursery
    [DecidableEq TaskId]
    [DecidableEq NurseryId]
    {before after : World TaskId NurseryId WaitKey Failure}
    {event : Event TaskId NurseryId WaitKey Failure}
    {nursery : NurseryId}
    {cause : NurseryCause Failure}
    (transition : Step before event after)
    (closed : before.nurseries nursery = some (.closed cause)) :
    after.nurseries nursery = some (.closed cause) := by
  cases transition with
  | spawn | dispatch | suspend | wake | requestCancel | observeCancel |
      completeSucceeded =>
      exact closed
  | completeFailed taskId task requested phase failure present running
      nurseryPresent notClosed =>
      have different : nursery ≠ task.nursery := by
        intro same
        subst nursery
        rw [closed] at nurseryPresent
        have phaseClosed : phase = .closed cause :=
          Option.some.inj nurseryPresent.symm
        exact notClosed ⟨cause, phaseClosed⟩
      unfold World.failTask
      dsimp
      split <;>
        simp [World.setTask, World.setNursery, World.requestCancelChildren,
          different, closed]
  | beginClose changed nurseryOpen =>
      have different : nursery ≠ changed := by
        intro same
        subst changed
        rw [closed] at nurseryOpen
        simp at nurseryOpen
      exact (World.setNursery_other before changed nursery _ different).trans closed
  | beginCancel changed phase changedCause present accepted cancellation =>
      have different : nursery ≠ changed := by
        intro same
        subst changed
        rw [closed] at present
        have phaseClosed : phase = .closed cause := Option.some.inj present.symm
        subst phase
        simp [AcceptsCancellation] at accepted
      unfold World.beginCancellation
      exact (World.setNursery_other before changed nursery _ different).trans closed
  | settleCancellation changed changedCause cancelling =>
      have different : nursery ≠ changed := by
        intro same
        subst changed
        rw [closed] at cancelling
        simp at cancelling
      exact (World.setNursery_other before changed nursery _ different).trans closed
  | close changed changedCause closing childrenTerminal =>
      have different : nursery ≠ changed := by
        intro same
        subst changed
        rw [closed] at closing
        simp at closing
      exact (World.setNursery_other before changed nursery _ different).trans closed

theorem execution_preserves_closed_nursery
    [DecidableEq TaskId]
    [DecidableEq NurseryId]
    {start finish : World TaskId NurseryId WaitKey Failure}
    {events : List (Event TaskId NurseryId WaitKey Failure)}
    {nursery : NurseryId}
    {cause : NurseryCause Failure}
    (execution : Execution start events finish)
    (closed : start.nurseries nursery = some (.closed cause)) :
    finish.nurseries nursery = some (.closed cause) := by
  induction execution with
  | refl => exact closed
  | step transition rest inductionHypothesis =>
      exact inductionHypothesis
        (step_preserves_closed_nursery transition closed)

end VibeFormal.Async
