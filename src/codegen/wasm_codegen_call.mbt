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
  let pos_args = extract_positional_exprs_with_arity(args, name, 2)
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
  let pos_args = extract_positional_exprs_with_arity(args, name, 2)
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
  let pos_args = extract_positional_exprs_with_arity(args, name, 2)
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
  let pos_args = extract_positional_exprs_with_arity(args, name, 2)
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
  let pos_args = extract_positional_exprs_with_arity(args, name, 2)
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
fn extract_positional_exprs_with_arity(
  args : Array[@core.CallArg],
  name : String,
  expected_arity : Int,
) -> Array[@core.Expr] raise WasmGenError {
  let pos_args = extract_positional_exprs(args, name)
  if pos_args.length() != expected_arity {
    raise WasmGenError::Unsupported(name + " arity")
  }
  pos_args
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
fn compile_call_user_fn(
  ctx : CodegenCtx,
  buf : ByteBuf,
  name : String,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
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
  // Multi-value re-boxing: if function returns multiple values,
  // re-pack them into a heap-allocated tuple for general use.
  match ctx.fn_multivalue_results.get(name) {
    Some(mv_kinds) => emit_rebox_multivalue(ctx, buf, mv_kinds)
    None => ()
  }
}

///|
fn compile_call_by_name(
  ctx : CodegenCtx,
  buf : ByteBuf,
  name : String,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  let is_user_fn = ctx.fn_indices.contains(name)
  if compile_call_builtin_pre_user(ctx, buf, name, args, is_user_fn) {
    return ()
  }
  if is_user_fn {
    compile_call_user_fn(ctx, buf, name, args)
    return ()
  }
  if compile_call_builtin_post_user(ctx, buf, name, args) {
    return ()
  }
  match name {
    _ if ctx.enum_ctor_tags.contains(name) => {
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
    }
    _ => {
      if is_qualified_name(name) {
        raise WasmGenError::BackendLimit(
          backend="wasm",
          feature="qualified call: " + name,
        )
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
        raise WasmGenError::BackendLimit(
          backend="wasm",
          feature="call: " + name,
        )
      }
    }
  }
}
