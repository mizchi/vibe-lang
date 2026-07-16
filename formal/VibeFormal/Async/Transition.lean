import VibeFormal.Async.State

set_option autoImplicit false

namespace VibeFormal.Async

universe uTask uNursery uWait uFailure

variable {TaskId : Type uTask}
variable {NurseryId : Type uNursery}
variable {WaitKey : Type uWait}
variable {Failure : Type uFailure}

inductive CancelPoint where
  | dispatch
  | suspend
  | blockedWait
  deriving DecidableEq, Repr

inductive Event
    (TaskId : Type uTask)
    (NurseryId : Type uNursery)
    (WaitKey : Type uWait)
    (Failure : Type uFailure) where
  | spawn (nursery : NurseryId) (child : TaskId)
  | dispatch (task : TaskId)
  | suspend (task : TaskId) (reason : WaitReason TaskId WaitKey)
  | wake (task : TaskId)
  | requestCancel (task : TaskId)
  | observeCancel (task : TaskId) (point : CancelPoint)
  | complete (task : TaskId) (outcome : TaskOutcome Failure)
  | beginClose (nursery : NurseryId)
  | beginCancel (nursery : NurseryId) (cause : NurseryCause Failure)
  | settleCancellation (nursery : NurseryId)
  | close (nursery : NurseryId) (cause : NurseryCause Failure)
  deriving DecidableEq, Repr

/-- A cancel request is observed only at an approved scheduler boundary. -/
inductive AtCancelPoint
    {TaskId : Type uTask}
    {WaitKey : Type uWait} :
    LivePhase TaskId WaitKey → CancelPoint → Prop where
  | dispatch : AtCancelPoint .ready .dispatch
  | suspend : AtCancelPoint .running .suspend
  | blocked (reason : WaitReason TaskId WaitKey) :
      AtCancelPoint (.blocked reason) .blockedWait

/-- A blocked task may wake only when its wait reason has become ready. -/
inductive Wakeable
    (world : World TaskId NurseryId WaitKey Failure) :
    WaitReason TaskId WaitKey → Prop where
  | yielded : Wakeable world .yield
  | external (key : WaitKey) : Wakeable world (.external key)
  | joined (target : TaskId)
      (targetState : TaskState TaskId NurseryId WaitKey Failure)
      (outcome : TaskOutcome Failure)
      (present : world.tasks target = some targetState)
      (terminal : targetState.status = .terminal outcome) :
      Wakeable world (.join target)

def CancellationCause (cause : NurseryCause Failure) : Prop :=
  cause ≠ .succeeded

def AcceptsCancellation (phase : NurseryPhase Failure) : Prop :=
  phase = .open ∨ phase = .closing .succeeded

/--
One observable async transition. Nondeterminism is the choice of the next
event, not hidden mutation inside an event.
-/
inductive Step
    [DecidableEq TaskId]
    [DecidableEq NurseryId] :
    World TaskId NurseryId WaitKey Failure →
      Event TaskId NurseryId WaitKey Failure →
      World TaskId NurseryId WaitKey Failure → Prop where
  | spawn
      (world : World TaskId NurseryId WaitKey Failure)
      (nursery : NurseryId)
      (child : TaskId)
      (nurseryOpen : world.nurseries nursery = some .open)
      (fresh : world.tasks child = none) :
      Step world (.spawn nursery child)
        (world.setTask child (TaskState.ready nursery))
  | dispatch
      (world : World TaskId NurseryId WaitKey Failure)
      (taskId : TaskId)
      (task : TaskState TaskId NurseryId WaitKey Failure)
      (present : world.tasks taskId = some task)
      (ready : task.status = .live .ready false) :
      Step world (.dispatch taskId)
        (world.setTask taskId { task with status := .live .running false })
  | suspend
      (world : World TaskId NurseryId WaitKey Failure)
      (taskId : TaskId)
      (task : TaskState TaskId NurseryId WaitKey Failure)
      (reason : WaitReason TaskId WaitKey)
      (present : world.tasks taskId = some task)
      (running : task.status = .live .running false) :
      Step world (.suspend taskId reason)
        (world.setTask taskId { task with status := .live (.blocked reason) false })
  | wake
      (world : World TaskId NurseryId WaitKey Failure)
      (taskId : TaskId)
      (task : TaskState TaskId NurseryId WaitKey Failure)
      (reason : WaitReason TaskId WaitKey)
      (present : world.tasks taskId = some task)
      (blocked : task.status = .live (.blocked reason) false)
      (wakeable : Wakeable world reason) :
      Step world (.wake taskId)
        (world.setTask taskId { task with status := .live .ready false })
  | requestCancel
      (world : World TaskId NurseryId WaitKey Failure)
      (taskId : TaskId)
      (task : TaskState TaskId NurseryId WaitKey Failure)
      (present : world.tasks taskId = some task) :
      Step world (.requestCancel taskId)
        (world.setTask taskId task.requestCancel)
  | observeCancel
      (world : World TaskId NurseryId WaitKey Failure)
      (taskId : TaskId)
      (task : TaskState TaskId NurseryId WaitKey Failure)
      (phase : LivePhase TaskId WaitKey)
      (point : CancelPoint)
      (present : world.tasks taskId = some task)
      (requested : task.status = .live phase true)
      (atPoint : AtCancelPoint phase point) :
      Step world (.observeCancel taskId point)
        (world.setTask taskId { task with status := .terminal .cancelled })
  | completeSucceeded
      (world : World TaskId NurseryId WaitKey Failure)
      (taskId : TaskId)
      (task : TaskState TaskId NurseryId WaitKey Failure)
      (requested : Bool)
      (present : world.tasks taskId = some task)
      (running : task.status = .live .running requested) :
      Step world (.complete taskId .succeeded)
        (world.setTask taskId { task with status := .terminal .succeeded })
  | completeFailed
      (world : World TaskId NurseryId WaitKey Failure)
      (taskId : TaskId)
      (task : TaskState TaskId NurseryId WaitKey Failure)
      (requested : Bool)
      (phase : NurseryPhase Failure)
      (failure : Failure)
      (present : world.tasks taskId = some task)
      (running : task.status = .live .running requested)
      (nurseryPresent : world.nurseries task.nursery = some phase)
      (notClosed : ¬phase.IsClosed) :
      Step world (.complete taskId (.failed failure))
        (world.failTask taskId task phase failure)
  | beginClose
      (world : World TaskId NurseryId WaitKey Failure)
      (nursery : NurseryId)
      (nurseryOpen : world.nurseries nursery = some .open) :
      Step world (.beginClose nursery)
        (world.setNursery nursery (.closing .succeeded))
  | beginCancel
      (world : World TaskId NurseryId WaitKey Failure)
      (nursery : NurseryId)
      (phase : NurseryPhase Failure)
      (cause : NurseryCause Failure)
      (present : world.nurseries nursery = some phase)
      (accepted : AcceptsCancellation phase)
      (cancellation : CancellationCause cause) :
      Step world (.beginCancel nursery cause)
        (world.beginCancellation nursery cause)
  | settleCancellation
      (world : World TaskId NurseryId WaitKey Failure)
      (nursery : NurseryId)
      (cause : NurseryCause Failure)
      (cancelling : world.nurseries nursery = some (.cancelling cause)) :
      Step world (.settleCancellation nursery)
        (world.setNursery nursery (.closing cause))
  | close
      (world : World TaskId NurseryId WaitKey Failure)
      (nursery : NurseryId)
      (cause : NurseryCause Failure)
      (closing : world.nurseries nursery = some (.closing cause))
      (childrenTerminal : world.AllChildrenTerminal nursery) :
      Step world (.close nursery cause)
        (world.setNursery nursery (.closed cause))

end VibeFormal.Async
