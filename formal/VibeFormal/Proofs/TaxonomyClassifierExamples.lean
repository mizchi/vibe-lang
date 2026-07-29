import VibeFormal.Proofs.TaxonomyClassifierCorrect

set_option autoImplicit false

namespace VibeFormal.EffectTaxonomy.Classifier.Examples

private def fsEffect : EffectDefId :=
  ⟨"vibe/std", "fs", 0⟩

private def loggerEffect : EffectDefId :=
  ⟨"example/app", "logger", 0⟩

private def exceptionEffect : EffectDefId :=
  ⟨"vibe/core", "exception", 0⟩

private def unknownEffect : EffectDefId :=
  ⟨"example/app", "unknown", 0⟩

private def rootKind : Capability.ResourceKind :=
  ⟨0⟩

private def fsMetadata : Metadata :=
  { effectDef := fsEffect
    effectClass := .capability rootKind }

private def loggerMetadata : Metadata :=
  { effectDef := loggerEffect
    effectClass := .algebraic }

private def exceptionMetadata : Metadata :=
  { effectDef := exceptionEffect
    effectClass := .coreException }

private def catalog : Catalog :=
  [fsMetadata, loggerMetadata, exceptionMetadata]

private def fsRead : OperationRef :=
  ⟨⟨fsEffect, 0⟩, [.resourceId 0]⟩

private def fsReadWithoutResource : OperationRef :=
  ⟨⟨fsEffect, 0⟩, []⟩

private def loggerLog : OperationRef :=
  ⟨⟨loggerEffect, 0⟩, []⟩

private def forgedResourceLogger : OperationRef :=
  ⟨⟨loggerEffect, 0⟩, [.resourceId 0]⟩

private def ioException : OperationRef :=
  ⟨⟨exceptionEffect, 0⟩, [.typeId 7]⟩

private def malformedException : OperationRef :=
  ⟨⟨exceptionEffect, 0⟩, [.typeId 7, .typeId 8]⟩

private def unknownOperation : OperationRef :=
  ⟨⟨unknownEffect, 0⟩, []⟩

private def sourceRoot : EffectTaxonomy.CapabilityRef :=
  { operation := fsRead
    resourceKind := rootKind
    resource := ⟨0⟩ }

example :
    classifyOperation catalog fsRead =
      some (.capability sourceRoot) := by
  decide

example :
    classifyOperation catalog loggerLog =
      some (.algebraic loggerLog) := by
  decide

example :
    classifyOperation catalog ioException =
      some (.exception 7) := by
  decide

/-- Capability metadata without exactly one logical resource fails closed. -/
example :
    classifyOperation catalog fsReadWithoutResource = none := by
  decide

/-- Algebraic metadata cannot be overridden by forging a resource argument. -/
example :
    classifyOperation catalog forgedResourceLogger = none := by
  decide

/-- Core exceptions retain exactly one normalized payload type identity. -/
example :
    classifyOperation catalog malformedException = none := by
  decide

/-- Missing metadata cannot silently invent an effect class. -/
example :
    classifyOperation catalog unknownOperation = none := by
  decide

/-- Duplicate declaration identity is ambiguous and therefore rejected. -/
private def duplicateFsCatalog : Catalog :=
  [fsMetadata, { fsMetadata with effectClass := .algebraic }]

example :
    classifyOperation duplicateFsCatalog fsRead = none := by
  decide

/-- A successful row keeps every operation and produces a well-formed row. -/
private def classifiedRow : EffectTaxonomy.Row :=
  [.capability sourceRoot, .algebraic loggerLog, .exception 7]

example :
    classifyRow catalog [fsRead, loggerLog, ioException] =
      some classifiedRow := by
  decide

example : EffectTaxonomy.Row.WellFormed classifiedRow := by
  exact (classifyRow_sound
    catalog
    [fsRead, loggerLog, ioException]
    classifiedRow
    (by decide)).1

/--
Rejected classifier: argument shape alone upgrades an algebraic declaration to
a capability, bypassing the catalog's source-of-truth class.
-/
private def brokenInferClassFromArguments
    (operation : OperationRef) : Option EffectTaxonomy.Requirement :=
  match operation.uniqueResourceId? with
  | some resource =>
      some (.capability {
        operation
        resourceKind := rootKind
        resource
      })
  | none => some (.algebraic operation)

example :
    brokenInferClassFromArguments forgedResourceLogger =
      some (.capability {
        operation := forgedResourceLogger
        resourceKind := rootKind
        resource := ⟨0⟩
      }) ∧
      classifyOperation catalog forgedResourceLogger = none := by
  decide

/--
Rejected row conversion: `filterMap` silently drops a malformed operation and
therefore changes the semantic row instead of rejecting it.
-/
private def brokenDropFailures
    (catalog : Catalog)
    (operations : List OperationRef) : EffectTaxonomy.Row :=
  operations.filterMap (classifyOperation catalog)

example :
    brokenDropFailures catalog [forgedResourceLogger, loggerLog] =
      [.algebraic loggerLog] ∧
      classifyRow catalog [forgedResourceLogger, loggerLog] = none := by
  decide

end VibeFormal.EffectTaxonomy.Classifier.Examples
