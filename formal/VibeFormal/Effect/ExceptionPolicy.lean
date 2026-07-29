import VibeFormal.Effect.Id

set_option autoImplicit false

namespace VibeFormal.ExceptionPolicy

/--
Nominal identity of a typed exception family. The production compiler will use
the normalized type argument of `Exception[E]`; `Nat` keeps this model minimal.
-/
abbrev ExceptionKind := Nat

/--
Typed exceptions and capability operations occupy distinct row elements.
Different `ExceptionKind` values must never authorize or discharge each other.
-/
inductive StaticEffect where
  | exception (kind : ExceptionKind)
  | capability (operation : OperationRef)
  deriving Repr, DecidableEq

/--
Minimal terms needed to distinguish return, typed raise, capability perform,
transitive propagation, sequencing, and exact-kind exception handling.
-/
inductive Term where
  | returned
  | throwException (kind : ExceptionKind)
  | perform (operation : OperationRef)
  | call (callee : Term)
  | seq (first second : Term)
  | handleException (kind : ExceptionKind) (body : Term)
  deriving Repr

def normalizeRequirements (requirements : List StaticEffect) : List StaticEffect :=
  requirements.eraseDups

/-- Static requirements for checked typed exceptions. -/
def requirements : Term → List StaticEffect
  | .returned => []
  | .throwException kind => [.exception kind]
  | .perform operation => [.capability operation]
  | .call callee => requirements callee
  | .seq first second =>
      normalizeRequirements (requirements first ++ requirements second)
  | .handleException kind body =>
      (requirements body).filter fun requirement => requirement ≠ .exception kind

/-- A declaration admits every statically tracked requirement of the term. -/
def Allowed (declared : List StaticEffect) (term : Term) : Prop :=
  ∀ requirement,
    requirement ∈ requirements term → requirement ∈ declared

/-- Observations distinguish each exception kind from capability exits. -/
inductive Outcome where
  | returned
  | raised (kind : ExceptionKind)
  | performed (operation : OperationRef)
  deriving Repr, DecidableEq

/-- Deterministic big-step observation for the minimal term language. -/
def run : Term → Outcome
  | .returned => .returned
  | .throwException kind => .raised kind
  | .perform operation => .performed operation
  | .call callee => run callee
  | .seq first second =>
      match run first with
      | .returned => run second
      | outcome => outcome
  | .handleException handledKind body =>
      match run body with
      | .raised raisedKind =>
          if raisedKind = handledKind then .returned else .raised raisedKind
      | outcome => outcome

/--
Deliberately broken requirements: a handler for one exception kind erases every
typed-exception requirement. The proof layer preserves a cross-kind witness.
-/
def brokenRequirements : Term → List StaticEffect
  | .returned => []
  | .throwException kind => [.exception kind]
  | .perform operation => [.capability operation]
  | .call callee => brokenRequirements callee
  | .seq first second =>
      normalizeRequirements
        (brokenRequirements first ++ brokenRequirements second)
  | .handleException _ body =>
      (brokenRequirements body).filter fun requirement =>
        match requirement with
        | .exception _ => False
        | .capability _ => True

def BrokenAllowed (declared : List StaticEffect) (term : Term) : Prop :=
  ∀ requirement,
    requirement ∈ brokenRequirements term → requirement ∈ declared

end VibeFormal.ExceptionPolicy
