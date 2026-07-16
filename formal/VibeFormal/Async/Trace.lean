import VibeFormal.Async.Transition

set_option autoImplicit false

namespace VibeFormal.Async

universe uTask uNursery uWait uFailure

variable {TaskId : Type uTask}
variable {NurseryId : Type uNursery}
variable {WaitKey : Type uWait}
variable {Failure : Type uFailure}

/-- A chronological trace accepted by the abstract async machine. -/
inductive Execution
    [DecidableEq TaskId]
    [DecidableEq NurseryId] :
    World TaskId NurseryId WaitKey Failure →
      List (Event TaskId NurseryId WaitKey Failure) →
      World TaskId NurseryId WaitKey Failure → Prop where
  | refl (world : World TaskId NurseryId WaitKey Failure) :
      Execution world [] world
  | step
      {start next finish : World TaskId NurseryId WaitKey Failure}
      {event : Event TaskId NurseryId WaitKey Failure}
      {events : List (Event TaskId NurseryId WaitKey Failure)} :
      Step start event next →
      Execution next events finish →
      Execution start (event :: events) finish

def AcceptsTrace
    [DecidableEq TaskId]
    [DecidableEq NurseryId]
    (start : World TaskId NurseryId WaitKey Failure)
    (events : List (Event TaskId NurseryId WaitKey Failure)) : Prop :=
  ∃ finish, Execution start events finish

end VibeFormal.Async
