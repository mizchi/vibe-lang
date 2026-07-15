import Std

set_option autoImplicit false

namespace VibeFormal.Compiler

universe u v w

variable {ModuleId : Type u}
variable {JobResult : Type v}
variable {State : Type w}

/--
An acyclic compiler project. Direct imports must have a strictly smaller rank,
which gives the scheduler a well-founded dependency order.
-/
structure Project (ModuleId : Type u) where
  dependencies : ModuleId → List ModuleId
  rank : ModuleId → Nat
  dependencyRankLt :
    ∀ moduleId dependency,
      dependency ∈ dependencies moduleId → rank dependency < rank moduleId

namespace Project

theorem no_self_dependency
    (project : Project ModuleId)
    (moduleId : ModuleId) :
    moduleId ∉ project.dependencies moduleId := by
  intro member
  exact (Nat.lt_irrefl (project.rank moduleId))
    (project.dependencyRankLt moduleId moduleId member)

end Project

/--
The coordinator-owned result store. A worker never receives this whole value;
it receives only `dependencySnapshot` for its own module.
-/
structure BuildState (ModuleId : Type u) (JobResult : Type v) where
  results : ModuleId → Option JobResult

namespace BuildState

/-- No module has completed in the initial state. -/
def empty : BuildState ModuleId JobResult :=
  ⟨fun _ => none⟩

/-- Publish one completed job result without mutating any other entry. -/
def finish [DecidableEq ModuleId]
    (state : BuildState ModuleId JobResult)
    (moduleId : ModuleId)
    (result : JobResult) : BuildState ModuleId JobResult :=
  ⟨fun candidate =>
    if candidate = moduleId then some result else state.results candidate⟩

@[simp]
theorem finish_self [DecidableEq ModuleId]
    (state : BuildState ModuleId JobResult)
    (moduleId : ModuleId)
    (result : JobResult) :
    (state.finish moduleId result).results moduleId = some result := by
  simp [finish]

@[simp]
theorem finish_other [DecidableEq ModuleId]
    (state : BuildState ModuleId JobResult)
    (moduleId other : ModuleId)
    (result : JobResult)
    (different : other ≠ moduleId) :
    (state.finish moduleId result).results other = state.results other := by
  simp [finish, different]

end BuildState

/-- A module has reached a terminal worker result. -/
def Completed
    (state : BuildState ModuleId JobResult)
    (moduleId : ModuleId) : Prop :=
  ∃ result, state.results moduleId = some result

/-- A job may start exactly once and only after all direct dependencies finish. -/
def Ready
    (project : Project ModuleId)
    (state : BuildState ModuleId JobResult)
    (moduleId : ModuleId) : Prop :=
  state.results moduleId = none ∧
    ∀ dependency, dependency ∈ project.dependencies moduleId →
      Completed state dependency

/-- Workers see only a stable, module-local dependency snapshot. -/
def dependencySnapshot
    (project : Project ModuleId)
    (state : BuildState ModuleId JobResult)
    (moduleId : ModuleId) : List (ModuleId × Option JobResult) :=
  (project.dependencies moduleId).map fun dependency =>
    (dependency, state.results dependency)

/-- The pure worker boundary used by the scheduler model. -/
abbrev CompileJob (ModuleId : Type u) (JobResult : Type v) :=
  ModuleId → List (ModuleId × Option JobResult) → JobResult

def runJob
    (project : Project ModuleId)
    (job : CompileJob ModuleId JobResult)
    (state : BuildState ModuleId JobResult)
    (moduleId : ModuleId) : JobResult :=
  job moduleId (dependencySnapshot project state moduleId)

/-- One nondeterministically selected ready job completes and is published. -/
inductive Step [DecidableEq ModuleId]
    (project : Project ModuleId)
    (job : CompileJob ModuleId JobResult) :
    BuildState ModuleId JobResult → BuildState ModuleId JobResult → Prop where
  | run (state : BuildState ModuleId JobResult) (moduleId : ModuleId)
      (ready : Ready project state moduleId) :
      Step project job state
        (state.finish moduleId (runJob project job state moduleId))

/-- Reflexive-transitive closure of scheduler steps. -/
inductive Runs (relation : State → State → Prop) : State → State → Prop where
  | refl (state : State) : Runs relation state state
  | tail {start next finish : State} :
      relation start next → Runs relation next finish → Runs relation start finish

/-- Every published result agrees with the canonical sequential result. -/
def StoreCorrect
    (expected : ModuleId → JobResult)
    (state : BuildState ModuleId JobResult) : Prop :=
  ∀ moduleId result, state.results moduleId = some result →
    result = expected moduleId

/--
Worker contract: on a correct ready snapshot, compiling a module yields its
canonical result. `JobResult` may represent either an artifact or diagnostics.
-/
def JobCorrect
    (project : Project ModuleId)
    (job : CompileJob ModuleId JobResult)
    (expected : ModuleId → JobResult) : Prop :=
  ∀ state moduleId,
    StoreCorrect expected state →
    Ready project state moduleId →
    runJob project job state moduleId = expected moduleId

/-- Every module has a terminal result. -/
def Complete (state : BuildState ModuleId JobResult) : Prop :=
  ∀ moduleId, Completed state moduleId

end VibeFormal.Compiler
