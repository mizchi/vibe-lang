import VibeFormal.Effect.ExceptionPolicy

set_option autoImplicit false

namespace VibeFormal.ExceptionPolicy

/-- Every escaping typed exception retains its exact kind in the static row. -/
theorem raised_requires_exception
    (term : Term)
    (kind : ExceptionKind)
    (observed : run term = .raised kind) :
    .exception kind ∈ requirements term := by
  induction term with
  | returned => simp [run] at observed
  | throwException thrownKind =>
      simp only [run, Outcome.raised.injEq] at observed
      subst thrownKind
      simp [requirements]
  | perform operation => simp [run] at observed
  | call callee inductionHypothesis =>
      exact inductionHypothesis observed
  | seq first second firstHypothesis secondHypothesis =>
      simp only [run] at observed
      split at observed
      · simp [requirements, normalizeRequirements, secondHypothesis observed]
      · rename_i outcome equation
        cases outcome <;> simp_all [requirements, normalizeRequirements]
  | handleException handledKind body inductionHypothesis =>
      cases bodyOutcome : run body with
      | returned => simp [run, bodyOutcome] at observed
      | performed operation => simp [run, bodyOutcome] at observed
      | raised raisedKind =>
          by_cases sameKind : raisedKind = handledKind
          · simp [run, bodyOutcome, sameKind] at observed
          · have kindEq : raisedKind = kind := by
              simpa [run, bodyOutcome, sameKind] using observed
            subst raisedKind
            have tracked := inductionHypothesis bodyOutcome
            simpa [requirements, sameKind] using tracked

/-- Capability operations remain tracked independently of typed exceptions. -/
theorem performed_requires_capability
    (term : Term)
    (operation : OperationRef)
    (observed : run term = .performed operation) :
    .capability operation ∈ requirements term := by
  induction term with
  | returned => simp [run] at observed
  | throwException kind => simp [run] at observed
  | perform performedOperation =>
      simp only [run, Outcome.performed.injEq] at observed
      subst performedOperation
      simp [requirements]
  | call callee inductionHypothesis =>
      exact inductionHypothesis observed
  | seq first second firstHypothesis secondHypothesis =>
      simp only [run] at observed
      split at observed
      · simp [requirements, normalizeRequirements, secondHypothesis observed]
      · rename_i outcome equation
        cases outcome <;> simp_all [requirements, normalizeRequirements]
  | handleException handledKind body inductionHypothesis =>
      cases bodyOutcome : run body with
      | returned => simp [run, bodyOutcome] at observed
      | raised raisedKind =>
          by_cases sameKind : raisedKind = handledKind <;>
            simp [run, bodyOutcome, sameKind] at observed
      | performed performedOperation =>
          simp only [run, bodyOutcome, Outcome.performed.injEq] at observed
          subst performedOperation
          have tracked := inductionHypothesis bodyOutcome
          simpa [requirements] using tracked

/-- An empty checked row cannot end in any unhandled typed exception. -/
theorem empty_cannot_raise
    (term : Term)
    (allowed : Allowed [] term)
    (kind : ExceptionKind) :
    run term ≠ .raised kind := by
  intro observed
  have tracked := raised_requires_exception term kind observed
  have impossible := allowed (.exception kind) tracked
  simp at impossible

/-- A handler discharges only the exact exception kind it names. -/
theorem handler_does_not_catch_other_kind
    (handled raised : ExceptionKind)
    (different : raised ≠ handled) :
    run (.handleException handled (.throwException raised)) = .raised raised := by
  simp [run, different]

/--
Erasing exception identity makes the checker accept an empty row even though
an exception of a different kind escapes. This witness makes kind identity
load-bearing rather than documentary.
-/
theorem broken_cross_kind_handler_is_unsound :
    BrokenAllowed [] (.handleException 0 (.throwException 1)) ∧
      run (.handleException 0 (.throwException 1)) = .raised 1 := by
  simp [BrokenAllowed, brokenRequirements, run]

end VibeFormal.ExceptionPolicy
