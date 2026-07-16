import VibeFormal.Module.Policy

set_option autoImplicit false

namespace VibeFormal.Module

private theorem every_holds
    {Item : Type}
    {predicate : Item → Prop}
    {items : List Item}
    (every : Every predicate items)
    {item : Item}
    (member : item ∈ items) :
    predicate item := by
  induction items with
  | nil => simp at member
  | cons head tail induction =>
      simp only [Every] at every
      simp only [List.mem_cons] at member
      rcases member with equals | member
      · subst item
        exact every.1
      · exact induction every.2 member

theorem valid_correct (workspace : Workspace) :
    workspace.valid = true ↔ Valid workspace := by
  simp [Workspace.valid]

theorem boundary_correct (workspace : Workspace) (directory : Directory) :
    workspace.isBoundary directory = true ↔ Boundary workspace directory := by
  simp [Workspace.isBoundary]

theorem implicit_build_root_correct
    (workspace : Workspace)
    (boundary : Directory)
    (source : Source) :
    workspace.isImplicitBuildRoot boundary source = true ↔
      workspace.IsImplicitBuildRoot boundary source := by
  simp [Workspace.isImplicitBuildRoot]

theorem shared_import_inheritance_correct
    (workspace : Workspace)
    (source : Source) :
    workspace.inheritsSharedImports source = true ↔
      workspace.InheritsSharedImports source := by
  simp [Workspace.inheritsSharedImports]

theorem import_allowed_correct
    (workspace : Workspace)
    (importer target : Source) :
    workspace.importAllowed importer target = true ↔
      workspace.AllowedImport importer target := by
  simp [Workspace.importAllowed]

/-- A valid workspace contains no symlink source. -/
theorem valid_source_is_regular
    {workspace : Workspace}
    (valid : Valid workspace)
    {source : Source}
    (present : SourcePresent workspace source) :
    source.kind = .regular := by
  exact every_holds valid.1 present

/-- Test and bench companions can be importers, but never import targets. -/
theorem allowed_import_target_is_not_companion
    {workspace : Workspace}
    {importer target : Source}
    (allowed : workspace.AllowedImport importer target) :
    target.role ≠ .testCompanion ∧ target.role ≠ .benchCompanion := by
  rcases allowed with ⟨_, _, _, _, _, visible⟩
  constructor
  · intro role
    unfold Workspace.TargetVisible at visible
    rw [role] at visible
    exact visible
  · intro role
    unfold Workspace.TargetVisible at visible
    rw [role] at visible
    exact visible

/-- A reachable explicit-only dependency is covered by the package hash. -/
theorem reachable_explicit_only_is_hashed
    {source : Source}
    (role : source.role = .explicitOnly) :
    source.includedInPackageHash true = true := by
  simp [Source.includedInPackageHash,
    Source.automaticallyIncludedInPackageHash, role]

/-- An owned production implementation cannot be imported across package ownership. -/
theorem different_owner_cannot_import_production
    {workspace : Workspace}
    {importer target : Source}
    (production : target.role = .production)
    (targetOwned : workspace.ownerOf target ≠ none)
    (different : workspace.ownerOf importer ≠ workspace.ownerOf target) :
    ¬workspace.AllowedImport importer target := by
  intro allowed
  rcases allowed with ⟨_, _, _, _, _, visible⟩
  unfold Workspace.TargetVisible at visible
  rw [production] at visible
  rcases visible with ownerless | same
  · exact targetOwned ownerless
  · exact different same

/-- A regular ownerless production source is public compatibility space. -/
theorem ownerless_can_import_production
    {workspace : Workspace}
    {importer target : Source}
    (valid : Valid workspace)
    (importerPresent : SourcePresent workspace importer)
    (targetPresent : SourcePresent workspace target)
    (importerRegular : importer.kind = .regular)
    (targetRegular : target.kind = .regular)
    (production : target.role = .production)
    (ownerless : workspace.ownerOf target = none) :
    workspace.AllowedImport importer target := by
  refine ⟨valid, importerPresent, targetPresent, importerRegular,
    targetRegular, ?_⟩
  unfold Workspace.TargetVisible
  rw [production]
  exact Or.inl ownerless

/-- An explicitly-run companion may import a regular production source it owns. -/
theorem same_owner_can_import_production
    {workspace : Workspace}
    {importer target : Source}
    (valid : Valid workspace)
    (importerPresent : SourcePresent workspace importer)
    (targetPresent : SourcePresent workspace target)
    (importerRegular : importer.kind = .regular)
    (targetRegular : target.kind = .regular)
    (production : target.role = .production)
    (same : workspace.ownerOf importer = workspace.ownerOf target) :
    workspace.AllowedImport importer target := by
  refine ⟨valid, importerPresent, targetPresent, importerRegular,
    targetRegular, ?_⟩
  unfold Workspace.TargetVisible
  rw [production]
  exact Or.inr same

end VibeFormal.Module
