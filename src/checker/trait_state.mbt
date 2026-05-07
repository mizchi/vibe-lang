// ADR-0051 storage layer. `TraitState` owns the trait-definition and
// trait-impl maps that historically lived on `TypeEnv`. The struct exists
// so the layered API (`TraitGraph`, `ImplIndex`, `ObligationSolver`) has a
// single, focused storage target — `TypeEnv` becomes the compatibility
// adapter promised by the ADR's staged migration plan.
//
// The struct is intentionally `pub(all)` because both the `TraitGraph` /
// `ImplIndex` adapters and the legacy `TypeEnv` shims read/write the
// underlying maps in-place. External packages still go through the
// adapter or env methods, never these fields directly.

///|
pub(all) struct TraitState {
  traits : Map[String, TraitDefInfo]
  trait_impls : Map[String, Array[TraitImplDef]]
} derive(Debug, Eq)

///|
pub fn TraitState::new() -> TraitState {
  TraitState::{ traits: {}, trait_impls: {} }
}

///|
/// Shallow copy used by `TypeEnv::clone` and friends. Preserves the
/// pre-existing semantics of `traits.copy()` + `trait_impls.copy()` — the
/// outer maps are duplicated; the impl-list arrays are shared until
/// `add_trait_impl` clones one for mutation.
pub fn TraitState::copy(self : TraitState) -> TraitState {
  TraitState::{
    traits: self.traits.copy(),
    trait_impls: self.trait_impls.copy(),
  }
}
