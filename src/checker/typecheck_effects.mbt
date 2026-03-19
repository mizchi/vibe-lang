///|
priv struct EffectSet {
  consts : Map[String, Bool]
  rest : String?
}

///|
priv struct EffectScope {
  allow_all : Bool
  allowed : Map[String, Bool]
  rest : String?
}

///|
fn effect_scope_all() -> EffectScope {
  EffectScope::{ allow_all: true, allowed: {}, rest: None }
}

///|
fn effect_scope_from_list(effects : Array[@core.EffectAtom]) -> EffectScope {
  let allowed : Map[String, Bool] = {}
  let mut rest : String? = None
  for effect in effects {
    match effect {
      @core.EffectAtom::Const(name) => {
        allowed[name] = true
        // Net is a super-effect that includes Http, Socket
        if name == "Net" {
          allowed["Http"] = true
          allowed["Socket"] = true
        }
      }
      @core.EffectAtom::Var(name) =>
        match rest {
          Some(existing) => if existing != name { () }
          None => rest = Some(name)
        }
    }
  }
  EffectScope::{ allow_all: false, allowed, rest }
}

///|
fn normalize_effects(
  effects : Array[@core.EffectAtom],
  span : @core.Span,
) -> Array[@core.EffectAtom] raise TypeError {
  let out : Array[@core.EffectAtom] = []
  let seen : Map[String, Bool] = {}
  let mut seen_var : String? = None
  for effect in effects {
    match effect {
      @core.EffectAtom::Const(name) =>
        if not(seen.contains(name)) {
          seen[name] = true
          out.push(effect)
        }
      @core.EffectAtom::Var(name) =>
        match seen_var {
          Some(existing) =>
            if existing != name {
              raise TypeError::BadTypeDef(message="multiple effect vars", span~)
            } else {
              ()
            }
          None => {
            seen_var = Some(name)
            out.push(effect)
          }
        }
    }
  }
  out
}

///|
fn require_effects(
  env : TypeEnv,
  scope : EffectScope,
  effects : Array[@core.EffectAtom],
  operation : String,
  span : @core.Span,
) -> Unit raise TypeError {
  match find_missing_effect(env, scope, effects) {
    Some(name) =>
      raise TypeError::EffectGuardNotSatisfied(
        operation~,
        missing_effect=Some(name),
        span~,
      )
    None => ()
  }
}

///|
fn find_missing_effect(
  env : TypeEnv,
  scope : EffectScope,
  effects : Array[@core.EffectAtom],
) -> String? raise TypeError {
  if scope.allow_all {
    return None
  }
  let scope_set = effect_set_from_scope(scope)
  let required_set = effect_set_from_atoms(env, effects)
  ensure_effects_allowed(env, scope_set, required_set)
}

///|
fn require_effect_guard(
  env : TypeEnv,
  scope : EffectScope,
  _allow_effect : Bool,
  operation : String,
  required_effects : Array[@core.EffectAtom],
  span : @core.Span,
) -> Unit raise TypeError {
  let missing_effect = find_missing_effect(env, scope, required_effects)
  match missing_effect {
    Some(_) =>
      raise TypeError::EffectGuardNotSatisfied(
        operation~,
        missing_effect~,
        span~,
      )
    None => ()
  }
}

///|
fn builtin_effects(name : String) -> Array[@core.EffectAtom] {
  match name {
    "sh" => [@core.EffectAtom::Const("Process")]
    "sh_lines" => [@core.EffectAtom::Const("Process")]
    "Stdout::write_char" => [@core.EffectAtom::Const("Stdout")]
    "Stdout::write_stream" => [@core.EffectAtom::Const("Stdout")]
    "Stdin::read_char" => [@core.EffectAtom::Const("Stdin")]
    "Stdin::read_stream" => [@core.EffectAtom::Const("Stdin")]
    "sleep" => [@core.EffectAtom::Const("Async")]
    "Threads::probe_wat"
    | "Threads::runtime_hints"
    | "Threads::channel_new"
    | "Threads::send"
    | "Threads::recv"
    | "Threads::spawn"
    | "Threads::wait" => [@core.EffectAtom::Const("Threads")]
    "Path::resolve" => [@core.EffectAtom::Const("Env")]
    "Fs::read_file"
    | "Fs::write_file"
    | "Fs::exists"
    | "Fs::stat_token"
    | "Fs::readdir"
    | "Fs::is_dir"
    | "Fs::mkdir"
    | "Fs::mkdir_p"
    | "Fs::getcwd"
    | "Fs::chdir"
    | "Fs::remove"
    | "Fs::is_file"
    | "Fs::copy"
    | "Fs::rename"
    | "Fs::append" => [@core.EffectAtom::Const("Fs")]
    "Env::get" | "Env::args_len" | "Env::args_get" =>
      [@core.EffectAtom::Const("Env")]
    "Socket::tcp_connect"
    | "Socket::tcp_read"
    | "Socket::tcp_write"
    | "Socket::tcp_close" => [@core.EffectAtom::Const("Net")]
    "Http::request"
    | "Http::response_status"
    | "Http::response_header"
    | "Http::response_body"
    | "Http::close"
    | "Http::listen"
    | "Http::accept"
    | "Http::request_method"
    | "Http::request_url"
    | "Http::request_header"
    | "Http::request_body"
    | "Http::respond" => [@core.EffectAtom::Const("Net")]
    "Llm::complete" | "Rlm::run" => [@core.EffectAtom::Const("Llm")]
    _ => []
  }
}

///|
fn compatible_effect_aliases(required_effect : String) -> Array[String] {
  match required_effect {
    // Temporary compatibility for legacy scripts: Process replaced Stdout for sh/sh_lines.
    "Process" => ["Stdout"]
    _ => []
  }
}

///|
fn effect_const_satisfied(
  scope_consts : Map[String, Bool],
  required_effect : String,
) -> Bool {
  if scope_consts.contains(required_effect) {
    true
  } else {
    let compatible = compatible_effect_aliases(required_effect)
    let mut ok = false
    for legacy_name in compatible {
      if scope_consts.contains(legacy_name) {
        ok = true
      }
    }
    ok
  }
}

///|
fn effect_scope_extend(
  scope : EffectScope,
  extra : Array[@core.EffectAtom],
) -> EffectScope {
  if scope.allow_all {
    scope
  } else {
    let allowed : Map[String, Bool] = {}
    let mut rest = scope.rest
    for key, val in scope.allowed {
      allowed[key] = val
    }
    for effect in extra {
      match effect {
        @core.EffectAtom::Const(name) => allowed[name] = true
        @core.EffectAtom::Var(name) =>
          match rest {
            Some(existing) => if existing != name { () }
            None => rest = Some(name)
          }
      }
    }
    EffectScope::{ allow_all: false, allowed, rest }
  }
}

///|
/// Check if a specific effect name is allowed by the scope.
fn effect_scope_allows(scope : EffectScope, effect_name : String) -> Bool {
  if scope.allow_all {
    true
  } else {
    scope.allowed.contains(effect_name) || scope.rest is Some(_)
  }
}

///|
fn effect_set_empty() -> EffectSet {
  EffectSet::{ consts: {}, rest: None }
}

///|
fn effect_set_from_scope(scope : EffectScope) -> EffectSet {
  let consts : Map[String, Bool] = {}
  for key, val in scope.allowed {
    consts[key] = val
  }
  EffectSet::{ consts, rest: scope.rest }
}

///|
fn effect_set_merge(a : EffectSet, b : EffectSet) -> EffectSet raise TypeError {
  let consts : Map[String, Bool] = {}
  for key, val in a.consts {
    consts[key] = val
  }
  for key, val in b.consts {
    consts[key] = val
  }
  let rest = match (a.rest, b.rest) {
    (None, None) => None
    (Some(v), None) => Some(v)
    (None, Some(v)) => Some(v)
    (Some(v1), Some(v2)) =>
      if v1 == v2 {
        Some(v1)
      } else {
        raise TypeError::BadTypeDef(
          message="multiple effect vars",
          span=unknown_span(),
        )
      }
  }
  EffectSet::{ consts, rest }
}

///|
fn effect_set_from_atoms(
  env : TypeEnv,
  effects : Array[@core.EffectAtom],
) -> EffectSet raise TypeError {
  effect_set_from_atoms_inner(env, effects, {})
}

///|
fn effect_set_from_atoms_inner(
  env : TypeEnv,
  effects : Array[@core.EffectAtom],
  visiting : Map[String, Bool],
) -> EffectSet raise TypeError {
  let mut out = effect_set_empty()
  for effect in effects {
    match effect {
      @core.EffectAtom::Const(name) => {
        let consts : Map[String, Bool] = {}
        consts[name] = true
        out = effect_set_merge(out, EffectSet::{ consts, rest: None })
      }
      @core.EffectAtom::Var(name) => {
        let resolved = resolve_effect_var(env, name, visiting)
        out = effect_set_merge(out, resolved)
      }
    }
  }
  out
}

///|
fn resolve_effect_var(
  env : TypeEnv,
  name : String,
  visiting : Map[String, Bool],
) -> EffectSet raise TypeError {
  if visiting.contains(name) {
    EffectSet::{ consts: {}, rest: Some(name) }
  } else {
    match env.effect_subs.get(name) {
      Some(effects) => {
        let next : Map[String, Bool] = {}
        for key, val in visiting {
          next[key] = val
        }
        next[name] = true
        effect_set_from_atoms_inner(env, effects, next)
      }
      None => EffectSet::{ consts: {}, rest: Some(name) }
    }
  }
}

///|
fn effect_set_to_atoms(set : EffectSet) -> Array[@core.EffectAtom] {
  let out : Array[@core.EffectAtom] = []
  for name, _ in set.consts {
    out.push(@core.EffectAtom::Const(name))
  }
  match set.rest {
    Some(name) => out.push(@core.EffectAtom::Var(name))
    None => ()
  }
  out
}

///|
fn effect_consts_subset(
  small : Map[String, Bool],
  large : Map[String, Bool],
) -> Bool {
  for name, _ in small {
    if not(large.contains(name)) {
      return false
    }
  }
  true
}

///|
fn effect_consts_equal(
  left : Map[String, Bool],
  right : Map[String, Bool],
) -> Bool {
  effect_consts_subset(left, right) && effect_consts_subset(right, left)
}

///|
fn effect_consts_minus(
  left : Map[String, Bool],
  right : Map[String, Bool],
) -> Map[String, Bool] {
  let out : Map[String, Bool] = {}
  for name, _ in left {
    if not(right.contains(name)) {
      out[name] = true
    }
  }
  out
}

///|
fn effect_var_occurs(
  env : TypeEnv,
  name : String,
  set : EffectSet,
) -> Bool raise TypeError {
  match set.rest {
    Some(var_name) =>
      if var_name == name {
        true
      } else {
        match env.effect_subs.get(var_name) {
          Some(effects) =>
            effect_var_occurs(env, name, effect_set_from_atoms(env, effects))
          None => false
        }
      }
    None => false
  }
}

///|
fn bind_effect_var(
  env : TypeEnv,
  name : String,
  set : EffectSet,
) -> Bool raise TypeError {
  match set.rest {
    Some(var_name) =>
      if var_name == name {
        if set.consts.length() == 0 {
          true
        } else {
          let rest = fresh_effect_var(env)
          let updated = EffectSet::{ consts: set.consts, rest: Some(rest) }
          env.effect_subs[name] = effect_set_to_atoms(updated)
          true
        }
      } else if effect_var_occurs(env, name, set) {
        false
      } else {
        env.effect_subs[name] = effect_set_to_atoms(set)
        true
      }
    None =>
      if effect_var_occurs(env, name, set) {
        false
      } else {
        env.effect_subs[name] = effect_set_to_atoms(set)
        true
      }
  }
}

///|
fn add_const_to_effect_var(
  env : TypeEnv,
  name : String,
  effect : String,
) -> Unit raise TypeError {
  match env.effect_subs.get(name) {
    None => {
      let rest = fresh_effect_var(env)
      env.effect_subs[name] = [
        @core.EffectAtom::Const(effect),
        @core.EffectAtom::Var(rest),
      ]
    }
    Some(effects) => {
      let current = effect_set_from_atoms(env, effects)
      let consts : Map[String, Bool] = {}
      for key, val in current.consts {
        consts[key] = val
      }
      consts[effect] = true
      let updated = EffectSet::{ consts, rest: current.rest }
      env.effect_subs[name] = effect_set_to_atoms(updated)
    }
  }
}

///|
fn ensure_effects_allowed(
  env : TypeEnv,
  scope_set : EffectSet,
  required_set : EffectSet,
) -> String? raise TypeError {
  let resolved_scope = effect_set_from_atoms(
    env,
    effect_set_to_atoms(scope_set),
  )
  let resolved_req = effect_set_from_atoms(
    env,
    effect_set_to_atoms(required_set),
  )
  let scope_var = scope_set.rest
  for name, _ in resolved_req.consts {
    if effect_const_satisfied(resolved_scope.consts, name) {
      ()
    } else {
      match scope_var {
        Some(var_name) => add_const_to_effect_var(env, var_name, name)
        None => return Some(name)
      }
    }
  }
  match resolved_req.rest {
    None => None
    Some(req_var) =>
      match scope_var {
        Some(scope_var_name) =>
          if req_var == scope_var_name {
            None
          } else {
            let ok = bind_effect_var(env, req_var, EffectSet::{
              consts: {},
              rest: Some(scope_var_name),
            })
            if ok {
              None
            } else {
              Some("effect")
            }
          }
        None => Some("effect")
      }
  }
}

///|
fn unify_effects(
  env : TypeEnv,
  left : Array[@core.EffectAtom],
  right : Array[@core.EffectAtom],
) -> Bool raise TypeError {
  let a = effect_set_from_atoms(env, left)
  let b = effect_set_from_atoms(env, right)
  unify_effect_sets(env, a, b)
}

///|
fn unify_effect_sets(
  env : TypeEnv,
  left : EffectSet,
  right : EffectSet,
) -> Bool raise TypeError {
  match (left.rest, right.rest) {
    (None, None) => effect_consts_equal(left.consts, right.consts)
    (Some(var_name), None) =>
      if effect_consts_subset(left.consts, right.consts) {
        let diff = effect_consts_minus(right.consts, left.consts)
        bind_effect_var(env, var_name, EffectSet::{ consts: diff, rest: None })
      } else {
        false
      }
    (None, Some(var_name)) =>
      if effect_consts_subset(right.consts, left.consts) {
        let diff = effect_consts_minus(left.consts, right.consts)
        bind_effect_var(env, var_name, EffectSet::{ consts: diff, rest: None })
      } else {
        false
      }
    (Some(var_left), Some(var_right)) =>
      if effect_consts_equal(left.consts, right.consts) {
        if var_left == var_right {
          true
        } else {
          bind_effect_var(env, var_left, EffectSet::{
            consts: {},
            rest: Some(var_right),
          })
        }
      } else if effect_consts_subset(left.consts, right.consts) {
        let diff = effect_consts_minus(right.consts, left.consts)
        bind_effect_var(env, var_left, EffectSet::{
          consts: diff,
          rest: Some(var_right),
        })
      } else if effect_consts_subset(right.consts, left.consts) {
        let diff = effect_consts_minus(left.consts, right.consts)
        bind_effect_var(env, var_right, EffectSet::{
          consts: diff,
          rest: Some(var_left),
        })
      } else {
        false
      }
  }
}
