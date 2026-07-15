import VibeFormal.Proofs.SchedulerCorrect

set_option autoImplicit false

namespace VibeFormal.Compiler.Examples

inductive DemoModule where
  | base
  | frontend
  | backend
  | app
  deriving DecidableEq, Repr

def demoDependencies : DemoModule → List DemoModule
  | .base => []
  | .frontend => [.base]
  | .backend => [.base]
  | .app => [.frontend, .backend]

def demoRank : DemoModule → Nat
  | .base => 0
  | .frontend => 1
  | .backend => 1
  | .app => 2

def demoProject : Project DemoModule where
  dependencies := demoDependencies
  rank := demoRank
  dependencyRankLt := by
    intro moduleId dependency member
    cases moduleId with
    | base => simp [demoDependencies] at member
    | frontend =>
        simp [demoDependencies] at member
        subst dependency
        decide
    | backend =>
        simp [demoDependencies] at member
        subst dependency
        decide
    | app =>
        simp [demoDependencies] at member
        rcases member with same | same
        · subst dependency
          decide
        · subst dependency
          decide

def expectedResult : DemoModule → Nat
  | .base => 10
  | .frontend => 20
  | .backend => 30
  | .app => 60

def demoJob : CompileJob DemoModule Nat :=
  fun moduleId _dependencySnapshot => expectedResult moduleId

def initial : BuildState DemoModule Nat := BuildState.empty
def afterBase : BuildState DemoModule Nat := initial.finish .base 10
def afterFrontend : BuildState DemoModule Nat :=
  afterBase.finish .frontend 20
def afterBackend : BuildState DemoModule Nat :=
  afterBase.finish .backend 30
def frontendThenBackend : BuildState DemoModule Nat :=
  afterFrontend.finish .backend 30
def backendThenFrontend : BuildState DemoModule Nat :=
  afterBackend.finish .frontend 20
def frontendFirstFinal : BuildState DemoModule Nat :=
  frontendThenBackend.finish .app 60
def backendFirstFinal : BuildState DemoModule Nat :=
  backendThenFrontend.finish .app 60

theorem initial_correct : StoreCorrect expectedResult initial := by
  intro moduleId result published
  simp [initial, BuildState.empty] at published

theorem demo_job_correct : JobCorrect demoProject demoJob expectedResult := by
  intro state moduleId stateCorrect ready
  rfl

theorem ready_base : Ready demoProject initial .base := by
  constructor
  · rfl
  · intro dependency member
    simp [demoProject, demoDependencies] at member

theorem ready_frontend_after_base :
    Ready demoProject afterBase .frontend := by
  constructor
  · simp [afterBase, initial, BuildState.empty]
  · intro dependency member
    simp [demoProject, demoDependencies] at member
    subst dependency
    exact ⟨10, by simp [afterBase]⟩

theorem ready_backend_after_base :
    Ready demoProject afterBase .backend := by
  constructor
  · simp [afterBase, initial, BuildState.empty]
  · intro dependency member
    simp [demoProject, demoDependencies] at member
    subst dependency
    exact ⟨10, by simp [afterBase]⟩

theorem ready_backend_after_frontend :
    Ready demoProject afterFrontend .backend := by
  constructor
  · simp [afterFrontend, afterBase, initial, BuildState.empty]
  · intro dependency member
    simp [demoProject, demoDependencies] at member
    subst dependency
    exact ⟨10, by simp [afterFrontend, afterBase]⟩

theorem ready_frontend_after_backend :
    Ready demoProject afterBackend .frontend := by
  constructor
  · simp [afterBackend, afterBase, initial, BuildState.empty]
  · intro dependency member
    simp [demoProject, demoDependencies] at member
    subst dependency
    exact ⟨10, by simp [afterBackend, afterBase]⟩

theorem ready_app_after_frontend_first :
    Ready demoProject frontendThenBackend .app := by
  constructor
  · simp [frontendThenBackend, afterFrontend, afterBase, initial,
      BuildState.empty]
  · intro dependency member
    simp [demoProject, demoDependencies] at member
    rcases member with same | same
    · subst dependency
      exact ⟨20, by simp [frontendThenBackend, afterFrontend]⟩
    · subst dependency
      exact ⟨30, by simp [frontendThenBackend]⟩

theorem ready_app_after_backend_first :
    Ready demoProject backendThenFrontend .app := by
  constructor
  · simp [backendThenFrontend, afterBackend, afterBase, initial,
      BuildState.empty]
  · intro dependency member
    simp [demoProject, demoDependencies] at member
    rcases member with same | same
    · subst dependency
      exact ⟨20, by simp [backendThenFrontend]⟩
    · subst dependency
      exact ⟨30, by simp [backendThenFrontend, afterBackend]⟩

theorem frontend_first_run :
    Runs (Step demoProject demoJob) initial frontendFirstFinal := by
  apply Runs.tail (Step.run initial .base ready_base)
  apply Runs.tail (Step.run afterBase .frontend ready_frontend_after_base)
  apply Runs.tail
    (Step.run afterFrontend .backend ready_backend_after_frontend)
  apply Runs.tail
    (Step.run frontendThenBackend .app ready_app_after_frontend_first)
  exact Runs.refl _

theorem backend_first_run :
    Runs (Step demoProject demoJob) initial backendFirstFinal := by
  apply Runs.tail (Step.run initial .base ready_base)
  apply Runs.tail (Step.run afterBase .backend ready_backend_after_base)
  apply Runs.tail
    (Step.run afterBackend .frontend ready_frontend_after_backend)
  apply Runs.tail
    (Step.run backendThenFrontend .app ready_app_after_backend_first)
  exact Runs.refl _

theorem frontend_first_complete : Complete frontendFirstFinal := by
  intro moduleId
  cases moduleId <;>
    simp [Completed, frontendFirstFinal, frontendThenBackend, afterFrontend,
      afterBase, initial, BuildState.empty]

theorem backend_first_complete : Complete backendFirstFinal := by
  intro moduleId
  cases moduleId <;>
    simp [Completed, backendFirstFinal, backendThenFrontend, afterBackend,
      afterBase, initial, BuildState.empty]

example : frontendFirstFinal = backendFirstFinal := by
  exact complete_schedules_are_deterministic
    demo_job_correct initial_correct
    frontend_first_run backend_first_run
    frontend_first_complete backend_first_complete

def emitChecksum (state : BuildState DemoModule Nat) : Nat :=
  (state.results .base).getD 0 +
    (state.results .frontend).getD 0 +
    (state.results .backend).getD 0 +
    (state.results .app).getD 0

example : emitChecksum frontendFirstFinal = emitChecksum backendFirstFinal := by
  exact emitted_output_is_deterministic
    demo_job_correct initial_correct
    frontend_first_run backend_first_run
    frontend_first_complete backend_first_complete emitChecksum

/-- A worker that violates the canonical-result contract is rejected. -/
def wrongJob : CompileJob DemoModule Nat :=
  fun moduleId _snapshot =>
    match moduleId with
    | .base => 999
    | other => expectedResult other

example : ¬JobCorrect demoProject wrongJob expectedResult := by
  intro wrongCorrect
  have contradiction :=
    wrongCorrect initial .base initial_correct ready_base
  simp [runJob, wrongJob, expectedResult] at contradiction

end VibeFormal.Compiler.Examples
