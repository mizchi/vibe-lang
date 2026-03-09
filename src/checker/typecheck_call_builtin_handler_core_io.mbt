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
  match builtin_name {
    "path" | "Path::ref" =>
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
    "Path::to_string" =>
      check_builtin_simple(
        env,
        "Path::to_string",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Path],
        @core.Type::String,
        false,
      )
    "Path::is_absolute" =>
      check_builtin_simple(
        env,
        "Path::is_absolute",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
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
      check_builtin_simple(
        env,
        "PromptText::to_string",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::PromptText],
        @core.Type::String,
        false,
      )
    "Path::resolve" =>
      check_builtin_simple(
        env,
        "Path::resolve",
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
    "Threads::probe_wat" =>
      check_builtin_simple(
        env,
        "Threads::probe_wat",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [],
        @core.Type::String,
        true,
      )
    "Threads::runtime_hints" => {
      require_effect_guard(
        env,
        effects,
        allow_effect,
        "Threads::runtime_hints",
        builtin_effects("Threads::runtime_hints"),
        call_span,
      )
      let pos_args = extract_positional_args(
        args, "Threads::runtime_hints", call_span,
      )
      if pos_args.length() != 0 {
        raise TypeError::BadCall(
          message="Threads::runtime_hints",
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
    "Threads::channel_new" =>
      check_builtin_simple(
        env,
        "Threads::channel_new",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Int],
        @core.Type::Int,
        true,
      )
    "Threads::send" =>
      check_builtin_simple(
        env,
        "Threads::send",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Int, @core.Type::String],
        @core.Type::Bool,
        true,
      )
    "Threads::recv" =>
      check_builtin_simple(
        env,
        "Threads::recv",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Int],
        @core.Type::String,
        true,
      )
    "Threads::spawn" => {
      require_effect_guard(
        env,
        effects,
        allow_effect,
        "Threads::spawn",
        builtin_effects("Threads::spawn"),
        call_span,
      )
      let pos_args = extract_positional_args(args, "Threads::spawn", call_span)
      if pos_args.length() != 2 {
        raise TypeError::BadCall(message="Threads::spawn", span=call_span)
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
    "Threads::wait" =>
      check_builtin_simple(
        env,
        "Threads::wait",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Int],
        @core.Type::Int,
        true,
      )
    "Stdout::write_char" =>
      check_builtin_simple(
        env,
        "Stdout::write_char",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Int],
        @core.Type::Unit,
        true,
      )
    "Stdin::read_char" =>
      check_builtin_simple(
        env,
        "Stdin::read_char",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [],
        @core.Type::Int,
        true,
      )
    "Stdout::write_stream" =>
      check_builtin_simple(
        env,
        "Stdout::write_stream",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String],
        @core.Type::Unit,
        true,
      )
    "Stdin::read_stream" =>
      check_builtin_simple(
        env,
        "Stdin::read_stream",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Int],
        @core.Type::String,
        true,
      )
    "Fs::read_file" | "Fs::read_string" =>
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
        true,
      )
    "Fs::write_file" | "Fs::write_string" =>
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
    "Fs::read_bytes" =>
      check_builtin_simple(
        env,
        "Fs::read_bytes",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String],
        @core.Type::Bytes,
        true,
      )
    "Fs::write_bytes" =>
      check_builtin_simple(
        env,
        "Fs::write_bytes",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String, @core.Type::Bytes],
        @core.Type::Unit,
        true,
      )
    "Fs::exists" =>
      check_builtin_simple(
        env,
        "Fs::exists",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String],
        @core.Type::Bool,
        true,
      )
    "Fs::readdir" =>
      check_builtin_simple(
        env,
        "Fs::readdir",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String],
        @core.Type::Array(@core.Type::String),
        true,
      )
    "Fs::is_dir" =>
      check_builtin_simple(
        env,
        "Fs::is_dir",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String],
        @core.Type::Bool,
        true,
      )
    "Fs::mkdir" | "Fs::mkdir_p" =>
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
    "Fs::getcwd" =>
      check_builtin_simple(
        env,
        "Fs::getcwd",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [],
        @core.Type::String,
        true,
      )
    "Fs::chdir" =>
      check_builtin_simple(
        env,
        "Fs::chdir",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String],
        @core.Type::Unit,
        true,
      )
    "Fs::remove" =>
      check_builtin_simple(
        env,
        "Fs::remove",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String],
        @core.Type::Unit,
        true,
      )
    "Fs::is_file" =>
      check_builtin_simple(
        env,
        "Fs::is_file",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String],
        @core.Type::Bool,
        true,
      )
    "Fs::copy" | "Fs::rename" =>
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
    "Fs::append" =>
      check_builtin_simple(
        env,
        "Fs::append",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String, @core.Type::String],
        @core.Type::Unit,
        true,
      )
    "Env::get" =>
      check_builtin_simple(
        env,
        "Env::get",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String],
        @core.Type::String,
        true,
      )
    "Socket::tcp_connect" =>
      check_builtin_simple(
        env,
        "Socket::tcp_connect",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String, @core.Type::Int],
        @core.Type::Int,
        true,
      )
    "Socket::tcp_read" =>
      check_builtin_simple(
        env,
        "Socket::tcp_read",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Int, @core.Type::Int],
        @core.Type::String,
        true,
      )
    "Socket::tcp_write" =>
      check_builtin_simple(
        env,
        "Socket::tcp_write",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Int, @core.Type::String],
        @core.Type::Unit,
        true,
      )
    "Socket::tcp_close" =>
      check_builtin_simple(
        env,
        "Socket::tcp_close",
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
    "Http::request" =>
      check_builtin_simple(
        env,
        "Http::request",
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
    "Http::response_status" =>
      check_builtin_simple(
        env,
        "Http::response_status",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Int],
        @core.Type::Int,
        true,
      )
    "Http::response_header" =>
      check_builtin_simple(
        env,
        "Http::response_header",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Int, @core.Type::String],
        @core.Type::String,
        true,
      )
    "Http::response_body" =>
      check_builtin_simple(
        env,
        "Http::response_body",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Int],
        @core.Type::String,
        true,
      )
    "Http::close" =>
      check_builtin_simple(
        env,
        "Http::close",
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
    "Http::listen" =>
      check_builtin_simple(
        env,
        "Http::listen",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Int],
        @core.Type::Int,
        true,
      )
    "Http::accept" =>
      check_builtin_simple(
        env,
        "Http::accept",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Int],
        @core.Type::Int,
        true,
      )
    "Http::request_method" | "Http::request_url" | "Http::request_body" =>
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
    "Http::request_header" =>
      check_builtin_simple(
        env,
        "Http::request_header",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Int, @core.Type::String],
        @core.Type::String,
        true,
      )
    "Http::respond" =>
      check_builtin_simple(
        env,
        "Http::respond",
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
      check_builtin_simple(
        env,
        "Rlm::finalize",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
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
