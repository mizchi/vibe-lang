///|
pub struct TypeScheme {
  vars : Array[Int]
  num_vars : Array[Int]
  effect_vars : Array[String]
  trait_bounds : Map[Int, Array[String]]
  ty : @core.Type
} derive(Show, Eq)

///|
pub struct ApiSemver {
  major : Int
  minor : Int
  patch : Int
} derive(Show, Eq)

///|
pub fn TypeEnv::get(self : TypeEnv, name : String) -> @core.Type? {
  match self.bindings.get(name) {
    Some(scheme) => Some(instantiate_scheme(self, scheme))
    None => None
  }
}

///|
pub fn TypeEnv::get_scheme(self : TypeEnv, name : String) -> TypeScheme? {
  self.bindings.get(name)
}

///|
pub fn TypeEnv::get_purity(self : TypeEnv, name : String) -> Bool? {
  self.purities.get(name)
}

///|
pub fn TypeEnv::get_addr_type(self : TypeEnv, addr : String) -> @core.Type? {
  self.addr_types.get(addr)
}

///|
pub fn TypeEnv::get_expr_type(self : TypeEnv, span : @core.Span) -> @core.Type? {
  self.expr_types.get(span_key(span))
}

///|
pub fn TypeEnv::set(self : TypeEnv, name : String, ty : @core.Type) -> Unit {
  self.set_scheme(name, TypeScheme::{
    vars: [],
    num_vars: [],
    effect_vars: [],
    trait_bounds: {},
    ty,
  })
}

///|
pub fn TypeEnv::set_scheme(
  self : TypeEnv,
  name : String,
  scheme : TypeScheme,
) -> Unit {
  self.bindings[name] = scheme
}

///|
pub fn TypeEnv::set_exported_scheme(
  self : TypeEnv,
  name : String,
  scheme : TypeScheme,
) -> Unit {
  let next_ty = resolve_type(self, scheme.ty)
  match self.bindings.get(name) {
    Some(prev_scheme) => {
      let prev_ty = resolve_type(self, prev_scheme.ty)
      match (prev_ty, next_ty) {
        (@core.Type::Func(..), @core.Type::Func(..)) =>
          match self.fn_versions.get(name) {
            Some(current) => {
              let bump = if prev_ty == next_ty {
                ApiVersionBump::Patch
              } else {
                classify_function_api_change(self, prev_ty, next_ty)
              }
              self.fn_versions[name] = semver_apply(current, bump)
            }
            None => self.fn_versions[name] = semver_init()
          }
        (@core.Type::Func(..), _) =>
          match self.fn_versions.get(name) {
            Some(current) =>
              self.fn_versions[name] = semver_apply(
                current,
                ApiVersionBump::Major,
              )
            None => self.fn_versions[name] = semver_init()
          }
        (_, @core.Type::Func(..)) => self.fn_versions[name] = semver_init()
        _ => ()
      }
    }
    None =>
      match next_ty {
        @core.Type::Func(..) => self.fn_versions[name] = semver_init()
        _ => ()
      }
  }
  self.bindings[name] = scheme
}

///|
pub fn TypeEnv::set_purity(self : TypeEnv, name : String, pure : Bool) -> Unit {
  self.purities[name] = pure
}

///|
pub fn TypeEnv::get_fn_version(self : TypeEnv, name : String) -> ApiSemver? {
  self.fn_versions.get(name)
}

///|
pub fn TypeEnv::set_addr_type(
  self : TypeEnv,
  addr : String,
  ty : @core.Type,
) -> Unit {
  self.addr_types[addr] = ty
}
