///|
fn normalize_type(env : TypeEnv, ty : @core.Type) -> @core.Type raise TypeError {
  let resolved = resolve_type(env, ty)
  // Fast path: ground types need no normalization
  match resolved {
    Int
    | Float
    | Double
    | Bool
    | Char
    | String
    | Path
    | PromptText
    | Unit
    | StringBuilder
    | Never
    | Var(_)
    | Param(_) => return resolved
    _ => ()
  }
  let visiting : Map[String, Bool] = {}
  normalize_type_inner(env, resolved, visiting)
}

///|
fn normalize_type_inner(
  env : TypeEnv,
  ty : @core.Type,
  visiting : Map[String, Bool],
) -> @core.Type raise TypeError {
  match ty {
    @core.Type::Named(name~, args~) => {
      let normalized_args : Array[@core.Type] = []
      for arg in args {
        normalized_args.push(normalize_type_inner(env, arg, visiting))
      }
      if name == "Ref" {
        if normalized_args.length() != 1 {
          raise TypeError::BadTypeDef(
            message="type arity: Ref",
            span=unknown_span(),
          )
        }
        return @core.Type::Named(name~, args=normalized_args)
      }
      // Json is a builtin opaque type - preserve as-is (unless user defines their own Json)
      if name == "Json" &&
        normalized_args.length() == 0 &&
        env.get_type_alias(name) is None &&
        env.get_enum_def(name) is None &&
        env.get_struct(name) is None {
        return @core.Type::Named(name~, args=normalized_args)
      }
      if visiting.contains(name) {
        match env.get_enum_def(name) {
          Some(_) => @core.Type::Named(name~, args=normalized_args)
          None =>
            raise TypeError::BadTypeDef(
              message="recursive type: " + name,
              span=unknown_span(),
            )
        }
      } else {
        visiting[name] = true
        let normalized = match env.get_type_alias(name) {
          Some(type_alias) => {
            if type_alias.params.length() != normalized_args.length() {
              raise TypeError::BadTypeDef(
                message="type arity: " + name,
                span=unknown_span(),
              )
            }
            let mapping : Map[String, @core.Type] = {}
            for i in 0..<type_alias.params.length() {
              mapping[type_alias.params[i]] = normalized_args[i]
            }
            let substituted = substitute_type(type_alias.target, mapping)
            normalize_type_inner(env, substituted, visiting)
          }
          None =>
            match env.get_enum_def(name) {
              Some(def) => {
                if def.params.length() != normalized_args.length() {
                  raise TypeError::BadTypeDef(
                    message="type arity: " + name,
                    span=unknown_span(),
                  )
                }
                let mapping : Map[String, @core.Type] = {}
                for i in 0..<def.params.length() {
                  mapping[def.params[i]] = normalized_args[i]
                }
                let ctor_map : Map[String, @core.Type] = {}
                for ctor in def.ctors {
                  let base_payload = if ctor.args.length() == 0 {
                    @core.Type::Unit
                  } else if ctor.args.length() == 1 {
                    ctor.args[0]
                  } else {
                    @core.Type::Tuple(ctor.args)
                  }
                  let substituted = substitute_type(base_payload, mapping)
                  ctor_map[ctor.name] = normalize_type_inner(
                    env, substituted, visiting,
                  )
                }
                @core.Type::Variant(ctor_map)
              }
              None =>
                match env.get_struct(name) {
                  Some(struct_def) => {
                    if struct_def.params.length() != normalized_args.length() {
                      raise TypeError::BadTypeDef(
                        message="type arity: " + name,
                        span=unknown_span(),
                      )
                    }
                    // For struct types, return Named type with normalized args
                    @core.Type::Named(name~, args=normalized_args)
                  }
                  None =>
                    raise TypeError::UnknownType(
                      name~,
                      span=unknown_span(),
                      suggestion=find_type_suggestion(env, name),
                    )
                }
            }
        }
        visiting.remove(name)
        normalized
      }
    }
    @core.Type::Tuple(items) => {
      let out : Array[@core.Type] = []
      for item in items {
        out.push(normalize_type_inner(env, item, visiting))
      }
      @core.Type::Tuple(out)
    }
    @core.Type::Record(fields) => {
      let out : Map[String, @core.Type] = {}
      for name, item in fields {
        out[name] = normalize_type_inner(env, item, visiting)
      }
      @core.Type::Record(out)
    }
    @core.Type::Array(inner) =>
      @core.Type::Array(normalize_type_inner(env, inner, visiting))
    @core.Type::Map(inner) =>
      @core.Type::Map(normalize_type_inner(env, inner, visiting))
    @core.Type::ArrayBuilder(inner) =>
      @core.Type::ArrayBuilder(normalize_type_inner(env, inner, visiting))
    @core.Type::MapBuilder(inner) =>
      @core.Type::MapBuilder(normalize_type_inner(env, inner, visiting))
    @core.Type::Variant(fields) => {
      let out : Map[String, @core.Type] = {}
      for name, item in fields {
        out[name] = normalize_type_inner(env, item, visiting)
      }
      @core.Type::Variant(out)
    }
    @core.Type::Param(_) => ty
    @core.Type::Var(_) => ty
    @core.Type::Func(params~, ret~, effects~) => {
      let out : Array[@core.FuncParam] = []
      for param in params {
        out.push(@core.FuncParam::{
          name: param.name,
          label: param.label,
          ty: normalize_type_inner(env, param.ty, visiting),
          bounds: param.bounds,
        })
      }
      @core.Type::Func(
        params=out,
        ret=normalize_type_inner(env, ret, visiting),
        effects~,
      )
    }
    _ => ty
  }
}

///|
fn type_may_contain_scoped_ref_hint(ty : @core.Type) -> Bool {
  match ty {
    @core.Type::Named(name~, args~) => {
      if name == "Ref" {
        return true
      }
      for arg in args {
        if type_may_contain_scoped_ref_hint(arg) {
          return true
        }
      }
      // User-defined named types/aliases may hide `Ref`.
      true
    }
    @core.Type::Tuple(items) => {
      for item in items {
        if type_may_contain_scoped_ref_hint(item) {
          return true
        }
      }
      false
    }
    @core.Type::Record(fields) => {
      for _, value in fields {
        if type_may_contain_scoped_ref_hint(value) {
          return true
        }
      }
      false
    }
    @core.Type::Array(inner)
    | @core.Type::Map(inner)
    | @core.Type::ArrayBuilder(inner)
    | @core.Type::MapBuilder(inner) => type_may_contain_scoped_ref_hint(inner)
    @core.Type::Variant(ctors) => {
      for _, payload_ty in ctors {
        if type_may_contain_scoped_ref_hint(payload_ty) {
          return true
        }
      }
      false
    }
    @core.Type::Func(params~, ret~, ..) => {
      if type_may_contain_scoped_ref_hint(ret) {
        return true
      }
      for param in params {
        if type_may_contain_scoped_ref_hint(param.ty) {
          return true
        }
      }
      false
    }
    @core.Type::Int
    | @core.Type::Float
    | @core.Type::Double
    | @core.Type::Bool
    | @core.Type::Char
    | @core.Type::String
    | @core.Type::Path
    | @core.Type::PromptText
    | @core.Type::Unit
    | @core.Type::StringBuilder
    | @core.Type::Param(_)
    | @core.Type::Var(_)
    | @core.Type::Never => false
  }
}

///|
fn scoped_ref_cache_key(env : TypeEnv, ty : @core.Type) -> String {
  env.scoped_ref_contains_cache_version.to_string() +
  "#" +
  ty.structural_hash().to_string()
}

///|
fn scoped_ref_cache_lookup(env : TypeEnv, ty : @core.Type) -> Bool? {
  let key = scoped_ref_cache_key(env, ty)
  match env.scoped_ref_contains_cache.get(key) {
    Some(entries) => {
      for entry in entries {
        if entry.ty == ty {
          return Some(entry.has_scoped_ref)
        }
      }
      None
    }
    None => None
  }
}

///|
fn scoped_ref_cache_store(env : TypeEnv, ty : @core.Type, value : Bool) -> Unit {
  let key = scoped_ref_cache_key(env, ty)
  let next = ScopedRefContainsCacheEntry::{ ty, has_scoped_ref: value }
  match env.scoped_ref_contains_cache.get(key) {
    Some(entries) => entries.push(next)
    None => env.scoped_ref_contains_cache[key] = [next]
  }
}

///|
fn type_contains_scoped_ref(
  env : TypeEnv,
  ty : @core.Type,
) -> Bool raise TypeError {
  if not(env.scoped_ref_checks_enabled) {
    return false
  }
  let profile_start = if env.scoped_ref_profile_enabled {
    env.scoped_ref_contains_calls += 1
    Some(@bench.monotonic_clock_start())
  } else {
    None
  }
  let finish = fn(result : Bool) -> Bool {
    match profile_start {
      Some(ts) =>
        env.scoped_ref_contains_time_us += @bench.monotonic_clock_end(ts)
      None => ()
    }
    result
  }
  let resolved = resolve_type(env, ty)
  if not(type_may_contain_scoped_ref_hint(resolved)) {
    return finish(false)
  }
  match scoped_ref_cache_lookup(env, resolved) {
    Some(hit) => {
      if env.scoped_ref_profile_enabled {
        env.scoped_ref_contains_cache_hits += 1
      }
      return finish(hit)
    }
    None =>
      if env.scoped_ref_profile_enabled {
        env.scoped_ref_contains_cache_misses += 1
      }
  }
  let visiting : Map[String, Bool] = {}
  let result = type_contains_scoped_ref_inner(env, resolved, visiting)
  scoped_ref_cache_store(env, resolved, result)
  finish(result)
}

///|
fn type_contains_scoped_ref_inner(
  env : TypeEnv,
  ty : @core.Type,
  visiting : Map[String, Bool],
) -> Bool raise TypeError {
  match resolve_type(env, ty) {
    @core.Type::Named(name~, args~) => {
      if name == "Ref" {
        return true
      }
      for arg in args {
        if type_contains_scoped_ref_inner(env, arg, visiting) {
          return true
        }
      }
      if visiting.contains(name) {
        return false
      }
      visiting[name] = true
      let found = match env.get_type_alias(name) {
        Some(type_alias) =>
          if type_alias.params.length() != args.length() {
            false
          } else {
            let mapping : Map[String, @core.Type] = {}
            for i in 0..<type_alias.params.length() {
              mapping[type_alias.params[i]] = args[i]
            }
            type_contains_scoped_ref_inner(
              env,
              substitute_type(type_alias.target, mapping),
              visiting,
            )
          }
        None =>
          match env.get_struct(name) {
            Some(struct_def) =>
              if struct_def.params.length() != args.length() {
                false
              } else {
                let mapping : Map[String, @core.Type] = {}
                for i in 0..<struct_def.params.length() {
                  mapping[struct_def.params[i]] = args[i]
                }
                let mut hit = false
                for field in struct_def.fields {
                  let field_ty = substitute_type(field.ty, mapping)
                  if type_contains_scoped_ref_inner(env, field_ty, visiting) {
                    hit = true
                    break
                  }
                }
                hit
              }
            None =>
              match env.get_enum_def(name) {
                Some(enum_def) =>
                  if enum_def.params.length() != args.length() {
                    false
                  } else {
                    let mapping : Map[String, @core.Type] = {}
                    for i in 0..<enum_def.params.length() {
                      mapping[enum_def.params[i]] = args[i]
                    }
                    let mut hit = false
                    for ctor in enum_def.ctors {
                      for arg_ty in ctor.args {
                        let payload_ty = substitute_type(arg_ty, mapping)
                        if type_contains_scoped_ref_inner(
                            env, payload_ty, visiting,
                          ) {
                          hit = true
                          break
                        }
                      }
                      if hit {
                        break
                      }
                    }
                    hit
                  }
                None => false
              }
          }
      }
      visiting.remove(name)
      found
    }
    @core.Type::Tuple(items) => {
      for item in items {
        if type_contains_scoped_ref_inner(env, item, visiting) {
          return true
        }
      }
      false
    }
    @core.Type::Record(fields) => {
      for _, value in fields {
        if type_contains_scoped_ref_inner(env, value, visiting) {
          return true
        }
      }
      false
    }
    @core.Type::Array(inner)
    | @core.Type::Map(inner)
    | @core.Type::ArrayBuilder(inner)
    | @core.Type::MapBuilder(inner) =>
      type_contains_scoped_ref_inner(env, inner, visiting)
    @core.Type::Variant(ctors) => {
      for _, payload_ty in ctors {
        if type_contains_scoped_ref_inner(env, payload_ty, visiting) {
          return true
        }
      }
      false
    }
    @core.Type::Func(params~, ret~, ..) => {
      if type_contains_scoped_ref_inner(env, ret, visiting) {
        return true
      }
      for param in params {
        if type_contains_scoped_ref_inner(env, param.ty, visiting) {
          return true
        }
      }
      false
    }
    @core.Type::Int
    | @core.Type::Float
    | @core.Type::Double
    | @core.Type::Bool
    | @core.Type::Char
    | @core.Type::String
    | @core.Type::Path
    | @core.Type::PromptText
    | @core.Type::Unit
    | @core.Type::StringBuilder
    | @core.Type::Param(_)
    | @core.Type::Var(_)
    | @core.Type::Never => false
  }
}

///|
fn ensure_no_scoped_ref_return_escape(
  env : TypeEnv,
  ret_ty : @core.Type,
  span : @core.Span,
) -> Unit raise TypeError {
  if not(env.scoped_ref_checks_enabled) {
    return
  }
  let profile_start = if env.scoped_ref_profile_enabled {
    env.scoped_ref_return_checks += 1
    Some(@bench.monotonic_clock_start())
  } else {
    None
  }
  let finish = fn() {
    match profile_start {
      Some(ts) =>
        env.scoped_ref_return_time_us += @bench.monotonic_clock_end(ts)
      None => ()
    }
  }
  if type_contains_scoped_ref(env, ret_ty) {
    finish()
    raise TypeError::ScopedRefEscape(context="function return", span~)
  }
  finish()
}

///|
fn ensure_no_toplevel_scoped_ref_escape(
  env : TypeEnv,
  ty : @core.Type,
  span : @core.Span,
) -> Unit raise TypeError {
  if not(env.scoped_ref_checks_enabled) {
    return
  }
  let profile_start = if env.scoped_ref_profile_enabled {
    env.scoped_ref_toplevel_checks += 1
    Some(@bench.monotonic_clock_start())
  } else {
    None
  }
  let finish = fn() {
    match profile_start {
      Some(ts) =>
        env.scoped_ref_toplevel_time_us += @bench.monotonic_clock_end(ts)
      None => ()
    }
  }
  let resolved = resolve_type(env, ty)
  match resolved {
    @core.Type::Func(ret~, ..) =>
      if type_contains_scoped_ref(env, ret) {
        finish()
        raise TypeError::ScopedRefEscape(
          context="top-level function return",
          span~,
        )
      }
    _ =>
      if type_contains_scoped_ref(env, resolved) {
        finish()
        raise TypeError::ScopedRefEscape(context="top-level binding", span~)
      }
  }
  finish()
}

///|
fn type_equal(
  env : TypeEnv,
  a : @core.Type,
  b : @core.Type,
) -> Bool raise TypeError {
  unify_types(env, a, b)
}

///|
pub enum ApiVersionBump {
  Patch
  Minor
  Major
} derive(Show, Eq)

///|
fn semver_init() -> ApiSemver {
  ApiSemver::{ major: 1, minor: 0, patch: 0 }
}

///|
fn semver_apply(version : ApiSemver, bump : ApiVersionBump) -> ApiSemver {
  match bump {
    ApiVersionBump::Patch =>
      ApiSemver::{
        major: version.major,
        minor: version.minor,
        patch: version.patch + 1,
      }
    ApiVersionBump::Minor =>
      ApiSemver::{ major: version.major, minor: version.minor + 1, patch: 0 }
    ApiVersionBump::Major =>
      ApiSemver::{ major: version.major + 1, minor: 0, patch: 0 }
  }
}

///|
fn effect_atom_key(effect : @core.EffectAtom) -> String {
  match effect {
    @core.EffectAtom::Const(name) => "C:" + name
    @core.EffectAtom::Var(name) => "V:" + name
  }
}

///|
fn effects_subset(
  small : Array[@core.EffectAtom],
  large : Array[@core.EffectAtom],
) -> Bool {
  let large_keys : Map[String, Bool] = {}
  for effect in large {
    large_keys[effect_atom_key(effect)] = true
  }
  for effect in small {
    if not(large_keys.contains(effect_atom_key(effect))) {
      return false
    }
  }
  true
}

///|
fn trait_bounds_subset(
  env : TypeEnv,
  small : Array[String],
  large : Array[String],
) -> Bool {
  let required = dedup_trait_bounds(small)
  let available = dedup_trait_bounds(large)
  for bound in required {
    if not(trait_bound_satisfied(env, available, bound)) {
      return false
    }
  }
  true
}

///|
fn try_type_equal(env : TypeEnv, left : @core.Type, right : @core.Type) -> Bool {
  let result : Result[Bool, TypeError] = try? type_equal(env, left, right)
  match result {
    Ok(v) => v
    Err(_) => false
  }
}

///|
pub fn is_type_subtype(
  env : TypeEnv,
  sub : @core.Type,
  sup : @core.Type,
) -> Bool {
  let left = resolve_type(env, sub)
  let right = resolve_type(env, sup)
  if try_type_equal(env, left, right) {
    return true
  }
  match (left, right) {
    (_, @core.Type::Named(name=trait_name, args=[])) if env.has_trait(
        trait_name,
      ) => type_implements_trait(env, left, trait_name)
    (@core.Type::Tuple(sub_items), @core.Type::Tuple(sup_items)) =>
      if sub_items.length() != sup_items.length() {
        false
      } else {
        let mut ok = true
        for i in 0..<sub_items.length() {
          if not(is_type_subtype(env, sub_items[i], sup_items[i])) {
            ok = false
            break
          }
        }
        ok
      }
    (@core.Type::Record(sub_fields), @core.Type::Record(sup_fields)) => {
      let mut ok = true
      for name, sup_ty in sup_fields {
        match sub_fields.get(name) {
          Some(sub_ty) =>
            if not(is_type_subtype(env, sub_ty, sup_ty)) {
              ok = false
              break
            }
          None => {
            ok = false
            break
          }
        }
      }
      ok
    }
    (@core.Type::Array(sub_inner), @core.Type::Array(sup_inner)) =>
      is_type_subtype(env, sub_inner, sup_inner)
    (@core.Type::Map(sub_inner), @core.Type::Map(sup_inner)) =>
      is_type_subtype(env, sub_inner, sup_inner)
    (@core.Type::ArrayBuilder(sub_inner), @core.Type::ArrayBuilder(sup_inner)) =>
      is_type_subtype(env, sub_inner, sup_inner)
    (@core.Type::MapBuilder(sub_inner), @core.Type::MapBuilder(sup_inner)) =>
      is_type_subtype(env, sub_inner, sup_inner)
    (
      @core.Type::Func(params=sub_params, ret=sub_ret, effects=sub_effects),
      @core.Type::Func(params=sup_params, ret=sup_ret, effects=sup_effects),
    ) =>
      if sub_params.length() != sup_params.length() {
        false
      } else if not(effects_subset(sub_effects, sup_effects)) {
        false
      } else {
        let mut ok = true
        for i in 0..<sub_params.length() {
          let sub_param = sub_params[i]
          let sup_param = sup_params[i]
          if sub_param.label != sup_param.label {
            ok = false
            break
          }
          if not(@core.ParamLabel::is_positional(sub_param.label)) &&
            sub_param.name != sup_param.name {
            ok = false
            break
          }
          if not(trait_bounds_subset(env, sub_param.bounds, sup_param.bounds)) {
            ok = false
            break
          }
          // Function parameter types are contravariant:
          // new <: old requires old_param <: new_param
          if not(is_type_subtype(env, sup_param.ty, sub_param.ty)) {
            ok = false
            break
          }
        }
        ok && is_type_subtype(env, sub_ret, sup_ret)
      }
    _ => false
  }
}

///|
pub fn classify_function_api_change(
  env : TypeEnv,
  old_ty : @core.Type,
  new_ty : @core.Type,
) -> ApiVersionBump {
  let check_minor_env = clone_env(env)
  if is_type_subtype(check_minor_env, new_ty, old_ty) {
    let check_patch_env = clone_env(env)
    if is_type_subtype(check_patch_env, old_ty, new_ty) {
      ApiVersionBump::Patch
    } else {
      ApiVersionBump::Minor
    }
  } else {
    ApiVersionBump::Major
  }
}

///|
/// Completion helper: true if param type can accept receiver type.
pub fn completion_param_matches(
  env : TypeEnv,
  receiver : @core.Type,
  param : @core.Type,
) -> Bool {
  let recv = normalize_type(env, receiver) catch { _ => receiver }
  let param_ty = normalize_type(env, param) catch { _ => param }
  match param_ty {
    @core.Type::Var(_) | @core.Type::Param(_) => true
    _ =>
      match recv {
        @core.Type::Var(_) | @core.Type::Param(_) => true
        _ => type_equal(env, recv, param_ty) catch { _ => false }
      }
  }
}

///|
fn unify_types(
  env : TypeEnv,
  a : @core.Type,
  b : @core.Type,
) -> Bool raise TypeError {
  let left = resolve_type(env, a)
  let right = resolve_type(env, b)
  match (left, right) {
    (@core.Type::Never, _) => true
    (_, @core.Type::Never) => true
    (@core.Type::Named(name=an, args=aa), @core.Type::Named(name=bn, args=bb)) =>
      if an == bn {
        if aa.length() != bb.length() {
          false
        } else {
          let mut ok = true
          for i in 0..<aa.length() {
            if not(unify_types(env, aa[i], bb[i])) {
              ok = false
              break
            }
          }
          ok
        }
      } else {
        let nl = normalize_type(env, left)
        let nr = normalize_type(env, right)
        unify_types(env, nl, nr)
      }
    (@core.Type::Var(id), t) => bind_var(env, id, t)
    (t, @core.Type::Var(id)) => bind_var(env, id, t)
    (@core.Type::Param(a0), @core.Type::Param(b0)) => a0 == b0
    (@core.Type::Param(_), _) => false
    (_, @core.Type::Param(_)) => false
    (@core.Type::Named(..), _) => {
      let nl = normalize_type(env, left)
      unify_types(env, nl, right)
    }
    (_, @core.Type::Named(..)) => {
      let nr = normalize_type(env, right)
      unify_types(env, left, nr)
    }
    (@core.Type::Int, @core.Type::Int) => true
    (@core.Type::Float, @core.Type::Float) => true
    (@core.Type::Double, @core.Type::Double) => true
    (@core.Type::Bool, @core.Type::Bool) => true
    (@core.Type::Char, @core.Type::Char) => true
    (@core.Type::String, @core.Type::String) => true
    (@core.Type::Path, @core.Type::Path) => true
    (@core.Type::PromptText, @core.Type::PromptText) => true
    (@core.Type::String, @core.Type::PromptText) => true
    (@core.Type::Unit, @core.Type::Unit) => true
    (@core.Type::Tuple(xs), @core.Type::Tuple(ys)) =>
      if xs.length() != ys.length() {
        false
      } else {
        let mut ok = true
        for i in 0..<xs.length() {
          if not(unify_types(env, xs[i], ys[i])) {
            ok = false
            break
          }
        }
        ok
      }
    (@core.Type::Record(ax), @core.Type::Record(bx)) =>
      if ax.length() != bx.length() {
        false
      } else {
        let mut ok = true
        for name, ty in ax {
          match bx.get(name) {
            Some(other) =>
              if not(unify_types(env, ty, other)) {
                ok = false
                break
              }
            None => {
              ok = false
              break
            }
          }
        }
        ok
      }
    (@core.Type::Array(ae), @core.Type::Array(be)) => unify_types(env, ae, be)
    (@core.Type::Map(av), @core.Type::Map(bv)) => unify_types(env, av, bv)
    (@core.Type::ArrayBuilder(ae), @core.Type::ArrayBuilder(be)) =>
      unify_types(env, ae, be)
    (@core.Type::MapBuilder(av), @core.Type::MapBuilder(bv)) =>
      unify_types(env, av, bv)
    (@core.Type::StringBuilder, @core.Type::StringBuilder) => true
    (@core.Type::Variant(ax), @core.Type::Variant(bx)) =>
      if ax.length() != bx.length() {
        false
      } else {
        let mut ok = true
        for name, ty in ax {
          match bx.get(name) {
            Some(other) =>
              if not(unify_types(env, ty, other)) {
                ok = false
                break
              }
            None => {
              ok = false
              break
            }
          }
        }
        ok
      }
    (
      @core.Type::Func(params=pa, ret=ra, effects=ea),
      @core.Type::Func(params=pb, ret=rb, effects=eb),
    ) =>
      if pa.length() != pb.length() {
        false
      } else if not(unify_effects(env, ea, eb)) {
        false
      } else if not(unify_types(env, ra, rb)) {
        false
      } else {
        let mut ok = true
        for i in 0..<pa.length() {
          if not(param_unify(env, pa[i], pb[i])) {
            ok = false
            break
          }
        }
        ok
      }
    _ => false
  }
}

///|
fn param_unify(
  env : TypeEnv,
  a : @core.FuncParam,
  b : @core.FuncParam,
) -> Bool raise TypeError {
  if a.label != b.label {
    return false
  }
  if not(@core.ParamLabel::is_positional(a.label)) && a.name != b.name {
    return false
  }
  if not(
      trait_bounds_subset(env, a.bounds, b.bounds) &&
      trait_bounds_subset(env, b.bounds, a.bounds),
    ) {
    return false
  }
  unify_types(env, a.ty, b.ty)
}

///|
fn bind_var(env : TypeEnv, id : Int, ty : @core.Type) -> Bool {
  let resolved = resolve_type(env, ty)
  let required_bounds = match env.var_trait_bounds.get(id) {
    Some(bounds) => bounds
    None => []
  }
  if is_num_var(env, id) {
    match resolved {
      @core.Type::Var(other) =>
        if other == id {
          true
        } else if occurs_in(env, id, resolved) {
          false
        } else {
          mark_num_var(env, other)
          add_var_trait_bounds(env, other, required_bounds)
          env.subs[id] = resolved
          true
        }
      @core.Type::Int | @core.Type::Float | @core.Type::Double => {
        for bound in required_bounds {
          if not(type_implements_trait(env, resolved, bound)) {
            return false
          }
        }
        env.subs[id] = resolved
        true
      }
      _ => false
    }
  } else {
    match resolved {
      @core.Type::Var(other) =>
        if other == id {
          true
        } else if occurs_in(env, id, resolved) {
          false
        } else {
          add_var_trait_bounds(env, other, required_bounds)
          env.subs[id] = resolved
          true
        }
      _ =>
        if occurs_in(env, id, resolved) {
          false
        } else {
          for bound in required_bounds {
            if not(type_implements_trait(env, resolved, bound)) {
              return false
            }
          }
          env.subs[id] = resolved
          true
        }
    }
  }
}

///|
fn occurs_in(env : TypeEnv, id : Int, ty : @core.Type) -> Bool {
  match resolve_type(env, ty) {
    @core.Type::Var(other) => other == id
    @core.Type::Tuple(items) => {
      let mut found = false
      for item in items {
        if occurs_in(env, id, item) {
          found = true
          break
        }
      }
      found
    }
    @core.Type::Record(fields) => {
      let mut found = false
      for _, item in fields {
        if occurs_in(env, id, item) {
          found = true
          break
        }
      }
      found
    }
    @core.Type::Array(inner) => occurs_in(env, id, inner)
    @core.Type::Map(inner) => occurs_in(env, id, inner)
    @core.Type::Variant(fields) => {
      let mut found = false
      for _, item in fields {
        if occurs_in(env, id, item) {
          found = true
          break
        }
      }
      found
    }
    @core.Type::Named(name=_, args~) => {
      let mut found = false
      for arg in args {
        if occurs_in(env, id, arg) {
          found = true
          break
        }
      }
      found
    }
    @core.Type::Func(params~, ret~, effects=_) => {
      let mut found = occurs_in(env, id, ret)
      if not(found) {
        for param in params {
          if occurs_in(env, id, param.ty) {
            found = true
            break
          }
        }
      }
      found
    }
    _ => false
  }
}

///|
fn has_alias_prefix(name : String, aliases : Map[String, @core.Ref]) -> Bool {
  let chars : Array[Char] = []
  for c in name {
    chars.push(c)
  }
  let mut dot = -1
  for i in 0..<chars.length() {
    if chars[i] == '.' {
      dot = i
      break
    }
  }
  if dot == -1 {
    return false
  }
  let buf = StringBuilder::new()
  for i in 0..<dot {
    buf.write_char(chars[i])
  }
  let prefix = buf.to_string()
  aliases.contains(prefix)
}
