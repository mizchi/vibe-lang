import VibeFormal.Effect.Id

set_option autoImplicit false

/-
#942 / #1238: the `resume` discipline of ADR-0050 -- `resume` is legal only
inside the handler arm that received it, and at most once per invocation of
that arm.

The live checker enforces both halves (a `resume` outside any handler arm is
rejected outright; a second `resume` on the same continuation is the one-shot
rule ADR-0076's evidence lowering depends on -- a tail-resumptive arm compiles
to a direct call precisely because the continuation cannot be run twice). This
file states them as properties of a minimal model rather than re-deriving the
checker.

**Scope.** The model is about WHICH resume tokens a program point may use and
HOW OFTEN, not about what resuming computes. Values, effect payloads, and the
handler's own result are all absent: they do not participate in either rule,
and including them would only add cases every theorem below has to skip.
Multi-shot handlers are out of scope by construction here -- ADR-0068 keeps
yield bubbling able to support them, so a future slice modeling that lane
would relax `Trace.Valid`'s one-shot clause rather than contradict it.

**Out of scope.** Nesting discipline across two handlers for DIFFERENT effects
(each arm still only sees its own token, which is what `inArm` models, but the
interleaving of two live handlers is a separate property), and the dynamic
extent of a continuation captured as a value (`Typing`-level; ADR-0076 追記31's
suspend class).
-/

namespace VibeFormal.Effect

/-- The identity of one activation of a handler arm: which operation it
handles, and which activation of it this is. Two activations of the SAME arm
are different tokens -- re-entering an arm hands out a fresh continuation. -/
structure ResumeToken where
  operation : OperationRef
  activation : Nat
  deriving DecidableEq, Repr

/-- One step of a program's observable resume behaviour. -/
inductive Event where
  /-- Control entered the arm activation `token` (an operation was performed
  and this handler caught it). -/
  | enterArm (token : ResumeToken)
  /-- Control left that arm activation without resuming again. -/
  | leaveArm (token : ResumeToken)
  /-- `resume` was invoked on `token`. -/
  | resume (token : ResumeToken)
  deriving DecidableEq, Repr

abbrev Trace := List Event

namespace Trace

/-- The arm activations currently entered, innermost first. -/
def live : Trace → List ResumeToken
  | [] => []
  | .enterArm token :: rest => token :: live rest
  | .leaveArm token :: rest => (live rest).filter (fun t => t != token)
  | .resume _ :: rest => live rest

/-- How many times `token` has been resumed. -/
def resumeCount (token : ResumeToken) : Trace → Nat
  | [] => 0
  | .resume other :: rest => (if other = token then 1 else 0) + resumeCount token rest
  | _ :: rest => resumeCount token rest

end Trace

/-- What the single event `event` requires of the trace `rest` that precedes
it. Only `resume` constrains anything; entering and leaving an arm are always
legal. Factoring the per-event rule out of the recursion keeps `Valid`'s shape
uniform, so every theorem below reads the head with `.1` and the tail with
`.2`. -/
def Trace.stepOk : Event → Trace → Prop
  | .resume token, rest => token ∈ Trace.live rest ∧ Trace.resumeCount token rest = 0
  | _, _ => True

/--
The two rules, as a predicate on a trace whose head is the LATEST event
(matching `live`/`resumeCount`'s recursion):

- **scope** -- a `resume` on `token` requires `token` to be a live arm
  activation. This is the "no `resume` outside a handler" half: outside any
  arm nothing is live, so no resume is legal.
- **one-shot** -- at the moment of a `resume`, that token must not have been
  resumed already.
-/
def Trace.Valid : Trace → Prop
  | [] => True
  | event :: rest => Trace.stepOk event rest ∧ Trace.Valid rest

namespace Trace

/-- Nothing is live in the empty trace: at top level, before any operation has
been caught, there is no continuation to resume. -/
theorem live_nil : Trace.live [] = [] := rfl

/--
**#942's first half.** A `resume` at top level -- no arm entered before it --
is invalid. This is the formal counterpart of the checker rejecting `resume`
written outside any handler arm.
-/
theorem not_valid_resume_at_top (token : ResumeToken) :
    ¬ Trace.Valid [Event.resume token] := by
  intro valid
  have membership : token ∈ Trace.live [] := valid.1.1
  simp [live_nil] at membership

/--
**#942's second half.** Resuming the same token twice inside one arm
activation is invalid: the second `resume` sees a non-zero count.

Stated on the smallest witness (enter, resume, resume) so the statement is
about the rule and not about a particular surrounding program.
-/
theorem not_valid_double_resume (token : ResumeToken) :
    ¬ Trace.Valid [Event.resume token, Event.resume token, Event.enterArm token] := by
  intro valid
  have step : token ∈ (Trace.live [Event.resume token, Event.enterArm token])
      ∧ (Trace.resumeCount token [Event.resume token, Event.enterArm token]) = 0 := valid.1
  simp [resumeCount] at step

/--
Positive counterpart: resuming ONCE inside the arm that produced the token is
valid. Confirms the rules reject double and out-of-scope resumes rather than
rejecting `resume` outright.
-/
theorem valid_single_resume (token : ResumeToken) :
    Trace.Valid [Event.resume token, Event.enterArm token] := by
  refine ⟨⟨?_, ?_⟩, ?_, ?_⟩
  · simp [live]
  · simp [resumeCount]
  · trivial
  · trivial

/--
A token from a DIFFERENT arm activation is not resumable from this one. The
`activation` field is what makes this bite: re-entering the same arm yields a
fresh token, so a continuation captured in an earlier activation cannot be run
from a later one.
-/
theorem not_valid_foreign_resume {inner outer : ResumeToken} (distinct : inner ≠ outer) :
    ¬ Trace.Valid [Event.resume outer, Event.enterArm inner] := by
  intro valid
  have step : outer ∈ (Trace.live [Event.enterArm inner])
      ∧ (Trace.resumeCount outer [Event.enterArm inner]) = 0 := valid.1
  have membership := step.1
  simp [live] at membership
  exact distinct membership.symm

/--
Leaving an arm retires its token: a `resume` after the arm has returned is
invalid even though the arm was entered earlier. This is what makes the scope
rule a genuine extent rather than a "was it ever entered" check.
-/
theorem not_valid_resume_after_leave (token : ResumeToken) :
    ¬ Trace.Valid [Event.resume token, Event.leaveArm token, Event.enterArm token] := by
  intro valid
  have step : token ∈ (Trace.live [Event.leaveArm token, Event.enterArm token])
      ∧ (Trace.resumeCount token [Event.leaveArm token, Event.enterArm token]) = 0 := valid.1
  have membership := step.1
  simp [live] at membership

/-- Validity is prefix-closed: the earlier part of a valid trace is itself
valid. Lets a later slice reason about a program's behaviour up to a point
without re-checking the whole run. -/
theorem valid_tail {event : Event} {rest : Trace} (valid : Trace.Valid (event :: rest)) :
    Trace.Valid rest :=
  valid.2

end Trace

end VibeFormal.Effect
