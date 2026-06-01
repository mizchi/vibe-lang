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
fn effect_scope_none() -> EffectScope {
  EffectScope::{ allow_all: false, allowed: {}, rest: None }
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
        if !seen.contains(name) {
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
    if !large.contains(name) {
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
    if !right.contains(name) {
      out[name] = true
    }
  }
  out
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
fn compatible_effect_aliases(required_effect : String) -> Array[String] {
  match required_effect {
    // Temporary compatibility for legacy scripts: Process replaced Stdout for sh/sh_lines.
    "Process" => ["Stdout"]
    _ => []
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
    | "Fs::append"
    | "Fs::open_write"
    | "Fs::write_chunk"
    | "Fs::close_write" => [@core.EffectAtom::Const("Fs")]
    "Fs::read_string" => [@core.EffectAtom::Const("Fs")]
    "Fs::write_string" => [@core.EffectAtom::Const("Fs")]
    "Fs::read_bytes" => [@core.EffectAtom::Const("Fs")]
    "Fs::write_bytes" => [@core.EffectAtom::Const("Fs")]
    "Env::get" | "Env::args_len" | "Env::args_get" =>
      [@core.EffectAtom::Const("Env")]
    "Socket::tcp_connect"
    | "Socket::tcp_read"
    | "Socket::tcp_write"
    | "Socket::tcp_close" => [@core.EffectAtom::Const("Socket")]
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
    | "Http::respond" => [@core.EffectAtom::Const("Http")]
    "Llm::complete" | "Rlm::run" => [@core.EffectAtom::Const("Llm")]
    _ => []
  }
}
