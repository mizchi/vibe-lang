import VibeFormal.Proofs.ModuleCorrect

set_option autoImplicit false

namespace VibeFormal.Module.Examples

private def workspaceDir : Directory := ⟨["workspace"]⟩
private def packageDir : Directory := ⟨["workspace", "pkg"]⟩
private def subDir : Directory := ⟨["workspace", "pkg", "sub"]⟩
private def nestedDir : Directory := ⟨["workspace", "pkg", "nested"]⟩

private def entry : Source := Source.regular workspaceDir "main.vibe"
private def contract : Source := Source.regular packageDir "index.vpkg"
private def api : Source := Source.regular packageDir "api.vibe"
private def helper : Source := Source.regular subDir "helper.vibe"
private def testCompanion : Source := Source.regular packageDir "api_test.vibe"
private def benchCompanion : Source := Source.regular packageDir "api_bench.vibe"
private def privateScratch : Source := Source.regular packageDir "_scratch.vibe"
private def draft : Source := Source.regular packageDir "experiment.draft.vibe"
private def nestedContract : Source := Source.regular nestedDir "index.vpkg"
private def nestedImpl : Source := Source.regular nestedDir "impl.vibe"
private def legacyIndex : Source := Source.regular workspaceDir "index.vibe"
private def legacyContract : Source := Source.regular workspaceDir "index.vibei"

private def workspace : Workspace :=
  ⟨[entry, contract, api, helper, testCompanion, benchCompanion,
    privateScratch, draft, nestedContract, nestedImpl]⟩

/-- Only index.vpkg introduces a boundary. -/
example : workspace.isBoundary packageDir = true := by native_decide
example : workspace.isBoundary workspaceDir = false := by native_decide
example : legacyIndex.role = .legacyIndex := by native_decide
example : legacyContract.role = .legacyContract := by native_decide

/-- Direct production siblings are roots; subdirectory files need an import edge. -/
example : workspace.isImplicitBuildRoot packageDir api = true := by native_decide
example : workspace.isImplicitBuildRoot packageDir helper = false := by native_decide

/-- Test, bench, private, and draft sources are absent from normal build/hash input. -/
example : testCompanion.role = .testCompanion := by native_decide
example : benchCompanion.role = .benchCompanion := by native_decide
example : privateScratch.role = .explicitOnly := by native_decide
example : draft.role = .explicitOnly := by native_decide
example : testCompanion.includedInPackageHash true = false := by native_decide
example : benchCompanion.includedInPackageHash true = false := by native_decide
example : privateScratch.automaticallyIncludedInPackageHash = false := by native_decide
example : draft.automaticallyIncludedInPackageHash = false := by native_decide
example : privateScratch.includedInPackageHash true = true := by native_decide
example : draft.includedInPackageHash true = true := by native_decide

/-- Companion and explicit-only files inherit imports without becoming roots. -/
example : workspace.inheritsSharedImports testCompanion = true := by native_decide
example : workspace.inheritsSharedImports benchCompanion = true := by native_decide
example : workspace.inheritsSharedImports privateScratch = true := by native_decide
example : workspace.inheritsSharedImports draft = true := by native_decide
example : workspace.inheritsSharedImports helper = false := by native_decide
example : workspace.isImplicitBuildRoot packageDir testCompanion = false := by native_decide
example : workspace.isImplicitBuildRoot packageDir privateScratch = false := by native_decide

/-- External clients enter through index.vpkg and cannot bypass it. -/
example : workspace.importAllowed entry contract = true := by native_decide
example : workspace.importAllowed entry api = false := by native_decide

/-- An explicitly run test is a package companion with private implementation access. -/
example : workspace.importAllowed testCompanion api = true := by native_decide
example : workspace.importAllowed api testCompanion = false := by native_decide
example : workspace.importAllowed api privateScratch = true := by native_decide
example : workspace.importAllowed api draft = true := by native_decide

/-- A nested index.vpkg starts a distinct package boundary. -/
example : workspace.importAllowed api nestedContract = true := by native_decide
example : workspace.importAllowed api nestedImpl = false := by native_decide
example : workspace.importAllowed nestedImpl api = false := by native_decide

/-- index.vpkg plus index.vibe is an invalid package. -/
private def conflicting : Workspace :=
  ⟨[contract, Source.regular packageDir "index.vibe"]⟩

example : conflicting.valid = false := by native_decide

/-- Symlinks are rejected before resolution or hashing. -/
private def linked : Workspace :=
  ⟨[contract, Source.symlink packageDir "api.vibe"]⟩

example : linked.valid = false := by native_decide

end VibeFormal.Module.Examples
