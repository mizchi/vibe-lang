///|
fn type_call_builtin_handler_core_io(
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
    "path" | "Path::ref" =>
      ctx.simple(name, [@core.Type::String], @core.Type::Path, false)
    "Path::to_string" =>
      ctx.simple(
        "Path::to_string",
        [@core.Type::Path],
        @core.Type::String,
        false,
      )
    "Path::is_absolute" =>
      ctx.simple(
        "Path::is_absolute",
        [@core.Type::Path],
        @core.Type::Bool,
        false,
      )
    "PromptText::new" => {
      let pos_args = prepare_builtin_pos_args(
        env, "PromptText::new", args, 1, effects, allow_effect, call_span, false,
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
    "PromptText::to_string" =>
      ctx.simple(
        "PromptText::to_string",
        [@core.Type::PromptText],
        @core.Type::String,
        false,
      )
    "Path::resolve" =>
      ctx.simple("Path::resolve", [@core.Type::String], @core.Type::Path, true)
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
    "sh" => ctx.simple("sh", [@core.Type::String], @core.Type::Unit, true)
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
      if !type_equal(env, arg_ty, @core.Type::String) {
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
        if !type_equal(env, lty, @core.Type::Bool) {
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
        if !type_equal(env, arg_ty, @core.Type::String) {
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
    "sleep" => ctx.simple("sleep", [@core.Type::Int], @core.Type::Unit, true)
    "Stdout::write_char" =>
      ctx.simple(
        "Stdout::write_char",
        [@core.Type::Int],
        @core.Type::Unit,
        true,
      )
    "Stdin::read_char" =>
      ctx.simple("Stdin::read_char", [], @core.Type::Int, true)
    "Stdout::write_stream" =>
      ctx.simple(
        "Stdout::write_stream",
        [@core.Type::String],
        @core.Type::Unit,
        true,
      )
    "Stdin::read_stream" =>
      ctx.simple(
        "Stdin::read_stream",
        [@core.Type::Int],
        @core.Type::String,
        true,
      )
    "Fs::read_file" | "Fs::read_string" =>
      ctx.simple(name, [@core.Type::String], @core.Type::String, true)
    "Fs::write_file" | "Fs::write_string" =>
      ctx.simple(
        name,
        [@core.Type::String, @core.Type::String],
        @core.Type::Unit,
        true,
      )
    "Fs::read_bytes" =>
      ctx.simple(
        "Fs::read_bytes",
        [@core.Type::String],
        @core.Type::Bytes,
        true,
      )
    "Fs::write_bytes" =>
      ctx.simple(
        "Fs::write_bytes",
        [@core.Type::String, @core.Type::Bytes],
        @core.Type::Unit,
        true,
      )
    "Fs::exists" =>
      ctx.simple("Fs::exists", [@core.Type::String], @core.Type::Bool, true)
    "Fs::stat_token" =>
      ctx.simple("Fs::stat_token", [@core.Type::String], @core.Type::Int, true)
    "Fs::readdir" =>
      ctx.simple(
        "Fs::readdir",
        [@core.Type::String],
        @core.Type::Array(@core.Type::String),
        true,
      )
    "Fs::is_dir" =>
      ctx.simple("Fs::is_dir", [@core.Type::String], @core.Type::Bool, true)
    "Fs::mkdir" | "Fs::mkdir_p" =>
      ctx.simple(name, [@core.Type::String], @core.Type::Unit, true)
    "Fs::getcwd" => ctx.simple("Fs::getcwd", [], @core.Type::String, true)
    "Fs::chdir" =>
      ctx.simple("Fs::chdir", [@core.Type::String], @core.Type::Unit, true)
    "Fs::remove" =>
      ctx.simple("Fs::remove", [@core.Type::String], @core.Type::Unit, true)
    "Fs::is_file" =>
      ctx.simple("Fs::is_file", [@core.Type::String], @core.Type::Bool, true)
    "Fs::copy" | "Fs::rename" =>
      ctx.simple(
        name,
        [@core.Type::String, @core.Type::String],
        @core.Type::Unit,
        true,
      )
    "Fs::append" =>
      ctx.simple(
        "Fs::append",
        [@core.Type::String, @core.Type::String],
        @core.Type::Unit,
        true,
      )
    "Fs::open_write" =>
      ctx.simple("Fs::open_write", [@core.Type::String], @core.Type::Int, true)
    "Fs::write_chunk" =>
      ctx.simple(
        "Fs::write_chunk",
        [@core.Type::Int, @core.Type::String],
        @core.Type::Unit,
        true,
      )
    "Fs::close_write" =>
      ctx.simple("Fs::close_write", [@core.Type::Int], @core.Type::Unit, true)
    "Env::get" =>
      ctx.simple("Env::get", [@core.Type::String], @core.Type::String, true)
    "Env::args_len" => ctx.simple("Env::args_len", [], @core.Type::Int, true)
    "Env::args_get" =>
      ctx.simple("Env::args_get", [@core.Type::Int], @core.Type::String, true)
    "Socket::tcp_connect" =>
      ctx.simple(
        "Socket::tcp_connect",
        [@core.Type::String, @core.Type::Int],
        @core.Type::Int,
        true,
      )
    "Socket::tcp_read" =>
      ctx.simple(
        "Socket::tcp_read",
        [@core.Type::Int, @core.Type::Int],
        @core.Type::String,
        true,
      )
    "Socket::tcp_write" =>
      ctx.simple(
        "Socket::tcp_write",
        [@core.Type::Int, @core.Type::String],
        @core.Type::Unit,
        true,
      )
    "Socket::tcp_close" =>
      ctx.simple("Socket::tcp_close", [@core.Type::Int], @core.Type::Unit, true)
    // --- HTTP Client builtins ---
    "Http::request" =>
      ctx.simple(
        "Http::request",
        [
          @core.Type::String,
          @core.Type::String,
          @core.Type::String,
          @core.Type::String,
        ],
        @core.Type::Int,
        true,
      )
    "Http::response_status" =>
      ctx.simple(
        "Http::response_status",
        [@core.Type::Int],
        @core.Type::Int,
        true,
      )
    "Http::response_header" =>
      ctx.simple(
        "Http::response_header",
        [@core.Type::Int, @core.Type::String],
        @core.Type::String,
        true,
      )
    "Http::response_body" =>
      ctx.simple(
        "Http::response_body",
        [@core.Type::Int],
        @core.Type::String,
        true,
      )
    "Http::close" =>
      ctx.simple("Http::close", [@core.Type::Int], @core.Type::Unit, true)
    // --- HTTP Server builtins ---
    "Http::listen" =>
      ctx.simple("Http::listen", [@core.Type::Int], @core.Type::Int, true)
    "Http::accept" =>
      ctx.simple("Http::accept", [@core.Type::Int], @core.Type::Int, true)
    "Http::request_method" | "Http::request_url" | "Http::request_body" =>
      ctx.simple(name, [@core.Type::Int], @core.Type::String, true)
    "Http::request_header" =>
      ctx.simple(
        "Http::request_header",
        [@core.Type::Int, @core.Type::String],
        @core.Type::String,
        true,
      )
    "Http::respond" =>
      ctx.simple(
        "Http::respond",
        [
          @core.Type::Int,
          @core.Type::Int,
          @core.Type::String,
          @core.Type::String,
        ],
        @core.Type::Unit,
        true,
      )
    "Llm::complete" => {
      // (system: String, user: String) -> String with { Llm }
      let pos_args = prepare_builtin_pos_args(
        env, "Llm::complete", args, 2, effects, allow_effect, call_span, true,
      )
      for arg in pos_args {
        let _ = check_arg_string_or_prompt_text(
          env, arg, aliases, effects, allow_effect,
        )
      }
      @core.Type::String
    }
    "Rlm::run" => {
      // (task: String, prompt: String|PromptText) -> String with { Llm }
      let pos_args = prepare_builtin_pos_args(
        env, "Rlm::run", args, 2, effects, allow_effect, call_span, true,
      )
      for arg in pos_args {
        let _ = check_arg_string_or_prompt_text(
          env, arg, aliases, effects, allow_effect,
        )
      }
      @core.Type::String
    }
    "Rlm::finalize" =>
      ctx.simple(
        "Rlm::finalize",
        [@core.Type::String],
        @core.Type::String,
        false,
      )
    _ =>
      type_call_builtin_handler_collection_numeric(
        env, name, builtin_name, args, aliases, effects, allow_effect, call_span,
      )
  }
}
