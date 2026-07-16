import VibeFormal.Proofs.AsyncSafety
import VibeFormal.Proofs.NurseryCorrect

set_option autoImplicit false

namespace VibeFormal.Async.Examples

abbrev DemoTaskState := TaskState Nat Nat Nat String
abbrev DemoWorld := World Nat Nat Nat String

private def readyChild : DemoTaskState := TaskState.ready 0
private def runningChild : DemoTaskState := TaskState.running 0
private def cancelRequestedReady : DemoTaskState := readyChild.requestCancel

private def singletonWorld
    (task : DemoTaskState)
    (phase : NurseryPhase String) : DemoWorld :=
  { tasks := fun taskId => if taskId = 1 then some task else none
    nurseries := fun nurseryId => if nurseryId = 0 then some phase else none }

private def siblingWorld : DemoWorld :=
  { tasks := fun taskId =>
      if taskId = 1 then some runningChild
      else if taskId = 2 then some readyChild
      else none
    nurseries := fun nurseryId =>
      if nurseryId = 0 then some .open else none }

/-- Repeating a cancellation request changes no logical state. -/
example : cancelRequestedReady.requestCancel = cancelRequestedReady := by
  native_decide

/-- Dispatch is a cancel point: a not-yet-started child may cancel there. -/
private def beforeDispatchCancel : DemoWorld :=
  singletonWorld cancelRequestedReady .open

private def afterDispatchCancel : DemoWorld :=
  beforeDispatchCancel.setTask 1
    { cancelRequestedReady with status := .terminal .cancelled }

example :
    Step beforeDispatchCancel (.observeCancel 1 .dispatch)
      afterDispatchCancel := by
  apply Step.observeCancel beforeDispatchCancel 1 cancelRequestedReady .ready
  · simp [beforeDispatchCancel, singletonWorld]
  · rfl
  · exact AtCancelPoint.dispatch

/-- A first child failure requests sibling cancellation and records its cause. -/
private def afterFirstFailure : DemoWorld :=
  siblingWorld.failTask 1 runningChild .open "boom"

example :
    Step siblingWorld (.complete 1 (.failed "boom")) afterFirstFailure := by
  apply Step.completeFailed siblingWorld 1 runningChild false .open "boom"
  · simp [siblingWorld]
  · rfl
  · simp [siblingWorld, runningChild, TaskState.running]
  · simp [NurseryPhase.IsClosed]

example :
    afterFirstFailure.nurseries 0 = some (.cancelling (.failed "boom")) := by
  native_decide

example :
    ∃ sibling,
      afterFirstFailure.tasks 2 = some sibling ∧ sibling.CancelRequested := by
  refine ⟨readyChild.requestCancel, ?_, ?_⟩
  · native_decide
  · exact ⟨.ready, rfl⟩

/-- Explicit child cancellation alone does not turn a successful body into failure. -/
private def explicitCancelStart : DemoWorld :=
  singletonWorld runningChild .open

private def explicitCancelRequested : DemoWorld :=
  explicitCancelStart.setTask 1 runningChild.requestCancel

private def explicitCancelTerminal : DemoWorld :=
  explicitCancelRequested.setTask 1
    { runningChild with status := .terminal .cancelled }

private def completionWinsTerminal : DemoWorld :=
  explicitCancelRequested.setTask 1
    { runningChild with status := .terminal .succeeded }

private def explicitCancelClosing : DemoWorld :=
  explicitCancelTerminal.setNursery 0 (.closing .succeeded)

private def explicitCancelClosed : DemoWorld :=
  explicitCancelClosing.setNursery 0 (.closed .succeeded)

/-- Completion may win if a running task reaches no later cancel point. -/
example :
    Execution explicitCancelStart
      [ .requestCancel 1, .complete 1 .succeeded ]
      completionWinsTerminal := by
  apply Execution.step
    (Step.requestCancel explicitCancelStart 1 runningChild (by
      simp [explicitCancelStart, singletonWorld]))
  apply Execution.step
    (Step.completeSucceeded explicitCancelRequested 1 runningChild.requestCancel true
      (by simp [explicitCancelRequested]) rfl)
  exact Execution.refl _

example :
    Execution explicitCancelStart
      [ .requestCancel 1,
        .observeCancel 1 .suspend,
        .beginClose 0,
        .close 0 .succeeded ]
      explicitCancelClosed := by
  apply Execution.step
    (Step.requestCancel explicitCancelStart 1 runningChild (by
      simp [explicitCancelStart, singletonWorld]))
  apply Execution.step
    (Step.observeCancel explicitCancelRequested 1 runningChild.requestCancel
      .running .suspend (by simp [explicitCancelRequested]) rfl
      AtCancelPoint.suspend)
  apply Execution.step
    (Step.beginClose explicitCancelTerminal 0 (by
      simp [explicitCancelTerminal, explicitCancelRequested,
        explicitCancelStart, singletonWorld, World.setTask]))
  apply Execution.step
    (Step.close explicitCancelClosing 0 .succeeded (by
      simp [explicitCancelClosing]) (by
      intro taskId task present owned
      by_cases same : taskId = 1
      · subst taskId
        simp [explicitCancelClosing, explicitCancelTerminal,
          explicitCancelRequested, explicitCancelStart, singletonWorld,
          World.setTask, World.setNursery] at present
        subst task
        exact ⟨.cancelled, rfl⟩
      · have missing : explicitCancelClosing.tasks taskId = none := by
          simp [explicitCancelClosing, explicitCancelTerminal,
            explicitCancelRequested, explicitCancelStart, singletonWorld,
            World.setTask, World.setNursery, same]
        rw [missing] at present
        contradiction))
  exact Execution.refl _

example : explicitCancelClosed.nurseries 0 = some (.closed .succeeded) := by
  native_decide

/-- Deliberately broken witnesses are rejected by the transition contract. -/
private def closedWorld : DemoWorld := singletonWorld readyChild (.closed .succeeded)

example : ¬∃ after, Step closedWorld (.spawn 0 2) after := by
  exact spawn_rejected_unless_open (world := closedWorld) (nursery := 0)
    (child := 2) (by simp [closedWorld, singletonWorld])

private def liveClosingWorld : DemoWorld :=
  singletonWorld readyChild (.closing .succeeded)

example : ¬∃ after, Step liveClosingWorld (.close 0 .succeeded) after := by
  exact close_rejected_with_live_child
    (world := liveClosingWorld) (nursery := 0) (cause := .succeeded)
    (taskId := 1) (task := readyChild)
    (by simp [liveClosingWorld, singletonWorld]) rfl rfl

end VibeFormal.Async.Examples
