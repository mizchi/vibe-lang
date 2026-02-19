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
) -> @core.Type raise TypeError {
  let elem_ty = fresh_type_var(env)
  ensure_type(env, actual, @core.Type::Map(elem_ty), span, "argument")
  elem_ty
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
) -> @core.Type raise TypeError {
  let elem_ty = fresh_type_var(env)
  ensure_type(env, actual, @core.Type::MapBuilder(elem_ty), span, "argument")
  elem_ty
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
  match builtin_name {
    "path" | "path_ref" =>
      check_builtin_simple(
        env,
        name,
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String],
        @core.Type::Path,
        false,
      )
    "path_to_string" =>
      check_builtin_simple(
        env,
        "path_to_string",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Path],
        @core.Type::String,
        false,
      )
    "path_is_absolute" =>
      check_builtin_simple(
        env,
        "path_is_absolute",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Path],
        @core.Type::Bool,
        false,
      )
    "prompt_text" => {
      let pos_args = prepare_builtin_pos_args(
        env,
        "prompt_text",
        args,
        1,
        effects,
        allow_effect,
        call_span,
        false,
      )
      let _ = check_arg_string_or_prompt_text(
        env,
        pos_args[0],
        aliases,
        effects,
        allow_effect,
      )
      @core.Type::PromptText
    }
    "prompt_text_to_string" =>
      check_builtin_simple(
        env,
        "prompt_text_to_string",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::PromptText],
        @core.Type::String,
        false,
      )
    "dynamic_path_resolve" =>
      check_builtin_simple(
        env,
        "dynamic_path_resolve",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String],
        @core.Type::Path,
        true,
      )
    "addr" => {
      let pos_args = extract_positional_args(args, "addr", call_span)
      if pos_args.length() != 1 {
        raise TypeError::BadCall(message="addr", span=call_span)
      }
      match pos_args[0] {
        @core.Expr::String(value=s, span~) =>
          match env.get_addr_type(s) {
            Some(ty) => ty
            None =>
              raise TypeError::UnknownName(
                name="addr:" + s,
                span~,
                suggestion=None,
              )
          }
        _ => raise TypeError::BadCall(message="addr", span=call_span)
      }
    }
    "sh" =>
      check_builtin_simple(
        env,
        "sh",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String],
        @core.Type::Unit,
        true,
      )
    "sh_lines" => {
      // Extract positional arg (cmd string) and optional labeled args (Bool flags)
      let pos_args : Array[@core.Expr] = []
      let label_args : Array[@core.CallArg] = []
      for arg in args {
        match arg.label {
          Some(_) => label_args.push(arg)
          None => pos_args.push(arg.expr)
        }
      }
      if pos_args.length() != 1 {
        raise TypeError::BadCall(message="sh_lines", span=call_span)
      }
      require_effect_guard(
        env,
        effects,
        allow_effect,
        "sh_lines",
        builtin_effects("sh_lines"),
        call_span,
      )
      let arg_ty = type_expr_eff(
        env,
        pos_args[0],
        aliases,
        effects,
        allow_effect,
      )
      if not(type_equal(env, arg_ty, @core.Type::String)) {
        raise TypeError::Mismatch(
          expected=@core.Type::String,
          actual=arg_ty,
          span=pos_args[0].span(),
          context=Some("argument"),
        )
      }
      // Validate labeled args are all Bool
      for larg in label_args {
        let lty = type_expr_eff(env, larg.expr, aliases, effects, allow_effect)
        if not(type_equal(env, lty, @core.Type::Bool)) {
          raise TypeError::Mismatch(
            expected=@core.Type::Bool,
            actual=lty,
            span=larg.span,
            context=Some("flag argument"),
          )
        }
      }
      @core.Type::Array(@core.Type::String)
    }
    "select" => {
      let pos_args = extract_positional_args(args, "select", call_span)
      if pos_args.length() < 2 {
        raise TypeError::BadCall(message="select", span=call_span)
      }
      let target_ty = type_expr_eff(
        env,
        pos_args[0],
        aliases,
        effects,
        allow_effect,
      )
      let field_names : Array[String] = []
      for i in 1..<pos_args.length() {
        let arg_ty = type_expr_eff(
          env,
          pos_args[i],
          aliases,
          effects,
          allow_effect,
        )
        if not(type_equal(env, arg_ty, @core.Type::String)) {
          raise TypeError::Mismatch(
            expected=@core.Type::String,
            actual=arg_ty,
            span=pos_args[i].span(),
            context=Some("select field name"),
          )
        }
        match pos_args[i] {
          @core.Expr::String(value~, ..) => field_names.push(value)
          _ =>
            raise TypeError::BadCall(
              message="select: field names must be string literals",
              span=pos_args[i].span(),
            )
        }
      }
      match target_ty {
        @core.Type::Record(fields) => {
          let result_fields : Map[String, @core.Type] = {}
          for name in field_names {
            match fields.get(name) {
              Some(ty) => result_fields[name] = ty
              None =>
                raise TypeError::BadCall(
                  message="select: unknown field: " + name,
                  span=call_span,
                )
            }
          }
          @core.Type::Record(result_fields)
        }
        @core.Type::Array(@core.Type::Record(fields) as _elem_ty) => {
          let result_fields : Map[String, @core.Type] = {}
          for name in field_names {
            match fields.get(name) {
              Some(ty) => result_fields[name] = ty
              None =>
                raise TypeError::BadCall(
                  message="select: unknown field: " + name,
                  span=call_span,
                )
            }
          }
          @core.Type::Array(@core.Type::Record(result_fields))
        }
        _ =>
          raise TypeError::BadCall(
            message="select: first argument must be Record or Array[Record]",
            span=pos_args[0].span(),
          )
      }
    }
    "sleep" =>
      check_builtin_simple(
        env,
        "sleep",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Int],
        @core.Type::Unit,
        true,
      )
    "threads_probe_wat" =>
      check_builtin_simple(
        env,
        "threads_probe_wat",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [],
        @core.Type::String,
        false,
      )
    "threads_runtime_hints" => {
      let pos_args = extract_positional_args(
        args, "threads_runtime_hints", call_span,
      )
      if pos_args.length() != 0 {
        raise TypeError::BadCall(
          message="threads_runtime_hints",
          span=call_span,
        )
      }
      let fields : Map[String, @core.Type] = {}
      fields["wasm_flags"] = @core.Type::Array(@core.Type::String)
      fields["wasi_flags"] = @core.Type::Array(@core.Type::String)
      fields["wasm_env"] = @core.Type::String
      fields["wasi_env"] = @core.Type::String
      @core.Type::Record(fields)
    }
    "threads_channel_new" =>
      check_builtin_simple(
        env,
        "threads_channel_new",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Int],
        @core.Type::Int,
        false,
      )
    "threads_send" =>
      check_builtin_simple(
        env,
        "threads_send",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Int, @core.Type::String],
        @core.Type::Bool,
        false,
      )
    "threads_recv" =>
      check_builtin_simple(
        env,
        "threads_recv",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Int],
        @core.Type::String,
        false,
      )
    "threads_spawn" => {
      let pos_args = extract_positional_args(args, "threads_spawn", call_span)
      if pos_args.length() != 2 {
        raise TypeError::BadCall(message="threads_spawn", span=call_span)
      }
      let name_ty = type_expr_eff(
        env,
        pos_args[0],
        aliases,
        effects,
        allow_effect,
      )
      if not(type_equal(env, name_ty, @core.Type::String)) {
        raise TypeError::Mismatch(
          expected=@core.Type::String,
          actual=name_ty,
          span=pos_args[0].span(),
          context=Some("argument"),
        )
      }
      let mailbox_ty = type_expr_eff(
        env,
        pos_args[1],
        aliases,
        effects,
        allow_effect,
      )
      if not(type_equal(env, mailbox_ty, @core.Type::Int)) {
        raise TypeError::Mismatch(
          expected=@core.Type::Int,
          actual=mailbox_ty,
          span=pos_args[1].span(),
          context=Some("argument"),
        )
      }
      @core.Type::Int
    }
    "threads_wait" =>
      check_builtin_simple(
        env,
        "threads_wait",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Int],
        @core.Type::Int,
        false,
      )
    "stdout_write_char" =>
      check_builtin_simple(
        env,
        "stdout_write_char",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Int],
        @core.Type::Unit,
        true,
      )
    "stdin_read_char" =>
      check_builtin_simple(
        env,
        "stdin_read_char",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [],
        @core.Type::Int,
        true,
      )
    "stdout_write_stream" =>
      check_builtin_simple(
        env,
        "stdout_write_stream",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String],
        @core.Type::Unit,
        true,
      )
    "stdin_read_stream" =>
      check_builtin_simple(
        env,
        "stdin_read_stream",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Int],
        @core.Type::String,
        true,
      )
    "fs_read_file" =>
      check_builtin_simple(
        env,
        "fs_read_file",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String],
        @core.Type::String,
        true,
      )
    "fs_write_file" =>
      check_builtin_simple(
        env,
        "fs_write_file",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String, @core.Type::String],
        @core.Type::Unit,
        true,
      )
    "fs_exists" =>
      check_builtin_simple(
        env,
        "fs_exists",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String],
        @core.Type::Bool,
        true,
      )
    "fs_readdir" =>
      check_builtin_simple(
        env,
        "fs_readdir",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String],
        @core.Type::Array(@core.Type::String),
        true,
      )
    "fs_is_dir" =>
      check_builtin_simple(
        env,
        "fs_is_dir",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String],
        @core.Type::Bool,
        true,
      )
    "fs_mkdir" | "fs_mkdir_p" =>
      check_builtin_simple(
        env,
        name,
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String],
        @core.Type::Unit,
        true,
      )
    "fs_getcwd" =>
      check_builtin_simple(
        env,
        "fs_getcwd",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [],
        @core.Type::String,
        true,
      )
    "fs_chdir" =>
      check_builtin_simple(
        env,
        "fs_chdir",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String],
        @core.Type::Unit,
        true,
      )
    "fs_remove" =>
      check_builtin_simple(
        env,
        "fs_remove",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String],
        @core.Type::Unit,
        true,
      )
    "fs_is_file" =>
      check_builtin_simple(
        env,
        "fs_is_file",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String],
        @core.Type::Bool,
        true,
      )
    "fs_copy" | "fs_rename" =>
      check_builtin_simple(
        env,
        name,
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String, @core.Type::String],
        @core.Type::Unit,
        true,
      )
    "fs_append" =>
      check_builtin_simple(
        env,
        "fs_append",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String, @core.Type::String],
        @core.Type::Unit,
        true,
      )
    "env_get" =>
      check_builtin_simple(
        env,
        "env_get",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String],
        @core.Type::String,
        true,
      )
    "socket_tcp_connect" =>
      check_builtin_simple(
        env,
        "socket_tcp_connect",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String, @core.Type::Int],
        @core.Type::Int,
        true,
      )
    "socket_tcp_read" =>
      check_builtin_simple(
        env,
        "socket_tcp_read",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Int, @core.Type::Int],
        @core.Type::String,
        true,
      )
    "socket_tcp_write" =>
      check_builtin_simple(
        env,
        "socket_tcp_write",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Int, @core.Type::String],
        @core.Type::Unit,
        true,
      )
    "socket_tcp_close" =>
      check_builtin_simple(
        env,
        "socket_tcp_close",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Int],
        @core.Type::Unit,
        true,
      )
    // --- HTTP Client builtins ---
    "http_request" =>
      check_builtin_simple(
        env,
        "http_request",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [
          @core.Type::String,
          @core.Type::String,
          @core.Type::String,
          @core.Type::String,
        ],
        @core.Type::Int,
        true,
      )
    "http_response_status" =>
      check_builtin_simple(
        env,
        "http_response_status",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Int],
        @core.Type::Int,
        true,
      )
    "http_response_header" =>
      check_builtin_simple(
        env,
        "http_response_header",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Int, @core.Type::String],
        @core.Type::String,
        true,
      )
    "http_response_body" =>
      check_builtin_simple(
        env,
        "http_response_body",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Int],
        @core.Type::String,
        true,
      )
    "http_close" =>
      check_builtin_simple(
        env,
        "http_close",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Int],
        @core.Type::Unit,
        true,
      )
    // --- HTTP Server builtins ---
    "http_listen" =>
      check_builtin_simple(
        env,
        "http_listen",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Int],
        @core.Type::Int,
        true,
      )
    "http_accept" =>
      check_builtin_simple(
        env,
        "http_accept",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Int],
        @core.Type::Int,
        true,
      )
    "http_request_method" | "http_request_url" | "http_request_body" =>
      check_builtin_simple(
        env,
        name,
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Int],
        @core.Type::String,
        true,
      )
    "http_request_header" =>
      check_builtin_simple(
        env,
        "http_request_header",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Int, @core.Type::String],
        @core.Type::String,
        true,
      )
    "http_respond" =>
      check_builtin_simple(
        env,
        "http_respond",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [
          @core.Type::Int,
          @core.Type::Int,
          @core.Type::String,
          @core.Type::String,
        ],
        @core.Type::Unit,
        true,
      )
    "llm_complete" => {
      // (system: String, user: String) -> String with { Llm }
      let pos_args = prepare_builtin_pos_args(
        env,
        "llm_complete",
        args,
        2,
        effects,
        allow_effect,
        call_span,
        true,
      )
      for arg in pos_args {
        let _ = check_arg_string_or_prompt_text(
          env,
          arg,
          aliases,
          effects,
          allow_effect,
        )
      }
      @core.Type::String
    }
    "rlm_run" => {
      // (task: String, prompt: String|PromptText) -> String with { Llm }
      let pos_args = prepare_builtin_pos_args(
        env,
        "rlm_run",
        args,
        2,
        effects,
        allow_effect,
        call_span,
        true,
      )
      for arg in pos_args {
        let _ = check_arg_string_or_prompt_text(
          env,
          arg,
          aliases,
          effects,
          allow_effect,
        )
      }
      @core.Type::String
    }
    "rlm_finalize" =>
      check_builtin_simple(
        env,
        "rlm_finalize",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String],
        @core.Type::String,
        false,
      )
    "string_from_char_code" =>
      check_builtin_simple(
        env,
        "string_from_char_code",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Int],
        @core.Type::String,
        false,
      )
    "char_to_int" =>
      check_builtin_simple(
        env,
        "char_to_int",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Char],
        @core.Type::Int,
        false,
      )
    "char_from_int" =>
      check_builtin_simple(
        env,
        "char_from_int",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Int],
        @core.Type::Char,
        false,
      )
    "string_builder" =>
      check_builtin_simple(
        env,
        "string_builder",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [],
        @core.Type::StringBuilder,
        true,
      )
    "string_builder_push" =>
      check_builtin_simple(
        env,
        "string_builder_push",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::StringBuilder, @core.Type::String],
        @core.Type::Unit,
        true,
      )
    "string_builder_freeze" =>
      check_builtin_simple(
        env,
        "string_builder_freeze",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::StringBuilder],
        @core.Type::String,
        true,
      )
    "array_builder" =>
      check_builtin_simple(
        env,
        "array_builder",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [],
        @core.Type::ArrayBuilder(fresh_type_var(env)),
        true,
      )
    "array_builder_push" => {
      let pos_args = prepare_builtin_pos_args(
        env,
        "array_builder_push",
        args,
        2,
        effects,
        allow_effect,
        call_span,
        true,
      )
      let builder_ty = type_expr_eff(
        env,
        pos_args[0],
        aliases,
        effects,
        allow_effect,
      )
      let value_ty = type_expr_eff(
        env,
        pos_args[1],
        aliases,
        effects,
        allow_effect,
      )
      let elem_ty = expect_array_builder_elem_type(env, builder_ty, pos_args[0].span())
      ensure_type(env, value_ty, elem_ty, pos_args[1].span(), "argument")
      @core.Type::Unit
    }
    "array_builder_freeze" => {
      let pos_args = prepare_builtin_pos_args(
        env,
        "array_builder_freeze",
        args,
        1,
        effects,
        allow_effect,
        call_span,
        true,
      )
      let builder_ty = type_expr_eff(
        env,
        pos_args[0],
        aliases,
        effects,
        allow_effect,
      )
      let elem_ty = expect_array_builder_elem_type(env, builder_ty, pos_args[0].span())
      @core.Type::Array(elem_ty)
    }
    "map_builder" =>
      check_builtin_simple(
        env,
        "map_builder",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [],
        @core.Type::MapBuilder(fresh_type_var(env)),
        true,
      )
    "map_builder_set" => {
      let pos_args = prepare_builtin_pos_args(
        env,
        "map_builder_set",
        args,
        3,
        effects,
        allow_effect,
        call_span,
        true,
      )
      let builder_ty = type_expr_eff(
        env,
        pos_args[0],
        aliases,
        effects,
        allow_effect,
      )
      let _ = check_arg_type(
        env,
        pos_args[1],
        @core.Type::String,
        aliases,
        effects,
        allow_effect,
      )
      let value_ty = type_expr_eff(
        env,
        pos_args[2],
        aliases,
        effects,
        allow_effect,
      )
      let elem_ty = expect_map_builder_elem_type(env, builder_ty, pos_args[0].span())
      ensure_type(env, value_ty, elem_ty, pos_args[2].span(), "argument")
      @core.Type::Unit
    }
    "map_builder_freeze" => {
      let pos_args = prepare_builtin_pos_args(
        env,
        "map_builder_freeze",
        args,
        1,
        effects,
        allow_effect,
        call_span,
        true,
      )
      let builder_ty = type_expr_eff(
        env,
        pos_args[0],
        aliases,
        effects,
        allow_effect,
      )
      let elem_ty = expect_map_builder_elem_type(env, builder_ty, pos_args[0].span())
      @core.Type::Map(elem_ty)
    }
    "array_length" => {
      let pos_args = check_positional_arity(args, "array_length", 1, call_span)
      let array_ty = type_expr_eff(
        env,
        pos_args[0],
        aliases,
        effects,
        allow_effect,
      )
      let _ = expect_array_elem_type(env, array_ty, pos_args[0].span())
      @core.Type::Int
    }
    "array_get" => {
      let pos_args = check_positional_arity(args, "array_get", 2, call_span)
      let array_ty = type_expr_eff(
        env,
        pos_args[0],
        aliases,
        effects,
        allow_effect,
      )
      let _ = check_arg_type(
        env,
        pos_args[1],
        @core.Type::Int,
        aliases,
        effects,
        allow_effect,
      )
      let elem_ty = expect_array_elem_type(env, array_ty, pos_args[0].span())
      elem_ty
    }
    "map_get" => {
      let pos_args = check_positional_arity(args, "map_get", 2, call_span)
      let map_ty = type_expr_eff(
        env,
        pos_args[0],
        aliases,
        effects,
        allow_effect,
      )
      let _ = check_arg_type(
        env,
        pos_args[1],
        @core.Type::String,
        aliases,
        effects,
        allow_effect,
      )
      let elem_ty = expect_map_elem_type(env, map_ty, pos_args[0].span())
      elem_ty
    }
    "string_length"
    | "string_utf8_length"
    | "string_utf16_length"
    | "string_unicode_length" =>
      check_builtin_simple(
        env,
        name,
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String],
        @core.Type::Int,
        false,
      )
    "string_char_code_at" =>
      check_builtin_simple(
        env,
        "string_char_code_at",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String, @core.Type::Int],
        @core.Type::Int,
        false,
      )
    "string_substring" =>
      check_builtin_simple(
        env,
        "string_substring",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String, @core.Type::Int, @core.Type::Int],
        @core.Type::String,
        false,
      )
    "string_concat" =>
      check_builtin_simple(
        env,
        "string_concat",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String, @core.Type::String],
        @core.Type::String,
        false,
      )
    "string_equals" =>
      check_builtin_simple(
        env,
        "string_equals",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String, @core.Type::String],
        @core.Type::Bool,
        false,
      )
    "string_split" =>
      check_builtin_simple(
        env,
        "string_split",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String, @core.Type::String],
        @core.Type::Array(@core.Type::String),
        false,
      )
    "string_index_of" | "string_last_index_of" | "string_count" =>
      check_builtin_simple(
        env,
        name,
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String, @core.Type::String],
        @core.Type::Int,
        false,
      )
    "string_contains" | "string_starts_with" | "string_ends_with" =>
      check_builtin_simple(
        env,
        name,
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String, @core.Type::String],
        @core.Type::Bool,
        false,
      )
    "string_trim" | "string_trim_start" | "string_trim_end" =>
      check_builtin_simple(
        env,
        name,
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String],
        @core.Type::String,
        false,
      )
    "string_replace" | "string_replace_all" =>
      check_builtin_simple(
        env,
        name,
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String, @core.Type::String, @core.Type::String],
        @core.Type::String,
        false,
      )
    "int_abs" | "int_signum" =>
      type_check_unary_convert(
        env,
        args,
        call_span,
        aliases,
        effects,
        allow_effect,
        name,
        @core.Type::Int,
        @core.Type::Int,
      )
    "int_is_even" | "int_is_odd" =>
      type_check_unary_convert(
        env,
        args,
        call_span,
        aliases,
        effects,
        allow_effect,
        name,
        @core.Type::Int,
        @core.Type::Bool,
      )
    "int_max" | "int_min" =>
      check_builtin_simple(
        env,
        name,
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Int, @core.Type::Int],
        @core.Type::Int,
        false,
      )
    "int_clamp" =>
      check_builtin_simple(
        env,
        "int_clamp",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Int, @core.Type::Int, @core.Type::Int],
        @core.Type::Int,
        false,
      )
    "double_abs" =>
      type_check_unary_convert(
        env,
        args,
        call_span,
        aliases,
        effects,
        allow_effect,
        name,
        @core.Type::Double,
        @core.Type::Double,
      )
    "double_max" | "double_min" =>
      check_builtin_simple(
        env,
        name,
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Double, @core.Type::Double],
        @core.Type::Double,
        false,
      )
    "double_floor" | "double_ceil" =>
      type_check_unary_convert(
        env,
        args,
        call_span,
        aliases,
        effects,
        allow_effect,
        name,
        @core.Type::Double,
        @core.Type::Double,
      )
    "string_to_upper" | "string_to_lower" =>
      type_check_unary_convert(
        env,
        args,
        call_span,
        aliases,
        effects,
        allow_effect,
        name,
        @core.Type::String,
        @core.Type::String,
      )
    "__add" => {
      let pos_args = extract_positional_args(args, "__add", call_span)
      if pos_args.length() != 2 {
        raise TypeError::BadCall(message="__add", span=call_span)
      }
      let a = type_expr_eff(env, pos_args[0], aliases, effects, allow_effect)
      let b = type_expr_eff(env, pos_args[1], aliases, effects, allow_effect)
      ensure_num_operand(env, a, pos_args[0].span())
      if not(type_equal(env, b, a)) {
        raise TypeError::Mismatch(
          expected=a,
          actual=b,
          span=pos_args[1].span(),
          context=Some("argument"),
        )
      }
      a
    }
    "__sub" => {
      let pos_args = extract_positional_args(args, "__sub", call_span)
      if pos_args.length() != 2 {
        raise TypeError::BadCall(message="__sub", span=call_span)
      }
      let a = type_expr_eff(env, pos_args[0], aliases, effects, allow_effect)
      let b = type_expr_eff(env, pos_args[1], aliases, effects, allow_effect)
      ensure_num_operand(env, a, pos_args[0].span())
      if not(type_equal(env, b, a)) {
        raise TypeError::Mismatch(
          expected=a,
          actual=b,
          span=pos_args[1].span(),
          context=Some("argument"),
        )
      }
      a
    }
    "__mul" => {
      let pos_args = extract_positional_args(args, "__mul", call_span)
      if pos_args.length() != 2 {
        raise TypeError::BadCall(message="__mul", span=call_span)
      }
      let a = type_expr_eff(env, pos_args[0], aliases, effects, allow_effect)
      let b = type_expr_eff(env, pos_args[1], aliases, effects, allow_effect)
      ensure_num_operand(env, a, pos_args[0].span())
      if not(type_equal(env, b, a)) {
        raise TypeError::Mismatch(
          expected=a,
          actual=b,
          span=pos_args[1].span(),
          context=Some("argument"),
        )
      }
      a
    }
    "__div" | "__mod" => {
      let pos_args = extract_positional_args(args, name, call_span)
      if pos_args.length() != 2 {
        raise TypeError::BadCall(message=name, span=call_span)
      }
      let a = type_expr_eff(env, pos_args[0], aliases, effects, allow_effect)
      let b = type_expr_eff(env, pos_args[1], aliases, effects, allow_effect)
      ensure_num_operand(env, a, pos_args[0].span())
      if not(type_equal(env, b, a)) {
        raise TypeError::Mismatch(
          expected=a,
          actual=b,
          span=pos_args[1].span(),
          context=Some("argument"),
        )
      }
      a
    }
    "__lshift" | "__rshift" | "__bit_and" | "__bit_or" | "__bit_xor" => {
      let pos_args = extract_positional_args(args, name, call_span)
      if pos_args.length() != 2 {
        raise TypeError::BadCall(message=name, span=call_span)
      }
      let a = type_expr_eff(env, pos_args[0], aliases, effects, allow_effect)
      let b = type_expr_eff(env, pos_args[1], aliases, effects, allow_effect)
      if not(type_equal(env, a, @core.Type::Int)) {
        raise TypeError::Mismatch(
          expected=@core.Type::Int,
          actual=a,
          span=pos_args[0].span(),
          context=Some("bit operation"),
        )
      }
      if not(type_equal(env, b, @core.Type::Int)) {
        raise TypeError::Mismatch(
          expected=@core.Type::Int,
          actual=b,
          span=pos_args[1].span(),
          context=Some("bit operation"),
        )
      }
      @core.Type::Int
    }
    "i32_eqz" =>
      type_check_unary_convert(
        env,
        args,
        call_span,
        aliases,
        effects,
        allow_effect,
        "i32_eqz",
        @core.Type::Int,
        @core.Type::Int,
      )
    "i32_eq" | "i32_ne" | "i32_lt_s" | "i32_le_s" | "i32_gt_s" | "i32_ge_s" =>
      type_check_binary_exact(
        env,
        args,
        call_span,
        aliases,
        effects,
        allow_effect,
        builtin_name,
        @core.Type::Int,
        @core.Type::Int,
        @core.Type::Int,
      )
    "f32_eq" | "f32_ne" | "f32_lt" | "f32_le" | "f32_gt" | "f32_ge" =>
      type_check_binary_exact(
        env,
        args,
        call_span,
        aliases,
        effects,
        allow_effect,
        builtin_name,
        @core.Type::Float,
        @core.Type::Float,
        @core.Type::Int,
      )
    "f64_eq" | "f64_ne" | "f64_lt" | "f64_le" | "f64_gt" | "f64_ge" =>
      type_check_binary_exact(
        env,
        args,
        call_span,
        aliases,
        effects,
        allow_effect,
        builtin_name,
        @core.Type::Double,
        @core.Type::Double,
        @core.Type::Int,
      )
    "anyref_eq"
    | "eqref_eq"
    | "i31ref_eq"
    | "structref_eq"
    | "arrayref_eq"
    | "funcref_eq"
    | "externref_eq" => {
      let ref_name = match @core.wasm_gc_ref_eq_type_name(builtin_name) {
        Some(t) => t
        None => raise TypeError::BadCall(message=builtin_name, span=call_span)
      }
      type_check_binary_exact(
        env,
        args,
        call_span,
        aliases,
        effects,
        allow_effect,
        builtin_name,
        @core.Type::Named(name=ref_name, args=[]),
        @core.Type::Named(name=ref_name, args=[]),
        @core.Type::Int,
      )
    }
    "__index" => {
      let pos_args = extract_positional_args(args, "__index", call_span)
      if pos_args.length() != 2 {
        raise TypeError::BadCall(message="__index", span=call_span)
      }
      let container_ty = type_expr_eff(
        env,
        pos_args[0],
        aliases,
        effects,
        allow_effect,
      )
      let index_ty = type_expr_eff(
        env,
        pos_args[1],
        aliases,
        effects,
        allow_effect,
      )
      let elem_ty = fresh_type_var(env)
      match container_ty {
        @core.Type::Array(_) => {
          if not(type_equal(env, index_ty, @core.Type::Int)) {
            raise TypeError::Mismatch(
              expected=@core.Type::Int,
              actual=index_ty,
              span=pos_args[1].span(),
              context=Some("index"),
            )
          }
          if not(type_equal(env, container_ty, @core.Type::Array(elem_ty))) {
            raise TypeError::Mismatch(
              expected=@core.Type::Array(elem_ty),
              actual=container_ty,
              span=pos_args[0].span(),
              context=Some("argument"),
            )
          }
          elem_ty
        }
        @core.Type::Map(_) => {
          if not(type_equal(env, index_ty, @core.Type::String)) {
            raise TypeError::Mismatch(
              expected=@core.Type::String,
              actual=index_ty,
              span=pos_args[1].span(),
              context=Some("index"),
            )
          }
          if not(type_equal(env, container_ty, @core.Type::Map(elem_ty))) {
            raise TypeError::Mismatch(
              expected=@core.Type::Map(elem_ty),
              actual=container_ty,
              span=pos_args[0].span(),
              context=Some("argument"),
            )
          }
          elem_ty
        }
        _ => {
          let _ = index_ty
          let _ = elem_ty
          raise TypeError::BadCall(
            message="__index: not indexable",
            span=call_span,
          )
        }
      }
    }
    "__eq" => {
      let pos_args = extract_positional_args(args, "__eq", call_span)
      if pos_args.length() != 2 {
        raise TypeError::BadCall(message="__eq", span=call_span)
      }
      let a = type_expr_eff(env, pos_args[0], aliases, effects, allow_effect)
      let b = type_expr_eff(env, pos_args[1], aliases, effects, allow_effect)
      ensure_eq_operand(env, a, pos_args[0].span())
      ensure_eq_operand(env, b, pos_args[1].span())
      if not(type_equal(env, b, a)) && not(int_char_comparable_pair(env, a, b)) {
        raise TypeError::Mismatch(
          expected=a,
          actual=b,
          span=pos_args[1].span(),
          context=Some("argument"),
        )
      }
      @core.Type::Bool
    }
    "__lt" => {
      let pos_args = extract_positional_args(args, "__lt", call_span)
      if pos_args.length() != 2 {
        raise TypeError::BadCall(message="__lt", span=call_span)
      }
      let a = type_expr_eff(env, pos_args[0], aliases, effects, allow_effect)
      let b = type_expr_eff(env, pos_args[1], aliases, effects, allow_effect)
      ensure_ord_operand(env, a, pos_args[0].span())
      ensure_ord_operand(env, b, pos_args[1].span())
      if not(type_equal(env, b, a)) && not(int_char_comparable_pair(env, a, b)) {
        raise TypeError::Mismatch(
          expected=a,
          actual=b,
          span=pos_args[1].span(),
          context=Some("argument"),
        )
      }
      @core.Type::Bool
    }
    "__neg" => {
      let pos_args = extract_positional_args(args, "__neg", call_span)
      if pos_args.length() != 1 {
        raise TypeError::BadCall(message="__neg", span=call_span)
      }
      let a = type_expr_eff(env, pos_args[0], aliases, effects, allow_effect)
      ensure_num_operand(env, a, pos_args[0].span())
      a
    }
    "__assert" => {
      let pos_args = extract_positional_args(args, "__assert", call_span)
      if pos_args.length() != 1 {
        raise TypeError::BadCall(message="__assert", span=call_span)
      }
      let a = type_expr_eff(env, pos_args[0], aliases, effects, allow_effect)
      if not(type_equal(env, a, @core.Type::Bool)) {
        raise TypeError::Mismatch(
          expected=@core.Type::Bool,
          actual=a,
          span=pos_args[0].span(),
          context=Some("argument"),
        )
      }
      @core.Type::Unit
    }
    "record_set" => {
      let pos_args = extract_positional_args(args, "record_set", call_span)
      if pos_args.length() != 3 {
        raise TypeError::BadCall(message="record_set", span=call_span)
      }
      let record_ty = normalize_type(
        env,
        type_expr_eff(env, pos_args[0], aliases, effects, allow_effect),
      )
      let field_ty = type_expr_eff(
        env,
        pos_args[1],
        aliases,
        effects,
        allow_effect,
      )
      if not(type_equal(env, field_ty, @core.Type::String)) {
        raise TypeError::Mismatch(
          expected=@core.Type::String,
          actual=field_ty,
          span=pos_args[1].span(),
          context=Some("record field name"),
        )
      }
      let value_ty = type_expr_eff(
        env,
        pos_args[2],
        aliases,
        effects,
        allow_effect,
      )
      match record_ty {
        @core.Type::Record(fields) =>
          match pos_args[1] {
            @core.Expr::String(value=name, span~) =>
              match fields.get(name) {
                Some(expect) =>
                  if not(type_equal(env, expect, value_ty)) {
                    raise TypeError::Mismatch(
                      expected=expect,
                      actual=value_ty,
                      span=pos_args[2].span(),
                      context=Some("record field value"),
                    )
                  }
                None => raise TypeError::BadCall(message="record_set", span~)
              }
            _ => ()
          }
        _ => raise TypeError::BadCall(message="record_set", span=call_span)
      }
      record_ty
    }
    "map_keys" => {
      let pos_args = extract_positional_args(args, "map_keys", call_span)
      if pos_args.length() != 1 {
        raise TypeError::BadCall(message="map_keys", span=call_span)
      }
      let map_ty = type_expr_eff(
        env,
        pos_args[0],
        aliases,
        effects,
        allow_effect,
      )
      let resolved = normalize_type(env, map_ty)
      match resolved {
        @core.Type::Map(_) => @core.Type::Array(@core.Type::String)
        _ => raise TypeError::BadCall(message="map_keys", span=call_span)
      }
    }
    "map_values" => {
      let pos_args = extract_positional_args(args, "map_values", call_span)
      if pos_args.length() != 1 {
        raise TypeError::BadCall(message="map_values", span=call_span)
      }
      let map_ty = type_expr_eff(
        env,
        pos_args[0],
        aliases,
        effects,
        allow_effect,
      )
      let resolved = normalize_type(env, map_ty)
      match resolved {
        @core.Type::Map(elem_ty) => @core.Type::Array(elem_ty)
        _ => raise TypeError::BadCall(message="map_values", span=call_span)
      }
    }
    "map_has_key" => {
      let pos_args = extract_positional_args(args, "map_has_key", call_span)
      if pos_args.length() != 2 {
        raise TypeError::BadCall(message="map_has_key", span=call_span)
      }
      let map_ty = type_expr_eff(
        env,
        pos_args[0],
        aliases,
        effects,
        allow_effect,
      )
      let resolved = normalize_type(env, map_ty)
      match resolved {
        @core.Type::Map(_) => ()
        _ => raise TypeError::BadCall(message="map_has_key", span=call_span)
      }
      let key_ty = type_expr_eff(
        env,
        pos_args[1],
        aliases,
        effects,
        allow_effect,
      )
      if not(type_equal(env, key_ty, @core.Type::String)) {
        raise TypeError::Mismatch(
          expected=@core.Type::String,
          actual=key_ty,
          span=pos_args[1].span(),
          context=Some("argument"),
        )
      }
      @core.Type::Bool
    }
    "array_slice" => {
      let pos_args = extract_positional_args(args, "array_slice", call_span)
      if pos_args.length() != 3 {
        raise TypeError::BadCall(message="array_slice", span=call_span)
      }
      let array_ty = type_expr_eff(
        env,
        pos_args[0],
        aliases,
        effects,
        allow_effect,
      )
      let resolved = normalize_type(env, array_ty)
      let elem_ty = match resolved {
        @core.Type::Array(elem_ty) => elem_ty
        _ => raise TypeError::BadCall(message="array_slice", span=call_span)
      }
      let start_ty = type_expr_eff(
        env,
        pos_args[1],
        aliases,
        effects,
        allow_effect,
      )
      if not(type_equal(env, start_ty, @core.Type::Int)) {
        raise TypeError::Mismatch(
          expected=@core.Type::Int,
          actual=start_ty,
          span=pos_args[1].span(),
          context=Some("argument"),
        )
      }
      let end_ty = type_expr_eff(
        env,
        pos_args[2],
        aliases,
        effects,
        allow_effect,
      )
      if not(type_equal(env, end_ty, @core.Type::Int)) {
        raise TypeError::Mismatch(
          expected=@core.Type::Int,
          actual=end_ty,
          span=pos_args[2].span(),
          context=Some("argument"),
        )
      }
      @core.Type::Array(elem_ty)
    }
    "int_to_float" | "f32_convert_i32_s" =>
      type_check_unary_convert(
        env,
        args,
        call_span,
        aliases,
        effects,
        allow_effect,
        name,
        @core.Type::Int,
        @core.Type::Float,
      )
    "int_to_double" | "f64_convert_i32_s" =>
      type_check_unary_convert(
        env,
        args,
        call_span,
        aliases,
        effects,
        allow_effect,
        name,
        @core.Type::Int,
        @core.Type::Double,
      )
    "float_to_int" | "i32_trunc_f32_s" =>
      type_check_unary_convert(
        env,
        args,
        call_span,
        aliases,
        effects,
        allow_effect,
        name,
        @core.Type::Float,
        @core.Type::Int,
      )
    "float_to_double" | "f64_promote_f32" =>
      type_check_unary_convert(
        env,
        args,
        call_span,
        aliases,
        effects,
        allow_effect,
        name,
        @core.Type::Float,
        @core.Type::Double,
      )
    "double_to_int" | "i32_trunc_f64_s" =>
      type_check_unary_convert(
        env,
        args,
        call_span,
        aliases,
        effects,
        allow_effect,
        name,
        @core.Type::Double,
        @core.Type::Int,
      )
    "double_to_float" | "f32_demote_f64" =>
      type_check_unary_convert(
        env,
        args,
        call_span,
        aliases,
        effects,
        allow_effect,
        name,
        @core.Type::Double,
        @core.Type::Float,
      )
    "i32_shr_u" => {
      let pos_args = extract_positional_args(args, name, call_span)
      if pos_args.length() != 2 {
        raise TypeError::BadCall(message=name, span=call_span)
      }
      let a = type_expr_eff(env, pos_args[0], aliases, effects, allow_effect)
      let b = type_expr_eff(env, pos_args[1], aliases, effects, allow_effect)
      if not(type_equal(env, a, @core.Type::Int)) {
        raise TypeError::Mismatch(
          expected=@core.Type::Int,
          actual=a,
          span=pos_args[0].span(),
          context=Some("bit operation"),
        )
      }
      if not(type_equal(env, b, @core.Type::Int)) {
        raise TypeError::Mismatch(
          expected=@core.Type::Int,
          actual=b,
          span=pos_args[1].span(),
          context=Some("bit operation"),
        )
      }
      @core.Type::Int
    }
    "f32_neg" =>
      type_check_unary_convert(
        env,
        args,
        call_span,
        aliases,
        effects,
        allow_effect,
        "f32_neg",
        @core.Type::Float,
        @core.Type::Float,
      )
    "f64_neg" =>
      type_check_unary_convert(
        env,
        args,
        call_span,
        aliases,
        effects,
        allow_effect,
        "f64_neg",
        @core.Type::Double,
        @core.Type::Double,
      )
    "i32_load" | "i32_load8_u" => {
      let pos_args = extract_positional_args(args, name, call_span)
      if pos_args.length() != 2 {
        raise TypeError::BadCall(message=name, span=call_span)
      }
      let base_ty = type_expr_eff(
        env,
        pos_args[0],
        aliases,
        effects,
        allow_effect,
      )
      if not(type_equal(env, base_ty, @core.Type::Int)) {
        raise TypeError::Mismatch(
          expected=@core.Type::Int,
          actual=base_ty,
          span=pos_args[0].span(),
          context=Some("argument"),
        )
      }
      let offset_ty = type_expr_eff(
        env,
        pos_args[1],
        aliases,
        effects,
        allow_effect,
      )
      if not(type_equal(env, offset_ty, @core.Type::Int)) {
        raise TypeError::Mismatch(
          expected=@core.Type::Int,
          actual=offset_ty,
          span=pos_args[1].span(),
          context=Some("argument"),
        )
      }
      @core.Type::Int
    }
    "i32_store" | "i32_store8" => {
      let pos_args = extract_positional_args(args, name, call_span)
      if pos_args.length() != 3 {
        raise TypeError::BadCall(message=name, span=call_span)
      }
      let base_ty = type_expr_eff(
        env,
        pos_args[0],
        aliases,
        effects,
        allow_effect,
      )
      if not(type_equal(env, base_ty, @core.Type::Int)) {
        raise TypeError::Mismatch(
          expected=@core.Type::Int,
          actual=base_ty,
          span=pos_args[0].span(),
          context=Some("argument"),
        )
      }
      let offset_ty = type_expr_eff(
        env,
        pos_args[1],
        aliases,
        effects,
        allow_effect,
      )
      if not(type_equal(env, offset_ty, @core.Type::Int)) {
        raise TypeError::Mismatch(
          expected=@core.Type::Int,
          actual=offset_ty,
          span=pos_args[1].span(),
          context=Some("argument"),
        )
      }
      let value_ty = type_expr_eff(
        env,
        pos_args[2],
        aliases,
        effects,
        allow_effect,
      )
      if not(type_equal(env, value_ty, @core.Type::Int)) {
        raise TypeError::Mismatch(
          expected=@core.Type::Int,
          actual=value_ty,
          span=pos_args[2].span(),
          context=Some("argument"),
        )
      }
      @core.Type::Unit
    }
    "f32_load" => {
      let pos_args = extract_positional_args(args, name, call_span)
      if pos_args.length() != 2 {
        raise TypeError::BadCall(message=name, span=call_span)
      }
      let base_ty = type_expr_eff(
        env,
        pos_args[0],
        aliases,
        effects,
        allow_effect,
      )
      if not(type_equal(env, base_ty, @core.Type::Int)) {
        raise TypeError::Mismatch(
          expected=@core.Type::Int,
          actual=base_ty,
          span=pos_args[0].span(),
          context=Some("argument"),
        )
      }
      let offset_ty = type_expr_eff(
        env,
        pos_args[1],
        aliases,
        effects,
        allow_effect,
      )
      if not(type_equal(env, offset_ty, @core.Type::Int)) {
        raise TypeError::Mismatch(
          expected=@core.Type::Int,
          actual=offset_ty,
          span=pos_args[1].span(),
          context=Some("argument"),
        )
      }
      @core.Type::Float
    }
    "f64_load" => {
      let pos_args = extract_positional_args(args, name, call_span)
      if pos_args.length() != 2 {
        raise TypeError::BadCall(message=name, span=call_span)
      }
      let base_ty = type_expr_eff(
        env,
        pos_args[0],
        aliases,
        effects,
        allow_effect,
      )
      if not(type_equal(env, base_ty, @core.Type::Int)) {
        raise TypeError::Mismatch(
          expected=@core.Type::Int,
          actual=base_ty,
          span=pos_args[0].span(),
          context=Some("argument"),
        )
      }
      let offset_ty = type_expr_eff(
        env,
        pos_args[1],
        aliases,
        effects,
        allow_effect,
      )
      if not(type_equal(env, offset_ty, @core.Type::Int)) {
        raise TypeError::Mismatch(
          expected=@core.Type::Int,
          actual=offset_ty,
          span=pos_args[1].span(),
          context=Some("argument"),
        )
      }
      @core.Type::Double
    }
    "f32_store" => {
      let pos_args = extract_positional_args(args, name, call_span)
      if pos_args.length() != 3 {
        raise TypeError::BadCall(message=name, span=call_span)
      }
      let base_ty = type_expr_eff(
        env,
        pos_args[0],
        aliases,
        effects,
        allow_effect,
      )
      if not(type_equal(env, base_ty, @core.Type::Int)) {
        raise TypeError::Mismatch(
          expected=@core.Type::Int,
          actual=base_ty,
          span=pos_args[0].span(),
          context=Some("argument"),
        )
      }
      let offset_ty = type_expr_eff(
        env,
        pos_args[1],
        aliases,
        effects,
        allow_effect,
      )
      if not(type_equal(env, offset_ty, @core.Type::Int)) {
        raise TypeError::Mismatch(
          expected=@core.Type::Int,
          actual=offset_ty,
          span=pos_args[1].span(),
          context=Some("argument"),
        )
      }
      let value_ty = type_expr_eff(
        env,
        pos_args[2],
        aliases,
        effects,
        allow_effect,
      )
      if not(type_equal(env, value_ty, @core.Type::Float)) {
        raise TypeError::Mismatch(
          expected=@core.Type::Float,
          actual=value_ty,
          span=pos_args[2].span(),
          context=Some("argument"),
        )
      }
      @core.Type::Unit
    }
    "f64_store" => {
      let pos_args = extract_positional_args(args, name, call_span)
      if pos_args.length() != 3 {
        raise TypeError::BadCall(message=name, span=call_span)
      }
      let base_ty = type_expr_eff(
        env,
        pos_args[0],
        aliases,
        effects,
        allow_effect,
      )
      if not(type_equal(env, base_ty, @core.Type::Int)) {
        raise TypeError::Mismatch(
          expected=@core.Type::Int,
          actual=base_ty,
          span=pos_args[0].span(),
          context=Some("argument"),
        )
      }
      let offset_ty = type_expr_eff(
        env,
        pos_args[1],
        aliases,
        effects,
        allow_effect,
      )
      if not(type_equal(env, offset_ty, @core.Type::Int)) {
        raise TypeError::Mismatch(
          expected=@core.Type::Int,
          actual=offset_ty,
          span=pos_args[1].span(),
          context=Some("argument"),
        )
      }
      let value_ty = type_expr_eff(
        env,
        pos_args[2],
        aliases,
        effects,
        allow_effect,
      )
      if not(type_equal(env, value_ty, @core.Type::Double)) {
        raise TypeError::Mismatch(
          expected=@core.Type::Double,
          actual=value_ty,
          span=pos_args[2].span(),
          context=Some("argument"),
        )
      }
      @core.Type::Unit
    }
    "__to_string" => {
      let pos_args = extract_positional_args(args, "__to_string", call_span)
      if pos_args.length() != 1 {
        raise TypeError::BadCall(message="__to_string", span=call_span)
      }
      let _ = type_expr_eff(env, pos_args[0], aliases, effects, allow_effect)
      @core.Type::String
    }
    "string_join" =>
      check_builtin_simple(
        env,
        "string_join",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Array(@core.Type::String), @core.Type::String],
        @core.Type::String,
        false,
      )
    "from_lines" =>
      check_builtin_simple(
        env,
        "from_lines",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String],
        @core.Type::Array(@core.Type::String),
        false,
      )
    "to_lines" =>
      check_builtin_simple(
        env,
        "to_lines",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Array(@core.Type::String)],
        @core.Type::String,
        false,
      )
    "to_json" =>
      check_builtin_simple(
        env,
        "to_json",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [builtin_json_type()],
        @core.Type::String,
        false,
      )
    "from_json" =>
      check_builtin_simple(
        env,
        "from_json",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String],
        builtin_json_type(),
        false,
      )
    "to_jsonl" =>
      check_builtin_simple(
        env,
        "to_jsonl",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Array(builtin_json_type())],
        @core.Type::String,
        false,
      )
    "from_jsonl" =>
      check_builtin_simple(
        env,
        "from_jsonl",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String],
        @core.Type::Array(builtin_json_type()),
        false,
      )
    "json_type" | "json_string" =>
      check_builtin_simple(
        env,
        name,
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [builtin_json_type()],
        @core.Type::String,
        false,
      )
    "json_get" =>
      check_builtin_simple(
        env,
        "json_get",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [builtin_json_type(), @core.Type::String],
        builtin_json_type(),
        false,
      )
    "json_index" =>
      check_builtin_simple(
        env,
        "json_index",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [builtin_json_type(), @core.Type::Int],
        builtin_json_type(),
        false,
      )
    "json_number" =>
      check_builtin_simple(
        env,
        "json_number",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [builtin_json_type()],
        @core.Type::Double,
        false,
      )
    "json_bool" | "json_is_null" =>
      check_builtin_simple(
        env,
        name,
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [builtin_json_type()],
        @core.Type::Bool,
        false,
      )
    "json_length" =>
      check_builtin_simple(
        env,
        "json_length",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [builtin_json_type()],
        @core.Type::Int,
        false,
      )
    "json_keys" =>
      check_builtin_simple(
        env,
        "json_keys",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [builtin_json_type()],
        @core.Type::Array(@core.Type::String),
        false,
      )
    _ =>
      // Try to interpret as field access: x(p) where p is a record/struct
      // and x is a field name
      match
        try_field_access(
          env, name, args, aliases, effects, allow_effect, call_span,
        ) {
        Some(ty) => ty
        None => raise TypeError::BadCall(message=name, span=call_span)
      }
  }
}
