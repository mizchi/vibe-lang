///|
fn compile_expr_i32(
  ctx : CodegenCtx,
  buf : ByteBuf,
  expr : @core.Expr,
) -> Unit raise WasmGenError {
  if ctx.use_js_strings {
    let kind = infer_expr_kind(ctx, expr)
    if kind == ValueKind::ExternRef {
      raise WasmGenError::BackendLimit(backend="wasm-js-string", feature="i32 expression")
    }
  }
  compile_expr(ctx, buf, expr)
}

///|
fn compile_expr_ref(
  ctx : CodegenCtx,
  buf : ByteBuf,
  expr : @core.Expr,
) -> Unit raise WasmGenError {
  if ctx.use_js_strings {
    let kind = infer_expr_kind(ctx, expr)
    if kind != ValueKind::ExternRef {
      raise WasmGenError::BackendLimit(backend="wasm-js-string", feature="ref expression")
    }
  }
  compile_expr(ctx, buf, expr)
}

///|
fn emit_boxed_f32(
  ctx : CodegenCtx,
  buf : ByteBuf,
  emit_value : () -> Unit,
) -> Unit raise WasmGenError {
  require_heap(ctx)
  let size = align4(8)
  let obj_local = alloc_temp_local(ctx)
  emit_heap_alloc(ctx, buf, size, obj_local)
  emit_local_get(buf, obj_local)
  emit_i32_const_raw(buf, obj_float)
  emit_i32_store(buf, 0)
  emit_local_get(buf, obj_local)
  emit_value()
  emit_f32_store(buf, 4)
  emit_local_get(buf, obj_local)
  emit_i64_extend_i32_u(buf)
  emit_i64_const_raw(buf, tag_obj.to_int64())
  emit_i64_or(buf)
}

///|
fn emit_boxed_f64(
  ctx : CodegenCtx,
  buf : ByteBuf,
  emit_value : () -> Unit,
) -> Unit raise WasmGenError {
  require_heap(ctx)
  let size = align4(12)
  let obj_local = alloc_temp_local(ctx)
  emit_heap_alloc(ctx, buf, size, obj_local)
  emit_local_get(buf, obj_local)
  emit_i32_const_raw(buf, obj_double)
  emit_i32_store(buf, 0)
  emit_local_get(buf, obj_local)
  emit_value()
  emit_f64_store(buf, 4)
  emit_local_get(buf, obj_local)
  emit_i64_extend_i32_u(buf)
  emit_i64_const_raw(buf, tag_obj.to_int64())
  emit_i64_or(buf)
}

///|
fn emit_boxed_f32_raise(
  ctx : CodegenCtx,
  buf : ByteBuf,
  emit_value : () -> Unit raise WasmGenError,
) -> Unit raise WasmGenError {
  require_heap(ctx)
  let size = align4(8)
  let obj_local = alloc_temp_local(ctx)
  emit_heap_alloc(ctx, buf, size, obj_local)
  emit_local_get(buf, obj_local)
  emit_i32_const_raw(buf, obj_float)
  emit_i32_store(buf, 0)
  emit_local_get(buf, obj_local)
  emit_value()
  emit_f32_store(buf, 4)
  emit_local_get(buf, obj_local)
  emit_i64_extend_i32_u(buf)
  emit_i64_const_raw(buf, tag_obj.to_int64())
  emit_i64_or(buf)
}

///|
fn emit_boxed_f64_raise(
  ctx : CodegenCtx,
  buf : ByteBuf,
  emit_value : () -> Unit raise WasmGenError,
) -> Unit raise WasmGenError {
  require_heap(ctx)
  let size = align4(12)
  let obj_local = alloc_temp_local(ctx)
  emit_heap_alloc(ctx, buf, size, obj_local)
  emit_local_get(buf, obj_local)
  emit_i32_const_raw(buf, obj_double)
  emit_i32_store(buf, 0)
  emit_local_get(buf, obj_local)
  emit_value()
  emit_f64_store(buf, 4)
  emit_local_get(buf, obj_local)
  emit_i64_extend_i32_u(buf)
  emit_i64_const_raw(buf, tag_obj.to_int64())
  emit_i64_or(buf)
}

///|
fn emit_unbox_f32_expr(
  ctx : CodegenCtx,
  buf : ByteBuf,
  expr : @core.Expr,
) -> Unit raise WasmGenError {
  let tmp = alloc_temp_local(ctx)
  compile_expr_i32(ctx, buf, expr)
  emit_local_set(buf, tmp)
  emit_untag_ptr(buf, tmp)
  emit_f32_load(buf, 4)
}

///|
fn emit_unbox_f64_expr(
  ctx : CodegenCtx,
  buf : ByteBuf,
  expr : @core.Expr,
) -> Unit raise WasmGenError {
  let tmp = alloc_temp_local(ctx)
  compile_expr_i32(ctx, buf, expr)
  emit_local_set(buf, tmp)
  emit_untag_ptr(buf, tmp)
  emit_f64_load(buf, 4)
}

///|
fn scan_needs_expr(ctx : CodegenCtx, expr : @core.Expr) -> Unit {
  match expr {
    @core.Expr::Call(name~, args~, span~, ..) => {
      let _ = span
      if name == "sh" {
        ctx.need_sh = true
      } else if name == "path" {
        ctx.need_path = true
      } else if name == "string_length" {
        if ctx.use_js_strings {
          ctx.need_js_length = true
        }
      } else if name == "string_char_code_at" {
        if ctx.use_js_strings {
          ctx.need_js_char_code_at = true
        }
      } else if name == "string_substring" {
        if ctx.use_js_strings {
          ctx.need_js_substring = true
        }
      } else if name == "string_concat" {
        if ctx.use_js_strings {
          ctx.need_js_concat = true
        }
      } else if name == "string_equals" {
        if ctx.use_js_strings {
          ctx.need_js_equals = true
        }
      } else if name == "array_builder" ||
        name == "map_builder" ||
        name == "string_builder" {
        ctx.need_heap = true
      } else if name == "map_get" {
        if ctx.use_js_strings {
          ctx.need_js_equals = true
        }
      } else if name == "sleep" {
        ctx.need_sleep = true
      } else if name == "stdout_write_char" {
        ctx.need_stdout_write_char = true
      } else if name == "stdout_write_stream" {
        ctx.need_stdout_write_char = true
      } else if name == "stdin_read_char" {
        ctx.need_stdin_read_char = true
      } else if name == "stdin_read_stream" {
        ctx.need_stdin_read_char = true
      } else if name == "string_from_char_code" {
        ctx.need_heap = true
      } else if name == "char_to_int" || name == "char_from_int" {
        ()
      } else if name == "__to_string" {
        if not(ctx.use_js_strings) {
          ctx.need_heap = true
        }
      } else if name == "to_double" {
        ctx.need_heap = true
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
    @core.Expr::Try(try_body~, catch_body~, span~) => {
      let _ = span
      ctx.need_exceptions = true
      scan_needs_block(ctx, try_body)
      scan_needs_block(ctx, catch_body)
    }
    @core.Expr::Raise(value~, span~) => {
      let _ = span
      ctx.need_exceptions = true
      scan_needs_expr(ctx, value)
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
    @core.Expr::Do(body~, span~) => {
      let _ = span
      scan_needs_block(ctx, body)
    }
    @core.Expr::Fn(params~, ret~, effects=_, body~, span~, ..) => {
      let _ = span
      let _ = params
      let _ = ret
      let key = span_key(span)
      match ctx.fn_closure_captures.get(key) {
        Some(captures) => if captures.length() > 0 { ctx.need_heap = true }
        None => ()
      }
      scan_needs_block(ctx, body)
    }
    @core.Expr::Await(expr~, span~) => {
      let _ = span
      ctx.need_stack_switching = true
      scan_needs_expr(ctx, expr)
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
    @core.Stmt::EnumDef(name~, params~, ctors~, span~) => {
      let _ = name
      let _ = params
      let _ = span
      for i in 0..<ctors.length() {
        let ctor = ctors[i]
        ctx.enum_ctor_tags[ctor.name] = i
        ctx.enum_ctor_arities[ctor.name] = ctor.args.length()
        let arg_kinds : Array[ValueKind] = []
        for arg in ctor.args {
          arg_kinds.push(value_kind_from_type(ctx, arg))
        }
        ctx.enum_ctor_arg_kinds[ctor.name] = arg_kinds
      }
    }
    @core.Stmt::ExportEnumDef(name~, params~, ctors~, span~) =>
      scan_needs_stmt(ctx, @core.Stmt::EnumDef(name~, params~, ctors~, span~))
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
    @core.Expr::Do(body~, span~) => {
      let _ = span
      scan_strings(ctx, body)
    }
    @core.Expr::Try(try_body~, catch_body~, span~) => {
      let _ = span
      scan_strings(ctx, try_body)
      scan_strings(ctx, catch_body)
    }
    @core.Expr::Fn(params~, ret~, effects~, body~, span~, ..) => {
      let _ = params
      let _ = ret
      let _ = effects
      let _ = span
      scan_strings(ctx, body)
    }
    @core.Expr::Raise(value~, span~) => {
      let _ = span
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

///|
fn compile_i32_add_tagged(
  ctx : CodegenCtx,
  buf : ByteBuf,
  left : @core.Expr,
  right : @core.Expr,
) -> Unit raise WasmGenError {
  compile_expr_i32(ctx, buf, left)
  compile_expr_i32(ctx, buf, right)
  emit_i64_add(buf)
  // Correction only needed if tag_int != 0
  // Currently tag_int = 0, so no correction needed
}

///|
fn compile_i32_sub_tagged(
  ctx : CodegenCtx,
  buf : ByteBuf,
  left : @core.Expr,
  right : @core.Expr,
) -> Unit raise WasmGenError {
  compile_expr_i32(ctx, buf, left)
  compile_expr_i32(ctx, buf, right)
  emit_i64_sub(buf)
  // Correction only needed if tag_int != 0
  // Currently tag_int = 0, so no correction needed
}

///|
fn compile_i32_mul_tagged(
  ctx : CodegenCtx,
  buf : ByteBuf,
  left : @core.Expr,
  right : @core.Expr,
) -> Unit raise WasmGenError {
  // Untag first operand
  compile_expr_i32(ctx, buf, left)
  emit_i64_const_raw(buf, 2L)
  emit_i64_shr_s(buf)
  // Untag second operand
  compile_expr_i32(ctx, buf, right)
  emit_i64_const_raw(buf, 2L)
  emit_i64_shr_s(buf)
  // Multiply
  emit_i64_mul(buf)
  // Retag result
  emit_i64_const_raw(buf, 2L)
  emit_i64_shl(buf)
  emit_i64_const_raw(buf, tag_int.to_int64())
  emit_i64_or(buf)
}

///|
fn compile_i32_div_tagged(
  ctx : CodegenCtx,
  buf : ByteBuf,
  left : @core.Expr,
  right : @core.Expr,
) -> Unit raise WasmGenError {
  // Untag first operand
  compile_expr_i32(ctx, buf, left)
  emit_i64_const_raw(buf, 2L)
  emit_i64_shr_s(buf)
  // Untag second operand
  compile_expr_i32(ctx, buf, right)
  emit_i64_const_raw(buf, 2L)
  emit_i64_shr_s(buf)
  // Divide (signed)
  emit_i64_div_s(buf)
  // Retag result
  emit_i64_const_raw(buf, 2L)
  emit_i64_shl(buf)
  emit_i64_const_raw(buf, tag_int.to_int64())
  emit_i64_or(buf)
}

///|
fn compile_i32_mod_tagged(
  ctx : CodegenCtx,
  buf : ByteBuf,
  left : @core.Expr,
  right : @core.Expr,
) -> Unit raise WasmGenError {
  // Untag first operand
  compile_expr_i32(ctx, buf, left)
  emit_i64_const_raw(buf, 2L)
  emit_i64_shr_s(buf)
  // Untag second operand
  compile_expr_i32(ctx, buf, right)
  emit_i64_const_raw(buf, 2L)
  emit_i64_shr_s(buf)
  // Remainder (signed)
  emit_i64_rem_s(buf)
  // Retag result
  emit_i64_const_raw(buf, 2L)
  emit_i64_shl(buf)
  emit_i64_const_raw(buf, tag_int.to_int64())
  emit_i64_or(buf)
}

///|
fn compile_binary_arith_op(
  ctx : CodegenCtx,
  buf : ByteBuf,
  name : String,
  args : Array[@core.CallArg],
  emit_f32 : (ByteBuf) -> Unit,
  emit_f64 : (ByteBuf) -> Unit,
) -> Unit raise WasmGenError {
  let pos_args = extract_positional_exprs(args, name)
  if pos_args.length() != 2 {
    raise WasmGenError::Unsupported(name + " arity")
  }
  let resolved_kind = resolve_numeric_kind(ctx, pos_args[0], pos_args[1])
  match resolved_kind {
    ValueKind::I32 | ValueKind::I64 =>
      // Tagged i64 arithmetic is handled by dedicated functions
      // This branch should not be reached if called correctly
      raise WasmGenError::Unsupported("i64 arith via compile_binary_arith_op")
    ValueKind::BoxedF32 =>
      emit_boxed_f32_raise(ctx, buf, fn() raise WasmGenError {
        emit_unbox_f32_expr(ctx, buf, pos_args[0])
        emit_unbox_f32_expr(ctx, buf, pos_args[1])
        emit_f32(buf)
      })
    ValueKind::BoxedF64 =>
      emit_boxed_f64_raise(ctx, buf, fn() raise WasmGenError {
        emit_unbox_f64_expr(ctx, buf, pos_args[0])
        emit_unbox_f64_expr(ctx, buf, pos_args[1])
        emit_f64(buf)
      })
    _ => raise WasmGenError::Unsupported("numeric kind")
  }
}

///|
fn compile_binary_cmp_op(
  ctx : CodegenCtx,
  buf : ByteBuf,
  name : String,
  args : Array[@core.CallArg],
  emit_i64_cmp : (ByteBuf) -> Unit,
  emit_f32 : (ByteBuf) -> Unit,
  emit_f64 : (ByteBuf) -> Unit,
) -> Unit raise WasmGenError {
  let pos_args = extract_positional_exprs(args, name)
  if pos_args.length() != 2 {
    raise WasmGenError::Unsupported(name + " arity")
  }
  let resolved_kind = resolve_numeric_kind(ctx, pos_args[0], pos_args[1])
  match resolved_kind {
    ValueKind::I32 | ValueKind::I64 => {
      // Dynamic numeric comparison for generic Num paths (e.g. prelude eq/lt):
      // when tagged objects are boxed float/double, compare payload values.
      let left_local = alloc_temp_local_with_kind(ctx, ValueKind::I64)
      let right_local = alloc_temp_local_with_kind(ctx, ValueKind::I64)
      let left_tag_local = alloc_temp_local(ctx)
      let right_tag_local = alloc_temp_local(ctx)
      let left_ptr_local = alloc_temp_local(ctx)
      let right_ptr_local = alloc_temp_local(ctx)
      let left_type_local = alloc_temp_local(ctx)
      let right_type_local = alloc_temp_local(ctx)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_local_set(buf, left_local)
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_local_set(buf, right_local)
      // Extract tags (i64 -> i64, then wrap to i32 for tag locals)
      emit_local_get(buf, left_local)
      emit_i64_const_raw(buf, tag_mask.to_int64())
      emit_i64_and(buf)
      emit_i32_wrap_i64(buf)
      emit_local_set(buf, left_tag_local)
      emit_local_get(buf, right_local)
      emit_i64_const_raw(buf, tag_mask.to_int64())
      emit_i64_and(buf)
      emit_i32_wrap_i64(buf)
      emit_local_set(buf, right_tag_local)
      emit_local_get(buf, left_tag_local)
      emit_i32_const_raw(buf, tag_obj)
      emit_i32_eq(buf)
      emit_local_get(buf, right_tag_local)
      emit_i32_const_raw(buf, tag_obj)
      emit_i32_eq(buf)
      emit_i32_and(buf)
      buf.push((4).to_byte()) // if
      buf.push((127).to_byte()) // result i32
      // Untag pointers to i32 addresses
      emit_local_get(buf, left_local)
      emit_i64_const_raw(buf, (-4).to_int64())
      emit_i64_and(buf)
      emit_i32_wrap_i64(buf)
      emit_local_set(buf, left_ptr_local)
      emit_local_get(buf, right_local)
      emit_i64_const_raw(buf, (-4).to_int64())
      emit_i64_and(buf)
      emit_i32_wrap_i64(buf)
      emit_local_set(buf, right_ptr_local)
      emit_local_get(buf, left_ptr_local)
      emit_i32_load(buf, 0)
      emit_local_set(buf, left_type_local)
      emit_local_get(buf, right_ptr_local)
      emit_i32_load(buf, 0)
      emit_local_set(buf, right_type_local)
      emit_local_get(buf, left_type_local)
      emit_i32_const_raw(buf, obj_float)
      emit_i32_eq(buf)
      emit_local_get(buf, right_type_local)
      emit_i32_const_raw(buf, obj_float)
      emit_i32_eq(buf)
      emit_i32_and(buf)
      buf.push((4).to_byte()) // if
      buf.push((127).to_byte()) // result i32
      emit_local_get(buf, left_ptr_local)
      emit_f32_load(buf, 4)
      emit_local_get(buf, right_ptr_local)
      emit_f32_load(buf, 4)
      emit_f32(buf)
      buf.push((5).to_byte()) // else
      emit_local_get(buf, left_type_local)
      emit_i32_const_raw(buf, obj_double)
      emit_i32_eq(buf)
      emit_local_get(buf, right_type_local)
      emit_i32_const_raw(buf, obj_double)
      emit_i32_eq(buf)
      emit_i32_and(buf)
      buf.push((4).to_byte()) // if
      buf.push((127).to_byte()) // result i32
      emit_local_get(buf, left_ptr_local)
      emit_f64_load(buf, 4)
      emit_local_get(buf, right_ptr_local)
      emit_f64_load(buf, 4)
      emit_f64(buf)
      buf.push((5).to_byte()) // else
      // Compare tagged i64 values directly
      emit_local_get(buf, left_local)
      emit_local_get(buf, right_local)
      emit_i64_cmp(buf)
      buf.push((11).to_byte()) // end if
      buf.push((11).to_byte()) // end if
      buf.push((5).to_byte()) // else
      // Compare tagged i64 values directly
      emit_local_get(buf, left_local)
      emit_local_get(buf, right_local)
      emit_i64_cmp(buf)
      buf.push((11).to_byte()) // end if
      // Convert i32 comparison result to tagged i64 bool
      emit_i64_extend_i32_s(buf)
      emit_i64_const_raw(buf, 2L)
      emit_i64_shl(buf)
      emit_i64_const_raw(buf, tag_bool.to_int64())
      emit_i64_or(buf)
    }
    ValueKind::BoxedF32 => {
      emit_unbox_f32_expr(ctx, buf, pos_args[0])
      emit_unbox_f32_expr(ctx, buf, pos_args[1])
      emit_f32(buf)
      // Convert i32 comparison result to tagged i64 bool
      emit_i64_extend_i32_s(buf)
      emit_i64_const_raw(buf, 2L)
      emit_i64_shl(buf)
      emit_i64_const_raw(buf, tag_bool.to_int64())
      emit_i64_or(buf)
    }
    ValueKind::BoxedF64 => {
      emit_unbox_f64_expr(ctx, buf, pos_args[0])
      emit_unbox_f64_expr(ctx, buf, pos_args[1])
      emit_f64(buf)
      // Convert i32 comparison result to tagged i64 bool
      emit_i64_extend_i32_s(buf)
      emit_i64_const_raw(buf, 2L)
      emit_i64_shl(buf)
      emit_i64_const_raw(buf, tag_bool.to_int64())
      emit_i64_or(buf)
    }
    _ => raise WasmGenError::Unsupported("numeric kind")
  }
}

///|
fn emit_i32_result_as_tagged_int(buf : ByteBuf) -> Unit {
  emit_i64_extend_i32_s(buf)
  emit_i64_const_raw(buf, 2L)
  emit_i64_shl(buf)
  emit_i64_const_raw(buf, tag_int.to_int64())
  emit_i64_or(buf)
}

///|
fn compile_i32_cmp_to_tagged_int(
  ctx : CodegenCtx,
  buf : ByteBuf,
  name : String,
  args : Array[@core.CallArg],
  emit_cmp : (ByteBuf) -> Unit,
) -> Unit raise WasmGenError {
  let pos_args = extract_positional_exprs(args, name)
  if pos_args.length() != 2 {
    raise WasmGenError::Unsupported(name + " arity")
  }
  compile_expr_i32(ctx, buf, pos_args[0])
  emit_i64_const_raw(buf, 2L)
  emit_i64_shr_s(buf)
  emit_i32_wrap_i64(buf)
  compile_expr_i32(ctx, buf, pos_args[1])
  emit_i64_const_raw(buf, 2L)
  emit_i64_shr_s(buf)
  emit_i32_wrap_i64(buf)
  emit_cmp(buf)
  emit_i32_result_as_tagged_int(buf)
}

///|
fn compile_f32_cmp_to_tagged_int(
  ctx : CodegenCtx,
  buf : ByteBuf,
  name : String,
  args : Array[@core.CallArg],
  emit_cmp : (ByteBuf) -> Unit,
) -> Unit raise WasmGenError {
  let pos_args = extract_positional_exprs(args, name)
  if pos_args.length() != 2 {
    raise WasmGenError::Unsupported(name + " arity")
  }
  emit_unbox_f32_expr(ctx, buf, pos_args[0])
  emit_unbox_f32_expr(ctx, buf, pos_args[1])
  emit_cmp(buf)
  emit_i32_result_as_tagged_int(buf)
}

///|
fn compile_f64_cmp_to_tagged_int(
  ctx : CodegenCtx,
  buf : ByteBuf,
  name : String,
  args : Array[@core.CallArg],
  emit_cmp : (ByteBuf) -> Unit,
) -> Unit raise WasmGenError {
  let pos_args = extract_positional_exprs(args, name)
  if pos_args.length() != 2 {
    raise WasmGenError::Unsupported(name + " arity")
  }
  emit_unbox_f64_expr(ctx, buf, pos_args[0])
  emit_unbox_f64_expr(ctx, buf, pos_args[1])
  emit_cmp(buf)
  emit_i32_result_as_tagged_int(buf)
}

///|
/// Adjust loop break/continue offsets when entering/leaving WASM label scopes
fn adjust_loop_offsets(ctx : CodegenCtx, delta : Int) -> Unit {
  if ctx.loop_break_offset >= 0 {
    ctx.loop_break_offset += delta
    ctx.loop_continue_offset += delta
  }
}

///|
fn compile_expr(
  ctx : CodegenCtx,
  buf : ByteBuf,
  expr : @core.Expr,
) -> Unit raise WasmGenError {
  match expr {
    @core.Expr::Int(value=n, span~) => {
      let _ = span
      emit_i64_const_tagged(buf, n)
    }
    @core.Expr::Float(value=n, span~) => {
      let _ = span
      emit_boxed_f32(ctx, buf, () => emit_f32_const(buf, n))
    }
    @core.Expr::Double(value=n, span~) => {
      let _ = span
      emit_boxed_f64(ctx, buf, () => emit_f64_const(buf, n))
    }
    @core.Expr::Bool(value=b, span~) => {
      let _ = span
      emit_i64_const_raw(buf, tag_bool_value64(b))
    }
    @core.Expr::Char(value=c, span~) => {
      let _ = span
      emit_i64_const_tagged(buf, c.to_int().to_int64())
    }
    @core.Expr::String(value=s, span~) => {
      let _ = span
      if ctx.use_js_strings {
        let idx = ctx.js_strings.intern(s)
        emit_global_get(buf, idx)
      } else {
        let offset = ctx.strings.intern(s)
        emit_i64_const_raw(buf, tag_ptr64(offset, tag_obj))
      }
    }
    @core.Expr::Ident(name~, span~) => {
      let _ = span
      if is_qualified_name(name) {
        raise WasmGenError::BackendLimit(backend="wasm", feature="qualified name: " + name)
      }
      match ctx.locals.get(name) {
        Some(idx) => emit_local_get(buf, idx)
        None =>
          match ctx.fn_indices.get(name) {
            Some(idx) => {
              if fn_index_needs_env(ctx, idx) {
                raise WasmGenError::Unsupported(
                  "function value requires closure env in scope: " + name,
                )
              }
              let slot = ensure_funcref_slot(ctx, idx)
              emit_i64_const_raw(buf, tag_fn_value64(slot.to_int64()))
            }
            None =>
              if ctx.enum_ctor_tags.contains(name) {
                // Nullary enum constructor
                let tag = match ctx.enum_ctor_tags.get(name) {
                  Some(t) => t
                  None => 0
                }
                require_heap(ctx)
                let size = align4(8)
                let obj_local = alloc_temp_local(ctx)
                emit_heap_alloc(ctx, buf, size, obj_local)
                emit_local_get(buf, obj_local)
                emit_i32_const_raw(buf, obj_enum)
                emit_i32_store(buf, 0)
                emit_local_get(buf, obj_local)
                emit_i32_const_raw(buf, tag)
                emit_i32_store(buf, 4)
                emit_local_get(buf, obj_local)
                emit_i64_extend_i32_u(buf)
                emit_i64_const_raw(buf, tag_obj.to_int64())
                emit_i64_or(buf)
              } else {
                raise WasmGenError::UnknownName(name)
              }
          }
      }
    }
    @core.Expr::Placeholder(..) =>
      // Placeholder should be desugared before codegen
      raise WasmGenError::Unsupported("placeholder in codegen")
    @core.Expr::Call(name~, args~, span~, ..) => {
      let _ = span
      let name = @core.lower_wasm_intrinsic_name(name)
      if ctx.fn_local_sigs.contains(name) &&
        ctx.locals.contains(name) &&
        not(ctx.enum_ctor_tags.contains(name)) {
        let sig = match ctx.fn_local_sigs.get(name) {
          Some(s) => s
          None => raise WasmGenError::BackendLimit(backend="wasm", feature="call: " + name)
        }
        let pos_args = extract_positional_exprs(args, name)
        let sig_param_len = if sig.params.length() > 0 {
          sig.params.length() - 1
        } else {
          0
        }
        if pos_args.length() != sig_param_len {
          raise WasmGenError::Unsupported("arity: " + name)
        }
        let fn_value_idx = match ctx.locals.get(name) {
          Some(idx) => idx
          None => raise WasmGenError::UnknownName(name)
        }
        let env_idx = alloc_temp_local(ctx)
        let func_idx = alloc_temp_local(ctx)
        // Check if fn value is a bare function (tag_fn) or closure (tag_obj)
        emit_local_get(buf, fn_value_idx)
        emit_i64_const_raw(buf, tag_mask.to_int64())
        emit_i64_and(buf)
        emit_i64_const_raw(buf, tag_fn.to_int64())
        emit_i64_eq(buf)
        buf.push((4).to_byte())
        buf.push((64).to_byte())
        // Bare function: env = 0, extract func index from tagged i64
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, env_idx)
        emit_local_get(buf, fn_value_idx)
        emit_i64_const_raw(buf, tag_fn.to_int64())
        emit_i64_sub(buf)
        emit_i64_const_raw(buf, 2L)
        emit_i64_shr_u(buf)
        emit_i32_wrap_i64(buf)
        emit_local_set(buf, func_idx)
        buf.push((5).to_byte())
        // Closure: untag ptr, load func index from memory
        emit_untag_ptr(buf, fn_value_idx)
        emit_local_set(buf, env_idx)
        emit_local_get(buf, env_idx)
        emit_i32_load(buf, 4)
        emit_local_set(buf, func_idx)
        buf.push((11).to_byte())
        for i in 0..<sig_param_len {
          let kind = sig.params[i]
          if ctx.use_js_strings && kind == ValueKind::ExternRef {
            compile_expr_ref(ctx, buf, pos_args[i])
          } else {
            compile_expr_i32(ctx, buf, pos_args[i])
          }
        }
        emit_local_get(buf, env_idx)
        emit_local_get(buf, func_idx)
        let type_idx = match ctx.fn_sig_type_indices.get(func_sig_key(sig)) {
          Some(idx) => idx
          None => raise WasmGenError::BackendLimit(backend="wasm", feature="call: " + name)
        }
        // Sync heap pointer to global before call so callee sees current heap
        if ctx.heap_local >= 0 && ctx.use_heap_global {
          emit_local_get(buf, ctx.heap_local)
          emit_global_set(buf, ctx.heap_global)
        }
        emit_call_indirect(buf, type_idx)
        // Reload heap pointer from global after call (callee may have bumped it)
        if ctx.heap_local >= 0 && ctx.use_heap_global {
          emit_global_get(buf, ctx.heap_global)
          emit_local_set(buf, ctx.heap_local)
        }
      } else if ctx.locals.contains(name) &&
        not(ctx.enum_ctor_tags.contains(name)) {
        let pos_args = extract_positional_exprs(args, name)
        if not(ctx.fn_local_sigs.contains(name)) {
          let guessed_params : Array[ValueKind] = []
          for arg in pos_args {
            let arg_kind = if ctx.use_js_strings {
              infer_expr_kind(ctx, arg)
            } else {
              ValueKind::I32
            }
            if ctx.use_js_strings && arg_kind == ValueKind::ExternRef {
              guessed_params.push(ValueKind::ExternRef)
            } else {
              guessed_params.push(ValueKind::I32)
            }
          }
          let guessed_result = if ctx.use_js_strings {
            let kind = infer_expr_kind(ctx, expr)
            if kind == ValueKind::ExternRef {
              ValueKind::ExternRef
            } else {
              ValueKind::I32
            }
          } else {
            ValueKind::I32
          }
          ctx.fn_local_sigs[name] = func_sig_with_env(
            guessed_params, guessed_result,
          )
        }
        let sig = match ctx.fn_local_sigs.get(name) {
          Some(s) => s
          None => raise WasmGenError::BackendLimit(backend="wasm", feature="call: " + name)
        }
        let sig_param_len = if sig.params.length() > 0 {
          sig.params.length() - 1
        } else {
          0
        }
        if pos_args.length() != sig_param_len {
          raise WasmGenError::Unsupported("arity: " + name)
        }
        let fn_value_idx = match ctx.locals.get(name) {
          Some(idx) => idx
          None => raise WasmGenError::UnknownName(name)
        }
        let env_idx = alloc_temp_local(ctx)
        let func_idx = alloc_temp_local(ctx)
        // Check if fn value is a bare function (tag_fn) or closure (tag_obj)
        emit_local_get(buf, fn_value_idx)
        emit_i64_const_raw(buf, tag_mask.to_int64())
        emit_i64_and(buf)
        emit_i64_const_raw(buf, tag_fn.to_int64())
        emit_i64_eq(buf)
        buf.push((4).to_byte())
        buf.push((64).to_byte())
        // Bare function: env = 0, extract func index from tagged i64
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, env_idx)
        emit_local_get(buf, fn_value_idx)
        emit_i64_const_raw(buf, tag_fn.to_int64())
        emit_i64_sub(buf)
        emit_i64_const_raw(buf, 2L)
        emit_i64_shr_u(buf)
        emit_i32_wrap_i64(buf)
        emit_local_set(buf, func_idx)
        buf.push((5).to_byte())
        // Closure: untag ptr, load func index from memory
        emit_untag_ptr(buf, fn_value_idx)
        emit_local_set(buf, env_idx)
        emit_local_get(buf, env_idx)
        emit_i32_load(buf, 4)
        emit_local_set(buf, func_idx)
        buf.push((11).to_byte())
        for i in 0..<sig_param_len {
          let kind = sig.params[i]
          if ctx.use_js_strings && kind == ValueKind::ExternRef {
            compile_expr_ref(ctx, buf, pos_args[i])
          } else {
            compile_expr_i32(ctx, buf, pos_args[i])
          }
        }
        emit_local_get(buf, env_idx)
        emit_local_get(buf, func_idx)
        let type_idx = match ctx.fn_sig_type_indices.get(func_sig_key(sig)) {
          Some(idx) => idx
          None => {
            let new_idx = ensure_sig_index(ctx, sig)
            ctx.fn_sig_type_indices[func_sig_key(sig)] = new_idx
            new_idx
          }
        }
        if ctx.heap_local >= 0 && ctx.use_heap_global {
          emit_local_get(buf, ctx.heap_local)
          emit_global_set(buf, ctx.heap_global)
        }
        emit_call_indirect(buf, type_idx)
        if ctx.heap_local >= 0 && ctx.use_heap_global {
          emit_global_get(buf, ctx.heap_global)
          emit_local_set(buf, ctx.heap_local)
        }
      } else if name == "sh" {
        let pos_args = extract_positional_exprs(args, "sh")
        if pos_args.length() != 1 {
          raise WasmGenError::Unsupported("sh arity")
        }
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_call(buf, import_index_sh(ctx))
        emit_drop(buf)
        emit_i64_const_tagged(buf, 0L)
      } else if name == "path" {
        let pos_args = extract_positional_exprs(args, "path")
        if pos_args.length() != 1 {
          raise WasmGenError::Unsupported("path arity")
        }
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_call(buf, import_index_path(ctx))
      } else if name == "add" && not(ctx.fn_indices.contains(name)) {
        let pos_args = extract_positional_exprs(args, "add")
        if pos_args.length() != 2 {
          raise WasmGenError::Unsupported("add arity")
        }
        compile_i32_add_tagged(ctx, buf, pos_args[0], pos_args[1])
      } else if name == "sub" && not(ctx.fn_indices.contains(name)) {
        let pos_args = extract_positional_exprs(args, "sub")
        if pos_args.length() != 2 {
          raise WasmGenError::Unsupported("sub arity")
        }
        compile_i32_sub_tagged(ctx, buf, pos_args[0], pos_args[1])
      } else if name == "mul" && not(ctx.fn_indices.contains(name)) {
        let pos_args = extract_positional_exprs(args, "mul")
        if pos_args.length() != 2 {
          raise WasmGenError::Unsupported("mul arity")
        }
        compile_i32_mul_tagged(ctx, buf, pos_args[0], pos_args[1])
      } else if name == "div" && not(ctx.fn_indices.contains(name)) {
        let pos_args = extract_positional_exprs(args, "div")
        if pos_args.length() != 2 {
          raise WasmGenError::Unsupported("div arity")
        }
        compile_i32_div_tagged(ctx, buf, pos_args[0], pos_args[1])
      } else if name == "eq" && not(ctx.fn_indices.contains(name)) {
        compile_binary_cmp_op(
          ctx, buf, "eq", args, emit_i64_eq, emit_f32_eq, emit_f64_eq,
        )
      } else if name == "lt" && not(ctx.fn_indices.contains(name)) {
        compile_binary_cmp_op(
          ctx, buf, "lt", args, emit_i64_lt_s, emit_f32_lt, emit_f64_lt,
        )
      } else if name == "assert" && not(ctx.fn_indices.contains(name)) {
        let pos_args = extract_positional_exprs(args, "assert")
        if pos_args.length() != 1 {
          raise WasmGenError::Unsupported("assert arity")
        }
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_i64_const_raw(buf, tag_bool_value64(true))
        emit_i64_eq(buf)
        emit_i32_eqz(buf)
        buf.push((4).to_byte()) // if
        buf.push((64).to_byte()) // empty result
        buf.push((0).to_byte()) // unreachable (trap)
        buf.push((11).to_byte()) // end if
        emit_i64_const_tagged(buf, 0L)
      } else if name == "__add" {
        let pos_args = extract_positional_exprs(args, "__add")
        if pos_args.length() != 2 {
          raise WasmGenError::Unsupported("__add arity")
        }
        let resolved_kind = resolve_numeric_kind(ctx, pos_args[0], pos_args[1])
        match resolved_kind {
          ValueKind::I32 | ValueKind::I64 =>
            compile_i32_add_tagged(ctx, buf, pos_args[0], pos_args[1])
          _ =>
            compile_binary_arith_op(
              ctx, buf, "__add", args, emit_f32_add, emit_f64_add,
            )
        }
      } else if name == "__sub" {
        let pos_args = extract_positional_exprs(args, "__sub")
        if pos_args.length() != 2 {
          raise WasmGenError::Unsupported("__sub arity")
        }
        let resolved_kind = resolve_numeric_kind(ctx, pos_args[0], pos_args[1])
        match resolved_kind {
          ValueKind::I32 | ValueKind::I64 =>
            compile_i32_sub_tagged(ctx, buf, pos_args[0], pos_args[1])
          _ =>
            compile_binary_arith_op(
              ctx, buf, "__sub", args, emit_f32_sub, emit_f64_sub,
            )
        }
      } else if name == "__mul" {
        let pos_args = extract_positional_exprs(args, "__mul")
        if pos_args.length() != 2 {
          raise WasmGenError::Unsupported("__mul arity")
        }
        let resolved_kind = resolve_numeric_kind(ctx, pos_args[0], pos_args[1])
        match resolved_kind {
          ValueKind::I32 | ValueKind::I64 =>
            compile_i32_mul_tagged(ctx, buf, pos_args[0], pos_args[1])
          _ =>
            compile_binary_arith_op(
              ctx, buf, "__mul", args, emit_f32_mul, emit_f64_mul,
            )
        }
      } else if name == "__div" {
        let pos_args = extract_positional_exprs(args, "__div")
        if pos_args.length() != 2 {
          raise WasmGenError::Unsupported("__div arity")
        }
        let resolved_kind = resolve_numeric_kind(ctx, pos_args[0], pos_args[1])
        match resolved_kind {
          ValueKind::I32 | ValueKind::I64 =>
            compile_i32_div_tagged(ctx, buf, pos_args[0], pos_args[1])
          _ =>
            compile_binary_arith_op(
              ctx, buf, "__div", args, emit_f32_div, emit_f64_div,
            )
        }
      } else if name == "__mod" {
        let pos_args = extract_positional_exprs(args, "__mod")
        if pos_args.length() != 2 {
          raise WasmGenError::Unsupported("__mod arity")
        }
        let resolved_kind = resolve_numeric_kind(ctx, pos_args[0], pos_args[1])
        match resolved_kind {
          ValueKind::I32 | ValueKind::I64 =>
            compile_i32_mod_tagged(ctx, buf, pos_args[0], pos_args[1])
          _ => raise WasmGenError::Unsupported("__mod for float types")
        }
      } else if name == "__lshift" {
        let pos_args = extract_positional_exprs(args, "__lshift")
        if pos_args.length() != 2 {
          raise WasmGenError::Unsupported("__lshift arity")
        }
        // (a >> 2) << (b >> 2), then tag result
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_i64_const_raw(buf, 2L)
        emit_i64_shr_s(buf)
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_i64_const_raw(buf, 2L)
        emit_i64_shr_s(buf)
        emit_i64_shl(buf)
        emit_i64_const_raw(buf, 2L)
        emit_i64_shl(buf)
        emit_i64_const_raw(buf, tag_int.to_int64())
        emit_i64_or(buf)
      } else if name == "__rshift" {
        let pos_args = extract_positional_exprs(args, "__rshift")
        if pos_args.length() != 2 {
          raise WasmGenError::Unsupported("__rshift arity")
        }
        // (a >> 2) >> (b >> 2), then tag result
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_i64_const_raw(buf, 2L)
        emit_i64_shr_s(buf)
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_i64_const_raw(buf, 2L)
        emit_i64_shr_s(buf)
        emit_i64_shr_s(buf)
        emit_i64_const_raw(buf, 2L)
        emit_i64_shl(buf)
        emit_i64_const_raw(buf, tag_int.to_int64())
        emit_i64_or(buf)
      } else if name == "i32_shr_u" {
        let pos_args = extract_positional_exprs(args, "i32_shr_u")
        if pos_args.length() != 2 {
          raise WasmGenError::Unsupported("i32_shr_u arity")
        }
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_i64_const_raw(buf, 2L)
        emit_i64_shr_s(buf)
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_i64_const_raw(buf, 2L)
        emit_i64_shr_s(buf)
        emit_i64_shr_u(buf)
        emit_i64_const_raw(buf, 2L)
        emit_i64_shl(buf)
        emit_i64_const_raw(buf, tag_int.to_int64())
        emit_i64_or(buf)
      } else if name == "__bit_and" {
        let pos_args = extract_positional_exprs(args, "__bit_and")
        if pos_args.length() != 2 {
          raise WasmGenError::Unsupported("__bit_and arity")
        }
        // Tagged ints: (a & b) works directly since tag bits are 0
        compile_expr_i32(ctx, buf, pos_args[0])
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_i64_and(buf)
      } else if name == "__bit_or" {
        let pos_args = extract_positional_exprs(args, "__bit_or")
        if pos_args.length() != 2 {
          raise WasmGenError::Unsupported("__bit_or arity")
        }
        // Tagged ints: (a | b) works directly since tag bits are 0
        compile_expr_i32(ctx, buf, pos_args[0])
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_i64_or(buf)
      } else if name == "__bit_xor" {
        let pos_args = extract_positional_exprs(args, "__bit_xor")
        if pos_args.length() != 2 {
          raise WasmGenError::Unsupported("__bit_xor arity")
        }
        // Tagged ints: (a ^ b) works directly since tag bits are 0
        compile_expr_i32(ctx, buf, pos_args[0])
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_i64_xor(buf)
      } else if name == "__eq" {
        compile_binary_cmp_op(
          ctx, buf, "__eq", args, emit_i64_eq, emit_f32_eq, emit_f64_eq,
        )
      } else if name == "__lt" {
        compile_binary_cmp_op(
          ctx, buf, "__lt", args, emit_i64_lt_s, emit_f32_lt, emit_f64_lt,
        )
      } else if name == "i32_eqz" && not(ctx.fn_indices.contains(name)) {
        let pos_args = extract_positional_exprs(args, "i32_eqz")
        if pos_args.length() != 1 {
          raise WasmGenError::Unsupported("i32_eqz arity")
        }
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_i64_const_raw(buf, 2L)
        emit_i64_shr_s(buf)
        emit_i32_wrap_i64(buf)
        emit_i32_eqz(buf)
        emit_i32_result_as_tagged_int(buf)
      } else if name == "i32_eq" && not(ctx.fn_indices.contains(name)) {
        compile_i32_cmp_to_tagged_int(ctx, buf, "i32_eq", args, emit_i32_eq)
      } else if name == "i32_ne" && not(ctx.fn_indices.contains(name)) {
        compile_i32_cmp_to_tagged_int(ctx, buf, "i32_ne", args, emit_i32_ne)
      } else if name == "i32_lt_s" && not(ctx.fn_indices.contains(name)) {
        compile_i32_cmp_to_tagged_int(ctx, buf, "i32_lt_s", args, emit_i32_lt_s)
      } else if name == "i32_gt_s" && not(ctx.fn_indices.contains(name)) {
        compile_i32_cmp_to_tagged_int(ctx, buf, "i32_gt_s", args, emit_i32_gt_s)
      } else if name == "i32_le_s" && not(ctx.fn_indices.contains(name)) {
        compile_i32_cmp_to_tagged_int(ctx, buf, "i32_le_s", args, emit_i32_le_s)
      } else if name == "i32_ge_s" && not(ctx.fn_indices.contains(name)) {
        compile_i32_cmp_to_tagged_int(ctx, buf, "i32_ge_s", args, emit_i32_ge_s)
      } else if name == "f32_eq" && not(ctx.fn_indices.contains(name)) {
        compile_f32_cmp_to_tagged_int(ctx, buf, "f32_eq", args, emit_f32_eq)
      } else if name == "f32_ne" && not(ctx.fn_indices.contains(name)) {
        compile_f32_cmp_to_tagged_int(ctx, buf, "f32_ne", args, emit_f32_ne)
      } else if name == "f32_lt" && not(ctx.fn_indices.contains(name)) {
        compile_f32_cmp_to_tagged_int(ctx, buf, "f32_lt", args, emit_f32_lt)
      } else if name == "f32_gt" && not(ctx.fn_indices.contains(name)) {
        compile_f32_cmp_to_tagged_int(ctx, buf, "f32_gt", args, emit_f32_gt)
      } else if name == "f32_le" && not(ctx.fn_indices.contains(name)) {
        compile_f32_cmp_to_tagged_int(ctx, buf, "f32_le", args, emit_f32_le)
      } else if name == "f32_ge" && not(ctx.fn_indices.contains(name)) {
        compile_f32_cmp_to_tagged_int(ctx, buf, "f32_ge", args, emit_f32_ge)
      } else if name == "f64_eq" && not(ctx.fn_indices.contains(name)) {
        compile_f64_cmp_to_tagged_int(ctx, buf, "f64_eq", args, emit_f64_eq)
      } else if name == "f64_ne" && not(ctx.fn_indices.contains(name)) {
        compile_f64_cmp_to_tagged_int(ctx, buf, "f64_ne", args, emit_f64_ne)
      } else if name == "f64_lt" && not(ctx.fn_indices.contains(name)) {
        compile_f64_cmp_to_tagged_int(ctx, buf, "f64_lt", args, emit_f64_lt)
      } else if name == "f64_gt" && not(ctx.fn_indices.contains(name)) {
        compile_f64_cmp_to_tagged_int(ctx, buf, "f64_gt", args, emit_f64_gt)
      } else if name == "f64_le" && not(ctx.fn_indices.contains(name)) {
        compile_f64_cmp_to_tagged_int(ctx, buf, "f64_le", args, emit_f64_le)
      } else if name == "f64_ge" && not(ctx.fn_indices.contains(name)) {
        compile_f64_cmp_to_tagged_int(ctx, buf, "f64_ge", args, emit_f64_ge)
      } else if name == "__neg" {
        let pos_args = extract_positional_exprs(args, "__neg")
        if pos_args.length() != 1 {
          raise WasmGenError::Unsupported("__neg arity")
        }
        let kind = infer_expr_kind(ctx, pos_args[0])
        match kind {
          ValueKind::I32 | ValueKind::I64 => {
            emit_i64_const_raw(buf, tag_int_value64(0L))
            compile_expr_i32(ctx, buf, pos_args[0])
            emit_i64_sub(buf)
          }
          ValueKind::BoxedF32 =>
            emit_boxed_f32_raise(ctx, buf, fn() raise WasmGenError {
              emit_unbox_f32_expr(ctx, buf, pos_args[0])
              emit_f32_neg(buf)
            })
          ValueKind::BoxedF64 =>
            emit_boxed_f64_raise(ctx, buf, fn() raise WasmGenError {
              emit_unbox_f64_expr(ctx, buf, pos_args[0])
              emit_f64_neg(buf)
            })
          _ => raise WasmGenError::Unsupported("numeric kind")
        }
      } else if name == "f32_neg" {
        let pos_args = extract_positional_exprs(args, "f32_neg")
        if pos_args.length() != 1 {
          raise WasmGenError::Unsupported("f32_neg arity")
        }
        emit_boxed_f32_raise(ctx, buf, fn() raise WasmGenError {
          emit_unbox_f32_expr(ctx, buf, pos_args[0])
          emit_f32_neg(buf)
        })
      } else if name == "f64_neg" {
        let pos_args = extract_positional_exprs(args, "f64_neg")
        if pos_args.length() != 1 {
          raise WasmGenError::Unsupported("f64_neg arity")
        }
        emit_boxed_f64_raise(ctx, buf, fn() raise WasmGenError {
          emit_unbox_f64_expr(ctx, buf, pos_args[0])
          emit_f64_neg(buf)
        })
      } else if name == "int_to_float" || name == "f32_convert_i32_s" {
        let pos_args = extract_positional_exprs(args, name)
        if pos_args.length() != 1 {
          raise WasmGenError::Unsupported(name + " arity")
        }
        emit_boxed_f32_raise(ctx, buf, fn() raise WasmGenError {
          compile_expr_i32(ctx, buf, pos_args[0])
          emit_i64_const_raw(buf, 2L)
          emit_i64_shr_s(buf)
          emit_i32_wrap_i64(buf)
          emit_f32_convert_i32_s(buf)
        })
      } else if name == "int_to_double" ||
        name == "f64_convert_i32_s" ||
        name == "to_double" {
        let pos_args = extract_positional_exprs(args, name)
        if pos_args.length() != 1 {
          raise WasmGenError::Unsupported(name + " arity")
        }
        emit_boxed_f64_raise(ctx, buf, fn() raise WasmGenError {
          compile_expr_i32(ctx, buf, pos_args[0])
          emit_i64_const_raw(buf, 2L)
          emit_i64_shr_s(buf)
          emit_i32_wrap_i64(buf)
          emit_f64_convert_i32_s(buf)
        })
      } else if name == "float_to_int" || name == "i32_trunc_f32_s" {
        let pos_args = extract_positional_exprs(args, name)
        if pos_args.length() != 1 {
          raise WasmGenError::Unsupported(name + " arity")
        }
        emit_unbox_f32_expr(ctx, buf, pos_args[0])
        emit_i32_trunc_f32_s(buf)
        emit_i64_extend_i32_s(buf)
        emit_i64_const_raw(buf, 2L)
        emit_i64_shl(buf)
        emit_i64_const_raw(buf, tag_int.to_int64())
        emit_i64_or(buf)
      } else if name == "double_to_int" || name == "i32_trunc_f64_s" {
        let pos_args = extract_positional_exprs(args, name)
        if pos_args.length() != 1 {
          raise WasmGenError::Unsupported(name + " arity")
        }
        emit_unbox_f64_expr(ctx, buf, pos_args[0])
        emit_i32_trunc_f64_s(buf)
        emit_i64_extend_i32_s(buf)
        emit_i64_const_raw(buf, 2L)
        emit_i64_shl(buf)
        emit_i64_const_raw(buf, tag_int.to_int64())
        emit_i64_or(buf)
      } else if name == "float_to_double" || name == "f64_promote_f32" {
        let pos_args = extract_positional_exprs(args, name)
        if pos_args.length() != 1 {
          raise WasmGenError::Unsupported(name + " arity")
        }
        emit_boxed_f64_raise(ctx, buf, fn() raise WasmGenError {
          emit_unbox_f32_expr(ctx, buf, pos_args[0])
          emit_f64_promote_f32(buf)
        })
      } else if name == "double_to_float" || name == "f32_demote_f64" {
        let pos_args = extract_positional_exprs(args, name)
        if pos_args.length() != 1 {
          raise WasmGenError::Unsupported(name + " arity")
        }
        emit_boxed_f32_raise(ctx, buf, fn() raise WasmGenError {
          emit_unbox_f64_expr(ctx, buf, pos_args[0])
          emit_f32_demote_f64(buf)
        })
      } else if name == "i32_load" {
        let pos_args = extract_positional_exprs(args, "i32_load")
        if pos_args.length() != 2 {
          raise WasmGenError::Unsupported("i32_load arity")
        }
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_i64_const_raw(buf, 2L)
        emit_i64_shr_s(buf)
        emit_i32_wrap_i64(buf)
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_i64_const_raw(buf, 2L)
        emit_i64_shr_s(buf)
        emit_i32_wrap_i64(buf)
        emit_i32_add(buf)
        emit_i32_load(buf, 0)
        emit_i64_extend_i32_s(buf)
        emit_i64_const_raw(buf, 2L)
        emit_i64_shl(buf)
        emit_i64_const_raw(buf, tag_int.to_int64())
        emit_i64_or(buf)
      } else if name == "i32_load8_u" {
        let pos_args = extract_positional_exprs(args, "i32_load8_u")
        if pos_args.length() != 2 {
          raise WasmGenError::Unsupported("i32_load8_u arity")
        }
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_i64_const_raw(buf, 2L)
        emit_i64_shr_s(buf)
        emit_i32_wrap_i64(buf)
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_i64_const_raw(buf, 2L)
        emit_i64_shr_s(buf)
        emit_i32_wrap_i64(buf)
        emit_i32_add(buf)
        emit_i32_load8_u(buf, 0)
        emit_i64_extend_i32_s(buf)
        emit_i64_const_raw(buf, 2L)
        emit_i64_shl(buf)
        emit_i64_const_raw(buf, tag_int.to_int64())
        emit_i64_or(buf)
      } else if name == "i32_store" {
        let pos_args = extract_positional_exprs(args, "i32_store")
        if pos_args.length() != 3 {
          raise WasmGenError::Unsupported("i32_store arity")
        }
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_i64_const_raw(buf, 2L)
        emit_i64_shr_s(buf)
        emit_i32_wrap_i64(buf)
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_i64_const_raw(buf, 2L)
        emit_i64_shr_s(buf)
        emit_i32_wrap_i64(buf)
        emit_i32_add(buf)
        compile_expr_i32(ctx, buf, pos_args[2])
        emit_i64_const_raw(buf, 2L)
        emit_i64_shr_s(buf)
        emit_i32_wrap_i64(buf)
        emit_i32_store(buf, 0)
        emit_i64_const_tagged(buf, 0L)
      } else if name == "i32_store8" {
        let pos_args = extract_positional_exprs(args, "i32_store8")
        if pos_args.length() != 3 {
          raise WasmGenError::Unsupported("i32_store8 arity")
        }
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_i64_const_raw(buf, 2L)
        emit_i64_shr_s(buf)
        emit_i32_wrap_i64(buf)
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_i64_const_raw(buf, 2L)
        emit_i64_shr_s(buf)
        emit_i32_wrap_i64(buf)
        emit_i32_add(buf)
        compile_expr_i32(ctx, buf, pos_args[2])
        emit_i64_const_raw(buf, 2L)
        emit_i64_shr_s(buf)
        emit_i32_wrap_i64(buf)
        emit_i32_store8(buf, 0)
        emit_i64_const_tagged(buf, 0L)
      } else if name == "f32_load" {
        let pos_args = extract_positional_exprs(args, "f32_load")
        if pos_args.length() != 2 {
          raise WasmGenError::Unsupported("f32_load arity")
        }
        emit_boxed_f32_raise(ctx, buf, fn() raise WasmGenError {
          compile_expr_i32(ctx, buf, pos_args[0])
          emit_i64_const_raw(buf, 2L)
          emit_i64_shr_s(buf)
          emit_i32_wrap_i64(buf)
          compile_expr_i32(ctx, buf, pos_args[1])
          emit_i64_const_raw(buf, 2L)
          emit_i64_shr_s(buf)
          emit_i32_wrap_i64(buf)
          emit_i32_add(buf)
          emit_f32_load(buf, 0)
        })
      } else if name == "f64_load" {
        let pos_args = extract_positional_exprs(args, "f64_load")
        if pos_args.length() != 2 {
          raise WasmGenError::Unsupported("f64_load arity")
        }
        emit_boxed_f64_raise(ctx, buf, fn() raise WasmGenError {
          compile_expr_i32(ctx, buf, pos_args[0])
          emit_i64_const_raw(buf, 2L)
          emit_i64_shr_s(buf)
          emit_i32_wrap_i64(buf)
          compile_expr_i32(ctx, buf, pos_args[1])
          emit_i64_const_raw(buf, 2L)
          emit_i64_shr_s(buf)
          emit_i32_wrap_i64(buf)
          emit_i32_add(buf)
          emit_f64_load(buf, 0)
        })
      } else if name == "f32_store" {
        let pos_args = extract_positional_exprs(args, "f32_store")
        if pos_args.length() != 3 {
          raise WasmGenError::Unsupported("f32_store arity")
        }
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_i64_const_raw(buf, 2L)
        emit_i64_shr_s(buf)
        emit_i32_wrap_i64(buf)
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_i64_const_raw(buf, 2L)
        emit_i64_shr_s(buf)
        emit_i32_wrap_i64(buf)
        emit_i32_add(buf)
        emit_unbox_f32_expr(ctx, buf, pos_args[2])
        emit_f32_store(buf, 0)
        emit_i64_const_tagged(buf, 0L)
      } else if name == "f64_store" {
        let pos_args = extract_positional_exprs(args, "f64_store")
        if pos_args.length() != 3 {
          raise WasmGenError::Unsupported("f64_store arity")
        }
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_i64_const_raw(buf, 2L)
        emit_i64_shr_s(buf)
        emit_i32_wrap_i64(buf)
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_i64_const_raw(buf, 2L)
        emit_i64_shr_s(buf)
        emit_i32_wrap_i64(buf)
        emit_i32_add(buf)
        emit_unbox_f64_expr(ctx, buf, pos_args[2])
        emit_f64_store(buf, 0)
        emit_i64_const_tagged(buf, 0L)
      } else if name == "not" && not(ctx.fn_indices.contains(name)) {
        let pos_args = extract_positional_exprs(args, "not")
        if pos_args.length() != 1 {
          raise WasmGenError::Unsupported("not arity")
        }
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_i64_const_raw(buf, 4L)
        emit_i64_xor(buf)
      } else if name == "and" && not(ctx.fn_indices.contains(name)) {
        let pos_args = extract_positional_exprs(args, "and")
        if pos_args.length() != 2 {
          raise WasmGenError::Unsupported("and arity")
        }
        compile_expr_i32(ctx, buf, pos_args[0])
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_i64_and(buf)
      } else if name == "or" && not(ctx.fn_indices.contains(name)) {
        let pos_args = extract_positional_exprs(args, "or")
        if pos_args.length() != 2 {
          raise WasmGenError::Unsupported("or arity")
        }
        compile_expr_i32(ctx, buf, pos_args[0])
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_i64_or(buf)
      } else if name == "__to_string" {
        let pos_args = extract_positional_exprs(args, "__to_string")
        if pos_args.length() != 1 {
          raise WasmGenError::Unsupported("__to_string arity")
        }
        if ctx.use_js_strings {
          let arg_kind = infer_expr_kind(ctx, pos_args[0])
          if arg_kind == ValueKind::ExternRef {
            compile_expr_ref(ctx, buf, pos_args[0])
          } else {
            compile_expr_i32(ctx, buf, pos_args[0])
            emit_drop(buf)
            emit_string_const(ctx, buf, "")
          }
        } else {
          require_heap(ctx)
          let true_str = tag_ptr64(ctx.strings.intern("true"), tag_obj)
          let false_str = tag_ptr64(ctx.strings.intern("false"), tag_obj)
          let fallback_str = tag_ptr64(ctx.strings.intern("<value>"), tag_obj)
          let value_local = alloc_temp_local(ctx)
          let tag_local = alloc_temp_local(ctx)
          compile_expr_i32(ctx, buf, pos_args[0])
          emit_local_set(buf, value_local)
          // Extract tag (i32) from i64 value
          emit_local_get(buf, value_local)
          emit_i64_const_raw(buf, tag_mask.to_int64())
          emit_i64_and(buf)
          emit_i32_wrap_i64(buf)
          emit_local_set(buf, tag_local)
          emit_local_get(buf, tag_local)
          emit_i32_const_raw(buf, tag_obj)
          emit_i32_eq(buf)
          buf.push((4).to_byte()) // if
          buf.push((126).to_byte()) // result i64
          emit_local_get(buf, value_local)
          buf.push((5).to_byte()) // else
          emit_local_get(buf, tag_local)
          emit_i32_const_raw(buf, tag_bool)
          emit_i32_eq(buf)
          buf.push((4).to_byte()) // if
          buf.push((126).to_byte()) // result i64
          emit_local_get(buf, value_local)
          emit_i64_const_raw(buf, tag_bool_value64(true))
          emit_i64_eq(buf)
          buf.push((4).to_byte()) // if
          buf.push((126).to_byte()) // result i64
          emit_i64_const_raw(buf, true_str)
          buf.push((5).to_byte()) // else
          emit_i64_const_raw(buf, false_str)
          buf.push((11).to_byte()) // end if
          buf.push((5).to_byte()) // else
          emit_local_get(buf, tag_local)
          emit_i32_const_raw(buf, tag_int)
          emit_i32_eq(buf)
          buf.push((4).to_byte()) // if
          buf.push((126).to_byte()) // result i64
          let n_local = alloc_temp_local(ctx)
          let is_neg_local = alloc_temp_local(ctx)
          let scratch_local = alloc_temp_local(ctx)
          let digit_len_local = alloc_temp_local(ctx)
          let digit_local = alloc_temp_local(ctx)
          let copy_i_local = alloc_temp_local(ctx)
          let obj_local = alloc_temp_local(ctx)
          let src_idx_local = alloc_temp_local(ctx)
          let alloc_size_local = alloc_temp_local(ctx)
          emit_local_get(buf, value_local)
          emit_i64_const_raw(buf, 2L)
          emit_i64_shr_s(buf)
          emit_i32_wrap_i64(buf)
          emit_local_set(buf, n_local)
          emit_i32_const_raw(buf, 0)
          emit_local_set(buf, is_neg_local)
          emit_local_get(buf, n_local)
          emit_i32_const_raw(buf, 0)
          emit_i32_lt_s(buf)
          buf.push((4).to_byte()) // if
          buf.push((64).to_byte()) // void
          emit_i32_const_raw(buf, 1)
          emit_local_set(buf, is_neg_local)
          emit_i32_const_raw(buf, 0)
          emit_local_get(buf, n_local)
          emit_i32_sub(buf)
          emit_local_set(buf, n_local)
          buf.push((11).to_byte()) // end if
          emit_heap_alloc(ctx, buf, 64, scratch_local)
          emit_i32_const_raw(buf, 0)
          emit_local_set(buf, digit_len_local)
          emit_local_get(buf, n_local)
          emit_i32_eqz(buf)
          buf.push((4).to_byte()) // if
          buf.push((64).to_byte()) // void
          emit_local_get(buf, scratch_local)
          emit_i32_const_raw(buf, 48)
          emit_i32_store8(buf, 0)
          emit_i32_const_raw(buf, 1)
          emit_local_set(buf, digit_len_local)
          buf.push((5).to_byte()) // else
          emit_block(buf)
          emit_loop(buf)
          emit_local_get(buf, n_local)
          emit_i32_eqz(buf)
          emit_br_if(buf, 1)
          emit_local_get(buf, n_local)
          emit_i32_const_raw(buf, 10)
          emit_i32_rem_s(buf)
          emit_local_set(buf, digit_local)
          emit_local_get(buf, n_local)
          emit_i32_const_raw(buf, 10)
          emit_i32_div_s(buf)
          emit_local_set(buf, n_local)
          emit_local_get(buf, scratch_local)
          emit_local_get(buf, digit_len_local)
          emit_i32_add(buf)
          emit_local_get(buf, digit_local)
          emit_i32_const_raw(buf, 48)
          emit_i32_add(buf)
          emit_i32_store8(buf, 0)
          emit_local_get(buf, digit_len_local)
          emit_i32_const_raw(buf, 1)
          emit_i32_add(buf)
          emit_local_set(buf, digit_len_local)
          emit_br(buf, 0)
          emit_end(buf)
          emit_end(buf)
          buf.push((11).to_byte()) // end if
          emit_local_get(buf, is_neg_local)
          emit_i32_eqz(buf)
          buf.push((4).to_byte()) // if
          buf.push((64).to_byte()) // void
          buf.push((5).to_byte()) // else
          emit_local_get(buf, scratch_local)
          emit_local_get(buf, digit_len_local)
          emit_i32_add(buf)
          emit_i32_const_raw(buf, 45)
          emit_i32_store8(buf, 0)
          emit_local_get(buf, digit_len_local)
          emit_i32_const_raw(buf, 1)
          emit_i32_add(buf)
          emit_local_set(buf, digit_len_local)
          buf.push((11).to_byte()) // end if
          emit_local_get(buf, digit_len_local)
          emit_i32_const_raw(buf, 11)
          emit_i32_add(buf)
          emit_i32_const_raw(buf, -4)
          emit_i32_and(buf)
          emit_local_set(buf, alloc_size_local)
          emit_heap_alloc_local(ctx, buf, alloc_size_local, obj_local)
          emit_local_get(buf, obj_local)
          emit_i32_const_raw(buf, obj_string)
          emit_i32_store(buf, 0)
          emit_local_get(buf, obj_local)
          emit_local_get(buf, digit_len_local)
          emit_i32_store(buf, 4)
          emit_i32_const_raw(buf, 0)
          emit_local_set(buf, copy_i_local)
          emit_block(buf)
          emit_loop(buf)
          emit_local_get(buf, copy_i_local)
          emit_local_get(buf, digit_len_local)
          emit_i32_lt_s(buf)
          emit_i32_eqz(buf)
          emit_br_if(buf, 1)
          emit_local_get(buf, digit_len_local)
          emit_i32_const_raw(buf, 1)
          emit_i32_sub(buf)
          emit_local_get(buf, copy_i_local)
          emit_i32_sub(buf)
          emit_local_set(buf, src_idx_local)
          emit_local_get(buf, obj_local)
          emit_local_get(buf, copy_i_local)
          emit_i32_add(buf)
          emit_local_get(buf, scratch_local)
          emit_local_get(buf, src_idx_local)
          emit_i32_add(buf)
          emit_i32_load8_u(buf, 0)
          emit_i32_store8(buf, 8)
          emit_local_get(buf, copy_i_local)
          emit_i32_const_raw(buf, 1)
          emit_i32_add(buf)
          emit_local_set(buf, copy_i_local)
          emit_br(buf, 0)
          emit_end(buf)
          emit_end(buf)
          emit_local_get(buf, obj_local)
          emit_i64_extend_i32_u(buf)
          emit_i64_const_raw(buf, tag_obj.to_int64())
          emit_i64_or(buf)
          buf.push((5).to_byte()) // else
          emit_i64_const_raw(buf, fallback_str)
          buf.push((11).to_byte()) // end if
          buf.push((11).to_byte()) // end if
          buf.push((11).to_byte()) // end if
        }
      } else if name == "threads_probe_wat" {
        let pos_args = extract_positional_exprs(args, "threads_probe_wat")
        if pos_args.length() != 0 {
          raise WasmGenError::Unsupported("threads_probe_wat arity")
        }
        emit_string_const(ctx, buf, "(module)")
      } else if name == "threads_runtime_hints" {
        let pos_args = extract_positional_exprs(args, "threads_runtime_hints")
        if pos_args.length() != 0 {
          raise WasmGenError::Unsupported("threads_runtime_hints arity")
        }
        emit_i64_const_tagged(buf, 0L)
      } else if name == "wasm_env" {
        let pos_args = extract_positional_exprs(args, "wasm_env")
        if pos_args.length() != 1 {
          raise WasmGenError::Unsupported("wasm_env arity")
        }
        compile_expr(ctx, buf, pos_args[0])
        emit_drop(buf)
        emit_string_const(ctx, buf, "threads=y shared-memory=y")
      } else if name == "wasi_env" {
        let pos_args = extract_positional_exprs(args, "wasi_env")
        if pos_args.length() != 1 {
          raise WasmGenError::Unsupported("wasi_env arity")
        }
        compile_expr(ctx, buf, pos_args[0])
        emit_drop(buf)
        emit_string_const(ctx, buf, "threads=y")
      } else if name == "threads_channel_new" {
        let pos_args = extract_positional_exprs(args, "threads_channel_new")
        if pos_args.length() != 1 {
          raise WasmGenError::Unsupported("threads_channel_new arity")
        }
        let cap_local = alloc_temp_local(ctx)
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_i64_const_raw(buf, 2L)
        emit_i64_shr_s(buf)
        emit_i32_wrap_i64(buf)
        emit_local_set(buf, cap_local)
        emit_local_get(buf, cap_local)
        emit_i32_const_raw(buf, 0)
        emit_i32_lt_s(buf)
        buf.push((4).to_byte()) // if
        buf.push((127).to_byte()) // result i32
        emit_i32_const_raw(buf, 0)
        buf.push((5).to_byte()) // else
        emit_local_get(buf, cap_local)
        buf.push((11).to_byte()) // end if
        emit_i64_extend_i32_s(buf)
        emit_i64_const_raw(buf, 2L)
        emit_i64_shl(buf)
        emit_i64_const_raw(buf, tag_int.to_int64())
        emit_i64_or(buf)
      } else if name == "threads_spawn" {
        let pos_args = extract_positional_exprs(args, "threads_spawn")
        if pos_args.length() != 2 {
          raise WasmGenError::Unsupported("threads_spawn arity")
        }
        compile_expr(ctx, buf, pos_args[0])
        emit_drop(buf)
        compile_expr_i32(ctx, buf, pos_args[1])
      } else if name == "threads_send" {
        let pos_args = extract_positional_exprs(args, "threads_send")
        if pos_args.length() != 2 {
          raise WasmGenError::Unsupported("threads_send arity")
        }
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_drop(buf)
        compile_expr(ctx, buf, pos_args[1])
        emit_drop(buf)
        emit_i64_const_raw(buf, tag_bool_value64(true))
      } else if name == "threads_recv" {
        let pos_args = extract_positional_exprs(args, "threads_recv")
        if pos_args.length() != 1 {
          raise WasmGenError::Unsupported("threads_recv arity")
        }
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_drop(buf)
        emit_string_const(ctx, buf, "")
      } else if name == "threads_wait" {
        let pos_args = extract_positional_exprs(args, "threads_wait")
        if pos_args.length() != 1 {
          raise WasmGenError::Unsupported("threads_wait arity")
        }
        compile_expr_i32(ctx, buf, pos_args[0])
      } else if name == "string_length" {
        let pos_args = extract_positional_exprs(args, "string_length")
        if pos_args.length() != 1 {
          raise WasmGenError::Unsupported("string_length arity")
        }
        if ctx.use_js_strings {
          ctx.need_js_length = true
          compile_expr_ref(ctx, buf, pos_args[0])
          emit_call(buf, import_index_js_length(ctx))
          emit_i64_extend_i32_s(buf)
          emit_i64_const_raw(buf, 2L)
          emit_i64_shl(buf)
        } else {
          // Untag pointer to i32, load length, tag as i64
          compile_expr_i32(ctx, buf, pos_args[0])
          emit_i64_const_raw(buf, (-4).to_int64())
          emit_i64_and(buf)
          emit_i32_wrap_i64(buf)
          emit_i32_load(buf, 4)
          emit_i64_extend_i32_s(buf)
          emit_i64_const_raw(buf, 2L)
          emit_i64_shl(buf)
          emit_i64_const_raw(buf, tag_int.to_int64())
          emit_i64_or(buf)
        }
      } else if name == "string_char_code_at" {
        let pos_args = extract_positional_exprs(args, "string_char_code_at")
        if pos_args.length() != 2 {
          raise WasmGenError::Unsupported("string_char_code_at arity")
        }
        if ctx.use_js_strings {
          ctx.need_js_char_code_at = true
          compile_expr_ref(ctx, buf, pos_args[0])
          compile_expr_i32(ctx, buf, pos_args[1])
          emit_i64_const_raw(buf, 2L)
          emit_i64_shr_s(buf)
          emit_i32_wrap_i64(buf)
          emit_call(buf, import_index_js_char_code_at(ctx))
          emit_i64_extend_i32_s(buf)
          emit_i64_const_raw(buf, 2L)
          emit_i64_shl(buf)
        } else {
          let str_ptr_local = alloc_temp_local(ctx)
          let str_len_local = alloc_temp_local(ctx)
          let idx_local = alloc_temp_local(ctx)
          compile_expr_i32(ctx, buf, pos_args[0])
          emit_i64_const_raw(buf, (-4).to_int64())
          emit_i64_and(buf)
          emit_i32_wrap_i64(buf)
          emit_local_set(buf, str_ptr_local)
          emit_local_get(buf, str_ptr_local)
          emit_i32_load(buf, 4)
          emit_local_set(buf, str_len_local)
          compile_expr_i32(ctx, buf, pos_args[1])
          emit_i64_const_raw(buf, 2L)
          emit_i64_shr_s(buf)
          emit_i32_wrap_i64(buf)
          emit_local_set(buf, idx_local)
          emit_local_get(buf, idx_local)
          emit_i32_const_raw(buf, 0)
          emit_i32_lt_s(buf)
          emit_local_get(buf, idx_local)
          emit_local_get(buf, str_len_local)
          emit_i32_lt_s(buf)
          emit_i32_eqz(buf)
          emit_i32_or(buf)
          buf.push((4).to_byte()) // if
          buf.push((126).to_byte()) // result i64
          emit_i64_const_tagged(buf, -1L)
          buf.push((5).to_byte()) // else
          emit_local_get(buf, str_ptr_local)
          emit_local_get(buf, idx_local)
          emit_i32_add(buf)
          emit_i32_load8_u(buf, 8)
          emit_i64_extend_i32_s(buf)
          emit_i64_const_raw(buf, 2L)
          emit_i64_shl(buf)
          emit_i64_const_raw(buf, tag_int.to_int64())
          emit_i64_or(buf)
          buf.push((11).to_byte()) // end if
        }
      } else if name == "string_substring" {
        let pos_args = extract_positional_exprs(args, "string_substring")
        if pos_args.length() != 3 {
          raise WasmGenError::Unsupported("string_substring arity")
        }
        if ctx.use_js_strings {
          ctx.need_js_substring = true
          compile_expr_ref(ctx, buf, pos_args[0])
          compile_expr_i32(ctx, buf, pos_args[1])
          emit_i64_const_raw(buf, 2L)
          emit_i64_shr_s(buf)
          emit_i32_wrap_i64(buf)
          compile_expr_i32(ctx, buf, pos_args[2])
          emit_i64_const_raw(buf, 2L)
          emit_i64_shr_s(buf)
          emit_i32_wrap_i64(buf)
          emit_call(buf, import_index_js_substring(ctx))
        } else {
          require_heap(ctx)
          let str_ptr_local = alloc_temp_local(ctx)
          let str_len_local = alloc_temp_local(ctx)
          let start_local = alloc_temp_local(ctx)
          let end_local = alloc_temp_local(ctx)
          let sub_len_local = alloc_temp_local(ctx)
          let obj_local = alloc_temp_local(ctx)
          let copy_i_local = alloc_temp_local(ctx)
          let alloc_size_local = alloc_temp_local(ctx)
          compile_expr_i32(ctx, buf, pos_args[0])
          emit_i64_const_raw(buf, (-4).to_int64())
          emit_i64_and(buf)
          emit_i32_wrap_i64(buf)
          emit_local_set(buf, str_ptr_local)
          emit_local_get(buf, str_ptr_local)
          emit_i32_load(buf, 4)
          emit_local_set(buf, str_len_local)
          compile_expr_i32(ctx, buf, pos_args[1])
          emit_i64_const_raw(buf, 2L)
          emit_i64_shr_s(buf)
          emit_i32_wrap_i64(buf)
          emit_local_set(buf, start_local)
          compile_expr_i32(ctx, buf, pos_args[2])
          emit_i64_const_raw(buf, 2L)
          emit_i64_shr_s(buf)
          emit_i32_wrap_i64(buf)
          emit_local_set(buf, end_local)
          emit_local_get(buf, start_local)
          emit_i32_const_raw(buf, 0)
          emit_i32_lt_s(buf)
          buf.push((4).to_byte()) // if
          buf.push((64).to_byte()) // void
          emit_i32_const_raw(buf, 0)
          emit_local_set(buf, start_local)
          buf.push((11).to_byte()) // end if
          emit_local_get(buf, str_len_local)
          emit_local_get(buf, start_local)
          emit_i32_lt_s(buf)
          buf.push((4).to_byte()) // if
          buf.push((64).to_byte()) // void
          emit_local_get(buf, str_len_local)
          emit_local_set(buf, start_local)
          buf.push((11).to_byte()) // end if
          emit_local_get(buf, end_local)
          emit_i32_const_raw(buf, 0)
          emit_i32_lt_s(buf)
          buf.push((4).to_byte()) // if
          buf.push((64).to_byte()) // void
          emit_i32_const_raw(buf, 0)
          emit_local_set(buf, end_local)
          buf.push((11).to_byte()) // end if
          emit_local_get(buf, str_len_local)
          emit_local_get(buf, end_local)
          emit_i32_lt_s(buf)
          buf.push((4).to_byte()) // if
          buf.push((64).to_byte()) // void
          emit_local_get(buf, str_len_local)
          emit_local_set(buf, end_local)
          buf.push((11).to_byte()) // end if
          emit_local_get(buf, end_local)
          emit_local_get(buf, start_local)
          emit_i32_lt_s(buf)
          buf.push((4).to_byte()) // if
          buf.push((64).to_byte()) // void
          emit_local_get(buf, start_local)
          emit_local_set(buf, end_local)
          buf.push((11).to_byte()) // end if
          emit_local_get(buf, end_local)
          emit_local_get(buf, start_local)
          emit_i32_sub(buf)
          emit_local_set(buf, sub_len_local)
          emit_local_get(buf, sub_len_local)
          emit_i32_const_raw(buf, 11)
          emit_i32_add(buf)
          emit_i32_const_raw(buf, -4)
          emit_i32_and(buf)
          emit_local_set(buf, alloc_size_local)
          emit_heap_alloc_local(ctx, buf, alloc_size_local, obj_local)
          emit_local_get(buf, obj_local)
          emit_i32_const_raw(buf, obj_string)
          emit_i32_store(buf, 0)
          emit_local_get(buf, obj_local)
          emit_local_get(buf, sub_len_local)
          emit_i32_store(buf, 4)
          emit_i32_const_raw(buf, 0)
          emit_local_set(buf, copy_i_local)
          emit_block(buf)
          emit_loop(buf)
          emit_local_get(buf, copy_i_local)
          emit_local_get(buf, sub_len_local)
          emit_i32_lt_s(buf)
          emit_i32_eqz(buf)
          emit_br_if(buf, 1)
          emit_local_get(buf, obj_local)
          emit_local_get(buf, copy_i_local)
          emit_i32_add(buf)
          emit_local_get(buf, str_ptr_local)
          emit_local_get(buf, start_local)
          emit_i32_add(buf)
          emit_local_get(buf, copy_i_local)
          emit_i32_add(buf)
          emit_i32_load8_u(buf, 8)
          emit_i32_store8(buf, 8)
          emit_local_get(buf, copy_i_local)
          emit_i32_const_raw(buf, 1)
          emit_i32_add(buf)
          emit_local_set(buf, copy_i_local)
          emit_br(buf, 0)
          emit_end(buf)
          emit_end(buf)
          emit_local_get(buf, obj_local)
          emit_i64_extend_i32_u(buf)
          emit_i64_const_raw(buf, tag_obj.to_int64())
          emit_i64_or(buf)
        }
      } else if name == "string_concat" {
        let pos_args = extract_positional_exprs(args, "string_concat")
        if pos_args.length() != 2 {
          raise WasmGenError::Unsupported("string_concat arity")
        }
        if ctx.use_js_strings {
          ctx.need_js_concat = true
          compile_expr_ref(ctx, buf, pos_args[0])
          compile_expr_ref(ctx, buf, pos_args[1])
          emit_call(buf, import_index_js_concat(ctx))
        } else {
          require_heap(ctx)
          let left_ptr_local = alloc_temp_local(ctx)
          let left_len_local = alloc_temp_local(ctx)
          let right_ptr_local = alloc_temp_local(ctx)
          let right_len_local = alloc_temp_local(ctx)
          let total_len_local = alloc_temp_local(ctx)
          let obj_local = alloc_temp_local(ctx)
          let copy_i_local = alloc_temp_local(ctx)
          let alloc_size_local = alloc_temp_local(ctx)
          compile_expr_i32(ctx, buf, pos_args[0])
          emit_i64_const_raw(buf, (-4).to_int64())
          emit_i64_and(buf)
          emit_i32_wrap_i64(buf)
          emit_local_set(buf, left_ptr_local)
          emit_local_get(buf, left_ptr_local)
          emit_i32_load(buf, 4)
          emit_local_set(buf, left_len_local)
          compile_expr_i32(ctx, buf, pos_args[1])
          emit_i64_const_raw(buf, (-4).to_int64())
          emit_i64_and(buf)
          emit_i32_wrap_i64(buf)
          emit_local_set(buf, right_ptr_local)
          emit_local_get(buf, right_ptr_local)
          emit_i32_load(buf, 4)
          emit_local_set(buf, right_len_local)
          emit_local_get(buf, left_len_local)
          emit_local_get(buf, right_len_local)
          emit_i32_add(buf)
          emit_local_set(buf, total_len_local)
          emit_local_get(buf, total_len_local)
          emit_i32_const_raw(buf, 11)
          emit_i32_add(buf)
          emit_i32_const_raw(buf, -4)
          emit_i32_and(buf)
          emit_local_set(buf, alloc_size_local)
          emit_heap_alloc_local(ctx, buf, alloc_size_local, obj_local)
          emit_local_get(buf, obj_local)
          emit_i32_const_raw(buf, obj_string)
          emit_i32_store(buf, 0)
          emit_local_get(buf, obj_local)
          emit_local_get(buf, total_len_local)
          emit_i32_store(buf, 4)
          emit_i32_const_raw(buf, 0)
          emit_local_set(buf, copy_i_local)
          emit_block(buf)
          emit_loop(buf)
          emit_local_get(buf, copy_i_local)
          emit_local_get(buf, left_len_local)
          emit_i32_lt_s(buf)
          emit_i32_eqz(buf)
          emit_br_if(buf, 1)
          emit_local_get(buf, obj_local)
          emit_local_get(buf, copy_i_local)
          emit_i32_add(buf)
          emit_local_get(buf, left_ptr_local)
          emit_local_get(buf, copy_i_local)
          emit_i32_add(buf)
          emit_i32_load8_u(buf, 8)
          emit_i32_store8(buf, 8)
          emit_local_get(buf, copy_i_local)
          emit_i32_const_raw(buf, 1)
          emit_i32_add(buf)
          emit_local_set(buf, copy_i_local)
          emit_br(buf, 0)
          emit_end(buf)
          emit_end(buf)
          emit_i32_const_raw(buf, 0)
          emit_local_set(buf, copy_i_local)
          emit_block(buf)
          emit_loop(buf)
          emit_local_get(buf, copy_i_local)
          emit_local_get(buf, right_len_local)
          emit_i32_lt_s(buf)
          emit_i32_eqz(buf)
          emit_br_if(buf, 1)
          emit_local_get(buf, obj_local)
          emit_local_get(buf, left_len_local)
          emit_i32_add(buf)
          emit_local_get(buf, copy_i_local)
          emit_i32_add(buf)
          emit_local_get(buf, right_ptr_local)
          emit_local_get(buf, copy_i_local)
          emit_i32_add(buf)
          emit_i32_load8_u(buf, 8)
          emit_i32_store8(buf, 8)
          emit_local_get(buf, copy_i_local)
          emit_i32_const_raw(buf, 1)
          emit_i32_add(buf)
          emit_local_set(buf, copy_i_local)
          emit_br(buf, 0)
          emit_end(buf)
          emit_end(buf)
          emit_local_get(buf, obj_local)
          emit_i64_extend_i32_u(buf)
          emit_i64_const_raw(buf, tag_obj.to_int64())
          emit_i64_or(buf)
        }
      } else if name == "string_equals" {
        let pos_args = extract_positional_exprs(args, "string_equals")
        if pos_args.length() != 2 {
          raise WasmGenError::Unsupported("string_equals arity")
        }
        if ctx.use_js_strings {
          ctx.need_js_equals = true
          compile_expr_ref(ctx, buf, pos_args[0])
          compile_expr_ref(ctx, buf, pos_args[1])
          emit_call(buf, import_index_js_equals(ctx))
          emit_i64_extend_i32_s(buf)
          emit_i64_const_raw(buf, 2L)
          emit_i64_shl(buf)
          emit_i64_const_raw(buf, tag_bool.to_int64())
          emit_i64_or(buf)
        } else {
          let left_ptr_local = alloc_temp_local(ctx)
          let right_ptr_local = alloc_temp_local(ctx)
          let left_len_local = alloc_temp_local(ctx)
          let right_len_local = alloc_temp_local(ctx)
          let loop_i_local = alloc_temp_local(ctx)
          let eq_local = alloc_temp_local(ctx)
          compile_expr_i32(ctx, buf, pos_args[0])
          emit_i64_const_raw(buf, (-4).to_int64())
          emit_i64_and(buf)
          emit_i32_wrap_i64(buf)
          emit_local_set(buf, left_ptr_local)
          compile_expr_i32(ctx, buf, pos_args[1])
          emit_i64_const_raw(buf, (-4).to_int64())
          emit_i64_and(buf)
          emit_i32_wrap_i64(buf)
          emit_local_set(buf, right_ptr_local)
          emit_local_get(buf, left_ptr_local)
          emit_local_get(buf, right_ptr_local)
          emit_i32_eq(buf)
          buf.push((4).to_byte()) // if
          buf.push((127).to_byte()) // result i32
          emit_i32_const_raw(buf, 1)
          buf.push((5).to_byte()) // else
          emit_local_get(buf, left_ptr_local)
          emit_i32_load(buf, 4)
          emit_local_set(buf, left_len_local)
          emit_local_get(buf, right_ptr_local)
          emit_i32_load(buf, 4)
          emit_local_set(buf, right_len_local)
          emit_local_get(buf, left_len_local)
          emit_local_get(buf, right_len_local)
          emit_i32_eq(buf)
          buf.push((4).to_byte()) // if
          buf.push((127).to_byte()) // result i32
          emit_i32_const_raw(buf, 1)
          emit_local_set(buf, eq_local)
          emit_i32_const_raw(buf, 0)
          emit_local_set(buf, loop_i_local)
          emit_block(buf)
          emit_loop(buf)
          emit_local_get(buf, loop_i_local)
          emit_local_get(buf, left_len_local)
          emit_i32_lt_s(buf)
          emit_i32_eqz(buf)
          emit_br_if(buf, 1)
          emit_local_get(buf, left_ptr_local)
          emit_local_get(buf, loop_i_local)
          emit_i32_add(buf)
          emit_i32_load8_u(buf, 8)
          emit_local_get(buf, right_ptr_local)
          emit_local_get(buf, loop_i_local)
          emit_i32_add(buf)
          emit_i32_load8_u(buf, 8)
          emit_i32_eq(buf)
          emit_i32_eqz(buf)
          buf.push((4).to_byte()) // if
          buf.push((64).to_byte()) // void
          emit_i32_const_raw(buf, 0)
          emit_local_set(buf, eq_local)
          emit_local_get(buf, left_len_local)
          emit_local_set(buf, loop_i_local)
          buf.push((5).to_byte()) // else
          emit_local_get(buf, loop_i_local)
          emit_i32_const_raw(buf, 1)
          emit_i32_add(buf)
          emit_local_set(buf, loop_i_local)
          buf.push((11).to_byte()) // end if
          emit_br(buf, 0)
          emit_end(buf)
          emit_end(buf)
          emit_local_get(buf, eq_local)
          buf.push((5).to_byte()) // else
          emit_i32_const_raw(buf, 0)
          buf.push((11).to_byte()) // end if
          buf.push((11).to_byte()) // end if
          emit_i64_extend_i32_s(buf)
          emit_i64_const_raw(buf, 2L)
          emit_i64_shl(buf)
          emit_i64_const_raw(buf, tag_bool.to_int64())
          emit_i64_or(buf)
        }
      } else if name == "string_builder" {
        // string_builder() -> allocate empty array obj with len=0 (same layout as array_builder)
        let max_cap = 256
        require_heap(ctx)
        let size = align4(8 + max_cap * 4)
        let obj_local = alloc_temp_local(ctx)
        emit_heap_alloc(ctx, buf, size, obj_local)
        emit_local_get(buf, obj_local)
        emit_i32_const_raw(buf, obj_array)
        emit_i32_store(buf, 0)
        emit_local_get(buf, obj_local)
        emit_i32_const_raw(buf, 0)
        emit_i32_store(buf, 4)
        emit_local_get(buf, obj_local)
        emit_i64_extend_i32_u(buf)
        emit_i64_const_raw(buf, tag_obj.to_int64())
        emit_i64_or(buf)
      } else if name == "string_builder_push" {
        // string_builder_push(builder, value) -> same layout as array_builder_push
        let pos_args = extract_positional_exprs(args, name)
        if pos_args.length() != 2 {
          raise WasmGenError::Unsupported("string_builder_push arity")
        }
        let builder_local = alloc_temp_local(ctx)
        let ptr_local = alloc_temp_local(ctx)
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_i64_const_raw(buf, (-4).to_int64())
        emit_i64_and(buf)
        emit_i32_wrap_i64(buf)
        emit_local_tee(buf, builder_local)
        emit_local_set(buf, ptr_local)
        // store value at [ptr + 8 + len*4]
        emit_local_get(buf, ptr_local)
        emit_local_get(buf, ptr_local)
        emit_i32_load(buf, 4) // len
        emit_i32_const_raw(buf, 4)
        emit_i32_mul(buf)
        emit_i32_add(buf)
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_i32_wrap_i64(buf)
        emit_i32_store(buf, 8)
        // increment len
        emit_local_get(buf, ptr_local)
        emit_local_get(buf, ptr_local)
        emit_i32_load(buf, 4)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_i32_store(buf, 4)
        // return unit
        emit_i64_const_tagged(buf, 0L)
      } else if name == "string_builder_freeze" {
        // string_builder_freeze(builder) -> concatenate all stored strings
        // Two-pass: 1) sum total byte length, 2) allocate and copy
        let pos_args = extract_positional_exprs(args, name)
        if pos_args.length() != 1 {
          raise WasmGenError::Unsupported("string_builder_freeze arity")
        }
        require_heap(ctx)
        let builder_ptr = alloc_temp_local(ctx)
        let num_strings = alloc_temp_local(ctx)
        let total_len = alloc_temp_local(ctx)
        let result_ptr = alloc_temp_local(ctx)
        let loop_i = alloc_temp_local(ctx)
        let str_ptr = alloc_temp_local(ctx)
        let str_len = alloc_temp_local(ctx)
        let write_offset = alloc_temp_local(ctx)
        let copy_j = alloc_temp_local(ctx)
        let alloc_size = alloc_temp_local(ctx)
        // untag builder pointer
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_i64_const_raw(buf, (-4).to_int64())
        emit_i64_and(buf)
        emit_i32_wrap_i64(buf)
        emit_local_set(buf, builder_ptr)
        // read number of strings
        emit_local_get(buf, builder_ptr)
        emit_i32_load(buf, 4)
        emit_local_set(buf, num_strings)
        // Pass 1: calculate total byte length
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, total_len)
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, loop_i)
        emit_block(buf)
        emit_loop(buf)
        emit_local_get(buf, loop_i)
        emit_local_get(buf, num_strings)
        emit_i32_ge_s(buf)
        emit_br_if(buf, 1) // break if i >= num_strings
        // load string ref at builder_ptr + 8 + i*4, untag to get str_ptr
        emit_local_get(buf, builder_ptr)
        emit_local_get(buf, loop_i)
        emit_i32_const_raw(buf, 4)
        emit_i32_mul(buf)
        emit_i32_add(buf)
        emit_i32_load(buf, 8)
        emit_i32_const_raw(buf, -4)
        emit_i32_and(buf)
        emit_local_set(buf, str_ptr)
        // total_len += str_ptr.len (at offset 4)
        emit_local_get(buf, total_len)
        emit_local_get(buf, str_ptr)
        emit_i32_load(buf, 4)
        emit_i32_add(buf)
        emit_local_set(buf, total_len)
        // i++
        emit_local_get(buf, loop_i)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, loop_i)
        emit_br(buf, 0)
        emit_end(buf)
        emit_end(buf)
        // Allocate result string: align4(8 + total_len)
        emit_local_get(buf, total_len)
        emit_i32_const_raw(buf, 11) // 8 + 3 for alignment
        emit_i32_add(buf)
        emit_i32_const_raw(buf, -4)
        emit_i32_and(buf)
        emit_local_set(buf, alloc_size)
        emit_heap_alloc_local(ctx, buf, alloc_size, result_ptr)
        emit_local_get(buf, result_ptr)
        emit_i32_const_raw(buf, obj_string)
        emit_i32_store(buf, 0)
        emit_local_get(buf, result_ptr)
        emit_local_get(buf, total_len)
        emit_i32_store(buf, 4)
        // Pass 2: copy bytes from each string into result
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, write_offset)
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, loop_i)
        emit_block(buf) // outer block
        emit_loop(buf) // outer loop
        emit_local_get(buf, loop_i)
        emit_local_get(buf, num_strings)
        emit_i32_ge_s(buf)
        emit_br_if(buf, 1) // break if i >= num_strings
        // load and untag string ptr
        emit_local_get(buf, builder_ptr)
        emit_local_get(buf, loop_i)
        emit_i32_const_raw(buf, 4)
        emit_i32_mul(buf)
        emit_i32_add(buf)
        emit_i32_load(buf, 8)
        emit_i32_const_raw(buf, -4)
        emit_i32_and(buf)
        emit_local_set(buf, str_ptr)
        emit_local_get(buf, str_ptr)
        emit_i32_load(buf, 4)
        emit_local_set(buf, str_len)
        // inner loop: copy str_len bytes
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, copy_j)
        emit_block(buf) // inner block
        emit_loop(buf) // inner loop
        emit_local_get(buf, copy_j)
        emit_local_get(buf, str_len)
        emit_i32_ge_s(buf)
        emit_br_if(buf, 1) // break if j >= str_len
        // result_ptr + 8 + write_offset + j
        emit_local_get(buf, result_ptr)
        emit_local_get(buf, write_offset)
        emit_i32_add(buf)
        emit_local_get(buf, copy_j)
        emit_i32_add(buf)
        // load byte from str_ptr + 8 + j
        emit_local_get(buf, str_ptr)
        emit_local_get(buf, copy_j)
        emit_i32_add(buf)
        emit_i32_load8_u(buf, 8)
        emit_i32_store8(buf, 8)
        // j++
        emit_local_get(buf, copy_j)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, copy_j)
        emit_br(buf, 0)
        emit_end(buf) // end inner loop
        emit_end(buf) // end inner block
        // write_offset += str_len
        emit_local_get(buf, write_offset)
        emit_local_get(buf, str_len)
        emit_i32_add(buf)
        emit_local_set(buf, write_offset)
        // i++
        emit_local_get(buf, loop_i)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, loop_i)
        emit_br(buf, 0)
        emit_end(buf) // end outer loop
        emit_end(buf) // end outer block
        // return tagged result
        emit_local_get(buf, result_ptr)
        emit_i64_extend_i32_u(buf)
        emit_i64_const_raw(buf, tag_obj.to_int64())
        emit_i64_or(buf)
      } else if name == "array_builder" {
        // array_builder() -> allocate empty array obj with len=0
        // Reserve max_capacity * 4 bytes after header for future pushes
        let max_cap = 256
        require_heap(ctx)
        let size = align4(8 + max_cap * 4)
        let obj_local = alloc_temp_local(ctx)
        emit_heap_alloc(ctx, buf, size, obj_local)
        emit_local_get(buf, obj_local)
        emit_i32_const_raw(buf, obj_array)
        emit_i32_store(buf, 0)
        emit_local_get(buf, obj_local)
        emit_i32_const_raw(buf, 0)
        emit_i32_store(buf, 4)
        emit_local_get(buf, obj_local)
        emit_i64_extend_i32_u(buf)
        emit_i64_const_raw(buf, tag_obj.to_int64())
        emit_i64_or(buf)
      } else if name == "array_builder_push" {
        // array_builder_push(builder, value) -> store value at [builder + 8 + len*4], increment len
        let pos_args = extract_positional_exprs(args, name)
        if pos_args.length() != 2 {
          raise WasmGenError::Unsupported("array_builder_push arity")
        }
        let builder_local = alloc_temp_local(ctx)
        let ptr_local = alloc_temp_local(ctx)
        compile_expr_i32(ctx, buf, pos_args[0])
        // untag pointer
        emit_i64_const_raw(buf, (-4).to_int64())
        emit_i64_and(buf)
        emit_i32_wrap_i64(buf)
        emit_local_tee(buf, builder_local)
        emit_local_set(buf, ptr_local)
        // store value at [ptr + 8 + len*4]
        emit_local_get(buf, ptr_local)
        emit_local_get(buf, ptr_local)
        emit_i32_load(buf, 4) // len
        emit_i32_const_raw(buf, 4)
        emit_i32_mul(buf)
        emit_i32_add(buf)
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_i32_wrap_i64(buf)
        emit_i32_store(buf, 8)
        // increment len
        emit_local_get(buf, ptr_local)
        emit_local_get(buf, ptr_local)
        emit_i32_load(buf, 4)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_i32_store(buf, 4)
        // return unit
        emit_i64_const_tagged(buf, 0L)
      } else if name == "array_builder_freeze" {
        // array_builder_freeze(builder) -> return builder as-is (it is already an array obj)
        let pos_args = extract_positional_exprs(args, name)
        if pos_args.length() != 1 {
          raise WasmGenError::Unsupported("array_builder_freeze arity")
        }
        compile_expr_i32(ctx, buf, pos_args[0])
      } else if name == "map_builder" {
        // map_builder() -> allocate empty map obj with len=0
        let max_cap = 128
        require_heap(ctx)
        let size = align4(8 + max_cap * 8)
        let obj_local = alloc_temp_local(ctx)
        emit_heap_alloc(ctx, buf, size, obj_local)
        emit_local_get(buf, obj_local)
        emit_i32_const_raw(buf, obj_map)
        emit_i32_store(buf, 0)
        emit_local_get(buf, obj_local)
        emit_i32_const_raw(buf, 0)
        emit_i32_store(buf, 4)
        emit_local_get(buf, obj_local)
        emit_i64_extend_i32_u(buf)
        emit_i64_const_raw(buf, tag_obj.to_int64())
        emit_i64_or(buf)
      } else if name == "map_builder_set" {
        // map_builder_set(builder, key, value) -> store key+value at end, increment len
        let pos_args = extract_positional_exprs(args, name)
        if pos_args.length() != 3 {
          raise WasmGenError::Unsupported("map_builder_set arity")
        }
        let ptr_local = alloc_temp_local(ctx)
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_i64_const_raw(buf, (-4).to_int64())
        emit_i64_and(buf)
        emit_i32_wrap_i64(buf)
        emit_local_set(buf, ptr_local)
        // key slot offset = 8 + len*8
        let offset_local = alloc_temp_local(ctx)
        emit_local_get(buf, ptr_local)
        emit_i32_load(buf, 4) // len
        emit_i32_const_raw(buf, 8)
        emit_i32_mul(buf)
        emit_local_set(buf, offset_local)
        // store key at [ptr + 8 + len*8]
        emit_local_get(buf, ptr_local)
        emit_local_get(buf, offset_local)
        emit_i32_add(buf)
        if ctx.use_js_strings {
          // key is externref -> store in extern table
          let key_kind = infer_expr_kind(ctx, pos_args[1])
          if key_kind == ValueKind::ExternRef {
            ctx.need_extern_table = true
            let slot = ctx.extern_table_next_slot
            ctx.extern_table_next_slot += 1
            emit_i32_const_raw(buf, slot)
            compile_expr(ctx, buf, pos_args[1])
            emit_table_set(buf, ctx.extern_table_index)
            emit_i32_const_raw(buf, slot)
          } else {
            compile_expr_i32(ctx, buf, pos_args[1])
            emit_i32_wrap_i64(buf)
          }
        } else {
          compile_expr_i32(ctx, buf, pos_args[1])
          emit_i32_wrap_i64(buf)
        }
        emit_i32_store(buf, 8)
        // store value at [ptr + 8 + len*8 + 4]
        emit_local_get(buf, ptr_local)
        emit_local_get(buf, offset_local)
        emit_i32_add(buf)
        compile_expr_i32(ctx, buf, pos_args[2])
        emit_i32_wrap_i64(buf)
        emit_i32_store(buf, 12)
        // increment len
        emit_local_get(buf, ptr_local)
        emit_local_get(buf, ptr_local)
        emit_i32_load(buf, 4)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_i32_store(buf, 4)
        // return unit
        emit_i64_const_tagged(buf, 0L)
      } else if name == "map_builder_freeze" {
        // map_builder_freeze(builder) -> return builder as-is (it is already a map obj)
        let pos_args = extract_positional_exprs(args, name)
        if pos_args.length() != 1 {
          raise WasmGenError::Unsupported("map_builder_freeze arity")
        }
        compile_expr_i32(ctx, buf, pos_args[0])
      } else if name == "array_length" {
        // array_length(arr) -> load len field, shift left 2 (tag as int)
        let pos_args = extract_positional_exprs(args, name)
        if pos_args.length() != 1 {
          raise WasmGenError::Unsupported("array_length arity")
        }
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_i64_const_raw(buf, (-4).to_int64())
        emit_i64_and(buf)
        emit_i32_wrap_i64(buf)
        emit_i32_load(buf, 4)
        emit_i64_extend_i32_s(buf)
        emit_i64_const_raw(buf, 2L)
        emit_i64_shl(buf)
        emit_i64_const_raw(buf, tag_int.to_int64())
        emit_i64_or(buf)
      } else if name == "array_get" || name == "__index" {
        // array_get(arr, idx) -> load arr[idx]
        let pos_args = extract_positional_exprs(args, name)
        if pos_args.length() != 2 {
          raise WasmGenError::Unsupported("array_get arity")
        }
        let ptr_local = alloc_temp_local(ctx)
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_i64_const_raw(buf, (-4).to_int64())
        emit_i64_and(buf)
        emit_i32_wrap_i64(buf)
        emit_local_set(buf, ptr_local)
        // offset = 8 + (idx >> 2) * 4
        emit_local_get(buf, ptr_local)
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_i64_const_raw(buf, 2L)
        emit_i64_shr_s(buf)
        emit_i32_wrap_i64(buf)
        emit_i32_const_raw(buf, 4)
        emit_i32_mul(buf)
        emit_i32_add(buf)
        emit_i32_load(buf, 8)
        emit_i64_extend_i32_s(buf)
      } else if name == "map_get" {
        // map_get(map, key) -> linear search for key, return value
        let pos_args = extract_positional_exprs(args, name)
        if pos_args.length() != 2 {
          raise WasmGenError::Unsupported("map_get arity")
        }
        let map_ptr = alloc_temp_local(ctx)
        let map_len = alloc_temp_local(ctx)
        let loop_i = alloc_temp_local(ctx)
        let result_local = alloc_temp_local(ctx)
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_i64_const_raw(buf, (-4).to_int64())
        emit_i64_and(buf)
        emit_i32_wrap_i64(buf)
        emit_local_set(buf, map_ptr)
        emit_local_get(buf, map_ptr)
        emit_i32_load(buf, 4)
        emit_local_set(buf, map_len)
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, loop_i)
        emit_i64_const_tagged(buf, 0L)
        emit_i32_wrap_i64(buf)
        emit_local_set(buf, result_local)
        if ctx.use_js_strings {
          // key is externref: store in temp table slot for comparison
          let key_kind = infer_expr_kind(ctx, pos_args[1])
          if key_kind == ValueKind::ExternRef {
            ctx.need_extern_table = true
            ctx.need_js_equals = true
            let key_local = alloc_temp_local_with_kind(
              ctx,
              ValueKind::ExternRef,
            )
            compile_expr(ctx, buf, pos_args[1])
            emit_local_set(buf, key_local)
            // loop
            buf.push((3).to_byte()) // loop
            buf.push((64).to_byte()) // void
            emit_local_get(buf, loop_i)
            emit_local_get(buf, map_len)
            emit_i32_lt_s(buf)
            buf.push((4).to_byte()) // if
            buf.push((64).to_byte()) // void
            // load stored key from extern table
            emit_local_get(buf, map_ptr)
            emit_local_get(buf, loop_i)
            emit_i32_const_raw(buf, 8)
            emit_i32_mul(buf)
            emit_i32_add(buf)
            emit_i32_load(buf, 8) // slot index
            emit_table_get(buf, ctx.extern_table_index)
            emit_local_get(buf, key_local)
            emit_call(buf, import_index_js_equals(ctx))
            buf.push((4).to_byte()) // if (equals)
            buf.push((64).to_byte()) // void
            // found: load value
            emit_local_get(buf, map_ptr)
            emit_local_get(buf, loop_i)
            emit_i32_const_raw(buf, 8)
            emit_i32_mul(buf)
            emit_i32_add(buf)
            emit_i32_load(buf, 12) // value at key_offset + 4
            emit_local_set(buf, result_local)
            buf.push((11).to_byte()) // end if (equals)
            // loop_i++
            emit_local_get(buf, loop_i)
            emit_i32_const_raw(buf, 1)
            emit_i32_add(buf)
            emit_local_set(buf, loop_i)
            buf.push((12).to_byte()) // br
            write_u32_leb(buf, 1) // to loop
            buf.push((11).to_byte()) // end if (i < len)
            buf.push((11).to_byte()) // end loop
            emit_local_get(buf, result_local)
            emit_i64_extend_i32_s(buf)
          } else {
            // non-externref key (unlikely for map_get in json.vibe, but handle)
            let key_local = alloc_temp_local(ctx)
            compile_expr_i32(ctx, buf, pos_args[1])
            emit_i32_wrap_i64(buf)
            emit_local_set(buf, key_local)
            buf.push((3).to_byte()) // loop
            buf.push((64).to_byte()) // void
            emit_local_get(buf, loop_i)
            emit_local_get(buf, map_len)
            emit_i32_lt_s(buf)
            buf.push((4).to_byte()) // if
            buf.push((64).to_byte()) // void
            emit_local_get(buf, map_ptr)
            emit_local_get(buf, loop_i)
            emit_i32_const_raw(buf, 8)
            emit_i32_mul(buf)
            emit_i32_add(buf)
            emit_i32_load(buf, 8) // key
            emit_local_get(buf, key_local)
            emit_i32_eq(buf)
            buf.push((4).to_byte()) // if
            buf.push((64).to_byte()) // void
            emit_local_get(buf, map_ptr)
            emit_local_get(buf, loop_i)
            emit_i32_const_raw(buf, 8)
            emit_i32_mul(buf)
            emit_i32_add(buf)
            emit_i32_load(buf, 12) // value
            emit_local_set(buf, result_local)
            buf.push((11).to_byte()) // end if
            emit_local_get(buf, loop_i)
            emit_i32_const_raw(buf, 1)
            emit_i32_add(buf)
            emit_local_set(buf, loop_i)
            buf.push((12).to_byte()) // br
            write_u32_leb(buf, 1) // to loop
            buf.push((11).to_byte()) // end if
            buf.push((11).to_byte()) // end loop
            emit_local_get(buf, result_local)
            emit_i64_extend_i32_s(buf)
          }
        } else {
          // non-js-string mode: keys are i32 string pointers
          let key_local = alloc_temp_local(ctx)
          compile_expr_i32(ctx, buf, pos_args[1])
          emit_i32_wrap_i64(buf)
          emit_local_set(buf, key_local)
          buf.push((3).to_byte()) // loop
          buf.push((64).to_byte()) // void
          emit_local_get(buf, loop_i)
          emit_local_get(buf, map_len)
          emit_i32_lt_s(buf)
          buf.push((4).to_byte()) // if
          buf.push((64).to_byte()) // void
          emit_local_get(buf, map_ptr)
          emit_local_get(buf, loop_i)
          emit_i32_const_raw(buf, 8)
          emit_i32_mul(buf)
          emit_i32_add(buf)
          emit_i32_load(buf, 8) // key
          emit_local_get(buf, key_local)
          emit_i32_eq(buf)
          buf.push((4).to_byte()) // if
          buf.push((64).to_byte()) // void
          emit_local_get(buf, map_ptr)
          emit_local_get(buf, loop_i)
          emit_i32_const_raw(buf, 8)
          emit_i32_mul(buf)
          emit_i32_add(buf)
          emit_i32_load(buf, 12) // value
          emit_local_set(buf, result_local)
          buf.push((11).to_byte()) // end if
          emit_local_get(buf, loop_i)
          emit_i32_const_raw(buf, 1)
          emit_i32_add(buf)
          emit_local_set(buf, loop_i)
          buf.push((12).to_byte()) // br
          write_u32_leb(buf, 1) // to loop
          buf.push((11).to_byte()) // end if
          buf.push((11).to_byte()) // end loop
          emit_local_get(buf, result_local)
          emit_i64_extend_i32_s(buf)
        }
      } else if name == "sleep" {
        // sleep(ms) - call imported sleep function
        let pos_args = extract_positional_exprs(args, "sleep")
        if pos_args.length() != 1 {
          raise WasmGenError::Unsupported("sleep arity")
        }
        // Compile the duration argument (tagged int)
        compile_expr_i32(ctx, buf, pos_args[0])
        // Call imported sleep function (host will untag: ms >> 2)
        buf.push((0x10).to_byte()) // call
        write_u32_leb(buf, ctx.sleep_import_index)
        // Return Unit (tagged 0)
        emit_i64_const_raw(buf, tag_int_value64(0L))
      } else if name == "stdout_write_char" {
        let pos_args = extract_positional_exprs(args, "stdout_write_char")
        if pos_args.length() != 1 {
          raise WasmGenError::Unsupported("stdout_write_char arity")
        }
        require_heap(ctx)
        let code_local = alloc_temp_local(ctx)
        let out_stream_local = alloc_temp_local(ctx)
        let scratch_local = alloc_temp_local(ctx)
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_i64_const_raw(buf, 2L)
        emit_i64_shr_s(buf)
        emit_i32_wrap_i64(buf)
        emit_local_set(buf, code_local)
        emit_local_get(buf, ctx.heap_local)
        emit_local_set(buf, scratch_local)
        emit_local_get(buf, scratch_local)
        emit_local_get(buf, code_local)
        emit_i32_store8(buf, 0)
        emit_call(buf, import_index_stdout_get_stream(ctx))
        emit_local_set(buf, out_stream_local)
        emit_local_get(buf, out_stream_local)
        emit_local_get(buf, scratch_local)
        emit_i32_const_raw(buf, 1)
        emit_local_get(buf, scratch_local)
        emit_i32_const_raw(buf, 4)
        emit_i32_add(buf)
        emit_call(buf, import_index_stdout_write_stream(ctx))
        emit_i64_const_raw(buf, tag_int_value64(0L))
      } else if name == "stdout_write_stream" {
        if ctx.use_js_strings {
          raise WasmGenError::Unsupported(
            "stdout_write_stream requires --wasm backend",
          )
        }
        let pos_args = extract_positional_exprs(args, "stdout_write_stream")
        if pos_args.length() != 1 {
          raise WasmGenError::Unsupported("stdout_write_stream arity")
        }
        require_heap(ctx)
        let raw_local = alloc_temp_local(ctx)
        let len_local = alloc_temp_local(ctx)
        let out_stream_local = alloc_temp_local(ctx)
        let ret_area_local = alloc_temp_local(ctx)
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_i64_const_raw(buf, (-4).to_int64())
        emit_i64_and(buf)
        emit_i32_wrap_i64(buf)
        emit_local_set(buf, raw_local)
        emit_local_get(buf, raw_local)
        emit_i32_load(buf, 4)
        emit_local_set(buf, len_local)
        emit_local_get(buf, len_local)
        emit_i32_eqz(buf)
        buf.push((4).to_byte()) // if
        buf.push((126).to_byte()) // result i64
        emit_i64_const_raw(buf, tag_int_value64(0L))
        buf.push((5).to_byte()) // else
        emit_call(buf, import_index_stdout_get_stream(ctx))
        emit_local_set(buf, out_stream_local)
        emit_heap_alloc(ctx, buf, align4(8), ret_area_local)
        emit_local_get(buf, out_stream_local)
        emit_local_get(buf, raw_local)
        emit_i32_const_raw(buf, 8)
        emit_i32_add(buf)
        emit_local_get(buf, len_local)
        emit_local_get(buf, ret_area_local)
        emit_call(buf, import_index_stdout_write_stream(ctx))
        emit_i64_const_raw(buf, tag_int_value64(0L))
        buf.push((11).to_byte()) // end if
      } else if name == "stdin_read_char" {
        let pos_args = extract_positional_exprs(args, "stdin_read_char")
        if pos_args.length() != 0 {
          raise WasmGenError::Unsupported("stdin_read_char arity")
        }
        require_heap(ctx)
        let in_stream_local = alloc_temp_local(ctx)
        let ret_area_local = alloc_temp_local(ctx)
        let data_ptr_local = alloc_temp_local(ctx)
        let data_len_local = alloc_temp_local(ctx)
        emit_call(buf, import_index_stdin_get_stream(ctx))
        emit_local_set(buf, in_stream_local)
        emit_heap_alloc(ctx, buf, align4(16), ret_area_local)
        // imported `blocking-read` may call cabi_realloc; sync local heap first.
        if ctx.heap_local >= 0 && ctx.use_heap_global {
          emit_local_get(buf, ctx.heap_local)
          emit_global_set(buf, ctx.heap_global)
        }
        emit_local_get(buf, in_stream_local)
        // i64.const 1 (len=1)
        buf.push((66).to_byte())
        buf.push((1).to_byte())
        emit_local_get(buf, ret_area_local)
        emit_call(buf, import_index_stdin_read_stream(ctx))
        // reload heap in case cabi_realloc bumped it.
        if ctx.heap_local >= 0 && ctx.use_heap_global {
          emit_global_get(buf, ctx.heap_global)
          emit_local_set(buf, ctx.heap_local)
        }
        emit_local_get(buf, ret_area_local)
        emit_i32_load8_u(buf, 0)
        emit_i32_eqz(buf)
        buf.push((4).to_byte()) // if
        buf.push((126).to_byte()) // result i64
        emit_local_get(buf, ret_area_local)
        emit_i32_load(buf, 4)
        emit_local_set(buf, data_ptr_local)
        emit_local_get(buf, ret_area_local)
        emit_i32_load(buf, 8)
        emit_local_set(buf, data_len_local)
        emit_local_get(buf, data_len_local)
        emit_i32_eqz(buf)
        buf.push((4).to_byte()) // if
        buf.push((126).to_byte()) // result i64
        emit_i64_const_raw(buf, tag_int_value64(-1L))
        buf.push((5).to_byte()) // else
        emit_local_get(buf, data_ptr_local)
        emit_i32_load8_u(buf, 0)
        emit_i64_extend_i32_s(buf)
        emit_i64_const_raw(buf, 2L)
        emit_i64_shl(buf)
        emit_i64_const_raw(buf, tag_int.to_int64())
        emit_i64_or(buf)
        buf.push((11).to_byte()) // end if
        buf.push((5).to_byte()) // else
        emit_i64_const_raw(buf, tag_int_value64(-1L))
        buf.push((11).to_byte()) // end if
      } else if name == "stdin_read_stream" {
        if ctx.use_js_strings {
          raise WasmGenError::Unsupported(
            "stdin_read_stream requires --wasm backend",
          )
        }
        let pos_args = extract_positional_exprs(args, "stdin_read_stream")
        if pos_args.length() != 1 {
          raise WasmGenError::Unsupported("stdin_read_stream arity")
        }
        require_heap(ctx)
        let in_stream_local = alloc_temp_local(ctx)
        let req_len_local = alloc_temp_local(ctx)
        let ret_area_local = alloc_temp_local(ctx)
        let data_ptr_local = alloc_temp_local(ctx)
        let data_len_local = alloc_temp_local(ctx)
        let obj_local = alloc_temp_local(ctx)
        let copy_i_local = alloc_temp_local(ctx)
        let alloc_size_local = alloc_temp_local(ctx)
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_i64_const_raw(buf, 2L)
        emit_i64_shr_s(buf)
        emit_i32_wrap_i64(buf)
        emit_local_set(buf, req_len_local)
        emit_local_get(buf, req_len_local)
        emit_i32_const_raw(buf, 0)
        emit_i32_lt_s(buf)
        buf.push((4).to_byte()) // if
        buf.push((64).to_byte()) // empty result
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, req_len_local)
        buf.push((11).to_byte()) // end if
        emit_call(buf, import_index_stdin_get_stream(ctx))
        emit_local_set(buf, in_stream_local)
        emit_heap_alloc(ctx, buf, align4(16), ret_area_local)
        // imported `blocking-read` may call cabi_realloc; sync local heap first.
        if ctx.heap_local >= 0 && ctx.use_heap_global {
          emit_local_get(buf, ctx.heap_local)
          emit_global_set(buf, ctx.heap_global)
        }
        emit_local_get(buf, in_stream_local)
        emit_local_get(buf, req_len_local)
        // i64.extend_i32_u
        buf.push((173).to_byte())
        emit_local_get(buf, ret_area_local)
        emit_call(buf, import_index_stdin_read_stream(ctx))
        // reload heap in case cabi_realloc bumped it.
        if ctx.heap_local >= 0 && ctx.use_heap_global {
          emit_global_get(buf, ctx.heap_global)
          emit_local_set(buf, ctx.heap_local)
        }
        emit_local_get(buf, ret_area_local)
        emit_i32_load8_u(buf, 0)
        emit_i32_eqz(buf)
        buf.push((4).to_byte()) // if
        buf.push((126).to_byte()) // result i64
        emit_local_get(buf, ret_area_local)
        emit_i32_load(buf, 4)
        emit_local_set(buf, data_ptr_local)
        emit_local_get(buf, ret_area_local)
        emit_i32_load(buf, 8)
        emit_local_set(buf, data_len_local)
        emit_local_get(buf, data_len_local)
        emit_i32_const_raw(buf, 11) // align4(8 + len) == (len + 11) & -4
        emit_i32_add(buf)
        emit_i32_const_raw(buf, -4)
        emit_i32_and(buf)
        emit_local_set(buf, alloc_size_local)
        emit_heap_alloc_local(ctx, buf, alloc_size_local, obj_local)
        emit_local_get(buf, obj_local)
        emit_i32_const_raw(buf, obj_string)
        emit_i32_store(buf, 0)
        emit_local_get(buf, obj_local)
        emit_local_get(buf, data_len_local)
        emit_i32_store(buf, 4)
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, copy_i_local)
        emit_block(buf)
        emit_loop(buf)
        emit_local_get(buf, copy_i_local)
        emit_local_get(buf, data_len_local)
        emit_i32_lt_s(buf)
        emit_i32_eqz(buf)
        emit_br_if(buf, 1)
        emit_local_get(buf, obj_local)
        emit_local_get(buf, copy_i_local)
        emit_i32_add(buf)
        emit_local_get(buf, data_ptr_local)
        emit_local_get(buf, copy_i_local)
        emit_i32_add(buf)
        emit_i32_load8_u(buf, 0)
        emit_i32_store8(buf, 8)
        emit_local_get(buf, copy_i_local)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, copy_i_local)
        emit_br(buf, 0)
        emit_end(buf)
        emit_end(buf)
        emit_local_get(buf, obj_local)
        emit_i64_extend_i32_u(buf)
        emit_i64_const_raw(buf, tag_obj.to_int64())
        emit_i64_or(buf)
        buf.push((5).to_byte()) // else
        emit_heap_alloc(ctx, buf, align4(8), obj_local)
        emit_local_get(buf, obj_local)
        emit_i32_const_raw(buf, obj_string)
        emit_i32_store(buf, 0)
        emit_local_get(buf, obj_local)
        emit_i32_const_raw(buf, 0)
        emit_i32_store(buf, 4)
        emit_local_get(buf, obj_local)
        emit_i64_extend_i32_u(buf)
        emit_i64_const_raw(buf, tag_obj.to_int64())
        emit_i64_or(buf)
        buf.push((11).to_byte()) // end if
      } else if name == "char_to_int" {
        let pos_args = extract_positional_exprs(args, "char_to_int")
        if pos_args.length() != 1 {
          raise WasmGenError::Unsupported("char_to_int arity")
        }
        compile_expr(ctx, buf, pos_args[0])
      } else if name == "char_from_int" {
        let pos_args = extract_positional_exprs(args, "char_from_int")
        if pos_args.length() != 1 {
          raise WasmGenError::Unsupported("char_from_int arity")
        }
        compile_expr(ctx, buf, pos_args[0])
      } else if name == "string_from_char_code" {
        let pos_args = extract_positional_exprs(args, "string_from_char_code")
        if pos_args.length() != 1 {
          raise WasmGenError::Unsupported("string_from_char_code arity")
        }
        require_heap(ctx)
        let raw_local = alloc_temp_local(ctx)
        let code_local = alloc_temp_local(ctx)
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_i64_const_raw(buf, 2L)
        emit_i64_shr_s(buf)
        emit_i32_wrap_i64(buf)
        emit_local_set(buf, code_local)
        emit_heap_alloc(ctx, buf, 12, raw_local)
        emit_local_get(buf, raw_local)
        emit_i32_const_raw(buf, obj_string)
        emit_i32_store(buf, 0)
        emit_local_get(buf, raw_local)
        emit_i32_const_raw(buf, 1)
        emit_i32_store(buf, 4)
        emit_local_get(buf, raw_local)
        emit_local_get(buf, code_local)
        emit_i32_store8(buf, 8)
        emit_local_get(buf, raw_local)
        emit_i64_extend_i32_u(buf)
        emit_i64_const_raw(buf, tag_obj.to_int64())
        emit_i64_or(buf)
      } else if ctx.fn_indices.contains(name) {
        // Resolve labeled arguments for user-defined functions
        let pos_args = resolve_args_with_labels(ctx, args, name)
        let param_kinds = match ctx.fn_params.get(name) {
          Some(kinds) => kinds
          None => []
        }
        if pos_args.length() != param_kinds.length() {
          raise WasmGenError::Unsupported("arity: " + name)
        }
        for i in 0..<pos_args.length() {
          let kind = param_kinds[i]
          if ctx.use_js_strings && kind == ValueKind::ExternRef {
            compile_expr_ref(ctx, buf, pos_args[i])
          } else {
            compile_expr_i32(ctx, buf, pos_args[i])
          }
        }
        let fn_idx = match ctx.fn_indices.get(name) {
          Some(i) => i
          None => 0
        }
        // Direct call needs the callee's closure env when the function has captures.
        // Do not fall back to current function env; it may belong to another closure.
        match ctx.locals.get(name) {
          Some(local_idx) if ctx.fn_local_sigs.contains(name) => {
            let env_local = alloc_temp_local(ctx)
            emit_local_get(buf, local_idx)
            emit_i64_const_raw(buf, tag_mask.to_int64())
            emit_i64_and(buf)
            emit_i64_const_raw(buf, tag_fn.to_int64())
            emit_i64_eq(buf)
            buf.push((4).to_byte()) // if
            buf.push((127).to_byte()) // result i32
            emit_i32_const_raw(buf, 0) // bare fn: env = 0
            buf.push((5).to_byte()) // else
            // closure: env ptr = untag obj ptr -> i32
            emit_local_get(buf, local_idx)
            emit_i64_const_raw(buf, (-4).to_int64())
            emit_i64_and(buf)
            emit_i32_wrap_i64(buf)
            buf.push((11).to_byte()) // end
            emit_local_set(buf, env_local)
            emit_local_get(buf, env_local)
          }
          _ =>
            if fn_index_needs_env(ctx, fn_idx) {
              raise WasmGenError::Unsupported(
                "missing closure env for direct call: " + name,
              )
            } else {
              emit_i32_const_raw(buf, 0)
            }
        }
        if ctx.heap_local >= 0 && ctx.use_heap_global {
          emit_local_get(buf, ctx.heap_local)
          emit_global_set(buf, ctx.heap_global)
        }
        let idx = func_import_count(ctx) + fn_idx
        emit_call(buf, idx)
        if ctx.heap_local >= 0 && ctx.use_heap_global {
          emit_global_get(buf, ctx.heap_global)
          emit_local_set(buf, ctx.heap_local)
        }
      } else if ctx.enum_ctor_tags.contains(name) {
        // Enum constructor call
        let tag = match ctx.enum_ctor_tags.get(name) {
          Some(t) => t
          None => 0
        }
        let arity = match ctx.enum_ctor_arities.get(name) {
          Some(a) => a
          None => 0
        }
        let pos_args = extract_positional_exprs(args, name)
        if arity == 0 {
          // Nullary ctor: heap object with just type + tag
          require_heap(ctx)
          let size = align4(8)
          let obj_local = alloc_temp_local(ctx)
          emit_heap_alloc(ctx, buf, size, obj_local)
          emit_local_get(buf, obj_local)
          emit_i32_const_raw(buf, obj_enum)
          emit_i32_store(buf, 0)
          emit_local_get(buf, obj_local)
          emit_i32_const_raw(buf, tag)
          emit_i32_store(buf, 4)
          emit_local_get(buf, obj_local)
          emit_i64_extend_i32_u(buf)
          emit_i64_const_raw(buf, tag_obj.to_int64())
          emit_i64_or(buf)
        } else {
          // Ctor with args: heap object with type + tag + payload
          require_heap(ctx)
          let size = align4(8 + arity * 4)
          let obj_local = alloc_temp_local(ctx)
          emit_heap_alloc(ctx, buf, size, obj_local)
          emit_local_get(buf, obj_local)
          emit_i32_const_raw(buf, obj_enum)
          emit_i32_store(buf, 0)
          emit_local_get(buf, obj_local)
          emit_i32_const_raw(buf, tag)
          emit_i32_store(buf, 4)
          for i in 0..<arity {
            let arg_kind = infer_expr_kind(ctx, pos_args[i])
            if ctx.use_js_strings && arg_kind == ValueKind::ExternRef {
              // Store externref in extern table, put slot index in payload
              ctx.need_extern_table = true
              let slot = ctx.extern_table_next_slot
              ctx.extern_table_next_slot += 1
              emit_i32_const_raw(buf, slot)
              compile_expr(ctx, buf, pos_args[i])
              emit_table_set(buf, ctx.extern_table_index)
              emit_local_get(buf, obj_local)
              emit_i32_const_raw(buf, slot)
              emit_i32_store(buf, 8 + i * 4)
            } else {
              emit_local_get(buf, obj_local)
              compile_expr_i32(ctx, buf, pos_args[i])
              emit_i32_wrap_i64(buf)
              emit_i32_store(buf, 8 + i * 4)
            }
          }
          emit_local_get(buf, obj_local)
          emit_i64_extend_i32_u(buf)
          emit_i64_const_raw(buf, tag_obj.to_int64())
          emit_i64_or(buf)
        }
      } else {
        if is_qualified_name(name) {
          raise WasmGenError::BackendLimit(backend="wasm", feature="qualified call: " + name)
        }
        let pos_args = extract_positional_exprs(args, name)
        if pos_args.length() == 1 && ctx.known_record_fields.contains(name) {
          // Fallback for method-style record field access desugared as `field(record)`.
          let record_ptr_local = alloc_temp_local(ctx)
          let record_len_local = alloc_temp_local(ctx)
          let loop_i_local = alloc_temp_local(ctx)
          let result_local = alloc_temp_local(ctx)
          let found_local = alloc_temp_local(ctx)
          let field_name_ptr = ctx.strings.intern(name)
          compile_expr_i32(ctx, buf, pos_args[0])
          emit_i64_const_raw(buf, (-4).to_int64())
          emit_i64_and(buf)
          emit_i32_wrap_i64(buf)
          emit_local_set(buf, record_ptr_local)
          emit_local_get(buf, record_ptr_local)
          emit_i32_load(buf, 4)
          emit_local_set(buf, record_len_local)
          emit_i32_const_raw(buf, 0)
          emit_local_set(buf, loop_i_local)
          emit_i64_const_tagged(buf, 0L)
          emit_i32_wrap_i64(buf)
          emit_local_set(buf, result_local)
          emit_i32_const_raw(buf, 0)
          emit_local_set(buf, found_local)
          emit_block(buf)
          emit_loop(buf)
          emit_local_get(buf, loop_i_local)
          emit_local_get(buf, record_len_local)
          emit_i32_lt_s(buf)
          emit_i32_eqz(buf)
          emit_br_if(buf, 1)
          emit_local_get(buf, record_ptr_local)
          emit_local_get(buf, loop_i_local)
          emit_i32_const_raw(buf, 8)
          emit_i32_mul(buf)
          emit_i32_add(buf)
          emit_i32_load(buf, 8)
          emit_i32_const_raw(buf, field_name_ptr)
          emit_i32_eq(buf)
          buf.push((4).to_byte()) // if
          buf.push((64).to_byte()) // void
          emit_local_get(buf, record_ptr_local)
          emit_local_get(buf, loop_i_local)
          emit_i32_const_raw(buf, 8)
          emit_i32_mul(buf)
          emit_i32_add(buf)
          emit_i32_load(buf, 12)
          emit_local_set(buf, result_local)
          emit_i32_const_raw(buf, 1)
          emit_local_set(buf, found_local)
          emit_local_get(buf, record_len_local)
          emit_local_set(buf, loop_i_local)
          buf.push((11).to_byte()) // end if
          emit_local_get(buf, loop_i_local)
          emit_i32_const_raw(buf, 1)
          emit_i32_add(buf)
          emit_local_set(buf, loop_i_local)
          emit_br(buf, 0)
          emit_end(buf)
          emit_end(buf)
          emit_local_get(buf, found_local)
          emit_i32_eqz(buf)
          buf.push((4).to_byte()) // if
          buf.push((64).to_byte()) // void
          buf.push((0).to_byte()) // unreachable
          buf.push((11).to_byte()) // end if
          emit_local_get(buf, result_local)
          emit_i64_extend_i32_s(buf)
        } else {
          raise WasmGenError::BackendLimit(backend="wasm", feature="call: " + name)
        }
      }
    }
    @core.Expr::Tuple(items~, span~) => {
      let _ = span
      compile_tuple_expr(ctx, buf, items)
    }
    @core.Expr::TupleIndex(expr~, index~, span~) => {
      let _ = span
      // Compile the tuple expression (puts tagged i64 pointer on stack)
      compile_expr(ctx, buf, expr)
      // Untag pointer to i32
      emit_i64_const_raw(buf, (-4).to_int64())
      emit_i64_and(buf)
      emit_i32_wrap_i64(buf)
      // Load element at index: tuple layout is [type_tag:4][len:4][elem0:4][elem1:4]...
      // So element i is at offset 8 + i * 4
      emit_i32_load(buf, 8 + index * 4)
      emit_i64_extend_i32_s(buf)
    }
    @core.Expr::Record(fields~, span~) => {
      let _ = span
      compile_record_expr(ctx, buf, fields)
    }
    @core.Expr::Array(items~, span~) => {
      let _ = span
      compile_array_expr(ctx, buf, items)
    }
    @core.Expr::Map(fields~, span~) => {
      let _ = span
      compile_map_expr(ctx, buf, fields)
    }
    @core.Expr::If(cond~, then_body~, else_body~, span~) => {
      let _ = span
      let if_kind = if ctx.use_js_strings {
        infer_expr_kind(ctx, expr)
      } else {
        ValueKind::I64
      }
      compile_expr_i32(ctx, buf, cond)
      emit_i64_const_raw(buf, 2L)
      emit_i64_shr_u(buf)
      emit_i32_wrap_i64(buf)
      buf.push((4).to_byte()) // if
      buf.push(valtype_byte(if_kind))
      adjust_loop_offsets(ctx, 1)
      emit_coverage(ctx, buf, WasmCoveragePointKind::BranchIfThen, span)
      compile_block_expr(ctx, buf, then_body)
      buf.push((5).to_byte()) // else
      emit_coverage(ctx, buf, WasmCoveragePointKind::BranchIfElse, span)
      compile_block_expr(ctx, buf, else_body)
      buf.push((11).to_byte()) // end
      adjust_loop_offsets(ctx, -1)
    }
    @core.Expr::Block(body~, span~) => {
      let _ = span
      compile_block_expr(ctx, buf, body)
    }
    @core.Expr::Match(scrutinee~, arms~, span~) => {
      let _ = span
      let saved = ctx.locals.copy()
      let saved_kinds = ctx.local_kinds.copy()
      let scrut_idx = ctx.local_count
      ctx.local_count += 1
      ctx.local_types.push(ValueKind::I64)
      compile_expr_i32(ctx, buf, scrutinee)
      emit_local_set(buf, scrut_idx)
      compile_match_chain(ctx, buf, scrut_idx, arms, 0)
      restore_locals(ctx, saved)
      restore_local_kinds(ctx, saved_kinds)
    }
    @core.Expr::Do(body~, span~) => {
      let _ = span
      compile_block_expr(ctx, buf, body)
    }
    @core.Expr::Try(try_body~, catch_body~, span~) => {
      let _ = span
      let try_kind = if ctx.use_js_strings {
        infer_block_kind(ctx, try_body, ctx.local_kinds)
      } else {
        ValueKind::I64
      }
      // Adjust loop offsets for nesting (+3 label scopes: block, block, try_table)
      adjust_loop_offsets(ctx, 3)
      // (block $outer (result <type>)
      buf.push((2).to_byte()) // block opcode
      buf.push(valtype_byte(try_kind)) // result type
      //   (block $catch_target  ;; catch_all: no result
      buf.push((2).to_byte()) // block opcode
      buf.push((64).to_byte()) // empty type (0x40)
      //     (try_table (result <type>) (catch_all 0)
      buf.push((31).to_byte()) // try_table opcode = 0x1F
      buf.push(valtype_byte(try_kind)) // result type
      write_u32_leb(buf, 1) // catch clause count = 1
      buf.push((2).to_byte()) // catch_all = 0x02
      write_u32_leb(buf, 0) // label depth = 0 ($catch_target)
      //       compile try_body
      compile_block_expr(ctx, buf, try_body)
      //     end try_table
      buf.push((11).to_byte())
      //     br $outer (label depth = 1)
      buf.push((12).to_byte()) // br opcode
      write_u32_leb(buf, 1) // label depth = 1
      //   end $catch_target
      buf.push((11).to_byte())
      //   compile catch_body (at depth +2 from original: outer block + catch_target block)
      adjust_loop_offsets(ctx, -1) // try_table ended, now at +2
      compile_block_expr(ctx, buf, catch_body)
      // end $outer
      buf.push((11).to_byte())
      adjust_loop_offsets(ctx, -2) // both blocks ended, back to original
    }
    @core.Expr::Fn(params~, ret~, effects~, body~, span~, ..) => {
      let _ = params
      let _ = ret
      let _ = effects
      let _ = body
      let key = span_key(span)
      let func_idx = match ctx.fn_closure_indices.get(key) {
        Some(idx) => idx
        None => raise WasmGenError::Unsupported("fn index")
      }
      let captures = match ctx.fn_closure_captures.get(key) {
        Some(list) => list
        None => []
      }
      if captures.length() == 0 {
        let slot = ensure_funcref_slot(ctx, func_idx)
        emit_i64_const_raw(buf, tag_fn_value64(slot.to_int64()))
      } else {
        require_heap(ctx)
        let len = captures.length()
        let size = align4(8 + len * 4)
        let obj_local = alloc_temp_local(ctx)
        emit_heap_alloc(ctx, buf, size, obj_local)
        emit_local_get(buf, obj_local)
        emit_i32_const_raw(buf, obj_fn)
        emit_i32_store(buf, 0)
        emit_local_get(buf, obj_local)
        let slot = ensure_funcref_slot(ctx, func_idx)
        emit_i32_const_raw(buf, slot)
        emit_i32_store(buf, 4)
        let capture_kinds : Array[ValueKind] = []
        for i in 0..<len {
          let name = captures[i]
          let cap_kind = match ctx.local_kinds.get(name) {
            Some(kind) => kind
            None => ValueKind::I32
          }
          capture_kinds.push(cap_kind)
          if ctx.use_js_strings && cap_kind == ValueKind::ExternRef {
            // Store externref in extern table, put slot index in closure env
            ctx.need_extern_table = true
            let slot = ctx.extern_table_next_slot
            ctx.extern_table_next_slot += 1
            // table.set $extern_table slot externref_value
            emit_i32_const_raw(buf, slot)
            match ctx.locals.get(name) {
              Some(idx) => emit_local_get(buf, idx)
              None => raise WasmGenError::UnknownName(name)
            }
            emit_table_set(buf, ctx.extern_table_index)
            // Store slot index in closure env
            emit_local_get(buf, obj_local)
            emit_i32_const_raw(buf, slot)
            emit_i32_store(buf, 8 + i * 4)
          } else {
            emit_local_get(buf, obj_local)
            match ctx.locals.get(name) {
              Some(idx) => {
                emit_local_get(buf, idx)
                // Local is i64 tagged value, wrap to i32 for memory store
                let lkind = match ctx.local_kinds.get(name) {
                  Some(k) => k
                  None => ValueKind::I64
                }
                if lkind == ValueKind::I64 {
                  emit_i32_wrap_i64(buf)
                }
              }
              None =>
                match ctx.fn_indices.get(name) {
                  Some(idx) => {
                    if fn_index_needs_env(ctx, idx) {
                      raise WasmGenError::Unsupported(
                        "closure capture requires env-backed function in scope: " +
                        name,
                      )
                    }
                    let slot = ensure_funcref_slot(ctx, idx)
                    emit_i64_const_raw(buf, tag_fn_value64(slot.to_int64()))
                    emit_i32_wrap_i64(buf)
                  }
                  None => raise WasmGenError::UnknownName(name)
                }
            }
            emit_i32_store(buf, 8 + i * 4)
          }
        }
        ctx.fn_closure_capture_kinds[key] = capture_kinds
        emit_local_get(buf, obj_local)
        emit_i64_extend_i32_u(buf)
        emit_i64_const_raw(buf, tag_obj.to_int64())
        emit_i64_or(buf)
      }
    }
    @core.Expr::While(cond~, body~, span~) => {
      let _ = span
      // Save loop offsets for nesting
      let saved_break = ctx.loop_break_offset
      let saved_continue = ctx.loop_continue_offset
      let saved_param_locals = ctx.loop_param_locals

      emit_block(buf) // block $exit (label 1)
      emit_loop(buf) // loop $continue (label 0)

      // Set offsets: from inside loop body, break=1 (outer block), continue=0 (inner loop)
      ctx.loop_break_offset = 1
      ctx.loop_continue_offset = 0
      ctx.loop_param_locals = []

      // Evaluate condition
      compile_expr_i32(ctx, buf, cond)
      // Extract bool value: (tagged >> 2) & 1
      emit_i64_const_raw(buf, 2L)
      emit_i64_shr_u(buf)
      emit_i32_wrap_i64(buf)
      emit_i32_const_raw(buf, 1)
      emit_i32_and(buf)
      // If condition is 0, exit loop
      emit_i32_eqz(buf)
      emit_br_if(buf, 1) // br_if $exit (label 1 = outer block)

      // Execute body
      for i in 0..<body.stmts.length() {
        compile_stmt(ctx, buf, body.stmts[i], false)
      }

      // Loop back to continue
      emit_br(buf, 0) // br $continue (label 0 = inner loop)
      emit_end(buf) // end loop
      emit_end(buf) // end block

      // Restore loop offsets
      ctx.loop_break_offset = saved_break
      ctx.loop_continue_offset = saved_continue
      ctx.loop_param_locals = saved_param_locals

      // While expression returns unit
      emit_i64_const_tagged(buf, 0L)
    }
    @core.Expr::Break(value~, span~) => {
      let _ = span
      if ctx.loop_break_offset < 0 {
        raise WasmGenError::Unsupported("break outside loop")
      }
      match value {
        Some(expr) => compile_expr(ctx, buf, expr)
        None => emit_i64_const_tagged(buf, 0L)
      }
      emit_br(buf, ctx.loop_break_offset)
      emit_unreachable(buf)
    }
    @core.Expr::Continue(args~, span~) => {
      let _ = span
      if ctx.loop_continue_offset < 0 {
        raise WasmGenError::Unsupported("continue outside loop")
      }
      // For parameterized loop: set args to temp locals, then copy to param locals
      if args.length() > 0 {
        let param_locals = ctx.loop_param_locals
        if args.length() != param_locals.length() {
          raise WasmGenError::Unsupported("continue arity mismatch")
        }
        // Compile all args to temp locals first (avoid mutual overwrite)
        let temps : Array[Int] = []
        for arg in args {
          let tmp = ctx.local_count
          ctx.local_count += 1
          ctx.local_types.push(ValueKind::I64)
          compile_expr(ctx, buf, arg)
          emit_local_set(buf, tmp)
          temps.push(tmp)
        }
        // Copy temps to param locals
        for i in 0..<temps.length() {
          emit_local_get(buf, temps[i])
          emit_local_set(buf, param_locals[i])
        }
      }
      emit_br(buf, ctx.loop_continue_offset)
      emit_unreachable(buf)
    }
    @core.Expr::Loop(params~, body~, span~) => {
      let _ = span
      // Save loop offsets for nesting
      let saved_break = ctx.loop_break_offset
      let saved_continue = ctx.loop_continue_offset
      let saved_param_locals = ctx.loop_param_locals
      let saved_locals = ctx.locals.copy()
      let saved_kinds = ctx.local_kinds.copy()

      // Allocate locals for loop params and compile init expressions
      let param_locals : Array[Int] = []
      for param in params {
        let idx = ctx.local_count
        ctx.local_count += 1
        ctx.local_types.push(ValueKind::I64)
        compile_expr(ctx, buf, param.init)
        emit_local_set(buf, idx)
        ctx.locals[param.name] = idx
        ctx.local_kinds[param.name] = ValueKind::I32
        param_locals.push(idx)
      }
      ctx.loop_param_locals = param_locals

      // block $exit (result i64)  -- break value lands here
      //   loop $continue          -- continue jumps here
      //     <body>
      //   end
      // end
      emit_block_i64(buf) // block $exit (result i64)
      emit_loop(buf) // loop $continue

      // Set offsets: break=1 (outer block), continue=0 (inner loop)
      ctx.loop_break_offset = 1
      ctx.loop_continue_offset = 0

      // Compile body
      let len = body.stmts.length()
      if len == 0 {
        emit_i64_const_tagged(buf, 0L)
      } else {
        for i in 0..<len {
          let is_last = i == len - 1
          compile_stmt(ctx, buf, body.stmts[i], is_last)
        }
      }

      emit_end(buf) // end loop
      emit_end(buf) // end block

      // Restore
      ctx.loop_break_offset = saved_break
      ctx.loop_continue_offset = saved_continue
      ctx.loop_param_locals = saved_param_locals
      restore_locals(ctx, saved_locals)
      restore_local_kinds(ctx, saved_kinds)
    }
    @core.Expr::Raise(value~, span~) => {
      let _ = span
      if not(ctx.use_js_strings) && not(ctx.embed_error_strings) {
        match value {
          @core.Expr::String(value=message, span~) => {
            let _ = span
            emit_i64_const_tagged(
              buf,
              intern_error_code(ctx, message).to_int64(),
            )
          }
          _ => compile_expr_i32(ctx, buf, value)
        }
      } else if ctx.use_js_strings {
        compile_expr(ctx, buf, value) // externref string on stack
      } else {
        compile_expr_i32(ctx, buf, value) // tagged i32 string on stack
      }
      buf.push((8).to_byte()) // throw opcode = 0x08
      write_u32_leb(buf, ctx.error_tag_index) // tag index
    }
    @core.Expr::Await(expr~, span~) => {
      let _ = span
      // Compile the expression to get the value to yield
      compile_expr_i32(ctx, buf, expr)
      // Emit suspend instruction with await tag
      // suspend opcode = 0xe2, tag_index
      buf.push((0xe2).to_byte())
      write_u32_leb(buf, ctx.await_tag_index)
      // After resume, read resolved value from async_result global
      // global.get opcode = 0x23
      buf.push((0x23).to_byte())
      write_u32_leb(buf, ctx.async_result_global_index)
    }
    @core.Expr::Yield(expr~, span~) => {
      let _ = span
      // Compile the expression to get the value to yield
      compile_expr_i32(ctx, buf, expr)
      // Emit suspend instruction with await tag (yield uses same tag)
      buf.push((0xe2).to_byte())
      write_u32_leb(buf, ctx.await_tag_index)
      // Yield returns Unit - the suspend result is dropped and we return 0
      buf.push((26).to_byte()) // drop the suspend result
      emit_i64_const_raw(buf, tag_int_value64(0L))
    }
    @core.Expr::StructLit(fields~, span~, ..) => {
      let _ = span
      // StructLit is compiled as record - same memory layout
      compile_record_expr(ctx, buf, fields)
    }
  }
}

///|
fn extract_positional_exprs(
  args : Array[@core.CallArg],
  name : String,
) -> Array[@core.Expr] raise WasmGenError {
  let out : Array[@core.Expr] = []
  for arg in args {
    match arg.label {
      Some(_) => raise WasmGenError::Unsupported("labeled arg: " + name)
      None => out.push(arg.expr)
    }
  }
  out
}

///|
fn resolve_args_with_labels(
  ctx : CodegenCtx,
  args : Array[@core.CallArg],
  func_name : String,
) -> Array[@core.Expr] raise WasmGenError {
  // Check if any labeled args exist
  let mut has_labeled = false
  for arg in args {
    if arg.label is Some(_) {
      has_labeled = true
      break
    }
  }
  // If no labeled args, just return positional
  if not(has_labeled) {
    let out : Array[@core.Expr] = []
    for arg in args {
      out.push(arg.expr)
    }
    return out
  }
  // Get parameter names for this function
  match ctx.fn_param_names.get(func_name) {
    None =>
      raise WasmGenError::Unsupported("labeled arg unknown fn: " + func_name)
    Some(param_names) => {
      // Initialize result array
      let result : Array[@core.Expr?] = Array::make(param_names.length(), None)
      let mut pos_idx = 0
      for arg in args {
        match arg.label {
          Some(label) => {
            // Find parameter position by name
            let mut found = -1
            for i, pname in param_names {
              if pname == label {
                found = i
                break
              }
            }
            if found < 0 {
              raise WasmGenError::Unsupported("unknown label: " + label)
            }
            if result[found] is Some(_) {
              raise WasmGenError::Unsupported("duplicate label: " + label)
            }
            result[found] = Some(arg.expr)
          }
          None => {
            // Find next available positional slot
            while pos_idx < result.length() && result[pos_idx] is Some(_) {
              pos_idx += 1
            }
            if pos_idx >= result.length() {
              raise WasmGenError::Unsupported("too many positional args")
            }
            result[pos_idx] = Some(arg.expr)
            pos_idx += 1
          }
        }
      }
      // Check all slots are filled and extract exprs
      let out : Array[@core.Expr] = []
      for i, opt in result {
        match opt {
          Some(e) => out.push(e)
          None =>
            raise WasmGenError::Unsupported("missing arg: " + param_names[i])
        }
      }
      out
    }
  }
}

///|
fn compile_stmt(
  ctx : CodegenCtx,
  buf : ByteBuf,
  stmt : @core.Stmt,
  is_last : Bool,
) -> Unit raise WasmGenError {
  emit_coverage(ctx, buf, WasmCoveragePointKind::Line, stmt.span())
  match stmt {
    @core.Stmt::Let(rec~, name~, expr~, span~) => {
      let _ = span
      match expr {
        @core.Expr::Fn(
          params=fn_params,
          ret=fn_ret,
          effects~,
          body=fn_body,
          span=fn_span,
          ..
        ) => {
          let _ = effects
          let key = span_key(fn_span)
          let func_idx = match ctx.fn_closure_indices.get(key) {
            Some(i) => i
            None => -1
          }
          let kinds = param_kinds(ctx, fn_params)
          let ret_kind = match fn_ret {
            Some(r) => value_kind_from_type(ctx, r)
            None => ValueKind::I32
          }
          ctx.fn_local_sigs[name] = func_sig_with_env(kinds, ret_kind)
          if func_idx >= 0 {
            // Register as callable function (direct call)
            ctx.fn_indices[name] = func_idx
            ctx.fn_params[name] = kinds
            // Save parameter names for labeled args resolution
            let names : Array[String] = []
            for p in fn_params {
              names.push(p.name)
            }
            ctx.fn_param_names[name] = names
            ctx.fn_returns[name] = ret_kind
            // Infer return signature if function returns a function type
            match fn_ret {
              Some(r) =>
                match func_sig_from_type(ctx, r) {
                  Some(sig) => ctx.fn_return_sigs[name] = sig
                  None => ()
                }
              None =>
                // Try to infer from body's last expression
                match infer_body_return_sig(ctx, fn_body) {
                  Some(sig) => ctx.fn_return_sigs[name] = sig
                  None => ()
                }
            }
          }
          let kind = infer_expr_kind(ctx, expr)
          let idx = ctx.local_count
          ctx.local_count += 1
          ctx.local_types.push(kind)
          ctx.locals[name] = idx
          ctx.local_kinds[name] = kind
          compile_expr(ctx, buf, expr)
          if is_last {
            emit_local_tee(buf, idx)
          } else {
            emit_local_set(buf, idx)
          }
          // Back-patch self-reference for recursive closures
          if rec {
            let captures = match ctx.fn_closure_captures.get(key) {
              Some(list) => list
              None => []
            }
            for i in 0..<captures.length() {
              if captures[i] == name {
                // Found self-reference capture at slot i
                // Load env pointer (untag obj ptr), write closure value to slot
                let env_local = alloc_temp_local(ctx)
                emit_local_get(buf, idx)
                emit_i64_const_raw(buf, (-4).to_int64())
                emit_i64_and(buf)
                emit_i32_wrap_i64(buf) // untag obj pointer to i32
                emit_local_set(buf, env_local)
                emit_local_get(buf, env_local)
                emit_local_get(buf, idx) // closure value (i64)
                emit_i32_wrap_i64(buf) // truncate to i32 for memory store
                emit_i32_store(buf, 8 + i * 4) // write to capture slot
                break
              }
            }
          }
        }
        _ => {
          let kind = infer_expr_kind(ctx, expr)
          let idx = ctx.local_count
          ctx.local_count += 1
          ctx.local_types.push(kind)
          ctx.locals[name] = idx
          ctx.local_kinds[name] = kind
          // If the expression is a Call that returns a function, register in fn_local_sigs
          match expr {
            @core.Expr::Ident(name=source_name, span~) => {
              let _ = span
              match ctx.fn_local_sigs.get(source_name) {
                Some(sig) => ctx.fn_local_sigs[name] = sig
                None => ()
              }
              match ctx.fn_indices.get(source_name) {
                Some(func_idx) => {
                  ctx.fn_indices[name] = func_idx
                  match ctx.fn_params.get(source_name) {
                    Some(kinds) => ctx.fn_params[name] = kinds
                    None => ()
                  }
                  match ctx.fn_param_names.get(source_name) {
                    Some(names) => ctx.fn_param_names[name] = names
                    None => ()
                  }
                  match ctx.fn_returns.get(source_name) {
                    Some(ret_kind) => ctx.fn_returns[name] = ret_kind
                    None => ()
                  }
                  match ctx.fn_return_sigs.get(source_name) {
                    Some(sig) => ctx.fn_return_sigs[name] = sig
                    None => ()
                  }
                }
                None => ()
              }
            }
            @core.Expr::Call(name=call_name, args~, span~, ..) => {
              let _ = args
              let _ = span
              match ctx.fn_return_sigs.get(call_name) {
                Some(sig) => ctx.fn_local_sigs[name] = sig
                None => ()
              }
            }
            _ => ()
          }
          compile_expr(ctx, buf, expr)
          if is_last {
            emit_local_tee(buf, idx)
          } else {
            emit_local_set(buf, idx)
          }
        }
      }
    }
    @core.Stmt::EnumDef(name~, params~, ctors~, span~) => {
      let _ = name
      let _ = params
      let _ = span
      for i in 0..<ctors.length() {
        let ctor = ctors[i]
        ctx.enum_ctor_tags[ctor.name] = i
        ctx.enum_ctor_arities[ctor.name] = ctor.args.length()
        if not(ctx.enum_ctor_arg_kinds.contains(ctor.name)) {
          let arg_kinds : Array[ValueKind] = []
          for arg in ctor.args {
            arg_kinds.push(value_kind_from_type(ctx, arg))
          }
          ctx.enum_ctor_arg_kinds[ctor.name] = arg_kinds
        }
      }
      if is_last {
        emit_i64_const_tagged(buf, 0L)
      }
    }
    @core.Stmt::TypeAlias(name~, params~, target~, span~) => {
      let _ = name
      let _ = params
      let _ = target
      let _ = span
      if is_last {
        emit_i64_const_tagged(buf, 0L)
      }
    }
    @core.Stmt::Expr(expr~, span~) => {
      let _ = span
      compile_expr(ctx, buf, expr)
      if not(is_last) {
        emit_drop(buf)
      }
    }
    @core.Stmt::Test(name~, body~, span~) => {
      let _ = name
      let _ = body
      let _ = span
      if is_last {
        emit_i64_const_tagged(buf, 0L)
      }
    }
    @core.Stmt::Bench(name~, body~, span~) => {
      let _ = name
      let _ = body
      let _ = span
      if is_last {
        emit_i64_const_tagged(buf, 0L)
      }
    }
    @core.Stmt::Import(spec~, source~, span~) => {
      let _ = spec
      let _ = source
      let _ = span
      raise WasmGenError::Unsupported("import")
    }
    @core.Stmt::ExportLet(rec~, name~, expr~, span~) =>
      // ExportLet is compiled like Let - the export is handled at module level
      compile_stmt(
        ctx,
        buf,
        @core.Stmt::Let(rec~, name~, expr~, span~),
        is_last,
      )
    @core.Stmt::ExportEnumDef(name~, params~, ctors~, span~) =>
      // ExportEnumDef is compiled like EnumDef for constructor metadata.
      compile_stmt(
        ctx,
        buf,
        @core.Stmt::EnumDef(name~, params~, ctors~, span~),
        is_last,
      )
    @core.Stmt::ExportTypeAlias(..) =>
      // Type exports have no runtime representation in WASM
      // If this is the last statement, push unit
      if is_last {
        emit_i64_const_tagged(buf, 0L)
      }
    @core.Stmt::Export(..)
    | @core.Stmt::ReExport(..)
    | @core.Stmt::TraitDef(..)
    | @core.Stmt::TraitImpl(..)
    | @core.Stmt::StructDef(..)
    | @core.Stmt::ExportStructDef(..) =>
      // export { ... } statements and struct definitions are handled during bundling/typechecking
      // At codegen time, they are no-ops
      if is_last {
        emit_i64_const_tagged(buf, 0L)
      }
    @core.Stmt::LetMut(name~, expr~, span~) => {
      let _ = span
      // LetMut is similar to Let, but the variable can be reassigned
      let kind = infer_expr_kind(ctx, expr)
      let idx = ctx.local_count
      ctx.local_count += 1
      ctx.local_types.push(kind)
      ctx.locals[name] = idx
      ctx.local_kinds[name] = kind
      compile_expr(ctx, buf, expr)
      if is_last {
        emit_local_tee(buf, idx)
      } else {
        emit_local_set(buf, idx)
      }
    }
    @core.Stmt::Assign(name~, expr~, span~) => {
      let _ = span
      // Assign updates an existing mutable variable
      match ctx.locals.get(name) {
        Some(idx) => {
          compile_expr(ctx, buf, expr)
          if is_last {
            emit_local_tee(buf, idx)
          } else {
            emit_local_set(buf, idx)
          }
        }
        None => raise UnknownName(name)
      }
    }
    @core.Stmt::IndexAssign(target~, index~, value~, span~) => {
      // IndexAssign: target[index] = value → __set_index(target, index, value)
      // Desugar to call expression
      let call_expr = @core.Expr::Call(
        name="__set_index",
        type_args=[],
        args=[
          @core.CallArg::{ label: None, expr: target, span: target.span() },
          @core.CallArg::{ label: None, expr: index, span: index.span() },
          @core.CallArg::{ label: None, expr: value, span: value.span() },
        ],
        span~,
      )
      compile_expr(ctx, buf, call_expr)
      if not(is_last) {
        emit_drop(buf)
      }
    }
    @core.Stmt::LetPat(pat~, expr~, span~) => {
      let _ = span
      match pat {
        @core.Pat::Tuple(items~, span=pat_span) => {
          let _ = pat_span
          compile_expr_i32(ctx, buf, expr) // tuple pointer (tagged i64)
          let tuple_local = alloc_temp_local_with_kind(ctx, ValueKind::I64)
          emit_local_set(buf, tuple_local)
          let len = items.length()
          for i in 0..<len {
            match items[i] {
              @core.Pat::Bind(name~, span=bind_span) => {
                let _ = bind_span
                let local_idx = ctx.local_count
                ctx.local_count += 1
                ctx.local_types.push(ValueKind::I64)
                ctx.locals[name] = local_idx
                ctx.local_kinds[name] = ValueKind::I64
                emit_load_tuple_elem(buf, tuple_local, i)
                if is_last && i == len - 1 {
                  emit_local_tee(buf, local_idx)
                } else {
                  emit_local_set(buf, local_idx)
                }
              }
              @core.Pat::Wildcard(..) =>
                if is_last && i == len - 1 {
                  emit_load_tuple_elem(buf, tuple_local, i)
                }
              _ => {
                // Nested pattern - load element and recursively destructure
                let elem_local = alloc_temp_local_with_kind(ctx, ValueKind::I64)
                emit_load_tuple_elem(buf, tuple_local, i)
                emit_local_set(buf, elem_local)
                compile_let_pat_nested(ctx, buf, items[i], elem_local)
              }
            }
          }
          if is_last && len == 0 {
            emit_i64_const_tagged(buf, 0L)
          }
        }
        @core.Pat::Record(fields~, span=pat_span) => {
          let _ = pat_span
          compile_expr_i32(ctx, buf, expr) // record pointer (tagged i64)
          let record_local = alloc_temp_local_with_kind(ctx, ValueKind::I64)
          emit_local_set(buf, record_local)
          let sorted = sort_record_fields_pat(fields)
          let len = sorted.length()
          for i, field in sorted {
            match field.pat {
              @core.Pat::Bind(name~, span=bind_span) => {
                let _ = bind_span
                let local_idx = ctx.local_count
                ctx.local_count += 1
                ctx.local_types.push(ValueKind::I64)
                ctx.locals[name] = local_idx
                ctx.local_kinds[name] = ValueKind::I64
                // Record value is at offset 8 + i * 8 + 4 (key-value pairs)
                emit_load_record_value(buf, record_local, i)
                if is_last && i == len - 1 {
                  emit_local_tee(buf, local_idx)
                } else {
                  emit_local_set(buf, local_idx)
                }
              }
              @core.Pat::Wildcard(..) =>
                if is_last && i == len - 1 {
                  emit_load_record_value(buf, record_local, i)
                }
              _ => {
                // Nested pattern - load element and recursively destructure
                let elem_local = alloc_temp_local_with_kind(ctx, ValueKind::I64)
                emit_load_record_value(buf, record_local, i)
                emit_local_set(buf, elem_local)
                compile_let_pat_nested(ctx, buf, field.pat, elem_local)
              }
            }
          }
          if is_last && len == 0 {
            emit_i64_const_tagged(buf, 0L)
          }
        }
        @core.Pat::Ctor(name~, args~, span=pat_span) => {
          let _ = name
          let _ = pat_span
          compile_expr_i32(ctx, buf, expr) // enum pointer (tagged i64)
          let ctor_local = alloc_temp_local_with_kind(ctx, ValueKind::I64)
          emit_local_set(buf, ctor_local)
          let len = args.length()
          for i, arg_pat in args {
            match arg_pat {
              @core.Pat::Bind(name~, span=bind_span) => {
                let _ = bind_span
                let local_idx = ctx.local_count
                ctx.local_count += 1
                ctx.local_types.push(ValueKind::I64)
                ctx.locals[name] = local_idx
                ctx.local_kinds[name] = ValueKind::I64
                // Load from enum payload: offset 8 + i * 4
                emit_untag_ptr(buf, ctor_local)
                emit_i32_load(buf, 8 + i * 4)
                emit_i64_extend_i32_s(buf)
                if is_last && i == len - 1 {
                  emit_local_tee(buf, local_idx)
                } else {
                  emit_local_set(buf, local_idx)
                }
              }
              @core.Pat::Wildcard(..) =>
                if is_last && i == len - 1 {
                  emit_untag_ptr(buf, ctor_local)
                  emit_i32_load(buf, 8 + i * 4)
                  emit_i64_extend_i32_s(buf)
                }
              _ => {
                // Nested pattern
                let elem_local = alloc_temp_local_with_kind(ctx, ValueKind::I64)
                emit_untag_ptr(buf, ctor_local)
                emit_i32_load(buf, 8 + i * 4)
                emit_i64_extend_i32_s(buf)
                emit_local_set(buf, elem_local)
                compile_let_pat_nested(ctx, buf, arg_pat, elem_local)
              }
            }
          }
          if is_last && len == 0 {
            emit_i64_const_tagged(buf, 0L)
          }
        }
        _ => raise WasmGenError::Unsupported("let pat: non-tuple/record/ctor")
      }
    }
    @core.Stmt::LetPatElse(pat~, expr~, else_body~, span~) => {
      // Desugar to match: match expr { pat => unit, _ => else_body }
      let scrut_idx = ctx.local_count
      ctx.local_count += 1
      ctx.local_types.push(ValueKind::I64)
      compile_expr_i32(ctx, buf, expr)
      emit_local_set(buf, scrut_idx)
      // Build 2-arm match: success (bind + unit) and fallback (else_body)
      let success_arm = @core.MatchArm::{
        pat,
        cond: None,
        expr: @core.Expr::Tuple(items=[], span~),
        span,
      }
      let fallback_arm = @core.MatchArm::{
        pat: @core.Pat::Wildcard(span~),
        cond: None,
        expr: @core.Expr::Block(body=else_body, span~),
        span,
      }
      let arms = [success_arm, fallback_arm]
      compile_match_chain(ctx, buf, scrut_idx, arms, 0)
      // Drop the result if not last
      if not(is_last) {
        emit_drop(buf)
      }
    }
  }
}

///|
/// Recursively compile a let pattern element.
/// value_local contains the tagged i64 value to destructure.
fn compile_let_pat_nested(
  ctx : CodegenCtx,
  buf : ByteBuf,
  pat : @core.Pat,
  value_local : Int,
) -> Unit raise WasmGenError {
  match pat {
    @core.Pat::Bind(name~, span~) => {
      let _ = span
      let local_idx = ctx.local_count
      ctx.local_count += 1
      ctx.local_types.push(ValueKind::I64)
      ctx.locals[name] = local_idx
      ctx.local_kinds[name] = ValueKind::I64
      emit_local_get(buf, value_local)
      emit_local_set(buf, local_idx)
    }
    @core.Pat::Wildcard(..) => ()
    @core.Pat::Tuple(items~, span~) => {
      let _ = span
      // value_local contains tuple pointer (i64 tagged)
      for i, item in items {
        let elem_local = alloc_temp_local_with_kind(ctx, ValueKind::I64)
        emit_load_tuple_elem(buf, value_local, i)
        emit_local_set(buf, elem_local)
        compile_let_pat_nested(ctx, buf, item, elem_local)
      }
    }
    @core.Pat::Record(fields~, span~) => {
      let _ = span
      let sorted = sort_record_fields_pat(fields)
      for i, field in sorted {
        let elem_local = alloc_temp_local_with_kind(ctx, ValueKind::I64)
        emit_load_tuple_elem(buf, value_local, i)
        emit_local_set(buf, elem_local)
        compile_let_pat_nested(ctx, buf, field.pat, elem_local)
      }
    }
    @core.Pat::Ctor(name~, args~, span~) => {
      let _ = name
      let _ = span
      // Ctor payload starts at offset 8 (after obj_type and tag)
      // Each arg is at offset 8 + i * 4
      for i, arg_pat in args {
        let elem_local = alloc_temp_local_with_kind(ctx, ValueKind::I64)
        // Load from enum payload: untag ptr, load at offset 8 + i * 4
        emit_untag_ptr(buf, value_local)
        emit_i32_load(buf, 8 + i * 4)
        emit_i64_extend_i32_s(buf)
        emit_local_set(buf, elem_local)
        compile_let_pat_nested(ctx, buf, arg_pat, elem_local)
      }
    }
    _ => raise WasmGenError::Unsupported("let pat nested: unsupported pattern")
  }
}

///|
fn compile_block_expr(
  ctx : CodegenCtx,
  buf : ByteBuf,
  body : @core.Module,
) -> Unit raise WasmGenError {
  let saved = ctx.locals.copy()
  let saved_kinds = ctx.local_kinds.copy()
  let len = body.stmts.length()
  if len == 0 {
    emit_i64_const_tagged(buf, 0L)
  } else {
    for i in 0..<len {
      let is_last = i == len - 1
      compile_stmt(ctx, buf, body.stmts[i], is_last)
    }
  }
  restore_locals(ctx, saved)
  restore_local_kinds(ctx, saved_kinds)
}

///|
fn require_heap(ctx : CodegenCtx) -> Unit raise WasmGenError {
  if ctx.heap_local < 0 {
    raise WasmGenError::Unsupported("heap not initialized")
  }
}

///|
fn emit_heap_reserve(
  ctx : CodegenCtx,
  buf : ByteBuf,
  size : Int,
) -> Unit raise WasmGenError {
  require_heap(ctx)
  if size <= 0 {
    return
  }
  let new_heap_local = alloc_temp_local(ctx)
  let current_pages_local = alloc_temp_local(ctx)
  let required_pages_local = alloc_temp_local(ctx)
  emit_local_get(buf, ctx.heap_local)
  emit_i32_const_raw(buf, size)
  emit_i32_add(buf)
  emit_local_set(buf, new_heap_local)
  emit_memory_size(buf)
  emit_local_set(buf, current_pages_local)
  emit_local_get(buf, new_heap_local)
  emit_i32_const_raw(buf, 65535)
  emit_i32_add(buf)
  emit_i32_const_raw(buf, 16)
  emit_i32_shr_u(buf)
  emit_local_set(buf, required_pages_local)
  emit_local_get(buf, current_pages_local)
  emit_local_get(buf, required_pages_local)
  emit_i32_lt_s(buf)
  buf.push((4).to_byte()) // if
  buf.push((64).to_byte()) // empty
  emit_local_get(buf, required_pages_local)
  emit_local_get(buf, current_pages_local)
  emit_i32_sub(buf)
  emit_memory_grow(buf)
  emit_drop(buf)
  buf.push((11).to_byte()) // end
}

///|
fn emit_heap_alloc(
  ctx : CodegenCtx,
  buf : ByteBuf,
  size : Int,
  obj_local : Int,
) -> Unit raise WasmGenError {
  emit_heap_reserve(ctx, buf, size)
  emit_local_get(buf, ctx.heap_local)
  emit_local_set(buf, obj_local)
  emit_local_get(buf, ctx.heap_local)
  emit_i32_const_raw(buf, size)
  emit_i32_add(buf)
  emit_local_set(buf, ctx.heap_local)
}

///|
fn emit_heap_reserve_local(
  ctx : CodegenCtx,
  buf : ByteBuf,
  size_local : Int,
) -> Unit raise WasmGenError {
  require_heap(ctx)
  let new_heap_local = alloc_temp_local(ctx)
  let current_pages_local = alloc_temp_local(ctx)
  let required_pages_local = alloc_temp_local(ctx)
  emit_local_get(buf, ctx.heap_local)
  emit_local_get(buf, size_local)
  emit_i32_add(buf)
  emit_local_set(buf, new_heap_local)
  emit_memory_size(buf)
  emit_local_set(buf, current_pages_local)
  emit_local_get(buf, new_heap_local)
  emit_i32_const_raw(buf, 65535)
  emit_i32_add(buf)
  emit_i32_const_raw(buf, 16)
  emit_i32_shr_u(buf)
  emit_local_set(buf, required_pages_local)
  emit_local_get(buf, current_pages_local)
  emit_local_get(buf, required_pages_local)
  emit_i32_lt_s(buf)
  buf.push((4).to_byte()) // if
  buf.push((64).to_byte()) // empty
  emit_local_get(buf, required_pages_local)
  emit_local_get(buf, current_pages_local)
  emit_i32_sub(buf)
  emit_memory_grow(buf)
  emit_drop(buf)
  buf.push((11).to_byte()) // end
}

///|
fn emit_heap_alloc_local(
  ctx : CodegenCtx,
  buf : ByteBuf,
  size_local : Int,
  obj_local : Int,
) -> Unit raise WasmGenError {
  emit_heap_reserve_local(ctx, buf, size_local)
  emit_local_get(buf, ctx.heap_local)
  emit_local_set(buf, obj_local)
  emit_local_get(buf, ctx.heap_local)
  emit_local_get(buf, size_local)
  emit_i32_add(buf)
  emit_local_set(buf, ctx.heap_local)
}

///|
fn compile_tuple_expr(
  ctx : CodegenCtx,
  buf : ByteBuf,
  items : Array[@core.Expr],
) -> Unit raise WasmGenError {
  require_heap(ctx)
  let len = items.length()
  let size = align4(8 + len * 4)
  let obj_local = alloc_temp_local(ctx)
  emit_heap_alloc(ctx, buf, size, obj_local)
  emit_local_get(buf, obj_local)
  emit_i32_const_raw(buf, obj_tuple)
  emit_i32_store(buf, 0)
  emit_local_get(buf, obj_local)
  emit_i32_const_raw(buf, len)
  emit_i32_store(buf, 4)
  for i in 0..<len {
    let item_kind = if ctx.use_js_strings {
      infer_expr_kind(ctx, items[i])
    } else {
      ValueKind::I32
    }
    if ctx.use_js_strings && item_kind == ValueKind::ExternRef {
      // Store externref in extern table, put slot index in tuple
      ctx.need_extern_table = true
      let slot = ctx.extern_table_next_slot
      ctx.extern_table_next_slot += 1
      emit_i32_const_raw(buf, slot)
      compile_expr(ctx, buf, items[i])
      emit_table_set(buf, ctx.extern_table_index)
      emit_local_get(buf, obj_local)
      emit_i32_const_raw(buf, slot)
      emit_i32_store(buf, 8 + i * 4)
    } else {
      emit_local_get(buf, obj_local)
      compile_expr_i32(ctx, buf, items[i])
      emit_i32_wrap_i64(buf)
      emit_i32_store(buf, 8 + i * 4)
    }
  }
  emit_local_get(buf, obj_local)
  emit_i64_extend_i32_u(buf)
  emit_i64_const_raw(buf, tag_obj.to_int64())
  emit_i64_or(buf)
}

///|
fn compile_record_expr(
  ctx : CodegenCtx,
  buf : ByteBuf,
  fields : Array[@core.RecordFieldExpr],
) -> Unit raise WasmGenError {
  require_heap(ctx)
  let ordered = sort_record_fields_expr(fields)
  let len = ordered.length()
  let size = align4(8 + len * 8)
  let obj_local = alloc_temp_local(ctx)
  emit_heap_alloc(ctx, buf, size, obj_local)
  emit_local_get(buf, obj_local)
  emit_i32_const_raw(buf, obj_record)
  emit_i32_store(buf, 0)
  emit_local_get(buf, obj_local)
  emit_i32_const_raw(buf, len)
  emit_i32_store(buf, 4)
  for i in 0..<len {
    let field = ordered[i]
    let name_ptr = ctx.strings.intern(field.name)
    emit_local_get(buf, obj_local)
    emit_i32_const_raw(buf, name_ptr)
    emit_i32_store(buf, 8 + i * 8)
    emit_local_get(buf, obj_local)
    compile_expr_i32(ctx, buf, field.expr)
    emit_i32_wrap_i64(buf)
    emit_i32_store(buf, 8 + i * 8 + 4)
  }
  emit_local_get(buf, obj_local)
  emit_i64_extend_i32_u(buf)
  emit_i64_const_raw(buf, tag_obj.to_int64())
  emit_i64_or(buf)
}

///|
fn compile_array_expr(
  ctx : CodegenCtx,
  buf : ByteBuf,
  items : Array[@core.Expr],
) -> Unit raise WasmGenError {
  require_heap(ctx)
  let len = items.length()
  let size = align4(8 + len * 4)
  let obj_local = alloc_temp_local(ctx)
  emit_heap_alloc(ctx, buf, size, obj_local)
  emit_local_get(buf, obj_local)
  emit_i32_const_raw(buf, obj_array)
  emit_i32_store(buf, 0)
  emit_local_get(buf, obj_local)
  emit_i32_const_raw(buf, len)
  emit_i32_store(buf, 4)
  for i in 0..<len {
    emit_local_get(buf, obj_local)
    compile_expr_i32(ctx, buf, items[i])
    emit_i32_wrap_i64(buf)
    emit_i32_store(buf, 8 + i * 4)
  }
  emit_local_get(buf, obj_local)
  emit_i64_extend_i32_u(buf)
  emit_i64_const_raw(buf, tag_obj.to_int64())
  emit_i64_or(buf)
}

///|
fn compile_map_expr(
  ctx : CodegenCtx,
  buf : ByteBuf,
  fields : Array[@core.MapFieldExpr],
) -> Unit raise WasmGenError {
  require_heap(ctx)
  let len = fields.length()
  let size = align4(8 + len * 8)
  let obj_local = alloc_temp_local(ctx)
  emit_heap_alloc(ctx, buf, size, obj_local)
  emit_local_get(buf, obj_local)
  emit_i32_const_raw(buf, obj_map)
  emit_i32_store(buf, 0)
  emit_local_get(buf, obj_local)
  emit_i32_const_raw(buf, len)
  emit_i32_store(buf, 4)
  for i in 0..<len {
    let field = fields[i]
    let key_ptr = ctx.strings.intern(field.key)
    emit_local_get(buf, obj_local)
    emit_i32_const_raw(buf, key_ptr)
    emit_i32_store(buf, 8 + i * 8)
    emit_local_get(buf, obj_local)
    compile_expr_i32(ctx, buf, field.expr)
    emit_i32_wrap_i64(buf)
    emit_i32_store(buf, 8 + i * 8 + 4)
  }
  emit_local_get(buf, obj_local)
  emit_i64_extend_i32_u(buf)
  emit_i64_const_raw(buf, tag_obj.to_int64())
  emit_i64_or(buf)
}

///|
fn sort_record_fields_expr(
  fields : Array[@core.RecordFieldExpr],
) -> Array[@core.RecordFieldExpr] {
  let out : Array[@core.RecordFieldExpr] = []
  for field in fields {
    out.push(field)
    let mut i = out.length() - 1
    while i > 0 && out[i].name < out[i - 1].name {
      let tmp = out[i - 1]
      out[i - 1] = out[i]
      out[i] = tmp
      i -= 1
    }
  }
  out
}

///|
fn sort_record_fields_pat(
  fields : Array[@core.RecordFieldPat],
) -> Array[@core.RecordFieldPat] {
  let out : Array[@core.RecordFieldPat] = []
  for field in fields {
    out.push(field)
    let mut i = out.length() - 1
    while i > 0 && out[i].name < out[i - 1].name {
      let tmp = out[i - 1]
      out[i - 1] = out[i]
      out[i] = tmp
      i -= 1
    }
  }
  out
}

///|
fn compile_func_body(
  ctx : CodegenCtx,
  ast : @core.Module,
  result_kind : ValueKind,
  need_heap : Bool,
  prelude : Array[Byte],
) -> Array[Byte] raise WasmGenError {
  let instr = ByteBuf::new()
  if ctx.use_js_strings && result_kind != ValueKind::I32 {
    let inferred = infer_block_kind(ctx, ast, ctx.local_kinds)
    if inferred != result_kind {
      raise WasmGenError::BackendLimit(backend="wasm-js-string", feature="return kind mismatch")
    }
  }
  ctx.need_heap = need_heap
  if ctx.need_heap {
    ctx.heap_local = ctx.local_count
    ctx.local_count += 1
    ctx.local_types.push(ValueKind::I32)
  }
  compile_block_expr(ctx, instr, ast)
  if ctx.need_heap && ctx.use_heap_global {
    emit_local_get(instr, ctx.heap_local)
    emit_global_set(instr, ctx.heap_global)
  }
  instr.push((11).to_byte())
  if ctx.need_heap || prelude.length() > 0 {
    let prologue = ByteBuf::new()
    if ctx.need_heap {
      if ctx.use_heap_global {
        emit_global_get(prologue, ctx.heap_global)
        emit_local_set(prologue, ctx.heap_local)
      } else {
        let coverage_bytes = if ctx.coverage_enabled {
          ctx.coverage_points.length() * 4
        } else {
          0
        }
        let heap_start = align4(ctx.strings.next_offset + coverage_bytes)
        emit_i32_const_raw(prologue, heap_start)
        emit_local_set(prologue, ctx.heap_local)
      }
    }
    if prelude.length() > 0 {
      prologue.extend(prelude)
    }
    prologue.extend(instr.data)
    prologue.data
  } else {
    instr.data
  }
}

///|
fn compile_function(
  ctx : CodegenCtx,
  self_name : String?,
  params : Array[@core.FuncParam],
  param_kinds : Array[ValueKind],
  result_kind : ValueKind,
  body : @core.Module,
  need_heap : Bool,
  captures : Array[String],
  capture_kinds : Array[ValueKind],
  with_env : Bool,
) -> WasmFunc raise WasmGenError {
  let saved_locals = ctx.locals
  let saved_kinds = ctx.local_kinds
  let saved_types = ctx.local_types
  let saved_count = ctx.local_count
  let saved_need_heap = ctx.need_heap
  let saved_heap_local = ctx.heap_local
  let saved_current_env_idx = ctx.current_env_idx
  let saved_fn_locals = ctx.fn_local_sigs
  ctx.locals = {}
  ctx.local_kinds = {}
  ctx.local_types = []
  ctx.local_count = 0
  ctx.need_heap = false
  ctx.heap_local = -1
  ctx.fn_local_sigs = {}
  let param_len = if params.length() < param_kinds.length() {
    params.length()
  } else {
    param_kinds.length()
  }
  for i in 0..<param_len {
    ctx.locals[params[i].name] = i
    ctx.local_kinds[params[i].name] = param_kinds[i]
    ctx.local_count += 1
    match func_sig_from_type(ctx, params[i].ty) {
      Some(sig) => ctx.fn_local_sigs[params[i].name] = sig
      None => ()
    }
  }
  match self_name {
    Some(name) =>
      // Keep self signature visible while compiling this function body.
      // This is required for recursive local closures where `name` is both
      // in fn_indices (direct call target) and in locals (captured closure).
      ctx.fn_local_sigs[name] = func_sig_with_env(param_kinds, result_kind)
    None => ()
  }
  let env_idx = if with_env {
    let idx = ctx.local_count
    ctx.local_count += 1
    idx
  } else {
    -1
  }
  ctx.current_env_idx = env_idx
  let prelude = ByteBuf::new()
  match self_name {
    Some(name) =>
      if with_env && captures.length() > 0 {
        match ctx.fn_indices.get(name) {
          Some(_) => {
            // Materialize current function value so nested closures can capture
            // the correct closure (including env), not a bare function slot.
            let self_local = ctx.local_count
            ctx.local_count += 1
            ctx.local_types.push(ValueKind::I64)
            ctx.locals[name] = self_local
            ctx.local_kinds[name] = ValueKind::I64
            emit_local_get(prelude, env_idx)
            emit_i64_extend_i32_u(prelude)
            emit_i64_const_raw(prelude, tag_obj.to_int64())
            emit_i64_or(prelude)
            emit_local_set(prelude, self_local)
          }
          None => ()
        }
      }
    None => ()
  }
  if with_env && captures.length() > 0 {
    for i in 0..<captures.length() {
      let name = captures[i]
      let kind = if i < capture_kinds.length() {
        capture_kinds[i]
      } else {
        ValueKind::I32
      }
      let idx = ctx.local_count
      ctx.local_count += 1
      match saved_fn_locals.get(name) {
        Some(sig) => ctx.fn_local_sigs[name] = sig
        None =>
          match ctx.fn_params.get(name) {
            Some(param_kinds) =>
              match ctx.fn_returns.get(name) {
                Some(ret_kind) =>
                  ctx.fn_local_sigs[name] = func_sig_with_env(
                    param_kinds, ret_kind,
                  )
                None => ()
              }
            None => ()
          }
      }
      if ctx.use_js_strings && kind == ValueKind::ExternRef {
        // ExternRef capture: load table slot index from env, then table.get
        ctx.local_types.push(ValueKind::ExternRef)
        ctx.locals[name] = idx
        ctx.local_kinds[name] = ValueKind::ExternRef
        emit_local_get(prelude, env_idx)
        emit_i32_load(prelude, 8 + i * 4) // load slot index
        emit_table_get(prelude, ctx.extern_table_index)
        emit_local_set(prelude, idx)
      } else {
        ctx.local_types.push(ValueKind::I64)
        ctx.locals[name] = idx
        ctx.local_kinds[name] = kind
        emit_local_get(prelude, env_idx)
        emit_i32_load(prelude, 8 + i * 4)
        emit_i64_extend_i32_s(prelude)
        emit_local_set(prelude, idx)
      }
    }
  }
  let body_bytes = compile_func_body(
    ctx,
    body,
    result_kind,
    need_heap,
    prelude.data,
  )
  let locals = ctx.local_types
  let params_with_env : Array[ValueKind] = []
  for kind in param_kinds {
    params_with_env.push(kind)
  }
  if with_env {
    params_with_env.push(ValueKind::I32)
  }
  let func = WasmFunc::{
    params: params_with_env,
    locals,
    result: result_kind,
    body: body_bytes,
  }
  ctx.locals = saved_locals
  ctx.local_kinds = saved_kinds
  ctx.local_types = saved_types
  ctx.local_count = saved_count
  ctx.need_heap = saved_need_heap
  ctx.heap_local = saved_heap_local
  ctx.current_env_idx = saved_current_env_idx
  ctx.fn_local_sigs = saved_fn_locals
  func
}

///|
fn compile_cabi_realloc_function(
  ctx : CodegenCtx,
) -> WasmFunc raise WasmGenError {
  if ctx.heap_global < 0 {
    raise WasmGenError::Unsupported("cabi_realloc requires heap global")
  }
  let body = ByteBuf::new()
  let ptr_local = 4
  let align_mask_local = 5
  // if new_size == 0: return align
  emit_local_get(body, 3)
  emit_i32_eqz(body)
  body.push((4).to_byte()) // if
  body.push((127).to_byte()) // result i32
  emit_local_get(body, 2)
  body.push((5).to_byte()) // else
  emit_global_get(body, ctx.heap_global)
  emit_local_set(body, ptr_local)
  // canonical ABI passes an alignment (power of two) in param[2].
  emit_local_get(body, 2)
  emit_i32_const_raw(body, 1)
  emit_i32_sub(body)
  emit_local_set(body, align_mask_local)
  emit_local_get(body, align_mask_local)
  emit_i32_eqz(body)
  body.push((4).to_byte()) // if
  body.push((64).to_byte()) // empty block
  body.push((5).to_byte()) // else
  emit_local_get(body, ptr_local)
  emit_local_get(body, align_mask_local)
  emit_i32_add(body)
  emit_local_get(body, align_mask_local)
  emit_i32_const_raw(body, -1)
  emit_i32_xor(body)
  emit_i32_and(body)
  emit_local_set(body, ptr_local)
  body.push((11).to_byte()) // end if
  emit_local_get(body, ptr_local)
  emit_local_get(body, 3)
  emit_i32_add(body)
  emit_i32_const_raw(body, 3)
  emit_i32_add(body)
  emit_i32_const_raw(body, -4)
  emit_i32_and(body)
  emit_global_set(body, ctx.heap_global)
  emit_local_get(body, ptr_local)
  body.push((11).to_byte()) // end if
  body.push((11).to_byte()) // end func
  WasmFunc::{
    params: [ValueKind::I32, ValueKind::I32, ValueKind::I32, ValueKind::I32],
    locals: [ValueKind::I32, ValueKind::I32],
    result: ValueKind::I32,
    body: body.data,
  }
}

///|
priv enum PatCont {
  Arm
  Tuple(Int, Array[@core.Pat], Int, PatCont) // raw_ptr, items, index, next
  Record(Int, Array[@core.RecordFieldPat], Int, PatCont) // raw_ptr, fields, index, next
  Ctor(Int, Array[@core.Pat], Int, String, PatCont) // raw_ptr, args, index, ctor_name, next
}

///|
fn compile_pat_cont(
  ctx : CodegenCtx,
  buf : ByteBuf,
  cont : PatCont,
  match_scrut_idx : Int,
  arms : Array[@core.MatchArm],
  start : Int,
  arm : @core.MatchArm,
  bindings : Map[String, Int],
) -> Unit raise WasmGenError {
  match cont {
    PatCont::Arm =>
      compile_guarded_arm_with_bindings(
        ctx, buf, match_scrut_idx, arms, start, arm, bindings,
      )
    PatCont::Tuple(tuple_idx, items, index, next) =>
      compile_tuple_items_cont(
        ctx, buf, tuple_idx, items, index, next, match_scrut_idx, arms, start, arm,
        bindings,
      )
    PatCont::Record(record_idx, fields, index, next) =>
      compile_record_fields_cont(
        ctx, buf, record_idx, fields, index, next, match_scrut_idx, arms, start,
        arm, bindings,
      )
    PatCont::Ctor(ctor_idx, args, index, ctor_name, next) =>
      compile_ctor_args_cont(
        ctx, buf, ctor_idx, args, index, ctor_name, next, match_scrut_idx, arms,
        start, arm, bindings,
      )
  }
}

///|
fn compile_pat_match(
  ctx : CodegenCtx,
  buf : ByteBuf,
  value_idx : Int,
  pat : @core.Pat,
  match_scrut_idx : Int,
  arms : Array[@core.MatchArm],
  start : Int,
  arm : @core.MatchArm,
  bindings : Map[String, Int],
  cont : PatCont,
) -> Unit raise WasmGenError {
  match pat {
    @core.Pat::Wildcard(span~) => {
      let _ = span
      compile_pat_cont(
        ctx, buf, cont, match_scrut_idx, arms, start, arm, bindings,
      )
    }
    @core.Pat::Bind(name~, span~) => {
      let _ = span
      let idx = bind_local(ctx, name)
      emit_local_get(buf, value_idx)
      emit_local_set(buf, idx)
      bindings[name] = idx
      compile_pat_cont(
        ctx, buf, cont, match_scrut_idx, arms, start, arm, bindings,
      )
    }
    @core.Pat::Int(value~, span~) => {
      let _ = value
      let _ = span
      emit_local_get(buf, value_idx)
      emit_pat_literal(ctx, buf, pat)
      emit_i64_eq(buf)
      buf.push((4).to_byte())
      buf.push((126).to_byte())
      adjust_loop_offsets(ctx, 1)
      compile_pat_cont(
        ctx, buf, cont, match_scrut_idx, arms, start, arm, bindings,
      )
      buf.push((5).to_byte())
      compile_match_chain(ctx, buf, match_scrut_idx, arms, start + 1)
      buf.push((11).to_byte())
      adjust_loop_offsets(ctx, -1)
    }
    @core.Pat::Char(value~, span~) => {
      let _ = value
      let _ = span
      emit_local_get(buf, value_idx)
      emit_pat_literal(ctx, buf, pat)
      emit_i64_eq(buf)
      buf.push((4).to_byte())
      buf.push((126).to_byte())
      adjust_loop_offsets(ctx, 1)
      compile_pat_cont(
        ctx, buf, cont, match_scrut_idx, arms, start, arm, bindings,
      )
      buf.push((5).to_byte())
      compile_match_chain(ctx, buf, match_scrut_idx, arms, start + 1)
      buf.push((11).to_byte())
      adjust_loop_offsets(ctx, -1)
    }
    @core.Pat::Float(value=n, span~) => {
      let _ = span
      // Combined check: tag_obj AND type==obj_float AND value==n
      emit_tag_obj_check(buf, value_idx)
      emit_load_obj_type(buf, value_idx)
      emit_i32_const_raw(buf, obj_float)
      emit_i32_eq(buf)
      emit_i32_and(buf)
      emit_untag_ptr(buf, value_idx)
      emit_f32_load(buf, 4)
      emit_f32_const(buf, n)
      emit_f32_eq(buf)
      emit_i32_and(buf)
      // Single if-else
      buf.push((4).to_byte()) // if
      buf.push((126).to_byte()) // result i64
      adjust_loop_offsets(ctx, 1)
      compile_pat_cont(
        ctx, buf, cont, match_scrut_idx, arms, start, arm, bindings,
      )
      buf.push((5).to_byte()) // else
      compile_match_chain(ctx, buf, match_scrut_idx, arms, start + 1)
      buf.push((11).to_byte()) // end
      adjust_loop_offsets(ctx, -1)
    }
    @core.Pat::Double(value=n, span~) => {
      let _ = span
      // Combined check: tag_obj AND type==obj_double AND value==n
      emit_tag_obj_check(buf, value_idx)
      emit_load_obj_type(buf, value_idx)
      emit_i32_const_raw(buf, obj_double)
      emit_i32_eq(buf)
      emit_i32_and(buf)
      emit_untag_ptr(buf, value_idx)
      emit_f64_load(buf, 4)
      emit_f64_const(buf, n)
      emit_f64_eq(buf)
      emit_i32_and(buf)
      // Single if-else
      buf.push((4).to_byte()) // if
      buf.push((126).to_byte()) // result i64
      adjust_loop_offsets(ctx, 1)
      compile_pat_cont(
        ctx, buf, cont, match_scrut_idx, arms, start, arm, bindings,
      )
      buf.push((5).to_byte()) // else
      compile_match_chain(ctx, buf, match_scrut_idx, arms, start + 1)
      buf.push((11).to_byte()) // end
      adjust_loop_offsets(ctx, -1)
    }
    @core.Pat::Bool(value~, span~) => {
      let _ = value
      let _ = span
      emit_local_get(buf, value_idx)
      emit_pat_literal(ctx, buf, pat)
      emit_i64_eq(buf)
      buf.push((4).to_byte())
      buf.push((126).to_byte())
      adjust_loop_offsets(ctx, 1)
      compile_pat_cont(
        ctx, buf, cont, match_scrut_idx, arms, start, arm, bindings,
      )
      buf.push((5).to_byte())
      compile_match_chain(ctx, buf, match_scrut_idx, arms, start + 1)
      buf.push((11).to_byte())
      adjust_loop_offsets(ctx, -1)
    }
    @core.Pat::String(value=s, span~) => {
      let _ = span
      if ctx.use_js_strings {
        // js-string mode: use js_equals to compare externref strings
        ctx.need_js_equals = true
        // Load scrutinee (externref)
        emit_local_get(buf, value_idx)
        // Load pattern string constant (externref from global)
        let str_idx = ctx.js_strings.intern(s)
        emit_global_get(buf, str_idx)
        // Call js_equals
        emit_call(buf, import_index_js_equals(ctx))
        // Result is i32 (0 or 1)
        buf.push((4).to_byte()) // if
        buf.push((126).to_byte()) // result i64
        adjust_loop_offsets(ctx, 1)
        compile_pat_cont(
          ctx, buf, cont, match_scrut_idx, arms, start, arm, bindings,
        )
        buf.push((5).to_byte())
        compile_match_chain(ctx, buf, match_scrut_idx, arms, start + 1)
        buf.push((11).to_byte())
        adjust_loop_offsets(ctx, -1)
      } else {
        // Non-js-string mode: compare tagged pointers
        emit_local_get(buf, value_idx)
        emit_pat_literal(ctx, buf, pat)
        emit_i64_eq(buf)
        buf.push((4).to_byte())
        buf.push((126).to_byte())
        adjust_loop_offsets(ctx, 1)
        compile_pat_cont(
          ctx, buf, cont, match_scrut_idx, arms, start, arm, bindings,
        )
        buf.push((5).to_byte())
        compile_match_chain(ctx, buf, match_scrut_idx, arms, start + 1)
        buf.push((11).to_byte())
        adjust_loop_offsets(ctx, -1)
      }
    }
    @core.Pat::Ctor(name~, args~, span~) => {
      let _ = span
      let tag = match ctx.enum_ctor_tags.get(name) {
        Some(t) => t
        None => raise WasmGenError::Unsupported("unknown ctor: " + name)
      }
      // Cache raw pointer for repeated use
      let raw_ptr = emit_untag_ptr_cached(ctx, buf, value_idx)
      // Combined header check: tag_obj AND type==obj_enum AND tag matches
      emit_tag_obj_check(buf, value_idx)
      emit_load_obj_type_raw(buf, raw_ptr)
      emit_i32_const_raw(buf, obj_enum)
      emit_i32_eq(buf)
      emit_i32_and(buf)
      emit_load_ctor_tag_raw(buf, raw_ptr)
      emit_i32_const_raw(buf, tag)
      emit_i32_eq(buf)
      emit_i32_and(buf)
      // Single if-else
      buf.push((4).to_byte()) // if
      buf.push((126).to_byte()) // result i64
      adjust_loop_offsets(ctx, 1)
      // Bind args
      if args.length() == 0 {
        compile_pat_cont(
          ctx, buf, cont, match_scrut_idx, arms, start, arm, bindings,
        )
      } else {
        compile_ctor_args_cont(
          ctx, buf, raw_ptr, args, 0, name, cont, match_scrut_idx, arms, start, arm,
          bindings,
        )
      }
      buf.push((5).to_byte()) // else
      compile_match_chain(ctx, buf, match_scrut_idx, arms, start + 1)
      buf.push((11).to_byte()) // end
      adjust_loop_offsets(ctx, -1)
    }
    @core.Pat::Tuple(items~, span~) => {
      let _ = span
      // Cache raw pointer for repeated use
      let raw_ptr = emit_untag_ptr_cached(ctx, buf, value_idx)
      // Combined header check: tag_obj AND type==obj_tuple AND length matches
      emit_tag_obj_check(buf, value_idx)
      emit_load_obj_type_raw(buf, raw_ptr)
      emit_i32_const_raw(buf, obj_tuple)
      emit_i32_eq(buf)
      emit_i32_and(buf)
      emit_load_obj_len_raw(buf, raw_ptr)
      emit_i32_const_raw(buf, items.length())
      emit_i32_eq(buf)
      emit_i32_and(buf)
      // Single if-else
      buf.push((4).to_byte()) // if
      buf.push((126).to_byte()) // result i64
      adjust_loop_offsets(ctx, 1)
      compile_tuple_items_cont(
        ctx, buf, raw_ptr, items, 0, cont, match_scrut_idx, arms, start, arm, bindings,
      )
      buf.push((5).to_byte()) // else
      compile_match_chain(ctx, buf, match_scrut_idx, arms, start + 1)
      buf.push((11).to_byte()) // end
      adjust_loop_offsets(ctx, -1)
    }
    @core.Pat::Record(fields~, span~) => {
      let _ = span
      let ordered = sort_record_fields_pat(fields)
      // Cache raw pointer for repeated use
      let raw_ptr = emit_untag_ptr_cached(ctx, buf, value_idx)
      // Combined header check: tag_obj AND type==obj_record AND length matches
      emit_tag_obj_check(buf, value_idx)
      emit_load_obj_type_raw(buf, raw_ptr)
      emit_i32_const_raw(buf, obj_record)
      emit_i32_eq(buf)
      emit_i32_and(buf)
      emit_load_obj_len_raw(buf, raw_ptr)
      emit_i32_const_raw(buf, ordered.length())
      emit_i32_eq(buf)
      emit_i32_and(buf)
      // Single if-else
      buf.push((4).to_byte()) // if
      buf.push((126).to_byte()) // result i64
      adjust_loop_offsets(ctx, 1)
      compile_record_fields_cont(
        ctx, buf, raw_ptr, ordered, 0, cont, match_scrut_idx, arms, start, arm, bindings,
      )
      buf.push((5).to_byte()) // else
      compile_match_chain(ctx, buf, match_scrut_idx, arms, start + 1)
      buf.push((11).to_byte()) // end
      adjust_loop_offsets(ctx, -1)
    }
    @core.Pat::Or(pats~, span~) => {
      let _ = span
      // Expand Or pattern: try each sub-pattern, first match wins
      // Create synthetic arms for each sub-pattern with the same body
      let expanded_arms : Array[@core.MatchArm] = []
      for p in pats {
        expanded_arms.push(@core.MatchArm::{
          pat: p,
          cond: arm.cond,
          expr: arm.expr,
          span: arm.span,
        })
      }
      // Add remaining arms after this one
      for i in (start + 1)..<arms.length() {
        expanded_arms.push(arms[i])
      }
      compile_match_chain(ctx, buf, match_scrut_idx, expanded_arms, 0)
    }
    @core.Pat::Struct(fields~, span~, ..) => {
      let _ = span
      // Struct pattern is same as Record pattern
      let ordered = sort_record_fields_pat(fields)
      let raw_ptr = alloc_temp_local(ctx)
      // Untag pointer and cache
      emit_local_get(buf, value_idx)
      emit_i64_const_raw(buf, (-4).to_int64())
      emit_i64_and(buf)
      emit_i32_wrap_i64(buf)
      emit_local_set(buf, raw_ptr)
      // Check object type
      emit_local_get(buf, value_idx)
      emit_i64_const_raw(buf, tag_mask.to_int64())
      emit_i64_and(buf)
      emit_i64_const_raw(buf, tag_obj.to_int64())
      emit_i64_eq(buf)
      // Single if-else
      buf.push((4).to_byte()) // if
      buf.push((126).to_byte()) // result i64
      adjust_loop_offsets(ctx, 1)
      compile_record_fields_cont(
        ctx, buf, raw_ptr, ordered, 0, cont, match_scrut_idx, arms, start, arm, bindings,
      )
      buf.push((5).to_byte()) // else
      compile_match_chain(ctx, buf, match_scrut_idx, arms, start + 1)
      buf.push((11).to_byte()) // end
      adjust_loop_offsets(ctx, -1)
    }
  }
}

///|
fn compile_ctor_args_cont(
  ctx : CodegenCtx,
  buf : ByteBuf,
  raw_ptr : Int, // cached untagged pointer
  args : Array[@core.Pat],
  index : Int,
  ctor_name : String,
  next : PatCont,
  match_scrut_idx : Int,
  arms : Array[@core.MatchArm],
  start : Int,
  arm : @core.MatchArm,
  bindings : Map[String, Int],
) -> Unit raise WasmGenError {
  if index >= args.length() {
    compile_pat_cont(
      ctx, buf, next, match_scrut_idx, arms, start, arm, bindings,
    )
    return
  }
  let arg_kinds = match ctx.enum_ctor_arg_kinds.get(ctor_name) {
    Some(kinds) => kinds
    None => []
  }
  let field_kind = if index < arg_kinds.length() {
    arg_kinds[index]
  } else {
    ValueKind::I32
  }
  if ctx.use_js_strings && field_kind == ValueKind::ExternRef {
    // ExternRef field: load table slot index, then table.get
    let tmp = alloc_temp_local_with_kind(ctx, ValueKind::ExternRef)
    emit_load_ctor_arg_raw(buf, raw_ptr, index)
    emit_table_get(buf, ctx.extern_table_index)
    emit_local_set(buf, tmp)
    let cont = PatCont::Ctor(raw_ptr, args, index + 1, ctor_name, next)
    compile_pat_match(
      ctx,
      buf,
      tmp,
      args[index],
      match_scrut_idx,
      arms,
      start,
      arm,
      bindings,
      cont,
    )
  } else {
    let tmp = alloc_temp_local(ctx)
    emit_load_ctor_arg_raw(buf, raw_ptr, index)
    emit_local_set(buf, tmp)
    let cont = PatCont::Ctor(raw_ptr, args, index + 1, ctor_name, next)
    compile_pat_match(
      ctx,
      buf,
      tmp,
      args[index],
      match_scrut_idx,
      arms,
      start,
      arm,
      bindings,
      cont,
    )
  }
}

///|
fn compile_tuple_items_cont(
  ctx : CodegenCtx,
  buf : ByteBuf,
  raw_ptr : Int, // cached untagged pointer
  items : Array[@core.Pat],
  index : Int,
  next : PatCont,
  match_scrut_idx : Int,
  arms : Array[@core.MatchArm],
  start : Int,
  arm : @core.MatchArm,
  bindings : Map[String, Int],
) -> Unit raise WasmGenError {
  if index >= items.length() {
    compile_pat_cont(
      ctx, buf, next, match_scrut_idx, arms, start, arm, bindings,
    )
    return
  }
  let tmp = alloc_temp_local(ctx)
  emit_load_tuple_elem_raw(buf, raw_ptr, index)
  emit_local_set(buf, tmp)
  let cont = PatCont::Tuple(raw_ptr, items, index + 1, next)
  compile_pat_match(
    ctx,
    buf,
    tmp,
    items[index],
    match_scrut_idx,
    arms,
    start,
    arm,
    bindings,
    cont,
  )
}

///|
fn compile_record_fields_cont(
  ctx : CodegenCtx,
  buf : ByteBuf,
  raw_ptr : Int, // cached untagged pointer
  fields : Array[@core.RecordFieldPat],
  index : Int,
  next : PatCont,
  match_scrut_idx : Int,
  arms : Array[@core.MatchArm],
  start : Int,
  arm : @core.MatchArm,
  bindings : Map[String, Int],
) -> Unit raise WasmGenError {
  if index >= fields.length() {
    compile_pat_cont(
      ctx, buf, next, match_scrut_idx, arms, start, arm, bindings,
    )
    return
  }
  let field = fields[index]
  let name_ptr = ctx.strings.intern(field.name)
  emit_load_record_name_raw(buf, raw_ptr, index)
  emit_i32_const_raw(buf, name_ptr)
  emit_i32_eq(buf)
  buf.push((4).to_byte())
  buf.push((126).to_byte())
  let tmp = alloc_temp_local(ctx)
  emit_load_record_value_raw(buf, raw_ptr, index)
  emit_local_set(buf, tmp)
  let cont = PatCont::Record(raw_ptr, fields, index + 1, next)
  compile_pat_match(
    ctx,
    buf,
    tmp,
    field.pat,
    match_scrut_idx,
    arms,
    start,
    arm,
    bindings,
    cont,
  )
  buf.push((5).to_byte())
  compile_match_chain(ctx, buf, match_scrut_idx, arms, start + 1)
  buf.push((11).to_byte())
}

///|
fn emit_pat_literal(
  ctx : CodegenCtx,
  buf : ByteBuf,
  pat : @core.Pat,
) -> Unit raise WasmGenError {
  match pat {
    @core.Pat::Wildcard(span~) => {
      let _ = span
      raise WasmGenError::Unsupported("wildcard literal")
    }
    @core.Pat::Bind(name~, span~) => {
      let _ = name
      let _ = span
      raise WasmGenError::Unsupported("bind literal")
    }
    @core.Pat::Ctor(name~, args~, span~) => {
      let _ = name
      let _ = args
      let _ = span
      raise WasmGenError::Unsupported("ctor literal")
    }
    @core.Pat::Tuple(items~, span~) => {
      let _ = items
      let _ = span
      raise WasmGenError::Unsupported("tuple literal")
    }
    @core.Pat::Record(fields~, span~) => {
      let _ = fields
      let _ = span
      raise WasmGenError::Unsupported("record literal")
    }
    @core.Pat::Int(value=n, span~) => {
      let _ = span
      emit_i64_const_tagged(buf, n)
    }
    @core.Pat::Char(value=c, span~) => {
      let _ = span
      emit_i64_const_tagged(buf, c.to_int().to_int64())
    }
    @core.Pat::Float(value~, span~) => {
      let _ = value
      let _ = span
      raise WasmGenError::Unsupported("float literal")
    }
    @core.Pat::Double(value~, span~) => {
      let _ = value
      let _ = span
      raise WasmGenError::Unsupported("double literal")
    }
    @core.Pat::Bool(value=b, span~) => {
      let _ = span
      emit_i64_const_raw(buf, tag_bool_value64(b))
    }
    @core.Pat::String(value=s, span~) => {
      let _ = span
      if ctx.use_js_strings {
        raise WasmGenError::BackendLimit(backend="wasm-js-string", feature="string pattern matching")
      }
      let offset = ctx.strings.intern(s)
      emit_i64_const_raw(buf, tag_ptr64(offset, tag_obj))
    }
    @core.Pat::Or(pats~, span~) => {
      let _ = pats
      let _ = span
      raise WasmGenError::Unsupported("or pattern literal")
    }
    @core.Pat::Struct(fields~, span~, ..) => {
      let _ = fields
      let _ = span
      raise WasmGenError::Unsupported("struct pattern literal")
    }
  }
}

///|
fn compile_match_chain(
  ctx : CodegenCtx,
  buf : ByteBuf,
  scrut_idx : Int,
  arms : Array[@core.MatchArm],
  start : Int,
) -> Unit raise WasmGenError {
  if start >= arms.length() {
    emit_i64_const_tagged(buf, 0L)
    return
  }
  let arm = arms[start]
  let saved = ctx.locals.copy()
  let saved_kinds = ctx.local_kinds.copy()
  let bindings : Map[String, Int] = {}
  compile_pat_match(
    ctx,
    buf,
    scrut_idx,
    arm.pat,
    scrut_idx,
    arms,
    start,
    arm,
    bindings,
    PatCont::Arm,
  )
  restore_locals(ctx, saved)
  restore_local_kinds(ctx, saved_kinds)
}

///|
fn compile_guarded_arm_with_bindings(
  ctx : CodegenCtx,
  buf : ByteBuf,
  scrut_idx : Int,
  arms : Array[@core.MatchArm],
  index : Int,
  arm : @core.MatchArm,
  bindings : Map[String, Int],
) -> Unit raise WasmGenError {
  let saved = ctx.locals.copy()
  let saved_kinds = ctx.local_kinds.copy()
  for name, idx in bindings {
    ctx.locals[name] = idx
    ctx.local_kinds[name] = ValueKind::I32
  }
  match arm.cond {
    Some(c) => {
      compile_expr(ctx, buf, c)
      emit_i64_const_raw(buf, 2L)
      emit_i64_shr_u(buf)
      emit_i32_wrap_i64(buf)
      buf.push((4).to_byte())
      buf.push((126).to_byte())
      adjust_loop_offsets(ctx, 1)
      emit_coverage(ctx, buf, WasmCoveragePointKind::BranchMatchArm, arm.span)
      compile_expr(ctx, buf, arm.expr)
      buf.push((5).to_byte())
      restore_locals(ctx, saved)
      restore_local_kinds(ctx, saved_kinds)
      compile_match_chain(ctx, buf, scrut_idx, arms, index + 1)
      buf.push((11).to_byte())
      adjust_loop_offsets(ctx, -1)
      restore_locals(ctx, saved)
      restore_local_kinds(ctx, saved_kinds)
    }
    None => {
      emit_coverage(ctx, buf, WasmCoveragePointKind::BranchMatchArm, arm.span)
      compile_expr(ctx, buf, arm.expr)
      restore_locals(ctx, saved)
      restore_local_kinds(ctx, saved_kinds)
    }
  }
}

///|
fn bind_local(ctx : CodegenCtx, _name : String) -> Int {
  let idx = ctx.local_count
  ctx.local_count += 1
  ctx.local_types.push(ValueKind::I64)
  idx
}

///|
fn alloc_temp_local(ctx : CodegenCtx) -> Int {
  let idx = ctx.local_count
  ctx.local_count += 1
  ctx.local_types.push(ValueKind::I32)
  idx
}

///|
fn alloc_temp_local_with_kind(ctx : CodegenCtx, kind : ValueKind) -> Int {
  let idx = ctx.local_count
  ctx.local_count += 1
  ctx.local_types.push(kind)
  idx
}

///|
fn emit_tag_obj_check(buf : ByteBuf, scrut_idx : Int) -> Unit {
  emit_local_get(buf, scrut_idx)
  emit_i64_const_raw(buf, tag_mask.to_int64())
  emit_i64_and(buf)
  emit_i64_const_raw(buf, tag_obj.to_int64())
  emit_i64_eq(buf)
}

///|
fn emit_untag_ptr(buf : ByteBuf, scrut_idx : Int) -> Unit {
  emit_local_get(buf, scrut_idx)
  emit_i64_const_raw(buf, (-4).to_int64())
  emit_i64_and(buf)
  emit_i32_wrap_i64(buf)
}

///|
/// Compute untagged pointer and store in a new temp local, returning the local index
fn emit_untag_ptr_cached(
  ctx : CodegenCtx,
  buf : ByteBuf,
  scrut_idx : Int,
) -> Int {
  let raw_ptr = alloc_temp_local(ctx)
  emit_untag_ptr(buf, scrut_idx)
  emit_local_set(buf, raw_ptr)
  raw_ptr
}

///|
fn emit_load_obj_type(buf : ByteBuf, scrut_idx : Int) -> Unit {
  emit_untag_ptr(buf, scrut_idx)
  emit_i32_load(buf, 0)
}

///|
/// Load object type using cached raw pointer
fn emit_load_obj_type_raw(buf : ByteBuf, raw_ptr_idx : Int) -> Unit {
  emit_local_get(buf, raw_ptr_idx)
  emit_i32_load(buf, 0)
}

///|
/// Load object length using cached raw pointer
fn emit_load_obj_len_raw(buf : ByteBuf, raw_ptr_idx : Int) -> Unit {
  emit_local_get(buf, raw_ptr_idx)
  emit_i32_load(buf, 4)
}

///|
fn emit_load_tuple_elem(buf : ByteBuf, scrut_idx : Int, index : Int) -> Unit {
  emit_untag_ptr(buf, scrut_idx)
  emit_i32_load(buf, 8 + index * 4)
  emit_i64_extend_i32_s(buf)
}

///|
/// Load tuple element using cached raw pointer
fn emit_load_tuple_elem_raw(
  buf : ByteBuf,
  raw_ptr_idx : Int,
  index : Int,
) -> Unit {
  emit_local_get(buf, raw_ptr_idx)
  emit_i32_load(buf, 8 + index * 4)
  emit_i64_extend_i32_s(buf)
}

///|
/// Load record value (for let destructuring)
fn emit_load_record_value(buf : ByteBuf, scrut_idx : Int, index : Int) -> Unit {
  emit_untag_ptr(buf, scrut_idx)
  emit_i32_load(buf, 8 + index * 8 + 4)
  emit_i64_extend_i32_s(buf)
}

///|
/// Load record name using cached raw pointer
fn emit_load_record_name_raw(
  buf : ByteBuf,
  raw_ptr_idx : Int,
  index : Int,
) -> Unit {
  emit_local_get(buf, raw_ptr_idx)
  emit_i32_load(buf, 8 + index * 8)
}

///|
/// Load record value using cached raw pointer
fn emit_load_record_value_raw(
  buf : ByteBuf,
  raw_ptr_idx : Int,
  index : Int,
) -> Unit {
  emit_local_get(buf, raw_ptr_idx)
  emit_i32_load(buf, 8 + index * 8 + 4)
  emit_i64_extend_i32_s(buf)
}

///|
/// Load ctor tag using cached raw pointer
fn emit_load_ctor_tag_raw(buf : ByteBuf, raw_ptr_idx : Int) -> Unit {
  emit_local_get(buf, raw_ptr_idx)
  emit_i32_load(buf, 4)
}

///|
/// Load ctor arg using cached raw pointer
fn emit_load_ctor_arg_raw(
  buf : ByteBuf,
  raw_ptr_idx : Int,
  index : Int,
) -> Unit {
  emit_local_get(buf, raw_ptr_idx)
  emit_i32_load(buf, 8 + index * 4)
  emit_i64_extend_i32_s(buf)
}
