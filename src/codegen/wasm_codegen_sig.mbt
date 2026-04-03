///|
priv struct WasmFunc {
  params : Array[ValueKind]
  locals : Array[ValueKind]
  results : Array[ValueKind]
  body : Array[Byte]
}

///|
fn value_kind_from_type(ctx : CodegenCtx, ty : @core.Type) -> ValueKind {
  match ty {
    @core.Type::Char => ValueKind::I64
    @core.Type::String =>
      if ctx.use_js_strings {
        ValueKind::ExternRef
      } else {
        ValueKind::I64
      }
    @core.Type::Float => ValueKind::BoxedF32
    @core.Type::Double => ValueKind::BoxedF64
    @core.Type::Named(name~, args~) => {
      if args.length() > 0 {
        return ValueKind::I64
      }
      let is_string_name = name == "String" ||
        name.has_suffix(".String") ||
        name.has_suffix("::String") ||
        name.has_suffix("/String")
      let is_float_name = name == "Float" ||
        name == "f32" ||
        name.has_suffix(".Float") ||
        name.has_suffix("::Float") ||
        name.has_suffix("/Float")
      let is_double_name = name == "Double" ||
        name == "f64" ||
        name.has_suffix(".Double") ||
        name.has_suffix("::Double") ||
        name.has_suffix("/Double")
      if is_string_name {
        if ctx.use_js_strings {
          ValueKind::ExternRef
        } else {
          ValueKind::I64
        }
      } else if is_float_name {
        ValueKind::BoxedF32
      } else if is_double_name {
        ValueKind::BoxedF64
      } else {
        ValueKind::I64
      }
    }
    _ => ValueKind::I64
  }
}

///|
fn linked_funcref_key(import_idx : Int) -> Int {
  -import_idx - 1
}

///|
fn decode_funcref_func_index(func_import_count : Int, key : Int) -> Int {
  if key < 0 {
    -key - 1
  } else {
    func_import_count + key
  }
}

///|
fn ensure_funcref_slot(ctx : CodegenCtx, func_idx : Int) -> Int {
  match ctx.fn_table_slots.get(func_idx) {
    Some(slot) => slot
    None => {
      let slot = ctx.fn_table_order.length()
      ctx.fn_table_slots[func_idx] = slot
      ctx.fn_table_order.push(func_idx)
      slot
    }
  }
}

///|
fn value_kind_key_char(kind : ValueKind) -> Char {
  match kind {
    ValueKind::I32 => 'i'
    ValueKind::I64 | ValueKind::BoxedF32 | ValueKind::BoxedF64 => 'l'
    ValueKind::ExternRef => 'r'
    ValueKind::V128 => 'v'
  }
}

///|
fn func_sig_key_from_parts(
  params : Array[ValueKind],
  results : Array[ValueKind],
) -> String {
  let sb = StringBuilder::new()
  sb.write_char('(')
  for i in 0..<params.length() {
    if i > 0 {
      sb.write_char(',')
    }
    sb.write_char(value_kind_key_char(params[i]))
  }
  sb.write_string(")->")
  for r in results {
    sb.write_char(value_kind_key_char(r))
  }
  sb.to_string()
}

///|
fn func_sig_key(sig : FuncSig) -> String {
  func_sig_key_from_parts(sig.params, sig.results)
}

///|
fn func_sig_with_env(params : Array[ValueKind], result : ValueKind) -> FuncSig {
  let out : Array[ValueKind] = []
  for kind in params {
    out.push(kind)
  }
  out.push(ValueKind::I32)
  FuncSig::{ params: out, results: [result] }
}

///|
fn func_sig_with_env_multi(
  params : Array[ValueKind],
  results : Array[ValueKind],
) -> FuncSig {
  let out : Array[ValueKind] = []
  for kind in params {
    out.push(kind)
  }
  out.push(ValueKind::I32)
  FuncSig::{ params: out, results }
}

///|
fn func_sig_from_type(ctx : CodegenCtx, ty : @core.Type) -> FuncSig? {
  match ty {
    @core.Type::Func(params~, ret~, effects~) => {
      let _ = effects
      let param_kinds : Array[ValueKind] = []
      for param in params {
        param_kinds.push(value_kind_from_type(ctx, param.ty))
      }
      let result = value_kind_from_type(ctx, ret)
      Some(func_sig_with_env(param_kinds, result))
    }
    _ => None
  }
}

///|
fn infer_expr_func_sig(ctx : CodegenCtx, expr : @core.Expr) -> FuncSig? {
  match expr {
    @core.Expr::Fn(params~, ret~, effects~, body~, span~, ..) => {
      let _ = effects
      let _ = body
      let _ = span
      let param_kinds : Array[ValueKind] = []
      for param in params {
        param_kinds.push(value_kind_from_type(ctx, param.ty))
      }
      let result = match ret {
        Some(r) => value_kind_from_type(ctx, r)
        None => ValueKind::I64
      }
      Some(func_sig_with_env(param_kinds, result))
    }
    @core.Expr::Block(body~, span~) => {
      let _ = span
      if body.stmts.length() > 0 {
        match body.stmts[body.stmts.length() - 1] {
          @core.Stmt::Expr(expr~, span~) => {
            let _ = span
            infer_expr_func_sig(ctx, expr)
          }
          _ => None
        }
      } else {
        None
      }
    }
    _ => None
  }
}

///|
fn infer_body_return_sig(ctx : CodegenCtx, body : @core.Module) -> FuncSig? {
  if body.stmts.length() > 0 {
    match body.stmts[body.stmts.length() - 1] {
      @core.Stmt::Expr(expr~, span~) => {
        let _ = span
        infer_expr_func_sig(ctx, expr)
      }
      _ => None
    }
  } else {
    None
  }
}

///|
fn builtin_type_count(ctx : CodegenCtx) -> Int {
  let mut count = 0
  if ctx.need_js_length {
    count += 1
  }
  if ctx.need_js_char_code_at {
    count += 1
  }
  if ctx.need_js_substring {
    count += 1
  }
  if ctx.need_js_concat {
    count += 1
  }
  if ctx.need_js_equals {
    count += 1
  }
  if ctx.need_sh || ctx.need_path || ctx.need_env_get {
    count += 1
  }
  if ctx.need_env_args_get || ctx.need_dynamic_path_resolve {
    count += 1
  }
  if ctx.need_env_args_len {
    count += 1
  }
  if ctx.need_sleep {
    count += 1
  }
  if ctx.need_stdout_write_char || ctx.need_stdin_read_char {
    count += 1
  }
  if ctx.need_stdout_write_char {
    count += 1
  }
  if ctx.need_stdin_read_char {
    count += 1
  }
  if ctx.need_fs && not(ctx.fs_host_imports) {
    // Keep in sync with wasm_codegen_module.mbt type section:
    // get-directories/resource-drop, open-at, read, write, metadata-hash-at, stat-at
    count += 5
  }
  if ctx.need_fs && ctx.fs_host_imports {
    // Keep in sync with wasm_codegen_module.mbt type section:
    // fs host import arity signatures: (0), (1), (2) -> i64
    count += 3
  }
  if ctx.need_socket {
    // Keep in sync with wasm_codegen_module.mbt type section:
    // instance-network, create-tcp, start-connect, finish-connect,
    // subscribe, poll, shutdown, resource-drop, stream-read, stream-write
    count += 10
  }
  if ctx.need_http && ctx.http_host_imports {
    // Keep in sync with wasm_codegen_module.mbt type section:
    // host http import arity signatures: (1), (2), (4) -> i64
    count += 3
  }
  count
}

///|
fn ensure_sig_index(ctx : CodegenCtx, sig : FuncSig) -> Int {
  let key = func_sig_key(sig)
  match ctx.fn_sig_type_indices.get(key) {
    Some(idx) => idx
    None => {
      let idx = builtin_type_count(ctx) + ctx.fn_sig_order.length()
      ctx.fn_sig_type_indices[key] = idx
      ctx.fn_sig_order.push(sig)
      idx
    }
  }
}

///|
fn func_import_count(ctx : CodegenCtx) -> Int {
  let mut count = 0
  if ctx.need_js_length {
    count += 1
  }
  if ctx.need_js_char_code_at {
    count += 1
  }
  if ctx.need_js_substring {
    count += 1
  }
  if ctx.need_js_concat {
    count += 1
  }
  if ctx.need_js_equals {
    count += 1
  }
  if ctx.need_path {
    count += 1
  }
  if ctx.need_dynamic_path_resolve {
    count += 1
  }
  if ctx.need_sh {
    count += 1
  }
  if ctx.need_env_get {
    count += 1
  }
  if ctx.need_env_args_len {
    count += 1
  }
  if ctx.need_env_args_get {
    count += 1
  }
  if ctx.need_sleep {
    count += 1
  }
  if ctx.need_stdout_write_char {
    count += 2
  }
  if ctx.need_stdin_read_char {
    count += 2
  }
  if ctx.need_fs && not(ctx.fs_host_imports) {
    count += 7
  }
  if ctx.need_fs && ctx.fs_host_imports {
    // 16 original fs imports + 3 streaming writes (open_write, write_chunk, close_write)
    count += 19
  }
  if ctx.need_fs && ctx.fs_host_imports {
    // Json host imports: json_parse(i64)->i64, json_stringify(i64)->i64
    // Reuses fs_host_arity1_type (param i64 result i64)
    count += 2
  }
  if ctx.need_socket {
    count += 13
  }
  if ctx.need_http && ctx.http_host_imports {
    // http_request + response/status/header/body/close +
    // listen/accept/request_* + respond
    count += 12
  }
  // Exclude handled effect ops (they use throw/catch, not imports)
  count += ctx.effect_op_imports.length() - ctx.effect_handled_ops.length()
  count += ctx.linked_fn_imports_list.length()
  count
}

///|
fn is_qualified_name(name : String) -> Bool {
  for c in name {
    if c == '.' || c == '#' {
      return true
    }
  }
  false
}

///|
fn infer_expr_kind(
  ctx : CodegenCtx,
  expr : @core.Expr,
) -> ValueKind raise WasmGenError {
  infer_expr_kind_with(ctx, expr, ctx.local_kinds)
}

///|
fn infer_expr_kind_with(
  ctx : CodegenCtx,
  expr : @core.Expr,
  locals : Map[String, ValueKind],
) -> ValueKind raise WasmGenError {
  match expr {
    @core.Expr::Int(value~, span~) => {
      let _ = value
      let _ = span
      ValueKind::I64
    }
    @core.Expr::Bool(value~, span~) => {
      let _ = value
      let _ = span
      ValueKind::I64
    }
    @core.Expr::Char(value~, span~) => {
      let _ = value
      let _ = span
      ValueKind::I64
    }
    @core.Expr::String(value~, span~) => {
      let _ = value
      let _ = span
      if ctx.use_js_strings {
        ValueKind::ExternRef
      } else {
        ValueKind::I64
      }
    }
    @core.Expr::Float(value~, span~) => {
      let _ = value
      let _ = span
      ValueKind::BoxedF32
    }
    @core.Expr::Double(value~, span~) => {
      let _ = value
      let _ = span
      ValueKind::BoxedF64
    }
    @core.Expr::Ident(name~, span~) => {
      let _ = span
      match locals.get(name) {
        Some(kind) =>
          if kind == ValueKind::I32 && ctx.mut_captured_vars.contains(name) {
            // `let mut` captured vars are stored as i32 ref-cell pointers,
            // but reading the identifier yields the boxed value (i64).
            ValueKind::I64
          } else {
            kind
          }
        None => ValueKind::I64
      }
    }
    @core.Expr::Placeholder(..) =>
      // Placeholder should be desugared before codegen
      ValueKind::I64
    @core.Expr::Call(name~, args~, span~, ..) => {
      let _ = span
      let name = @core.lower_wasm_intrinsic_name(name)
      let pos_args = extract_positional_exprs(args, name)
      match name {
        "add" | "sub" | "mul" | "div" | "eq" | "lt" => ValueKind::I64
        "__index" | "__len" => ValueKind::I64
        "__add" | "__sub" | "__mul" | "__div" | "__mod" => {
          if pos_args.length() != 2 {
            raise WasmGenError::Unsupported("arity: " + name)
          }
          let left_kind = infer_expr_kind_with(ctx, pos_args[0], locals)
          let right_kind = infer_expr_kind_with(ctx, pos_args[1], locals)
          // When one side is I64 (generic tagged), coerce to the other side's type
          let backend = if ctx.use_js_strings {
            "wasm-js-string"
          } else {
            "wasm"
          }
          let resolved_kind = if left_kind == right_kind {
            left_kind
          } else if left_kind == ValueKind::I64 {
            right_kind
          } else if right_kind == ValueKind::I64 {
            left_kind
          } else {
            raise WasmGenError::BackendLimit(
              backend~,
              feature="numeric kind mismatch",
            )
          }
          match resolved_kind {
            ValueKind::I64 | ValueKind::BoxedF32 | ValueKind::BoxedF64 =>
              resolved_kind
            _ =>
              raise WasmGenError::BackendLimit(backend~, feature="numeric kind")
          }
        }
        "__neg" => {
          if pos_args.length() != 1 {
            raise WasmGenError::Unsupported("arity: " + name)
          }
          let kind = infer_expr_kind_with(ctx, pos_args[0], locals)
          let backend = if ctx.use_js_strings {
            "wasm-js-string"
          } else {
            "wasm"
          }
          match kind {
            ValueKind::I64 | ValueKind::BoxedF32 | ValueKind::BoxedF64 => kind
            _ =>
              raise WasmGenError::BackendLimit(backend~, feature="numeric kind")
          }
        }
        "Int::to_float"
        | "f32_convert_i32_s"
        | "Double::to_float"
        | "f32_demote_f64"
        | "f32_neg"
        | "f32_abs"
        | "f32_ceil"
        | "f32_floor"
        | "f32_trunc"
        | "f32_nearest"
        | "f32_sqrt"
        | "f32_load" => ValueKind::BoxedF32
        "Int::to_double"
        | "f64_convert_i32_s"
        | "to_double"
        | "Float::to_double"
        | "f64_promote_f32"
        | "f64_neg"
        | "f64_abs"
        | "f64_ceil"
        | "f64_floor"
        | "f64_trunc"
        | "f64_nearest"
        | "f64_sqrt"
        | "f64_load" => ValueKind::BoxedF64
        "Float::to_int"
        | "i32_trunc_f32_s"
        | "Double::to_int"
        | "i32_trunc_f64_s"
        | "i32_eqz"
        | "i32_eq"
        | "i32_ne"
        | "i32_lt_s"
        | "i32_le_s"
        | "i32_gt_s"
        | "i32_ge_s"
        | "f32_eq"
        | "f32_ne"
        | "f32_lt"
        | "f32_le"
        | "f32_gt"
        | "f32_ge"
        | "f64_eq"
        | "f64_ne"
        | "f64_lt"
        | "f64_le"
        | "f64_gt"
        | "f64_ge"
        | "i32_shr_u"
        | "i32_load"
        | "i32_load8_u"
        | "i32_store"
        | "i32_store8"
        | "f32_store"
        | "f64_store" => ValueKind::I64
        "anyref_eq"
        | "eqref_eq"
        | "i31ref_eq"
        | "structref_eq"
        | "arrayref_eq"
        | "funcref_eq"
        | "externref_eq" => ValueKind::I64
        "__eq" | "__lt" | "__assert_eq" => ValueKind::I64
        "__to_string" =>
          if ctx.use_js_strings {
            ValueKind::ExternRef
          } else {
            ValueKind::I64
          }
        "String::length" => ValueKind::I64
        "String::char_code_at" => ValueKind::I64
        "String::substring" =>
          if ctx.use_js_strings {
            ValueKind::ExternRef
          } else {
            ValueKind::I64
          }
        "String::concat" =>
          if ctx.use_js_strings {
            ValueKind::ExternRef
          } else {
            ValueKind::I64
          }
        "String::equals" => ValueKind::I64
        "ArrayBuilder::new" | "ArrayBuilder::freeze" => ValueKind::I64
        "ArrayBuilder::push"
        | "Array::push"
        | "Array::push_all"
        | "Array::truncate" => ValueKind::I64
        "array_new" => ValueKind::I64
        "array_contains_str" => ValueKind::I64
        "Double::to_i64_bits" | "Double::from_i64_bits" => ValueKind::I64
        "string_to_data" => ValueKind::I64
        "Fs::write_bytes" | "Fs::stat_token" => ValueKind::I64
        "Bytes::from_array" => ValueKind::I64
        "Bytes::length" => ValueKind::I64
        "Bytes::get" => ValueKind::I64
        "MapBuilder::new" | "MapBuilder::freeze" => ValueKind::I64
        "MapBuilder::set" => ValueKind::I64
        "Array::length" => ValueKind::I64
        "Array::get" => ValueKind::I64
        "Map::get" => ValueKind::I64
        "sleep" => ValueKind::I64
        "Stdout::write_char" => ValueKind::I64
        "Stdout::write_stream" => ValueKind::I64
        "Stdin::read_char" => ValueKind::I64
        "Stdin::read_stream" => ValueKind::I64
        "String::from_char_code" => ValueKind::I64
        "Char::to_int" => ValueKind::I64
        "Char::from_int" => ValueKind::I64
        "Threads::probe_wat" =>
          if ctx.use_js_strings {
            ValueKind::ExternRef
          } else {
            ValueKind::I64
          }
        "Threads::runtime_hints" => ValueKind::I64
        "wasm_env" | "wasi_env" =>
          if ctx.use_js_strings {
            ValueKind::ExternRef
          } else {
            ValueKind::I64
          }
        "Threads::channel_new" => ValueKind::I64
        "Threads::spawn" => ValueKind::I64
        "Threads::send" => ValueKind::I64
        "Threads::recv" =>
          if ctx.use_js_strings {
            ValueKind::ExternRef
          } else {
            ValueKind::I64
          }
        "Threads::wait" => ValueKind::I64
        _ if ctx.fn_local_sigs.contains(name) =>
          match ctx.fn_local_sigs.get(name) {
            Some(sig) =>
              if sig.results.length() > 0 {
                sig.results[0]
              } else {
                ValueKind::I64
              }
            None => ValueKind::I64
          }
        _ =>
          if ctx.fn_returns.contains(name) {
            match ctx.fn_returns.get(name) {
              Some(kind) => kind
              None => ValueKind::I64
            }
          } else {
            ValueKind::I64
          }
      }
    }
    @core.Expr::If(cond~, then_body~, else_body~, span~) => {
      let _ = span
      let _ = cond
      let then_kind = infer_block_kind(ctx, then_body, locals)
      let else_kind = infer_block_kind(ctx, else_body, locals)
      if then_kind != else_kind {
        let backend = if ctx.use_js_strings { "wasm-js-string" } else { "wasm" }
        raise WasmGenError::BackendLimit(backend~, feature="if kind mismatch")
      }
      then_kind
    }
    @core.Expr::Block(body~, span~) => {
      let _ = span
      infer_block_kind(ctx, body, locals)
    }
    @core.Expr::Perform(..) => ValueKind::I64 // effect ops return tagged i64
    @core.Expr::Handle(body~, arms~, span~) => {
      let _ = span
      let try_kind = infer_block_kind(ctx, body, locals)
      if arms.length() > 0 {
        let catch_kind = infer_expr_kind_with(ctx, arms[0].expr, locals)
        if try_kind != catch_kind {
          let backend = if ctx.use_js_strings {
            "wasm-js-string"
          } else {
            "wasm"
          }
          raise WasmGenError::BackendLimit(
            backend~,
            feature="handle kind mismatch",
          )
        }
      }
      try_kind
    }
    @core.Expr::Match(scrutinee~, arms~, span~) => {
      let _ = span
      if arms.length() == 0 {
        ValueKind::I64
      } else {
        // Infer type from the first arm's expression
        let arm = arms[0]
        let arm_locals = locals.copy()
        let scrut_kind = infer_expr_kind_with(ctx, scrutinee, locals)
        let binding_kinds : Map[String, ValueKind] = {}
        collect_pat_binding_kinds_codegen(
          ctx,
          arm.pat,
          scrut_kind,
          binding_kinds,
        )
        for name, kind in binding_kinds {
          arm_locals[name] = kind
        }
        infer_expr_kind_with(ctx, arm.expr, arm_locals)
      }
    }
    @core.Expr::Tuple(items~, span~) => {
      let _ = items
      let _ = span
      ValueKind::I64
    }
    @core.Expr::TupleIndex(expr~, index~, span~) => {
      let _ = expr
      let _ = index
      let _ = span
      ValueKind::I64
    }
    @core.Expr::Record(fields~, span~) => {
      let _ = fields
      let _ = span
      ValueKind::I64
    }
    @core.Expr::Array(items~, span~) => {
      let _ = items
      let _ = span
      ValueKind::I64
    }
    @core.Expr::Map(fields~, span~) => {
      let _ = fields
      let _ = span
      ValueKind::I64
    }
    @core.Expr::ForIn(value_name~, index_name~, iterable~, body~, span~) => {
      let desugared = if @core.is_string_for_in(span.start) {
        @core.desugar_for_in_string(
          value_name, index_name, iterable, body, span,
        )
      } else {
        @core.desugar_for_in(value_name, index_name, iterable, body, span)
      }
      infer_block_kind(ctx, desugared, locals)
    }
    @core.Expr::Fn(params~, ret~, effects~, body~, span~, ..) => {
      let _ = params
      let _ = ret
      let _ = effects
      let _ = body
      let _ = span
      ValueKind::I64
    }
    @core.Expr::While(cond~, body~, span~) => {
      let _ = cond
      let _ = body
      let _ = span
      ValueKind::I64
    }
    @core.Expr::Loop(params~, body~, span~) => {
      let _ = params
      let _ = body
      let _ = span
      ValueKind::I64
    }
    @core.Expr::Break(span~, ..) => {
      let _ = span
      ValueKind::I64
    }
    @core.Expr::Continue(span~, ..) => {
      let _ = span
      ValueKind::I64
    }
    @core.Expr::Yield(expr~, span~) => {
      let _ = expr
      let _ = span
      ValueKind::I64
    }
    @core.Expr::StructLit(fields~, span~, ..) => {
      let _ = fields
      let _ = span
      // Struct is compiled as record - same layout (pointer)
      ValueKind::I64
    }
    @core.Expr::Spread(span~, ..) => {
      let _ = span
      raise WasmGenError::Unsupported("spread outside array literal")
    }
    @core.Expr::StringInterp(..) => ValueKind::I64 // string = tagged i64
  }
}

///|
fn infer_block_kind(
  ctx : CodegenCtx,
  body : @core.Module,
  locals : Map[String, ValueKind],
) -> ValueKind raise WasmGenError {
  let kinds = locals.copy()
  let mut last = ValueKind::I64
  for stmt in body.stmts {
    last = infer_stmt_kind(ctx, stmt, kinds)
  }
  last
}

///|
fn infer_stmt_kind(
  ctx : CodegenCtx,
  stmt : @core.Stmt,
  locals : Map[String, ValueKind],
) -> ValueKind raise WasmGenError {
  match stmt {
    @core.Stmt::Let(rec~, name~, expr~, span~) => {
      let _ = span
      let _ = rec
      let kind = infer_expr_kind_with(ctx, expr, locals)
      locals[name] = kind
      kind
    }
    @core.Stmt::Expr(expr~, span~) => {
      let _ = span
      infer_expr_kind_with(ctx, expr, locals)
    }
    @core.Stmt::EnumDef(name~, params~, ctors~, span~) => {
      let _ = name
      let _ = params
      let _ = ctors
      let _ = span
      ValueKind::I64
    }
    @core.Stmt::TypeAlias(name~, params~, target~, span~) => {
      let _ = name
      let _ = params
      let _ = target
      let _ = span
      ValueKind::I64
    }
    @core.Stmt::Test(name~, body~, span~) => {
      let _ = name
      let _ = body
      let _ = span
      ValueKind::I64
    }
    @core.Stmt::Bench(name~, body~, span~) => {
      let _ = name
      let _ = body
      let _ = span
      ValueKind::I64
    }
    @core.Stmt::LetPat(pat~, expr~, span~) => {
      let _ = span
      let kind = infer_expr_kind_with(ctx, expr, locals)
      let _ = kind
      let bindings : Array[String] = []
      collect_pat_bindings_codegen(pat, bindings)
      for name in bindings {
        locals[name] = ValueKind::I64
      }
      ValueKind::I64
    }
    @core.Stmt::LetPatElse(pat~, expr~, else_body~, span~) => {
      let _ = span
      let _ = else_body
      let kind = infer_expr_kind_with(ctx, expr, locals)
      let _ = kind
      let bindings : Array[String] = []
      collect_pat_bindings_codegen(pat, bindings)
      for name in bindings {
        locals[name] = ValueKind::I64
      }
      ValueKind::I64
    }
    @core.Stmt::LetMut(name~, expr~, span~) => {
      let _ = span
      let kind = infer_expr_kind_with(ctx, expr, locals)
      locals[name] = kind
      kind
    }
    _ => ValueKind::I64
  }
}

///|
fn collect_top_level_funcs(ast : @core.Module) -> Array[FuncDef] {
  let out : Array[FuncDef] = []
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::Let(rec~, name~, expr~, span~) => {
        let _ = rec
        let _ = span
        match expr {
          @core.Expr::Fn(params~, ret~, effects~, body~, span~, ..) => {
            let _ = effects
            out.push(FuncDef::{
              name: Some(name),
              params,
              ret,
              body,
              span_key: span_key_named(Some(name), span, params),
              captures: [],
            })
          }
          _ => ()
        }
      }
      @core.Stmt::ExportLet(rec~, name~, expr~, span~) => {
        // ExportLet is treated like Let for top-level function collection
        let _ = rec
        let _ = span
        match expr {
          @core.Expr::Fn(params~, ret~, effects~, body~, span~, ..) => {
            let _ = effects
            out.push(FuncDef::{
              name: Some(name),
              params,
              ret,
              body,
              span_key: span_key_named(Some(name), span, params),
              captures: [],
            })
          }
          _ => ()
        }
      }
      _ => ()
    }
  }
  out
}

///|
fn filter_top_level_funcs(ctx : CodegenCtx, ast : @core.Module) -> @core.Module {
  let out : Array[@core.Stmt] = []
  for stmt in ast.stmts {
    let skip = match stmt {
      @core.Stmt::Let(rec=_, name~, expr~, span=_) =>
        match expr {
          @core.Expr::Fn(params~, ret=_, effects=_, body=_, span~, ..) => {
            // Only skip functions with NO captures
            // Functions with captures need to be processed in run() to create closure
            let key = span_key_named(Some(name), span, params)
            match ctx.fn_closure_captures.get(key) {
              Some(captures) => captures.length() == 0
              None => true // No capture info, assume no captures
            }
          }
          _ => false
        }
      @core.Stmt::ExportLet(rec=_, name~, expr~, span=_) =>
        // ExportLet functions are also skipped if they have no captures
        match expr {
          @core.Expr::Fn(params~, ret=_, effects=_, body=_, span~, ..) =>
            if ctx.exported_fn_env_globals.contains(name) {
              false
            } else {
              let key = span_key_named(Some(name), span, params)
              match ctx.fn_closure_captures.get(key) {
                Some(captures) => captures.length() == 0
                None => true
              }
            }
          _ => false
        }
      _ => false
    }
    if not(skip) {
      out.push(stmt)
    }
  }
  @core.Module::{ stmts: out }
}

///|
fn needs_heap_block(ctx : CodegenCtx, body : @core.Module) -> Bool {
  for stmt in body.stmts {
    if needs_heap_stmt(ctx, stmt) {
      return true
    }
  }
  false
}

///|
fn needs_heap_stmt(ctx : CodegenCtx, stmt : @core.Stmt) -> Bool {
  match stmt {
    @core.Stmt::Let(rec~, name~, expr~, span~) => {
      let _ = rec
      let _ = name
      let _ = span
      needs_heap_expr(ctx, expr)
    }
    @core.Stmt::Expr(expr~, span~) => {
      let _ = span
      needs_heap_expr(ctx, expr)
    }
    @core.Stmt::Test(name~, body~, span~) => {
      let _ = name
      let _ = span
      needs_heap_block(ctx, body)
    }
    @core.Stmt::Bench(name~, body~, span~) => {
      let _ = name
      let _ = span
      needs_heap_block(ctx, body)
    }
    @core.Stmt::LetPat(pat~, expr~, span~) => {
      let _ = pat
      let _ = span
      needs_heap_expr(ctx, expr)
    }
    @core.Stmt::LetPatElse(pat~, expr~, else_body~, span~) => {
      let _ = pat
      let _ = span
      needs_heap_expr(ctx, expr) || needs_heap_block(ctx, else_body)
    }
    @core.Stmt::LetMut(name~, expr~, span~) => {
      let _ = name
      let _ = span
      needs_heap_expr(ctx, expr)
    }
    @core.Stmt::ExportLet(rec~, name~, expr~, span~) => {
      let _ = rec
      let _ = name
      let _ = span
      needs_heap_expr(ctx, expr)
    }
    @core.Stmt::Assign(name~, expr~, span~) => {
      let _ = name
      let _ = span
      needs_heap_expr(ctx, expr)
    }
    _ => false
  }
}

///|
/// Check if an expression tree contains any float/double literals
/// or calls to float-producing functions, indicating that dynamic
/// arithmetic might need heap for boxed float allocation.
fn has_float_operand(expr : @core.Expr) -> Bool {
  match expr {
    @core.Expr::Float(..) | @core.Expr::Double(..) => true
    @core.Expr::Call(name~, args~, ..) =>
      match name {
        "Int::to_float"
        | "f32_convert_i32_s"
        | "Int::to_double"
        | "to_double"
        | "f64_convert_i32_s"
        | "Float::to_double"
        | "f64_promote_f32"
        | "Double::to_float"
        | "f32_demote_f64"
        | "f32_neg"
        | "f32_abs"
        | "f32_ceil"
        | "f32_floor"
        | "f32_trunc"
        | "f32_nearest"
        | "f32_sqrt"
        | "f64_neg"
        | "f64_abs"
        | "f64_ceil"
        | "f64_floor"
        | "f64_trunc"
        | "f64_nearest"
        | "f64_sqrt"
        | "f32_load"
        | "f64_load" => true
        _ => args.iter().any(fn(a) { has_float_operand(a.expr) })
      }
    _ => false
  }
}

///|
fn needs_heap_expr(ctx : CodegenCtx, expr : @core.Expr) -> Bool {
  match expr {
    // S7: string literals use pre-interned data segment, no heap alloc
    @core.Expr::String(..) => false
    @core.Expr::Float(..) => true
    @core.Expr::Double(..) => true
    @core.Expr::Tuple(..) => true
    // S7: tuple index is just memory load, recurse into inner expression
    @core.Expr::TupleIndex(expr=inner, ..) => needs_heap_expr(ctx, inner)
    @core.Expr::Record(..) => true
    @core.Expr::StructLit(..) => true
    @core.Expr::Array(..) => true
    @core.Expr::Map(..) => true
    @core.Expr::Call(name~, args~, span~, ..) => {
      let _ = span
      // __add/__sub/__mul/__div/__mod only need heap when operands
      // include floats (boxed float allocation). With int operands,
      // the tagged arithmetic path doesn't allocate.
      if name == "__add" ||
        name == "__sub" ||
        name == "__mul" ||
        name == "__div" ||
        name == "__mod" ||
        name == "__neg" {
        for arg in args {
          if has_float_operand(arg.expr) {
            return true
          }
        }
        // Int operands only: check if args themselves need heap
        for arg in args {
          if needs_heap_expr(ctx, arg.expr) {
            return true
          }
        }
        return false
      }
      if name == "Int::to_float" ||
        name == "f32_convert_i32_s" ||
        name == "Int::to_double" ||
        name == "to_double" ||
        name == "f64_convert_i32_s" ||
        name == "Float::to_double" ||
        name == "f64_promote_f32" ||
        name == "Double::to_float" ||
        name == "f32_demote_f64" ||
        name == "f32_neg" ||
        name == "f32_abs" ||
        name == "f32_ceil" ||
        name == "f32_floor" ||
        name == "f32_trunc" ||
        name == "f32_nearest" ||
        name == "f32_sqrt" ||
        name == "f64_neg" ||
        name == "f64_abs" ||
        name == "f64_ceil" ||
        name == "f64_floor" ||
        name == "f64_trunc" ||
        name == "f64_nearest" ||
        name == "f64_sqrt" ||
        name == "f32_load" ||
        name == "f64_load" ||
        name == "Stdout::write_char" ||
        name == "Stdout::write_stream" ||
        name == "Stdin::read_char" ||
        name == "Stdin::read_stream" ||
        name == "__slice" ||
        name == "String::substring" ||
        name == "String::concat" ||
        name == "__to_string" ||
        name == "String::from_char_code" ||
        name == "Array::slice" ||
        name == "Array::concat" ||
        name == "ArrayBuilder::new" ||
        name == "ArrayBuilder::push" ||
        name == "ArrayBuilder::freeze" ||
        name == "Array::push" ||
        name == "Array::push_all" ||
        name == "array_new" ||
        name == "Array::truncate" ||
        name == "array_contains_str" ||
        name == "Double::to_i64_bits" ||
        name == "Double::from_i64_bits" ||
        name == "string_to_data" ||
        name == "MapBuilder::new" ||
        name == "MapBuilder::set" ||
        name == "MapBuilder::freeze" ||
        name == "StringBuilder::new" ||
        name == "String::join" ||
        name == "StringBuilder::push" ||
        name == "StringBuilder::freeze" ||
        name == "Map::keys" ||
        name == "Map::values" ||
        name == "String::trim" ||
        name == "String::trim_start" ||
        name == "String::trim_end" ||
        name == "String::to_upper" ||
        name == "String::to_lower" ||
        name == "String::replace" ||
        name == "String::replace_all" ||
        name == "String::split" ||
        name == "Fs::read_file" ||
        name == "Fs::write_file" ||
        name == "Fs::write_bytes" ||
        name == "Bytes::new" ||
        name == "Bytes::from_array" ||
        name == "Bytes::from_string" ||
        name == "Bytes::to_string" ||
        name == "Bytes::length" ||
        name == "Bytes::get" ||
        name == "Bytes::set" ||
        name == "Bytes::push" ||
        name == "Bytes::append" ||
        name == "Bytes::blit" ||
        name == "Bytes::fill" ||
        name == "Bytes::slice" ||
        name == "Bytes::concat" ||
        name == "Bytes::to_array" ||
        name == "Fs::exists" ||
        name == "Fs::stat_token" ||
        name == "Socket::tcp_connect" ||
        name == "Socket::tcp_read" ||
        name == "Socket::tcp_write" ||
        name == "Socket::tcp_close" ||
        name == "Http::request" ||
        name == "Http::response_status" ||
        name == "Http::response_header" ||
        name == "Http::response_body" ||
        name == "Http::close" ||
        name == "Http::listen" ||
        name == "Http::accept" ||
        name == "Http::request_method" ||
        name == "Http::request_url" ||
        name == "Http::request_header" ||
        name == "Http::request_body" ||
        name == "Http::respond" ||
        name == "Int::parse" ||
        name == "Double::parse" {
        return true
      }
      // User function calls that are lowered to multi-value must be
      // re-boxed into tuple objects, which allocates on heap.
      if ctx.fn_multivalue_results.contains(name) {
        return true
      }
      // Enum constructor call needs heap
      if ctx.enum_ctor_tags.contains(name) {
        return true
      }
      // S8: If the callee is known to use heap, the caller must also
      // set up heap_local so that the pre/post call sync works correctly.
      match ctx.fn_needs_heap.get(name) {
        Some(true) => return true
        _ => ()
      }
      for arg in args {
        if needs_heap_expr(ctx, arg.expr) {
          return true
        }
      }
      false
    }
    @core.Expr::Ident(name~, span~) => {
      let _ = span
      // Nullary enum constructor needs heap
      ctx.enum_ctor_tags.contains(name)
    }
    @core.Expr::If(cond~, then_body~, else_body~, span~) => {
      let _ = span
      needs_heap_expr(ctx, cond) ||
      needs_heap_block(ctx, then_body) ||
      needs_heap_block(ctx, else_body)
    }
    @core.Expr::Block(body~, span~) => {
      let _ = span
      needs_heap_block(ctx, body)
    }
    @core.Expr::Match(scrutinee~, arms~, span~) => {
      let _ = span
      if needs_heap_expr(ctx, scrutinee) {
        return true
      }
      for arm in arms {
        if needs_heap_expr(ctx, arm.expr) {
          return true
        }
        match arm.cond {
          Some(c) => if needs_heap_expr(ctx, c) { return true }
          None => ()
        }
      }
      false
    }
    @core.Expr::ForIn(value_name~, index_name~, iterable~, body~, span~) => {
      let desugared = if @core.is_string_for_in(span.start) {
        @core.desugar_for_in_string(
          value_name, index_name, iterable, body, span,
        )
      } else {
        @core.desugar_for_in(value_name, index_name, iterable, body, span)
      }
      needs_heap_block(ctx, desugared)
    }
    @core.Expr::Handle(body~, arms~, span~) => {
      let _ = span
      let mut result = needs_heap_block(ctx, body)
      for arm in arms {
        if needs_heap_expr(ctx, arm.expr) {
          result = true
        }
        match arm.cond {
          Some(c) => if needs_heap_expr(ctx, c) { result = true }
          None => ()
        }
      }
      result
    }
    @core.Expr::While(cond~, body~, span~) => {
      let _ = span
      needs_heap_expr(ctx, cond) || needs_heap_block(ctx, body)
    }
    @core.Expr::Loop(params~, body~, span~) => {
      let _ = span
      let mut result = needs_heap_block(ctx, body)
      for param in params {
        if needs_heap_expr(ctx, param.init) {
          result = true
        }
      }
      result
    }
    @core.Expr::Yield(expr~, span~) => {
      let _ = span
      needs_heap_expr(ctx, expr)
    }
    @core.Expr::Fn(params~, ret~, effects~, body~, span~, ..) => {
      let _ = params
      let _ = ret
      let _ = effects
      let _ = body
      fn_closure_has_captures(ctx, span, params)
    }
    _ => false
  }
}

///|
fn fn_closure_has_captures(
  ctx : CodegenCtx,
  span : @core.Span,
  params : Array[@core.FuncParam],
) -> Bool {
  let base = span_key_unique(span, params)
  match ctx.fn_closure_captures.get(base) {
    Some(captures) => captures.length() > 0
    None => {
      let prefix = base + "#"
      for key, captures in ctx.fn_closure_captures {
        if key.has_prefix(prefix) {
          return captures.length() > 0
        }
      }
      false
    }
  }
}

///|
fn param_kinds(
  ctx : CodegenCtx,
  params : Array[@core.FuncParam],
) -> Array[ValueKind] {
  let out : Array[ValueKind] = []
  for param in params {
    out.push(value_kind_from_type(ctx, param.ty))
  }
  out
}

///|
fn param_kind_map(
  params : Array[@core.FuncParam],
  kinds : Array[ValueKind],
) -> Map[String, ValueKind] {
  let out : Map[String, ValueKind] = {}
  let len = if params.length() < kinds.length() {
    params.length()
  } else {
    kinds.length()
  }
  for i in 0..<len {
    out[params[i].name] = kinds[i]
  }
  out
}

///|
fn infer_func_return_kind(
  ctx : CodegenCtx,
  params : Array[@core.FuncParam],
  kinds : Array[ValueKind],
  ret : @core.Type?,
  body : @core.Module,
) -> ValueKind raise WasmGenError {
  let locals = param_kind_map(params, kinds)
  let saved_fn_locals = ctx.fn_local_sigs
  ctx.fn_local_sigs = {}
  for param in params {
    match func_sig_from_type(ctx, param.ty) {
      Some(sig) => ctx.fn_local_sigs[param.name] = sig
      None => ()
    }
  }
  let inferred = if ctx.use_js_strings {
    infer_block_kind(ctx, body, locals)
  } else {
    ValueKind::I64
  }
  ctx.fn_local_sigs = saved_fn_locals
  match ret {
    Some(r) => {
      let declared = value_kind_from_type(ctx, r)
      if ctx.use_js_strings && declared != inferred {
        raise WasmGenError::BackendLimit(
          backend="wasm-js-string",
          feature="fn return kind mismatch: declared=" +
            declared.to_string() +
            " inferred=" +
            inferred.to_string(),
        )
      }
      declared
    }
    None => inferred
  }
}

///|
fn js_import_count(ctx : CodegenCtx) -> Int {
  let mut idx = 0
  if ctx.need_js_length {
    idx += 1
  }
  if ctx.need_js_char_code_at {
    idx += 1
  }
  if ctx.need_js_substring {
    idx += 1
  }
  if ctx.need_js_concat {
    idx += 1
  }
  if ctx.need_js_equals {
    idx += 1
  }
  idx
}

///|
fn import_index_path(ctx : CodegenCtx) -> Int raise WasmGenError {
  if not(ctx.need_path) {
    raise WasmGenError::BackendLimit(backend="wasm", feature="path import")
  }
  js_import_count(ctx)
}

///|
fn import_index_dynamic_path_resolve(
  ctx : CodegenCtx,
) -> Int raise WasmGenError {
  if not(ctx.need_dynamic_path_resolve) {
    raise WasmGenError::BackendLimit(
      backend="wasm",
      feature="Path::resolve import",
    )
  }
  let mut idx = js_import_count(ctx)
  if ctx.need_path {
    idx += 1
  }
  idx
}

///|
fn import_index_sh(ctx : CodegenCtx) -> Int raise WasmGenError {
  if not(ctx.need_sh) {
    raise WasmGenError::BackendLimit(backend="wasm", feature="sh import")
  }
  let mut idx = js_import_count(ctx)
  if ctx.need_path {
    idx += 1
  }
  if ctx.need_dynamic_path_resolve {
    idx += 1
  }
  idx
}

///|
fn import_index_env_get(ctx : CodegenCtx) -> Int raise WasmGenError {
  if not(ctx.need_env_get) {
    raise WasmGenError::BackendLimit(backend="wasm", feature="Env::get import")
  }
  let mut idx = js_import_count(ctx)
  if ctx.need_path {
    idx += 1
  }
  if ctx.need_dynamic_path_resolve {
    idx += 1
  }
  if ctx.need_sh {
    idx += 1
  }
  idx
}

///|
fn import_index_env_args_len(ctx : CodegenCtx) -> Int raise WasmGenError {
  if not(ctx.need_env_args_len) {
    raise WasmGenError::BackendLimit(
      backend="wasm",
      feature="Env::args_len import",
    )
  }
  let mut idx = js_import_count(ctx)
  if ctx.need_path {
    idx += 1
  }
  if ctx.need_dynamic_path_resolve {
    idx += 1
  }
  if ctx.need_sh {
    idx += 1
  }
  if ctx.need_env_get {
    idx += 1
  }
  idx
}

///|
fn import_index_env_args_get(ctx : CodegenCtx) -> Int raise WasmGenError {
  if not(ctx.need_env_args_get) {
    raise WasmGenError::BackendLimit(
      backend="wasm",
      feature="Env::args_get import",
    )
  }
  let mut idx = js_import_count(ctx)
  if ctx.need_path {
    idx += 1
  }
  if ctx.need_dynamic_path_resolve {
    idx += 1
  }
  if ctx.need_sh {
    idx += 1
  }
  if ctx.need_env_get {
    idx += 1
  }
  if ctx.need_env_args_len {
    idx += 1
  }
  idx
}

///|
fn import_index_js_length(ctx : CodegenCtx) -> Int raise WasmGenError {
  if not(ctx.need_js_length) {
    raise WasmGenError::BackendLimit(
      backend="wasm-js-string",
      feature="length import",
    )
  }
  0
}

///|
fn import_index_js_char_code_at(ctx : CodegenCtx) -> Int raise WasmGenError {
  if not(ctx.need_js_char_code_at) {
    raise WasmGenError::BackendLimit(
      backend="wasm-js-string",
      feature="charCodeAt import",
    )
  }
  let mut idx = 0
  if ctx.need_js_length {
    idx += 1
  }
  idx
}

///|
fn import_index_js_substring(ctx : CodegenCtx) -> Int raise WasmGenError {
  if not(ctx.need_js_substring) {
    raise WasmGenError::BackendLimit(
      backend="wasm-js-string",
      feature="substring import",
    )
  }
  let mut idx = 0
  if ctx.need_js_length {
    idx += 1
  }
  if ctx.need_js_char_code_at {
    idx += 1
  }
  idx
}

///|
fn import_index_js_concat(ctx : CodegenCtx) -> Int raise WasmGenError {
  if not(ctx.need_js_concat) {
    raise WasmGenError::BackendLimit(
      backend="wasm-js-string",
      feature="concat import",
    )
  }
  let mut idx = 0
  if ctx.need_js_length {
    idx += 1
  }
  if ctx.need_js_char_code_at {
    idx += 1
  }
  if ctx.need_js_substring {
    idx += 1
  }
  idx
}

///|
fn import_index_js_equals(ctx : CodegenCtx) -> Int raise WasmGenError {
  if not(ctx.need_js_equals) {
    raise WasmGenError::BackendLimit(
      backend="wasm-js-string",
      feature="equals import",
    )
  }
  let mut idx = 0
  if ctx.need_js_length {
    idx += 1
  }
  if ctx.need_js_char_code_at {
    idx += 1
  }
  if ctx.need_js_substring {
    idx += 1
  }
  if ctx.need_js_concat {
    idx += 1
  }
  idx
}

///|
fn import_index_after_sleep(ctx : CodegenCtx) -> Int {
  let mut idx = js_import_count(ctx)
  if ctx.need_path {
    idx += 1
  }
  if ctx.need_dynamic_path_resolve {
    idx += 1
  }
  if ctx.need_sh {
    idx += 1
  }
  if ctx.need_env_get {
    idx += 1
  }
  if ctx.need_env_args_len {
    idx += 1
  }
  if ctx.need_env_args_get {
    idx += 1
  }
  if ctx.need_sleep {
    idx += 1
  }
  idx
}

///|
fn import_index_stdout_get_stream(ctx : CodegenCtx) -> Int raise WasmGenError {
  if not(ctx.need_stdout_write_char) {
    raise WasmGenError::BackendLimit(
      backend="wasm",
      feature="stdout stream import",
    )
  }
  import_index_after_sleep(ctx)
}

///|
fn import_index_stdout_write_stream(ctx : CodegenCtx) -> Int raise WasmGenError {
  if not(ctx.need_stdout_write_char) {
    raise WasmGenError::BackendLimit(
      backend="wasm",
      feature="stdout stream import",
    )
  }
  import_index_after_sleep(ctx) + 1
}

///|
fn import_index_stdin_get_stream(ctx : CodegenCtx) -> Int raise WasmGenError {
  if not(ctx.need_stdin_read_char) {
    raise WasmGenError::BackendLimit(
      backend="wasm",
      feature="stdin stream import",
    )
  }
  let mut idx = import_index_after_sleep(ctx)
  if ctx.need_stdout_write_char {
    idx += 2
  }
  idx
}

///|
fn import_index_stdin_read_stream(ctx : CodegenCtx) -> Int raise WasmGenError {
  if not(ctx.need_stdin_read_char) {
    raise WasmGenError::BackendLimit(
      backend="wasm",
      feature="stdin stream import",
    )
  }
  import_index_stdin_get_stream(ctx) + 1
}

///|
fn import_index_after_stdin(ctx : CodegenCtx) -> Int {
  let mut idx = import_index_after_sleep(ctx)
  if ctx.need_stdout_write_char {
    idx += 2
  }
  if ctx.need_stdin_read_char {
    idx += 2
  }
  idx
}

///|
fn import_index_fs_get_directories(ctx : CodegenCtx) -> Int raise WasmGenError {
  if not(ctx.need_fs) || ctx.fs_host_imports {
    raise WasmGenError::BackendLimit(backend="wasm", feature="fs WASI import")
  }
  import_index_after_stdin(ctx)
}

///|
fn import_index_fs_open_at(ctx : CodegenCtx) -> Int raise WasmGenError {
  import_index_fs_get_directories(ctx) + 1
}

///|
fn import_index_fs_read(ctx : CodegenCtx) -> Int raise WasmGenError {
  import_index_fs_get_directories(ctx) + 2
}

///|
fn import_index_fs_write(ctx : CodegenCtx) -> Int raise WasmGenError {
  import_index_fs_get_directories(ctx) + 3
}

///|
fn import_index_fs_metadata_hash_at(ctx : CodegenCtx) -> Int raise WasmGenError {
  import_index_fs_get_directories(ctx) + 4
}

///|
fn import_index_fs_stat_at(ctx : CodegenCtx) -> Int raise WasmGenError {
  import_index_fs_get_directories(ctx) + 5
}

///|
fn import_index_fs_resource_drop(ctx : CodegenCtx) -> Int raise WasmGenError {
  import_index_fs_get_directories(ctx) + 6
}

///|
fn fs_root_descriptor_global_index(ctx : CodegenCtx) -> Int {
  (if ctx.use_heap_global { 1 } else { 0 }) +
  (if ctx.need_stack_switching { 1 } else { 0 }) +
  (if ctx.coverage_enabled { 2 } else { 0 })
}

///|
fn import_index_fs_host_read_file(ctx : CodegenCtx) -> Int raise WasmGenError {
  if not(ctx.need_fs && ctx.fs_host_imports) {
    raise WasmGenError::BackendLimit(backend="wasm", feature="fs host import")
  }
  import_index_after_stdin(ctx)
}

///|
fn import_index_fs_host_exists(ctx : CodegenCtx) -> Int raise WasmGenError {
  import_index_fs_host_read_file(ctx) + 1
}

///|
fn import_index_fs_host_stat_token(ctx : CodegenCtx) -> Int raise WasmGenError {
  import_index_fs_host_read_file(ctx) + 2
}

///|
fn import_index_fs_host_write_file(ctx : CodegenCtx) -> Int raise WasmGenError {
  import_index_fs_host_read_file(ctx) + 3
}

///|
fn import_index_fs_host_write_bytes(ctx : CodegenCtx) -> Int raise WasmGenError {
  import_index_fs_host_read_file(ctx) + 4
}

///|
fn import_index_fs_host_readdir(ctx : CodegenCtx) -> Int raise WasmGenError {
  import_index_fs_host_read_file(ctx) + 5
}

///|
fn import_index_fs_host_getcwd(ctx : CodegenCtx) -> Int raise WasmGenError {
  import_index_fs_host_read_file(ctx) + 6
}

///|
fn import_index_fs_host_chdir(ctx : CodegenCtx) -> Int raise WasmGenError {
  import_index_fs_host_read_file(ctx) + 7
}

///|
fn import_index_fs_host_is_dir(ctx : CodegenCtx) -> Int raise WasmGenError {
  import_index_fs_host_read_file(ctx) + 8
}

///|
fn import_index_fs_host_is_file(ctx : CodegenCtx) -> Int raise WasmGenError {
  import_index_fs_host_read_file(ctx) + 9
}

///|
fn import_index_fs_host_mkdir(ctx : CodegenCtx) -> Int raise WasmGenError {
  import_index_fs_host_read_file(ctx) + 10
}

///|
fn import_index_fs_host_mkdir_p(ctx : CodegenCtx) -> Int raise WasmGenError {
  import_index_fs_host_read_file(ctx) + 11
}

///|
fn import_index_fs_host_remove(ctx : CodegenCtx) -> Int raise WasmGenError {
  import_index_fs_host_read_file(ctx) + 12
}

///|
fn import_index_fs_host_rename(ctx : CodegenCtx) -> Int raise WasmGenError {
  import_index_fs_host_read_file(ctx) + 13
}

///|
fn import_index_fs_host_copy(ctx : CodegenCtx) -> Int raise WasmGenError {
  import_index_fs_host_read_file(ctx) + 14
}

///|
fn import_index_fs_host_append(ctx : CodegenCtx) -> Int raise WasmGenError {
  import_index_fs_host_read_file(ctx) + 15
}

///|
fn import_index_fs_host_open_write(ctx : CodegenCtx) -> Int raise WasmGenError {
  import_index_fs_host_read_file(ctx) + 16
}

///|
fn import_index_fs_host_write_chunk(ctx : CodegenCtx) -> Int raise WasmGenError {
  import_index_fs_host_read_file(ctx) + 17
}

///|
fn import_index_fs_host_close_write(ctx : CodegenCtx) -> Int raise WasmGenError {
  import_index_fs_host_read_file(ctx) + 18
}

///|
fn import_index_after_fs(ctx : CodegenCtx) -> Int {
  let mut idx = import_index_after_stdin(ctx)
  if ctx.need_fs && not(ctx.fs_host_imports) {
    idx += 7
  }
  if ctx.need_fs && ctx.fs_host_imports {
    idx += 19
  }
  if ctx.need_fs && ctx.fs_host_imports {
    // Json host imports: json_parse, json_stringify
    idx += 2
  }
  idx
}

///|
fn import_index_json_host_parse(ctx : CodegenCtx) -> Int raise WasmGenError {
  if not(ctx.need_fs && ctx.fs_host_imports) {
    raise WasmGenError::BackendLimit(backend="wasm", feature="json host import")
  }
  let mut idx = import_index_after_stdin(ctx)
  if ctx.need_fs && ctx.fs_host_imports {
    idx += 19
  }
  idx
}

///|
fn import_index_json_host_stringify(ctx : CodegenCtx) -> Int raise WasmGenError {
  import_index_json_host_parse(ctx) + 1
}

///|
fn import_index_socket_instance_network(
  ctx : CodegenCtx,
) -> Int raise WasmGenError {
  if not(ctx.need_socket) {
    raise WasmGenError::BackendLimit(
      backend="wasm",
      feature="socket WASI import",
    )
  }
  import_index_after_fs(ctx)
}

///|
fn import_index_socket_create_tcp(ctx : CodegenCtx) -> Int raise WasmGenError {
  import_index_socket_instance_network(ctx) + 1
}

///|
fn import_index_socket_start_connect(
  ctx : CodegenCtx,
) -> Int raise WasmGenError {
  import_index_socket_instance_network(ctx) + 2
}

///|
fn import_index_socket_finish_connect(
  ctx : CodegenCtx,
) -> Int raise WasmGenError {
  import_index_socket_instance_network(ctx) + 3
}

///|
fn import_index_socket_subscribe(ctx : CodegenCtx) -> Int raise WasmGenError {
  import_index_socket_instance_network(ctx) + 4
}

///|
fn import_index_socket_poll(ctx : CodegenCtx) -> Int raise WasmGenError {
  import_index_socket_instance_network(ctx) + 5
}

///|
fn import_index_socket_stream_read(ctx : CodegenCtx) -> Int raise WasmGenError {
  import_index_socket_instance_network(ctx) + 6
}

///|
fn import_index_socket_stream_write(ctx : CodegenCtx) -> Int raise WasmGenError {
  import_index_socket_instance_network(ctx) + 7
}

///|
fn import_index_socket_shutdown(ctx : CodegenCtx) -> Int raise WasmGenError {
  import_index_socket_instance_network(ctx) + 8
}

///|
fn import_index_socket_drop_tcp(ctx : CodegenCtx) -> Int raise WasmGenError {
  import_index_socket_instance_network(ctx) + 9
}

///|
fn import_index_socket_drop_input(ctx : CodegenCtx) -> Int raise WasmGenError {
  import_index_socket_instance_network(ctx) + 10
}

///|
fn import_index_socket_drop_output(ctx : CodegenCtx) -> Int raise WasmGenError {
  import_index_socket_instance_network(ctx) + 11
}

///|
fn import_index_socket_drop_pollable(
  ctx : CodegenCtx,
) -> Int raise WasmGenError {
  import_index_socket_instance_network(ctx) + 12
}

///|
fn import_index_after_socket(ctx : CodegenCtx) -> Int {
  let mut idx = import_index_after_fs(ctx)
  if ctx.need_socket {
    idx += 13
  }
  idx
}

///|
fn import_index_http_request(ctx : CodegenCtx) -> Int raise WasmGenError {
  if not(ctx.need_http && ctx.http_host_imports) {
    raise WasmGenError::BackendLimit(backend="wasm", feature="http host import")
  }
  import_index_after_socket(ctx)
}

///|
fn import_index_http_response_status(
  ctx : CodegenCtx,
) -> Int raise WasmGenError {
  import_index_http_request(ctx) + 1
}

///|
fn import_index_http_response_header(
  ctx : CodegenCtx,
) -> Int raise WasmGenError {
  import_index_http_request(ctx) + 2
}

///|
fn import_index_http_response_body(ctx : CodegenCtx) -> Int raise WasmGenError {
  import_index_http_request(ctx) + 3
}

///|
fn import_index_http_close(ctx : CodegenCtx) -> Int raise WasmGenError {
  import_index_http_request(ctx) + 4
}

///|
fn import_index_http_listen(ctx : CodegenCtx) -> Int raise WasmGenError {
  import_index_http_request(ctx) + 5
}

///|
fn import_index_http_accept(ctx : CodegenCtx) -> Int raise WasmGenError {
  import_index_http_request(ctx) + 6
}

///|
fn import_index_http_request_method(ctx : CodegenCtx) -> Int raise WasmGenError {
  import_index_http_request(ctx) + 7
}

///|
fn import_index_http_request_url(ctx : CodegenCtx) -> Int raise WasmGenError {
  import_index_http_request(ctx) + 8
}

///|
fn import_index_http_request_header(ctx : CodegenCtx) -> Int raise WasmGenError {
  import_index_http_request(ctx) + 9
}

///|
fn import_index_http_request_body(ctx : CodegenCtx) -> Int raise WasmGenError {
  import_index_http_request(ctx) + 10
}

///|
fn import_index_http_respond(ctx : CodegenCtx) -> Int raise WasmGenError {
  import_index_http_request(ctx) + 11
}

///|
fn socket_table_global_index(ctx : CodegenCtx) -> Int {
  (if ctx.use_heap_global { 1 } else { 0 }) +
  (if ctx.need_stack_switching { 1 } else { 0 }) +
  (if ctx.coverage_enabled { 2 } else { 0 }) +
  (if ctx.need_fs && not(ctx.fs_host_imports) { 1 } else { 0 })
}

///|
fn resolve_numeric_kind(
  ctx : CodegenCtx,
  left : @core.Expr,
  right : @core.Expr,
) -> ValueKind raise WasmGenError {
  let left_kind = infer_expr_kind(ctx, left)
  let right_kind = infer_expr_kind(ctx, right)
  if left_kind == right_kind {
    left_kind
  } else if left_kind == ValueKind::I64 {
    right_kind
  } else if right_kind == ValueKind::I64 {
    left_kind
  } else {
    let backend = if ctx.use_js_strings { "wasm-js-string" } else { "wasm" }
    raise WasmGenError::BackendLimit(backend~, feature="numeric kind mismatch")
  }
}

///|
fn tuple_return_kinds(ctx : CodegenCtx, ret : @core.Type?) -> Array[ValueKind]? {
  match ret {
    Some(@core.Type::Tuple(items)) =>
      if items.length() >= 2 {
        let kinds : Array[ValueKind] = []
        for item in items {
          kinds.push(value_kind_from_type(ctx, item))
        }
        Some(kinds)
      } else {
        None
      }
    _ => None
  }
}

///|
fn body_always_returns_tuple(
  body : @core.Module,
  arity : Int,
  self_name : String,
  eligible_fns? : Map[String, Int]? = None,
) -> Bool {
  if body.stmts.length() == 0 {
    return false
  }
  let last = body.stmts[body.stmts.length() - 1]
  match last {
    @core.Stmt::Expr(expr~, span=_) =>
      expr_always_returns_tuple(expr, arity, self_name, eligible_fns~)
    _ => false
  }
}

///|
fn expr_always_returns_tuple(
  expr : @core.Expr,
  arity : Int,
  self_name : String,
  eligible_fns? : Map[String, Int]? = None,
) -> Bool {
  match expr {
    @core.Expr::Tuple(items~, span=_) => items.length() == arity
    @core.Expr::If(cond=_, then_body~, else_body~, span=_) =>
      body_always_returns_tuple(then_body, arity, self_name, eligible_fns~) &&
      body_always_returns_tuple(else_body, arity, self_name, eligible_fns~)
    @core.Expr::Block(body~, span=_) =>
      body_always_returns_tuple(body, arity, self_name, eligible_fns~)
    @core.Expr::Match(scrutinee=_, arms~, span=_) => {
      if arms.length() == 0 {
        return false
      }
      for arm in arms {
        if not(
            expr_always_returns_tuple(arm.expr, arity, self_name, eligible_fns~),
          ) {
          return false
        }
      }
      true
    }
    @core.Expr::ForIn(value_name~, index_name~, iterable~, body~, span~) => {
      let desugared = if @core.is_string_for_in(span.start) {
        @core.desugar_for_in_string(
          value_name, index_name, iterable, body, span,
        )
      } else {
        @core.desugar_for_in(value_name, index_name, iterable, body, span)
      }
      body_always_returns_tuple(desugared, arity, self_name, eligible_fns~)
    }
    @core.Expr::Handle(body~, arms~, span=_) => {
      let body_ok = body_always_returns_tuple(
        body,
        arity,
        self_name,
        eligible_fns~,
      )
      if not(body_ok) {
        return false
      }
      for arm in arms {
        if not(
            expr_always_returns_tuple(arm.expr, arity, self_name, eligible_fns~),
          ) {
          return false
        }
      }
      true
    }
    @core.Expr::Call(name~, ..) =>
      // Self-recursive call or call to known multi-value function with matching arity
      name == self_name ||
      (match eligible_fns {
        Some(s) =>
          match s.get(name) {
            Some(a) => a == arity
            None => false
          }
        None => false
      })
    _ => false
  }
}

///|
/// Tagged integer arithmetic operations
/// Tagged int format: (n << 2) | tag_int
/// Since tag_int = 0, add/sub work directly on tagged values
/// For mul/div: untag both, compute, retag
