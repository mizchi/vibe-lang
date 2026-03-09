///|
fn generalize(env : TypeEnv, ty : @core.Type) -> TypeScheme raise TypeError {
  let resolved = resolve_type(env, ty)
  let normalized = normalize_type(env, resolved)
  let free_ty = free_vars_in_type(env, normalized)
  let free_effects = free_effect_vars_in_type(env, normalized)
  // Fast path: fully determined type - skip O(n) env scans
  if free_ty.is_empty() && free_effects.is_empty() {
    return TypeScheme::{
      vars: [],
      num_vars: [],
      effect_vars: [],
      trait_bounds: {},
      ty: normalized,
    }
  }
  let vars : Array[Int] = []
  if not(free_ty.is_empty()) {
    let free_env = free_vars_in_env(env)
    for id, _ in free_ty {
      if not(free_env.contains(id)) {
        vars.push(id)
      }
    }
  }
  let num_vars : Array[Int] = []
  for id in vars {
    if env.num_vars.contains(id) {
      num_vars.push(id)
    }
  }
  let effect_vars : Array[String] = []
  if not(free_effects.is_empty()) {
    let free_effect_env = free_effect_vars_in_env(env)
    for name, _ in free_effects {
      if not(free_effect_env.contains(name)) {
        effect_vars.push(name)
      }
    }
  }
  let trait_bounds : Map[Int, Array[String]] = {}
  for id in vars {
    match env.var_trait_bounds.get(id) {
      Some(bounds) => trait_bounds[id] = bounds.copy()
      None => ()
    }
  }
  TypeScheme::{ vars, num_vars, effect_vars, trait_bounds, ty: normalized }
}

///|
fn free_vars_in_env(env : TypeEnv) -> Map[Int, Bool] {
  let out : Map[Int, Bool] = {}
  for _, scheme in env.bindings {
    let vars = free_vars_in_scheme(env, scheme)
    for id, _ in vars {
      out[id] = true
    }
  }
  out
}

///|
fn free_vars_in_scheme(env : TypeEnv, scheme : TypeScheme) -> Map[Int, Bool] {
  let out = free_vars_in_type(env, scheme.ty)
  for id in scheme.vars {
    out.remove(id)
  }
  out
}

///|
fn free_vars_in_type(env : TypeEnv, ty : @core.Type) -> Map[Int, Bool] {
  let out : Map[Int, Bool] = {}
  collect_free_vars(env, ty, out)
  out
}

///|
fn collect_free_vars(
  env : TypeEnv,
  ty : @core.Type,
  out : Map[Int, Bool],
) -> Unit {
  match resolve_type(env, ty) {
    @core.Type::Var(id) => out[id] = true
    @core.Type::Tuple(items) =>
      for item in items {
        collect_free_vars(env, item, out)
      }
    @core.Type::Record(fields) =>
      for _, item in fields {
        collect_free_vars(env, item, out)
      }
    @core.Type::Array(inner) | @core.Type::ArrayBuilder(inner) =>
      collect_free_vars(env, inner, out)
    @core.Type::Map(_key, inner) | @core.Type::MapBuilder(_key, inner) =>
      collect_free_vars(env, inner, out)
    @core.Type::Variant(fields) =>
      for _, item in fields {
        collect_free_vars(env, item, out)
      }
    @core.Type::Named(args~, ..) =>
      for arg in args {
        collect_free_vars(env, arg, out)
      }
    @core.Type::Func(params~, ret~, ..) => {
      for param in params {
        collect_free_vars(env, param.ty, out)
      }
      collect_free_vars(env, ret, out)
    }
    _ => ()
  }
}

///|
fn free_effect_vars_in_env(env : TypeEnv) -> Map[String, Bool] {
  let out : Map[String, Bool] = {}
  for _, scheme in env.bindings {
    let vars = free_effect_vars_in_scheme(env, scheme)
    for name, _ in vars {
      out[name] = true
    }
  }
  out
}

///|
fn free_effect_vars_in_scheme(
  env : TypeEnv,
  scheme : TypeScheme,
) -> Map[String, Bool] {
  let out = free_effect_vars_in_type(env, scheme.ty)
  for name in scheme.effect_vars {
    out.remove(name)
  }
  out
}

///|
fn free_effect_vars_in_type(
  env : TypeEnv,
  ty : @core.Type,
) -> Map[String, Bool] {
  let out : Map[String, Bool] = {}
  collect_free_effect_vars(env, ty, out)
  out
}

///|
fn collect_free_effect_vars(
  env : TypeEnv,
  ty : @core.Type,
  out : Map[String, Bool],
) -> Unit {
  match resolve_type(env, ty) {
    @core.Type::Tuple(items) =>
      for item in items {
        collect_free_effect_vars(env, item, out)
      }
    @core.Type::Record(fields) =>
      for _, item in fields {
        collect_free_effect_vars(env, item, out)
      }
    @core.Type::Array(inner) | @core.Type::ArrayBuilder(inner) =>
      collect_free_effect_vars(env, inner, out)
    @core.Type::Map(_key, inner) | @core.Type::MapBuilder(_key, inner) =>
      collect_free_effect_vars(env, inner, out)
    @core.Type::Variant(fields) =>
      for _, item in fields {
        collect_free_effect_vars(env, item, out)
      }
    @core.Type::Named(args~, ..) =>
      for arg in args {
        collect_free_effect_vars(env, arg, out)
      }
    @core.Type::Func(params~, ret~, effects~) => {
      for param in params {
        collect_free_effect_vars(env, param.ty, out)
      }
      collect_free_effect_vars(env, ret, out)
      collect_free_effect_vars_in_effects(env, effects, out, {})
    }
    _ => ()
  }
}

///|
fn collect_free_effect_vars_in_effects(
  env : TypeEnv,
  effects : Array[@core.EffectAtom],
  out : Map[String, Bool],
  visiting : Map[String, Bool],
) -> Unit {
  for effect in effects {
    match effect {
      @core.EffectAtom::Var(name) =>
        collect_free_effect_var(env, name, out, visiting)
      _ => ()
    }
  }
}

///|
fn collect_free_effect_var(
  env : TypeEnv,
  name : String,
  out : Map[String, Bool],
  visiting : Map[String, Bool],
) -> Unit {
  match env.effect_subs.get(name) {
    Some(bound) => {
      if visiting.contains(name) {
        out[name] = true
        return
      }
      let next_visiting = visiting.copy()
      next_visiting[name] = true
      collect_free_effect_vars_in_effects(env, bound, out, next_visiting)
    }
    None => out[name] = true
  }
}
