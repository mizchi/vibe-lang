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
  let effect_mapping : Map[String, String] = {}
  for name in scheme.effect_vars {
    effect_mapping[name] = fresh_effect_var(env)
  }
  let substituted = substitute_type_vars(scheme.ty, mapping)
  let replaced = substitute_effect_vars(substituted, effect_mapping)
  resolve_type(env, replaced)
}

///|
fn resolve_type(env : TypeEnv, ty : @core.Type) -> @core.Type {
  if env.subs.is_empty() {
    ty
  } else {
    match ty {
      @core.Type::Var(id) =>
        match env.subs.get(id) {
          Some(t) => {
            let resolved = resolve_type(env, t)
            env.subs[id] = resolved
            resolved
          }
          None => ty
        }
      @core.Type::Tuple(items) => {
        let out : Array[@core.Type] = []
        let mut changed = false
        for item in items {
          let resolved_item = resolve_type(env, item)
          if resolved_item != item {
            changed = true
          }
          out.push(resolved_item)
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
          let resolved_item = resolve_type(env, item)
          if resolved_item != item {
            changed = true
          }
          entries.push((name, resolved_item))
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
      @core.Type::Array(inner) => {
        let resolved_inner = resolve_type(env, inner)
        if resolved_inner == inner {
          ty
        } else {
          @core.Type::Array(resolved_inner)
        }
      }
      @core.Type::Map(inner) => {
        let resolved_inner = resolve_type(env, inner)
        if resolved_inner == inner {
          ty
        } else {
          @core.Type::Map(resolved_inner)
        }
      }
      @core.Type::ArrayBuilder(inner) => {
        let resolved_inner = resolve_type(env, inner)
        if resolved_inner == inner {
          ty
        } else {
          @core.Type::ArrayBuilder(resolved_inner)
        }
      }
      @core.Type::MapBuilder(inner) => {
        let resolved_inner = resolve_type(env, inner)
        if resolved_inner == inner {
          ty
        } else {
          @core.Type::MapBuilder(resolved_inner)
        }
      }
      @core.Type::Variant(fields) => {
        let entries : Array[(String, @core.Type)] = []
        let mut changed = false
        for name, item in fields {
          let resolved_item = resolve_type(env, item)
          if resolved_item != item {
            changed = true
          }
          entries.push((name, resolved_item))
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
          let resolved_arg = resolve_type(env, arg)
          if resolved_arg != arg {
            changed = true
          }
          out.push(resolved_arg)
        }
        if changed {
          @core.Type::Named(name~, args=out)
        } else {
          ty
        }
      }
      @core.Type::Func(params~, ret~, effects~) => {
        let resolved_ret = resolve_type(env, ret)
        let mut changed = resolved_ret != ret
        let out : Array[@core.FuncParam] = []
        for param in params {
          let resolved_param_ty = resolve_type(env, param.ty)
          if resolved_param_ty != param.ty {
            changed = true
            out.push(@core.FuncParam::{
              name: param.name,
              label: param.label,
              ty: resolved_param_ty,
              bounds: param.bounds,
            })
          } else {
            out.push(param)
          }
        }
        if changed {
          @core.Type::Func(params=out, ret=resolved_ret, effects~)
        } else {
          ty
        }
      }
      _ => ty
    }
  }
}

///|
fn substitute_type_vars(
  ty : @core.Type,
  subs : Map[Int, @core.Type],
) -> @core.Type {
  match ty {
    @core.Type::Var(id) =>
      match subs.get(id) {
        Some(t) => t
        None => ty
      }
    @core.Type::Tuple(items) => {
      let out : Array[@core.Type] = []
      for item in items {
        out.push(substitute_type_vars(item, subs))
      }
      @core.Type::Tuple(out)
    }
    @core.Type::Record(fields) => {
      let out : Map[String, @core.Type] = {}
      for name, item in fields {
        out[name] = substitute_type_vars(item, subs)
      }
      @core.Type::Record(out)
    }
    @core.Type::Array(inner) =>
      @core.Type::Array(substitute_type_vars(inner, subs))
    @core.Type::Map(inner) => @core.Type::Map(substitute_type_vars(inner, subs))
    @core.Type::ArrayBuilder(inner) =>
      @core.Type::ArrayBuilder(substitute_type_vars(inner, subs))
    @core.Type::MapBuilder(inner) =>
      @core.Type::MapBuilder(substitute_type_vars(inner, subs))
    @core.Type::Variant(fields) => {
      let out : Map[String, @core.Type] = {}
      for name, item in fields {
        out[name] = substitute_type_vars(item, subs)
      }
      @core.Type::Variant(out)
    }
    @core.Type::Named(name~, args~) => {
      let out : Array[@core.Type] = []
      for arg in args {
        out.push(substitute_type_vars(arg, subs))
      }
      @core.Type::Named(name~, args=out)
    }
    @core.Type::Func(params~, ret~, effects~) => {
      let out : Array[@core.FuncParam] = []
      for param in params {
        out.push(@core.FuncParam::{
          name: param.name,
          label: param.label,
          ty: substitute_type_vars(param.ty, subs),
          bounds: param.bounds,
        })
      }
      @core.Type::Func(
        params=out,
        ret=substitute_type_vars(ret, subs),
        effects~,
      )
    }
    _ => ty
  }
}

///|
fn substitute_effect_vars(
  ty : @core.Type,
  subs : Map[String, String],
) -> @core.Type {
  match ty {
    @core.Type::Tuple(items) => {
      let out : Array[@core.Type] = []
      for item in items {
        out.push(substitute_effect_vars(item, subs))
      }
      @core.Type::Tuple(out)
    }
    @core.Type::Record(fields) => {
      let out : Map[String, @core.Type] = {}
      for name, item in fields {
        out[name] = substitute_effect_vars(item, subs)
      }
      @core.Type::Record(out)
    }
    @core.Type::Array(inner) =>
      @core.Type::Array(substitute_effect_vars(inner, subs))
    @core.Type::Map(inner) =>
      @core.Type::Map(substitute_effect_vars(inner, subs))
    @core.Type::ArrayBuilder(inner) =>
      @core.Type::ArrayBuilder(substitute_effect_vars(inner, subs))
    @core.Type::MapBuilder(inner) =>
      @core.Type::MapBuilder(substitute_effect_vars(inner, subs))
    @core.Type::Variant(fields) => {
      let out : Map[String, @core.Type] = {}
      for name, item in fields {
        out[name] = substitute_effect_vars(item, subs)
      }
      @core.Type::Variant(out)
    }
    @core.Type::Named(name~, args~) => {
      let out : Array[@core.Type] = []
      for arg in args {
        out.push(substitute_effect_vars(arg, subs))
      }
      @core.Type::Named(name~, args=out)
    }
    @core.Type::Func(params~, ret~, effects~) => {
      let out : Array[@core.FuncParam] = []
      for param in params {
        out.push(@core.FuncParam::{
          name: param.name,
          label: param.label,
          ty: substitute_effect_vars(param.ty, subs),
          bounds: param.bounds,
        })
      }
      let eff_out : Array[@core.EffectAtom] = []
      for effect in effects {
        match effect {
          @core.EffectAtom::Const(_) => eff_out.push(effect)
          @core.EffectAtom::Var(name) =>
            match subs.get(name) {
              Some(mapped) => eff_out.push(@core.EffectAtom::Var(mapped))
              None => eff_out.push(effect)
            }
        }
      }
      @core.Type::Func(
        params=out,
        ret=substitute_effect_vars(ret, subs),
        effects=eff_out,
      )
    }
    _ => ty
  }
}

///|
fn substitute_type(
  ty : @core.Type,
  subs : Map[String, @core.Type],
) -> @core.Type {
  match ty {
    @core.Type::Param(name) =>
      match subs.get(name) {
        Some(t) => t
        None => ty
      }
    @core.Type::Tuple(items) => {
      let out : Array[@core.Type] = []
      for item in items {
        out.push(substitute_type(item, subs))
      }
      @core.Type::Tuple(out)
    }
    @core.Type::Record(fields) => {
      let out : Map[String, @core.Type] = {}
      for name, item in fields {
        out[name] = substitute_type(item, subs)
      }
      @core.Type::Record(out)
    }
    @core.Type::Array(inner) => @core.Type::Array(substitute_type(inner, subs))
    @core.Type::Map(inner) => @core.Type::Map(substitute_type(inner, subs))
    @core.Type::ArrayBuilder(inner) =>
      @core.Type::ArrayBuilder(substitute_type(inner, subs))
    @core.Type::MapBuilder(inner) =>
      @core.Type::MapBuilder(substitute_type(inner, subs))
    @core.Type::Variant(fields) => {
      let out : Map[String, @core.Type] = {}
      for name, item in fields {
        out[name] = substitute_type(item, subs)
      }
      @core.Type::Variant(out)
    }
    @core.Type::Named(name~, args~) => {
      let out : Array[@core.Type] = []
      for arg in args {
        out.push(substitute_type(arg, subs))
      }
      @core.Type::Named(name~, args=out)
    }
    @core.Type::Func(params~, ret~, effects~) => {
      let out : Array[@core.FuncParam] = []
      for param in params {
        out.push(@core.FuncParam::{
          name: param.name,
          label: param.label,
          ty: substitute_type(param.ty, subs),
          bounds: param.bounds,
        })
      }
      @core.Type::Func(params=out, ret=substitute_type(ret, subs), effects~)
    }
    _ => ty
  }
}
