// Layer 2 of the 3-layer trait resolution architecture (ADR-0051).
//
// `ImplIndex` indexes trait implementations by trait name and provides the
// overlap pre-check used at impl-registration time. Like `TraitGraph`, it is
// a read-only adapter over `env.trait_impls` so that the read path can be
// migrated independently of the storage layout.

///|
pub struct ImplIndex {
  env : TypeEnv
}

///|
pub fn ImplIndex::of(env : TypeEnv) -> ImplIndex {
  ImplIndex::{ env, }
}

///|
/// Direct impls registered for `trait_name`.
pub fn ImplIndex::impls_for(
  self : ImplIndex,
  trait_name : String,
) -> Array[TraitImplDef] {
  self.env.trait_impls_for(trait_name)
}

///|
/// Names of traits with at least one registered impl. Used by the obligation
/// solver to skip trait names that cannot contribute to the search.
pub fn ImplIndex::traits_with_impls(self : ImplIndex) -> Array[String] {
  let names : Array[String] = []
  for name, items in self.env.trait_impls {
    if items.length() > 0 {
      names.push(name)
    }
  }
  names
}

///|
/// True if `incoming` would overlap with any existing impl of `trait_name`.
/// This is the pre-check used by `register_trait_impl`; it preserves the
/// existing behaviour (target-shape filter + unifier-based confirmation).
pub fn ImplIndex::would_overlap(
  self : ImplIndex,
  trait_name : String,
  incoming : TraitImplDef,
) -> Bool {
  for impl_def in self.env.trait_impls_for(trait_name) {
    if trait_impls_overlap(self.env, impl_def, incoming) {
      return true
    }
  }
  false
}
