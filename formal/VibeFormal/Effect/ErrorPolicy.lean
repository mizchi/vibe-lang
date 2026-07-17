import VibeFormal.Effect.Id

set_option autoImplicit false

namespace VibeFormal.ErrorPolicy

/--
The adopted checked policy and the rejected ambient comparison used to expose
the #944 design difference.
-/
inductive Policy where
  | checked
  | ambient
  deriving Repr, DecidableEq

/--
The static row distinguishes the Error control operation from capability-bearing
operations. The latter retain their resolved operation identity.
-/
inductive StaticEffect where
  | error
  | capability (operation : OperationRef)
  deriving Repr, DecidableEq

/--
A minimal closed term language for the #944 decision. `call` makes transitive
propagation observable without introducing the full Vibe type system.
-/
inductive Term where
  | returned
  | throwError
  | perform (operation : OperationRef)
  | call (callee : Term)
  | seq (first second : Term)
  | handleError (body : Term)
  deriving Repr

def normalizeRequirements (requirements : List StaticEffect) : List StaticEffect :=
  requirements.eraseDups

/-- Static requirements under the selected `Error` policy. -/
def requirements : Policy → Term → List StaticEffect
  | _, .returned => []
  | .checked, .throwError => [.error]
  | .ambient, .throwError => []
  | _, .perform operation => [.capability operation]
  | policy, .call callee => requirements policy callee
  | policy, .seq first second =>
      normalizeRequirements
        (requirements policy first ++ requirements policy second)
  | policy, .handleError body =>
      (requirements policy body).filter fun requirement => requirement ≠ .error

/-- A declaration admits every statically tracked requirement of the term. -/
def Allowed
    (policy : Policy)
    (declared : List StaticEffect)
    (term : Term) : Prop :=
  ∀ requirement,
    requirement ∈ requirements policy term → requirement ∈ declared

/-- The observations needed to distinguish normal, exceptional, and capability exits. -/
inductive Outcome where
  | returned
  | raised
  | performed (operation : OperationRef)
  deriving Repr, DecidableEq

/-- Deterministic big-step observation for the minimal term language. -/
def run : Term → Outcome
  | .returned => .returned
  | .throwError => .raised
  | .perform operation => .performed operation
  | .call callee => run callee
  | .seq first second =>
      match run first with
      | .returned => run second
      | outcome => outcome
  | .handleError body =>
      match run body with
      | .raised => .returned
      | outcome => outcome

/--
The public entry boundary selected for checked Error. An escaping Error becomes
a diagnosable process failure instead of crossing the runtime boundary.
-/
inductive EntryOutcome where
  | succeeded
  | failedWithError
  | performed (operation : OperationRef)
  deriving Repr, DecidableEq

def runEntry (term : Term) : EntryOutcome :=
  match run term with
  | .returned => .succeeded
  | .raised => .failedWithError
  | .performed operation => .performed operation

/-- Deliberately broken checker: dropping capabilities as well as `Error`. -/
def brokenRequirements (_ : Term) : List StaticEffect :=
  []

def BrokenAllowed (declared : List StaticEffect) (term : Term) : Prop :=
  ∀ requirement,
    requirement ∈ brokenRequirements term → requirement ∈ declared

end VibeFormal.ErrorPolicy
