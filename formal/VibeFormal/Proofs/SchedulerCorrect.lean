import VibeFormal.Compiler.Scheduler

set_option autoImplicit false

namespace VibeFormal.Compiler

universe u v w

variable {ModuleId : Type u}
variable {JobResult : Type v}
variable {Output : Type w}

/-- A step publishes exactly one previously unpublished ready module. -/
theorem step_publishes_one_ready_module
    [DecidableEq ModuleId]
    {project : Project ModuleId}
    {job : CompileJob ModuleId JobResult}
    {before after : BuildState ModuleId JobResult}
    (transition : Step project job before after) :
    ∃ moduleId,
      Ready project before moduleId ∧
      after.results moduleId =
        some (runJob project job before moduleId) ∧
      ∀ other, other ≠ moduleId →
        after.results other = before.results other := by
  cases transition with
  | run moduleId ready =>
      refine ⟨moduleId, ready, ?_, ?_⟩
      · exact BuildState.finish_self before moduleId _
      · intro other different
        exact BuildState.finish_other before moduleId other _ different

theorem step_preserves_store_correct
    [DecidableEq ModuleId]
    {project : Project ModuleId}
    {job : CompileJob ModuleId JobResult}
    {expected : ModuleId → JobResult}
    (jobCorrect : JobCorrect project job expected)
    {before after : BuildState ModuleId JobResult}
    (transition : Step project job before after)
    (beforeCorrect : StoreCorrect expected before) :
    StoreCorrect expected after := by
  cases transition with
  | run moduleId ready =>
      intro candidate result published
      by_cases same : candidate = moduleId
      · subst candidate
        have produced := jobCorrect before moduleId beforeCorrect ready
        rw [BuildState.finish_self] at published
        have publishedResult := Option.some.inj published
        exact publishedResult.symm.trans produced
      · rw [BuildState.finish_other before moduleId candidate _ same] at published
        exact beforeCorrect candidate result published

theorem runs_preserve_store_correct
    [DecidableEq ModuleId]
    {project : Project ModuleId}
    {job : CompileJob ModuleId JobResult}
    {expected : ModuleId → JobResult}
    (jobCorrect : JobCorrect project job expected)
    {start finish : BuildState ModuleId JobResult}
    (execution : Runs (Step project job) start finish)
    (startCorrect : StoreCorrect expected start) :
    StoreCorrect expected finish := by
  induction execution with
  | refl => exact startCorrect
  | tail transition rest inductionHypothesis =>
      exact inductionHypothesis
        (step_preserves_store_correct jobCorrect transition startCorrect)

theorem complete_results_eq_expected
    {expected : ModuleId → JobResult}
    {state : BuildState ModuleId JobResult}
    (correct : StoreCorrect expected state)
    (complete : Complete state) :
    state.results = fun moduleId => some (expected moduleId) := by
  funext moduleId
  obtain ⟨result, published⟩ := complete moduleId
  have resultCorrect := correct moduleId result published
  rw [resultCorrect] at published
  exact published

theorem complete_correct_states_equal
    {expected : ModuleId → JobResult}
    {left right : BuildState ModuleId JobResult}
    (leftCorrect : StoreCorrect expected left)
    (leftComplete : Complete left)
    (rightCorrect : StoreCorrect expected right)
    (rightComplete : Complete right) :
    left = right := by
  have resultsEqual := (complete_results_eq_expected leftCorrect leftComplete).trans
    (complete_results_eq_expected rightCorrect rightComplete).symm
  cases left
  cases right
  cases resultsEqual
  rfl

/--
If two schedules both complete, their result stores are equal regardless of
which ready module each scheduler selected first.
-/
theorem complete_schedules_are_deterministic
    [DecidableEq ModuleId]
    {project : Project ModuleId}
    {job : CompileJob ModuleId JobResult}
    {expected : ModuleId → JobResult}
    (jobCorrect : JobCorrect project job expected)
    {start left right : BuildState ModuleId JobResult}
    (startCorrect : StoreCorrect expected start)
    (leftRun : Runs (Step project job) start left)
    (rightRun : Runs (Step project job) start right)
    (leftComplete : Complete left)
    (rightComplete : Complete right) :
    left = right := by
  exact complete_correct_states_equal
    (runs_preserve_store_correct jobCorrect leftRun startCorrect)
    leftComplete
    (runs_preserve_store_correct jobCorrect rightRun startCorrect)
    rightComplete

/-- A pure canonical linker/emitter observes the same output for all schedules. -/
theorem emitted_output_is_deterministic
    [DecidableEq ModuleId]
    {project : Project ModuleId}
    {job : CompileJob ModuleId JobResult}
    {expected : ModuleId → JobResult}
    (jobCorrect : JobCorrect project job expected)
    {start left right : BuildState ModuleId JobResult}
    (startCorrect : StoreCorrect expected start)
    (leftRun : Runs (Step project job) start left)
    (rightRun : Runs (Step project job) start right)
    (leftComplete : Complete left)
    (rightComplete : Complete right)
    (emit : BuildState ModuleId JobResult → Output) :
    emit left = emit right := by
  exact congrArg emit
    (complete_schedules_are_deterministic jobCorrect startCorrect
      leftRun rightRun leftComplete rightComplete)

end VibeFormal.Compiler
