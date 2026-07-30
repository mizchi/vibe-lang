import VibeFormal.Proofs.EffectTaxonomyCorrect

set_option autoImplicit false

namespace VibeFormal.EffectTaxonomy.Examples

private def fsEffect : EffectDefId :=
  ⟨"vibe/std", "fs", 0⟩

private def loggerEffect : EffectDefId :=
  ⟨"example/app", "logger", 0⟩

private def fsReadOperation (resource : Nat) : OperationRef :=
  ⟨⟨fsEffect, 0⟩, [.resourceId resource]⟩

private def loggerLog : OperationRef :=
  ⟨⟨loggerEffect, 0⟩, []⟩

private def sourceRoot : CapabilityRef :=
  { operation := fsReadOperation 0
    resourceKind := ⟨0⟩
    resource := ⟨0⟩ }

private def cacheRoot : CapabilityRef :=
  { operation := fsReadOperation 1
    resourceKind := ⟨0⟩
    resource := ⟨1⟩ }

private def fullHost : HostProfile :=
  { provides := [sourceRoot]
    forkable := [sourceRoot] }

private def serialHost : HostProfile :=
  { provides := [sourceRoot]
    forkable := [] }

/-- Capability + declared core exception is a valid entry row. -/
example :
    runnableB [.capability sourceRoot, .exception 0] fullHost = true := by
  decide

/-- Resource identity is exact: CacheRoot cannot satisfy SourceRoot. -/
example :
    runnableB [.capability cacheRoot] fullHost = false := by
  decide

/-- A host never resolves an undischarged algebraic Logger effect. -/
example :
    runnableB [.algebraic loggerLog] fullHost = false := by
  decide

/-- A resource-qualified operation cannot be mislabeled as algebraic. -/
example :
    Row.wellFormedB [.algebraic (fsReadOperation 0)] = false := by
  decide

/-- Handling Logger removes only Logger and preserves capability/core rows. -/
example :
    Row.dischargeAlgebraic loggerEffect
      [.algebraic loggerLog, .capability sourceRoot, .exception 0] =
        [.capability sourceRoot, .exception 0] := by
  decide

/-- An exception handler removes only its exact normalized exception kind. -/
example :
    Row.dischargeException 0 [.exception 0, .exception 1] =
      [.exception 1] := by
  decide

/-- A fork-safe capability and exact parent exception row may be delegated. -/
example :
    canSpawnB fullHost
      [.capability sourceRoot, .exception 0]
      [.capability sourceRoot, .exception 0] = true := by
  decide

/-- Provider availability without fork-safe evidence cannot authorize a child. -/
example :
    canSpawnB serialHost
      [.capability sourceRoot]
      [.capability sourceRoot] = false := by
  decide

/-- Algebraic evidence remains task-local even if the parent row contains it. -/
example :
    canSpawnB fullHost
      [.algebraic loggerLog]
      [.algebraic loggerLog] = false := by
  decide

/--
Rejected checker: projecting only capabilities before preflight silently drops
an algebraic requirement, so Logger appears runnable on an unrelated host.
-/
private def brokenCapabilityProjectionRunnable
    (row : Row)
    (host : HostProfile) : Bool :=
  host.validB &&
    (Row.capabilities row).all fun capabilityRef =>
      decide (capabilityRef ∈ host.provides)

example :
    brokenCapabilityProjectionRunnable [.algebraic loggerLog] fullHost = true ∧
      runnableB [.algebraic loggerLog] fullHost = false := by
  decide

end VibeFormal.EffectTaxonomy.Examples
