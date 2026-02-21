///|
fn fresh_type_var(env : TypeEnv) -> @core.Type {
  let id = env.session_state.type_var_counter
  env.session_state.type_var_counter += 1
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
