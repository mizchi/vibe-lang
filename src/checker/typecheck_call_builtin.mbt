///|
/// Check positional arity for builtin calls.
fn check_positional_arity(
  args : Array[@core.CallArg],
  name : String,
  expected : Int,
  call_span : @core.Span,
) -> Array[@core.Expr] raise TypeError {
  let pos_args = extract_positional_args(args, name, call_span)
  if pos_args.length() != expected {
    raise TypeError::BadCall(message=name, span=call_span)
  }
  pos_args
}

///|
/// Ensure already-inferred type matches expected type.
fn ensure_type(
  env : TypeEnv,
  actual : @core.Type,
  expected : @core.Type,
  span : @core.Span,
  context : String,
) -> Unit raise TypeError {
  if not(type_equal(env, actual, expected)) {
    raise TypeError::Mismatch(expected~, actual~, span~, context=Some(context))
  }
}

///|
/// Type-check a single argument and verify it matches expected type.
fn check_arg_type(
  env : TypeEnv,
  expr : @core.Expr,
  expected : @core.Type,
  aliases : Map[String, @core.Ref],
  effects : EffectScope,
  allow_effect : Bool,
) -> @core.Type raise TypeError {
  let actual = type_expr_eff(env, expr, aliases, effects, allow_effect)
  ensure_type(env, actual, expected, expr.span(), "argument")
  actual
}

///|
/// Type-check a single argument and verify it is either String or PromptText.
fn check_arg_string_or_prompt_text(
  env : TypeEnv,
  expr : @core.Expr,
  aliases : Map[String, @core.Ref],
  effects : EffectScope,
  allow_effect : Bool,
) -> @core.Type raise TypeError {
  let actual = type_expr_eff(env, expr, aliases, effects, allow_effect)
  if not(
      type_equal(env, actual, @core.Type::String) ||
      type_equal(env, actual, @core.Type::PromptText),
    ) {
    raise TypeError::Mismatch(
      expected=@core.Type::String,
      actual~,
      span=expr.span(),
      context=Some("argument"),
    )
  }
  actual
}

///|
/// Shared prelude for custom builtin checkers: arity check + optional effect guard.
fn prepare_builtin_pos_args(
  env : TypeEnv,
  name : String,
  args : Array[@core.CallArg],
  expected_arity : Int,
  effects : EffectScope,
  allow_effect : Bool,
  call_span : @core.Span,
  effectful : Bool,
) -> Array[@core.Expr] raise TypeError {
  let pos_args = check_positional_arity(args, name, expected_arity, call_span)
  if effectful {
    require_effect_guard(
      env,
      effects,
      allow_effect,
      name,
      builtin_effects(name),
      call_span,
    )
  }
  pos_args
}

///|
fn expect_array_elem_type(
  env : TypeEnv,
  actual : @core.Type,
  span : @core.Span,
) -> @core.Type raise TypeError {
  let elem_ty = fresh_type_var(env)
  ensure_type(env, actual, @core.Type::Array(elem_ty), span, "argument")
  elem_ty
}

///|
fn expect_map_elem_type(
  env : TypeEnv,
  actual : @core.Type,
  span : @core.Span,
) -> (@core.Type, @core.Type) raise TypeError {
  let key_ty = fresh_type_var(env)
  let elem_ty = fresh_type_var(env)
  ensure_type(env, actual, @core.Type::Map(key_ty, elem_ty), span, "argument")
  (key_ty, elem_ty)
}

///|
/// Ensure that a key type satisfies the Hash trait bound for map operations.
/// Primitive types (Int, Float, Double, Bool, Char, String) are always hashable.
fn ensure_map_key_hashable(
  env : TypeEnv,
  key_ty : @core.Type,
  span : @core.Span,
) -> Unit raise TypeError {
  let resolved = resolve_type(env, key_ty)
  match resolved {
    @core.Type::Var(_) => () // type variable: will be checked at instantiation
    @core.Type::Int
    | @core.Type::Float
    | @core.Type::Double
    | @core.Type::Bool
    | @core.Type::Char
    | @core.Type::String => () // primitive types are always hashable
    _ =>
      if not(type_implements_trait(env, resolved, "Hash")) {
        raise TypeError::Mismatch(
          expected=@core.Type::Named(name="Hash", args=[]),
          actual=resolved,
          span~,
          context=Some("map key must implement Hash"),
        )
      }
  }
}

///|
fn expect_array_builder_elem_type(
  env : TypeEnv,
  actual : @core.Type,
  span : @core.Span,
) -> @core.Type raise TypeError {
  let elem_ty = fresh_type_var(env)
  ensure_type(env, actual, @core.Type::ArrayBuilder(elem_ty), span, "argument")
  elem_ty
}

///|
fn expect_map_builder_elem_type(
  env : TypeEnv,
  actual : @core.Type,
  span : @core.Span,
) -> (@core.Type, @core.Type) raise TypeError {
  let key_ty = fresh_type_var(env)
  let elem_ty = fresh_type_var(env)
  ensure_type(
    env,
    actual,
    @core.Type::MapBuilder(key_ty, elem_ty),
    span,
    "argument",
  )
  (key_ty, elem_ty)
}

///|
/// Convenience: check a simple builtin call with fixed param types, optional effect, and return type.
fn check_builtin_simple(
  env : TypeEnv,
  name : String,
  args : Array[@core.CallArg],
  aliases : Map[String, @core.Ref],
  effects : EffectScope,
  allow_effect : Bool,
  call_span : @core.Span,
  param_types : Array[@core.Type],
  ret_type : @core.Type,
  effectful : Bool,
) -> @core.Type raise TypeError {
  let pos_args = prepare_builtin_pos_args(
    env,
    name,
    args,
    param_types.length(),
    effects,
    allow_effect,
    call_span,
    effectful,
  )
  for i in 0..<param_types.length() {
    let _ = check_arg_type(
      env,
      pos_args[i],
      param_types[i],
      aliases,
      effects,
      allow_effect,
    )
  }
  ret_type
}

///|
fn builtin_json_type() -> @core.Type {
  @core.Type::Named(name="Json", args=[])
}

///|
fn type_call_builtin(
  env : TypeEnv,
  name : String,
  args : Array[@core.CallArg],
  aliases : Map[String, @core.Ref],
  effects : EffectScope,
  allow_effect : Bool,
  call_span : @core.Span,
) -> @core.Type raise TypeError {
  let builtin_name = @core.lower_wasm_intrinsic_name(name)
  type_call_builtin_handler_core_io(
    env, name, builtin_name, args, aliases, effects, allow_effect, call_span,
  )
}
