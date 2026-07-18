import VibeFormal.Typing.Core

set_option autoImplicit false

namespace VibeFormal.Typing

structure Parameter where
  label : Option String
  type : Ty
  deriving DecidableEq, Repr

structure Signature where
  name : String
  typeParameterCount : Nat
  parameters : List Parameter
  returnType : Ty
  deriving DecidableEq, Repr

inductive Argument where
  | positional (type : Ty)
  | labeled (label : String) (type : Ty)
  deriving DecidableEq, Repr

namespace Argument

def type : Argument → Ty
  | .positional type => type
  | .labeled _ type => type

def isPositional : Argument → Bool
  | .positional _ => true
  | .labeled _ _ => false

def isLabeled : Argument → Bool
  | .positional _ => false
  | .labeled _ _ => true

end Argument

inductive CallErrorKind where
  | arityMismatch
  | mixedArgumentModes
  | unknownLabel
  | duplicateLabel
  | typeMismatch
  | unresolvedTypeParameter
  | malformedSignature
  | internalValidation
  deriving DecidableEq, Repr

inductive CallError where
  | arityMismatch (expected actual : Nat)
  | mixedArgumentModes
  | unknownLabel (label : String)
  | duplicateArgumentLabel (label : String)
  | duplicateParameterLabel (label : String)
  | typeMismatch (parameterIndex : Nat) (expected actual : Ty)
  | unresolvedTypeParameter (index : Nat)
  | invalidTypeVariable (index : Nat)
  | invalidReturnType
  | internalValidationFailure
  deriving DecidableEq, Repr

namespace CallError

def kind : CallError → CallErrorKind
  | .arityMismatch _ _ => .arityMismatch
  | .mixedArgumentModes => .mixedArgumentModes
  | .unknownLabel _ => .unknownLabel
  | .duplicateArgumentLabel _ => .duplicateLabel
  | .duplicateParameterLabel _ => .duplicateLabel
  | .typeMismatch _ _ _ => .typeMismatch
  | .unresolvedTypeParameter _ => .unresolvedTypeParameter
  | .invalidTypeVariable _ => .malformedSignature
  | .invalidReturnType => .malformedSignature
  | .internalValidationFailure => .internalValidation

end CallError

structure ResolvedArgument where
  parameterIndex : Nat
  parameterType : Ty
  actualType : Ty
  deriving DecidableEq, Repr

private def resolvePositional :
    List Parameter → List Argument → Nat → Except CallError (List ResolvedArgument)
  | [], [], _ => .ok []
  | parameter :: parameters, .positional actual :: arguments, index => do
      let rest ← resolvePositional parameters arguments (index + 1)
      pure (ResolvedArgument.mk index parameter.type actual :: rest)
  | _, _, _ => .error .mixedArgumentModes

private def findLabeledParameter
    (label : String) :
    List Parameter → Nat → Option (Nat × Parameter) → Except CallError (Nat × Parameter)
  | [], _, none => .error (.unknownLabel label)
  | [], _, some found => .ok found
  | parameter :: parameters, index, found =>
      if parameter.label = some label then
        match found with
        | none => findLabeledParameter label parameters (index + 1) (some (index, parameter))
        | some _ => .error (.duplicateParameterLabel label)
      else
        findLabeledParameter label parameters (index + 1) found

private def resolveLabeled
    (parameters : List Parameter) :
    List Argument → List String → Except CallError (List ResolvedArgument)
  | [], _ => .ok []
  | .positional _ :: _, _ => .error .mixedArgumentModes
  | .labeled label actual :: arguments, seen =>
      if label ∈ seen then
        .error (.duplicateArgumentLabel label)
      else do
        let (index, parameter) ← findLabeledParameter label parameters 0 none
        let rest ← resolveLabeled parameters arguments (label :: seen)
        pure (ResolvedArgument.mk index parameter.type actual :: rest)

/--
Resolve positional calls by declaration order and fully-labeled calls by the
declared ABI labels. Mixed calls are deliberately outside this slice and are
rejected instead of falling back to codegen order.
-/
def resolveArguments
    (parameters : List Parameter)
    (arguments : List Argument) : Except CallError (List ResolvedArgument) :=
  if parameters.length ≠ arguments.length then
    .error (.arityMismatch parameters.length arguments.length)
  else if arguments.all Argument.isPositional then
    resolvePositional parameters arguments 0
  else if arguments.all Argument.isLabeled then
    resolveLabeled parameters arguments []
  else
    .error .mixedArgumentModes

abbrev PartialSubstitution := List (Option Ty)

private def replaceAt? {α : Type} : List α → Nat → α → Option (List α)
  | [], _, _ => none
  | _ :: rest, 0, value => some (value :: rest)
  | head :: rest, index + 1, value => do
      let replaced ← replaceAt? rest index value
      pure (head :: replaced)

mutual
  private def inferType
      (parameterIndex : Nat)
      (expected actual : Ty)
      (substitution : PartialSubstitution) : Except CallError PartialSubstitution :=
    match expected with
    | .var index =>
        match Ty.listAt? substitution index with
        | none => .error (.invalidTypeVariable index)
        | some none =>
            match replaceAt? substitution index (some actual) with
            | none => .error (.invalidTypeVariable index)
            | some updated => .ok updated
        | some (some inferred) =>
            if inferred = actual then .ok substitution
            else .error (.typeMismatch parameterIndex inferred actual)
    | .prim expectedPrimitive =>
        match actual with
        | .prim actualPrimitive =>
            if expectedPrimitive = actualPrimitive then .ok substitution
            else .error (.typeMismatch parameterIndex expected actual)
        | _ => .error (.typeMismatch parameterIndex expected actual)
    | .nominal expectedName expectedArguments =>
        match actual with
        | .nominal actualName actualArguments =>
            if expectedName = actualName && expectedArguments.length = actualArguments.length then
              inferTypes parameterIndex expectedArguments actualArguments substitution
            else
              .error (.typeMismatch parameterIndex expected actual)
        | _ => .error (.typeMismatch parameterIndex expected actual)
  private def inferTypes
      (parameterIndex : Nat) :
      TyArgs → TyArgs → PartialSubstitution → Except CallError PartialSubstitution
    | .nil, .nil, substitution => .ok substitution
    | .cons expected expecteds, .cons actual actuals, substitution =>
        match inferType parameterIndex expected actual substitution with
        | .error error => .error error
        | .ok updated => inferTypes parameterIndex expecteds actuals updated
    | _, _, _ => .error (.typeMismatch parameterIndex .unit .unit)
end

private def inferResolved :
    List ResolvedArgument → PartialSubstitution → Except CallError PartialSubstitution
  | [], substitution => .ok substitution
  | argument :: arguments, substitution =>
      match inferType argument.parameterIndex argument.parameterType
          argument.actualType substitution with
      | .error error => .error error
      | .ok updated => inferResolved arguments updated

private def finalizeSubstitution :
    PartialSubstitution → Nat → Except CallError (List Ty)
  | [], _ => .ok []
  | none :: _, index => .error (.unresolvedTypeParameter index)
  | some type :: rest, index => do
      let finalized ← finalizeSubstitution rest (index + 1)
      pure (type :: finalized)

def resolvedArgumentsMatch
    (typeArguments : List Ty)
    (arguments : List ResolvedArgument) : Bool :=
  match arguments with
  | [] => true
  | argument :: rest =>
      decide (Ty.instantiate typeArguments argument.parameterType = some argument.actualType) &&
        resolvedArgumentsMatch typeArguments rest

def ResolvedArgumentsWellTyped
    (typeArguments : List Ty)
    (arguments : List ResolvedArgument) : Prop :=
  match arguments with
  | [] => True
  | argument :: rest =>
      Ty.instantiate typeArguments argument.parameterType = some argument.actualType ∧
        ResolvedArgumentsWellTyped typeArguments rest

/--
A successful result carries the resolution, argument, and return-type evidence
that later evaluator/codegen refinements may consume.
-/
structure CheckedCall (signature : Signature) (arguments : List Argument) where
  typeArguments : List Ty
  returnType : Ty
  resolvedArguments : List ResolvedArgument
  resolutionCorrect :
    resolveArguments signature.parameters arguments = .ok resolvedArguments
  argumentsMatch : resolvedArgumentsMatch typeArguments resolvedArguments = true
  returnTypeInstantiated :
    Ty.instantiate typeArguments signature.returnType = some returnType

/-- Executable call checker used as the Lean Oracle for this slice. -/
def checkCall
    (signature : Signature)
    (arguments : List Argument) : Except CallError (CheckedCall signature arguments) :=
  match resolution : resolveArguments signature.parameters arguments with
  | .error error => .error error
  | .ok resolved =>
      match inferResolved resolved (List.replicate signature.typeParameterCount none) with
      | .error error => .error error
      | .ok inferredSubstitution =>
          match finalizeSubstitution inferredSubstitution 0 with
          | .error error => .error error
          | .ok typeArguments =>
              if argumentsMatch : resolvedArgumentsMatch typeArguments resolved = true then
                match returnTypeResult : Ty.instantiate typeArguments signature.returnType with
                | none => .error .invalidReturnType
                | some returnType =>
                    .ok (CheckedCall.mk typeArguments returnType resolved resolution
                      argumentsMatch returnTypeResult)
              else
                .error .internalValidationFailure

inductive CallOutcome where
  | accepted (returnType : Ty) (typeArguments : List Ty)
  | rejected (kind : CallErrorKind)
  deriving DecidableEq, Repr

def checkCallOutcome (signature : Signature) (arguments : List Argument) : CallOutcome :=
  match checkCall signature arguments with
  | .error error => .rejected error.kind
  | .ok checked => .accepted checked.returnType checked.typeArguments

private def brokenArgumentsMatchHead : List Parameter → List Argument → Bool
  | [], [] => true
  | parameter :: parameters, argument :: arguments =>
      Ty.sameHead parameter.type argument.type && brokenArgumentsMatchHead parameters arguments
  | _, _ => false

/-- Broken witness for #981/#983: compare only the outer type constructor. -/
def brokenHeadOnlyAccepts (signature : Signature) (arguments : List Argument) : Bool :=
  signature.parameters.length = arguments.length &&
    brokenArgumentsMatchHead signature.parameters arguments

/-- Broken witness for #985/#986: arity is the only enforced call contract. -/
def brokenUncheckedAccepts (signature : Signature) (arguments : List Argument) : Bool :=
  signature.parameters.length = arguments.length

end VibeFormal.Typing
