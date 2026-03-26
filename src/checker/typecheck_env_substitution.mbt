///|
fn instantiate_scheme(env : TypeEnv, scheme : TypeScheme) -> @core.Type {
  if scheme.vars.is_empty() && scheme.effect_vars.is_empty() {
    return resolve_type(env, scheme.ty)
  }
  let mapping : Map[Int, @core.Type] = {}
  for id in scheme.vars {
    if scheme.num_vars.contains(id) {
      mapping[id] = fresh_num_var(env)
    } else {
      mapping[id] = fresh_type_var(env)
    }
  }
  if not(scheme.trait_bounds.is_empty()) {
    for id in scheme.vars {
      match mapping.get(id) {
        Some(@core.Type::Var(new_id)) =>
          match scheme.trait_bounds.get(id) {
            Some(bounds) => add_var_trait_bounds(env, new_id, bounds)
            None => ()
          }
        _ => ()
      }
    }
  }
  let substituted = substitute_type_vars(scheme.ty, mapping)
  let replaced = if scheme.effect_vars.is_empty() {
    substituted
  } else {
    let effect_mapping : Map[String, String] = {}
    for name in scheme.effect_vars {
      effect_mapping[name] = fresh_effect_var(env)
    }
    substitute_effect_vars(substituted, effect_mapping)
  }
  resolve_type(env, replaced)
}

///|
/// Check if any node in a type tree satisfies the predicate.
/// O(type_size), no allocations.
fn type_tree_any(ty : @core.Type, pred : (@core.Type) -> Bool) -> Bool {
  if pred(ty) {
    return true
  }
  match ty {
    @core.Type::Tuple(items) => {
      for item in items {
        if type_tree_any(item, pred) {
          return true
        }
      }
      false
    }
    @core.Type::Record(fields) | @core.Type::Variant(fields) => {
      for _, item in fields {
        if type_tree_any(item, pred) {
          return true
        }
      }
      false
    }
    @core.Type::Array(inner)
    | @core.Type::ArrayBuilder(inner)
    | @core.Type::Set(inner) => type_tree_any(inner, pred)
    @core.Type::Map(key, inner) | @core.Type::MapBuilder(key, inner) =>
      type_tree_any(key, pred) || type_tree_any(inner, pred)
    @core.Type::Named(args~, ..) => {
      for arg in args {
        if type_tree_any(arg, pred) {
          return true
        }
      }
      false
    }
    @core.Type::Func(params~, ret~, ..) => {
      if type_tree_any(ret, pred) {
        return true
      }
      for param in params {
        if type_tree_any(param.ty, pred) {
          return true
        }
      }
      false
    }
    _ => false
  }
}

///|
/// Check if a type contains any Var nodes whose IDs are keys in the subs map.
fn type_has_var_in_map(ty : @core.Type, subs : Map[Int, @core.Type]) -> Bool {
  type_tree_any(ty, fn(t) {
    match t {
      @core.Type::Var(id) => subs.contains(id)
      _ => false
    }
  })
}

///|
/// Check if a type contains any Func nodes with effect Var atoms in the subs map.
fn type_has_effect_var_in_map(
  ty : @core.Type,
  subs : Map[String, String],
) -> Bool {
  type_tree_any(ty, fn(t) {
    match t {
      @core.Type::Func(effects~, ..) => {
        for effect in effects {
          match effect {
            @core.EffectAtom::Var(name) =>
              if subs.contains(name) {
                return true
              }
            _ => ()
          }
        }
        false
      }
      _ => false
    }
  })
}

///|
/// Check if a type contains any Param nodes whose names are in the subs map.
fn type_has_param_in_map(
  ty : @core.Type,
  subs : Map[String, @core.Type],
) -> Bool {
  type_tree_any(ty, fn(t) {
    match t {
      @core.Type::Param(name) => subs.contains(name)
      _ => false
    }
  })
}

///|
/// Generic structural transform for compound type nodes.
/// Handles Tuple, Record, Array, Map, ArrayBuilder, MapBuilder, Variant, Named, Func.
/// Leaf types and special cases should be handled by the caller before calling this.
fn transform_type_structure(
  ty : @core.Type,
  walk : (@core.Type) -> @core.Type,
  has_target : (@core.Type) -> Bool,
) -> @core.Type {
  match ty {
    @core.Type::Tuple(items) => {
      let out : Array[@core.Type] = []
      let mut changed = false
      for item in items {
        if not(changed) && not(has_target(item)) {
          out.push(item)
        } else {
          out.push(walk(item))
          changed = true
        }
      }
      if changed {
        @core.Type::Tuple(out)
      } else {
        ty
      }
    }
    @core.Type::Record(fields) => {
      let entries : Array[(String, @core.Type)] = []
      let mut changed = false
      for name, item in fields {
        if has_target(item) {
          entries.push((name, walk(item)))
          changed = true
        } else {
          entries.push((name, item))
        }
      }
      if changed {
        let out : Map[String, @core.Type] = {}
        for entry in entries {
          let (name, value) = entry
          out[name] = value
        }
        @core.Type::Record(out)
      } else {
        ty
      }
    }
    @core.Type::Array(inner) =>
      if has_target(inner) {
        @core.Type::Array(walk(inner))
      } else {
        ty
      }
    @core.Type::Set(inner) =>
      if has_target(inner) {
        @core.Type::Set(walk(inner))
      } else {
        ty
      }
    @core.Type::Map(key, inner) => {
      let key_has = has_target(key)
      let inner_has = has_target(inner)
      if key_has || inner_has {
        @core.Type::Map(
          if key_has {
            walk(key)
          } else {
            key
          },
          if inner_has {
            walk(inner)
          } else {
            inner
          },
        )
      } else {
        ty
      }
    }
    @core.Type::ArrayBuilder(inner) =>
      if has_target(inner) {
        @core.Type::ArrayBuilder(walk(inner))
      } else {
        ty
      }
    @core.Type::MapBuilder(key, inner) => {
      let key_has = has_target(key)
      let inner_has = has_target(inner)
      if key_has || inner_has {
        @core.Type::MapBuilder(
          if key_has {
            walk(key)
          } else {
            key
          },
          if inner_has {
            walk(inner)
          } else {
            inner
          },
        )
      } else {
        ty
      }
    }
    @core.Type::Variant(fields) => {
      let entries : Array[(String, @core.Type)] = []
      let mut changed = false
      for name, item in fields {
        if has_target(item) {
          entries.push((name, walk(item)))
          changed = true
        } else {
          entries.push((name, item))
        }
      }
      if changed {
        let out : Map[String, @core.Type] = {}
        for entry in entries {
          let (name, value) = entry
          out[name] = value
        }
        @core.Type::Variant(out)
      } else {
        ty
      }
    }
    @core.Type::Named(name~, args~) => {
      let out : Array[@core.Type] = []
      let mut changed = false
      for arg in args {
        if not(changed) && not(has_target(arg)) {
          out.push(arg)
        } else {
          out.push(walk(arg))
          changed = true
        }
      }
      if changed {
        @core.Type::Named(name~, args=out)
      } else {
        ty
      }
    }
    @core.Type::Func(params~, ret~, effects~) => {
      let ret_has = has_target(ret)
      let new_ret = if ret_has { walk(ret) } else { ret }
      let mut changed = ret_has
      let out : Array[@core.FuncParam] = []
      for param in params {
        if has_target(param.ty) {
          changed = true
          out.push(@core.FuncParam::{
            name: param.name,
            label: param.label,
            ty: walk(param.ty),
            bounds: param.bounds,
          })
        } else {
          out.push(param)
        }
      }
      if changed {
        @core.Type::Func(params=out, ret=new_ret, effects~)
      } else {
        ty
      }
    }
    _ => ty
  }
}

///|
/// Check if a type contains any Var nodes that have substitutions in env.subs.
fn type_has_substitutable_var(env : TypeEnv, ty : @core.Type) -> Bool {
  type_has_var_in_map(ty, env.subs)
}

///|
fn resolve_type(env : TypeEnv, ty : @core.Type) -> @core.Type {
  if env.subs.is_empty() {
    return ty
  }
  if not(type_has_substitutable_var(env, ty)) {
    return ty
  }
  resolve_type_walk(env, ty)
}

///|
fn resolve_type_walk(env : TypeEnv, ty : @core.Type) -> @core.Type {
  match ty {
    @core.Type::Var(id) =>
      match env.subs.get(id) {
        Some(t) => {
          let resolved = resolve_type_walk(env, t)
          env.subs[id] = resolved
          resolved
        }
        None => ty
      }
    _ =>
      transform_type_structure(ty, fn(t) { resolve_type_walk(env, t) }, fn(t) {
        type_has_substitutable_var(env, t)
      })
  }
}

///|
fn substitute_type_vars(
  ty : @core.Type,
  subs : Map[Int, @core.Type],
) -> @core.Type {
  if subs.is_empty() || not(type_has_var_in_map(ty, subs)) {
    return ty
  }
  substitute_type_vars_walk(ty, subs)
}

///|
fn substitute_type_vars_walk(
  ty : @core.Type,
  subs : Map[Int, @core.Type],
) -> @core.Type {
  match ty {
    @core.Type::Var(id) =>
      match subs.get(id) {
        Some(t) => t
        None => ty
      }
    _ =>
      transform_type_structure(
        ty,
        fn(t) { substitute_type_vars_walk(t, subs) },
        fn(t) { type_has_var_in_map(t, subs) },
      )
  }
}

///|
fn substitute_effect_vars(
  ty : @core.Type,
  subs : Map[String, String],
) -> @core.Type {
  if subs.is_empty() || not(type_has_effect_var_in_map(ty, subs)) {
    return ty
  }
  substitute_effect_vars_walk(ty, subs)
}

///|
fn substitute_effect_vars_walk(
  ty : @core.Type,
  subs : Map[String, String],
) -> @core.Type {
  match ty {
    @core.Type::Func(params~, ret~, effects~) => {
      let ret_has = type_has_effect_var_in_map(ret, subs)
      let new_ret = if ret_has {
        substitute_effect_vars_walk(ret, subs)
      } else {
        ret
      }
      let mut changed = ret_has
      let out : Array[@core.FuncParam] = []
      for param in params {
        if type_has_effect_var_in_map(param.ty, subs) {
          changed = true
          out.push(@core.FuncParam::{
            name: param.name,
            label: param.label,
            ty: substitute_effect_vars_walk(param.ty, subs),
            bounds: param.bounds,
          })
        } else {
          out.push(param)
        }
      }
      let eff_out : Array[@core.EffectAtom] = []
      let mut eff_changed = false
      for effect in effects {
        match effect {
          @core.EffectAtom::Const(_) => eff_out.push(effect)
          @core.EffectAtom::Var(name) =>
            match subs.get(name) {
              Some(mapped) => {
                eff_out.push(@core.EffectAtom::Var(mapped))
                eff_changed = true
              }
              None => eff_out.push(effect)
            }
        }
      }
      if changed || eff_changed {
        @core.Type::Func(
          params=out,
          ret=new_ret,
          effects=if eff_changed { eff_out } else { effects },
        )
      } else {
        ty
      }
    }
    _ =>
      transform_type_structure(
        ty,
        fn(t) { substitute_effect_vars_walk(t, subs) },
        fn(t) { type_has_effect_var_in_map(t, subs) },
      )
  }
}

///|
fn substitute_type(
  ty : @core.Type,
  subs : Map[String, @core.Type],
) -> @core.Type {
  if subs.is_empty() || not(type_has_param_in_map(ty, subs)) {
    return ty
  }
  substitute_type_walk(ty, subs)
}

///|
fn substitute_type_walk(
  ty : @core.Type,
  subs : Map[String, @core.Type],
) -> @core.Type {
  match ty {
    @core.Type::Param(name) =>
      match subs.get(name) {
        Some(t) => t
        None => ty
      }
    _ =>
      transform_type_structure(ty, fn(t) { substitute_type_walk(t, subs) }, fn(
        t,
      ) {
        type_has_param_in_map(t, subs)
      })
  }
}
