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
    "String::join" =>
      check_builtin_simple(
        env,
        "String::join",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Array(@core.Type::String), @core.Type::String],
        @core.Type::String,
        false,
      )
    "Lines::parse" =>
      check_builtin_simple(
        env,
        "Lines::parse",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String],
        @core.Type::Array(@core.Type::String),
        false,
      )
    "Lines::stringify" =>
      check_builtin_simple(
        env,
        "Lines::stringify",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Array(@core.Type::String)],
        @core.Type::String,
        false,
      )
    "Json::stringify" =>
      check_builtin_simple(
        env,
        "Json::stringify",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [builtin_json_type()],
        @core.Type::String,
        false,
      )
    "Json::parse" =>
      check_builtin_simple(
        env,
        "Json::parse",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String],
        builtin_json_type(),
        false,
      )
    "Json::stringify_lines" =>
      check_builtin_simple(
        env,
        "Json::stringify_lines",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Array(builtin_json_type())],
        @core.Type::String,
        false,
      )
    "Json::parse_lines" =>
      check_builtin_simple(
        env,
        "Json::parse_lines",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String],
        @core.Type::Array(builtin_json_type()),
        false,
      )
    "Json::type_of" | "Json::string" =>
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
    "Json::get" =>
      check_builtin_simple(
        env,
        "Json::get",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [builtin_json_type(), @core.Type::String],
        builtin_json_type(),
        false,
      )
    "Json::index" =>
      check_builtin_simple(
        env,
        "Json::index",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [builtin_json_type(), @core.Type::Int],
        builtin_json_type(),
        false,
      )
    "Json::number" =>
      check_builtin_simple(
        env,
        "Json::number",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [builtin_json_type()],
        @core.Type::Double,
        false,
      )
    "Json::bool" | "Json::is_null" =>
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
    "Json::length" =>
      check_builtin_simple(
        env,
        "Json::length",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [builtin_json_type()],
        @core.Type::Int,
        false,
      )
    "Json::keys" =>
      check_builtin_simple(
        env,
        "Json::keys",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [builtin_json_type()],
        @core.Type::Array(@core.Type::String),
        false,
      )
    _ => raise TypeError::BadCall(message=name, span=call_span)
  }
}
