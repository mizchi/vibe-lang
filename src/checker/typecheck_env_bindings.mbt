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
pub fn TypeEnv::get_purity_tier(
  self : TypeEnv,
  name : String,
) -> TopLevelPurityTier? {
  self.purity_tiers.get(name)
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
pub fn TypeEnv::set_scoped_ref_checks_enabled(
  self : TypeEnv,
  enabled : Bool,
) -> Unit {
  self.scoped_ref_checks_enabled = enabled
  if enabled {
    self.has_scoped_ref_binding = false
    self.scoped_ref_binding_scan_stale = true
  } else {
    self.has_scoped_ref_binding = false
    self.scoped_ref_binding_scan_stale = false
  }
}

///|
pub fn TypeEnv::is_scoped_ref_checks_enabled(self : TypeEnv) -> Bool {
  self.scoped_ref_checks_enabled
}

///|
pub fn TypeEnv::set_scoped_ref_profile_enabled(
  self : TypeEnv,
  enabled : Bool,
) -> Unit {
  self.scoped_ref_profile_enabled = enabled
  if enabled {
    self.reset_scoped_ref_profile()
  }
}

///|
pub fn TypeEnv::reset_scoped_ref_profile(self : TypeEnv) -> Unit {
  self.scoped_ref_contains_calls = 0
  self.scoped_ref_contains_cache_hits = 0
  self.scoped_ref_contains_cache_misses = 0
  self.scoped_ref_contains_time_us = 0.0
  self.scoped_ref_capture_checks = 0
  self.scoped_ref_capture_time_us = 0.0
  self.scoped_ref_call_arg_checks = 0
  self.scoped_ref_call_arg_time_us = 0.0
  self.scoped_ref_return_checks = 0
  self.scoped_ref_return_time_us = 0.0
  self.scoped_ref_toplevel_checks = 0
  self.scoped_ref_toplevel_time_us = 0.0
}

///|
pub fn TypeEnv::get_scoped_ref_profile(self : TypeEnv) -> ScopedRefProfile {
  ScopedRefProfile::{
    contains_calls: self.scoped_ref_contains_calls,
    contains_cache_hits: self.scoped_ref_contains_cache_hits,
    contains_cache_misses: self.scoped_ref_contains_cache_misses,
    contains_time_us: self.scoped_ref_contains_time_us,
    capture_checks: self.scoped_ref_capture_checks,
    capture_time_us: self.scoped_ref_capture_time_us,
    call_arg_checks: self.scoped_ref_call_arg_checks,
    call_arg_time_us: self.scoped_ref_call_arg_time_us,
    return_checks: self.scoped_ref_return_checks,
    return_time_us: self.scoped_ref_return_time_us,
    toplevel_checks: self.scoped_ref_toplevel_checks,
    toplevel_time_us: self.scoped_ref_toplevel_time_us,
  }
}

///|
pub fn TypeEnv::invalidate_scoped_ref_contains_cache(self : TypeEnv) -> Unit {
  self.scoped_ref_contains_cache = {}
  self.scoped_ref_contains_cache_version += 1
}

///|
pub fn TypeEnv::invalidate_normalize_type_cache(self : TypeEnv) -> Unit {
  self.normalize_type_cache_expand = {}
  self.normalize_type_cache_preserve = {}
  self.normalize_type_cache_subs_version = self.subs_version
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
fn update_scoped_ref_binding_flag(
  env : TypeEnv,
  name : String,
  scheme : TypeScheme,
) -> Unit {
  if not(env.scoped_ref_checks_enabled) {
    return
  }
  if env.has_scoped_ref_binding {
    return
  }
  if @core.is_builtin_name(name) ||
    @core.is_logic_builtin_name(name) ||
    @core.has_qualified_name(name) {
    return
  }
  if not(type_may_contain_scoped_ref_hint(scheme.ty)) {
    return
  }
  env.scoped_ref_binding_scan_stale = true
}

///|
fn refresh_scoped_ref_binding_flag(env : TypeEnv) -> Unit {
  if not(env.scoped_ref_checks_enabled) {
    env.has_scoped_ref_binding = false
    env.scoped_ref_binding_scan_stale = false
    return
  }
  if env.has_scoped_ref_binding || not(env.scoped_ref_binding_scan_stale) {
    return
  }
  let mut found = false
  for name, scheme in env.bindings.iter2() {
    if @core.is_builtin_name(name) ||
      @core.is_logic_builtin_name(name) ||
      @core.has_qualified_name(name) {
      continue
    }
    let has_scoped_ref = type_contains_scoped_ref(env, scheme.ty) catch {
      _ => true
    }
    if has_scoped_ref {
      found = true
      break
    }
  }
  env.has_scoped_ref_binding = found
  env.scoped_ref_binding_scan_stale = false
}

///|
pub fn TypeEnv::has_scoped_ref_binding_for_capture(self : TypeEnv) -> Bool {
  if not(self.scoped_ref_checks_enabled) {
    return false
  }
  refresh_scoped_ref_binding_flag(self)
  self.has_scoped_ref_binding
}

///|
pub fn TypeEnv::set_scheme(
  self : TypeEnv,
  name : String,
  scheme : TypeScheme,
) -> Unit {
  update_scoped_ref_binding_flag(self, name, scheme)
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
  update_scoped_ref_binding_flag(self, name, scheme)
  self.bindings[name] = scheme
}

///|
pub fn TypeEnv::set_purity(self : TypeEnv, name : String, pure : Bool) -> Unit {
  self.purities[name] = pure
  self.purity_tiers[name] = if pure {
    TopLevelPurityTier::Pure
  } else {
    TopLevelPurityTier::Impure
  }
}

///|
pub fn TypeEnv::set_purity_tier(
  self : TypeEnv,
  name : String,
  tier : TopLevelPurityTier,
) -> Unit {
  self.purity_tiers[name] = tier
  self.purities[name] = tier == TopLevelPurityTier::Pure
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
