///|
fn scan_needs_expr(ctx : CodegenCtx, expr : @core.Expr) -> Unit {
  match expr {
    @core.Expr::Call(name~, args~, span~, ..) => {
      let _ = span
      match name {
        "sh" => ctx.need_sh = true
        "path" | "Path::ref" => ctx.need_path = true
        "Path::resolve" => ctx.need_dynamic_path_resolve = true
        "Env::get" => ctx.need_env_get = true
        "Env::args_len" => ctx.need_env_args_len = true
        "Env::args_get" => ctx.need_env_args_get = true
        "String::length" => if ctx.use_js_strings { ctx.need_js_length = true }
        "String::char_code_at" =>
          if ctx.use_js_strings {
            ctx.need_js_char_code_at = true
          }
        "String::substring" =>
          if ctx.use_js_strings {
            ctx.need_js_substring = true
          } else {
            ctx.need_heap = true
          }
        "String::concat" =>
          if ctx.use_js_strings {
            ctx.need_js_concat = true
          } else {
            ctx.need_heap = true
          }
        "String::equals" | "Map::get" =>
          if ctx.use_js_strings {
            ctx.need_js_equals = true
          }
        "ArrayBuilder::new"
        | "MapBuilder::new"
        | "StringBuilder::new"
        | "String::join"
        | "Map::keys"
        | "Map::values"
        | "String::trim"
        | "String::trim_start"
        | "String::trim_end"
        | "String::to_upper"
        | "String::to_lower"
        | "String::replace"
        | "String::replace_all"
        | "String::split"
        | "Bytes::new"
        | "Bytes::push"
        | "Bytes::append"
        | "Bytes::blit"
        | "Bytes::fill"
        | "Bytes::slice"
        | "Bytes::concat"
        | "Bytes::from_string"
        | "Bytes::to_string" => ctx.need_heap = true
        "sleep" => ctx.need_sleep = true
        "Stdout::write_char" | "Stdout::write_stream" =>
          ctx.need_stdout_write_char = true
        "Stdin::read_char" | "Stdin::read_stream" =>
          ctx.need_stdin_read_char = true
        "Fs::read_file"
        | "Fs::write_file"
        | "Fs::write_bytes"
        | "Fs::exists"
        | "Fs::stat_token"
        | "Fs::readdir"
        | "Fs::getcwd"
        | "Fs::chdir"
        | "Fs::is_dir"
        | "Fs::is_file"
        | "Fs::mkdir"
        | "Fs::mkdir_p"
        | "Fs::remove"
        | "Fs::rename"
        | "Fs::copy"
        | "Fs::append"
        | "Fs::open_write"
        | "Fs::write_chunk"
        | "Fs::close_write" => {
          ctx.need_fs = true
          ctx.need_heap = true
        }
        "Socket::tcp_connect"
        | "Socket::tcp_read"
        | "Socket::tcp_write"
        | "Socket::tcp_close" => {
          ctx.need_socket = true
          ctx.need_heap = true
        }
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
        | "Http::respond" => {
          ctx.need_http = true
          ctx.need_heap = true
          ctx.need_exceptions = true
        }
        "String::from_char_code"
        | "to_double"
        | "Int::parse"
        | "Double::parse"
        | "__slice" => ctx.need_heap = true
        "Char::to_int" | "Char::from_int" => ()
        "__to_string" => if not(ctx.use_js_strings) { ctx.need_heap = true }
        _ =>
          if is_wasm_runtime_fallback_builtin(name) {
            ctx.need_exceptions = true
          } else if ctx.enum_ctor_tags.contains(name) {
            // Enum constructor calls require heap allocation.
            ctx.need_heap = true
          }
      }
      for arg in args {
        scan_needs_expr(ctx, arg.expr)
      }
    }
    @core.Expr::Tuple(items~, span~) => {
      let _ = span
      ctx.need_heap = true
      for item in items {
        scan_needs_expr(ctx, item)
      }
    }
    @core.Expr::TupleIndex(expr~, ..) => {
      ctx.need_heap = true
      scan_needs_expr(ctx, expr)
    }
    @core.Expr::Record(fields~, span~) => {
      let _ = span
      ctx.need_heap = true
      for field in fields {
        scan_needs_expr(ctx, field.expr)
      }
    }
    @core.Expr::Array(items~, span~) => {
      let _ = span
      ctx.need_heap = true
      for item in items {
        scan_needs_expr(ctx, item)
      }
    }
    @core.Expr::Map(fields~, span~) => {
      let _ = span
      ctx.need_heap = true
      for field in fields {
        scan_needs_expr(ctx, field.expr)
      }
    }
    @core.Expr::If(cond~, then_body~, else_body~, span~) => {
      let _ = span
      scan_needs_expr(ctx, cond)
      scan_needs_block(ctx, then_body)
      scan_needs_block(ctx, else_body)
    }
    @core.Expr::Block(body~, span~) => {
      let _ = span
      scan_needs_block(ctx, body)
    }
    @core.Expr::Handle(body~, arms~, span~) => {
      let _ = span
      ctx.need_exceptions = true
      scan_needs_block(ctx, body)
      for arm in arms {
        // Detect effect handler arms (Effect::Op pattern)
        match arm.pat {
          @core.Pat::Ctor(name~, ..) if name.contains("::") => {
            ctx.need_effect_resume = true
            ctx.effect_handled_ops[name] = true
          }
          _ => ()
        }
        scan_needs_expr(ctx, arm.expr)
        match arm.cond {
          Some(c) => scan_needs_expr(ctx, c)
          None => ()
        }
      }
    }
    @core.Expr::Match(scrutinee~, arms~, span~) => {
      let _ = span
      scan_needs_expr(ctx, scrutinee)
      for arm in arms {
        scan_needs_expr(ctx, arm.expr)
        match arm.cond {
          Some(c) => scan_needs_expr(ctx, c)
          None => ()
        }
      }
    }
    @core.Expr::Fn(params~, ret~, effects=_, body~, span~, ..) => {
      let _ = ret
      let key = span_key_unique(span, params)
      match ctx.fn_closure_captures.get(key) {
        Some(captures) => if captures.length() > 0 { ctx.need_heap = true }
        None => ()
      }
      scan_needs_block(ctx, body)
    }
    @core.Expr::Yield(expr~, span~) => {
      let _ = span
      ctx.need_stack_switching = true
      scan_needs_expr(ctx, expr)
    }
    @core.Expr::While(cond~, body~, span~) => {
      let _ = span
      scan_needs_expr(ctx, cond)
      scan_needs_block(ctx, body)
    }
    @core.Expr::Loop(params~, body~, span~) => {
      let _ = span
      for param in params {
        scan_needs_expr(ctx, param.init)
      }
      scan_needs_block(ctx, body)
    }
    @core.Expr::StructLit(fields~, span~, ..) => {
      let _ = span
      ctx.need_heap = true
      for field in fields {
        scan_needs_expr(ctx, field.expr)
      }
    }
    @core.Expr::ForIn(value_name~, index_name~, iterable~, body~, span~) => {
      let desugared = @core.desugar_for_in(
        value_name, index_name, iterable, body, span,
      )
      scan_needs_block(ctx, desugared)
    }
    @core.Expr::Perform(effect_name="Error", op_name="Throw", args~, ..) => {
      ctx.need_exceptions = true
      for arg in args {
        scan_needs_expr(ctx, arg.expr)
      }
    }
    @core.Expr::Perform(effect_name~, op_name~, args~, ..) => {
      let key = effect_name + "::" + op_name
      // Only register as import if not a user-defined effect (handled by throw/catch)
      if not(ctx.effect_op_imports.contains(key)) &&
        not(ctx.effect_handled_ops.contains(key)) {
        ctx.effect_op_imports[key] = -1
        ctx.effect_op_param_counts[key] = args.length()
      }
      ctx.need_exceptions = true
      for arg in args {
        scan_needs_expr(ctx, arg.expr)
      }
    }
    _ => ()
  }
}

///|
fn scan_needs_block(ctx : CodegenCtx, body : @core.Module) -> Unit {
  for stmt in body.stmts {
    scan_needs_stmt(ctx, stmt)
  }
}

///|
fn scan_needs_stmt(ctx : CodegenCtx, stmt : @core.Stmt) -> Unit {
  match stmt {
    @core.Stmt::Let(rec~, name~, expr~, span~) => {
      let _ = span
      let _ = rec
      let _ = name
      scan_needs_expr(ctx, expr)
    }
    @core.Stmt::EnumDef(name=enum_name, params~, ctors~, span~) => {
      let _ = params
      let _ = span
      for i in 0..<ctors.length() {
        let ctor = ctors[i]
        if not(ctx.enum_ctor_tags.contains(ctor.name)) {
          ctx.enum_ctor_tags[ctor.name] = ctx.next_ctor_tag
          ctx.next_ctor_tag += 1
        }
        ctx.enum_ctor_arities[ctor.name] = ctor.args.length()
        let arg_kinds : Array[ValueKind] = []
        for arg in ctor.args {
          arg_kinds.push(value_kind_from_type(ctx, arg))
        }
        ctx.enum_ctor_arg_kinds[ctor.name] = arg_kinds
        // Register qualified form: EnumName::CtorName
        let qualified_ctor = enum_name + "::" + ctor.name
        if not(ctx.enum_ctor_tags.contains(qualified_ctor)) {
          ctx.enum_ctor_tags[qualified_ctor] = ctx.enum_ctor_tags[ctor.name]
          ctx.enum_ctor_arities[qualified_ctor] = ctor.args.length()
          ctx.enum_ctor_arg_kinds[qualified_ctor] = arg_kinds
        }
        // Register singleton for 0-arg enum constructors
        if ctor.args.length() == 0 {
          let offset = ctx.strings.intern_enum_singleton(
            ctor.name,
            ctx.enum_ctor_tags[ctor.name],
          )
          ctx.enum_ctor_singletons[ctor.name] = tag_ptr64(offset, tag_obj)
          ctx.enum_ctor_singletons[qualified_ctor] = tag_ptr64(offset, tag_obj)
        }
      }
    }
    @core.Stmt::ExportEnumDef(name~, params~, ctors~, span~) =>
      scan_needs_stmt(ctx, @core.Stmt::EnumDef(name~, params~, ctors~, span~))
    @core.Stmt::StructDef(name~, params~, fields~, span~) => {
      let _ = name
      let _ = params
      let _ = span
      for field in fields {
        ctx.known_record_fields[field.name] = true
      }
    }
    @core.Stmt::ExportStructDef(name~, params~, fields~, span~) =>
      scan_needs_stmt(
        ctx,
        @core.Stmt::StructDef(name~, params~, fields~, span~),
      )
    @core.Stmt::TypeAlias(name~, params~, target~, span~) => {
      let _ = name
      let _ = params
      let _ = target
      let _ = span
    }
    @core.Stmt::Expr(expr~, span~) => {
      let _ = span
      scan_needs_expr(ctx, expr)
    }
    @core.Stmt::Test(name~, body~, span~) => {
      let _ = name
      let _ = body
      let _ = span
    }
    @core.Stmt::Bench(name~, body~, span~) => {
      let _ = name
      let _ = body
      let _ = span
    }
    @core.Stmt::LetPat(pat~, expr~, span~) => {
      let _ = pat
      let _ = span
      scan_needs_expr(ctx, expr)
    }
    @core.Stmt::LetPatElse(pat~, expr~, else_body~, span~) => {
      let _ = pat
      let _ = span
      scan_needs_expr(ctx, expr)
      scan_needs_block(ctx, else_body)
    }
    @core.Stmt::LetMut(name~, expr~, span~) => {
      let _ = name
      let _ = span
      scan_needs_expr(ctx, expr)
    }
    @core.Stmt::ExportLet(rec~, name~, expr~, span~) => {
      let _ = rec
      let _ = name
      let _ = span
      scan_needs_expr(ctx, expr)
    }
    @core.Stmt::Assign(name~, expr~, span~) => {
      let _ = name
      let _ = span
      scan_needs_expr(ctx, expr)
    }
    _ => ()
  }
}

///|
fn scan_needs(ctx : CodegenCtx, ast : @core.Module) -> Unit {
  for stmt in ast.stmts {
    scan_needs_stmt(ctx, stmt)
  }
}

///|
fn scan_strings(ctx : CodegenCtx, ast : @core.Module) -> Unit {
  for stmt in ast.stmts {
    scan_strings_stmt(ctx, stmt)
  }
}

///|
fn scan_strings_stmt(ctx : CodegenCtx, stmt : @core.Stmt) -> Unit {
  match stmt {
    @core.Stmt::Let(rec~, name~, expr~, span~) => {
      let _ = rec
      let _ = name
      let _ = span
      scan_strings_expr(ctx, expr)
    }
    @core.Stmt::Expr(expr~, span~) => {
      let _ = span
      scan_strings_expr(ctx, expr)
    }
    @core.Stmt::Test(name~, body~, span~) => {
      let _ = name
      let _ = span
      let _ = body
    }
    @core.Stmt::Bench(name~, body~, span~) => {
      let _ = name
      let _ = span
      let _ = body
    }
    @core.Stmt::LetPat(pat~, expr~, span~) => {
      let _ = pat
      let _ = span
      scan_strings_expr(ctx, expr)
    }
    @core.Stmt::LetPatElse(pat~, expr~, else_body~, span~) => {
      let _ = pat
      let _ = span
      scan_strings_expr(ctx, expr)
      scan_strings(ctx, else_body)
    }
    @core.Stmt::LetMut(name~, expr~, span~) => {
      let _ = name
      let _ = span
      scan_strings_expr(ctx, expr)
    }
    @core.Stmt::ExportLet(rec~, name~, expr~, span~) => {
      let _ = rec
      let _ = name
      let _ = span
      scan_strings_expr(ctx, expr)
    }
    @core.Stmt::Assign(name~, expr~, span~) => {
      let _ = name
      let _ = span
      scan_strings_expr(ctx, expr)
    }
    _ => ()
  }
}

///|
fn scan_strings_expr(ctx : CodegenCtx, expr : @core.Expr) -> Unit {
  match expr {
    @core.Expr::String(value=s, span~) => {
      let _ = span
      if ctx.use_js_strings {
        let _ = ctx.js_strings.intern(s)
      } else {
        let _ = ctx.strings.intern(s)
      }
    }
    @core.Expr::Call(name~, args~, span~, ..) => {
      let _ = name
      let _ = span
      for arg in args {
        scan_strings_expr(ctx, arg.expr)
      }
    }
    @core.Expr::Tuple(items~, span~) => {
      let _ = span
      for item in items {
        scan_strings_expr(ctx, item)
      }
    }
    @core.Expr::TupleIndex(expr~, ..) => scan_strings_expr(ctx, expr)
    @core.Expr::Record(fields~, span~) => {
      let _ = span
      let ordered = sort_record_fields_expr(fields)
      for field in ordered {
        let _ = ctx.strings.intern(field.name)
        ctx.known_record_fields[field.name] = true
        scan_strings_expr(ctx, field.expr)
      }
    }
    @core.Expr::StructLit(fields~, span~, ..) => {
      let _ = span
      let ordered = sort_record_fields_expr(fields)
      for field in ordered {
        let _ = ctx.strings.intern(field.name)
        ctx.known_record_fields[field.name] = true
        scan_strings_expr(ctx, field.expr)
      }
    }
    @core.Expr::Array(items~, span~) => {
      let _ = span
      for item in items {
        scan_strings_expr(ctx, item)
      }
    }
    @core.Expr::Map(fields~, span~) => {
      let _ = span
      for field in fields {
        let _ = ctx.strings.intern(field.key)
        scan_strings_expr(ctx, field.expr)
      }
    }
    @core.Expr::If(cond~, then_body~, else_body~, span~) => {
      let _ = span
      scan_strings_expr(ctx, cond)
      scan_strings(ctx, then_body)
      scan_strings(ctx, else_body)
    }
    @core.Expr::Block(body~, span~) => {
      let _ = span
      scan_strings(ctx, body)
    }
    @core.Expr::Match(scrutinee~, arms~, span~) => {
      let _ = span
      scan_strings_expr(ctx, scrutinee)
      for arm in arms {
        scan_strings_pat(ctx, arm.pat)
        scan_strings_expr(ctx, arm.expr)
        match arm.cond {
          Some(c) => scan_strings_expr(ctx, c)
          None => ()
        }
      }
    }
    @core.Expr::Handle(body~, arms~, span~) => {
      let _ = span
      scan_strings(ctx, body)
      for arm in arms {
        scan_strings_expr(ctx, arm.expr)
        match arm.cond {
          Some(c) => scan_strings_expr(ctx, c)
          None => ()
        }
      }
    }
    @core.Expr::Fn(params~, ret~, effects~, body~, span~, ..) => {
      let _ = params
      let _ = ret
      let _ = effects
      let _ = span
      scan_strings(ctx, body)
    }
    @core.Expr::Perform(effect_name="Error", op_name="Throw", args~, ..) => {
      let value = if args.length() >= 1 { args[0].expr } else { return }
      if not(ctx.use_js_strings) {
        match value {
          @core.Expr::String(value=message, span~) => {
            let _ = span
            let _ = intern_error_code(ctx, message)
            if ctx.embed_error_strings {
              scan_strings_expr(ctx, value)
            }
          }
          _ => scan_strings_expr(ctx, value)
        }
      } else {
        scan_strings_expr(ctx, value)
      }
    }
    @core.Expr::While(cond~, body~, span~) => {
      let _ = span
      scan_strings_expr(ctx, cond)
      scan_strings(ctx, body)
    }
    @core.Expr::Loop(params~, body~, span~) => {
      let _ = span
      for param in params {
        scan_strings_expr(ctx, param.init)
      }
      scan_strings(ctx, body)
    }
    @core.Expr::ForIn(value_name~, index_name~, iterable~, body~, span~) => {
      let desugared = @core.desugar_for_in(
        value_name, index_name, iterable, body, span,
      )
      scan_strings(ctx, desugared)
    }
    _ => ()
  }
}

///|
fn scan_strings_pat(ctx : CodegenCtx, pat : @core.Pat) -> Unit {
  match pat {
    @core.Pat::String(value=s, span~) => {
      let _ = span
      if not(ctx.use_js_strings) {
        let _ = ctx.strings.intern(s)
      }
    }
    @core.Pat::Tuple(items~, span~) => {
      let _ = span
      for item in items {
        scan_strings_pat(ctx, item)
      }
    }
    @core.Pat::Record(fields~, span~) => {
      let _ = span
      for field in fields {
        ctx.known_record_fields[field.name] = true
        scan_strings_pat(ctx, field.pat)
      }
    }
    @core.Pat::Ctor(name~, args~, span~) => {
      let _ = name
      let _ = span
      for arg in args {
        scan_strings_pat(ctx, arg)
      }
    }
    _ => ()
  }
}
