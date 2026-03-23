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
  let ctx = BuiltinCallCtx::{
    env,
    args,
    aliases,
    effects,
    allow_effect,
    call_span,
  }
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
      ctx.simple(
        "String::join",
        [@core.Type::Array(@core.Type::String), @core.Type::String],
        @core.Type::String,
        false,
      )
    "Lines::parse" =>
      ctx.simple(
        "Lines::parse",
        [@core.Type::String],
        @core.Type::Array(@core.Type::String),
        false,
      )
    "Lines::stringify" =>
      ctx.simple(
        "Lines::stringify",
        [@core.Type::Array(@core.Type::String)],
        @core.Type::String,
        false,
      )
    "Json::stringify" =>
      ctx.simple(
        "Json::stringify",
        [builtin_json_type()],
        @core.Type::String,
        false,
      )
    "Json::parse" =>
      ctx.simple(
        "Json::parse",
        [@core.Type::String],
        builtin_json_type(),
        false,
      )
    "Json::stringify_lines" =>
      ctx.simple(
        "Json::stringify_lines",
        [@core.Type::Array(builtin_json_type())],
        @core.Type::String,
        false,
      )
    "Json::parse_lines" =>
      ctx.simple(
        "Json::parse_lines",
        [@core.Type::String],
        @core.Type::Array(builtin_json_type()),
        false,
      )
    "Json::type_of" | "Json::string" =>
      ctx.simple(name, [builtin_json_type()], @core.Type::String, false)
    "Json::get" =>
      ctx.simple(
        "Json::get",
        [builtin_json_type(), @core.Type::String],
        builtin_json_type(),
        false,
      )
    "Json::index" =>
      ctx.simple(
        "Json::index",
        [builtin_json_type(), @core.Type::Int],
        builtin_json_type(),
        false,
      )
    "Json::number" =>
      ctx.simple(
        "Json::number",
        [builtin_json_type()],
        @core.Type::Double,
        false,
      )
    "Json::bool" | "Json::is_null" =>
      ctx.simple(name, [builtin_json_type()], @core.Type::Bool, false)
    "Json::length" =>
      ctx.simple("Json::length", [builtin_json_type()], @core.Type::Int, false)
    "Json::keys" =>
      ctx.simple(
        "Json::keys",
        [builtin_json_type()],
        @core.Type::Array(@core.Type::String),
        false,
      )
    _ => raise TypeError::BadCall(message=name, span=call_span)
  }
}
