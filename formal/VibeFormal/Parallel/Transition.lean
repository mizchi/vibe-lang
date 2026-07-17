import VibeFormal.Async.Transition
import VibeFormal.Parallel.State

set_option autoImplicit false

namespace VibeFormal.Parallel

universe uWorker uTask uNursery uWait uFailure

variable {WorkerId : Type uWorker}
variable {TaskId : Type uTask}
variable {NurseryId : Type uNursery}
variable {WaitKey : Type uWait}
variable {Failure : Type uFailure}

/-- A control event does not change which logical tasks are running. -/
def SameRunningSet
    (before after : Async.World TaskId NurseryId WaitKey Failure) : Prop :=
  ∀ taskId, WorldRunning before taskId ↔ WorldRunning after taskId

/-- Claiming a worker adds exactly one logical running task. -/
structure AddsRunning
    (before after : Async.World TaskId NurseryId WaitKey Failure)
    (taskId : TaskId) : Prop where
  notRunningBefore : ¬WorldRunning before taskId
  runningAfter : WorldRunning after taskId
  other : ∀ candidate, candidate ≠ taskId →
    (WorldRunning before candidate ↔ WorldRunning after candidate)

/-- Releasing a worker removes exactly its logical running task. -/
structure RemovesRunning
    (before after : Async.World TaskId NurseryId WaitKey Failure)
    (taskId : TaskId) : Prop where
  runningBefore : WorldRunning before taskId
  notRunningAfter : ¬WorldRunning after taskId
  other : ∀ candidate, candidate ≠ taskId →
    (WorldRunning before candidate ↔ WorldRunning after candidate)

/-- Physical worker events project to the existing public async event trace. -/
inductive Event
    (WorkerId : Type uWorker)
    (TaskId : Type uTask)
    (NurseryId : Type uNursery)
    (WaitKey : Type uWait)
    (Failure : Type uFailure) where
  | control (event : Async.Event TaskId NurseryId WaitKey Failure)
  | claim (worker : WorkerId) (task : TaskId)
  | releaseSuspend
      (worker : WorkerId)
      (task : TaskId)
      (reason : Async.WaitReason TaskId WaitKey)
  | releaseCancel (worker : WorkerId) (task : TaskId)
  | releaseComplete
      (worker : WorkerId)
      (task : TaskId)
      (outcome : Async.TaskOutcome Failure)
  deriving DecidableEq, Repr

def Event.project :
    Event WorkerId TaskId NurseryId WaitKey Failure →
      Async.Event TaskId NurseryId WaitKey Failure
  | .control event => event
  | .claim _ task => .dispatch task
  | .releaseSuspend _ task reason => .suspend task reason
  | .releaseCancel _ task => .observeCancel task .suspend
  | .releaseComplete _ task outcome => .complete task outcome

/--
One physical-worker transition. Every constructor carries its public async
transition, making trace refinement explicit rather than backend folklore.
-/
inductive Step
    [DecidableEq WorkerId]
    [DecidableEq TaskId]
    [DecidableEq NurseryId] :
    Machine WorkerId TaskId NurseryId WaitKey Failure →
      Event WorkerId TaskId NurseryId WaitKey Failure →
      Machine WorkerId TaskId NurseryId WaitKey Failure → Prop where
  | control
      (before : Machine WorkerId TaskId NurseryId WaitKey Failure)
      (event : Async.Event TaskId NurseryId WaitKey Failure)
      (afterWorld : Async.World TaskId NurseryId WaitKey Failure)
      (transition : Async.Step before.world event afterWorld)
      (stable : SameRunningSet before.world afterWorld) :
      Step before (.control event) (before.withWorld afterWorld)
  | claim
      (before : Machine WorkerId TaskId NurseryId WaitKey Failure)
      (worker : WorkerId)
      (taskId : TaskId)
      (afterWorld : Async.World TaskId NurseryId WaitKey Failure)
      (idle : before.workers worker = .idle)
      (transition : Async.Step before.world (.dispatch taskId) afterWorld)
      (adds : AddsRunning before.world afterWorld taskId) :
      Step before (.claim worker taskId)
        ((before.setWorker worker (.running taskId)).withWorld afterWorld)
  | releaseSuspend
      (before : Machine WorkerId TaskId NurseryId WaitKey Failure)
      (worker : WorkerId)
      (taskId : TaskId)
      (reason : Async.WaitReason TaskId WaitKey)
      (afterWorld : Async.World TaskId NurseryId WaitKey Failure)
      (owned : before.Owns worker taskId)
      (transition : Async.Step before.world (.suspend taskId reason) afterWorld)
      (removes : RemovesRunning before.world afterWorld taskId) :
      Step before (.releaseSuspend worker taskId reason)
        ((before.setWorker worker .idle).withWorld afterWorld)
  | releaseCancel
      (before : Machine WorkerId TaskId NurseryId WaitKey Failure)
      (worker : WorkerId)
      (taskId : TaskId)
      (afterWorld : Async.World TaskId NurseryId WaitKey Failure)
      (owned : before.Owns worker taskId)
      (transition :
        Async.Step before.world (.observeCancel taskId .suspend) afterWorld)
      (removes : RemovesRunning before.world afterWorld taskId) :
      Step before (.releaseCancel worker taskId)
        ((before.setWorker worker .idle).withWorld afterWorld)
  | releaseComplete
      (before : Machine WorkerId TaskId NurseryId WaitKey Failure)
      (worker : WorkerId)
      (taskId : TaskId)
      (outcome : Async.TaskOutcome Failure)
      (afterWorld : Async.World TaskId NurseryId WaitKey Failure)
      (owned : before.Owns worker taskId)
      (transition : Async.Step before.world (.complete taskId outcome) afterWorld)
      (removes : RemovesRunning before.world afterWorld taskId) :
      Step before (.releaseComplete worker taskId outcome)
        ((before.setWorker worker .idle).withWorld afterWorld)

end VibeFormal.Parallel
