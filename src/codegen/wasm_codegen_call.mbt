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
fn compile_call_by_name(
  ctx : CodegenCtx,
  buf : ByteBuf,
  name : String,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  let is_user_fn = ctx.fn_indices.contains(name)
  match name {
    "sh" => {
      let pos_args = extract_positional_exprs(args, "sh")
      if pos_args.length() != 1 {
        raise WasmGenError::Unsupported("sh arity")
      }
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_call(buf, import_index_sh(ctx))
      emit_drop(buf)
      emit_i64_const_tagged(buf, 0L)
    }
    "path" => {
      let pos_args = extract_positional_exprs(args, "path")
      if pos_args.length() != 1 {
        raise WasmGenError::Unsupported("path arity")
      }
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_call(buf, import_index_path(ctx))
    }
    "add" if not(is_user_fn) => {
      let pos_args = extract_positional_exprs(args, "add")
      if pos_args.length() != 2 {
        raise WasmGenError::Unsupported("add arity")
      }
      compile_i32_add_tagged(ctx, buf, pos_args[0], pos_args[1])
    }
    "sub" if not(is_user_fn) => {
      let pos_args = extract_positional_exprs(args, "sub")
      if pos_args.length() != 2 {
        raise WasmGenError::Unsupported("sub arity")
      }
      compile_i32_sub_tagged(ctx, buf, pos_args[0], pos_args[1])
    }
    "mul" if not(is_user_fn) => {
      let pos_args = extract_positional_exprs(args, "mul")
      if pos_args.length() != 2 {
        raise WasmGenError::Unsupported("mul arity")
      }
      compile_i32_mul_tagged(ctx, buf, pos_args[0], pos_args[1])
    }
    "div" if not(is_user_fn) => {
      let pos_args = extract_positional_exprs(args, "div")
      if pos_args.length() != 2 {
        raise WasmGenError::Unsupported("div arity")
      }
      compile_i32_div_tagged(ctx, buf, pos_args[0], pos_args[1])
    }
    "eq" if not(is_user_fn) =>
      compile_binary_cmp_op(
        ctx, buf, "eq", args, emit_i64_eq, emit_f32_eq, emit_f64_eq,
      )
    "lt" if not(is_user_fn) =>
      compile_binary_cmp_op(
        ctx, buf, "lt", args, emit_i64_lt_s, emit_f32_lt, emit_f64_lt,
      )
    "assert" if not(is_user_fn) => {
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
    }
    "__add" => {
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
    }
    "__sub" => {
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
    }
    "__mul" => {
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
    }
    "__div" => {
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
    }
    "__mod" => {
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
    }
    "__lshift" => {
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
    }
    "__rshift" => {
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
    }
    "i32_shr_u" => {
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
    }
    "__bit_and" => {
      let pos_args = extract_positional_exprs(args, "__bit_and")
      if pos_args.length() != 2 {
        raise WasmGenError::Unsupported("__bit_and arity")
      }
      // Tagged ints: (a & b) works directly since tag bits are 0
      compile_expr_i32(ctx, buf, pos_args[0])
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_i64_and(buf)
    }
    "__bit_or" => {
      let pos_args = extract_positional_exprs(args, "__bit_or")
      if pos_args.length() != 2 {
        raise WasmGenError::Unsupported("__bit_or arity")
      }
      // Tagged ints: (a | b) works directly since tag bits are 0
      compile_expr_i32(ctx, buf, pos_args[0])
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_i64_or(buf)
    }
    "__bit_xor" => {
      let pos_args = extract_positional_exprs(args, "__bit_xor")
      if pos_args.length() != 2 {
        raise WasmGenError::Unsupported("__bit_xor arity")
      }
      // Tagged ints: (a ^ b) works directly since tag bits are 0
      compile_expr_i32(ctx, buf, pos_args[0])
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_i64_xor(buf)
    }
    "__eq" =>
      compile_binary_cmp_op(
        ctx, buf, "__eq", args, emit_i64_eq, emit_f32_eq, emit_f64_eq,
      )
    "__lt" =>
      compile_binary_cmp_op(
        ctx, buf, "__lt", args, emit_i64_lt_s, emit_f32_lt, emit_f64_lt,
      )
    "i32_eqz" if not(is_user_fn) => {
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
    }
    "i32_eq" if not(is_user_fn) =>
      compile_i32_cmp_to_tagged_int(ctx, buf, "i32_eq", args, emit_i32_eq)
    "i32_ne" if not(is_user_fn) =>
      compile_i32_cmp_to_tagged_int(ctx, buf, "i32_ne", args, emit_i32_ne)
    "i32_lt_s" if not(is_user_fn) =>
      compile_i32_cmp_to_tagged_int(ctx, buf, "i32_lt_s", args, emit_i32_lt_s)
    "i32_gt_s" if not(is_user_fn) =>
      compile_i32_cmp_to_tagged_int(ctx, buf, "i32_gt_s", args, emit_i32_gt_s)
    "i32_le_s" if not(is_user_fn) =>
      compile_i32_cmp_to_tagged_int(ctx, buf, "i32_le_s", args, emit_i32_le_s)
    "i32_ge_s" if not(is_user_fn) =>
      compile_i32_cmp_to_tagged_int(ctx, buf, "i32_ge_s", args, emit_i32_ge_s)
    "f32_eq" if not(is_user_fn) =>
      compile_f32_cmp_to_tagged_int(ctx, buf, "f32_eq", args, emit_f32_eq)
    "f32_ne" if not(is_user_fn) =>
      compile_f32_cmp_to_tagged_int(ctx, buf, "f32_ne", args, emit_f32_ne)
    "f32_lt" if not(is_user_fn) =>
      compile_f32_cmp_to_tagged_int(ctx, buf, "f32_lt", args, emit_f32_lt)
    "f32_gt" if not(is_user_fn) =>
      compile_f32_cmp_to_tagged_int(ctx, buf, "f32_gt", args, emit_f32_gt)
    "f32_le" if not(is_user_fn) =>
      compile_f32_cmp_to_tagged_int(ctx, buf, "f32_le", args, emit_f32_le)
    "f32_ge" if not(is_user_fn) =>
      compile_f32_cmp_to_tagged_int(ctx, buf, "f32_ge", args, emit_f32_ge)
    "f64_eq" if not(is_user_fn) =>
      compile_f64_cmp_to_tagged_int(ctx, buf, "f64_eq", args, emit_f64_eq)
    "f64_ne" if not(is_user_fn) =>
      compile_f64_cmp_to_tagged_int(ctx, buf, "f64_ne", args, emit_f64_ne)
    "f64_lt" if not(is_user_fn) =>
      compile_f64_cmp_to_tagged_int(ctx, buf, "f64_lt", args, emit_f64_lt)
    "f64_gt" if not(is_user_fn) =>
      compile_f64_cmp_to_tagged_int(ctx, buf, "f64_gt", args, emit_f64_gt)
    "f64_le" if not(is_user_fn) =>
      compile_f64_cmp_to_tagged_int(ctx, buf, "f64_le", args, emit_f64_le)
    "f64_ge" if not(is_user_fn) =>
      compile_f64_cmp_to_tagged_int(ctx, buf, "f64_ge", args, emit_f64_ge)
    "__neg" => {
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
    }
    "f32_neg" => {
      let pos_args = extract_positional_exprs(args, "f32_neg")
      if pos_args.length() != 1 {
        raise WasmGenError::Unsupported("f32_neg arity")
      }
      emit_boxed_f32_raise(ctx, buf, fn() raise WasmGenError {
        emit_unbox_f32_expr(ctx, buf, pos_args[0])
        emit_f32_neg(buf)
      })
    }
    "f64_neg" => {
      let pos_args = extract_positional_exprs(args, "f64_neg")
      if pos_args.length() != 1 {
        raise WasmGenError::Unsupported("f64_neg arity")
      }
      emit_boxed_f64_raise(ctx, buf, fn() raise WasmGenError {
        emit_unbox_f64_expr(ctx, buf, pos_args[0])
        emit_f64_neg(buf)
      })
    }
    "int_to_float" | "f32_convert_i32_s" => {
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
    }
    "int_to_double" | "f64_convert_i32_s" | "to_double" => {
      let pos_args = extract_positional_exprs(args, name)
      if pos_args.length() != 1 {
        raise WasmGenError::Unsupported(name + " arity")
      }
      emit_boxed_f64_raise(ctx, buf, fn() raise WasmGenError {
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_i64_const_raw(buf, 2L)
        emit_i64_shr_s(buf)
        emit_f64_convert_i64_s(buf)
      })
    }
    "float_to_int" | "i32_trunc_f32_s" => {
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
    }
    "double_to_int" | "i32_trunc_f64_s" => {
      let pos_args = extract_positional_exprs(args, name)
      if pos_args.length() != 1 {
        raise WasmGenError::Unsupported(name + " arity")
      }
      emit_unbox_f64_expr(ctx, buf, pos_args[0])
      emit_i64_trunc_f64_s(buf)
      emit_i64_const_raw(buf, 2L)
      emit_i64_shl(buf)
      emit_i64_const_raw(buf, tag_int.to_int64())
      emit_i64_or(buf)
    }
    "float_to_double" | "f64_promote_f32" => {
      let pos_args = extract_positional_exprs(args, name)
      if pos_args.length() != 1 {
        raise WasmGenError::Unsupported(name + " arity")
      }
      emit_boxed_f64_raise(ctx, buf, fn() raise WasmGenError {
        emit_unbox_f32_expr(ctx, buf, pos_args[0])
        emit_f64_promote_f32(buf)
      })
    }
    "double_to_float" | "f32_demote_f64" => {
      let pos_args = extract_positional_exprs(args, name)
      if pos_args.length() != 1 {
        raise WasmGenError::Unsupported(name + " arity")
      }
      emit_boxed_f32_raise(ctx, buf, fn() raise WasmGenError {
        emit_unbox_f64_expr(ctx, buf, pos_args[0])
        emit_f32_demote_f64(buf)
      })
    }
    "i32_load" => {
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
    }
    "i32_load8_u" => {
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
    }
    "i32_store" => {
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
    }
    "i32_store8" => {
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
    }
    "f32_load" => {
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
    }
    "f64_load" => {
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
    }
    "f32_store" => {
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
    }
    "f64_store" => {
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
    }
    "not" if not(is_user_fn) => {
      let pos_args = extract_positional_exprs(args, "not")
      if pos_args.length() != 1 {
        raise WasmGenError::Unsupported("not arity")
      }
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_i64_const_raw(buf, 4L)
      emit_i64_xor(buf)
    }
    "and" if not(is_user_fn) => {
      let pos_args = extract_positional_exprs(args, "and")
      if pos_args.length() != 2 {
        raise WasmGenError::Unsupported("and arity")
      }
      compile_expr_i32(ctx, buf, pos_args[0])
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_i64_and(buf)
    }
    "or" if not(is_user_fn) => {
      let pos_args = extract_positional_exprs(args, "or")
      if pos_args.length() != 2 {
        raise WasmGenError::Unsupported("or arity")
      }
      compile_expr_i32(ctx, buf, pos_args[0])
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_i64_or(buf)
    }
    "__to_string" => {
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
    }
    "threads_probe_wat" => {
      let pos_args = extract_positional_exprs(args, "threads_probe_wat")
      if pos_args.length() != 0 {
        raise WasmGenError::Unsupported("threads_probe_wat arity")
      }
      emit_string_const(ctx, buf, "(module)")
    }
    "threads_runtime_hints" => {
      let pos_args = extract_positional_exprs(args, "threads_runtime_hints")
      if pos_args.length() != 0 {
        raise WasmGenError::Unsupported("threads_runtime_hints arity")
      }
      emit_i64_const_tagged(buf, 0L)
    }
    "wasm_env" => {
      let pos_args = extract_positional_exprs(args, "wasm_env")
      if pos_args.length() != 1 {
        raise WasmGenError::Unsupported("wasm_env arity")
      }
      compile_expr(ctx, buf, pos_args[0])
      emit_drop(buf)
      emit_string_const(ctx, buf, "threads=y shared-memory=y")
    }
    "wasi_env" => {
      let pos_args = extract_positional_exprs(args, "wasi_env")
      if pos_args.length() != 1 {
        raise WasmGenError::Unsupported("wasi_env arity")
      }
      compile_expr(ctx, buf, pos_args[0])
      emit_drop(buf)
      emit_string_const(ctx, buf, "threads=y")
    }
    "threads_channel_new" => {
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
    }
    "threads_spawn" => {
      let pos_args = extract_positional_exprs(args, "threads_spawn")
      if pos_args.length() != 2 {
        raise WasmGenError::Unsupported("threads_spawn arity")
      }
      compile_expr(ctx, buf, pos_args[0])
      emit_drop(buf)
      compile_expr_i32(ctx, buf, pos_args[1])
    }
    "threads_send" => {
      let pos_args = extract_positional_exprs(args, "threads_send")
      if pos_args.length() != 2 {
        raise WasmGenError::Unsupported("threads_send arity")
      }
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_drop(buf)
      compile_expr(ctx, buf, pos_args[1])
      emit_drop(buf)
      emit_i64_const_raw(buf, tag_bool_value64(true))
    }
    "threads_recv" => {
      let pos_args = extract_positional_exprs(args, "threads_recv")
      if pos_args.length() != 1 {
        raise WasmGenError::Unsupported("threads_recv arity")
      }
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_drop(buf)
      emit_string_const(ctx, buf, "")
    }
    "threads_wait" => {
      let pos_args = extract_positional_exprs(args, "threads_wait")
      if pos_args.length() != 1 {
        raise WasmGenError::Unsupported("threads_wait arity")
      }
      compile_expr_i32(ctx, buf, pos_args[0])
    }
    "string_length" => {
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
    }
    "string_char_code_at" => {
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
    }
    "string_substring" => {
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
    }
    "string_concat" => {
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
    }
    "string_equals" => {
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
    }
    "string_index_of" => {
      // string_index_of(str, sub) -> Int (byte offset or -1)
      let pos_args = extract_positional_exprs(args, "string_index_of")
      if pos_args.length() != 2 {
        raise WasmGenError::Unsupported("string_index_of arity")
      }
      if ctx.use_js_strings {
        raise WasmGenError::BackendLimit(
          backend="wasm-js-string",
          feature="string_index_of",
        )
      } else {
        let str_ptr = alloc_temp_local(ctx)
        let str_len = alloc_temp_local(ctx)
        let sub_ptr = alloc_temp_local(ctx)
        let sub_len = alloc_temp_local(ctx)
        let outer_i = alloc_temp_local(ctx)
        let inner_j = alloc_temp_local(ctx)
        let result_local = alloc_temp_local(ctx)
        let matched = alloc_temp_local(ctx)
        let limit_local = alloc_temp_local(ctx)
        // get str pointer and length
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_i64_const_raw(buf, (-4).to_int64())
        emit_i64_and(buf)
        emit_i32_wrap_i64(buf)
        emit_local_set(buf, str_ptr)
        emit_local_get(buf, str_ptr)
        emit_i32_load(buf, 4)
        emit_local_set(buf, str_len)
        // get sub pointer and length
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_i64_const_raw(buf, (-4).to_int64())
        emit_i64_and(buf)
        emit_i32_wrap_i64(buf)
        emit_local_set(buf, sub_ptr)
        emit_local_get(buf, sub_ptr)
        emit_i32_load(buf, 4)
        emit_local_set(buf, sub_len)
        // result = -1 (not found)
        emit_i32_const_raw(buf, -1)
        emit_local_set(buf, result_local)
        // limit = str_len - sub_len + 1
        emit_local_get(buf, str_len)
        emit_local_get(buf, sub_len)
        emit_i32_sub(buf)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, limit_local)
        // if sub_len > str_len, skip search (limit <= 0)
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, outer_i)
        emit_block(buf) // block (for breaking when found)
        emit_loop(buf) // outer loop
        // if outer_i >= limit, break
        emit_local_get(buf, outer_i)
        emit_local_get(buf, limit_local)
        emit_i32_lt_s(buf)
        emit_i32_eqz(buf)
        emit_br_if(buf, 1) // break to block
        // check if all sub bytes match at position outer_i
        emit_i32_const_raw(buf, 1)
        emit_local_set(buf, matched)
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, inner_j)
        emit_block(buf) // inner block (for breaking when mismatch)
        emit_loop(buf) // inner loop
        emit_local_get(buf, inner_j)
        emit_local_get(buf, sub_len)
        emit_i32_lt_s(buf)
        emit_i32_eqz(buf)
        emit_br_if(buf, 1) // break inner block (all matched)
        // compare str[outer_i + inner_j] == sub[inner_j]
        emit_local_get(buf, str_ptr)
        emit_local_get(buf, outer_i)
        emit_i32_add(buf)
        emit_local_get(buf, inner_j)
        emit_i32_add(buf)
        emit_i32_load8_u(buf, 8) // str byte
        emit_local_get(buf, sub_ptr)
        emit_local_get(buf, inner_j)
        emit_i32_add(buf)
        emit_i32_load8_u(buf, 8) // sub byte
        emit_i32_eq(buf)
        emit_i32_eqz(buf)
        buf.push((4).to_byte()) // if (not equal)
        buf.push((64).to_byte()) // void
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, matched)
        emit_br(buf, 2) // break inner block
        buf.push((11).to_byte()) // end if
        // inner_j++
        emit_local_get(buf, inner_j)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, inner_j)
        emit_br(buf, 0) // continue inner loop
        emit_end(buf) // end inner loop
        emit_end(buf) // end inner block
        // if matched, set result and break outer
        emit_local_get(buf, matched)
        buf.push((4).to_byte()) // if
        buf.push((64).to_byte()) // void
        emit_local_get(buf, outer_i)
        emit_local_set(buf, result_local)
        emit_br(buf, 1) // break outer block
        buf.push((11).to_byte()) // end if
        // outer_i++
        emit_local_get(buf, outer_i)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, outer_i)
        emit_br(buf, 0) // continue outer loop
        emit_end(buf) // end outer loop
        emit_end(buf) // end outer block
        // tag result as int
        emit_local_get(buf, result_local)
        emit_i64_extend_i32_s(buf)
        emit_i64_const_raw(buf, 2L)
        emit_i64_shl(buf)
        emit_i64_const_raw(buf, tag_int.to_int64())
        emit_i64_or(buf)
      }
    }
    "string_builder" => {
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
    }
    "string_builder_push" => {
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
    }
    "string_builder_freeze" => {
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
    }
    "array_builder" => {
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
    }
    "array_builder_push" => {
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
    }
    "array_builder_freeze" => {
      // array_builder_freeze(builder) -> return builder as-is (it is already an array obj)
      let pos_args = extract_positional_exprs(args, name)
      if pos_args.length() != 1 {
        raise WasmGenError::Unsupported("array_builder_freeze arity")
      }
      compile_expr_i32(ctx, buf, pos_args[0])
    }
    "map_builder" => {
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
    }
    "map_builder_set" => {
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
    }
    "map_builder_freeze" => {
      // map_builder_freeze(builder) -> return builder as-is (it is already a map obj)
      let pos_args = extract_positional_exprs(args, name)
      if pos_args.length() != 1 {
        raise WasmGenError::Unsupported("map_builder_freeze arity")
      }
      compile_expr_i32(ctx, buf, pos_args[0])
    }
    "map_has_key" => {
      // map_has_key(map, key) -> linear search for key, return tagged bool
      let pos_args = extract_positional_exprs(args, name)
      if pos_args.length() != 2 {
        raise WasmGenError::Unsupported("map_has_key arity")
      }
      let map_ptr = alloc_temp_local(ctx)
      let map_len = alloc_temp_local(ctx)
      let loop_i = alloc_temp_local(ctx)
      let found_local = alloc_temp_local(ctx)
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
      emit_i32_const_raw(buf, 0)
      emit_local_set(buf, found_local)
      if ctx.use_js_strings {
        let key_kind = infer_expr_kind(ctx, pos_args[1])
        if key_kind == ValueKind::ExternRef {
          ctx.need_extern_table = true
          ctx.need_js_equals = true
          let key_local = alloc_temp_local_with_kind(ctx, ValueKind::ExternRef)
          compile_expr(ctx, buf, pos_args[1])
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
          emit_i32_load(buf, 8) // slot index
          emit_table_get(buf, ctx.extern_table_index)
          emit_local_get(buf, key_local)
          emit_call(buf, import_index_js_equals(ctx))
          buf.push((4).to_byte()) // if (equals)
          buf.push((64).to_byte()) // void
          emit_i32_const_raw(buf, 1)
          emit_local_set(buf, found_local)
          buf.push((11).to_byte()) // end if (equals)
          emit_local_get(buf, loop_i)
          emit_i32_const_raw(buf, 1)
          emit_i32_add(buf)
          emit_local_set(buf, loop_i)
          buf.push((12).to_byte()) // br
          write_u32_leb(buf, 1) // to loop
          buf.push((11).to_byte()) // end if (i < len)
          buf.push((11).to_byte()) // end loop
        } else {
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
          emit_i32_const_raw(buf, 1)
          emit_local_set(buf, found_local)
          buf.push((11).to_byte()) // end if
          emit_local_get(buf, loop_i)
          emit_i32_const_raw(buf, 1)
          emit_i32_add(buf)
          emit_local_set(buf, loop_i)
          buf.push((12).to_byte()) // br
          write_u32_leb(buf, 1) // to loop
          buf.push((11).to_byte()) // end if
          buf.push((11).to_byte()) // end loop
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
        emit_i32_const_raw(buf, 1)
        emit_local_set(buf, found_local)
        buf.push((11).to_byte()) // end if
        emit_local_get(buf, loop_i)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, loop_i)
        buf.push((12).to_byte()) // br
        write_u32_leb(buf, 1) // to loop
        buf.push((11).to_byte()) // end if
        buf.push((11).to_byte()) // end loop
      }
      // convert found_local (i32: 0 or 1) to tagged bool
      emit_local_get(buf, found_local)
      emit_i64_extend_i32_s(buf)
      emit_i64_const_raw(buf, 2L)
      emit_i64_shl(buf)
      emit_i64_const_raw(buf, tag_bool.to_int64())
      emit_i64_or(buf)
    }
    "map_keys" => {
      // map_keys(map) -> allocate new array with keys from map
      let pos_args = extract_positional_exprs(args, name)
      if pos_args.length() != 1 {
        raise WasmGenError::Unsupported("map_keys arity")
      }
      require_heap(ctx)
      let map_ptr = alloc_temp_local(ctx)
      let map_len = alloc_temp_local(ctx)
      let arr_ptr = alloc_temp_local(ctx)
      let loop_i = alloc_temp_local(ctx)
      // get map pointer
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_i64_const_raw(buf, (-4).to_int64())
      emit_i64_and(buf)
      emit_i32_wrap_i64(buf)
      emit_local_set(buf, map_ptr)
      emit_local_get(buf, map_ptr)
      emit_i32_load(buf, 4) // len
      emit_local_set(buf, map_len)
      // allocate array: [tag:i32, len:i32, elem:i32 * len]
      // size = 8 + len * 4, but len is dynamic so use max_cap approach
      let max_cap = 128
      let size = align4(8 + max_cap * 4)
      emit_heap_alloc(ctx, buf, size, arr_ptr)
      // set array tag
      emit_local_get(buf, arr_ptr)
      emit_i32_const_raw(buf, obj_array)
      emit_i32_store(buf, 0)
      // set array len = map_len
      emit_local_get(buf, arr_ptr)
      emit_local_get(buf, map_len)
      emit_i32_store(buf, 4)
      // copy keys: loop i = 0..len, arr[8+i*4] = map[8+i*8]
      emit_i32_const_raw(buf, 0)
      emit_local_set(buf, loop_i)
      buf.push((3).to_byte()) // loop
      buf.push((64).to_byte()) // void
      emit_local_get(buf, loop_i)
      emit_local_get(buf, map_len)
      emit_i32_lt_s(buf)
      buf.push((4).to_byte()) // if
      buf.push((64).to_byte()) // void
      // store: arr[8 + i*4] = map[8 + i*8]
      emit_local_get(buf, arr_ptr)
      emit_local_get(buf, loop_i)
      emit_i32_const_raw(buf, 4)
      emit_i32_mul(buf)
      emit_i32_add(buf)
      // load key from map
      emit_local_get(buf, map_ptr)
      emit_local_get(buf, loop_i)
      emit_i32_const_raw(buf, 8)
      emit_i32_mul(buf)
      emit_i32_add(buf)
      emit_i32_load(buf, 8)
      // store to array
      emit_i32_store(buf, 8)
      // i++
      emit_local_get(buf, loop_i)
      emit_i32_const_raw(buf, 1)
      emit_i32_add(buf)
      emit_local_set(buf, loop_i)
      buf.push((12).to_byte()) // br
      write_u32_leb(buf, 0) // to loop
      buf.push((11).to_byte()) // end if
      buf.push((11).to_byte()) // end loop
      // return tagged arr_ptr
      emit_local_get(buf, arr_ptr)
      emit_i64_extend_i32_u(buf)
      emit_i64_const_raw(buf, tag_obj.to_int64())
      emit_i64_or(buf)
    }
    "map_values" => {
      // map_values(map) -> allocate new array with values from map
      let pos_args = extract_positional_exprs(args, name)
      if pos_args.length() != 1 {
        raise WasmGenError::Unsupported("map_values arity")
      }
      require_heap(ctx)
      let map_ptr = alloc_temp_local(ctx)
      let map_len = alloc_temp_local(ctx)
      let arr_ptr = alloc_temp_local(ctx)
      let loop_i = alloc_temp_local(ctx)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_i64_const_raw(buf, (-4).to_int64())
      emit_i64_and(buf)
      emit_i32_wrap_i64(buf)
      emit_local_set(buf, map_ptr)
      emit_local_get(buf, map_ptr)
      emit_i32_load(buf, 4)
      emit_local_set(buf, map_len)
      let max_cap = 128
      let size = align4(8 + max_cap * 4)
      emit_heap_alloc(ctx, buf, size, arr_ptr)
      emit_local_get(buf, arr_ptr)
      emit_i32_const_raw(buf, obj_array)
      emit_i32_store(buf, 0)
      emit_local_get(buf, arr_ptr)
      emit_local_get(buf, map_len)
      emit_i32_store(buf, 4)
      emit_i32_const_raw(buf, 0)
      emit_local_set(buf, loop_i)
      buf.push((3).to_byte()) // loop
      buf.push((64).to_byte()) // void
      emit_local_get(buf, loop_i)
      emit_local_get(buf, map_len)
      emit_i32_lt_s(buf)
      buf.push((4).to_byte()) // if
      buf.push((64).to_byte()) // void
      // store: arr[8 + i*4] = map[8 + i*8 + 4] (value at offset +4 from key)
      emit_local_get(buf, arr_ptr)
      emit_local_get(buf, loop_i)
      emit_i32_const_raw(buf, 4)
      emit_i32_mul(buf)
      emit_i32_add(buf)
      emit_local_get(buf, map_ptr)
      emit_local_get(buf, loop_i)
      emit_i32_const_raw(buf, 8)
      emit_i32_mul(buf)
      emit_i32_add(buf)
      emit_i32_load(buf, 12) // value at key_offset + 4
      emit_i32_store(buf, 8)
      emit_local_get(buf, loop_i)
      emit_i32_const_raw(buf, 1)
      emit_i32_add(buf)
      emit_local_set(buf, loop_i)
      buf.push((12).to_byte()) // br
      write_u32_leb(buf, 0) // to loop
      buf.push((11).to_byte()) // end if
      buf.push((11).to_byte()) // end loop
      emit_local_get(buf, arr_ptr)
      emit_i64_extend_i32_u(buf)
      emit_i64_const_raw(buf, tag_obj.to_int64())
      emit_i64_or(buf)
    }
    "array_length" => {
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
    }
    "array_get" | "__index" => {
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
    }
    "map_get" => {
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
          let key_local = alloc_temp_local_with_kind(ctx, ValueKind::ExternRef)
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
    }
    "sleep" => {
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
    }
    "stdout_write_char" => {
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
    }
    "stdout_write_stream" => {
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
    }
    "stdin_read_char" => {
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
    }
    "stdin_read_stream" => {
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
    }
    "fs_exists" => {
      if ctx.use_js_strings {
        raise WasmGenError::Unsupported("fs_exists requires --wasm backend")
      }
      let pos_args = extract_positional_exprs(args, "fs_exists")
      if pos_args.length() != 1 {
        raise WasmGenError::Unsupported("fs_exists arity")
      }
      require_heap(ctx)
      let raw_local = alloc_temp_local(ctx)
      let len_local = alloc_temp_local(ctx)
      let ret_area_local = alloc_temp_local(ctx)
      let root_desc_local = alloc_temp_local(ctx)
      let fs_global = fs_root_descriptor_global_index(ctx)
      // Initialize root descriptor if needed
      emit_global_get(buf, fs_global)
      emit_i32_const_raw(buf, -1)
      emit_i32_eq(buf)
      buf.push((4).to_byte()) // if
      buf.push((64).to_byte()) // void
      emit_heap_alloc(ctx, buf, align4(16), ret_area_local)
      emit_local_get(buf, ret_area_local)
      emit_call(buf, import_index_fs_get_directories(ctx))
      // Load first descriptor from list: retptr[0]=list_ptr, retptr[4]=list_len
      emit_local_get(buf, ret_area_local)
      emit_i32_load(buf, 0)
      emit_i32_load(buf, 0) // first entry: descriptor handle at [list_ptr+0]
      emit_global_set(buf, fs_global)
      buf.push((11).to_byte()) // end if
      emit_global_get(buf, fs_global)
      emit_local_set(buf, root_desc_local)
      // Extract path string: raw_ptr, len
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_i64_const_raw(buf, (-4).to_int64())
      emit_i64_and(buf)
      emit_i32_wrap_i64(buf)
      emit_local_set(buf, raw_local)
      emit_local_get(buf, raw_local)
      emit_i32_load(buf, 4) // len
      emit_local_set(buf, len_local)
      // Allocate retptr for stat-at result (needs ~96 bytes)
      emit_heap_alloc(ctx, buf, align4(96), ret_area_local)
      // Sync heap before WASI call
      if ctx.heap_local >= 0 && ctx.use_heap_global {
        emit_local_get(buf, ctx.heap_local)
        emit_global_set(buf, ctx.heap_global)
      }
      // stat-at(root_desc, 0, path_ptr, path_len, retptr)
      emit_local_get(buf, root_desc_local)
      emit_i32_const_raw(buf, 0) // path-flags: no symlink follow
      emit_local_get(buf, raw_local)
      emit_i32_const_raw(buf, 8)
      emit_i32_add(buf) // path data ptr
      emit_local_get(buf, len_local)
      emit_local_get(buf, ret_area_local)
      emit_call(buf, import_index_fs_stat_at(ctx))
      // Reload heap after WASI call
      if ctx.heap_local >= 0 && ctx.use_heap_global {
        emit_global_get(buf, ctx.heap_global)
        emit_local_set(buf, ctx.heap_local)
      }
      // Check discriminant: 0=ok (exists), 1=err (not exists)
      emit_local_get(buf, ret_area_local)
      emit_i32_load8_u(buf, 0)
      emit_i32_eqz(buf) // 0 means ok -> true
      buf.push((4).to_byte()) // if
      buf.push((126).to_byte()) // result i64
      emit_i64_const_raw(buf, tag_int_value64(1L)) // true
      buf.push((5).to_byte()) // else
      emit_i64_const_raw(buf, tag_int_value64(0L)) // false
      buf.push((11).to_byte()) // end if
    }
    "fs_read_file" => {
      if ctx.use_js_strings {
        raise WasmGenError::Unsupported("fs_read_file requires --wasm backend")
      }
      let pos_args = extract_positional_exprs(args, "fs_read_file")
      if pos_args.length() != 1 {
        raise WasmGenError::Unsupported("fs_read_file arity")
      }
      require_heap(ctx)
      let raw_local = alloc_temp_local(ctx)
      let len_local = alloc_temp_local(ctx)
      let ret_area_local = alloc_temp_local(ctx)
      let root_desc_local = alloc_temp_local(ctx)
      let opened_desc_local = alloc_temp_local(ctx)
      let data_ptr_local = alloc_temp_local(ctx)
      let data_len_local = alloc_temp_local(ctx)
      let obj_local = alloc_temp_local(ctx)
      let copy_i_local = alloc_temp_local(ctx)
      let alloc_size_local = alloc_temp_local(ctx)
      let fs_global = fs_root_descriptor_global_index(ctx)
      // Initialize root descriptor if needed
      emit_global_get(buf, fs_global)
      emit_i32_const_raw(buf, -1)
      emit_i32_eq(buf)
      buf.push((4).to_byte()) // if
      buf.push((64).to_byte()) // void
      emit_heap_alloc(ctx, buf, align4(16), ret_area_local)
      emit_local_get(buf, ret_area_local)
      emit_call(buf, import_index_fs_get_directories(ctx))
      emit_local_get(buf, ret_area_local)
      emit_i32_load(buf, 0)
      emit_i32_load(buf, 0)
      emit_global_set(buf, fs_global)
      buf.push((11).to_byte()) // end if
      emit_global_get(buf, fs_global)
      emit_local_set(buf, root_desc_local)
      // Extract path string
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_i64_const_raw(buf, (-4).to_int64())
      emit_i64_and(buf)
      emit_i32_wrap_i64(buf)
      emit_local_set(buf, raw_local)
      emit_local_get(buf, raw_local)
      emit_i32_load(buf, 4) // len
      emit_local_set(buf, len_local)
      // Allocate retptr for open-at result
      emit_heap_alloc(ctx, buf, align4(16), ret_area_local)
      // Sync heap
      if ctx.heap_local >= 0 && ctx.use_heap_global {
        emit_local_get(buf, ctx.heap_local)
        emit_global_set(buf, ctx.heap_global)
      }
      // open-at(root_desc, 0, path_ptr, path_len, 0, 1, retptr)
      // open-flags=0 (none), desc-flags=1 (read)
      emit_local_get(buf, root_desc_local)
      emit_i32_const_raw(buf, 0) // path-flags
      emit_local_get(buf, raw_local)
      emit_i32_const_raw(buf, 8)
      emit_i32_add(buf) // path data ptr
      emit_local_get(buf, len_local)
      emit_i32_const_raw(buf, 0) // open-flags: none
      emit_i32_const_raw(buf, 1) // desc-flags: read
      emit_local_get(buf, ret_area_local)
      emit_call(buf, import_index_fs_open_at(ctx))
      // Reload heap
      if ctx.heap_local >= 0 && ctx.use_heap_global {
        emit_global_get(buf, ctx.heap_global)
        emit_local_set(buf, ctx.heap_local)
      }
      // Check open result: retptr[0] discriminant
      emit_local_get(buf, ret_area_local)
      emit_i32_load8_u(buf, 0)
      emit_i32_eqz(buf)
      buf.push((4).to_byte()) // if (ok)
      buf.push((126).to_byte()) // result i64
      // opened_desc = retptr[4]
      emit_local_get(buf, ret_area_local)
      emit_i32_load(buf, 4)
      emit_local_set(buf, opened_desc_local)
      // Allocate retptr for read result
      emit_heap_alloc(ctx, buf, align4(16), ret_area_local)
      // Sync heap
      if ctx.heap_local >= 0 && ctx.use_heap_global {
        emit_local_get(buf, ctx.heap_local)
        emit_global_set(buf, ctx.heap_global)
      }
      // read(opened_desc, max_len=0x7FFFFFFF, offset=0, retptr)
      emit_local_get(buf, opened_desc_local)
      // i64.const 0x7FFFFFFF (max read length)
      buf.push((66).to_byte())
      write_i64_leb(buf, 0x7FFFFFFFL)
      // i64.const 0 (offset)
      buf.push((66).to_byte())
      buf.push((0).to_byte())
      emit_local_get(buf, ret_area_local)
      emit_call(buf, import_index_fs_read(ctx))
      // Reload heap
      if ctx.heap_local >= 0 && ctx.use_heap_global {
        emit_global_get(buf, ctx.heap_global)
        emit_local_set(buf, ctx.heap_local)
      }
      // resource-drop opened descriptor
      emit_local_get(buf, opened_desc_local)
      emit_call(buf, import_index_fs_resource_drop(ctx))
      // Check read result: retptr[0] discriminant
      emit_local_get(buf, ret_area_local)
      emit_i32_load8_u(buf, 0)
      emit_i32_eqz(buf)
      buf.push((4).to_byte()) // if (ok)
      buf.push((126).to_byte()) // result i64
      // data_ptr = retptr[4], data_len = retptr[8]
      emit_local_get(buf, ret_area_local)
      emit_i32_load(buf, 4)
      emit_local_set(buf, data_ptr_local)
      emit_local_get(buf, ret_area_local)
      emit_i32_load(buf, 8)
      emit_local_set(buf, data_len_local)
      // Allocate vibe string: align4(8 + data_len)
      emit_local_get(buf, data_len_local)
      emit_i32_const_raw(buf, 11) // (len + 8 + 3) & ~3 == (len + 11) & -4
      emit_i32_add(buf)
      emit_i32_const_raw(buf, -4)
      emit_i32_and(buf)
      emit_local_set(buf, alloc_size_local)
      emit_heap_alloc_local(ctx, buf, alloc_size_local, obj_local)
      // Write string header
      emit_local_get(buf, obj_local)
      emit_i32_const_raw(buf, obj_string) // tag = obj_string
      emit_i32_store(buf, 0)
      emit_local_get(buf, obj_local)
      emit_local_get(buf, data_len_local)
      emit_i32_store(buf, 4)
      // Copy bytes from data_ptr to obj+8
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
      // Return tagged string pointer
      emit_local_get(buf, obj_local)
      emit_i64_extend_i32_u(buf)
      emit_i64_const_raw(buf, tag_obj.to_int64())
      emit_i64_or(buf)
      buf.push((5).to_byte()) // else (read error)
      // Return empty string on read error
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
      buf.push((11).to_byte()) // end if (read)
      buf.push((5).to_byte()) // else (open error)
      // Return empty string on open error
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
      buf.push((11).to_byte()) // end if (open)
    }
    "fs_write_file" => {
      if ctx.use_js_strings {
        raise WasmGenError::Unsupported("fs_write_file requires --wasm backend")
      }
      let pos_args = extract_positional_exprs(args, "fs_write_file")
      if pos_args.length() != 2 {
        raise WasmGenError::Unsupported("fs_write_file arity")
      }
      require_heap(ctx)
      let path_raw_local = alloc_temp_local(ctx)
      let path_len_local = alloc_temp_local(ctx)
      let content_raw_local = alloc_temp_local(ctx)
      let content_len_local = alloc_temp_local(ctx)
      let ret_area_local = alloc_temp_local(ctx)
      let root_desc_local = alloc_temp_local(ctx)
      let opened_desc_local = alloc_temp_local(ctx)
      let fs_global = fs_root_descriptor_global_index(ctx)
      // Initialize root descriptor if needed
      emit_global_get(buf, fs_global)
      emit_i32_const_raw(buf, -1)
      emit_i32_eq(buf)
      buf.push((4).to_byte()) // if
      buf.push((64).to_byte()) // void
      emit_heap_alloc(ctx, buf, align4(16), ret_area_local)
      emit_local_get(buf, ret_area_local)
      emit_call(buf, import_index_fs_get_directories(ctx))
      emit_local_get(buf, ret_area_local)
      emit_i32_load(buf, 0)
      emit_i32_load(buf, 0)
      emit_global_set(buf, fs_global)
      buf.push((11).to_byte()) // end if
      emit_global_get(buf, fs_global)
      emit_local_set(buf, root_desc_local)
      // Extract path string
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_i64_const_raw(buf, (-4).to_int64())
      emit_i64_and(buf)
      emit_i32_wrap_i64(buf)
      emit_local_set(buf, path_raw_local)
      emit_local_get(buf, path_raw_local)
      emit_i32_load(buf, 4)
      emit_local_set(buf, path_len_local)
      // Extract content string
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_i64_const_raw(buf, (-4).to_int64())
      emit_i64_and(buf)
      emit_i32_wrap_i64(buf)
      emit_local_set(buf, content_raw_local)
      emit_local_get(buf, content_raw_local)
      emit_i32_load(buf, 4)
      emit_local_set(buf, content_len_local)
      // Allocate retptr for open-at result
      emit_heap_alloc(ctx, buf, align4(16), ret_area_local)
      // Sync heap
      if ctx.heap_local >= 0 && ctx.use_heap_global {
        emit_local_get(buf, ctx.heap_local)
        emit_global_set(buf, ctx.heap_global)
      }
      // open-at(root_desc, 0, path_ptr, path_len, 5, 2, retptr)
      // open-flags=5 (create|truncate), desc-flags=2 (write)
      emit_local_get(buf, root_desc_local)
      emit_i32_const_raw(buf, 0) // path-flags
      emit_local_get(buf, path_raw_local)
      emit_i32_const_raw(buf, 8)
      emit_i32_add(buf) // path data ptr
      emit_local_get(buf, path_len_local)
      emit_i32_const_raw(buf, 5) // open-flags: create(1) | truncate(4) = 5
      emit_i32_const_raw(buf, 2) // desc-flags: write(2)
      emit_local_get(buf, ret_area_local)
      emit_call(buf, import_index_fs_open_at(ctx))
      // Reload heap
      if ctx.heap_local >= 0 && ctx.use_heap_global {
        emit_global_get(buf, ctx.heap_global)
        emit_local_set(buf, ctx.heap_local)
      }
      // Check open result
      emit_local_get(buf, ret_area_local)
      emit_i32_load8_u(buf, 0)
      emit_i32_eqz(buf)
      buf.push((4).to_byte()) // if (ok)
      buf.push((126).to_byte()) // result i64
      // opened_desc = retptr[4]
      emit_local_get(buf, ret_area_local)
      emit_i32_load(buf, 4)
      emit_local_set(buf, opened_desc_local)
      // Allocate retptr for write result
      emit_heap_alloc(ctx, buf, align4(16), ret_area_local)
      // Sync heap
      if ctx.heap_local >= 0 && ctx.use_heap_global {
        emit_local_get(buf, ctx.heap_local)
        emit_global_set(buf, ctx.heap_global)
      }
      // write(opened_desc, content_data_ptr, content_len, offset=0, retptr)
      emit_local_get(buf, opened_desc_local)
      emit_local_get(buf, content_raw_local)
      emit_i32_const_raw(buf, 8)
      emit_i32_add(buf) // content data ptr
      emit_local_get(buf, content_len_local)
      // i64.const 0 (offset)
      buf.push((66).to_byte())
      buf.push((0).to_byte())
      emit_local_get(buf, ret_area_local)
      emit_call(buf, import_index_fs_write(ctx))
      // Reload heap
      if ctx.heap_local >= 0 && ctx.use_heap_global {
        emit_global_get(buf, ctx.heap_global)
        emit_local_set(buf, ctx.heap_local)
      }
      // resource-drop opened descriptor
      emit_local_get(buf, opened_desc_local)
      emit_call(buf, import_index_fs_resource_drop(ctx))
      // Return Unit
      emit_i64_const_raw(buf, tag_int_value64(0L))
      buf.push((5).to_byte()) // else (open error)
      emit_i64_const_raw(buf, tag_int_value64(0L))
      buf.push((11).to_byte()) // end if
    }
    "socket_tcp_connect" => {
      if ctx.use_js_strings {
        raise WasmGenError::Unsupported(
          "socket_tcp_connect requires --wasm backend",
        )
      }
      let pos_args = extract_positional_exprs(args, "socket_tcp_connect")
      if pos_args.length() != 2 {
        raise WasmGenError::Unsupported("socket_tcp_connect arity")
      }
      require_heap(ctx)
      let host_raw_local = alloc_temp_local(ctx)
      let host_len_local = alloc_temp_local(ctx)
      let ret_area_local = alloc_temp_local(ctx)
      let network_local = alloc_temp_local(ctx)
      let socket_local = alloc_temp_local(ctx)
      let pollable_local = alloc_temp_local(ctx)
      let input_stream_local = alloc_temp_local(ctx)
      let output_stream_local = alloc_temp_local(ctx)
      let port_local = alloc_temp_local(ctx)
      let table_base_local = alloc_temp_local(ctx)
      let slot_local = alloc_temp_local(ctx)
      let a_local = alloc_temp_local(ctx)
      let b_local = alloc_temp_local(ctx)
      let c_local = alloc_temp_local(ctx)
      let d_local = alloc_temp_local(ctx)
      let i_local = alloc_temp_local(ctx)
      let acc_local = alloc_temp_local(ctx)
      let sock_global = socket_table_global_index(ctx)
      // Extract host string
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_i64_const_raw(buf, (-4).to_int64())
      emit_i64_and(buf)
      emit_i32_wrap_i64(buf)
      emit_local_set(buf, host_raw_local)
      emit_local_get(buf, host_raw_local)
      emit_i32_load(buf, 4) // len
      emit_local_set(buf, host_len_local)
      // Extract port (untag)
      compile_expr(ctx, buf, pos_args[1])
      emit_i64_const_raw(buf, 2L)
      emit_i64_shr_s(buf)
      emit_i32_wrap_i64(buf)
      emit_local_set(buf, port_local)
      // Parse IPv4 address: host bytes -> a.b.c.d
      // Initialize accumulators
      emit_i32_const_raw(buf, 0)
      emit_local_set(buf, a_local)
      emit_i32_const_raw(buf, 0)
      emit_local_set(buf, b_local)
      emit_i32_const_raw(buf, 0)
      emit_local_set(buf, c_local)
      emit_i32_const_raw(buf, 0)
      emit_local_set(buf, d_local)
      emit_i32_const_raw(buf, 0)
      emit_local_set(buf, acc_local)
      emit_i32_const_raw(buf, 0) // octet_index
      emit_local_set(buf, slot_local)
      emit_i32_const_raw(buf, 0)
      emit_local_set(buf, i_local)
      // Loop over host bytes
      emit_block(buf)
      emit_loop(buf)
      emit_local_get(buf, i_local)
      emit_local_get(buf, host_len_local)
      emit_i32_ge_s(buf)
      emit_br_if(buf, 1) // break if i >= len
      // Load byte
      emit_local_get(buf, host_raw_local)
      emit_local_get(buf, i_local)
      emit_i32_add(buf)
      emit_i32_load8_u(buf, 8) // +8 for string data offset
      // Check if '.' (0x2E)
      emit_i32_const_raw(buf, 0x2E)
      emit_i32_eq(buf)
      buf.push((4).to_byte()) // if (is dot)
      buf.push((64).to_byte()) // void
      // Store acc into current octet, advance
      emit_local_get(buf, slot_local)
      emit_i32_eqz(buf)
      buf.push((4).to_byte()) // if slot==0
      buf.push((64).to_byte())
      emit_local_get(buf, acc_local)
      emit_local_set(buf, a_local)
      buf.push((5).to_byte()) // else
      emit_local_get(buf, slot_local)
      emit_i32_const_raw(buf, 1)
      emit_i32_eq(buf)
      buf.push((4).to_byte()) // if slot==1
      buf.push((64).to_byte())
      emit_local_get(buf, acc_local)
      emit_local_set(buf, b_local)
      buf.push((5).to_byte()) // else
      emit_local_get(buf, acc_local)
      emit_local_set(buf, c_local)
      buf.push((11).to_byte()) // end if slot==1
      buf.push((11).to_byte()) // end if slot==0
      emit_i32_const_raw(buf, 0)
      emit_local_set(buf, acc_local)
      emit_local_get(buf, slot_local)
      emit_i32_const_raw(buf, 1)
      emit_i32_add(buf)
      emit_local_set(buf, slot_local)
      buf.push((5).to_byte()) // else (digit)
      // acc = acc * 10 + (byte - '0')
      emit_local_get(buf, acc_local)
      emit_i32_const_raw(buf, 10)
      emit_i32_mul(buf)
      emit_local_get(buf, host_raw_local)
      emit_local_get(buf, i_local)
      emit_i32_add(buf)
      emit_i32_load8_u(buf, 8) // +8 for string data offset
      emit_i32_const_raw(buf, 0x30) // '0'
      emit_i32_sub(buf)
      emit_i32_add(buf)
      emit_local_set(buf, acc_local)
      buf.push((11).to_byte()) // end if (dot/digit)
      // i++
      emit_local_get(buf, i_local)
      emit_i32_const_raw(buf, 1)
      emit_i32_add(buf)
      emit_local_set(buf, i_local)
      emit_br(buf, 0) // continue loop
      emit_end(buf) // end loop
      emit_end(buf) // end block
      // Last octet
      emit_local_get(buf, acc_local)
      emit_local_set(buf, d_local)
      // Allocate connection table if not yet done (256 bytes for 16 entries)
      emit_global_get(buf, sock_global)
      emit_i32_eqz(buf)
      buf.push((4).to_byte()) // if (table not allocated)
      buf.push((64).to_byte())
      emit_heap_alloc(ctx, buf, 256, table_base_local)
      emit_local_get(buf, table_base_local)
      emit_global_set(buf, sock_global)
      buf.push((11).to_byte()) // end if
      emit_global_get(buf, sock_global)
      emit_local_set(buf, table_base_local)
      // Allocate retptr (16 bytes)
      emit_heap_alloc(ctx, buf, align4(16), ret_area_local)
      // Sync heap before WASI calls
      if ctx.heap_local >= 0 && ctx.use_heap_global {
        emit_local_get(buf, ctx.heap_local)
        emit_global_set(buf, ctx.heap_global)
      }
      // 1. instance-network() -> network
      emit_call(buf, import_index_socket_instance_network(ctx))
      emit_local_set(buf, network_local)
      // 2. create-tcp-socket(family=0 IPv4, retptr)
      emit_i32_const_raw(buf, 0) // IPv4
      emit_local_get(buf, ret_area_local)
      emit_call(buf, import_index_socket_create_tcp(ctx))
      emit_local_get(buf, ret_area_local)
      emit_i32_load(buf, 0) // discriminant
      emit_i32_eqz(buf)
      buf.push((4).to_byte()) // if ok
      buf.push((126).to_byte()) // result i64
      emit_local_get(buf, ret_area_local)
      emit_i32_load(buf, 4) // socket handle
      emit_local_set(buf, socket_local)
      // 3. start-connect(self, network, disc=0, port, a, b, c, d, 0,0,0,0,0,0, retptr)
      emit_local_get(buf, socket_local)
      emit_local_get(buf, network_local)
      emit_i32_const_raw(buf, 0) // disc: IPv4
      emit_local_get(buf, port_local)
      emit_local_get(buf, a_local)
      emit_local_get(buf, b_local)
      emit_local_get(buf, c_local)
      emit_local_get(buf, d_local)
      emit_i32_const_raw(buf, 0) // padding
      emit_i32_const_raw(buf, 0)
      emit_i32_const_raw(buf, 0)
      emit_i32_const_raw(buf, 0)
      emit_i32_const_raw(buf, 0)
      emit_i32_const_raw(buf, 0)
      emit_local_get(buf, ret_area_local)
      emit_call(buf, import_index_socket_start_connect(ctx))
      // 4. subscribe(socket) -> pollable
      emit_local_get(buf, socket_local)
      emit_call(buf, import_index_socket_subscribe(ctx))
      emit_local_set(buf, pollable_local)
      // 5. poll([pollable], 1, retptr) - write pollable handle to retptr area
      emit_local_get(buf, ret_area_local)
      emit_local_get(buf, pollable_local)
      emit_i32_store(buf, 0)
      emit_local_get(buf, ret_area_local) // list_ptr
      emit_i32_const_raw(buf, 1) // list_len
      emit_local_get(buf, ret_area_local)
      emit_i32_const_raw(buf, 8)
      emit_i32_add(buf) // retptr (offset by 8 to avoid clobbering list)
      emit_call(buf, import_index_socket_poll(ctx))
      // 6. resource-drop pollable
      emit_local_get(buf, pollable_local)
      emit_call(buf, import_index_socket_drop_pollable(ctx))
      // 7. finish-connect(socket, retptr)
      emit_local_get(buf, socket_local)
      emit_local_get(buf, ret_area_local)
      emit_call(buf, import_index_socket_finish_connect(ctx))
      // Reload heap after WASI calls
      if ctx.heap_local >= 0 && ctx.use_heap_global {
        emit_global_get(buf, ctx.heap_global)
        emit_local_set(buf, ctx.heap_local)
      }
      // Check finish-connect result
      emit_local_get(buf, ret_area_local)
      emit_i32_load(buf, 0) // discriminant
      emit_i32_eqz(buf)
      buf.push((4).to_byte()) // if ok
      buf.push((126).to_byte()) // result i64
      // input_stream = retptr[4], output_stream = retptr[8]
      emit_local_get(buf, ret_area_local)
      emit_i32_load(buf, 4)
      emit_local_set(buf, input_stream_local)
      emit_local_get(buf, ret_area_local)
      emit_i32_load(buf, 8)
      emit_local_set(buf, output_stream_local)
      // Find free slot in connection table
      emit_i32_const_raw(buf, 0)
      emit_local_set(buf, slot_local)
      emit_block(buf)
      emit_loop(buf)
      emit_local_get(buf, slot_local)
      emit_i32_const_raw(buf, 16)
      emit_i32_ge_s(buf)
      emit_br_if(buf, 1) // break if slot >= 16
      // Check in_use flag: table_base + slot*16 + 12
      emit_local_get(buf, table_base_local)
      emit_local_get(buf, slot_local)
      emit_i32_const_raw(buf, 16)
      emit_i32_mul(buf)
      emit_i32_add(buf)
      emit_i32_load(buf, 12) // in_use
      emit_i32_eqz(buf)
      emit_br_if(buf, 1) // break if in_use == 0
      emit_local_get(buf, slot_local)
      emit_i32_const_raw(buf, 1)
      emit_i32_add(buf)
      emit_local_set(buf, slot_local)
      emit_br(buf, 0) // continue
      emit_end(buf) // end loop
      emit_end(buf) // end block
      // Store entry: [socket, input_stream, output_stream, 1]
      // entry_addr = table_base + slot * 16
      emit_local_get(buf, table_base_local)
      emit_local_get(buf, slot_local)
      emit_i32_const_raw(buf, 16)
      emit_i32_mul(buf)
      emit_i32_add(buf)
      emit_local_set(buf, ret_area_local) // reuse as entry_addr
      emit_local_get(buf, ret_area_local)
      emit_local_get(buf, socket_local)
      emit_i32_store(buf, 0)
      emit_local_get(buf, ret_area_local)
      emit_local_get(buf, input_stream_local)
      emit_i32_store(buf, 4)
      emit_local_get(buf, ret_area_local)
      emit_local_get(buf, output_stream_local)
      emit_i32_store(buf, 8)
      emit_local_get(buf, ret_area_local)
      emit_i32_const_raw(buf, 1)
      emit_i32_store(buf, 12) // in_use = 1
      // Return slot as tagged int
      emit_local_get(buf, slot_local)
      emit_i64_extend_i32_u(buf)
      emit_i64_const_raw(buf, 2L)
      emit_i64_shl(buf)
      buf.push((5).to_byte()) // else (finish-connect failed)
      emit_i64_const_raw(buf, tag_int_value64(-1L))
      buf.push((11).to_byte()) // end if (finish-connect)
      buf.push((5).to_byte()) // else (create-tcp-socket failed)
      emit_i64_const_raw(buf, tag_int_value64(-1L))
      buf.push((11).to_byte()) // end if (create-tcp-socket)
    }
    "socket_tcp_read" => {
      if ctx.use_js_strings {
        raise WasmGenError::Unsupported(
          "socket_tcp_read requires --wasm backend",
        )
      }
      let pos_args = extract_positional_exprs(args, "socket_tcp_read")
      if pos_args.length() != 2 {
        raise WasmGenError::Unsupported("socket_tcp_read arity")
      }
      require_heap(ctx)
      let handle_local = alloc_temp_local(ctx)
      let max_bytes_local = alloc_temp_local(ctx)
      let table_base_local = alloc_temp_local(ctx)
      let entry_addr_local = alloc_temp_local(ctx)
      let input_stream_local = alloc_temp_local(ctx)
      let ret_area_local = alloc_temp_local(ctx)
      let data_ptr_local = alloc_temp_local(ctx)
      let data_len_local = alloc_temp_local(ctx)
      let obj_local = alloc_temp_local(ctx)
      let copy_i_local = alloc_temp_local(ctx)
      let alloc_size_local = alloc_temp_local(ctx)
      let sock_global = socket_table_global_index(ctx)
      // Extract handle (untag)
      compile_expr(ctx, buf, pos_args[0])
      emit_i64_const_raw(buf, 2L)
      emit_i64_shr_s(buf)
      emit_i32_wrap_i64(buf)
      emit_local_set(buf, handle_local)
      // Extract max_bytes (untag)
      compile_expr(ctx, buf, pos_args[1])
      emit_i64_const_raw(buf, 2L)
      emit_i64_shr_s(buf)
      emit_i32_wrap_i64(buf)
      emit_local_set(buf, max_bytes_local)
      // Load table base
      emit_global_get(buf, sock_global)
      emit_local_set(buf, table_base_local)
      // entry_addr = table_base + handle * 16
      emit_local_get(buf, table_base_local)
      emit_local_get(buf, handle_local)
      emit_i32_const_raw(buf, 16)
      emit_i32_mul(buf)
      emit_i32_add(buf)
      emit_local_set(buf, entry_addr_local)
      // input_stream = entry[4]
      emit_local_get(buf, entry_addr_local)
      emit_i32_load(buf, 4)
      emit_local_set(buf, input_stream_local)
      // Allocate retptr
      emit_heap_alloc(ctx, buf, align4(16), ret_area_local)
      // Sync heap
      if ctx.heap_local >= 0 && ctx.use_heap_global {
        emit_local_get(buf, ctx.heap_local)
        emit_global_set(buf, ctx.heap_global)
      }
      // blocking-read(input_stream, max_bytes as i64, retptr)
      emit_local_get(buf, input_stream_local)
      emit_local_get(buf, max_bytes_local)
      emit_i64_extend_i32_u(buf) // convert to i64
      emit_local_get(buf, ret_area_local)
      emit_call(buf, import_index_socket_stream_read(ctx))
      // Reload heap
      if ctx.heap_local >= 0 && ctx.use_heap_global {
        emit_global_get(buf, ctx.heap_global)
        emit_local_set(buf, ctx.heap_local)
      }
      // Check result: retptr[0] discriminant
      emit_local_get(buf, ret_area_local)
      emit_i32_load8_u(buf, 0)
      emit_i32_eqz(buf)
      buf.push((4).to_byte()) // if ok
      buf.push((126).to_byte()) // result i64
      // data_ptr = retptr[4], data_len = retptr[8]
      emit_local_get(buf, ret_area_local)
      emit_i32_load(buf, 4)
      emit_local_set(buf, data_ptr_local)
      emit_local_get(buf, ret_area_local)
      emit_i32_load(buf, 8)
      emit_local_set(buf, data_len_local)
      // Allocate vibe string: align4(8 + data_len)
      emit_local_get(buf, data_len_local)
      emit_i32_const_raw(buf, 11)
      emit_i32_add(buf)
      emit_i32_const_raw(buf, -4)
      emit_i32_and(buf)
      emit_local_set(buf, alloc_size_local)
      emit_heap_alloc_local(ctx, buf, alloc_size_local, obj_local)
      // Write string header
      emit_local_get(buf, obj_local)
      emit_i32_const_raw(buf, obj_string)
      emit_i32_store(buf, 0)
      emit_local_get(buf, obj_local)
      emit_local_get(buf, data_len_local)
      emit_i32_store(buf, 4)
      // Copy bytes
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
      emit_end(buf) // end loop
      emit_end(buf) // end block
      // Return tagged string pointer
      emit_local_get(buf, obj_local)
      emit_i64_extend_i32_u(buf)
      emit_i64_const_raw(buf, tag_obj.to_int64())
      emit_i64_or(buf)
      buf.push((5).to_byte()) // else (read error)
      // Return empty string on error
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
    }
    "socket_tcp_write" => {
      if ctx.use_js_strings {
        raise WasmGenError::Unsupported(
          "socket_tcp_write requires --wasm backend",
        )
      }
      let pos_args = extract_positional_exprs(args, "socket_tcp_write")
      if pos_args.length() != 2 {
        raise WasmGenError::Unsupported("socket_tcp_write arity")
      }
      require_heap(ctx)
      let handle_local = alloc_temp_local(ctx)
      let data_raw_local = alloc_temp_local(ctx)
      let data_len_local = alloc_temp_local(ctx)
      let table_base_local = alloc_temp_local(ctx)
      let entry_addr_local = alloc_temp_local(ctx)
      let output_stream_local = alloc_temp_local(ctx)
      let ret_area_local = alloc_temp_local(ctx)
      let sock_global = socket_table_global_index(ctx)
      // Extract handle (untag)
      compile_expr(ctx, buf, pos_args[0])
      emit_i64_const_raw(buf, 2L)
      emit_i64_shr_s(buf)
      emit_i32_wrap_i64(buf)
      emit_local_set(buf, handle_local)
      // Extract data string
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_i64_const_raw(buf, (-4).to_int64())
      emit_i64_and(buf)
      emit_i32_wrap_i64(buf)
      emit_local_set(buf, data_raw_local)
      emit_local_get(buf, data_raw_local)
      emit_i32_load(buf, 4) // len
      emit_local_set(buf, data_len_local)
      // Load table base
      emit_global_get(buf, sock_global)
      emit_local_set(buf, table_base_local)
      // entry_addr = table_base + handle * 16
      emit_local_get(buf, table_base_local)
      emit_local_get(buf, handle_local)
      emit_i32_const_raw(buf, 16)
      emit_i32_mul(buf)
      emit_i32_add(buf)
      emit_local_set(buf, entry_addr_local)
      // output_stream = entry[8]
      emit_local_get(buf, entry_addr_local)
      emit_i32_load(buf, 8)
      emit_local_set(buf, output_stream_local)
      // Allocate retptr
      emit_heap_alloc(ctx, buf, align4(16), ret_area_local)
      // Sync heap
      if ctx.heap_local >= 0 && ctx.use_heap_global {
        emit_local_get(buf, ctx.heap_local)
        emit_global_set(buf, ctx.heap_global)
      }
      // blocking-write-and-flush(output_stream, data_ptr+8, data_len, retptr)
      emit_local_get(buf, output_stream_local)
      emit_local_get(buf, data_raw_local)
      emit_i32_const_raw(buf, 8)
      emit_i32_add(buf) // data ptr
      emit_local_get(buf, data_len_local)
      emit_local_get(buf, ret_area_local)
      emit_call(buf, import_index_socket_stream_write(ctx))
      // Reload heap
      if ctx.heap_local >= 0 && ctx.use_heap_global {
        emit_global_get(buf, ctx.heap_global)
        emit_local_set(buf, ctx.heap_local)
      }
      // Return Unit (tagged 0)
      emit_i64_const_raw(buf, tag_int_value64(0L))
    }
    "socket_tcp_close" => {
      if ctx.use_js_strings {
        raise WasmGenError::Unsupported(
          "socket_tcp_close requires --wasm backend",
        )
      }
      let pos_args = extract_positional_exprs(args, "socket_tcp_close")
      if pos_args.length() != 1 {
        raise WasmGenError::Unsupported("socket_tcp_close arity")
      }
      require_heap(ctx)
      let handle_local = alloc_temp_local(ctx)
      let table_base_local = alloc_temp_local(ctx)
      let entry_addr_local = alloc_temp_local(ctx)
      let socket_local = alloc_temp_local(ctx)
      let input_stream_local = alloc_temp_local(ctx)
      let output_stream_local = alloc_temp_local(ctx)
      let ret_area_local = alloc_temp_local(ctx)
      let sock_global = socket_table_global_index(ctx)
      // Extract handle (untag)
      compile_expr(ctx, buf, pos_args[0])
      emit_i64_const_raw(buf, 2L)
      emit_i64_shr_s(buf)
      emit_i32_wrap_i64(buf)
      emit_local_set(buf, handle_local)
      // Load table base
      emit_global_get(buf, sock_global)
      emit_local_set(buf, table_base_local)
      // entry_addr = table_base + handle * 16
      emit_local_get(buf, table_base_local)
      emit_local_get(buf, handle_local)
      emit_i32_const_raw(buf, 16)
      emit_i32_mul(buf)
      emit_i32_add(buf)
      emit_local_set(buf, entry_addr_local)
      // Load 3 handles
      emit_local_get(buf, entry_addr_local)
      emit_i32_load(buf, 0)
      emit_local_set(buf, socket_local)
      emit_local_get(buf, entry_addr_local)
      emit_i32_load(buf, 4)
      emit_local_set(buf, input_stream_local)
      emit_local_get(buf, entry_addr_local)
      emit_i32_load(buf, 8)
      emit_local_set(buf, output_stream_local)
      // Allocate retptr for shutdown
      emit_heap_alloc(ctx, buf, align4(16), ret_area_local)
      // shutdown(socket, 2=both, retptr)
      emit_local_get(buf, socket_local)
      emit_i32_const_raw(buf, 2) // both
      emit_local_get(buf, ret_area_local)
      emit_call(buf, import_index_socket_shutdown(ctx))
      // resource-drop input-stream
      emit_local_get(buf, input_stream_local)
      emit_call(buf, import_index_socket_drop_input(ctx))
      // resource-drop output-stream
      emit_local_get(buf, output_stream_local)
      emit_call(buf, import_index_socket_drop_output(ctx))
      // resource-drop tcp-socket
      emit_local_get(buf, socket_local)
      emit_call(buf, import_index_socket_drop_tcp(ctx))
      // Mark entry as free: in_use = 0
      emit_local_get(buf, entry_addr_local)
      emit_i32_const_raw(buf, 0)
      emit_i32_store(buf, 12) // in_use = 0
      // Return Unit (tagged 0)
      emit_i64_const_raw(buf, tag_int_value64(0L))
    }
    // --- HTTP builtins (P3 draft — raise error, interpreter-only for now) ---
    "http_request"
    | "http_response_status"
    | "http_response_header"
    | "http_response_body"
    | "http_close"
    | "http_listen"
    | "http_accept"
    | "http_request_method"
    | "http_request_url"
    | "http_request_header"
    | "http_request_body"
    | "http_respond" => {
      // WASI P3 HTTP is draft; emit raise with error message instead of
      // unreachable trap so the error is catchable by try/catch.
      let msg = name + " is not available on wasm target"
      if not(ctx.use_js_strings) && not(ctx.embed_error_strings) {
        emit_i64_const_tagged(buf, intern_error_code(ctx, msg).to_int64())
      } else if ctx.use_js_strings {
        emit_string_const(ctx, buf, msg)
      } else {
        emit_string_const(ctx, buf, msg)
      }
      buf.push((8).to_byte()) // throw
      write_u32_leb(buf, ctx.error_tag_index)
    }
    "char_to_int" => {
      let pos_args = extract_positional_exprs(args, "char_to_int")
      if pos_args.length() != 1 {
        raise WasmGenError::Unsupported("char_to_int arity")
      }
      compile_expr(ctx, buf, pos_args[0])
    }
    "char_from_int" => {
      let pos_args = extract_positional_exprs(args, "char_from_int")
      if pos_args.length() != 1 {
        raise WasmGenError::Unsupported("char_from_int arity")
      }
      compile_expr(ctx, buf, pos_args[0])
    }
    "string_from_char_code" => {
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
    }
    _ if is_user_fn => {
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
    "path_ref" => {
      // path_ref(s) -> same as path(s), calls the host import vibe.path
      let pos_args = extract_positional_exprs(args, "path_ref")
      if pos_args.length() != 1 {
        raise WasmGenError::Unsupported("path_ref arity")
      }
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_call(buf, import_index_path(ctx))
    }
    "dynamic_path_resolve" => {
      // dynamic_path_resolve(s) -> host import vibe.resolve_path
      let pos_args = extract_positional_exprs(args, "dynamic_path_resolve")
      if pos_args.length() != 1 {
        raise WasmGenError::Unsupported("dynamic_path_resolve arity")
      }
      compile_expr(ctx, buf, pos_args[0])
      emit_call(buf, import_index_dynamic_path_resolve(ctx))
    }
    "path_is_absolute" => {
      // path_is_absolute(path) -> check if first byte is '/'
      // In wasm, Path and String share the same object representation
      let pos_args = extract_positional_exprs(args, "path_is_absolute")
      if pos_args.length() != 1 {
        raise WasmGenError::Unsupported("path_is_absolute arity")
      }
      let str_ptr_local = alloc_temp_local(ctx)
      let str_len_local = alloc_temp_local(ctx)
      // Untag pointer (Path has same layout as String: tag_obj)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_i64_const_raw(buf, (-4).to_int64())
      emit_i64_and(buf)
      emit_i32_wrap_i64(buf)
      emit_local_set(buf, str_ptr_local)
      // Load string length
      emit_local_get(buf, str_ptr_local)
      emit_i32_load(buf, 4)
      emit_local_set(buf, str_len_local)
      // If length > 0 and first byte == '/' (47), return true
      emit_local_get(buf, str_len_local)
      emit_i32_const_raw(buf, 0)
      emit_i32_gt_s(buf)
      buf.push((4).to_byte()) // if
      buf.push((127).to_byte()) // result i32
      emit_local_get(buf, str_ptr_local)
      emit_i32_load8_u(buf, 8) // first byte at offset 8
      emit_i32_const_raw(buf, 47) // '/'
      emit_i32_eq(buf)
      buf.push((5).to_byte()) // else
      emit_i32_const_raw(buf, 0) // false
      buf.push((11).to_byte()) // end if
      // Tag as bool: 0 or 1 -> tagged
      emit_i64_extend_i32_s(buf)
      emit_i64_const_raw(buf, 2L)
      emit_i64_shl(buf)
      emit_i64_const_raw(buf, tag_int.to_int64())
      emit_i64_or(buf)
    }
    "path_to_string" => {
      // path_to_string(path) -> path is stored as string pointer in wasm, pass through
      let pos_args = extract_positional_exprs(args, "path_to_string")
      if pos_args.length() != 1 {
        raise WasmGenError::Unsupported("path_to_string arity")
      }
      // In wasm, Path and String share the same object representation (string pointer)
      // so path_to_string is identity
      compile_expr(ctx, buf, pos_args[0])
    }
    "string_utf8_length" => {
      // string_utf8_length(s) -> in non-js-string mode, string_length IS utf8 length
      // because strings are stored as UTF-8 bytes
      let pos_args = extract_positional_exprs(args, "string_utf8_length")
      if pos_args.length() != 1 {
        raise WasmGenError::Unsupported("string_utf8_length arity")
      }
      if ctx.use_js_strings {
        // JS strings are UTF-16; need host import for UTF-8 byte counting
        raise WasmGenError::BackendLimit(
          backend="wasm-js-string",
          feature="string_utf8_length",
        )
      } else {
        // Non-js-string: strings are UTF-8, so length field = UTF-8 byte count
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
    }
    "string_utf16_length" | "string_unicode_length" => {
      // In non-js-string mode, strings are UTF-8 bytes.
      // string_utf16_length: count UTF-16 code units from UTF-8
      // string_unicode_length: count Unicode codepoints from UTF-8
      let pos_args = extract_positional_exprs(args, name)
      if pos_args.length() != 1 {
        raise WasmGenError::Unsupported(name + " arity")
      }
      if ctx.use_js_strings {
        raise WasmGenError::BackendLimit(backend="wasm-js-string", feature=name)
      } else {
        let str_ptr_local = alloc_temp_local(ctx)
        let str_len_local = alloc_temp_local(ctx)
        let loop_i_local = alloc_temp_local(ctx)
        let count_local = alloc_temp_local(ctx)
        let byte_local = alloc_temp_local(ctx)
        // Untag string pointer
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_i64_const_raw(buf, (-4).to_int64())
        emit_i64_and(buf)
        emit_i32_wrap_i64(buf)
        emit_local_set(buf, str_ptr_local)
        // Load string byte length
        emit_local_get(buf, str_ptr_local)
        emit_i32_load(buf, 4)
        emit_local_set(buf, str_len_local)
        // Initialize loop variables
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, loop_i_local)
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, count_local)
        // Loop through UTF-8 bytes
        emit_block(buf) // block
        emit_loop(buf) // loop
        // if i >= len: break
        emit_local_get(buf, loop_i_local)
        emit_local_get(buf, str_len_local)
        emit_i32_ge_s(buf)
        emit_br_if(buf, 1) // break to block
        // Load byte at str_ptr + 8 + i
        emit_local_get(buf, str_ptr_local)
        emit_local_get(buf, loop_i_local)
        emit_i32_add(buf)
        emit_i32_load8_u(buf, 8)
        emit_local_set(buf, byte_local)
        // Check byte ranges to determine UTF-8 sequence length
        // if byte >= 0xF0: 4-byte sequence
        emit_local_get(buf, byte_local)
        emit_i32_const_raw(buf, 0xF0)
        emit_i32_ge_s(buf)
        buf.push((4).to_byte()) // if
        buf.push((64).to_byte()) // void
        // 4-byte: i += 4
        emit_local_get(buf, loop_i_local)
        emit_i32_const_raw(buf, 4)
        emit_i32_add(buf)
        emit_local_set(buf, loop_i_local)
        if name == "string_utf16_length" {
          // 4-byte UTF-8 = 2 UTF-16 code units (surrogate pair)
          emit_local_get(buf, count_local)
          emit_i32_const_raw(buf, 2)
          emit_i32_add(buf)
          emit_local_set(buf, count_local)
        } else {
          // unicode_length: 4-byte = 1 codepoint
          emit_local_get(buf, count_local)
          emit_i32_const_raw(buf, 1)
          emit_i32_add(buf)
          emit_local_set(buf, count_local)
        }
        buf.push((5).to_byte()) // else
        // if byte >= 0xE0: 3-byte sequence
        emit_local_get(buf, byte_local)
        emit_i32_const_raw(buf, 0xE0)
        emit_i32_ge_s(buf)
        buf.push((4).to_byte()) // if
        buf.push((64).to_byte()) // void
        emit_local_get(buf, loop_i_local)
        emit_i32_const_raw(buf, 3)
        emit_i32_add(buf)
        emit_local_set(buf, loop_i_local)
        emit_local_get(buf, count_local)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, count_local)
        buf.push((5).to_byte()) // else
        // if byte >= 0xC0: 2-byte sequence
        emit_local_get(buf, byte_local)
        emit_i32_const_raw(buf, 0xC0)
        emit_i32_ge_s(buf)
        buf.push((4).to_byte()) // if
        buf.push((64).to_byte()) // void
        emit_local_get(buf, loop_i_local)
        emit_i32_const_raw(buf, 2)
        emit_i32_add(buf)
        emit_local_set(buf, loop_i_local)
        emit_local_get(buf, count_local)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, count_local)
        buf.push((5).to_byte()) // else
        // 1-byte (ASCII)
        emit_local_get(buf, loop_i_local)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, loop_i_local)
        emit_local_get(buf, count_local)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, count_local)
        buf.push((11).to_byte()) // end if (>= 0xC0)
        buf.push((11).to_byte()) // end if (>= 0xE0)
        buf.push((11).to_byte()) // end if (>= 0xF0)
        emit_br(buf, 0) // continue loop
        emit_end(buf) // end loop
        emit_end(buf) // end block
        // Tag result as int
        emit_local_get(buf, count_local)
        emit_i64_extend_i32_s(buf)
        emit_i64_const_raw(buf, 2L)
        emit_i64_shl(buf)
        emit_i64_const_raw(buf, tag_int.to_int64())
        emit_i64_or(buf)
      }
    }
    "array_concat" => {
      // array_concat(xs, ys) -> new array with all elements from xs then ys
      let pos_args = extract_positional_exprs(args, "array_concat")
      if pos_args.length() != 2 {
        raise WasmGenError::Unsupported("array_concat arity")
      }
      require_heap(ctx)
      let xs_ptr_local = alloc_temp_local(ctx)
      let xs_len_local = alloc_temp_local(ctx)
      let ys_ptr_local = alloc_temp_local(ctx)
      let ys_len_local = alloc_temp_local(ctx)
      let total_len_local = alloc_temp_local(ctx)
      let obj_local = alloc_temp_local(ctx)
      let copy_i_local = alloc_temp_local(ctx)
      let alloc_size_local = alloc_temp_local(ctx)
      // Untag xs pointer
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_i64_const_raw(buf, (-4).to_int64())
      emit_i64_and(buf)
      emit_i32_wrap_i64(buf)
      emit_local_set(buf, xs_ptr_local)
      emit_local_get(buf, xs_ptr_local)
      emit_i32_load(buf, 4)
      emit_local_set(buf, xs_len_local)
      // Untag ys pointer
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_i64_const_raw(buf, (-4).to_int64())
      emit_i64_and(buf)
      emit_i32_wrap_i64(buf)
      emit_local_set(buf, ys_ptr_local)
      emit_local_get(buf, ys_ptr_local)
      emit_i32_load(buf, 4)
      emit_local_set(buf, ys_len_local)
      // total_len = xs_len + ys_len
      emit_local_get(buf, xs_len_local)
      emit_local_get(buf, ys_len_local)
      emit_i32_add(buf)
      emit_local_set(buf, total_len_local)
      // alloc_size = align4(8 + total_len * 4)
      emit_local_get(buf, total_len_local)
      emit_i32_const_raw(buf, 4)
      emit_i32_mul(buf)
      emit_i32_const_raw(buf, 8 + 3)
      emit_i32_add(buf)
      emit_i32_const_raw(buf, -4)
      emit_i32_and(buf)
      emit_local_set(buf, alloc_size_local)
      // Allocate
      emit_heap_alloc_local(ctx, buf, alloc_size_local, obj_local)
      // Set type = obj_array
      emit_local_get(buf, obj_local)
      emit_i32_const_raw(buf, obj_array)
      emit_i32_store(buf, 0)
      // Set length = total_len
      emit_local_get(buf, obj_local)
      emit_local_get(buf, total_len_local)
      emit_i32_store(buf, 4)
      // Copy xs elements: i = 0; i < xs_len; i++
      emit_i32_const_raw(buf, 0)
      emit_local_set(buf, copy_i_local)
      emit_block(buf)
      emit_loop(buf)
      emit_local_get(buf, copy_i_local)
      emit_local_get(buf, xs_len_local)
      emit_i32_lt_s(buf)
      emit_i32_eqz(buf)
      emit_br_if(buf, 1)
      // dst[i] = xs[i]
      emit_local_get(buf, obj_local)
      emit_local_get(buf, copy_i_local)
      emit_i32_const_raw(buf, 4)
      emit_i32_mul(buf)
      emit_i32_add(buf)
      emit_local_get(buf, xs_ptr_local)
      emit_local_get(buf, copy_i_local)
      emit_i32_const_raw(buf, 4)
      emit_i32_mul(buf)
      emit_i32_add(buf)
      emit_i32_load(buf, 8)
      emit_i32_store(buf, 8)
      emit_local_get(buf, copy_i_local)
      emit_i32_const_raw(buf, 1)
      emit_i32_add(buf)
      emit_local_set(buf, copy_i_local)
      emit_br(buf, 0)
      emit_end(buf)
      emit_end(buf)
      // Copy ys elements: i = 0; i < ys_len; i++
      emit_i32_const_raw(buf, 0)
      emit_local_set(buf, copy_i_local)
      emit_block(buf)
      emit_loop(buf)
      emit_local_get(buf, copy_i_local)
      emit_local_get(buf, ys_len_local)
      emit_i32_lt_s(buf)
      emit_i32_eqz(buf)
      emit_br_if(buf, 1)
      // dst[xs_len + i] = ys[i]
      emit_local_get(buf, obj_local)
      emit_local_get(buf, xs_len_local)
      emit_local_get(buf, copy_i_local)
      emit_i32_add(buf)
      emit_i32_const_raw(buf, 4)
      emit_i32_mul(buf)
      emit_i32_add(buf)
      emit_local_get(buf, ys_ptr_local)
      emit_local_get(buf, copy_i_local)
      emit_i32_const_raw(buf, 4)
      emit_i32_mul(buf)
      emit_i32_add(buf)
      emit_i32_load(buf, 8)
      emit_i32_store(buf, 8)
      emit_local_get(buf, copy_i_local)
      emit_i32_const_raw(buf, 1)
      emit_i32_add(buf)
      emit_local_set(buf, copy_i_local)
      emit_br(buf, 0)
      emit_end(buf)
      emit_end(buf)
      // Return tagged pointer
      emit_local_get(buf, obj_local)
      emit_i64_extend_i32_u(buf)
      emit_i64_const_raw(buf, tag_obj.to_int64())
      emit_i64_or(buf)
    }
    "array_slice" => {
      // array_slice(arr, start, end) -> new array with elements arr[start..end]
      let pos_args = extract_positional_exprs(args, "array_slice")
      if pos_args.length() != 3 {
        raise WasmGenError::Unsupported("array_slice arity")
      }
      require_heap(ctx)
      let arr_ptr_local = alloc_temp_local(ctx)
      let arr_len_local = alloc_temp_local(ctx)
      let start_local = alloc_temp_local(ctx)
      let end_local = alloc_temp_local(ctx)
      let slice_len_local = alloc_temp_local(ctx)
      let obj_local = alloc_temp_local(ctx)
      let copy_i_local = alloc_temp_local(ctx)
      let alloc_size_local = alloc_temp_local(ctx)
      // Untag array pointer
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_i64_const_raw(buf, (-4).to_int64())
      emit_i64_and(buf)
      emit_i32_wrap_i64(buf)
      emit_local_set(buf, arr_ptr_local)
      // Load array length
      emit_local_get(buf, arr_ptr_local)
      emit_i32_load(buf, 4)
      emit_local_set(buf, arr_len_local)
      // Untag start
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_i64_const_raw(buf, 2L)
      emit_i64_shr_s(buf)
      emit_i32_wrap_i64(buf)
      emit_local_set(buf, start_local)
      // Untag end
      compile_expr_i32(ctx, buf, pos_args[2])
      emit_i64_const_raw(buf, 2L)
      emit_i64_shr_s(buf)
      emit_i32_wrap_i64(buf)
      emit_local_set(buf, end_local)
      // Clamp start: if start < 0 then start = 0
      emit_local_get(buf, start_local)
      emit_i32_const_raw(buf, 0)
      emit_i32_lt_s(buf)
      buf.push((4).to_byte()) // if
      buf.push((64).to_byte()) // void
      emit_i32_const_raw(buf, 0)
      emit_local_set(buf, start_local)
      buf.push((11).to_byte()) // end if
      // Clamp start: if start > len then start = len
      emit_local_get(buf, arr_len_local)
      emit_local_get(buf, start_local)
      emit_i32_lt_s(buf)
      buf.push((4).to_byte()) // if
      buf.push((64).to_byte()) // void
      emit_local_get(buf, arr_len_local)
      emit_local_set(buf, start_local)
      buf.push((11).to_byte()) // end if
      // Clamp end: if end < 0 then end = 0
      emit_local_get(buf, end_local)
      emit_i32_const_raw(buf, 0)
      emit_i32_lt_s(buf)
      buf.push((4).to_byte()) // if
      buf.push((64).to_byte()) // void
      emit_i32_const_raw(buf, 0)
      emit_local_set(buf, end_local)
      buf.push((11).to_byte()) // end if
      // Clamp end: if end > len then end = len
      emit_local_get(buf, arr_len_local)
      emit_local_get(buf, end_local)
      emit_i32_lt_s(buf)
      buf.push((4).to_byte()) // if
      buf.push((64).to_byte()) // void
      emit_local_get(buf, arr_len_local)
      emit_local_set(buf, end_local)
      buf.push((11).to_byte()) // end if
      // If start > end then start = end (empty slice)
      emit_local_get(buf, end_local)
      emit_local_get(buf, start_local)
      emit_i32_lt_s(buf)
      buf.push((4).to_byte()) // if
      buf.push((64).to_byte()) // void
      emit_local_get(buf, start_local)
      emit_local_set(buf, end_local)
      buf.push((11).to_byte()) // end if
      // slice_len = end - start
      emit_local_get(buf, end_local)
      emit_local_get(buf, start_local)
      emit_i32_sub(buf)
      emit_local_set(buf, slice_len_local)
      // alloc_size = align4(8 + slice_len * 4)
      emit_local_get(buf, slice_len_local)
      emit_i32_const_raw(buf, 4)
      emit_i32_mul(buf)
      emit_i32_const_raw(buf, 8 + 3) // header + alignment
      emit_i32_add(buf)
      emit_i32_const_raw(buf, -4)
      emit_i32_and(buf)
      emit_local_set(buf, alloc_size_local)
      // Allocate
      emit_heap_alloc_local(ctx, buf, alloc_size_local, obj_local)
      // Set type = obj_array
      emit_local_get(buf, obj_local)
      emit_i32_const_raw(buf, obj_array)
      emit_i32_store(buf, 0)
      // Set length
      emit_local_get(buf, obj_local)
      emit_local_get(buf, slice_len_local)
      emit_i32_store(buf, 4)
      // Copy elements: loop i = 0; i < slice_len; i++
      emit_i32_const_raw(buf, 0)
      emit_local_set(buf, copy_i_local)
      emit_block(buf)
      emit_loop(buf)
      emit_local_get(buf, copy_i_local)
      emit_local_get(buf, slice_len_local)
      emit_i32_lt_s(buf)
      emit_i32_eqz(buf)
      emit_br_if(buf, 1) // break if i >= slice_len
      // dst[i] = src[start + i] (each element is 4 bytes, at offset 8)
      emit_local_get(buf, obj_local)
      emit_local_get(buf, copy_i_local)
      emit_i32_const_raw(buf, 4)
      emit_i32_mul(buf)
      emit_i32_add(buf)
      // load src[start + i]
      emit_local_get(buf, arr_ptr_local)
      emit_local_get(buf, start_local)
      emit_local_get(buf, copy_i_local)
      emit_i32_add(buf)
      emit_i32_const_raw(buf, 4)
      emit_i32_mul(buf)
      emit_i32_add(buf)
      emit_i32_load(buf, 8)
      // store to dst
      emit_i32_store(buf, 8)
      // i++
      emit_local_get(buf, copy_i_local)
      emit_i32_const_raw(buf, 1)
      emit_i32_add(buf)
      emit_local_set(buf, copy_i_local)
      emit_br(buf, 0) // continue loop
      emit_end(buf)
      emit_end(buf)
      // Return tagged pointer
      emit_local_get(buf, obj_local)
      emit_i64_extend_i32_u(buf)
      emit_i64_const_raw(buf, tag_obj.to_int64())
      emit_i64_or(buf)
    }
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
