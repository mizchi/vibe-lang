// Layer 2 of the 3-layer trait resolution architecture (ADR-0051).
//
// `ImplIndex` indexes trait implementations by trait name and owns the
// canonical write path for impl registration (overlap pre-check + storage).
// Storage still lives on `TypeEnv` so the index acts as a compatibility
// adapter; future work can move the underlying maps onto a dedicated
// `TraitState` without changing this API.

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
  for name, items in self.env.trait_state.trait_impls {
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
  match self.find_overlapping(trait_name, incoming) {
    Some(_) => true
    None => false
  }
}

///|
/// Diagnostic-friendly variant: returns the first existing impl that
/// overlaps with `incoming`, so the caller can report the conflicting
/// target type rather than just the trait name.
pub fn ImplIndex::find_overlapping(
  self : ImplIndex,
  trait_name : String,
  incoming : TraitImplDef,
) -> TraitImplDef? {
  for impl_def in self.env.trait_impls_for(trait_name) {
    if trait_impls_overlap(self.env, impl_def, incoming) {
      return Some(impl_def)
    }
  }
  None
}

///|
/// Idempotent Layer-2 write path for the *import* flow. Used when an impl
/// has already been validated by the upstream type-check (DB / cross-module
/// import) and may be re-encountered through transitive re-exports.
/// De-duplicates by exact equality and skips overlap detection on purpose:
/// the upstream module already proved the impl well-formed, and overlap
/// between import sources is the upstream's invariant, not ours.
pub fn ImplIndex::import_impl(
  self : ImplIndex,
  trait_name : String,
  impl_def : TraitImplDef,
) -> Unit {
  for existing in self.env.trait_impls_for(trait_name) {
    if existing == impl_def {
      return
    }
  }
  self.env.add_trait_impl(trait_name, impl_def)
}

///|
/// Canonical Layer-2 write path. Registers an impl through the index,
/// performing the validations the index is responsible for:
///   - target trait must exist,
///   - target trait must accept impls in the current module,
///   - impl-bound type-param names must be unique,
///   - declared trait bounds must reference known traits,
///   - target type is normalised before storage,
///   - overlap with existing impls is rejected (lenient mode silently drops).
pub fn ImplIndex::register_impl(
  self : ImplIndex,
  type_params : Array[String],
  type_bounds : Map[String, Array[String]],
  trait_name : String,
  target : @core.Type,
  span : @core.Span,
) -> Unit raise TypeError {
  if !self.env.has_trait(trait_name) {
    raise TypeError::BadTypeDef(message="unknown trait: " + trait_name, span~)
  }
  if !self.env.trait_accepts_impl_here(trait_name) {
    raise TypeError::TraitSealed(trait_name~, span~)
  }
  ensure_unique_params(type_params, span)
  let normalized_type_bounds : Map[String, Array[String]] = {}
  for type_param in type_params {
    match type_bounds.get(type_param) {
      Some(bounds) => {
        let deduped = dedup_trait_bounds(bounds)
        ensure_traits_defined(self.env, deduped, span)
        normalized_type_bounds[type_param] = deduped
      }
      None => ()
    }
  }
  let normalized_target = normalize_type(self.env, target)
  let incoming = TraitImplDef::{
    type_params,
    type_bounds: normalized_type_bounds,
    target: normalized_target,
  }
  match self.find_overlapping(trait_name, incoming) {
    Some(existing) =>
      if self.env.session_state.lenient_mode {
        return
      } else {
        raise TypeError::TraitImplOverlap(
          trait_name~,
          existing_target=existing.target,
          incoming_target=incoming.target,
          span~,
        )
      }
    None => ()
  }
  self.env.add_trait_impl(trait_name, incoming)
}
