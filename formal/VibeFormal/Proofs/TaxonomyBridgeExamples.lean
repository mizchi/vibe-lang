import VibeFormal.Proofs.TaxonomyBridgeCorrect

set_option autoImplicit false

namespace VibeFormal.EffectTaxonomy.Bridge.Examples

private def fsEffect : EffectDefId :=
  ⟨"vibe/std", "fs", 0⟩

private def loggerEffect : EffectDefId :=
  ⟨"example/app", "logger", 0⟩

private def fsReadSource : OperationRef :=
  ⟨⟨fsEffect, 0⟩, [.resourceId 0]⟩

private def loggerLog : OperationRef :=
  ⟨⟨loggerEffect, 0⟩, []⟩

private def sourceRoot : EffectTaxonomy.CapabilityRef :=
  { operation := fsReadSource
    resourceKind := ⟨0⟩
    resource := ⟨0⟩ }

/-- Same operation/resource identity, but a different nominal resource kind. -/
private def wrongKindSourceRoot : EffectTaxonomy.CapabilityRef :=
  { operation := fsReadSource
    resourceKind := ⟨1⟩
    resource := ⟨0⟩ }

private def fullHost : EffectTaxonomy.HostProfile :=
  { provides := [sourceRoot]
    forkable := [sourceRoot] }

private def wrongKindHost : EffectTaxonomy.HostProfile :=
  { provides := [wrongKindSourceRoot]
    forkable := [wrongKindSourceRoot] }

private def entryRow : EffectTaxonomy.Row :=
  [.capability sourceRoot, .exception 0]

private def childRow : EffectTaxonomy.Row :=
  [.capability sourceRoot]

/-- Complete taxonomy admission refines to the existing ADR-0075 preflight. -/
example :
    (toEntryContract entryRow childRow).runnable
      (toHostProfile fullHost) = true := by
  exact runnableB_refines_capability_contract
    (row := entryRow)
    (forkRow := childRow)
    (host := fullHost)
    (by decide)
    (by decide)

/-- Exact taxonomy identity rejects a provider with the wrong resource kind. -/
example :
    EffectTaxonomy.runnableB
      [.capability sourceRoot]
      wrongKindHost = false := by
  decide

/--
The bridge retains resource claims and bindings, so ADR-0075 preflight also
rejects the wrong-kind provider even though its projected operation matches.
-/
example :
    (toEntryContract [.capability sourceRoot] []).runnable
      (toHostProfile wrongKindHost) = false := by
  decide

/-- Rejected projection: dropping resource claims loses nominal-kind safety. -/
private def brokenDropClaims
    (row forkRow : EffectTaxonomy.Row) : Capability.EntryContract :=
  { toEntryContract row forkRow with resources := [] }

example :
    (brokenDropClaims [.capability sourceRoot] []).runnable
      (toHostProfile wrongKindHost) = true := by
  decide

/--
Projection is intentionally one-way: if taxonomy admission is skipped, an
undischarged algebraic effect disappears from the capability-only contract.
-/
example :
    EffectTaxonomy.runnableB [.algebraic loggerLog] fullHost = false ∧
      (toEntryContract [.algebraic loggerLog] []).runnable
        (toHostProfile fullHost) = true := by
  decide

end VibeFormal.EffectTaxonomy.Bridge.Examples
