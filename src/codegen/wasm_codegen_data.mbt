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
  let tmp = alloc_temp_local_with_kind(ctx, ValueKind::I64)
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
  let tmp = alloc_temp_local_with_kind(ctx, ValueKind::I64)
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
  multivalue_kinds? : Array[ValueKind]? = None,
) -> Array[Byte] raise WasmGenError {
  let instr = ByteBuf::new()
  if multivalue_kinds is None &&
    ctx.use_js_strings &&
    result_kind != ValueKind::I32 {
    let inferred = infer_block_kind(ctx, ast, ctx.local_kinds)
    if inferred != result_kind {
      raise WasmGenError::BackendLimit(
        backend="wasm-js-string",
        feature="return kind mismatch",
      )
    }
  }
  ctx.need_heap = need_heap
  if ctx.need_heap {
    ctx.heap_local = ctx.local_count
    ctx.local_count += 1
    ctx.local_types.push(ValueKind::I32)
  }
  match multivalue_kinds {
    Some(kinds) => compile_block_multivalue(ctx, instr, ast, kinds)
    None => compile_block_expr(ctx, instr, ast)
  }
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
      match ctx.fn_multivalue_results.get(name) {
        Some(results) =>
          ctx.fn_local_sigs[name] = func_sig_with_env_multi(
            param_kinds, results,
          )
        None =>
          ctx.fn_local_sigs[name] = func_sig_with_env(param_kinds, result_kind)
      }
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
        ValueKind::I64
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
                  ctx.fn_local_sigs[name] = match
                    ctx.fn_multivalue_results.get(name) {
                    Some(results) =>
                      func_sig_with_env_multi(param_kinds, results)
                    None => func_sig_with_env(param_kinds, ret_kind)
                  }
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
        emit_i64_load(prelude, 8 + i * 8) // load slot index as i64
        emit_i32_wrap_i64(prelude) // wrap to i32 for table.get
        emit_table_get(prelude, ctx.extern_table_index)
        emit_local_set(prelude, idx)
      } else {
        ctx.local_types.push(ValueKind::I64)
        ctx.locals[name] = idx
        ctx.local_kinds[name] = kind
        emit_local_get(prelude, env_idx)
        emit_i64_load(prelude, 8 + i * 8)
        emit_local_set(prelude, idx)
      }
    }
  }
  let mv_kinds : Array[ValueKind]? = match self_name {
    Some(name) =>
      match ctx.fn_multivalue_results.get(name) {
        Some(kinds) => Some(kinds)
        None => None
      }
    None => None
  }
  let body_bytes = compile_func_body(
    ctx,
    body,
    result_kind,
    need_heap,
    prelude.data,
    multivalue_kinds=mv_kinds,
  )
  let locals = ctx.local_types
  let params_with_env : Array[ValueKind] = []
  for kind in param_kinds {
    params_with_env.push(kind)
  }
  if with_env {
    params_with_env.push(ValueKind::I32)
  }
  let multi_results : Array[ValueKind] = match self_name {
    Some(name) =>
      match ctx.fn_multivalue_results.get(name) {
        Some(kinds) => kinds
        None => [result_kind]
      }
    None => [result_kind]
  }
  let func = WasmFunc::{
    params: params_with_env,
    locals,
    results: multi_results,
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
    results: [ValueKind::I32],
    body: body.data,
  }
}
