import Std

set_option autoImplicit false

/-
#952 / #1238: trait coherence.

`impl Show for Int` may exist at most once in a program. If it existed twice,
`x.to_string()` would have two elaborations, and which one a call site got
would depend on resolution order rather than on the program -- the dictionary
passed at runtime would differ between two builds of the same source. That is
why coherence is a soundness property and not a lint: dictionary elaboration
(desugar_trait_dict) reads the resolved impl to decide WHICH function pointer
to thread through a bounded call.

**In scope.** Uniqueness of the impl selected for a (trait, type) pair, that
uniqueness is exactly what makes elaboration a function, and that adding a
non-overlapping impl preserves both.

**Out of scope.** Where impls may be DECLARED (the orphan rule -- a separate
policy about which crate owns a pair, and one this repo states in terms of
package identity rather than resolution), bound satisfaction for generic
impls (`impl Show for Array[T] where T: Show` -- resolution there is
recursive, and the recursion is the content of a further slice), and
specialization, which the language does not have.
-/

namespace VibeFormal.Typing

/-- Which trait an impl is for, and which type head it covers. Both are
identities, not syntax: two spellings that resolve to the same pair are the
same pair, which is the whole point of the rule. -/
structure ImplKey where
  traitName : String
  typeName : String
  deriving DecidableEq, Repr

/-- An impl declaration, reduced to what coherence is about: the pair it
covers, and an identity standing for the dictionary it elaborates to. -/
structure ImplDecl where
  key : ImplKey
  dictionary : Nat
  deriving DecidableEq, Repr

abbrev ImplTable := List ImplDecl

namespace ImplTable

/-- The impls in `table` covering `key`. Resolution picks from this list; the
rule below is that it never has more than one element. -/
def candidates (table : ImplTable) (key : ImplKey) : List ImplDecl :=
  table.filter (fun decl => decl.key = key)

/--
Coherent: no two DISTINCT impls cover the same pair. Stated over membership
rather than over list positions, so it is insensitive to how the table was
assembled (declaration order, module merge order).
-/
def Coherent (table : ImplTable) : Prop :=
  ∀ left ∈ table, ∀ right ∈ table, left.key = right.key → left = right

/-- A coherent table resolves each pair to at most one dictionary -- the
property elaboration depends on. Two candidates for one key are equal, so
"which impl" is determined by the program and not by search order. -/
theorem unique_candidate {table : ImplTable} (coherent : Coherent table) {key : ImplKey}
    {left right : ImplDecl}
    (leftIn : left ∈ candidates table key) (rightIn : right ∈ candidates table key) :
    left = right := by
  simp [candidates, List.mem_filter] at leftIn rightIn
  exact coherent left leftIn.1 right rightIn.1 (leftIn.2.trans rightIn.2.symm)

/-- In particular the DICTIONARY is determined: the same bounded call site
elaborates to the same function pointer in every build of the program. -/
theorem unique_dictionary {table : ImplTable} (coherent : Coherent table) {key : ImplKey}
    {left right : ImplDecl}
    (leftIn : left ∈ candidates table key) (rightIn : right ∈ candidates table key) :
    left.dictionary = right.dictionary := by
  rw [unique_candidate coherent leftIn rightIn]

/-- The empty program is coherent. -/
theorem coherent_nil : Coherent [] := by
  intro left leftIn
  simp at leftIn

/-- Coherence is inherited by any sub-table: merging modules can only ever
introduce a conflict, never repair one, which is why the check runs on the
merged program. -/
theorem coherent_of_sublist {small large : ImplTable} (subset : ∀ d ∈ small, d ∈ large)
    (coherent : Coherent large) : Coherent small :=
  fun left leftIn right rightIn same =>
    coherent left (subset left leftIn) right (subset right rightIn) same

/-- Adding an impl whose pair nothing else covers keeps the table coherent --
the incremental step a checker takes as it walks declarations. -/
theorem coherent_cons {table : ImplTable} {decl : ImplDecl} (coherent : Coherent table)
    (fresh : ∀ other ∈ table, other.key ≠ decl.key) : Coherent (decl :: table) := by
  intro left leftIn right rightIn same
  simp only [List.mem_cons] at leftIn rightIn
  rcases leftIn with leftEq | leftIn
  · rcases rightIn with rightEq | rightIn
    · rw [leftEq, rightEq]
    · exact absurd (leftEq ▸ same.symm) (fresh right rightIn)
  · rcases rightIn with rightEq | rightIn
    · exact absurd (rightEq ▸ same) (fresh left leftIn)
    · exact coherent left leftIn right rightIn same

/--
**The negative witness.** Two impls covering the same pair but elaborating to
different dictionaries make the table incoherent -- this is the shape the
checker rejects, and the reason it must: the two dictionaries are what a call
site would have to choose between.
-/
theorem not_coherent_overlapping (key : ImplKey) {d₁ d₂ : Nat} (distinct : d₁ ≠ d₂) :
    ¬ Coherent [⟨key, d₁⟩, ⟨key, d₂⟩] := by
  intro coherent
  have same : (⟨key, d₁⟩ : ImplDecl) = ⟨key, d₂⟩ := by
    refine coherent ⟨key, d₁⟩ ?_ ⟨key, d₂⟩ ?_ rfl
    · exact List.mem_cons_self
    · exact List.mem_cons_of_mem _ List.mem_cons_self
  have : d₁ = d₂ := congrArg ImplDecl.dictionary same
  exact distinct this

/--
Positive counterpart: two impls of the same trait for DIFFERENT types coexist
happily. Confirms the rule rejects overlap rather than rejecting a trait
having several impls.
-/
theorem coherent_distinct_types {traitName leftType rightType : String}
    (distinct : leftType ≠ rightType) {d₁ d₂ : Nat} :
    Coherent [⟨⟨traitName, leftType⟩, d₁⟩, ⟨⟨traitName, rightType⟩, d₂⟩] := by
  refine coherent_cons (coherent_cons coherent_nil ?_) ?_
  · intro other otherIn
    simp at otherIn
  · intro other otherIn same
    simp only [List.mem_cons, List.not_mem_nil, or_false] at otherIn
    rw [otherIn] at same
    exact distinct (congrArg ImplKey.typeName same).symm

end ImplTable

end VibeFormal.Typing
