import VibeFormal.Effect.ErrorPolicy

set_option autoImplicit false

namespace VibeFormal.ErrorPolicy

/-- Under checked exceptions, every escaping raise has a tracked Error requirement. -/
theorem raised_requires_checked_error
    (term : Term)
    (observed : run term = .raised) :
    .error ∈ requirements .checked term := by
  induction term with
  | returned => simp [run] at observed
  | throwError => simp [requirements]
  | perform operation => simp [run] at observed
  | call callee inductionHypothesis =>
      exact inductionHypothesis observed
  | seq first second firstHypothesis secondHypothesis =>
      simp only [run] at observed
      split at observed
      · simp [requirements, normalizeRequirements, secondHypothesis observed]
      · rename_i outcome equation
        cases outcome <;> simp_all [requirements, normalizeRequirements]
  | handleError body inductionHypothesis =>
      simp only [run] at observed
      split at observed <;> contradiction

/-- Capability operations remain tracked under both checked and ambient Error. -/
theorem performed_requires_capability
    (policy : Policy)
    (term : Term)
    (operation : OperationRef)
    (observed : run term = .performed operation) :
    .capability operation ∈ requirements policy term := by
  induction term with
  | returned => simp [run] at observed
  | throwError => simp [run] at observed
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
  | handleError body inductionHypothesis =>
      simp only [run] at observed
      split at observed
      · contradiction
      · simpa [requirements] using inductionHypothesis observed

/-- An empty checked row cannot end in an unhandled Error. -/
theorem checked_empty_cannot_raise
    (term : Term)
    (allowed : Allowed .checked [] term) :
    run term ≠ .raised := by
  intro observed
  have tracked := raised_requires_checked_error term observed
  have impossible := allowed .error tracked
  simp at impossible

/-- An empty row under either comparison policy excludes capability operations. -/
theorem empty_cannot_perform_capability
    (policy : Policy)
    (term : Term)
    (allowed : Allowed policy [] term)
    (operation : OperationRef) :
    run term ≠ .performed operation := by
  intro observed
  have tracked := performed_requires_capability policy term operation observed
  have impossible := allowed (.capability operation) tracked
  simp at impossible

/-- A checked empty row has only normal termination in this minimal model. -/
theorem checked_empty_returns
    (term : Term)
    (allowed : Allowed .checked [] term) :
    run term = .returned := by
  cases observed : run term with
  | returned => rfl
  | raised => exact False.elim (checked_empty_cannot_raise term allowed observed)
  | performed operation =>
      exact False.elim
        (empty_cannot_perform_capability .checked term allowed operation observed)

/-- An ambient empty row permits normal return or an escaping `Error`, but no capability exit. -/
theorem ambient_empty_returns_or_raises
    (term : Term)
    (allowed : Allowed .ambient [] term) :
    run term = .returned ∨ run term = .raised := by
  cases observed : run term with
  | returned => exact Or.inl rfl
  | raised => exact Or.inr rfl
  | performed operation =>
      exact False.elim
        (empty_cannot_perform_capability .ambient term allowed operation observed)

/-- An Error-only checked entry cannot perform an undeclared capability operation. -/
theorem checked_error_only_entry_cannot_perform_capability
    (term : Term)
    (allowed : Allowed .checked [.error] term)
    (operation : OperationRef) :
    run term ≠ .performed operation := by
  intro observed
  have tracked := performed_requires_capability .checked term operation observed
  have impossible := allowed (.capability operation) tracked
  simp at impossible

/-- The runtime entry boundary converts every escaping checked Error to process failure. -/
theorem checked_error_only_entry_succeeds_or_fails
    (term : Term)
    (allowed : Allowed .checked [.error] term) :
    runEntry term = .succeeded ∨ runEntry term = .failedWithError := by
  cases observed : run term with
  | returned => exact Or.inl (by simp [runEntry, observed])
  | raised => exact Or.inr (by simp [runEntry, observed])
  | performed operation =>
      exact False.elim
        (checked_error_only_entry_cannot_perform_capability
          term allowed operation observed)

end VibeFormal.ErrorPolicy
