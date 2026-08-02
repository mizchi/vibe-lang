import VibeFormal.Compiler.Incremental

set_option autoImplicit false

namespace VibeFormal.Compiler

universe u v

variable {ModuleId : Type u}
variable {Fingerprint : Type v}

/-- Every module in an interface change's reverse closure is invalidated. -/
theorem reverse_interface_closure_is_invalidated
    {before after : IncrementalSnapshot ModuleId Fingerprint}
    {changed moduleId : ModuleId}
    (interfaceChanged : InterfaceChanged before after changed)
    (reachable : ReverseClosure before after changed moduleId) :
    TypingInvalidated before after moduleId := by
  exact Or.inl ⟨changed, interfaceChanged, reachable⟩

/-- Every changed local cache-key assumption is covered by invalidation. -/
theorem typing_assumption_change_is_invalidated
    {before after : IncrementalSnapshot ModuleId Fingerprint}
    {moduleId : ModuleId}
    (changed : TypingAssumptionChanged before after moduleId) :
    TypingInvalidated before after moduleId := by
  rcases changed with planChanged | ownerOrDependency
  · exact Or.inr (Or.inr planChanged)
  · rcases ownerOrDependency with ownerChanged | dependencyChanged
    · exact reverse_interface_closure_is_invalidated ownerChanged
        ReverseClosure.owner
    · obtain ⟨dependency, edge, interfaceChanged⟩ := dependencyChanged
      exact reverse_interface_closure_is_invalidated interfaceChanged
        (ReverseClosure.consumer ReverseClosure.owner edge)

/--
Cache-key eligibility is preserved when the owner dependency plan and every
recorded interface identity are unchanged. This transports fingerprint
assumptions only; compiler typing soundness is a separate obligation.
-/
theorem typing_cache_assumptions_preserved
    {before after : IncrementalSnapshot ModuleId Fingerprint}
    {entry : TypingCacheEntry ModuleId Fingerprint}
    (sameDependencies :
      before.dependencies entry.owner = after.dependencies entry.owner)
    (ownerInterfaceUnchanged :
      before.interfaceIdentity entry.owner = after.interfaceIdentity entry.owner)
    (dependencyInterfacesUnchanged : ∀ dependency,
      dependency ∈ before.dependencies entry.owner →
        before.interfaceIdentity dependency = after.interfaceIdentity dependency)
    (matchedBefore : TypingCacheAssumptionsMatch before entry) :
    TypingCacheAssumptionsMatch after entry := by
  constructor
  · exact matchedBefore.1.trans ownerInterfaceUnchanged
  · constructor
    · exact matchedBefore.2.1.trans sameDependencies
    · intro dependency recorded
      have directBefore : dependency ∈ before.dependencies entry.owner := by
        rw [← matchedBefore.2.1]
        exact recorded
      exact matchedBefore.2.2 dependency recorded |>.trans
        (dependencyInterfacesUnchanged dependency directBefore)

namespace IncrementalExamples

inductive DemoModule where
  | base
  | library
  | app
  deriving DecidableEq, Repr

def dependencies : DemoModule → List DemoModule
  | .base => []
  | .library => [.base]
  | .app => [.library]

def initialInterface : DemoModule → Nat
  | .base => 1
  | .library => 10
  | .app => 20

def initialImplementation : DemoModule → Nat
  | .base => 101
  | .library => 110
  | .app => 120

def before : IncrementalSnapshot DemoModule Nat where
  interfaceIdentity := initialInterface
  implementationIdentity := initialImplementation
  dependencies := dependencies

def noOp : IncrementalSnapshot DemoModule Nat := before

def privateBodyEdit : IncrementalSnapshot DemoModule Nat where
  interfaceIdentity := initialInterface
  implementationIdentity
    | .base => 101
    | .library => 111
    | .app => 120
  dependencies := dependencies

def publicInterfaceEdit : IncrementalSnapshot DemoModule Nat where
  interfaceIdentity
    | .base => 1
    | .library => 11
    | .app => 20
  implementationIdentity
    | .base => 101
    | .library => 111
    | .app => 120
  dependencies := dependencies

def transitiveBaseInterfaceEdit : IncrementalSnapshot DemoModule Nat where
  interfaceIdentity
    | .base => 2
    | .library => 10
    | .app => 20
  implementationIdentity
    | .base => 102
    | .library => 110
    | .app => 120
  dependencies := dependencies

def appAddsBaseImport : IncrementalSnapshot DemoModule Nat where
  interfaceIdentity := initialInterface
  implementationIdentity
    | .base => 101
    | .library => 110
    | .app => 121
  dependencies
    | .base => []
    | .library => [.base]
    | .app => [.library, .base]

def appTypingEntry : TypingCacheEntry DemoModule Nat where
  owner := .app
  ownerInterface := 20
  ownerDependencies := [.library]
  dependencyInterfaces := initialInterface

def linkedArtifact : ArtifactCacheEntry DemoModule Nat where
  recordedImplementations := fun moduleId => some (initialImplementation moduleId)

/-- Exact semantic no-op invalidates neither typing nor the linked artifact. -/
example : ¬ TypingInvalidated before noOp .app := by
  simp [TypingInvalidated, InterfaceInvalidated, InterfaceChanged,
    ImplementationOnlyChanged, DependencyPlanChanged, noOp]

example : ArtifactFresh noOp linkedArtifact := by
  intro moduleId fingerprint recorded
  simp [linkedArtifact] at recorded
  simpa [noOp, before] using recorded

/-- A private implementation edit invalidates only its owner for typing. -/
example : TypingInvalidated before privateBodyEdit .library := by
  apply Or.inr
  apply Or.inl
  simp [ImplementationOnlyChanged, before, privateBodyEdit,
    initialImplementation, initialInterface]

example : ¬ TypingInvalidated before privateBodyEdit .app := by
  simp [TypingInvalidated, InterfaceInvalidated, InterfaceChanged,
    ImplementationOnlyChanged, DependencyPlanChanged, before, privateBodyEdit,
    initialImplementation, initialInterface]

/-- Consumer cache assumptions still match, although the linked artifact is stale. -/
example : TypingCacheAssumptionsMatch privateBodyEdit appTypingEntry := by
  apply typing_cache_assumptions_preserved
  · rfl
  · rfl
  · intro dependency direct
    rfl
  · constructor
    · rfl
    · constructor
      · rfl
      · intro dependency direct
        rfl

example : ¬ ArtifactFresh privateBodyEdit linkedArtifact := by
  intro fresh
  have libraryFresh := fresh .library 110 (by simp [linkedArtifact,
    initialImplementation])
  simp [privateBodyEdit] at libraryFresh

/-- A public interface edit invalidates its direct consumer. -/
example : TypingInvalidated before publicInterfaceEdit .app := by
  apply typing_assumption_change_is_invalidated
  apply Or.inr
  apply Or.inr
  refine ⟨.library, ?_, ?_⟩
  · exact Or.inl (by simp [before, dependencies])
  · simp [InterfaceChanged, before, publicInterfaceEdit, initialInterface]

/-- An interface change reaches consumers through the complete reverse closure. -/
example : TypingInvalidated before transitiveBaseInterfaceEdit .app := by
  apply reverse_interface_closure_is_invalidated (changed := .base)
  · simp [InterfaceChanged, before, transitiveBaseInterfaceEdit, initialInterface]
  · have libraryReach : ReverseClosure before transitiveBaseInterfaceEdit .base .library :=
      ReverseClosure.consumer ReverseClosure.owner
        (Or.inl (by simp [before, dependencies]))
    exact ReverseClosure.consumer libraryReach
      (Or.inl (by simp [before, dependencies]))

/-- An added import invalidates the owner even when public identities are stable. -/
example : TypingInvalidated before appAddsBaseImport .app := by
  apply Or.inr
  apply Or.inr
  simp [DependencyPlanChanged, before, appAddsBaseImport, dependencies]

end IncrementalExamples
end VibeFormal.Compiler
