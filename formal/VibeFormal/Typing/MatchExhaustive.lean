import Std

set_option autoImplicit false

/-
#940 / #1238: match exhaustiveness.

A `match` is exhaustive when every value its scrutinee can take is matched by
some arm. The live checker reports the missing shapes; this slice states what
"missing" means and proves the two facts the report relies on -- that a
wildcard alone is exhaustive, and that a set of constructor arms is exhaustive
exactly when it leaves no constructor of the scrutinee's type uncovered.

**In scope.** Coverage of one scrutinee position over a closed constructor
signature, including a nested position (a constructor's argument matched by an
inner pattern), and the witness a non-exhaustive match admits: an actual value
no arm matches. That witness is the point -- "not exhaustive" without one is
just a failed search, and the checker's diagnostic names a concrete shape.

**Out of scope.** Usefulness of a single arm (is this arm reachable?), which
Maranget's algorithm computes with the same machinery but answers a different
question; guards, which make an arm's coverage undecidable from the pattern
alone; and or-patterns' binder agreement (#951 -- a separate slice; the rules
do not interact, a well-formed or-pattern can be non-exhaustive and vice
versa).
-/

namespace VibeFormal.Typing

/-- Values of the modeled types: a constructor applied to arguments. -/
inductive Value where
  | con (name : String) (args : List Value)
  deriving Repr

/-- Patterns: a wildcard, or a constructor applied to sub-patterns. -/
inductive Pattern where
  | wild
  | con (name : String) (args : List Pattern)
  deriving Repr

mutual
  /-- Does `pattern` match `value`? -/
  def Pattern.Matches : Pattern → Value → Prop
    | .wild, _ => True
    | .con pname pargs, .con vname vargs =>
        pname = vname ∧ Pattern.MatchesAll pargs vargs

  /-- Pointwise, and only when the lengths agree. -/
  def Pattern.MatchesAll : List Pattern → List Value → Prop
    | [], [] => True
    | p :: ps, v :: vs => Pattern.Matches p v ∧ Pattern.MatchesAll ps vs
    | _, _ => False
end

/-- A match's arms, in order. Order is irrelevant to exhaustiveness (it decides
WHICH arm runs, not whether one does), so it is not modeled beyond the list. -/
abbrev Arms := List Pattern

/-- Some arm matches `value`. -/
def Arms.Covers (arms : Arms) (value : Value) : Prop :=
  ∃ pattern ∈ arms, Pattern.Matches pattern value

/--
Exhaustive over `values`: every value the scrutinee can take is covered. The
value set is a parameter rather than derived from a signature so a nested
position can reuse the definition with its own argument type.
-/
def Arms.Exhaustive (arms : Arms) (values : Value → Prop) : Prop :=
  ∀ value, values value → arms.Covers value

namespace Arms

/-- A wildcard arm matches everything, so a match containing one is exhaustive
whatever the scrutinee's type -- the base case every diagnostic stops at. -/
theorem exhaustive_of_wild (rest : Arms) (values : Value → Prop) :
    Arms.Exhaustive (Pattern.wild :: rest) values := by
  intro value _
  exact ⟨Pattern.wild, List.mem_cons_self, trivial⟩

/-- Adding an arm never loses coverage: exhaustiveness is monotone, which is
what lets the checker stop as soon as it has covered everything. -/
theorem exhaustive_cons {arms : Arms} {values : Value → Prop} (pattern : Pattern)
    (exhaustive : Arms.Exhaustive arms values) :
    Arms.Exhaustive (pattern :: arms) values := by
  intro value inSet
  obtain ⟨p, member, hit⟩ := exhaustive value inSet
  exact ⟨p, List.mem_cons_of_mem _ member, hit⟩

/--
**The witness that makes "not exhaustive" mean something.** If some value the
scrutinee can take is matched by no arm, the match is not exhaustive -- and
that value is exactly the shape the checker's diagnostic names.
-/
theorem not_exhaustive_of_witness {arms : Arms} {values : Value → Prop} {value : Value}
    (inSet : values value) (uncovered : ¬ arms.Covers value) :
    ¬ Arms.Exhaustive arms values := by
  intro exhaustive
  exact uncovered (exhaustive value inSet)

/-- No arms at all covers nothing, so a match over an inhabited type with no
arms is never exhaustive. -/
theorem not_exhaustive_nil {values : Value → Prop} {value : Value} (inSet : values value) :
    ¬ Arms.Exhaustive ([] : Arms) values := by
  refine not_exhaustive_of_witness inSet ?_
  intro covered
  obtain ⟨_, member, _hit⟩ := covered
  simp at member

end Arms

/-- The values of a two-constructor type, the smallest setting in which a
missing constructor is observable. -/
def twoConValues (leftName rightName : String) (value : Value) : Prop :=
  value = Value.con leftName [] ∨ value = Value.con rightName []

/--
**Negative witness: a missing constructor.** Matching only `left` over a type
that also has `right` is not exhaustive, and `right` itself is the shape the
diagnostic reports.
-/
theorem not_exhaustive_missing_constructor {leftName rightName : String}
    (distinct : leftName ≠ rightName) :
    ¬ Arms.Exhaustive [Pattern.con leftName []] (twoConValues leftName rightName) := by
  refine Arms.not_exhaustive_of_witness (Or.inr rfl) ?_
  intro covered
  obtain ⟨p, member, hit⟩ := covered
  simp at member
  subst member
  have name : leftName = rightName := hit.1
  exact distinct name

/--
Positive counterpart: covering both constructors IS exhaustive, so the rule
rejects gaps rather than rejecting constructor arms.
-/
theorem exhaustive_both_constructors (leftName rightName : String) :
    Arms.Exhaustive [Pattern.con leftName [], Pattern.con rightName []]
      (twoConValues leftName rightName) := by
  intro value inSet
  rcases inSet with h | h
  · exact ⟨Pattern.con leftName [], List.mem_cons_self, by subst h; exact ⟨rfl, trivial⟩⟩
  · refine ⟨Pattern.con rightName [], ?_, ?_⟩
    · exact List.mem_cons_of_mem _ List.mem_cons_self
    · subst h
      exact ⟨rfl, trivial⟩

/--
**Negative witness: a gap in a NESTED position.** `Wrap(left)` covers the outer
constructor completely, so a checker that only compared outer constructors
would call this exhaustive -- but `Wrap(right)` is unmatched. This is the case
that makes exhaustiveness recursive rather than a one-level set comparison.
-/
theorem not_exhaustive_nested_gap {leftName rightName : String}
    (distinct : leftName ≠ rightName) :
    ¬ Arms.Exhaustive [Pattern.con "Wrap" [Pattern.con leftName []]]
      (fun value => value = Value.con "Wrap" [Value.con rightName []]) := by
  refine Arms.not_exhaustive_of_witness rfl ?_
  intro covered
  obtain ⟨p, member, hit⟩ := covered
  simp at member
  subst member
  have inner : Pattern.Matches (Pattern.con leftName []) (Value.con rightName []) :=
    hit.2.1
  exact distinct inner.1

end VibeFormal.Typing
