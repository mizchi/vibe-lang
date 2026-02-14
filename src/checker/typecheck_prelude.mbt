///|
fn clone_env(env : TypeEnv) -> TypeEnv {
  env.fork_for_check()
}

///|
fn ensure_unique_params(
  params : Array[String],
  span : @core.Span,
) -> Unit raise TypeError {
  let seen : Map[String, Bool] = {}
  for param in params {
    if seen.contains(param) {
      raise TypeError::BadTypeDef(
        message="duplicate type param: " + param,
        span~,
      )
    }
    seen[param] = true
  }
}

///|
fn simple_distance(a : String, b : String) -> Int {
  let a_chars = a.to_array()
  let b_chars = b.to_array()
  let min = if a_chars.length() < b_chars.length() {
    a_chars.length()
  } else {
    b_chars.length()
  }
  let mut diff = if a_chars.length() > b_chars.length() {
    a_chars.length() - b_chars.length()
  } else {
    b_chars.length() - a_chars.length()
  }
  for i in 0..<min {
    if a_chars[i] != b_chars[i] {
      diff += 1
    }
  }
  diff
}

///|
fn best_suggestion(candidates : Array[String], name : String) -> String? {
  let mut best : String? = None
  let mut best_score = 9999
  for cand in candidates {
    let score = simple_distance(name, cand)
    if score < best_score {
      best_score = score
      best = Some(cand)
    }
  }
  if best_score <= 3 {
    best
  } else {
    None
  }
}

///|
fn unknown_span() -> @core.Span {
  @core.Span::empty(0)
}

///|
fn span_key(span : @core.Span) -> String {
  span.start.to_string() + ":" + span.end.to_string()
}

///|
fn find_name_suggestion(
  env : TypeEnv,
  aliases : Map[String, @core.Ref],
  name : String,
) -> String? {
  let candidates : Array[String] = []
  for key, _ in env.bindings {
    candidates.push(key)
  }
  for key, _ in env.ctor_index {
    candidates.push(key)
  }
  for key, _ in aliases {
    candidates.push(key)
  }
  best_suggestion(candidates, name)
}

///|
fn find_type_suggestion(env : TypeEnv, name : String) -> String? {
  let candidates : Array[String] = [
    "Int", "Float", "Double", "Bool", "Char", "String", "@core.Path", "Unit", "Array",
    "Map", "ArrayBuilder", "MapBuilder", "i32", "f32", "f64", "anyref", "eqref",
    "i31ref", "structref", "arrayref", "funcref", "externref",
  ]
  for key, _ in env.enum_defs {
    candidates.push(key)
  }
  for key, _ in env.type_aliases {
    candidates.push(key)
  }
  best_suggestion(candidates, name)
}

///|
fn is_reserved_wasm_type_name(name : String) -> Bool {
  @core.is_wasm_reserved_type_name(name)
}

///|
fn ensure_not_reserved_wasm_type_name(
  name : String,
  span : @core.Span,
) -> Unit raise TypeError {
  if is_reserved_wasm_type_name(name) {
    raise TypeError::BadTypeDef(
      message="reserved wasm type name: " + name,
      span~,
    )
  }
}

///|
pub fn ensure_prelude_option(env : TypeEnv) -> Unit raise TypeError {
  if env.get_enum_def("Option") is Some(_) {
    return
  }
  let span = @core.Span::empty(0)
  let ctors : Array[@core.TypeCtor] = [
    @core.TypeCtor::{ name: "Some", args: [@core.Type::Param("T")], span },
    @core.TypeCtor::{ name: "None", args: [], span },
  ]
  register_enum_def(env, "Option", ["T"], ctors, span)
}

///|
fn ensure_prelude_error_trait(env : TypeEnv) -> Unit raise TypeError {
  let span = @core.Span::empty(0)
  if not(env.has_trait("Error")) {
    register_trait_def(env, "Error", [], true, true, span)
  }
  if not(type_implements_trait(env, @core.Type::String, "Error")) {
    register_trait_impl(env, [], {}, "Error", @core.Type::String, span)
  }
}

///|
pub fn ensure_prelude_functions(
  env : TypeEnv,
  aliases : Map[String, @core.Ref],
) -> Unit raise TypeError {
  ensure_prelude_error_trait(env)
  match env.get_purity("__prelude_loaded") {
    Some(_) => ()
    None => {
      let prelude = prelude_ast()
      let _ = type_check_stmts(
        env,
        prelude.stmts,
        aliases,
        effect_scope_all(),
        false,
        {},
      )
      env.set_purity("__prelude_loaded", true)
    }
  }
}

///|
fn fresh_type_var(env : TypeEnv) -> @core.Type {
  let id = global_next_type_var.val
  global_next_type_var.val += 1
  if env.next_var <= id {
    env.next_var = id + 1
  }
  @core.Type::Var(id)
}

///|
fn mark_num_var(env : TypeEnv, id : Int) -> Unit {
  env.num_vars[id] = true
}

///|
fn is_num_var(env : TypeEnv, id : Int) -> Bool {
  env.num_vars.contains(id)
}

///|
fn fresh_num_var(env : TypeEnv) -> @core.Type {
  let ty = fresh_type_var(env)
  match ty {
    @core.Type::Var(id) => mark_num_var(env, id)
    _ => ()
  }
  ty
}

///|
fn fresh_effect_var(env : TypeEnv) -> String {
  let id = env.next_effect_var
  env.next_effect_var += 1
  "$e" + id.to_string()
}

///|
fn dedup_trait_bounds(bounds : Array[String]) -> Array[String] {
  let seen : Map[String, Bool] = {}
  let out : Array[String] = []
  for bound in bounds {
    if not(seen.contains(bound)) {
      seen[bound] = true
      out.push(bound)
    }
  }
  out
}

///|
fn merge_trait_bounds(
  left : Array[String],
  right : Array[String],
) -> Array[String] {
  let out = left.copy()
  for bound in right {
    out.push(bound)
  }
  dedup_trait_bounds(out)
}

///|
fn declared_param_bounds(
  env : TypeEnv,
  param_ty : @core.Type,
  explicit_bounds : Array[String],
) -> Array[String] {
  let merged = dedup_trait_bounds(explicit_bounds)
  match resolve_type(env, param_ty) {
    @core.Type::Var(id) =>
      match env.var_trait_bounds.get(id) {
        Some(bounds) => merge_trait_bounds(merged, bounds)
        None => merged
      }
    _ => merged
  }
}

///|
fn add_var_trait_bounds(
  env : TypeEnv,
  id : Int,
  bounds : Array[String],
) -> Unit {
  if bounds.is_empty() {
    return
  }
  match env.var_trait_bounds.get(id) {
    Some(existing) =>
      env.var_trait_bounds[id] = merge_trait_bounds(existing, bounds)
    None => env.var_trait_bounds[id] = dedup_trait_bounds(bounds)
  }
}

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

///|
fn instantiate_ctor(env : TypeEnv, info : CtorInfo) -> CtorInstance {
  let mapping : Map[String, @core.Type] = {}
  let args : Array[@core.Type] = []
  for param in info.params {
    let ty_var = fresh_type_var(env)
    mapping[param] = ty_var
    args.push(ty_var)
  }
  let payload = substitute_type(info.payload, mapping)
  let ret = @core.Type::Named(name=info.type_name, args~)
  { payload, ret }
}

///|
fn has_num_type(ty : @core.Type) -> Bool {
  match ty {
    @core.Type::Named(name~, args~) =>
      if name == "Num" && args.is_empty() {
        true
      } else {
        let mut found = false
        for arg in args {
          if has_num_type(arg) {
            found = true
            break
          }
        }
        found
      }
    @core.Type::Tuple(items) => {
      let mut found = false
      for item in items {
        if has_num_type(item) {
          found = true
          break
        }
      }
      found
    }
    @core.Type::Record(fields) => {
      let mut found = false
      for _, item in fields {
        if has_num_type(item) {
          found = true
          break
        }
      }
      found
    }
    @core.Type::Array(inner)
    | @core.Type::Map(inner)
    | @core.Type::ArrayBuilder(inner)
    | @core.Type::MapBuilder(inner) => has_num_type(inner)
    @core.Type::Variant(fields) => {
      let mut found = false
      for _, item in fields {
        if has_num_type(item) {
          found = true
          break
        }
      }
      found
    }
    @core.Type::Func(params~, ret~, ..) => {
      let mut found = false
      for param in params {
        if has_num_type(param.ty) {
          found = true
          break
        }
      }
      if found {
        true
      } else {
        has_num_type(ret)
      }
    }
    _ => false
  }
}

///|
fn replace_num_type(ty : @core.Type, num_var : @core.Type) -> @core.Type {
  match ty {
    @core.Type::Named(name~, args~) =>
      if name == "Num" && args.is_empty() {
        num_var
      } else {
        let out : Array[@core.Type] = []
        for arg in args {
          out.push(replace_num_type(arg, num_var))
        }
        @core.Type::Named(name~, args=out)
      }
    @core.Type::Tuple(items) => {
      let out : Array[@core.Type] = []
      for item in items {
        out.push(replace_num_type(item, num_var))
      }
      @core.Type::Tuple(out)
    }
    @core.Type::Record(fields) => {
      let out : Map[String, @core.Type] = {}
      for name, item in fields {
        out[name] = replace_num_type(item, num_var)
      }
      @core.Type::Record(out)
    }
    @core.Type::Array(inner) =>
      @core.Type::Array(replace_num_type(inner, num_var))
    @core.Type::Map(inner) => @core.Type::Map(replace_num_type(inner, num_var))
    @core.Type::ArrayBuilder(inner) =>
      @core.Type::ArrayBuilder(replace_num_type(inner, num_var))
    @core.Type::MapBuilder(inner) =>
      @core.Type::MapBuilder(replace_num_type(inner, num_var))
    @core.Type::Variant(fields) => {
      let out : Map[String, @core.Type] = {}
      for name, item in fields {
        out[name] = replace_num_type(item, num_var)
      }
      @core.Type::Variant(out)
    }
    @core.Type::Func(params~, ret~, effects~) => {
      let out : Array[@core.FuncParam] = []
      for param in params {
        out.push(@core.FuncParam::{
          name: param.name,
          label: param.label,
          ty: replace_num_type(param.ty, num_var),
          bounds: param.bounds,
        })
      }
      @core.Type::Func(params=out, ret=replace_num_type(ret, num_var), effects~)
    }
    _ => ty
  }
}

///|
/// Substitute type parameters (Type::Param) with their corresponding type variables
fn substitute_type_params(
  ty : @core.Type,
  mapping : Map[String, @core.Type],
) -> @core.Type {
  match ty {
    @core.Type::Param(name) =>
      match mapping.get(name) {
        Some(var_ty) => var_ty
        None => ty // Keep as is if not in mapping
      }
    @core.Type::Named(name~, args~) => {
      let out : Array[@core.Type] = []
      for arg in args {
        out.push(substitute_type_params(arg, mapping))
      }
      @core.Type::Named(name~, args=out)
    }
    @core.Type::Tuple(items) => {
      let out : Array[@core.Type] = []
      for item in items {
        out.push(substitute_type_params(item, mapping))
      }
      @core.Type::Tuple(out)
    }
    @core.Type::Record(fields) => {
      let out : Map[String, @core.Type] = {}
      for name, item in fields {
        out[name] = substitute_type_params(item, mapping)
      }
      @core.Type::Record(out)
    }
    @core.Type::Array(inner) =>
      @core.Type::Array(substitute_type_params(inner, mapping))
    @core.Type::Map(inner) =>
      @core.Type::Map(substitute_type_params(inner, mapping))
    @core.Type::ArrayBuilder(inner) =>
      @core.Type::ArrayBuilder(substitute_type_params(inner, mapping))
    @core.Type::MapBuilder(inner) =>
      @core.Type::MapBuilder(substitute_type_params(inner, mapping))
    @core.Type::Variant(fields) => {
      let out : Map[String, @core.Type] = {}
      for name, item in fields {
        out[name] = substitute_type_params(item, mapping)
      }
      @core.Type::Variant(out)
    }
    @core.Type::Func(params~, ret~, effects~) => {
      let out : Array[@core.FuncParam] = []
      for param in params {
        out.push(@core.FuncParam::{
          name: param.name,
          label: param.label,
          ty: substitute_type_params(param.ty, mapping),
          bounds: param.bounds,
        })
      }
      @core.Type::Func(
        params=out,
        ret=substitute_type_params(ret, mapping),
        effects~,
      )
    }
    _ => ty
  }
}

///|
fn generalize(env : TypeEnv, ty : @core.Type) -> TypeScheme raise TypeError {
  let resolved = resolve_type(env, ty)
  let normalized = normalize_type(env, resolved)
  let free_ty = free_vars_in_type(env, normalized)
  let free_env = free_vars_in_env(env)
  let vars : Array[Int] = []
  for id, _ in free_ty {
    if not(free_env.contains(id)) {
      vars.push(id)
    }
  }
  let num_vars : Array[Int] = []
  for id in vars {
    if env.num_vars.contains(id) {
      num_vars.push(id)
    }
  }
  let free_effects = free_effect_vars_in_type(env, normalized)
  let free_effect_env = free_effect_vars_in_env(env)
  let effect_vars : Array[String] = []
  for name, _ in free_effects {
    if not(free_effect_env.contains(name)) {
      effect_vars.push(name)
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
    @core.Type::Array(inner) => collect_free_vars(env, inner, out)
    @core.Type::Map(inner) => collect_free_vars(env, inner, out)
    @core.Type::ArrayBuilder(inner) => collect_free_vars(env, inner, out)
    @core.Type::MapBuilder(inner) => collect_free_vars(env, inner, out)
    @core.Type::Variant(fields) =>
      for _, item in fields {
        collect_free_vars(env, item, out)
      }
    @core.Type::Named(name=_, args~) =>
      for arg in args {
        collect_free_vars(env, arg, out)
      }
    @core.Type::Func(params~, ret~, effects=_) => {
      collect_free_vars(env, ret, out)
      for param in params {
        collect_free_vars(env, param.ty, out)
      }
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
    @core.Type::Array(inner) => collect_free_effect_vars(env, inner, out)
    @core.Type::Map(inner) => collect_free_effect_vars(env, inner, out)
    @core.Type::ArrayBuilder(inner) => collect_free_effect_vars(env, inner, out)
    @core.Type::MapBuilder(inner) => collect_free_effect_vars(env, inner, out)
    @core.Type::Variant(fields) =>
      for _, item in fields {
        collect_free_effect_vars(env, item, out)
      }
    @core.Type::Named(name=_, args~) =>
      for arg in args {
        collect_free_effect_vars(env, arg, out)
      }
    @core.Type::Func(params~, ret~, effects~) => {
      collect_free_effect_vars(env, ret, out)
      for param in params {
        collect_free_effect_vars(env, param.ty, out)
      }
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
      @core.EffectAtom::Const(_) => ()
      @core.EffectAtom::Var(name) =>
        collect_free_effect_var(env, name, out, visiting)
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
  if visiting.contains(name) {
    out[name] = true
  } else {
    match env.effect_subs.get(name) {
      Some(effects) => {
        let next : Map[String, Bool] = {}
        for key, val in visiting {
          next[key] = val
        }
        next[name] = true
        collect_free_effect_vars_in_effects(env, effects, out, next)
      }
      None => out[name] = true
    }
  }
}
