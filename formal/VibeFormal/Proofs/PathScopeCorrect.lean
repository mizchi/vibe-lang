import VibeFormal.Capability.PathScope
import VibeFormal.Proofs.CapabilityContractCorrect

set_option autoImplicit false

namespace VibeFormal.Capability.PathScope

theorem SegmentPattern.matchesB_correct
    (pattern : SegmentPattern)
    (segment : String) :
    pattern.matchesB segment = true ↔ pattern.Matches segment := by
  cases pattern <;> simp [SegmentPattern.matchesB, SegmentPattern.Matches]

theorem SegmentPattern.compatible_correct
    (left right : SegmentPattern) :
    left.compatible right = true ↔ left.Compatible right := by
  cases left <;> cases right <;>
    simp [SegmentPattern.compatible, SegmentPattern.Compatible]

theorem SegmentPattern.common_match_implies_compatible
    {left right : SegmentPattern}
    {segment : String}
    (leftMatches : left.Matches segment)
    (rightMatches : right.Matches segment) :
    left.Compatible right := by
  cases left <;> cases right <;>
    simp_all [SegmentPattern.Matches, SegmentPattern.Compatible]

private def SegmentPattern.sample : SegmentPattern → String
  | .literal value => value
  | .any => "_"

private theorem SegmentPattern.sample_matches
    (pattern : SegmentPattern) :
    pattern.Matches pattern.sample := by
  cases pattern <;> simp [SegmentPattern.sample, SegmentPattern.Matches]

private theorem SegmentPattern.compatible_has_common_match
    {left right : SegmentPattern}
    (compatible : left.Compatible right) :
    ∃ segment, left.Matches segment ∧ right.Matches segment := by
  cases left with
  | literal left =>
      cases right with
      | literal right =>
          simp only [SegmentPattern.Compatible] at compatible
          subst right
          exact ⟨left, by simp [SegmentPattern.Matches]⟩
      | any =>
          exact ⟨left, by simp [SegmentPattern.Matches]⟩
  | any =>
      cases right with
      | literal right =>
          exact ⟨right, by simp [SegmentPattern.Matches]⟩
      | any =>
          exact ⟨"_", by simp [SegmentPattern.Matches]⟩

theorem PathGlob.prefixMatches_correct
    (patterns : List SegmentPattern)
    (path : NormalizedPath) :
    prefixMatches patterns path = true ↔ PrefixMatches patterns path := by
  induction patterns generalizing path with
  | nil =>
      simp [prefixMatches, PrefixMatches]
  | cons pattern patterns induction =>
      cases path with
      | nil =>
          simp [prefixMatches, PrefixMatches]
      | cons segment path =>
          simp [prefixMatches, PrefixMatches,
            SegmentPattern.matchesB_correct, induction]

theorem PathGlob.lengthAllowed_correct
    (pattern : PathGlob)
    (pathLength : Nat) :
    pattern.lengthAllowed pathLength = true ↔
      pattern.LengthAllowed pathLength := by
  cases pattern.recursive <;>
    simp [PathGlob.lengthAllowed, PathGlob.LengthAllowed]

theorem PathGlob.matchesB_correct
    (pattern : PathGlob)
    (path : NormalizedPath) :
    pattern.matchesB path = true ↔ pattern.Matches path := by
  simp [PathGlob.matchesB, PathGlob.Matches, Bool.and_eq_true,
    PathGlob.prefixMatches_correct, PathGlob.lengthAllowed_correct]

theorem PathGlob.prefixCompatible_correct
    (left right : List SegmentPattern) :
    prefixCompatible left right = true ↔ PrefixCompatible left right := by
  induction left generalizing right with
  | nil =>
      simp [prefixCompatible, PrefixCompatible]
  | cons pattern patterns induction =>
      cases right with
      | nil =>
          simp [prefixCompatible, PrefixCompatible]
      | cons other others =>
          simp [prefixCompatible, PrefixCompatible,
            SegmentPattern.compatible_correct, induction]

theorem PathGlob.lengthCompatible_correct
    (left right : PathGlob) :
    lengthCompatible left right = true ↔ LengthCompatible left right := by
  cases leftRecursive : left.recursive <;>
    cases rightRecursive : right.recursive <;>
    simp [PathGlob.lengthCompatible, PathGlob.LengthCompatible,
      leftRecursive, rightRecursive]

theorem PathGlob.overlaps_correct
    (left right : PathGlob) :
    left.overlaps right = true ↔ left.MayOverlap right := by
  simp [PathGlob.overlaps, PathGlob.MayOverlap, Bool.and_eq_true,
    PathGlob.prefixCompatible_correct, PathGlob.lengthCompatible_correct]

theorem PathGlob.overlaps_eq_false
    (left right : PathGlob) :
    left.overlaps right = false ↔ ¬left.MayOverlap right := by
  constructor
  · intro rejected overlap
    have accepted := (PathGlob.overlaps_correct left right).2 overlap
    rw [rejected] at accepted
    contradiction
  · intro disjoint
    cases accepted : left.overlaps right with
    | false => rfl
    | true =>
        exact False.elim
          (disjoint ((PathGlob.overlaps_correct left right).1 accepted))

private theorem prefix_common_match_implies_compatible
    {left right : List SegmentPattern}
    {path : NormalizedPath}
    (leftMatches : PathGlob.PrefixMatches left path)
    (rightMatches : PathGlob.PrefixMatches right path) :
    PathGlob.PrefixCompatible left right := by
  induction left generalizing right path with
  | nil =>
      simp [PathGlob.PrefixCompatible]
  | cons pattern patterns induction =>
      cases right with
      | nil =>
          simp [PathGlob.PrefixCompatible]
      | cons other others =>
          cases path with
          | nil =>
              simp [PathGlob.PrefixMatches] at leftMatches
          | cons segment path =>
              simp only [PathGlob.PrefixMatches] at leftMatches rightMatches
              exact ⟨
                SegmentPattern.common_match_implies_compatible
                  leftMatches.1 rightMatches.1,
                induction leftMatches.2 rightMatches.2
              ⟩

private theorem common_length_implies_compatible
    {left right : PathGlob}
    {pathLength : Nat}
    (leftAllowed : left.LengthAllowed pathLength)
    (rightAllowed : right.LengthAllowed pathLength) :
    left.LengthCompatible right := by
  cases leftRecursive : left.recursive <;>
    cases rightRecursive : right.recursive <;>
    simp_all [PathGlob.LengthAllowed, PathGlob.LengthCompatible]

/--
The overlap checker cannot miss an ambiguous path.
-/
theorem PathGlob.common_match_implies_mayOverlap
    {left right : PathGlob}
    {path : NormalizedPath}
    (leftMatches : left.Matches path)
    (rightMatches : right.Matches path) :
    left.MayOverlap right := by
  exact ⟨
    prefix_common_match_implies_compatible
      leftMatches.1 rightMatches.1,
    common_length_implies_compatible
      leftMatches.2 rightMatches.2
  ⟩

private theorem sampled_prefix_matches
    (patterns : List SegmentPattern) :
    PathGlob.PrefixMatches
      patterns
      (patterns.map SegmentPattern.sample) := by
  induction patterns with
  | nil =>
      simp [PathGlob.PrefixMatches]
  | cons pattern patterns induction =>
      simp [PathGlob.PrefixMatches,
        SegmentPattern.sample_matches, induction]

private theorem compatible_prefix_has_common_match
    {left right : List SegmentPattern}
    (compatible : PathGlob.PrefixCompatible left right) :
    ∃ path,
      PathGlob.PrefixMatches left path ∧
        PathGlob.PrefixMatches right path ∧
        path.length = Nat.max left.length right.length := by
  induction left generalizing right with
  | nil =>
      refine ⟨right.map SegmentPattern.sample, ?_, ?_, ?_⟩
      · simp [PathGlob.PrefixMatches]
      · exact sampled_prefix_matches right
      · simp
  | cons pattern patterns induction =>
      cases right with
      | nil =>
          refine ⟨
            (pattern :: patterns).map SegmentPattern.sample,
            sampled_prefix_matches (pattern :: patterns),
            ?_,
            ?_
          ⟩
          · simp [PathGlob.PrefixMatches]
          · simp
      | cons other others =>
          simp only [PathGlob.PrefixCompatible] at compatible
          obtain ⟨segment, patternMatches, otherMatches⟩ :=
            SegmentPattern.compatible_has_common_match compatible.1
          obtain ⟨path, patternsMatch, othersMatch, pathLength⟩ :=
            induction compatible.2
          refine ⟨segment :: path, ?_, ?_, ?_⟩
          · exact ⟨patternMatches, patternsMatch⟩
          · exact ⟨otherMatches, othersMatch⟩
          · simp only [List.length_cons]
            rw [pathLength]
            exact (Nat.succ_max_succ
              patterns.length others.length).symm

private theorem compatible_lengths_allow_max
    {left right : PathGlob}
    (compatible : left.LengthCompatible right) :
    left.LengthAllowed
        (Nat.max left.segments.length right.segments.length) ∧
      right.LengthAllowed
        (Nat.max left.segments.length right.segments.length) := by
  cases leftRecursive : left.recursive <;>
    cases rightRecursive : right.recursive <;>
    simp_all [PathGlob.LengthCompatible, PathGlob.LengthAllowed,
      Nat.le_max_left, Nat.le_max_right]

/--
For the restricted glob grammar, structural overlap is not an over-approximation:
it always has a concrete normalized path witness.
-/
theorem PathGlob.mayOverlap_has_common_match
    {left right : PathGlob}
    (overlap : left.MayOverlap right) :
    ∃ path, left.Matches path ∧ right.Matches path := by
  obtain ⟨path, leftPrefix, rightPrefix, pathLength⟩ :=
    compatible_prefix_has_common_match overlap.1
  have lengths := compatible_lengths_allow_max overlap.2
  refine ⟨path, ⟨leftPrefix, ?_⟩, ⟨rightPrefix, ?_⟩⟩
  · rw [pathLength]
    exact lengths.1
  · rw [pathLength]
    exact lengths.2

theorem PathGlob.mayOverlap_iff_common_match
    (left right : PathGlob) :
    left.MayOverlap right ↔
      ∃ path, left.Matches path ∧ right.Matches path := by
  exact ⟨
    PathGlob.mayOverlap_has_common_match,
    fun ⟨_path, leftMatches, rightMatches⟩ =>
      PathGlob.common_match_implies_mayOverlap leftMatches rightMatches
  ⟩

/-- The executable checker decides semantic glob-language intersection. -/
theorem PathGlob.overlaps_iff_common_match
    (left right : PathGlob) :
    left.overlaps right = true ↔
      ∃ path, left.Matches path ∧ right.Matches path := by
  exact (PathGlob.overlaps_correct left right).trans
    (PathGlob.mayOverlap_iff_common_match left right)

theorem Grant.permissionsEquivalentB_correct
    {Domain : Type}
    (left right : Grant Domain) :
    left.permissionsEquivalentB right = true ↔
      left.PermissionsEquivalent right := by
  simp only [Grant.permissionsEquivalentB, Bool.and_eq_true,
    EffectRow.subset_correct, Grant.PermissionsEquivalent]
  constructor
  · rintro ⟨leftRight, rightLeft⟩ operation
    exact ⟨leftRight operation, rightLeft operation⟩
  · intro equivalent
    constructor
    · intro operation present
      exact (equivalent operation).1 present
    · intro operation present
      exact (equivalent operation).2 present

theorem Grant.compatible_correct
    {Domain : Type}
    [DecidableEq Domain]
    (left right : Grant Domain) :
    left.compatible right = true ↔ left.Compatible right := by
  simp [Grant.compatible, Grant.Compatible,
    Grant.permissionsEquivalentB_correct, PathGlob.overlaps_eq_false]

theorem Policy.valid_correct
    {Domain : Type}
    [DecidableEq Domain]
    (policy : Policy Domain) :
    policy.valid = true ↔ policy.Valid := by
  simp [Policy.valid, Policy.Valid, List.all_eq_true,
    Grant.compatible_correct]

/--
In a valid policy, any two grants for one domain that match one path carry the
same authority. Rule order therefore cannot choose a stronger permission.
-/
theorem Policy.matching_permissions_unique
    {Domain : Type}
    [DecidableEq Domain]
    {policy : Policy Domain}
    (valid : policy.Valid)
    {left right : Grant Domain}
    (leftPresent : left ∈ policy)
    (rightPresent : right ∈ policy)
    {path : NormalizedPath}
    (sameDomain : left.domain = right.domain)
    (leftMatches : left.pattern.Matches path)
    (rightMatches : right.pattern.Matches path) :
    EffectRow.Equivalent left.permissions right.permissions := by
  rcases valid left leftPresent right rightPresent with
    differentDomain | samePermissions | disjoint
  · exact False.elim (differentDomain sameDomain)
  · exact samePermissions
  · exact False.elim
      (disjoint
        (PathGlob.common_match_implies_mayOverlap
          leftMatches rightMatches))

theorem scopedRunnable_correct
    {Domain : Type}
    [DecidableEq Domain]
    (contract : ScopedEntryContract Domain)
    (host : HostProfile) :
    contract.runnable host = true ↔ ScopedRunnable contract host := by
  simp [ScopedEntryContract.runnable, ScopedRunnable, Bool.and_eq_true,
    Capability.runnable_correct, Policy.valid_correct]

end VibeFormal.Capability.PathScope
