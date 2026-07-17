set_option autoImplicit false

namespace VibeFormal.Async

universe uTask uNursery uWait uFailure

variable {TaskId : Type uTask}
variable {NurseryId : Type uNursery}
variable {WaitKey : Type uWait}
variable {Failure : Type uFailure}

/-- A logical reason why a task yielded control to the scheduler. -/
inductive WaitReason
    (TaskId : Type uTask)
    (WaitKey : Type uWait) where
  | join (target : TaskId)
  | external (key : WaitKey)
  | yield
  deriving DecidableEq, Repr

/-- Public terminal outcome. Recoverable user errors remain ordinary values. -/
inductive TaskOutcome (Failure : Type uFailure) where
  | succeeded
  | failed (failure : Failure)
  | cancelled
  deriving DecidableEq, Repr

/--
`ready` is waiting for dispatch, `running` is between scheduler boundaries,
and `blocked` is waiting at an explicit suspend point. Multiple tasks may be
`running` in the abstract model; a cooperative backend refines this further.
-/
inductive LivePhase
    (TaskId : Type uTask)
    (WaitKey : Type uWait) where
  | ready
  | running
  | blocked (reason : WaitReason TaskId WaitKey)
  deriving DecidableEq, Repr

/-- Cancel requests are represented only while a task is live. -/
inductive TaskStatus
    (TaskId : Type uTask)
    (WaitKey : Type uWait)
    (Failure : Type uFailure) where
  | live (phase : LivePhase TaskId WaitKey) (cancelRequested : Bool)
  | terminal (outcome : TaskOutcome Failure)
  deriving DecidableEq, Repr

structure TaskState
    (TaskId : Type uTask)
    (NurseryId : Type uNursery)
    (WaitKey : Type uWait)
    (Failure : Type uFailure) where
  nursery : NurseryId
  status : TaskStatus TaskId WaitKey Failure
  deriving DecidableEq, Repr

namespace TaskState

def ready
    (nursery : NurseryId) :
    TaskState TaskId NurseryId WaitKey Failure :=
  ⟨nursery, .live .ready false⟩

def running
    (nursery : NurseryId) :
    TaskState TaskId NurseryId WaitKey Failure :=
  ⟨nursery, .live .running false⟩

def blocked
    (nursery : NurseryId)
    (reason : WaitReason TaskId WaitKey) :
    TaskState TaskId NurseryId WaitKey Failure :=
  ⟨nursery, .live (.blocked reason) false⟩

def finished
    (nursery : NurseryId)
    (outcome : TaskOutcome Failure) :
    TaskState TaskId NurseryId WaitKey Failure :=
  ⟨nursery, .terminal outcome⟩

/-- Requesting cancellation changes only a live task and is idempotent. -/
def requestCancel
    (task : TaskState TaskId NurseryId WaitKey Failure) :
    TaskState TaskId NurseryId WaitKey Failure :=
  match task.status with
  | .live phase _ => { task with status := .live phase true }
  | .terminal _ => task

def IsTerminal
    (task : TaskState TaskId NurseryId WaitKey Failure) : Prop :=
  ∃ outcome, task.status = .terminal outcome

def IsLive
    (task : TaskState TaskId NurseryId WaitKey Failure) : Prop :=
  ∃ phase requested, task.status = .live phase requested

def CancelRequested
    (task : TaskState TaskId NurseryId WaitKey Failure) : Prop :=
  ∃ phase, task.status = .live phase true

def joinResult
    (task : TaskState TaskId NurseryId WaitKey Failure) :
    Option (TaskOutcome Failure) :=
  match task.status with
  | .live _ _ => none
  | .terminal outcome => some outcome

@[simp]
theorem requestCancel_terminal
    (nursery : NurseryId)
    (outcome : TaskOutcome Failure) :
    (finished (TaskId := TaskId) (WaitKey := WaitKey) nursery outcome).requestCancel =
      finished nursery outcome := by
  rfl

theorem requestCancel_idempotent
    (task : TaskState TaskId NurseryId WaitKey Failure) :
    task.requestCancel.requestCancel = task.requestCancel := by
  cases task with
  | mk nursery status =>
      cases status <;> rfl

end TaskState

/-- Result selected when a structured nursery closes. -/
inductive NurseryCause (Failure : Type uFailure) where
  | succeeded
  | failed (failure : Failure)
  | cancelled
  deriving DecidableEq, Repr

/-- `Cancelling` requests child cancellation before entering `Closing`. -/
inductive NurseryPhase (Failure : Type uFailure) where
  | open
  | cancelling (cause : NurseryCause Failure)
  | closing (cause : NurseryCause Failure)
  | closed (cause : NurseryCause Failure)
  deriving DecidableEq, Repr

namespace NurseryPhase

def IsClosed (phase : NurseryPhase Failure) : Prop :=
  ∃ cause, phase = .closed cause

/-- The first observed child failure becomes the nursery cause. -/
def observeFailure
    (phase : NurseryPhase Failure)
    (failure : Failure) : NurseryPhase Failure :=
  match phase with
  | .open => .cancelling (.failed failure)
  | .closing .succeeded => .cancelling (.failed failure)
  | other => other

def failureStartsCancellation (phase : NurseryPhase Failure) : Bool :=
  match phase with
  | .open | .closing .succeeded => true
  | .cancelling _ | .closing (.failed _) | .closing .cancelled | .closed _ =>
      false

end NurseryPhase

/-- Backend-independent logical state. Heaps, threads, and host waitables are absent. -/
structure World
    (TaskId : Type uTask)
    (NurseryId : Type uNursery)
    (WaitKey : Type uWait)
    (Failure : Type uFailure) where
  tasks : TaskId → Option (TaskState TaskId NurseryId WaitKey Failure)
  nurseries : NurseryId → Option (NurseryPhase Failure)

namespace World

def setTask
    [DecidableEq TaskId]
    (world : World TaskId NurseryId WaitKey Failure)
    (taskId : TaskId)
    (task : TaskState TaskId NurseryId WaitKey Failure) :
    World TaskId NurseryId WaitKey Failure :=
  { world with
    tasks := fun candidate =>
      if candidate = taskId then some task else world.tasks candidate }

def setNursery
    [DecidableEq NurseryId]
    (world : World TaskId NurseryId WaitKey Failure)
    (nurseryId : NurseryId)
    (phase : NurseryPhase Failure) :
    World TaskId NurseryId WaitKey Failure :=
  { world with
    nurseries := fun candidate =>
      if candidate = nurseryId then some phase else world.nurseries candidate }

@[simp]
theorem setTask_self
    [DecidableEq TaskId]
    (world : World TaskId NurseryId WaitKey Failure)
    (taskId : TaskId)
    (task : TaskState TaskId NurseryId WaitKey Failure) :
    (world.setTask taskId task).tasks taskId = some task := by
  simp [setTask]

@[simp]
theorem setTask_other
    [DecidableEq TaskId]
    (world : World TaskId NurseryId WaitKey Failure)
    (taskId other : TaskId)
    (task : TaskState TaskId NurseryId WaitKey Failure)
    (different : other ≠ taskId) :
    (world.setTask taskId task).tasks other = world.tasks other := by
  simp [setTask, different]

@[simp]
theorem setNursery_self
    [DecidableEq NurseryId]
    (world : World TaskId NurseryId WaitKey Failure)
    (nurseryId : NurseryId)
    (phase : NurseryPhase Failure) :
    (world.setNursery nurseryId phase).nurseries nurseryId = some phase := by
  simp [setNursery]

@[simp]
theorem setNursery_other
    [DecidableEq NurseryId]
    (world : World TaskId NurseryId WaitKey Failure)
    (nurseryId other : NurseryId)
    (phase : NurseryPhase Failure)
    (different : other ≠ nurseryId) :
    (world.setNursery nurseryId phase).nurseries other =
      world.nurseries other := by
  simp [setNursery, different]

/-- Request cancellation for every live child; terminal children are unchanged. -/
def requestCancelChildren
    [DecidableEq NurseryId]
    (world : World TaskId NurseryId WaitKey Failure)
    (nurseryId : NurseryId) : World TaskId NurseryId WaitKey Failure :=
  { world with
    tasks := fun taskId =>
      match world.tasks taskId with
      | none => none
      | some task =>
          if task.nursery = nurseryId then some task.requestCancel else some task }

def AllChildrenTerminal
    (world : World TaskId NurseryId WaitKey Failure)
    (nurseryId : NurseryId) : Prop :=
  ∀ taskId task,
    world.tasks taskId = some task →
    task.nursery = nurseryId →
    task.IsTerminal

def beginCancellation
    [DecidableEq NurseryId]
    (world : World TaskId NurseryId WaitKey Failure)
    (nurseryId : NurseryId)
    (cause : NurseryCause Failure) : World TaskId NurseryId WaitKey Failure :=
  (world.setNursery nurseryId (.cancelling cause)).requestCancelChildren nurseryId

def failTask
    [DecidableEq TaskId]
    [DecidableEq NurseryId]
    (world : World TaskId NurseryId WaitKey Failure)
    (taskId : TaskId)
    (task : TaskState TaskId NurseryId WaitKey Failure)
    (phase : NurseryPhase Failure)
    (failure : Failure) : World TaskId NurseryId WaitKey Failure :=
  let terminalized := world.setTask taskId { task with status := .terminal (.failed failure) }
  let observed := terminalized.setNursery task.nursery (phase.observeFailure failure)
  if phase.failureStartsCancellation then
    observed.requestCancelChildren task.nursery
  else
    observed

end World

end VibeFormal.Async
