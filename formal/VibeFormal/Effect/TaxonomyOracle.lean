import VibeFormal.Effect.TaxonomyClassifier

set_option autoImplicit false

namespace VibeFormal.EffectTaxonomy.Classifier.Oracle

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

private def fullCatalog : Catalog :=
  [fsMetadata, loggerMetadata, exceptionMetadata]

private def fsRead : OperationRef :=
  ⟨⟨fsEffect, 0⟩, [.resourceId 0]⟩

private def fsReadGeneric : OperationRef :=
  ⟨⟨fsEffect, 0⟩, [.typeId 3, .resourceId 0]⟩

private def fsReadWithoutResource : OperationRef :=
  ⟨⟨fsEffect, 0⟩, []⟩

private def fsReadWithTwoResources : OperationRef :=
  ⟨⟨fsEffect, 0⟩, [.resourceId 0, .resourceId 1]⟩

private def loggerLog : OperationRef :=
  ⟨⟨loggerEffect, 0⟩, []⟩

private def genericLoggerLog : OperationRef :=
  ⟨⟨loggerEffect, 0⟩, [.typeId 3, .regionId 4]⟩

private def forgedResourceLogger : OperationRef :=
  ⟨⟨loggerEffect, 0⟩, [.resourceId 0]⟩

private def ioException : OperationRef :=
  ⟨⟨exceptionEffect, 0⟩, [.typeId 7]⟩

private def exceptionWithoutType : OperationRef :=
  ⟨⟨exceptionEffect, 0⟩, []⟩

private def exceptionWithTwoTypes : OperationRef :=
  ⟨⟨exceptionEffect, 0⟩, [.typeId 7, .typeId 8]⟩

private def resourceException : OperationRef :=
  ⟨⟨exceptionEffect, 0⟩, [.resourceId 0]⟩

private def unknownOperation : OperationRef :=
  ⟨⟨unknownEffect, 0⟩, []⟩

private def sourceRoot (operation : OperationRef) : CapabilityRef :=
  { operation
    resourceKind := rootKind
    resource := ⟨0⟩ }

structure OracleCase where
  name : String
  issue : String
  catalog : Catalog
  operations : List OperationRef
  expected : Option Row

def capabilityResource : OracleCase := {
  name := "capability-resource"
  issue := "#1218"
  catalog := fullCatalog
  operations := [fsRead]
  expected := some [.capability (sourceRoot fsRead)]
}

def capabilityGenericResource : OracleCase := {
  name := "capability-generic-resource"
  issue := "#1218"
  catalog := fullCatalog
  operations := [fsReadGeneric]
  expected := some [.capability (sourceRoot fsReadGeneric)]
}

def algebraicResourceFree : OracleCase := {
  name := "algebraic-resource-free"
  issue := "#1218"
  catalog := fullCatalog
  operations := [loggerLog]
  expected := some [.algebraic loggerLog]
}

def algebraicGenericRegion : OracleCase := {
  name := "algebraic-generic-region"
  issue := "#1218"
  catalog := fullCatalog
  operations := [genericLoggerLog]
  expected := some [.algebraic genericLoggerLog]
}

def coreExceptionTyped : OracleCase := {
  name := "core-exception-typed"
  issue := "#1218/#1136"
  catalog := fullCatalog
  operations := [ioException]
  expected := some [.exception 7]
}

def mixedRow : OracleCase := {
  name := "mixed-row"
  issue := "#1218"
  catalog := fullCatalog
  operations := [fsRead, loggerLog, ioException]
  expected := some [
    .capability (sourceRoot fsRead),
    .algebraic loggerLog,
    .exception 7
  ]
}

def unknownMetadata : OracleCase := {
  name := "unknown-metadata"
  issue := "#1218"
  catalog := fullCatalog
  operations := [unknownOperation]
  expected := none
}

def duplicateMetadata : OracleCase := {
  name := "duplicate-metadata"
  issue := "#1218"
  catalog := [fsMetadata, { fsMetadata with effectClass := .algebraic }]
  operations := [fsRead]
  expected := none
}

def capabilityMissingResource : OracleCase := {
  name := "capability-missing-resource"
  issue := "#1218"
  catalog := fullCatalog
  operations := [fsReadWithoutResource]
  expected := none
}

def capabilityDuplicateResource : OracleCase := {
  name := "capability-duplicate-resource"
  issue := "#1218"
  catalog := fullCatalog
  operations := [fsReadWithTwoResources]
  expected := none
}

def algebraicForgedResource : OracleCase := {
  name := "algebraic-forged-resource"
  issue := "#1218"
  catalog := fullCatalog
  operations := [forgedResourceLogger]
  expected := none
}

def exceptionMissingType : OracleCase := {
  name := "exception-missing-type"
  issue := "#1218/#1136"
  catalog := fullCatalog
  operations := [exceptionWithoutType]
  expected := none
}

def exceptionMultipleTypes : OracleCase := {
  name := "exception-multiple-types"
  issue := "#1218/#1136"
  catalog := fullCatalog
  operations := [exceptionWithTwoTypes]
  expected := none
}

def exceptionResourceArgument : OracleCase := {
  name := "exception-resource-argument"
  issue := "#1218/#1136"
  catalog := fullCatalog
  operations := [resourceException]
  expected := none
}

def rowFailsAtomically : OracleCase := {
  name := "row-fails-atomically"
  issue := "#1218"
  catalog := fullCatalog
  operations := [loggerLog, forgedResourceLogger]
  expected := none
}

def cases : List OracleCase := [
  capabilityResource,
  capabilityGenericResource,
  algebraicResourceFree,
  algebraicGenericRegion,
  coreExceptionTyped,
  mixedRow,
  unknownMetadata,
  duplicateMetadata,
  capabilityMissingResource,
  capabilityDuplicateResource,
  algebraicForgedResource,
  exceptionMissingType,
  exceptionMultipleTypes,
  exceptionResourceArgument,
  rowFailsAtomically
]

def OracleCase.actual (testCase : OracleCase) : Option Row :=
  classifyRow testCase.catalog testCase.operations

def OracleCase.passes (testCase : OracleCase) : Bool :=
  decide (testCase.actual = testCase.expected)

def allCasesPass : Bool :=
  cases.all OracleCase.passes

private def renderList {α : Type}
    (render : α → String)
    (items : List α) : String :=
  "[" ++ String.intercalate "," (items.map render) ++ "]"

private def renderEffectDef (effectDef : EffectDefId) : String :=
  effectDef.packageName ++ "/" ++ effectDef.moduleName ++ "#" ++
    toString effectDef.definitionIndex

private def renderEffectClass : EffectClass → String
  | .capability resourceKind =>
      "capability(kind=" ++ toString resourceKind.value ++ ")"
  | .algebraic => "algebraic"
  | .coreException => "core-exception"

private def renderMetadata (metadata : Metadata) : String :=
  renderEffectDef metadata.effectDef ++ "=" ++
    renderEffectClass metadata.effectClass

private def renderArgument : EffectArgument → String
  | .typeId id => "type:" ++ toString id
  | .regionId id => "region:" ++ toString id
  | .resourceId id => "resource:" ++ toString id

private def renderOperation (operation : OperationRef) : String :=
  renderEffectDef operation.id.effectDef ++ ":" ++
    toString operation.id.operationIndex ++
    "(" ++ String.intercalate "," (operation.arguments.map renderArgument) ++ ")"

private def renderRequirement : Requirement → String
  | .capability capabilityRef =>
      "capability(" ++ renderOperation capabilityRef.operation ++
        ";kind=" ++ toString capabilityRef.resourceKind.value ++
        ";resource=" ++ toString capabilityRef.resource.value ++ ")"
  | .algebraic operation =>
      "algebraic(" ++ renderOperation operation ++ ")"
  | .exception kind =>
      "exception(kind=" ++ toString kind ++ ")"

private def renderOutcome : Option Row → String × String
  | some row => ("accept", renderList renderRequirement row)
  | none => ("reject", "none")

private def renderCase (testCase : OracleCase) : String :=
  let (verdict, result) := renderOutcome testCase.actual
  String.intercalate "\t" [
    testCase.name,
    testCase.issue,
    verdict,
    result,
    renderList renderMetadata testCase.catalog,
    renderList renderOperation testCase.operations
  ]

def renderCorpus : String :=
  "version\t1\n" ++
    "name\tissue\tverdict\tresult\tcatalog\toperations\n" ++
    String.intercalate "\n" (cases.map renderCase) ++ "\n"

end VibeFormal.EffectTaxonomy.Classifier.Oracle
