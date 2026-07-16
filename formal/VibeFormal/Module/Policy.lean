import VibeFormal.Module.Path

set_option autoImplicit false

namespace VibeFormal.Module

inductive SourceKind where
  | regular
  | symlink
  deriving DecidableEq, Repr

inductive FileRole where
  | contract
  | legacyContract
  | legacyIndex
  | production
  | testCompanion
  | benchCompanion
  | explicitOnly
  | ignored
  deriving DecidableEq, Repr

structure Source where
  directory : Directory
  name : String
  kind : SourceKind
  deriving DecidableEq, Repr

namespace Source

def regular (directory : Directory) (name : String) : Source :=
  ⟨directory, name, .regular⟩

def symlink (directory : Directory) (name : String) : Source :=
  ⟨directory, name, .symlink⟩

/-- Canonical filename classification used by build and hash policy. -/
def role (source : Source) : FileRole :=
  if source.name == "index.vpkg" then
    .contract
  else if source.name == "index.vibei" then
    .legacyContract
  else if source.name == "index.vibe" then
    .legacyIndex
  else if source.name.endsWith "_test.vibe" then
    .testCompanion
  else if source.name.endsWith "_bench.vibe" then
    .benchCompanion
  else if source.name.startsWith "_" then
    .explicitOnly
  else if source.name.endsWith ".draft.vibe" then
    .explicitOnly
  else if source.name.endsWith ".vibe" then
    .production
  else
    .ignored

def fullPath (source : Source) : List String :=
  source.directory.segments ++ [source.name]

/-- Sources included without following an explicit relative dependency edge. -/
def automaticallyIncludedInPackageHash (source : Source) : Bool :=
  match source.role with
  | .contract | .legacyContract | .production => true
  | .legacyIndex | .testCompanion | .benchCompanion | .explicitOnly | .ignored => false

/--
Explicit-only sources enter the content-addressed hash exactly when reachable
from package production through an explicit relative dependency edge.
-/
def includedInPackageHash
    (source : Source)
    (explicitlyReachable : Bool) : Bool :=
  source.automaticallyIncludedInPackageHash ||
    (source.role == .explicitOnly && explicitlyReachable)

end Source

structure Workspace where
  sources : List Source
  deriving DecidableEq, Repr

def Every {Item : Type} (predicate : Item → Prop) : List Item → Prop
  | [] => True
  | item :: rest => predicate item ∧ Every predicate rest

private def decideEvery
    {Item : Type}
    (predicate : Item → Prop)
    [DecidablePred predicate] :
    ∀ items : List Item, Decidable (Every predicate items)
  | [] => isTrue trivial
  | item :: rest =>
      match (inferInstance : Decidable (predicate item)), decideEvery predicate rest with
      | isTrue head, isTrue tail => isTrue ⟨head, tail⟩
      | isFalse head, _ => isFalse fun every => head every.1
      | _, isFalse tail => isFalse fun every => tail every.2

instance {Item : Type} (predicate : Item → Prop) [DecidablePred predicate]
    (items : List Item) : Decidable (Every predicate items) :=
  decideEvery predicate items

def SomeItem {Item : Type} (predicate : Item → Prop) : List Item → Prop
  | [] => False
  | item :: rest => predicate item ∨ SomeItem predicate rest

private def decideSomeItem
    {Item : Type}
    (predicate : Item → Prop)
    [DecidablePred predicate] :
    ∀ items : List Item, Decidable (SomeItem predicate items)
  | [] => isFalse fun impossible => impossible
  | item :: rest =>
      match (inferInstance : Decidable (predicate item)), decideSomeItem predicate rest with
      | isTrue head, _ => isTrue (Or.inl head)
      | _, isTrue tail => isTrue (Or.inr tail)
      | isFalse head, isFalse tail =>
          isFalse fun some => some.elim head tail

instance {Item : Type} (predicate : Item → Prop) [DecidablePred predicate]
    (items : List Item) : Decidable (SomeItem predicate items) :=
  decideSomeItem predicate items

def RegularSource (source : Source) : Prop :=
  source.kind = .regular

def IndexSpelling (source : Source) : Prop :=
  source.role = .contract ∨
    source.role = .legacyContract ∨
    source.role = .legacyIndex

def CompatibleSources (left right : Source) : Prop :=
  ¬(left.directory = right.directory ∧
    IndexSpelling left ∧ IndexSpelling right)

/-- Package validity is checked before resolution and hashing. -/
def Valid (workspace : Workspace) : Prop :=
  Every RegularSource workspace.sources ∧
    (workspace.sources.map Source.fullPath).Nodup ∧
    workspace.sources.Pairwise CompatibleSources

instance (workspace : Workspace) : Decidable (Valid workspace) := by
  unfold Valid RegularSource CompatibleSources IndexSpelling
  infer_instance

/-- `index.vpkg` is the only boundary marker. -/
def Boundary (workspace : Workspace) (directory : Directory) : Prop :=
  SomeItem (fun source =>
    source.kind = .regular ∧
      source.directory = directory ∧
      source.role = .contract) workspace.sources

instance (workspace : Workspace) (directory : Directory) :
    Decidable (Boundary workspace directory) := by
  unfold Boundary
  infer_instance

def SourcePresent (workspace : Workspace) (source : Source) : Prop :=
  source ∈ workspace.sources

instance (workspace : Workspace) (source : Source) :
    Decidable (SourcePresent workspace source) := by
  unfold SourcePresent
  infer_instance

namespace Workspace

def valid (workspace : Workspace) : Bool :=
  decide (Valid workspace)

def isBoundary (workspace : Workspace) (directory : Directory) : Bool :=
  decide (Boundary workspace directory)

private def boundaryDirectories (workspace : Workspace) : List Directory :=
  workspace.sources.filterMap fun source =>
    if source.kind = .regular ∧ source.role = .contract then
      some source.directory
    else
      none

private def chooseDeeperOwner
    (sourceDirectory candidate : Directory)
    (current : Option Directory) : Option Directory :=
  if !candidate.isPrefixOf sourceDirectory then
    current
  else
    match current with
    | none => some candidate
    | some owner =>
        if owner.depth < candidate.depth then some candidate else current

/-- The nearest enclosing index.vpkg owns a source. Nested vpkg starts a new package. -/
def ownerOf (workspace : Workspace) (source : Source) : Option Directory :=
  workspace.boundaryDirectories.foldl
    (fun current candidate =>
      chooseDeeperOwner source.directory candidate current)
    none

def IsImplicitBuildRoot
    (workspace : Workspace)
    (boundary : Directory)
    (source : Source) : Prop :=
  Valid workspace ∧
    Boundary workspace boundary ∧
    SourcePresent workspace source ∧
    source.kind = .regular ∧
    source.directory = boundary ∧
    source.role = .production

instance
    (workspace : Workspace)
    (boundary : Directory)
    (source : Source) :
    Decidable (workspace.IsImplicitBuildRoot boundary source) := by
  unfold IsImplicitBuildRoot
  infer_instance

def isImplicitBuildRoot
    (workspace : Workspace)
    (boundary : Directory)
    (source : Source) : Bool :=
  decide (workspace.IsImplicitBuildRoot boundary source)

def SameOwner (workspace : Workspace) (left right : Source) : Prop :=
  workspace.ownerOf left = workspace.ownerOf right

instance
    (workspace : Workspace)
    (left right : Source) :
    Decidable (workspace.SameOwner left right) := by
  unfold SameOwner
  infer_instance

def SharedImportEligible (source : Source) : Prop :=
  match source.role with
  | .production | .testCompanion | .benchCompanion | .explicitOnly => True
  | .contract | .legacyContract | .legacyIndex | .ignored => False

instance (source : Source) : Decidable (SharedImportEligible source) := by
  unfold SharedImportEligible
  split <;> infer_instance

/--
Direct production siblings inherit directory-shared imports. Explicitly-run
test/bench companions and explicitly-reached private/draft sources inherit from
their nearest enclosing index.vpkg, including when they live below the package
directory. Build/hash membership remains a separate policy, so inheritance does
not make these sources implicit build roots.
-/
def InheritsSharedImports
    (workspace : Workspace)
    (source : Source) : Prop :=
  Valid workspace ∧
    SourcePresent workspace source ∧
    source.kind = .regular ∧
    SharedImportEligible source ∧
    SomeItem (fun boundary =>
      Boundary workspace boundary ∧
        ((source.role = .production ∧ source.directory = boundary) ∨
          ((source.role = .testCompanion ∨
              source.role = .benchCompanion ∨
              source.role = .explicitOnly) ∧
            workspace.ownerOf source = some boundary))) workspace.boundaryDirectories

instance
    (workspace : Workspace)
    (source : Source) :
    Decidable (workspace.InheritsSharedImports source) := by
  unfold InheritsSharedImports
  infer_instance

def inheritsSharedImports
    (workspace : Workspace)
    (source : Source) : Bool :=
  decide (workspace.InheritsSharedImports source)

def TargetVisible
    (workspace : Workspace)
    (importer target : Source) : Prop :=
  match target.role with
  | .contract => Boundary workspace target.directory
  | .legacyContract | .legacyIndex | .production | .explicitOnly => workspace.SameOwner importer target
  | .testCompanion | .benchCompanion | .ignored => False

instance
    (workspace : Workspace)
    (importer target : Source) :
    Decidable (workspace.TargetVisible importer target) := by
  unfold TargetVisible
  split <;> infer_instance

/--
Production and explicitly-run companion files may see implementation files in
their own package. Every other caller must enter a package through index.vpkg.
-/
def AllowedImport
    (workspace : Workspace)
    (importer target : Source) : Prop :=
  Valid workspace ∧
    SourcePresent workspace importer ∧
    SourcePresent workspace target ∧
    importer.kind = .regular ∧
    target.kind = .regular ∧
    workspace.TargetVisible importer target

instance
    (workspace : Workspace)
    (importer target : Source) :
    Decidable (workspace.AllowedImport importer target) := by
  unfold AllowedImport
  infer_instance

def importAllowed
    (workspace : Workspace)
    (importer target : Source) : Bool :=
  decide (workspace.AllowedImport importer target)

end Workspace

end VibeFormal.Module
