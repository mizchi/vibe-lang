///|
fn type_call_builtin_handler_json_and_fallback(
  env : TypeEnv,
  name : String,
  args : Array[@core.CallArg],
  aliases : Map[String, @core.Ref],
  effects : EffectScope,
  allow_effect : Bool,
  call_span : @core.Span,
) -> @core.Type raise TypeError {
  match @core.lower_wasm_intrinsic_name(name) {
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
