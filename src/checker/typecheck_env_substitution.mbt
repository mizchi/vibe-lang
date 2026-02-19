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
        for item in items {
          out.push(resolve_type(env, item))
        }
        @core.Type::Tuple(out)
      }
      @core.Type::Record(fields) => {
        let out : Map[String, @core.Type] = {}
        for name, item in fields {
          out[name] = resolve_type(env, item)
        }
        @core.Type::Record(out)
      }
      @core.Type::Array(inner) => @core.Type::Array(resolve_type(env, inner))
      @core.Type::Map(inner) => @core.Type::Map(resolve_type(env, inner))
      @core.Type::ArrayBuilder(inner) =>
        @core.Type::ArrayBuilder(resolve_type(env, inner))
      @core.Type::MapBuilder(inner) =>
        @core.Type::MapBuilder(resolve_type(env, inner))
      @core.Type::Variant(fields) => {
        let out : Map[String, @core.Type] = {}
        for name, item in fields {
          out[name] = resolve_type(env, item)
        }
        @core.Type::Variant(out)
      }
      @core.Type::Named(name~, args~) => {
        let out : Array[@core.Type] = []
        for arg in args {
          out.push(resolve_type(env, arg))
        }
        @core.Type::Named(name~, args=out)
      }
      @core.Type::Func(params~, ret~, effects~) => {
        let out : Array[@core.FuncParam] = []
        for param in params {
          out.push(@core.FuncParam::{
            name: param.name,
            label: param.label,
            ty: resolve_type(env, param.ty),
            bounds: param.bounds,
          })
        }
        @core.Type::Func(params=out, ret=resolve_type(env, ret), effects~)
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
