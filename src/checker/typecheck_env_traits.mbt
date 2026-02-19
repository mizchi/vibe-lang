///|
pub struct TraitImplDef {
  type_params : Array[String]
  type_bounds : Map[String, Array[String]]
  target : @core.Type
} derive(Show, Eq)

///|
pub struct TraitDefInfo {
  supertraits : Array[String]
  open_impl : Bool
  is_local : Bool
} derive(Show, Eq)

///|
pub fn TypeEnv::has_trait(self : TypeEnv, name : String) -> Bool {
  self.traits.contains(name)
}

///|
pub fn TypeEnv::set_trait(self : TypeEnv, name : String) -> Unit {
  self.set_trait_info(name, TraitDefInfo::{
    supertraits: [],
    open_impl: false,
    is_local: true,
  })
}

///|
pub fn TypeEnv::set_trait_info(
  self : TypeEnv,
  name : String,
  info : TraitDefInfo,
) -> Unit {
  self.traits[name] = info
}

///|
pub fn TypeEnv::get_trait_info(self : TypeEnv, name : String) -> TraitDefInfo? {
  self.traits.get(name)
}

///|
pub fn TypeEnv::trait_is_open(self : TypeEnv, name : String) -> Bool {
  match self.traits.get(name) {
    Some(info) => info.open_impl
    None => false
  }
}

///|
pub fn TypeEnv::trait_is_local(self : TypeEnv, name : String) -> Bool {
  match self.traits.get(name) {
    Some(info) => info.is_local
    None => false
  }
}

///|
pub fn TypeEnv::import_trait(
  self : TypeEnv,
  name : String,
  open_impl : Bool,
  supertraits : Array[String],
) -> Unit {
  self.set_trait_info(name, TraitDefInfo::{
    supertraits,
    open_impl,
    is_local: false,
  })
}

///|
pub fn TypeEnv::trait_supertraits(
  self : TypeEnv,
  name : String,
) -> Array[String] {
  match self.traits.get(name) {
    Some(info) => info.supertraits.copy()
    None => []
  }
}

///|
pub fn TypeEnv::trait_names(self : TypeEnv) -> Array[String] {
  let names : Array[String] = []
  for name, _ in self.traits {
    names.push(name)
  }
  names
}

///|
pub fn TypeEnv::trait_impls_for(
  self : TypeEnv,
  name : String,
) -> Array[TraitImplDef] {
  match self.trait_impls.get(name) {
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
  self.trait_impls[name] = next
}
