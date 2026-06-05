///|
fn threads_runtime_hints_type() -> @core.Type {
  @core.Type::Record({
    "wasm_flags": @core.Type::Array(@core.Type::String),
    "wasi_flags": @core.Type::Array(@core.Type::String),
    "wasm_env": @core.Type::String,
    "wasi_env": @core.Type::String,
  })
}

///|
fn threads_channel_type(payload : @core.Type) -> @core.Type {
  @core.Type::Named(name="ThreadChannel", args=[payload])
}

///|
fn threads_task_type(result : @core.Type) -> @core.Type {
  @core.Type::Named(name="ThreadTask", args=[result])
}

///|
fn expect_threads_channel_payload_type(
  env : TypeEnv,
  expr : @core.Expr,
  aliases : Map[String, @core.Ref],
  effects : EffectScope,
  allow_effect : Bool,
) -> @core.Type raise TypeError {
  let actual = type_expr_eff(env, expr, aliases, effects, allow_effect)
  let payload = fresh_type_var(env)
  let expected = threads_channel_type(payload)
  if !type_equal(env, actual, expected) {
    raise TypeError::Mismatch(
      expected~,
      actual=resolve_type(env, actual),
      span=expr.span(),
      context=Some("thread channel"),
    )
  }
  resolve_type(env, payload)
}

///|
fn expect_threads_task_result_type(
  env : TypeEnv,
  expr : @core.Expr,
  aliases : Map[String, @core.Ref],
  effects : EffectScope,
  allow_effect : Bool,
) -> @core.Type raise TypeError {
  let actual = type_expr_eff(env, expr, aliases, effects, allow_effect)
  let result = fresh_type_var(env)
  let expected = threads_task_type(result)
  if !type_equal(env, actual, expected) {
    raise TypeError::Mismatch(
      expected~,
      actual=resolve_type(env, actual),
      span=expr.span(),
      context=Some("thread task"),
    )
  }
  resolve_type(env, result)
}

///|
fn thread_spawn_result_type_from_name_expr(
  env : TypeEnv,
  expr : @core.Expr,
) -> @core.Type {
  match expr {
    @core.Expr::String(value~, ..) =>
      if value == "noop" || value == "alloc-probe" {
        @core.Type::Int
      } else {
        match env.get(value) {
          Some(@core.Type::Func(ret~, ..)) => resolve_type(env, ret)
          _ => @core.Type::Int
        }
      }
    _ => @core.Type::Int
  }
}

///|
fn threads_shared_value_is_int_type(ty : @core.Type) -> Bool {
  match ty {
    @core.Type::Int => true
    @core.Type::Named(name="Int", args=[]) => true
    _ => false
  }
}

///|
fn threads_shared_value_is_string_type(ty : @core.Type) -> Bool {
  match ty {
    @core.Type::String => true
    @core.Type::Named(name="String", args=[]) => true
    _ => false
  }
}

///|
fn threads_shared_value_is_supported_scalar_type(ty : @core.Type) -> Bool {
  threads_shared_value_is_int_type(ty) ||
  threads_shared_value_is_string_type(ty)
}

///|
fn threads_shared_value_is_supported_array_type(ty : @core.Type) -> Bool {
  match ty {
    @core.Type::Array(elem) =>
      threads_shared_value_is_supported_scalar_type(elem)
    @core.Type::Named(name="Array", args=[elem]) =>
      threads_shared_value_is_supported_scalar_type(elem)
    _ => false
  }
}

///|
fn threads_shared_value_is_supported_tuple_type(ty : @core.Type) -> Bool {
  match ty {
    @core.Type::Tuple(items) => {
      for item in items {
        if !threads_shared_value_is_supported_scalar_type(item) {
          return false
        }
      }
      true
    }
    _ => false
  }
}

///|
fn threads_shared_value_is_supported_type(ty : @core.Type) -> Bool {
  threads_shared_value_is_supported_scalar_type(ty) ||
  threads_shared_value_is_supported_array_type(ty) ||
  threads_shared_value_is_supported_tuple_type(ty)
}

///|
fn check_threads_payload_type(
  env : TypeEnv,
  expr : @core.Expr,
  aliases : Map[String, @core.Ref],
  effects : EffectScope,
  allow_effect : Bool,
) -> @core.Type raise TypeError {
  let actual = type_expr_eff(env, expr, aliases, effects, allow_effect)
  let resolved = resolve_type(env, actual)
  if threads_shared_value_is_supported_type(resolved) {
    actual
  } else {
    raise TypeError::Mismatch(
      expected=@core.Type::Named(name="ThreadChannelPayload", args=[]),
      actual=resolved,
      span=expr.span(),
      context=Some("thread channel payload"),
    )
  }
}

///|
fn type_call_builtin_handler_threads(
  env : TypeEnv,
  name : String,
  builtin_name : String,
  args : Array[@core.CallArg],
  aliases : Map[String, @core.Ref],
  effects : EffectScope,
  allow_effect : Bool,
  call_span : @core.Span,
) -> @core.Type raise TypeError {
  let ctx = BuiltinCallCtx::{
    env,
    args,
    aliases,
    effects,
    allow_effect,
    call_span,
  }
  match builtin_name {
    "Threads::probe_wat" =>
      ctx.simple("Threads::probe_wat", [], @core.Type::String, true)
    "Threads::runtime_hints" =>
      ctx.simple(
        "Threads::runtime_hints",
        [],
        threads_runtime_hints_type(),
        true,
      )
    "Threads::channel_new" =>
      ctx.simple(
        "Threads::channel_new",
        [@core.Type::Int],
        threads_channel_type(fresh_type_var(env)),
        true,
      )
    "Threads::send" => {
      let pos_args = prepare_builtin_pos_args(
        env, "Threads::send", args, 2, effects, allow_effect, call_span, true,
      )
      let channel_payload_ty = expect_threads_channel_payload_type(
        env,
        pos_args[0],
        aliases,
        effects,
        allow_effect,
      )
      let actual_payload_ty = check_threads_payload_type(
        env,
        pos_args[1],
        aliases,
        effects,
        allow_effect,
      )
      if !type_equal(env, actual_payload_ty, channel_payload_ty) {
        raise TypeError::Mismatch(
          expected=resolve_type(env, channel_payload_ty),
          actual=resolve_type(env, actual_payload_ty),
          span=pos_args[1].span(),
          context=Some("thread channel payload"),
        )
      }
      @core.Type::Bool
    }
    "Threads::recv" => {
      let pos_args = prepare_builtin_pos_args(
        env, "Threads::recv", args, 1, effects, allow_effect, call_span, true,
      )
      expect_threads_channel_payload_type(
        env,
        pos_args[0],
        aliases,
        effects,
        allow_effect,
      )
    }
    "Threads::spawn" => {
      let pos_args = prepare_builtin_pos_args(
        env, "Threads::spawn", args, 2, effects, allow_effect, call_span, true,
      )
      let _ = check_arg_type(
        env,
        pos_args[0],
        @core.Type::String,
        aliases,
        effects,
        allow_effect,
      )
      let _ = expect_threads_channel_payload_type(
        env,
        pos_args[1],
        aliases,
        effects,
        allow_effect,
      )
      threads_task_type(
        thread_spawn_result_type_from_name_expr(env, pos_args[0]),
      )
    }
    "Threads::wait" => {
      let pos_args = prepare_builtin_pos_args(
        env, "Threads::wait", args, 1, effects, allow_effect, call_span, true,
      )
      expect_threads_task_result_type(
        env,
        pos_args[0],
        aliases,
        effects,
        allow_effect,
      )
    }
    _ =>
      type_call_builtin_handler_collection_numeric(
        env, name, builtin_name, args, aliases, effects, allow_effect, call_span,
      )
  }
}
