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

private theorem SegmentPattern.sample_matches
    (pattern : SegmentPattern) :
    pattern.Matches pattern.sample := by
  cases pattern <;> simp [SegmentPattern.sample, SegmentPattern.Matches]

private theorem SegmentPattern.merge_matches
    {left right : SegmentPattern}
    (compatible : left.Compatible right) :
    left.Matches (left.merge right) ∧
      right.Matches (left.merge right) := by
  cases left <;> cases right <;>
    simp_all [SegmentPattern.Compatible, SegmentPattern.merge,
      SegmentPattern.Matches]

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

private theorem merged_prefix_matches
    {left right : List SegmentPattern}
    (compatible : PathGlob.PrefixCompatible left right) :
    PathGlob.PrefixMatches left (PathGlob.mergePrefixes left right) ∧
      PathGlob.PrefixMatches right (PathGlob.mergePrefixes left right) ∧
      (PathGlob.mergePrefixes left right).length =
        Nat.max left.length right.length := by
  induction left generalizing right with
  | nil =>
      exact ⟨
        by simp [PathGlob.PrefixMatches],
        sampled_prefix_matches right,
        by simp [PathGlob.mergePrefixes]
      ⟩
  | cons pattern patterns induction =>
      cases right with
      | nil =>
          exact ⟨
            sampled_prefix_matches (pattern :: patterns),
            by simp [PathGlob.PrefixMatches],
            by simp [PathGlob.mergePrefixes]
          ⟩
      | cons other others =>
          simp only [PathGlob.PrefixCompatible] at compatible
          have mergedSegment :=
            SegmentPattern.merge_matches compatible.1
          have mergedTail := induction compatible.2
          refine ⟨?_, ?_, ?_⟩
          · exact ⟨mergedSegment.1, mergedTail.1⟩
          · exact ⟨mergedSegment.2, mergedTail.2.1⟩
          · simp only [PathGlob.mergePrefixes, List.length_cons]
            rw [mergedTail.2.2]
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
private theorem merged_path_matches
    {left right : PathGlob}
    (overlap : left.MayOverlap right) :
    left.Matches
        (PathGlob.mergePrefixes left.segments right.segments) ∧
      right.Matches
        (PathGlob.mergePrefixes left.segments right.segments) := by
  have prefixes := merged_prefix_matches overlap.1
  have lengths := compatible_lengths_allow_max overlap.2
  refine ⟨⟨prefixes.1, ?_⟩, ⟨prefixes.2.1, ?_⟩⟩
  · rw [prefixes.2.2]
    exact lengths.1
  · rw [prefixes.2.2]
    exact lengths.2

theorem PathGlob.mayOverlap_has_common_match
    {left right : PathGlob}
    (overlap : left.MayOverlap right) :
    ∃ path, left.Matches path ∧ right.Matches path :=
  ⟨PathGlob.mergePrefixes left.segments right.segments,
    merged_path_matches overlap⟩

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

/-- Every emitted diagnostic witness belongs to both glob languages. -/
theorem PathGlob.overlapWitness_sound
    {left right : PathGlob}
    {path : NormalizedPath}
    (witness : left.overlapWitness right = some path) :
    left.Matches path ∧ right.Matches path := by
  cases overlap : left.overlaps right with
  | false =>
      simp [PathGlob.overlapWitness, overlap] at witness
  | true =>
      simp [PathGlob.overlapWitness, overlap] at witness
      subst path
      exact merged_path_matches
        ((PathGlob.overlaps_correct left right).1 overlap)

/-- A witness is present exactly when the Bool overlap checker accepts. -/
theorem PathGlob.overlapWitness_isSome
    (left right : PathGlob) :
    (left.overlapWitness right).isSome = left.overlaps right := by
  cases overlap : left.overlaps right <;>
    simp [PathGlob.overlapWitness, overlap]

/-- `none` is a proof-relevant diagnostic for semantic disjointness. -/
theorem PathGlob.overlapWitness_eq_none_iff
    (left right : PathGlob) :
    left.overlapWitness right = none ↔
      ¬∃ path, left.Matches path ∧ right.Matches path := by
  cases overlap : left.overlaps right with
  | false =>
      simp only [PathGlob.overlapWitness, overlap, Bool.false_eq_true,
        ↓reduceIte, true_iff]
      intro common
      have accepted :=
        (PathGlob.overlaps_iff_common_match left right).2 common
      rw [overlap] at accepted
      contradiction
  | true =>
      simp only [PathGlob.overlapWitness, overlap, ↓reduceIte,
        Option.some_ne_none, false_iff]
      exact fun noCommon =>
        noCommon ((PathGlob.overlaps_iff_common_match left right).1 overlap)

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
