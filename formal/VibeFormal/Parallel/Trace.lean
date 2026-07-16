import VibeFormal.Async.Trace
import VibeFormal.Parallel.Transition

set_option autoImplicit false

namespace VibeFormal.Parallel

universe uWorker uTask uNursery uWait uFailure

variable {WorkerId : Type uWorker}
variable {TaskId : Type uTask}
variable {NurseryId : Type uNursery}
variable {WaitKey : Type uWait}
variable {Failure : Type uFailure}

/-- A chronological physical-worker execution. -/
inductive Execution
    [DecidableEq WorkerId]
    [DecidableEq TaskId]
    [DecidableEq NurseryId] :
    Machine WorkerId TaskId NurseryId WaitKey Failure →
      List (Event WorkerId TaskId NurseryId WaitKey Failure) →
      Machine WorkerId TaskId NurseryId WaitKey Failure → Prop where
  | refl (machine : Machine WorkerId TaskId NurseryId WaitKey Failure) :
      Execution machine [] machine
  | step
      {start next finish : Machine WorkerId TaskId NurseryId WaitKey Failure}
      {event : Event WorkerId TaskId NurseryId WaitKey Failure}
      {events : List (Event WorkerId TaskId NurseryId WaitKey Failure)} :
      Step start event next →
      Execution next events finish →
      Execution start (event :: events) finish

def projectEvents
    (events : List (Event WorkerId TaskId NurseryId WaitKey Failure)) :
    List (Async.Event TaskId NurseryId WaitKey Failure) :=
  events.map Event.project

end VibeFormal.Parallel
