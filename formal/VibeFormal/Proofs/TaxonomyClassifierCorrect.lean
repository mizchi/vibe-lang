import VibeFormal.Effect.TaxonomyClassifier
import VibeFormal.Proofs.EffectTaxonomyCorrect

set_option autoImplicit false

namespace VibeFormal.EffectTaxonomy.Classifier

theorem mem_resourceIds
    {operation : OperationRef}
    {resource : Capability.ResourceId} :
    resource ∈ operation.resourceIds ↔
      .resourceId resource.value ∈ operation.arguments := by
  constructor
  · intro membership
    rw [OperationRef.resourceIds, List.mem_filterMap] at membership
    obtain ⟨argument, present, mapped⟩ := membership
    cases argument with
    | resourceId id =>
        cases mapped
        exact present
    | typeId id =>
        simp at mapped
    | regionId id =>
        simp at mapped
  · intro membership
    rw [OperationRef.resourceIds, List.mem_filterMap]
    exact ⟨.resourceId resource.value, membership, rfl⟩

theorem uniqueResourceId_mem
    {operation : OperationRef}
    {resource : Capability.ResourceId}
    (unique : operation.uniqueResourceId? = some resource) :
    .resourceId resource.value ∈ operation.arguments := by
  unfold OperationRef.uniqueResourceId? at unique
  split at unique
  · rename_i selected equation
    cases unique
    apply mem_resourceIds.mp
    rw [equation]
    simp
  · contradiction

theorem exceptionKind?_eq_some
    {operation : OperationRef}
    {kind : ExceptionPolicy.ExceptionKind} :
    operation.exceptionKind? = some kind ↔
      operation.arguments = [.typeId kind] := by
  constructor
  · intro classified
    unfold OperationRef.exceptionKind? at classified
    split at classified
    · rename_i selected equation
      cases classified
      exact equation
    · contradiction
  · intro argumentShape
    simp [OperationRef.exceptionKind?, argumentShape]

theorem classifyOperation_correct
    (catalog : Catalog)
    (operation : OperationRef)
    (requirement : EffectTaxonomy.Requirement) :
    classifyOperation catalog operation = some requirement ↔
      Classifies catalog operation requirement := by
  constructor
  · intro classified
    unfold classifyOperation at classified
    split at classified
    next resourceKind classFound =>
      split at classified
      next resource resourceFound =>
        cases classified
        exact .capability resourceKind resource classFound resourceFound
      next =>
        contradiction
    next classFound =>
      split at classified
      next resourceFree =>
        cases classified
        exact .algebraic classFound
          ((EffectTaxonomy.operationResourceFreeB_correct operation).mp
            resourceFree)
      next =>
        contradiction
    next classFound =>
      split at classified
      next kind kindFound =>
        cases classified
        exact .coreException kind classFound
          (exceptionKind?_eq_some.mp kindFound)
      next =>
        contradiction
    next =>
      contradiction
  · intro relation
    cases relation with
    | capability resourceKind resource classFound resourceFound =>
        simp [classifyOperation, classFound, resourceFound]
    | algebraic classFound resourceFree =>
        have resourceFreeChecked :
            operation.resourceFreeB = true :=
          (EffectTaxonomy.operationResourceFreeB_correct operation).mpr
            resourceFree
        simp [classifyOperation, classFound, resourceFreeChecked]
    | coreException kind classFound argumentShape =>
        have kindFound : operation.exceptionKind? = some kind :=
          exceptionKind?_eq_some.mpr argumentShape
        simp [classifyOperation, classFound, kindFound]

theorem classifyOperation_valid
    (catalog : Catalog)
    (operation : OperationRef)
    (requirement : EffectTaxonomy.Requirement)
    (classified : classifyOperation catalog operation = some requirement) :
    EffectTaxonomy.Row.RequirementValid requirement := by
  have relation :=
    (classifyOperation_correct catalog operation requirement).mp classified
  cases relation with
  | capability resourceKind resource classFound resourceFound =>
      exact uniqueResourceId_mem resourceFound
  | algebraic classFound resourceFree =>
      exact resourceFree
  | coreException kind classFound argumentShape =>
      trivial

/--
Successful classification is all-or-nothing: every resolved operation becomes
one valid taxonomy requirement, with no silently dropped row element.
-/
theorem classifyRow_sound
    (catalog : Catalog)
    (operations : List OperationRef)
    (row : EffectTaxonomy.Row)
    (classified : classifyRow catalog operations = some row) :
    EffectTaxonomy.Row.WellFormed row ∧
      row.length = operations.length := by
  induction operations generalizing row with
  | nil =>
      simp [classifyRow] at classified
      subst row
      exact ⟨by simp [EffectTaxonomy.Row.WellFormed], rfl⟩
  | cons operation operations inductionHypothesis =>
      simp only [classifyRow] at classified
      cases operationClassified :
        classifyOperation catalog operation with
      | none =>
          simp [operationClassified] at classified
      | some requirement =>
          rw [operationClassified] at classified
          cases tailClassified :
            classifyRow catalog operations with
          | none =>
              simp [tailClassified] at classified
          | some tail =>
              rw [tailClassified] at classified
              have headValid :=
                classifyOperation_valid
                  catalog operation requirement operationClassified
              cases classified
              obtain ⟨tailWellFormed, tailLength⟩ :=
                inductionHypothesis tail tailClassified
              constructor
              · intro candidate membership
                rcases List.mem_cons.mp membership with rfl | inTail
                · exact headValid
                · exact tailWellFormed candidate inTail
              · simp [tailLength]

end VibeFormal.EffectTaxonomy.Classifier
