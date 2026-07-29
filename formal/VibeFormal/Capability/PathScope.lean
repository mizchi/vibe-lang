import VibeFormal.Capability.Contract

set_option autoImplicit false

namespace VibeFormal.Capability.PathScope

/--
A path after platform-independent normalization. Empty segments, `.`, `..`,
absolute roots, symlinks, and case folding are provider/binding obligations
outside this syntax-level model.
-/
abbrev NormalizedPath := List String

/--
One normalized path-segment pattern. Phase 1 deliberately supports only a
literal segment or `*`; recursive matching is represented separately as a
trailing `**`.
-/
inductive SegmentPattern where
  | literal (value : String)
  | any
  deriving DecidableEq, Repr

namespace SegmentPattern

def Matches (pattern : SegmentPattern) (segment : String) : Prop :=
  match pattern with
  | .literal expected => expected = segment
  | .any => True

def matchesB (pattern : SegmentPattern) (segment : String) : Bool :=
  match pattern with
  | .literal expected => decide (expected = segment)
  | .any => true

/-- Two segment patterns can match the same normalized segment. -/
def Compatible (left right : SegmentPattern) : Prop :=
  match left, right with
  | .literal left, .literal right => left = right
  | _, _ => True

def compatible (left right : SegmentPattern) : Bool :=
  match left, right with
  | .literal left, .literal right => decide (left = right)
  | _, _ => true

end SegmentPattern

/--
A restricted, normalized glob. `recursive = true` means a trailing `/**`;
otherwise the pattern matches exactly the listed number of path segments.
-/
structure PathGlob where
  segments : List SegmentPattern
  recursive : Bool
  deriving DecidableEq, Repr

namespace PathGlob

def PrefixMatches :
    List SegmentPattern → NormalizedPath → Prop
  | [], _ => True
  | _ :: _, [] => False
  | pattern :: patterns, segment :: segments =>
      pattern.Matches segment ∧ PrefixMatches patterns segments

def prefixMatches :
    List SegmentPattern → NormalizedPath → Bool
  | [], _ => true
  | _ :: _, [] => false
  | pattern :: patterns, segment :: segments =>
      pattern.matchesB segment && prefixMatches patterns segments

def LengthAllowed (pattern : PathGlob) (pathLength : Nat) : Prop :=
  if pattern.recursive then
    pattern.segments.length ≤ pathLength
  else
    pattern.segments.length = pathLength

def lengthAllowed (pattern : PathGlob) (pathLength : Nat) : Bool :=
  if pattern.recursive then
    decide (pattern.segments.length ≤ pathLength)
  else
    decide (pattern.segments.length = pathLength)

def Matches (pattern : PathGlob) (path : NormalizedPath) : Prop :=
  PrefixMatches pattern.segments path ∧
    pattern.LengthAllowed path.length

def matchesB (pattern : PathGlob) (path : NormalizedPath) : Bool :=
  prefixMatches pattern.segments path &&
    pattern.lengthAllowed path.length

/--
Compatibility over the shared prefix. If either prefix ends, the remaining
segments can be consumed only when the length constraint permits it.
-/
def PrefixCompatible :
    List SegmentPattern → List SegmentPattern → Prop
  | [], _ => True
  | _, [] => True
  | left :: lefts, right :: rights =>
      left.Compatible right ∧ PrefixCompatible lefts rights

def prefixCompatible :
    List SegmentPattern → List SegmentPattern → Bool
  | [], _ => true
  | _, [] => true
  | left :: lefts, right :: rights =>
      left.compatible right && prefixCompatible lefts rights

/-- Whether the two exact/trailing-recursive length domains intersect. -/
def LengthCompatible (left right : PathGlob) : Prop :=
  match left.recursive, right.recursive with
  | false, false => left.segments.length = right.segments.length
  | true, false => left.segments.length ≤ right.segments.length
  | false, true => right.segments.length ≤ left.segments.length
  | true, true => True

def lengthCompatible (left right : PathGlob) : Bool :=
  match left.recursive, right.recursive with
  | false, false => decide (left.segments.length = right.segments.length)
  | true, false => decide (left.segments.length ≤ right.segments.length)
  | false, true => decide (right.segments.length ≤ left.segments.length)
  | true, true => true

/--
The conservative overlap relation used by policy validation. The correctness
proof establishes that two patterns matching one path always satisfy this
relation, so the checker has no false-negative ambiguity.
-/
def MayOverlap (left right : PathGlob) : Prop :=
  PrefixCompatible left.segments right.segments ∧
    LengthCompatible left right

def overlaps (left right : PathGlob) : Bool :=
  prefixCompatible left.segments right.segments &&
    lengthCompatible left right

end PathGlob

/--
One permission grant. `Domain` is `ResourceId` during source/plan validation
and may be a physical-root identity after BindingLock resolution.
-/
structure Grant (Domain : Type) where
  domain : Domain
  permissions : Authority
  pattern : PathGlob
  deriving Repr

namespace Grant

def PermissionsEquivalent {Domain : Type}
    (left right : Grant Domain) : Prop :=
  EffectRow.Equivalent left.permissions right.permissions

def permissionsEquivalentB {Domain : Type}
    (left right : Grant Domain) : Bool :=
  EffectRow.subset left.permissions right.permissions &&
    EffectRow.subset right.permissions left.permissions

def Compatible {Domain : Type} [DecidableEq Domain]
    (left right : Grant Domain) : Prop :=
  left.domain ≠ right.domain ∨
    left.PermissionsEquivalent right ∨
    ¬left.pattern.MayOverlap right.pattern

def compatible {Domain : Type} [DecidableEq Domain]
    (left right : Grant Domain) : Bool :=
  if left.domain = right.domain then
    if left.permissionsEquivalentB right then
      true
    else
      !left.pattern.overlaps right.pattern
  else
    true

end Grant

abbrev Policy (Domain : Type) := List (Grant Domain)

namespace Policy

def Valid {Domain : Type} [DecidableEq Domain]
    (policy : Policy Domain) : Prop :=
  ∀ left, left ∈ policy →
    ∀ right, right ∈ policy →
      left.Compatible right

def valid {Domain : Type} [DecidableEq Domain]
    (policy : Policy Domain) : Bool :=
  policy.all fun left =>
    policy.all fun right =>
      left.compatible right

end Policy

/--
ADR-0075 entry preflight extended with path-scope policy validation. `Domain`
can denote logical resources during planning or resolved physical roots after
BindingLock construction.
-/
structure ScopedEntryContract (Domain : Type) where
  base : EntryContract
  policy : Policy Domain
  deriving Repr

def ScopedRunnable {Domain : Type} [DecidableEq Domain]
    (contract : ScopedEntryContract Domain)
    (host : HostProfile) : Prop :=
  Capability.Runnable contract.base host ∧ contract.policy.Valid

namespace ScopedEntryContract

def runnable {Domain : Type} [DecidableEq Domain]
    (contract : ScopedEntryContract Domain)
    (host : HostProfile) : Bool :=
  contract.base.runnable host && contract.policy.valid

end ScopedEntryContract

end VibeFormal.Capability.PathScope
