import VibeFormal.Async.State

set_option autoImplicit false

namespace VibeFormal.Parallel

universe uWorker uTask uNursery uWait uFailure uLocation

variable {WorkerId : Type uWorker}
variable {TaskId : Type uTask}
variable {NurseryId : Type uNursery}
variable {WaitKey : Type uWait}
variable {Failure : Type uFailure}
variable {Location : Type uLocation}

/-- A backend worker is either available or owns one running logical task. -/
inductive WorkerSlot (TaskId : Type uTask) where
  | idle
  | running (task : TaskId)
  deriving DecidableEq, Repr

/--
A parallel backend overlays physical worker ownership on the async oracle.
Worker ids and worker count are not observable language values.
-/
structure Machine
    (WorkerId : Type uWorker)
    (TaskId : Type uTask)
    (NurseryId : Type uNursery)
    (WaitKey : Type uWait)
    (Failure : Type uFailure) where
  world : Async.World TaskId NurseryId WaitKey Failure
  workers : WorkerId → WorkerSlot TaskId

/-- A logical task is currently executing between scheduler boundaries. -/
def WorldRunning
    (world : Async.World TaskId NurseryId WaitKey Failure)
    (taskId : TaskId) : Prop :=
  ∃ task requested,
    world.tasks taskId = some task ∧
      task.status = .live .running requested

namespace Machine

def setWorker
    [DecidableEq WorkerId]
    (machine : Machine WorkerId TaskId NurseryId WaitKey Failure)
    (worker : WorkerId)
    (slot : WorkerSlot TaskId) :
    Machine WorkerId TaskId NurseryId WaitKey Failure :=
  { machine with
    workers := fun candidate =>
      if candidate = worker then slot else machine.workers candidate }

def withWorld
    (machine : Machine WorkerId TaskId NurseryId WaitKey Failure)
    (world : Async.World TaskId NurseryId WaitKey Failure) :
    Machine WorkerId TaskId NurseryId WaitKey Failure :=
  { machine with world := world }

@[simp]
theorem setWorker_self
    [DecidableEq WorkerId]
    (machine : Machine WorkerId TaskId NurseryId WaitKey Failure)
    (worker : WorkerId)
    (slot : WorkerSlot TaskId) :
    (machine.setWorker worker slot).workers worker = slot := by
  simp [setWorker]

@[simp]
theorem setWorker_other
    [DecidableEq WorkerId]
    (machine : Machine WorkerId TaskId NurseryId WaitKey Failure)
    (worker other : WorkerId)
    (slot : WorkerSlot TaskId)
    (different : other ≠ worker) :
    (machine.setWorker worker slot).workers other = machine.workers other := by
  simp [setWorker, different]

def Owns
    (machine : Machine WorkerId TaskId NurseryId WaitKey Failure)
    (worker : WorkerId)
    (taskId : TaskId) : Prop :=
  machine.workers worker = .running taskId

def Assigned
    (machine : Machine WorkerId TaskId NurseryId WaitKey Failure)
    (taskId : TaskId) : Prop :=
  ∃ worker, machine.Owns worker taskId

/-- Running logical tasks and physical worker ownership correspond one-to-one. -/
structure WellFormed
    (machine : Machine WorkerId TaskId NurseryId WaitKey Failure) : Prop where
  assignmentRunning :
    ∀ worker taskId, machine.Owns worker taskId →
      WorldRunning machine.world taskId
  runningAssigned :
    ∀ taskId, WorldRunning machine.world taskId → machine.Assigned taskId
  uniqueOwner :
    ∀ worker₁ worker₂ taskId,
      machine.Owns worker₁ taskId →
      machine.Owns worker₂ taskId →
      worker₁ = worker₂

end Machine

/-- Baseline per-task heap partition used by copy-on-send backends. -/
structure HeapOwnership
    (TaskId : Type uTask)
    (Location : Type uLocation) where
  owner : Location → Option TaskId

def HeapOwnership.MayAccess
    (ownership : HeapOwnership TaskId Location)
    (taskId : TaskId)
    (location : Location) : Prop :=
  ownership.owner location = some taskId

end VibeFormal.Parallel
