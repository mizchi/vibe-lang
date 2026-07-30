import VibeFormal.Proofs.PathScopeCorrect

set_option autoImplicit false

namespace VibeFormal.Capability.PathScope.Examples

private def fsEffect : EffectDefId :=
  ⟨"vibe/std", "fs", 0⟩

private def fsRead : OperationRef :=
  ⟨⟨fsEffect, 0⟩, [.resourceId 0]⟩

private def fsWrite : OperationRef :=
  ⟨⟨fsEffect, 1⟩, [.resourceId 0]⟩

private def sourceTree : PathGlob :=
  { segments := [.literal "src"]
    recursive := true }

private def generatedTree : PathGlob :=
  { segments := [.literal "src", .literal "generated"]
    recursive := true }

private def cacheTree : PathGlob :=
  { segments := [.literal "cache"]
    recursive := true }

private def sourceChild : PathGlob :=
  { segments := [.literal "src", .any]
    recursive := false }

private def generatedDirectory : PathGlob :=
  { segments := [.literal "src", .literal "generated"]
    recursive := false }

private def readSource : Grant Nat :=
  { domain := 0
    permissions := [fsRead]
    pattern := sourceTree }

private def writeGenerated : Grant Nat :=
  { domain := 0
    permissions := [fsWrite]
    pattern := generatedTree }

private def readGenerated : Grant Nat :=
  { domain := 0
    permissions := [fsRead]
    pattern := generatedTree }

private def writeCache : Grant Nat :=
  { domain := 0
    permissions := [fsWrite]
    pattern := cacheTree }

private def writeOtherDomain : Grant Nat :=
  { writeGenerated with domain := 1 }

private def readWriteSource : Grant Nat :=
  { domain := 0
    permissions := [fsRead, fsWrite]
    pattern := sourceTree }

private def reorderedReadWriteGenerated : Grant Nat :=
  { domain := 0
    permissions := [fsWrite, fsRead]
    pattern := generatedTree }

private def emptyEntry : EntryContract :=
  { requires := []
    forkRequires := []
    resources := [] }

private def emptyHost : HostProfile :=
  { provides := []
    forkable := []
    bindings := [] }

example : Policy.valid [readSource, writeGenerated] = false := by
  decide

example : Policy.valid [readSource, readGenerated] = true := by
  decide

/-- Authority equality is extensional rather than list-order-sensitive. -/
example :
    Policy.valid [readWriteSource, reorderedReadWriteGenerated] = true := by
  decide

example : Policy.valid [readSource, writeCache] = true := by
  decide

example : Policy.valid [readSource, writeOtherDomain] = true := by
  decide

example : PathGlob.overlaps sourceChild generatedDirectory = true := by
  decide

example :
    ∃ path,
      sourceChild.Matches path ∧ generatedDirectory.Matches path :=
  (PathGlob.overlaps_iff_common_match
    sourceChild generatedDirectory).1 (by decide)

example : emptyEntry.runnable emptyHost = true := by
  decide

/-- Ambiguous path authority blocks entry even when base preflight succeeds. -/
example :
    ScopedEntryContract.runnable
      { base := emptyEntry
        policy := [readSource, writeGenerated] }
      emptyHost = false := by
  decide

/-- Disjoint path authority composes with the existing ADR-0075 preflight. -/
example :
    ScopedEntryContract.runnable
      { base := emptyEntry
        policy := [readSource, writeCache] }
      emptyHost = true := by
  decide

example :
    PathGlob.matchesB sourceTree ["src", "generated", "output.wasm"] = true ∧
      PathGlob.matchesB generatedTree
        ["src", "generated", "output.wasm"] = true := by
  decide

/--
An order-sensitive first-match policy would silently choose read or write
authority for the same generated path.
-/
private def brokenFirstMatch
    (policy : Policy Nat)
    (path : NormalizedPath) : Option Authority :=
  (policy.find? fun grant => grant.pattern.matchesB path).map Grant.permissions

example :
    brokenFirstMatch [readSource, writeGenerated]
        ["src", "generated", "output.wasm"] = some [fsRead] ∧
      brokenFirstMatch [writeGenerated, readSource]
        ["src", "generated", "output.wasm"] = some [fsWrite] := by
  decide

end VibeFormal.Capability.PathScope.Examples
