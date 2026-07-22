import VibeFormal.Capability.Contract
import VibeFormal.Parallel.State

set_option autoImplicit false

namespace VibeFormal.Capability

universe uWorker uTask uNursery uWait uFailure

variable {WorkerId : Type uWorker}
variable {TaskId : Type uTask}
variable {NurseryId : Type uNursery}
variable {WaitKey : Type uWait}
variable {Failure : Type uFailure}

/--
A physical worker performs an operation only through the authority of the
logical task it currently owns. A worker/thread has no ambient language
authority of its own.
-/
def WorkerMayPerform
    (machine : Parallel.Machine WorkerId TaskId NurseryId WaitKey Failure)
    (taskAuthority : TaskId → Authority)
    (worker : WorkerId)
    (operation : OperationRef) : Prop :=
  ∃ task,
    machine.Owns worker task ∧ operation ∈ taskAuthority task

end VibeFormal.Capability
