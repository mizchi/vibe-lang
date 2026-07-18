import VibeFormal.Typing.Call

set_option autoImplicit false

namespace VibeFormal.Typing

/-- The executable validation bit has the intended pointwise typing meaning. -/
theorem resolved_arguments_match_sound
    (typeArguments : List Ty)
    (arguments : List ResolvedArgument)
    (validation : resolvedArgumentsMatch typeArguments arguments = true) :
    ResolvedArgumentsWellTyped typeArguments arguments := by
  induction arguments with
  | nil => simp [ResolvedArgumentsWellTyped]
  | cons argument rest inductionHypothesis =>
      simp only [resolvedArgumentsMatch, Bool.and_eq_true, decide_eq_true_eq] at validation
      simp only [ResolvedArgumentsWellTyped]
      exact ⟨validation.1, inductionHypothesis validation.2⟩

/-- Nominal type equality cannot silently forget either constructor arguments. -/
theorem named_type_injective
    {leftName rightName : String}
    {leftArguments rightArguments : TyArgs}
    (equal : Ty.nominal leftName leftArguments = Ty.nominal rightName rightArguments) :
    leftName = rightName ∧ leftArguments = rightArguments := by
  injection equal with names arguments
  exact ⟨names, arguments⟩

/-- Every successful call retains the exact argument-resolution witness. -/
theorem accepted_call_resolution
    (signature : Signature)
    (arguments : List Argument)
    (checked : CheckedCall signature arguments)
    (_accepted : checkCall signature arguments = .ok checked) :
    resolveArguments signature.parameters arguments = .ok checked.resolvedArguments :=
  checked.resolutionCorrect

/-- Every successful call matches all arguments after generic instantiation. -/
theorem accepted_call_arguments_match
    (signature : Signature)
    (arguments : List Argument)
    (checked : CheckedCall signature arguments)
    (_accepted : checkCall signature arguments = .ok checked) :
    ResolvedArgumentsWellTyped checked.typeArguments checked.resolvedArguments :=
  resolved_arguments_match_sound _ _ checked.argumentsMatch

/-- The reported return type is the unique instantiated signature result. -/
theorem accepted_call_return_instantiated
    (signature : Signature)
    (arguments : List Argument)
    (checked : CheckedCall signature arguments)
    (_accepted : checkCall signature arguments = .ok checked) :
    Ty.instantiate checked.typeArguments signature.returnType = some checked.returnType :=
  checked.returnTypeInstantiated

/-- One concrete generic substitution cannot produce two different return types. -/
theorem instantiated_return_unique
    (typeArguments : List Ty)
    (returnPattern first second : Ty)
    (firstResult : Ty.instantiate typeArguments returnPattern = some first)
    (secondResult : Ty.instantiate typeArguments returnPattern = some second) :
    first = second := by
  rw [firstResult] at secondResult
  exact Option.some.inj secondResult

end VibeFormal.Typing
