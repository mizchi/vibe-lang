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
fn span_key(span : @core.Span) -> Int64 {
  (span.start.to_int64() << 32) | span.end.to_int64()
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
    "Map", "ArrayBuilder", "MapBuilder", "StringBuilder", "i32", "f32", "f64", "anyref",
    "eqref", "i31ref", "structref", "arrayref", "funcref", "externref",
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
