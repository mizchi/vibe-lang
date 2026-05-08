///|
pub enum TraitOrigin {
  DefinedHere
  Imported
  PreludeSeed
} derive(Debug, Eq)

///|
pub struct TraitImplDef {
  type_params : Array[String]
  type_bounds : Map[String, Array[String]]
  target : @core.Type
} derive(Debug, Eq)

///|
pub struct TraitDefInfo {
  supertraits : Array[String]
  open_impl : Bool
  origin : TraitOrigin
} derive(Debug, Eq)

///|
pub fn TraitDefInfo::defined_here(
  supertraits : Array[String],
  open_impl : Bool,
) -> TraitDefInfo {
  { supertraits, open_impl, origin: TraitOrigin::DefinedHere }
}

///|
pub fn TraitDefInfo::imported(
  supertraits : Array[String],
  open_impl : Bool,
) -> TraitDefInfo {
  { supertraits, open_impl, origin: TraitOrigin::Imported }
}

///|
pub fn TraitDefInfo::prelude_seeded() -> TraitDefInfo {
  { supertraits: [], open_impl: false, origin: TraitOrigin::PreludeSeed }
}

///|
pub fn TraitDefInfo::is_defined_here(self : TraitDefInfo) -> Bool {
  self.origin == TraitOrigin::DefinedHere
}

///|
pub fn TraitDefInfo::allows_impl_here(self : TraitDefInfo) -> Bool {
  match self.origin {
    TraitOrigin::Imported => self.open_impl
    TraitOrigin::DefinedHere | TraitOrigin::PreludeSeed => true
  }
}

///|
pub fn TraitDefInfo::to_imported(
  self : TraitDefInfo,
  supertraits : Array[String],
) -> TraitDefInfo {
  TraitDefInfo::imported(supertraits, self.open_impl)
}

///|
pub fn TraitDefInfo::supertraits_copy(self : TraitDefInfo) -> Array[String] {
  self.supertraits.copy()
}

///|
pub fn TypeEnv::has_trait(self : TypeEnv, name : String) -> Bool {
  self.trait_state.traits.contains(name)
}

///|
pub fn TypeEnv::set_trait(self : TypeEnv, name : String) -> Unit {
  self.set_trait_info(name, TraitDefInfo::defined_here([], false))
}

///|
pub fn TypeEnv::set_trait_info(
  self : TypeEnv,
  name : String,
  info : TraitDefInfo,
) -> Unit {
  self.trait_state.traits[name] = info
}

///|
pub fn TypeEnv::get_trait_info(self : TypeEnv, name : String) -> TraitDefInfo? {
  self.trait_state.traits.get(name)
}

///|
pub fn TypeEnv::import_trait(
  self : TypeEnv,
  name : String,
  source_info : TraitDefInfo,
  supertraits : Array[String],
) -> Unit {
  self.set_trait_info(name, source_info.to_imported(supertraits))
}

///|
pub fn TypeEnv::trait_accepts_impl_here(self : TypeEnv, name : String) -> Bool {
  match self.trait_state.traits.get(name) {
    Some(info) => info.allows_impl_here()
    None => false
  }
}

///|
pub fn TypeEnv::trait_names(self : TypeEnv) -> Array[String] {
  let names : Array[String] = []
  for name, _ in self.trait_state.traits {
    names.push(name)
  }
  names
}

///|
pub fn TypeEnv::trait_impls_for(
  self : TypeEnv,
  name : String,
) -> Array[TraitImplDef] {
  match self.trait_state.trait_impls.get(name) {
    Some(items) => items
    None => []
  }
}

///|
pub fn TypeEnv::add_trait_impl(
  self : TypeEnv,
  name : String,
  impl_def : TraitImplDef,
) -> Unit {
  let items = self.trait_impls_for(name)
  let next = items.copy()
  next.push(impl_def)
  self.trait_state.trait_impls[name] = next
}
