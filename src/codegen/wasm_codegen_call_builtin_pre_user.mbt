///|
let pre_user_builtin_unhandled_marker = "__pre_user_builtin_unhandled__"

///|
fn compile_call_builtin_pre_user(
  ctx : CodegenCtx,
  buf : ByteBuf,
  name : String,
  args : Array[@core.CallArg],
  is_user_fn : Bool,
) -> Bool raise WasmGenError {
  let result : Result[Unit, WasmGenError] = try? compile_call_builtin_pre_user_inner(
    ctx, buf, name, args, is_user_fn,
  )
  match result {
    Ok(_) => true
    Err(WasmGenError::Unsupported(message)) =>
      if message == pre_user_builtin_unhandled_marker {
        false
      } else {
        raise WasmGenError::Unsupported(message)
      }
    Err(err) => raise err
  }
}

///|
fn emit_load_obj_number_as_f64(
  buf : ByteBuf,
  obj_ptr_local : Int,
  obj_ty_local : Int,
) -> Unit {
  emit_local_get(buf, obj_ty_local)
  emit_i32_const_raw(buf, obj_float)
  emit_i32_eq(buf)
  buf.push((4).to_byte()) // if
  buf.push((124).to_byte()) // result f64
  emit_local_get(buf, obj_ptr_local)
  emit_f32_load(buf, 4)
  emit_f64_promote_f32(buf)
  buf.push((5).to_byte()) // else
  emit_local_get(buf, obj_ptr_local)
  emit_f64_load(buf, 4)
  buf.push((11).to_byte()) // end if
}

///|
fn emit_number_obj_to_string(
  ctx : CodegenCtx,
  buf : ByteBuf,
  obj_ptr_local : Int,
  obj_ty_local : Int,
  fallback_str : Int64,
) -> Unit raise WasmGenError {
  let is_neg_local = alloc_temp_local(ctx)
  let int_part_local = alloc_temp_local(ctx)
  let scaled_local = alloc_temp_local(ctx)
  let frac_tmp_local = alloc_temp_local(ctx)
  let int_len_local = alloc_temp_local(ctx)
  let frac_len_local = alloc_temp_local(ctx)
  let digit_local = alloc_temp_local(ctx)
  let copy_i_local = alloc_temp_local(ctx)
  let src_idx_local = alloc_temp_local(ctx)
  let total_len_local = alloc_temp_local(ctx)
  let alloc_size_local = alloc_temp_local(ctx)
  let obj_local = alloc_temp_local(ctx)
  let scratch_local = alloc_temp_local(ctx)
  let invalid_local = alloc_temp_local(ctx)

  emit_heap_alloc(ctx, buf, 96, scratch_local)

  // scratch[0..8): original value as f64
  emit_local_get(buf, scratch_local)
  emit_load_obj_number_as_f64(buf, obj_ptr_local, obj_ty_local)
  emit_f64_store(buf, 0)

  // is_neg = value < 0.0
  emit_local_get(buf, scratch_local)
  emit_f64_load(buf, 0)
  emit_f64_const(buf, 0.0)
  emit_f64_lt(buf)
  emit_local_set(buf, is_neg_local)

  // scratch[8..16): abs(value)
  emit_local_get(buf, scratch_local)
  emit_local_get(buf, is_neg_local)
  buf.push((4).to_byte()) // if
  buf.push((124).to_byte()) // result f64
  emit_f64_const(buf, 0.0)
  emit_local_get(buf, scratch_local)
  emit_f64_load(buf, 0)
  emit_f64_sub(buf)
  buf.push((5).to_byte()) // else
  emit_local_get(buf, scratch_local)
  emit_f64_load(buf, 0)
  buf.push((11).to_byte()) // end if
  emit_f64_store(buf, 8)

  // invalid = isnan(abs)
  emit_local_get(buf, scratch_local)
  emit_f64_load(buf, 8)
  emit_local_get(buf, scratch_local)
  emit_f64_load(buf, 8)
  emit_f64_eq(buf)
  emit_i32_eqz(buf)
  emit_local_set(buf, invalid_local)

  // invalid |= abs > 2147483647.0
  emit_local_get(buf, scratch_local)
  emit_f64_load(buf, 8)
  emit_f64_const(buf, 2147483647.0)
  emit_f64_gt(buf)
  emit_local_get(buf, invalid_local)
  emit_i32_or(buf)
  emit_local_set(buf, invalid_local)

  emit_local_get(buf, invalid_local)
  buf.push((4).to_byte()) // if
  buf.push((126).to_byte()) // result i64
  emit_i64_const_raw(buf, fallback_str)
  buf.push((5).to_byte()) // else

  // int_part = trunc(abs)
  emit_local_get(buf, scratch_local)
  emit_f64_load(buf, 8)
  emit_i64_trunc_f64_s(buf)
  emit_i32_wrap_i64(buf)
  emit_local_set(buf, int_part_local)

  // scratch[16..24): frac = abs - int_to_double(int_part)
  emit_local_get(buf, scratch_local)
  emit_local_get(buf, scratch_local)
  emit_f64_load(buf, 8)
  emit_local_get(buf, int_part_local)
  emit_i64_extend_i32_s(buf)
  emit_f64_convert_i64_s(buf)
  emit_f64_sub(buf)
  emit_f64_store(buf, 16)

  // scaled = trunc(frac * 1_000_000 + 0.5)
  emit_local_get(buf, scratch_local)
  emit_f64_load(buf, 16)
  emit_f64_const(buf, 1000000.0)
  emit_f64_mul(buf)
  emit_f64_const(buf, 0.5)
  emit_f64_add(buf)
  emit_i64_trunc_f64_s(buf)
  emit_i32_wrap_i64(buf)
  emit_local_set(buf, scaled_local)

  // Carry from fractional rounding.
  emit_local_get(buf, scaled_local)
  emit_i32_const_raw(buf, 1000000)
  emit_i32_eq(buf)
  buf.push((4).to_byte()) // if
  buf.push((64).to_byte()) // void
  emit_local_get(buf, int_part_local)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, int_part_local)
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, scaled_local)
  buf.push((11).to_byte()) // end if

  // Encode int digits in reverse into scratch+32.
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, int_len_local)
  emit_local_get(buf, int_part_local)
  emit_i32_eqz(buf)
  buf.push((4).to_byte()) // if
  buf.push((64).to_byte()) // void
  emit_local_get(buf, scratch_local)
  emit_i32_const_raw(buf, 48)
  emit_i32_store8(buf, 32)
  emit_i32_const_raw(buf, 1)
  emit_local_set(buf, int_len_local)
  buf.push((5).to_byte()) // else
  emit_block(buf)
  emit_loop(buf)
  emit_local_get(buf, int_part_local)
  emit_i32_eqz(buf)
  emit_br_if(buf, 1)
  emit_local_get(buf, int_part_local)
  emit_i32_const_raw(buf, 10)
  emit_i32_rem_s(buf)
  emit_local_set(buf, digit_local)
  emit_local_get(buf, int_part_local)
  emit_i32_const_raw(buf, 10)
  emit_i32_div_s(buf)
  emit_local_set(buf, int_part_local)
  emit_local_get(buf, scratch_local)
  emit_local_get(buf, int_len_local)
  emit_i32_add(buf)
  emit_local_get(buf, digit_local)
  emit_i32_const_raw(buf, 48)
  emit_i32_add(buf)
  emit_i32_store8(buf, 32)
  emit_local_get(buf, int_len_local)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, int_len_local)
  emit_br(buf, 0)
  emit_end(buf)
  emit_end(buf)
  buf.push((11).to_byte()) // end if

  // Encode fraction (zero-padded 6 digits) into scratch+48, then trim tail zeros.
  emit_local_get(buf, scaled_local)
  emit_i32_eqz(buf)
  buf.push((4).to_byte()) // if
  buf.push((64).to_byte()) // void
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, frac_len_local)
  buf.push((5).to_byte()) // else
  emit_local_get(buf, scaled_local)
  emit_local_set(buf, frac_tmp_local)
  emit_i32_const_raw(buf, 6)
  emit_local_set(buf, copy_i_local)
  emit_block(buf)
  emit_loop(buf)
  emit_local_get(buf, copy_i_local)
  emit_i32_eqz(buf)
  emit_br_if(buf, 1)
  emit_local_get(buf, copy_i_local)
  emit_i32_const_raw(buf, 1)
  emit_i32_sub(buf)
  emit_local_set(buf, copy_i_local)
  emit_local_get(buf, frac_tmp_local)
  emit_i32_const_raw(buf, 10)
  emit_i32_rem_s(buf)
  emit_local_set(buf, digit_local)
  emit_local_get(buf, frac_tmp_local)
  emit_i32_const_raw(buf, 10)
  emit_i32_div_s(buf)
  emit_local_set(buf, frac_tmp_local)
  emit_local_get(buf, scratch_local)
  emit_local_get(buf, copy_i_local)
  emit_i32_add(buf)
  emit_local_get(buf, digit_local)
  emit_i32_const_raw(buf, 48)
  emit_i32_add(buf)
  emit_i32_store8(buf, 48)
  emit_br(buf, 0)
  emit_end(buf)
  emit_end(buf)
  emit_i32_const_raw(buf, 6)
  emit_local_set(buf, frac_len_local)
  emit_block(buf)
  emit_loop(buf)
  emit_local_get(buf, frac_len_local)
  emit_i32_eqz(buf)
  emit_br_if(buf, 1)
  emit_local_get(buf, frac_len_local)
  emit_i32_const_raw(buf, 1)
  emit_i32_sub(buf)
  emit_local_set(buf, src_idx_local)
  emit_local_get(buf, scratch_local)
  emit_local_get(buf, src_idx_local)
  emit_i32_add(buf)
  emit_i32_load8_u(buf, 48)
  emit_i32_const_raw(buf, 48)
  emit_i32_eq(buf)
  emit_i32_eqz(buf)
  emit_br_if(buf, 1)
  emit_local_get(buf, frac_len_local)
  emit_i32_const_raw(buf, 1)
  emit_i32_sub(buf)
  emit_local_set(buf, frac_len_local)
  emit_br(buf, 0)
  emit_end(buf)
  emit_end(buf)
  buf.push((11).to_byte()) // end if

  // total_len = int_len + sign + (frac_len>0 ? 1 + frac_len : 0)
  emit_local_get(buf, int_len_local)
  emit_local_set(buf, total_len_local)
  emit_local_get(buf, is_neg_local)
  emit_i32_eqz(buf)
  buf.push((4).to_byte()) // if
  buf.push((64).to_byte()) // void
  buf.push((5).to_byte()) // else
  emit_local_get(buf, total_len_local)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, total_len_local)
  buf.push((11).to_byte()) // end if
  emit_local_get(buf, frac_len_local)
  emit_i32_eqz(buf)
  buf.push((4).to_byte()) // if
  buf.push((64).to_byte()) // void
  buf.push((5).to_byte()) // else
  emit_local_get(buf, total_len_local)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_get(buf, frac_len_local)
  emit_i32_add(buf)
  emit_local_set(buf, total_len_local)
  buf.push((11).to_byte()) // end if

  // Allocate output string object.
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

  // Optional leading '-'.
  emit_local_get(buf, is_neg_local)
  emit_i32_eqz(buf)
  buf.push((4).to_byte()) // if
  buf.push((64).to_byte()) // void
  buf.push((5).to_byte()) // else
  emit_local_get(buf, obj_local)
  emit_local_get(buf, copy_i_local)
  emit_i32_add(buf)
  emit_i32_const_raw(buf, 45)
  emit_i32_store8(buf, 8)
  emit_local_get(buf, copy_i_local)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, copy_i_local)
  buf.push((11).to_byte()) // end if

  // Copy integer digits in reverse order from scratch+32.
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, src_idx_local)
  emit_block(buf)
  emit_loop(buf)
  emit_local_get(buf, src_idx_local)
  emit_local_get(buf, int_len_local)
  emit_i32_lt_s(buf)
  emit_i32_eqz(buf)
  emit_br_if(buf, 1)
  emit_local_get(buf, int_len_local)
  emit_i32_const_raw(buf, 1)
  emit_i32_sub(buf)
  emit_local_get(buf, src_idx_local)
  emit_i32_sub(buf)
  emit_local_set(buf, digit_local)
  emit_local_get(buf, obj_local)
  emit_local_get(buf, copy_i_local)
  emit_i32_add(buf)
  emit_local_get(buf, scratch_local)
  emit_local_get(buf, digit_local)
  emit_i32_add(buf)
  emit_i32_load8_u(buf, 32)
  emit_i32_store8(buf, 8)
  emit_local_get(buf, copy_i_local)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, copy_i_local)
  emit_local_get(buf, src_idx_local)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, src_idx_local)
  emit_br(buf, 0)
  emit_end(buf)
  emit_end(buf)

  // Fractional part.
  emit_local_get(buf, frac_len_local)
  emit_i32_eqz(buf)
  buf.push((4).to_byte()) // if
  buf.push((64).to_byte()) // void
  buf.push((5).to_byte()) // else
  emit_local_get(buf, obj_local)
  emit_local_get(buf, copy_i_local)
  emit_i32_add(buf)
  emit_i32_const_raw(buf, 46)
  emit_i32_store8(buf, 8)
  emit_local_get(buf, copy_i_local)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, copy_i_local)
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, src_idx_local)
  emit_block(buf)
  emit_loop(buf)
  emit_local_get(buf, src_idx_local)
  emit_local_get(buf, frac_len_local)
  emit_i32_lt_s(buf)
  emit_i32_eqz(buf)
  emit_br_if(buf, 1)
  emit_local_get(buf, obj_local)
  emit_local_get(buf, copy_i_local)
  emit_i32_add(buf)
  emit_local_get(buf, scratch_local)
  emit_local_get(buf, src_idx_local)
  emit_i32_add(buf)
  emit_i32_load8_u(buf, 48)
  emit_i32_store8(buf, 8)
  emit_local_get(buf, copy_i_local)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, copy_i_local)
  emit_local_get(buf, src_idx_local)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, src_idx_local)
  emit_br(buf, 0)
  emit_end(buf)
  emit_end(buf)
  buf.push((11).to_byte()) // end if

  emit_local_get(buf, obj_local)
  emit_i64_extend_i32_u(buf)
  emit_i64_const_raw(buf, tag_obj.to_int64())
  emit_i64_or(buf)

  buf.push((11).to_byte()) // end if invalid
}

///|
fn compile_call_builtin_pre_user_inner(
  ctx : CodegenCtx,
  buf : ByteBuf,
  name : String,
  args : Array[@core.CallArg],
  is_user_fn : Bool,
) -> Unit raise WasmGenError {
  match name {
    "sh" => {
      let pos_args = extract_positional_exprs_with_arity(args, "sh", 1)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_call(buf, import_index_sh(ctx))
      emit_drop(buf)
      emit_i64_const_tagged(buf, 0L)
    }
    "path" => {
      let pos_args = extract_positional_exprs_with_arity(args, "path", 1)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_call(buf, import_index_path(ctx))
    }
    "add" if not(is_user_fn) => {
      let pos_args = extract_positional_exprs_with_arity(args, "add", 2)
      compile_i32_add_tagged(ctx, buf, pos_args[0], pos_args[1])
    }
    "sub" if not(is_user_fn) => {
      let pos_args = extract_positional_exprs_with_arity(args, "sub", 2)
      compile_i32_sub_tagged(ctx, buf, pos_args[0], pos_args[1])
    }
    "mul" if not(is_user_fn) => {
      let pos_args = extract_positional_exprs_with_arity(args, "mul", 2)
      compile_i32_mul_tagged(ctx, buf, pos_args[0], pos_args[1])
    }
    "div" if not(is_user_fn) => {
      let pos_args = extract_positional_exprs_with_arity(args, "div", 2)
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
      let pos_args = extract_positional_exprs_with_arity(args, "assert", 1)
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
      let pos_args = extract_positional_exprs_with_arity(args, "__add", 2)
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
      let pos_args = extract_positional_exprs_with_arity(args, "__sub", 2)
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
      let pos_args = extract_positional_exprs_with_arity(args, "__mul", 2)
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
      let pos_args = extract_positional_exprs_with_arity(args, "__div", 2)
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
      let pos_args = extract_positional_exprs_with_arity(args, "__mod", 2)
      let resolved_kind = resolve_numeric_kind(ctx, pos_args[0], pos_args[1])
      match resolved_kind {
        ValueKind::I32 | ValueKind::I64 =>
          compile_i32_mod_tagged(ctx, buf, pos_args[0], pos_args[1])
        _ => raise WasmGenError::Unsupported("__mod for float types")
      }
    }
    "__lshift" => {
      let pos_args = extract_positional_exprs_with_arity(args, "__lshift", 2)
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
      let pos_args = extract_positional_exprs_with_arity(args, "__rshift", 2)
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
      let pos_args = extract_positional_exprs_with_arity(args, "i32_shr_u", 2)
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
      let pos_args = extract_positional_exprs_with_arity(args, "__bit_and", 2)
      // Tagged ints: (a & b) works directly since tag bits are 0
      compile_expr_i32(ctx, buf, pos_args[0])
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_i64_and(buf)
    }
    "__bit_or" => {
      let pos_args = extract_positional_exprs_with_arity(args, "__bit_or", 2)
      // Tagged ints: (a | b) works directly since tag bits are 0
      compile_expr_i32(ctx, buf, pos_args[0])
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_i64_or(buf)
    }
    "__bit_xor" => {
      let pos_args = extract_positional_exprs_with_arity(args, "__bit_xor", 2)
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
      let pos_args = extract_positional_exprs_with_arity(args, "i32_eqz", 1)
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
      let pos_args = extract_positional_exprs_with_arity(args, "__neg", 1)
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
      let pos_args = extract_positional_exprs_with_arity(args, "f32_neg", 1)
      emit_boxed_f32_raise(ctx, buf, fn() raise WasmGenError {
        emit_unbox_f32_expr(ctx, buf, pos_args[0])
        emit_f32_neg(buf)
      })
    }
    "f64_neg" => {
      let pos_args = extract_positional_exprs_with_arity(args, "f64_neg", 1)
      emit_boxed_f64_raise(ctx, buf, fn() raise WasmGenError {
        emit_unbox_f64_expr(ctx, buf, pos_args[0])
        emit_f64_neg(buf)
      })
    }
    "int_to_float" | "f32_convert_i32_s" => {
      let pos_args = extract_positional_exprs_with_arity(args, name, 1)
      emit_boxed_f32_raise(ctx, buf, fn() raise WasmGenError {
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_i64_const_raw(buf, 2L)
        emit_i64_shr_s(buf)
        emit_i32_wrap_i64(buf)
        emit_f32_convert_i32_s(buf)
      })
    }
    "int_to_double" | "f64_convert_i32_s" | "to_double" => {
      let pos_args = extract_positional_exprs_with_arity(args, name, 1)
      emit_boxed_f64_raise(ctx, buf, fn() raise WasmGenError {
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_i64_const_raw(buf, 2L)
        emit_i64_shr_s(buf)
        emit_f64_convert_i64_s(buf)
      })
    }
    "float_to_int" | "i32_trunc_f32_s" => {
      let pos_args = extract_positional_exprs_with_arity(args, name, 1)
      emit_unbox_f32_expr(ctx, buf, pos_args[0])
      emit_i32_trunc_f32_s(buf)
      emit_i64_extend_i32_s(buf)
      emit_i64_const_raw(buf, 2L)
      emit_i64_shl(buf)
      emit_i64_const_raw(buf, tag_int.to_int64())
      emit_i64_or(buf)
    }
    "double_to_int" | "i32_trunc_f64_s" => {
      let pos_args = extract_positional_exprs_with_arity(args, name, 1)
      emit_unbox_f64_expr(ctx, buf, pos_args[0])
      emit_i64_trunc_f64_s(buf)
      emit_i64_const_raw(buf, 2L)
      emit_i64_shl(buf)
      emit_i64_const_raw(buf, tag_int.to_int64())
      emit_i64_or(buf)
    }
    "float_to_double" | "f64_promote_f32" => {
      let pos_args = extract_positional_exprs_with_arity(args, name, 1)
      emit_boxed_f64_raise(ctx, buf, fn() raise WasmGenError {
        emit_unbox_f32_expr(ctx, buf, pos_args[0])
        emit_f64_promote_f32(buf)
      })
    }
    "double_to_float" | "f32_demote_f64" => {
      let pos_args = extract_positional_exprs_with_arity(args, name, 1)
      emit_boxed_f32_raise(ctx, buf, fn() raise WasmGenError {
        emit_unbox_f64_expr(ctx, buf, pos_args[0])
        emit_f32_demote_f64(buf)
      })
    }
    "i32_load" => {
      let pos_args = extract_positional_exprs_with_arity(args, "i32_load", 2)
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
      let pos_args = extract_positional_exprs_with_arity(args, "i32_load8_u", 2)
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
      let pos_args = extract_positional_exprs_with_arity(args, "i32_store", 3)
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
      let pos_args = extract_positional_exprs_with_arity(args, "i32_store8", 3)
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
      let pos_args = extract_positional_exprs_with_arity(args, "f32_load", 2)
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
      let pos_args = extract_positional_exprs_with_arity(args, "f64_load", 2)
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
      let pos_args = extract_positional_exprs_with_arity(args, "f32_store", 3)
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
      let pos_args = extract_positional_exprs_with_arity(args, "f64_store", 3)
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
      let pos_args = extract_positional_exprs_with_arity(args, "not", 1)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_i64_const_raw(buf, 4L)
      emit_i64_xor(buf)
    }
    "and" if not(is_user_fn) => {
      let pos_args = extract_positional_exprs_with_arity(args, "and", 2)
      compile_expr_i32(ctx, buf, pos_args[0])
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_i64_and(buf)
    }
    "or" if not(is_user_fn) => {
      let pos_args = extract_positional_exprs_with_arity(args, "or", 2)
      compile_expr_i32(ctx, buf, pos_args[0])
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_i64_or(buf)
    }
    "__to_string" => {
      let pos_args = extract_positional_exprs_with_arity(args, "__to_string", 1)
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
        let value_local = alloc_temp_local_with_kind(ctx, ValueKind::I64)
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
        let obj_ptr_local = alloc_temp_local(ctx)
        let obj_ty_local = alloc_temp_local(ctx)
        emit_local_get(buf, value_local)
        emit_i64_const_raw(buf, (-4).to_int64())
        emit_i64_and(buf)
        emit_i32_wrap_i64(buf)
        emit_local_set(buf, obj_ptr_local)
        emit_local_get(buf, obj_ptr_local)
        emit_i32_load(buf, 0)
        emit_local_set(buf, obj_ty_local)
        emit_local_get(buf, obj_ty_local)
        emit_i32_const_raw(buf, obj_string)
        emit_i32_eq(buf)
        buf.push((4).to_byte()) // if
        buf.push((126).to_byte()) // result i64
        emit_local_get(buf, value_local)
        buf.push((5).to_byte()) // else
        emit_local_get(buf, obj_ty_local)
        emit_i32_const_raw(buf, obj_float)
        emit_i32_eq(buf)
        emit_local_get(buf, obj_ty_local)
        emit_i32_const_raw(buf, obj_double)
        emit_i32_eq(buf)
        emit_i32_or(buf)
        buf.push((4).to_byte()) // if
        buf.push((126).to_byte()) // result i64
        emit_number_obj_to_string(
          ctx, buf, obj_ptr_local, obj_ty_local, fallback_str,
        )
        buf.push((5).to_byte()) // else
        emit_i64_const_raw(buf, fallback_str)
        buf.push((11).to_byte()) // end if
        buf.push((11).to_byte()) // end if
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
      let _ = extract_positional_exprs_with_arity(args, "threads_probe_wat", 0)
      emit_string_const(ctx, buf, "(module)")
    }
    "threads_runtime_hints" => {
      let _ = extract_positional_exprs_with_arity(
        args, "threads_runtime_hints", 0,
      )
      emit_i64_const_tagged(buf, 0L)
    }
    "wasm_env" => {
      let pos_args = extract_positional_exprs_with_arity(args, "wasm_env", 1)
      compile_expr(ctx, buf, pos_args[0])
      emit_drop(buf)
      emit_string_const(ctx, buf, "threads=y shared-memory=y")
    }
    "wasi_env" => {
      let pos_args = extract_positional_exprs_with_arity(args, "wasi_env", 1)
      compile_expr(ctx, buf, pos_args[0])
      emit_drop(buf)
      emit_string_const(ctx, buf, "threads=y")
    }
    "threads_channel_new" => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "threads_channel_new", 1,
      )
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
      let pos_args = extract_positional_exprs_with_arity(
        args, "threads_spawn", 2,
      )
      compile_expr(ctx, buf, pos_args[0])
      emit_drop(buf)
      compile_expr_i32(ctx, buf, pos_args[1])
    }
    "threads_send" => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "threads_send", 2,
      )
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_drop(buf)
      compile_expr(ctx, buf, pos_args[1])
      emit_drop(buf)
      emit_i64_const_raw(buf, tag_bool_value64(true))
    }
    "threads_recv" => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "threads_recv", 1,
      )
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_drop(buf)
      emit_string_const(ctx, buf, "")
    }
    "threads_wait" => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "threads_wait", 1,
      )
      compile_expr_i32(ctx, buf, pos_args[0])
    }
    "string_length" => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "string_length", 1,
      )
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
      let pos_args = extract_positional_exprs_with_arity(
        args, "string_char_code_at", 2,
      )
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
      let pos_args = extract_positional_exprs_with_arity(
        args, "string_substring", 3,
      )
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
      let pos_args = extract_positional_exprs_with_arity(
        args, "string_concat", 2,
      )
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
    "string_join" => {
      let pos_args = extract_positional_exprs_with_arity(args, "string_join", 2)
      if ctx.use_js_strings {
        raise WasmGenError::BackendLimit(
          backend="wasm-js-string",
          feature="string_join",
        )
      } else {
        require_heap(ctx)
        let arr_ptr_local = alloc_temp_local(ctx)
        let arr_len_local = alloc_temp_local(ctx)
        let sep_ptr_local = alloc_temp_local(ctx)
        let sep_len_local = alloc_temp_local(ctx)
        let loop_i_local = alloc_temp_local(ctx)
        let total_len_local = alloc_temp_local(ctx)
        let alloc_size_local = alloc_temp_local(ctx)
        let obj_local = alloc_temp_local(ctx)
        let out_pos_local = alloc_temp_local(ctx)
        let copy_j_local = alloc_temp_local(ctx)
        let elem_slot_local = alloc_temp_local(ctx)
        let elem_ptr_local = alloc_temp_local(ctx)
        let elem_len_local = alloc_temp_local(ctx)
        // arr pointer / length
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_i64_const_raw(buf, (-4).to_int64())
        emit_i64_and(buf)
        emit_i32_wrap_i64(buf)
        emit_local_set(buf, arr_ptr_local)
        emit_local_get(buf, arr_ptr_local)
        emit_i32_load(buf, 4)
        emit_local_set(buf, arr_len_local)
        // sep pointer / length
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_i64_const_raw(buf, (-4).to_int64())
        emit_i64_and(buf)
        emit_i32_wrap_i64(buf)
        emit_local_set(buf, sep_ptr_local)
        emit_local_get(buf, sep_ptr_local)
        emit_i32_load(buf, 4)
        emit_local_set(buf, sep_len_local)
        // total_len = sum(elem lengths) + sep * (len - 1)
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, total_len_local)
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, loop_i_local)
        emit_block(buf)
        emit_loop(buf)
        emit_local_get(buf, loop_i_local)
        emit_local_get(buf, arr_len_local)
        emit_i32_lt_s(buf)
        emit_i32_eqz(buf)
        emit_br_if(buf, 1)
        emit_local_get(buf, loop_i_local)
        emit_i32_const_raw(buf, 0)
        emit_i32_gt_s(buf)
        buf.push((4).to_byte()) // if
        buf.push((64).to_byte()) // void
        emit_local_get(buf, total_len_local)
        emit_local_get(buf, sep_len_local)
        emit_i32_add(buf)
        emit_local_set(buf, total_len_local)
        buf.push((11).to_byte()) // end if
        // elem = arr[i]
        emit_local_get(buf, arr_ptr_local)
        emit_local_get(buf, loop_i_local)
        emit_i32_const_raw(buf, 4)
        emit_i32_mul(buf)
        emit_i32_add(buf)
        emit_i32_load(buf, 8)
        emit_local_set(buf, elem_slot_local)
        // elem_ptr = untag(elem)
        emit_local_get(buf, elem_slot_local)
        emit_i32_const_raw(buf, -4)
        emit_i32_and(buf)
        emit_local_set(buf, elem_ptr_local)
        emit_local_get(buf, elem_ptr_local)
        emit_i32_load(buf, 4)
        emit_local_set(buf, elem_len_local)
        emit_local_get(buf, total_len_local)
        emit_local_get(buf, elem_len_local)
        emit_i32_add(buf)
        emit_local_set(buf, total_len_local)
        emit_local_get(buf, loop_i_local)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, loop_i_local)
        emit_br(buf, 0)
        emit_end(buf)
        emit_end(buf)
        // alloc_size = align4(8 + total_len)
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
        // Copy pass
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, out_pos_local)
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, loop_i_local)
        emit_block(buf)
        emit_loop(buf)
        emit_local_get(buf, loop_i_local)
        emit_local_get(buf, arr_len_local)
        emit_i32_lt_s(buf)
        emit_i32_eqz(buf)
        emit_br_if(buf, 1)
        // Add separator for i > 0
        emit_local_get(buf, loop_i_local)
        emit_i32_const_raw(buf, 0)
        emit_i32_gt_s(buf)
        buf.push((4).to_byte()) // if
        buf.push((64).to_byte()) // void
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, copy_j_local)
        emit_block(buf)
        emit_loop(buf)
        emit_local_get(buf, copy_j_local)
        emit_local_get(buf, sep_len_local)
        emit_i32_lt_s(buf)
        emit_i32_eqz(buf)
        emit_br_if(buf, 1)
        emit_local_get(buf, obj_local)
        emit_local_get(buf, out_pos_local)
        emit_i32_add(buf)
        emit_local_get(buf, copy_j_local)
        emit_i32_add(buf)
        emit_local_get(buf, sep_ptr_local)
        emit_local_get(buf, copy_j_local)
        emit_i32_add(buf)
        emit_i32_load8_u(buf, 8)
        emit_i32_store8(buf, 8)
        emit_local_get(buf, copy_j_local)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, copy_j_local)
        emit_br(buf, 0)
        emit_end(buf)
        emit_end(buf)
        emit_local_get(buf, out_pos_local)
        emit_local_get(buf, sep_len_local)
        emit_i32_add(buf)
        emit_local_set(buf, out_pos_local)
        buf.push((11).to_byte()) // end if
        // elem = arr[i]
        emit_local_get(buf, arr_ptr_local)
        emit_local_get(buf, loop_i_local)
        emit_i32_const_raw(buf, 4)
        emit_i32_mul(buf)
        emit_i32_add(buf)
        emit_i32_load(buf, 8)
        emit_local_set(buf, elem_slot_local)
        emit_local_get(buf, elem_slot_local)
        emit_i32_const_raw(buf, -4)
        emit_i32_and(buf)
        emit_local_set(buf, elem_ptr_local)
        emit_local_get(buf, elem_ptr_local)
        emit_i32_load(buf, 4)
        emit_local_set(buf, elem_len_local)
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, copy_j_local)
        emit_block(buf)
        emit_loop(buf)
        emit_local_get(buf, copy_j_local)
        emit_local_get(buf, elem_len_local)
        emit_i32_lt_s(buf)
        emit_i32_eqz(buf)
        emit_br_if(buf, 1)
        emit_local_get(buf, obj_local)
        emit_local_get(buf, out_pos_local)
        emit_i32_add(buf)
        emit_local_get(buf, copy_j_local)
        emit_i32_add(buf)
        emit_local_get(buf, elem_ptr_local)
        emit_local_get(buf, copy_j_local)
        emit_i32_add(buf)
        emit_i32_load8_u(buf, 8)
        emit_i32_store8(buf, 8)
        emit_local_get(buf, copy_j_local)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, copy_j_local)
        emit_br(buf, 0)
        emit_end(buf)
        emit_end(buf)
        emit_local_get(buf, out_pos_local)
        emit_local_get(buf, elem_len_local)
        emit_i32_add(buf)
        emit_local_set(buf, out_pos_local)
        emit_local_get(buf, loop_i_local)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, loop_i_local)
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
      let pos_args = extract_positional_exprs_with_arity(
        args, "string_equals", 2,
      )
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
      let pos_args = extract_positional_exprs_with_arity(
        args, "string_index_of", 2,
      )
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
        emit_br(buf, 2) // break outer block (depth: 0=if, 1=loop, 2=block)
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
    "string_contains" if not(is_user_fn) => {
      // string_contains(str, sub) -> Bool
      // Reuses the same substring search as string_index_of but returns bool.
      let pos_args = extract_positional_exprs_with_arity(
        args, "string_contains", 2,
      )
      if ctx.use_js_strings {
        raise WasmGenError::BackendLimit(
          backend="wasm-js-string",
          feature="string_contains",
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
        // result = 0 (not found / false)
        emit_i32_const_raw(buf, 0)
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
        // if matched, set result=1 and break outer
        emit_local_get(buf, matched)
        buf.push((4).to_byte()) // if
        buf.push((64).to_byte()) // void
        emit_i32_const_raw(buf, 1)
        emit_local_set(buf, result_local)
        emit_br(buf, 2) // break outer block (depth: 0=if, 1=loop, 2=block)
        buf.push((11).to_byte()) // end if
        // outer_i++
        emit_local_get(buf, outer_i)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, outer_i)
        emit_br(buf, 0) // continue outer loop
        emit_end(buf) // end outer loop
        emit_end(buf) // end outer block
        // tag result as bool
        emit_local_get(buf, result_local)
        emit_i64_extend_i32_s(buf)
        emit_i64_const_raw(buf, 2L)
        emit_i64_shl(buf)
        emit_i64_const_raw(buf, tag_bool.to_int64())
        emit_i64_or(buf)
      }
    }
    "string_starts_with" if not(is_user_fn) => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "string_starts_with", 2,
      )
      if ctx.use_js_strings {
        raise WasmGenError::BackendLimit(
          backend="wasm-js-string",
          feature="string_starts_with",
        )
      } else {
        let str_ptr_local = alloc_temp_local(ctx)
        let str_len_local = alloc_temp_local(ctx)
        let prefix_ptr_local = alloc_temp_local(ctx)
        let prefix_len_local = alloc_temp_local(ctx)
        let loop_i_local = alloc_temp_local(ctx)
        let result_local = alloc_temp_local(ctx)
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_i64_const_raw(buf, (-4).to_int64())
        emit_i64_and(buf)
        emit_i32_wrap_i64(buf)
        emit_local_set(buf, str_ptr_local)
        emit_local_get(buf, str_ptr_local)
        emit_i32_load(buf, 4)
        emit_local_set(buf, str_len_local)
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_i64_const_raw(buf, (-4).to_int64())
        emit_i64_and(buf)
        emit_i32_wrap_i64(buf)
        emit_local_set(buf, prefix_ptr_local)
        emit_local_get(buf, prefix_ptr_local)
        emit_i32_load(buf, 4)
        emit_local_set(buf, prefix_len_local)
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, result_local)
        emit_local_get(buf, prefix_len_local)
        emit_local_get(buf, str_len_local)
        emit_i32_le_s(buf)
        buf.push((4).to_byte()) // if
        buf.push((64).to_byte()) // void
        emit_i32_const_raw(buf, 1)
        emit_local_set(buf, result_local)
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, loop_i_local)
        emit_block(buf)
        emit_loop(buf)
        emit_local_get(buf, loop_i_local)
        emit_local_get(buf, prefix_len_local)
        emit_i32_lt_s(buf)
        emit_i32_eqz(buf)
        emit_br_if(buf, 1)
        emit_local_get(buf, str_ptr_local)
        emit_local_get(buf, loop_i_local)
        emit_i32_add(buf)
        emit_i32_load8_u(buf, 8)
        emit_local_get(buf, prefix_ptr_local)
        emit_local_get(buf, loop_i_local)
        emit_i32_add(buf)
        emit_i32_load8_u(buf, 8)
        emit_i32_eq(buf)
        emit_i32_eqz(buf)
        buf.push((4).to_byte()) // if
        buf.push((64).to_byte()) // void
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, result_local)
        emit_local_get(buf, prefix_len_local)
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
        buf.push((11).to_byte()) // end if
        emit_local_get(buf, result_local)
        emit_i64_extend_i32_s(buf)
        emit_i64_const_raw(buf, 2L)
        emit_i64_shl(buf)
        emit_i64_const_raw(buf, tag_bool.to_int64())
        emit_i64_or(buf)
      }
    }
    "string_ends_with" if not(is_user_fn) => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "string_ends_with", 2,
      )
      if ctx.use_js_strings {
        raise WasmGenError::BackendLimit(
          backend="wasm-js-string",
          feature="string_ends_with",
        )
      } else {
        let str_ptr_local = alloc_temp_local(ctx)
        let str_len_local = alloc_temp_local(ctx)
        let suffix_ptr_local = alloc_temp_local(ctx)
        let suffix_len_local = alloc_temp_local(ctx)
        let start_local = alloc_temp_local(ctx)
        let loop_i_local = alloc_temp_local(ctx)
        let result_local = alloc_temp_local(ctx)
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_i64_const_raw(buf, (-4).to_int64())
        emit_i64_and(buf)
        emit_i32_wrap_i64(buf)
        emit_local_set(buf, str_ptr_local)
        emit_local_get(buf, str_ptr_local)
        emit_i32_load(buf, 4)
        emit_local_set(buf, str_len_local)
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_i64_const_raw(buf, (-4).to_int64())
        emit_i64_and(buf)
        emit_i32_wrap_i64(buf)
        emit_local_set(buf, suffix_ptr_local)
        emit_local_get(buf, suffix_ptr_local)
        emit_i32_load(buf, 4)
        emit_local_set(buf, suffix_len_local)
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, result_local)
        emit_local_get(buf, suffix_len_local)
        emit_local_get(buf, str_len_local)
        emit_i32_le_s(buf)
        buf.push((4).to_byte()) // if
        buf.push((64).to_byte()) // void
        emit_local_get(buf, str_len_local)
        emit_local_get(buf, suffix_len_local)
        emit_i32_sub(buf)
        emit_local_set(buf, start_local)
        emit_i32_const_raw(buf, 1)
        emit_local_set(buf, result_local)
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, loop_i_local)
        emit_block(buf)
        emit_loop(buf)
        emit_local_get(buf, loop_i_local)
        emit_local_get(buf, suffix_len_local)
        emit_i32_lt_s(buf)
        emit_i32_eqz(buf)
        emit_br_if(buf, 1)
        emit_local_get(buf, str_ptr_local)
        emit_local_get(buf, start_local)
        emit_i32_add(buf)
        emit_local_get(buf, loop_i_local)
        emit_i32_add(buf)
        emit_i32_load8_u(buf, 8)
        emit_local_get(buf, suffix_ptr_local)
        emit_local_get(buf, loop_i_local)
        emit_i32_add(buf)
        emit_i32_load8_u(buf, 8)
        emit_i32_eq(buf)
        emit_i32_eqz(buf)
        buf.push((4).to_byte()) // if
        buf.push((64).to_byte()) // void
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, result_local)
        emit_local_get(buf, suffix_len_local)
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
        buf.push((11).to_byte()) // end if
        emit_local_get(buf, result_local)
        emit_i64_extend_i32_s(buf)
        emit_i64_const_raw(buf, 2L)
        emit_i64_shl(buf)
        emit_i64_const_raw(buf, tag_bool.to_int64())
        emit_i64_or(buf)
      }
    }
    "string_last_index_of" if not(is_user_fn) => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "string_last_index_of", 2,
      )
      if ctx.use_js_strings {
        raise WasmGenError::BackendLimit(
          backend="wasm-js-string",
          feature="string_last_index_of",
        )
      } else {
        let str_ptr_local = alloc_temp_local(ctx)
        let str_len_local = alloc_temp_local(ctx)
        let sub_ptr_local = alloc_temp_local(ctx)
        let sub_len_local = alloc_temp_local(ctx)
        let loop_i_local = alloc_temp_local(ctx)
        let inner_j_local = alloc_temp_local(ctx)
        let matched_local = alloc_temp_local(ctx)
        let result_local = alloc_temp_local(ctx)
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_i64_const_raw(buf, (-4).to_int64())
        emit_i64_and(buf)
        emit_i32_wrap_i64(buf)
        emit_local_set(buf, str_ptr_local)
        emit_local_get(buf, str_ptr_local)
        emit_i32_load(buf, 4)
        emit_local_set(buf, str_len_local)
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_i64_const_raw(buf, (-4).to_int64())
        emit_i64_and(buf)
        emit_i32_wrap_i64(buf)
        emit_local_set(buf, sub_ptr_local)
        emit_local_get(buf, sub_ptr_local)
        emit_i32_load(buf, 4)
        emit_local_set(buf, sub_len_local)
        emit_i32_const_raw(buf, -1)
        emit_local_set(buf, result_local)
        emit_local_get(buf, sub_len_local)
        emit_local_get(buf, str_len_local)
        emit_i32_le_s(buf)
        buf.push((4).to_byte()) // if
        buf.push((64).to_byte()) // void
        emit_local_get(buf, sub_len_local)
        emit_i32_eqz(buf)
        buf.push((4).to_byte()) // if
        buf.push((64).to_byte()) // void
        emit_local_get(buf, str_len_local)
        emit_local_set(buf, result_local)
        buf.push((5).to_byte()) // else
        emit_local_get(buf, str_len_local)
        emit_local_get(buf, sub_len_local)
        emit_i32_sub(buf)
        emit_local_set(buf, loop_i_local)
        emit_block(buf)
        emit_loop(buf)
        emit_local_get(buf, loop_i_local)
        emit_i32_const_raw(buf, 0)
        emit_i32_lt_s(buf)
        emit_br_if(buf, 1)
        emit_i32_const_raw(buf, 1)
        emit_local_set(buf, matched_local)
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, inner_j_local)
        emit_block(buf)
        emit_loop(buf)
        emit_local_get(buf, inner_j_local)
        emit_local_get(buf, sub_len_local)
        emit_i32_lt_s(buf)
        emit_i32_eqz(buf)
        emit_br_if(buf, 1)
        emit_local_get(buf, str_ptr_local)
        emit_local_get(buf, loop_i_local)
        emit_i32_add(buf)
        emit_local_get(buf, inner_j_local)
        emit_i32_add(buf)
        emit_i32_load8_u(buf, 8)
        emit_local_get(buf, sub_ptr_local)
        emit_local_get(buf, inner_j_local)
        emit_i32_add(buf)
        emit_i32_load8_u(buf, 8)
        emit_i32_eq(buf)
        emit_i32_eqz(buf)
        buf.push((4).to_byte()) // if
        buf.push((64).to_byte()) // void
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, matched_local)
        emit_local_get(buf, sub_len_local)
        emit_local_set(buf, inner_j_local)
        buf.push((5).to_byte()) // else
        emit_local_get(buf, inner_j_local)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, inner_j_local)
        buf.push((11).to_byte()) // end if
        emit_br(buf, 0)
        emit_end(buf)
        emit_end(buf)
        emit_local_get(buf, matched_local)
        buf.push((4).to_byte()) // if
        buf.push((64).to_byte()) // void
        emit_local_get(buf, loop_i_local)
        emit_local_set(buf, result_local)
        emit_br(buf, 2)
        buf.push((11).to_byte()) // end if
        emit_local_get(buf, loop_i_local)
        emit_i32_const_raw(buf, 1)
        emit_i32_sub(buf)
        emit_local_set(buf, loop_i_local)
        emit_br(buf, 0)
        emit_end(buf)
        emit_end(buf)
        buf.push((11).to_byte()) // end if
        buf.push((11).to_byte()) // end if
        emit_local_get(buf, result_local)
        emit_i64_extend_i32_s(buf)
        emit_i64_const_raw(buf, 2L)
        emit_i64_shl(buf)
        emit_i64_const_raw(buf, tag_int.to_int64())
        emit_i64_or(buf)
      }
    }
    "string_count" if not(is_user_fn) => {
      // string_count(str, sub) -> Int (non-overlapping count)
      let pos_args = extract_positional_exprs_with_arity(
        args, "string_count", 2,
      )
      if ctx.use_js_strings {
        raise WasmGenError::BackendLimit(
          backend="wasm-js-string",
          feature="string_count",
        )
      } else {
        let str_ptr = alloc_temp_local(ctx)
        let str_len = alloc_temp_local(ctx)
        let sub_ptr = alloc_temp_local(ctx)
        let sub_len = alloc_temp_local(ctx)
        let outer_i = alloc_temp_local(ctx)
        let inner_j = alloc_temp_local(ctx)
        let count_local = alloc_temp_local(ctx)
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
        // count = 0
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, count_local)
        // limit = str_len - sub_len + 1 (if sub_len == 0 or sub_len > str_len, skip)
        emit_local_get(buf, sub_len)
        emit_i32_eqz(buf)
        buf.push((4).to_byte()) // if sub_len == 0
        buf.push((64).to_byte()) // void
        // sub_len == 0 → count = 0, skip
        buf.push((5).to_byte()) // else
        emit_local_get(buf, str_len)
        emit_local_get(buf, sub_len)
        emit_i32_sub(buf)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, limit_local)
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, outer_i)
        emit_block(buf) // outer block (exit search)
        emit_loop(buf) // outer loop
        // if outer_i >= limit, break
        emit_local_get(buf, outer_i)
        emit_local_get(buf, limit_local)
        emit_i32_lt_s(buf)
        emit_i32_eqz(buf)
        emit_br_if(buf, 1) // break to outer block
        // check if all sub bytes match at position outer_i
        emit_i32_const_raw(buf, 1)
        emit_local_set(buf, matched)
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, inner_j)
        emit_block(buf) // inner block
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
        emit_i32_load8_u(buf, 8)
        emit_local_get(buf, sub_ptr)
        emit_local_get(buf, inner_j)
        emit_i32_add(buf)
        emit_i32_load8_u(buf, 8)
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
        // if matched, count++ and advance by sub_len (non-overlapping)
        emit_local_get(buf, matched)
        buf.push((4).to_byte()) // if
        buf.push((64).to_byte()) // void
        emit_local_get(buf, count_local)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, count_local)
        emit_local_get(buf, outer_i)
        emit_local_get(buf, sub_len)
        emit_i32_add(buf)
        emit_local_set(buf, outer_i)
        emit_br(buf, 1) // continue outer loop (skip outer_i++ below)
        buf.push((11).to_byte()) // end if
        // outer_i++ (no match case)
        emit_local_get(buf, outer_i)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, outer_i)
        emit_br(buf, 0) // continue outer loop
        emit_end(buf) // end outer loop
        emit_end(buf) // end outer block
        buf.push((11).to_byte()) // end else (sub_len != 0)
        // tag count as int
        emit_local_get(buf, count_local)
        emit_i64_extend_i32_s(buf)
        emit_i64_const_raw(buf, 2L)
        emit_i64_shl(buf)
        emit_i64_const_raw(buf, tag_int.to_int64())
        emit_i64_or(buf)
      }
    }
    "string_trim" if not(is_user_fn) => {
      // string_trim(str) -> String (trim ASCII whitespace from both ends)
      let pos_args = extract_positional_exprs_with_arity(
        args, "string_trim", 1,
      )
      if ctx.use_js_strings {
        raise WasmGenError::BackendLimit(
          backend="wasm-js-string",
          feature="string_trim",
        )
      } else {
        require_heap(ctx)
        let str_ptr = alloc_temp_local(ctx)
        let str_len = alloc_temp_local(ctx)
        let start_local = alloc_temp_local(ctx)
        let end_local = alloc_temp_local(ctx)
        let new_len = alloc_temp_local(ctx)
        let new_ptr = alloc_temp_local(ctx)
        let copy_i = alloc_temp_local(ctx)
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_i64_const_raw(buf, (-4).to_int64())
        emit_i64_and(buf)
        emit_i32_wrap_i64(buf)
        emit_local_set(buf, str_ptr)
        emit_local_get(buf, str_ptr)
        emit_i32_load(buf, 4)
        emit_local_set(buf, str_len)
        // start = 0; scan forward while whitespace
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, start_local)
        emit_block(buf)
        emit_loop(buf)
        emit_local_get(buf, start_local)
        emit_local_get(buf, str_len)
        emit_i32_lt_s(buf)
        emit_i32_eqz(buf)
        emit_br_if(buf, 1) // break if start >= len
        emit_local_get(buf, str_ptr)
        emit_local_get(buf, start_local)
        emit_i32_add(buf)
        emit_i32_load8_u(buf, 8)
        // check if byte <= 32 (space, tab, newline, cr)
        emit_i32_const_raw(buf, 32)
        emit_i32_gt_u(buf) // byte > 32 means non-whitespace
        emit_br_if(buf, 1) // break if non-whitespace
        emit_local_get(buf, start_local)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, start_local)
        emit_br(buf, 0)
        emit_end(buf)
        emit_end(buf)
        // end = str_len; scan backward while whitespace
        emit_local_get(buf, str_len)
        emit_local_set(buf, end_local)
        emit_block(buf)
        emit_loop(buf)
        emit_local_get(buf, end_local)
        emit_local_get(buf, start_local)
        emit_i32_gt_s(buf)
        emit_i32_eqz(buf)
        emit_br_if(buf, 1) // break if end <= start
        emit_local_get(buf, str_ptr)
        emit_local_get(buf, end_local)
        emit_i32_const_raw(buf, 1)
        emit_i32_sub(buf)
        emit_i32_add(buf)
        emit_i32_load8_u(buf, 8)
        emit_i32_const_raw(buf, 32)
        emit_i32_gt_u(buf)
        emit_br_if(buf, 1) // break if non-whitespace
        emit_local_get(buf, end_local)
        emit_i32_const_raw(buf, 1)
        emit_i32_sub(buf)
        emit_local_set(buf, end_local)
        emit_br(buf, 0)
        emit_end(buf)
        emit_end(buf)
        // new_len = end - start
        emit_local_get(buf, end_local)
        emit_local_get(buf, start_local)
        emit_i32_sub(buf)
        emit_local_set(buf, new_len)
        // allocate new string object: [type:i32, len:i32, bytes...]
        let obj_size_local = alloc_temp_local(ctx)
        emit_local_get(buf, new_len)
        emit_i32_const_raw(buf, 8) // header size
        emit_i32_add(buf)
        emit_local_set(buf, obj_size_local)
        emit_local_get(buf, obj_size_local)
        emit_i32_const_raw(buf, 3)
        emit_i32_add(buf)
        emit_i32_const_raw(buf, -4)
        emit_i32_and(buf)
        emit_local_set(buf, obj_size_local)
        emit_heap_alloc_local(ctx, buf, obj_size_local, new_ptr)
        // set type = obj_string
        emit_local_get(buf, new_ptr)
        emit_i32_const_raw(buf, obj_string)
        emit_i32_store(buf, 0)
        // set length
        emit_local_get(buf, new_ptr)
        emit_local_get(buf, new_len)
        emit_i32_store(buf, 4)
        // copy bytes
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, copy_i)
        emit_block(buf)
        emit_loop(buf)
        emit_local_get(buf, copy_i)
        emit_local_get(buf, new_len)
        emit_i32_lt_s(buf)
        emit_i32_eqz(buf)
        emit_br_if(buf, 1)
        emit_local_get(buf, new_ptr)
        emit_local_get(buf, copy_i)
        emit_i32_add(buf)
        emit_local_get(buf, str_ptr)
        emit_local_get(buf, start_local)
        emit_i32_add(buf)
        emit_local_get(buf, copy_i)
        emit_i32_add(buf)
        emit_i32_load8_u(buf, 8)
        emit_i32_store8(buf, 8)
        emit_local_get(buf, copy_i)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, copy_i)
        emit_br(buf, 0)
        emit_end(buf)
        emit_end(buf)
        // tag as obj pointer
        emit_local_get(buf, new_ptr)
        emit_i64_extend_i32_u(buf)
        emit_i64_const_raw(buf, tag_obj.to_int64())
        emit_i64_or(buf)
      }
    }
    "string_trim_start" if not(is_user_fn) => {
      // string_trim_start(str) -> String (trim leading whitespace)
      let pos_args = extract_positional_exprs_with_arity(
        args, "string_trim_start", 1,
      )
      if ctx.use_js_strings {
        raise WasmGenError::BackendLimit(
          backend="wasm-js-string",
          feature="string_trim_start",
        )
      } else {
        require_heap(ctx)
        let str_ptr = alloc_temp_local(ctx)
        let str_len = alloc_temp_local(ctx)
        let start_local = alloc_temp_local(ctx)
        let new_len = alloc_temp_local(ctx)
        let new_ptr = alloc_temp_local(ctx)
        let copy_i = alloc_temp_local(ctx)
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_i64_const_raw(buf, (-4).to_int64())
        emit_i64_and(buf)
        emit_i32_wrap_i64(buf)
        emit_local_set(buf, str_ptr)
        emit_local_get(buf, str_ptr)
        emit_i32_load(buf, 4)
        emit_local_set(buf, str_len)
        // start = 0; scan forward while whitespace
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, start_local)
        emit_block(buf)
        emit_loop(buf)
        emit_local_get(buf, start_local)
        emit_local_get(buf, str_len)
        emit_i32_lt_s(buf)
        emit_i32_eqz(buf)
        emit_br_if(buf, 1)
        emit_local_get(buf, str_ptr)
        emit_local_get(buf, start_local)
        emit_i32_add(buf)
        emit_i32_load8_u(buf, 8)
        emit_i32_const_raw(buf, 32)
        emit_i32_gt_u(buf)
        emit_br_if(buf, 1)
        emit_local_get(buf, start_local)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, start_local)
        emit_br(buf, 0)
        emit_end(buf)
        emit_end(buf)
        // new_len = str_len - start
        emit_local_get(buf, str_len)
        emit_local_get(buf, start_local)
        emit_i32_sub(buf)
        emit_local_set(buf, new_len)
        // allocate new string
        let obj_size_local = alloc_temp_local(ctx)
        emit_local_get(buf, new_len)
        emit_i32_const_raw(buf, 8)
        emit_i32_add(buf)
        emit_local_set(buf, obj_size_local)
        emit_local_get(buf, obj_size_local)
        emit_i32_const_raw(buf, 3)
        emit_i32_add(buf)
        emit_i32_const_raw(buf, -4)
        emit_i32_and(buf)
        emit_local_set(buf, obj_size_local)
        emit_heap_alloc_local(ctx, buf, obj_size_local, new_ptr)
        emit_local_get(buf, new_ptr)
        emit_i32_const_raw(buf, obj_string)
        emit_i32_store(buf, 0)
        emit_local_get(buf, new_ptr)
        emit_local_get(buf, new_len)
        emit_i32_store(buf, 4)
        // copy bytes
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, copy_i)
        emit_block(buf)
        emit_loop(buf)
        emit_local_get(buf, copy_i)
        emit_local_get(buf, new_len)
        emit_i32_lt_s(buf)
        emit_i32_eqz(buf)
        emit_br_if(buf, 1)
        emit_local_get(buf, new_ptr)
        emit_local_get(buf, copy_i)
        emit_i32_add(buf)
        emit_local_get(buf, str_ptr)
        emit_local_get(buf, start_local)
        emit_i32_add(buf)
        emit_local_get(buf, copy_i)
        emit_i32_add(buf)
        emit_i32_load8_u(buf, 8)
        emit_i32_store8(buf, 8)
        emit_local_get(buf, copy_i)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, copy_i)
        emit_br(buf, 0)
        emit_end(buf)
        emit_end(buf)
        emit_local_get(buf, new_ptr)
        emit_i64_extend_i32_u(buf)
        emit_i64_const_raw(buf, tag_obj.to_int64())
        emit_i64_or(buf)
      }
    }
    "string_trim_end" if not(is_user_fn) => {
      // string_trim_end(str) -> String (trim trailing whitespace)
      let pos_args = extract_positional_exprs_with_arity(
        args, "string_trim_end", 1,
      )
      if ctx.use_js_strings {
        raise WasmGenError::BackendLimit(
          backend="wasm-js-string",
          feature="string_trim_end",
        )
      } else {
        require_heap(ctx)
        let str_ptr = alloc_temp_local(ctx)
        let str_len = alloc_temp_local(ctx)
        let end_local = alloc_temp_local(ctx)
        let new_ptr = alloc_temp_local(ctx)
        let copy_i = alloc_temp_local(ctx)
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_i64_const_raw(buf, (-4).to_int64())
        emit_i64_and(buf)
        emit_i32_wrap_i64(buf)
        emit_local_set(buf, str_ptr)
        emit_local_get(buf, str_ptr)
        emit_i32_load(buf, 4)
        emit_local_set(buf, str_len)
        // end = str_len; scan backward while whitespace
        emit_local_get(buf, str_len)
        emit_local_set(buf, end_local)
        emit_block(buf)
        emit_loop(buf)
        emit_local_get(buf, end_local)
        emit_i32_const_raw(buf, 0)
        emit_i32_gt_s(buf)
        emit_i32_eqz(buf)
        emit_br_if(buf, 1) // break if end <= 0
        emit_local_get(buf, str_ptr)
        emit_local_get(buf, end_local)
        emit_i32_const_raw(buf, 1)
        emit_i32_sub(buf)
        emit_i32_add(buf)
        emit_i32_load8_u(buf, 8)
        emit_i32_const_raw(buf, 32)
        emit_i32_gt_u(buf)
        emit_br_if(buf, 1) // break if non-whitespace
        emit_local_get(buf, end_local)
        emit_i32_const_raw(buf, 1)
        emit_i32_sub(buf)
        emit_local_set(buf, end_local)
        emit_br(buf, 0)
        emit_end(buf)
        emit_end(buf)
        // allocate new string of length end
        let obj_size_local = alloc_temp_local(ctx)
        emit_local_get(buf, end_local)
        emit_i32_const_raw(buf, 8)
        emit_i32_add(buf)
        emit_local_set(buf, obj_size_local)
        emit_local_get(buf, obj_size_local)
        emit_i32_const_raw(buf, 3)
        emit_i32_add(buf)
        emit_i32_const_raw(buf, -4)
        emit_i32_and(buf)
        emit_local_set(buf, obj_size_local)
        emit_heap_alloc_local(ctx, buf, obj_size_local, new_ptr)
        emit_local_get(buf, new_ptr)
        emit_i32_const_raw(buf, obj_string)
        emit_i32_store(buf, 0)
        emit_local_get(buf, new_ptr)
        emit_local_get(buf, end_local)
        emit_i32_store(buf, 4)
        // copy bytes from start
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, copy_i)
        emit_block(buf)
        emit_loop(buf)
        emit_local_get(buf, copy_i)
        emit_local_get(buf, end_local)
        emit_i32_lt_s(buf)
        emit_i32_eqz(buf)
        emit_br_if(buf, 1)
        emit_local_get(buf, new_ptr)
        emit_local_get(buf, copy_i)
        emit_i32_add(buf)
        emit_local_get(buf, str_ptr)
        emit_local_get(buf, copy_i)
        emit_i32_add(buf)
        emit_i32_load8_u(buf, 8)
        emit_i32_store8(buf, 8)
        emit_local_get(buf, copy_i)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, copy_i)
        emit_br(buf, 0)
        emit_end(buf)
        emit_end(buf)
        emit_local_get(buf, new_ptr)
        emit_i64_extend_i32_u(buf)
        emit_i64_const_raw(buf, tag_obj.to_int64())
        emit_i64_or(buf)
      }
    }
    "string_to_upper" if not(is_user_fn) => {
      // string_to_upper(str) -> String (convert ASCII lowercase to uppercase)
      let pos_args = extract_positional_exprs_with_arity(
        args, "string_to_upper", 1,
      )
      if ctx.use_js_strings {
        raise WasmGenError::BackendLimit(
          backend="wasm-js-string",
          feature="string_to_upper",
        )
      } else {
        require_heap(ctx)
        let str_ptr = alloc_temp_local(ctx)
        let str_len = alloc_temp_local(ctx)
        let new_ptr = alloc_temp_local(ctx)
        let copy_i = alloc_temp_local(ctx)
        let byte_local = alloc_temp_local(ctx)
        // Untag and get source string pointer
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_i64_const_raw(buf, (-4).to_int64())
        emit_i64_and(buf)
        emit_i32_wrap_i64(buf)
        emit_local_set(buf, str_ptr)
        // Get source string length
        emit_local_get(buf, str_ptr)
        emit_i32_load(buf, 4)
        emit_local_set(buf, str_len)
        // Allocate new string: [type:i32, len:i32, bytes...]
        let obj_size_local = alloc_temp_local(ctx)
        emit_local_get(buf, str_len)
        emit_i32_const_raw(buf, 8)
        emit_i32_add(buf)
        emit_local_set(buf, obj_size_local)
        emit_local_get(buf, obj_size_local)
        emit_i32_const_raw(buf, 3)
        emit_i32_add(buf)
        emit_i32_const_raw(buf, -4)
        emit_i32_and(buf)
        emit_local_set(buf, obj_size_local)
        emit_heap_alloc_local(ctx, buf, obj_size_local, new_ptr)
        // Set type = obj_string
        emit_local_get(buf, new_ptr)
        emit_i32_const_raw(buf, obj_string)
        emit_i32_store(buf, 0)
        // Set length
        emit_local_get(buf, new_ptr)
        emit_local_get(buf, str_len)
        emit_i32_store(buf, 4)
        // Copy bytes, converting lowercase to uppercase
        // Branchless: new_byte = byte - 32 * ((byte >= 'a') & (byte <= 'z'))
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, copy_i)
        emit_block(buf)
        emit_loop(buf)
        emit_local_get(buf, copy_i)
        emit_local_get(buf, str_len)
        emit_i32_lt_s(buf)
        emit_i32_eqz(buf)
        emit_br_if(buf, 1)
        // Read source byte
        emit_local_get(buf, str_ptr)
        emit_local_get(buf, copy_i)
        emit_i32_add(buf)
        emit_i32_load8_u(buf, 8)
        emit_local_set(buf, byte_local)
        // Store address = new_ptr + copy_i
        emit_local_get(buf, new_ptr)
        emit_local_get(buf, copy_i)
        emit_i32_add(buf)
        // Compute: byte - 32 * (byte >= 97 && byte <= 122)
        emit_local_get(buf, byte_local)
        emit_i32_const_raw(buf, 32)
        emit_local_get(buf, byte_local)
        emit_i32_const_raw(buf, 97) // 'a'
        emit_i32_ge_s(buf)
        emit_local_get(buf, byte_local)
        emit_i32_const_raw(buf, 122) // 'z'
        emit_i32_le_s(buf)
        emit_i32_and(buf)
        emit_i32_mul(buf)
        emit_i32_sub(buf)
        emit_i32_store8(buf, 8)
        // i++
        emit_local_get(buf, copy_i)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, copy_i)
        emit_br(buf, 0)
        emit_end(buf)
        emit_end(buf)
        // Tag as obj pointer
        emit_local_get(buf, new_ptr)
        emit_i64_extend_i32_u(buf)
        emit_i64_const_raw(buf, tag_obj.to_int64())
        emit_i64_or(buf)
      }
    }
    "string_to_lower" if not(is_user_fn) => {
      // string_to_lower(str) -> String (convert ASCII uppercase to lowercase)
      let pos_args = extract_positional_exprs_with_arity(
        args, "string_to_lower", 1,
      )
      if ctx.use_js_strings {
        raise WasmGenError::BackendLimit(
          backend="wasm-js-string",
          feature="string_to_lower",
        )
      } else {
        require_heap(ctx)
        let str_ptr = alloc_temp_local(ctx)
        let str_len = alloc_temp_local(ctx)
        let new_ptr = alloc_temp_local(ctx)
        let copy_i = alloc_temp_local(ctx)
        let byte_local = alloc_temp_local(ctx)
        // Untag and get source string pointer
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_i64_const_raw(buf, (-4).to_int64())
        emit_i64_and(buf)
        emit_i32_wrap_i64(buf)
        emit_local_set(buf, str_ptr)
        // Get source string length
        emit_local_get(buf, str_ptr)
        emit_i32_load(buf, 4)
        emit_local_set(buf, str_len)
        // Allocate new string: [type:i32, len:i32, bytes...]
        let obj_size_local = alloc_temp_local(ctx)
        emit_local_get(buf, str_len)
        emit_i32_const_raw(buf, 8)
        emit_i32_add(buf)
        emit_local_set(buf, obj_size_local)
        emit_local_get(buf, obj_size_local)
        emit_i32_const_raw(buf, 3)
        emit_i32_add(buf)
        emit_i32_const_raw(buf, -4)
        emit_i32_and(buf)
        emit_local_set(buf, obj_size_local)
        emit_heap_alloc_local(ctx, buf, obj_size_local, new_ptr)
        // Set type = obj_string
        emit_local_get(buf, new_ptr)
        emit_i32_const_raw(buf, obj_string)
        emit_i32_store(buf, 0)
        // Set length
        emit_local_get(buf, new_ptr)
        emit_local_get(buf, str_len)
        emit_i32_store(buf, 4)
        // Copy bytes, converting uppercase to lowercase
        // Branchless: new_byte = byte + 32 * ((byte >= 'A') & (byte <= 'Z'))
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, copy_i)
        emit_block(buf)
        emit_loop(buf)
        emit_local_get(buf, copy_i)
        emit_local_get(buf, str_len)
        emit_i32_lt_s(buf)
        emit_i32_eqz(buf)
        emit_br_if(buf, 1)
        // Read source byte
        emit_local_get(buf, str_ptr)
        emit_local_get(buf, copy_i)
        emit_i32_add(buf)
        emit_i32_load8_u(buf, 8)
        emit_local_set(buf, byte_local)
        // Store address = new_ptr + copy_i
        emit_local_get(buf, new_ptr)
        emit_local_get(buf, copy_i)
        emit_i32_add(buf)
        // Compute: byte + 32 * (byte >= 65 && byte <= 90)
        emit_local_get(buf, byte_local)
        emit_i32_const_raw(buf, 32)
        emit_local_get(buf, byte_local)
        emit_i32_const_raw(buf, 65) // 'A'
        emit_i32_ge_s(buf)
        emit_local_get(buf, byte_local)
        emit_i32_const_raw(buf, 90) // 'Z'
        emit_i32_le_s(buf)
        emit_i32_and(buf)
        emit_i32_mul(buf)
        emit_i32_add(buf)
        emit_i32_store8(buf, 8)
        // i++
        emit_local_get(buf, copy_i)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, copy_i)
        emit_br(buf, 0)
        emit_end(buf)
        emit_end(buf)
        // Tag as obj pointer
        emit_local_get(buf, new_ptr)
        emit_i64_extend_i32_u(buf)
        emit_i64_const_raw(buf, tag_obj.to_int64())
        emit_i64_or(buf)
      }
    }
    "string_replace" if not(is_user_fn) => {
      // string_replace(str, pattern, replacement) -> String (replace first occurrence)
      let pos_args = extract_positional_exprs_with_arity(
        args, "string_replace", 3,
      )
      if ctx.use_js_strings {
        raise WasmGenError::BackendLimit(
          backend="wasm-js-string",
          feature="string_replace",
        )
      } else {
        emit_string_replace_impl(ctx, buf, pos_args, replace_all=false)
      }
    }
    "string_replace_all" if not(is_user_fn) => {
      // string_replace_all(str, pattern, replacement) -> String (replace all occurrences)
      let pos_args = extract_positional_exprs_with_arity(
        args, "string_replace_all", 3,
      )
      if ctx.use_js_strings {
        raise WasmGenError::BackendLimit(
          backend="wasm-js-string",
          feature="string_replace_all",
        )
      } else {
        emit_string_replace_impl(ctx, buf, pos_args, replace_all=true)
      }
    }
    "string_builder" => {
      // string_builder() -> allocate empty array obj with len=0 (same layout as array_builder)
      let max_cap = 4096
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
      let pos_args = extract_positional_exprs_with_arity(
        args, "string_builder_push", 2,
      )
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
      let pos_args = extract_positional_exprs_with_arity(
        args, "string_builder_freeze", 1,
      )
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
      let max_cap = 4096
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
      let pos_args = extract_positional_exprs_with_arity(
        args, "array_builder_push", 2,
      )
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
      let pos_args = extract_positional_exprs_with_arity(
        args, "array_builder_freeze", 1,
      )
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
      let pos_args = extract_positional_exprs_with_arity(
        args, "map_builder_set", 3,
      )
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
      let pos_args = extract_positional_exprs_with_arity(
        args, "map_builder_freeze", 1,
      )
      compile_expr_i32(ctx, buf, pos_args[0])
    }
    "map_has_key" => {
      // map_has_key(map, key) -> linear search for key, return tagged bool
      let pos_args = extract_positional_exprs_with_arity(args, "map_has_key", 2)
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
      let pos_args = extract_positional_exprs_with_arity(args, "map_keys", 1)
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
      let pos_args = extract_positional_exprs_with_arity(args, "map_values", 1)
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
      let pos_args = extract_positional_exprs_with_arity(
        args, "array_length", 1,
      )
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
    "iter_require" if not(is_user_fn) => {
      // iter_require(xs) -> identity (prelude fallback for Array iteration)
      let pos_args = extract_positional_exprs_with_arity(
        args, "iter_require", 1,
      )
      compile_expr(ctx, buf, pos_args[0])
    }
    "iter_length" if not(is_user_fn) => {
      // iter_length(xs) -> fallback to array_length(xs)
      let pos_args = extract_positional_exprs_with_arity(args, "iter_length", 1)
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
    "iter_get" if not(is_user_fn) => {
      // iter_get(xs, idx) -> fallback to array_get(xs, idx)
      let pos_args = extract_positional_exprs_with_arity(args, "iter_get", 2)
      let ptr_local = alloc_temp_local(ctx)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_i64_const_raw(buf, (-4).to_int64())
      emit_i64_and(buf)
      emit_i32_wrap_i64(buf)
      emit_local_set(buf, ptr_local)
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
    "array_get" => {
      // array_get(arr, idx) -> load arr[idx]
      let pos_args = extract_positional_exprs_with_arity(args, "array_get", 2)
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
    "__index" => {
      // __index(obj, key) -> record/map field access when key is string,
      //                      array_get when key is integer
      let pos_args = extract_positional_exprs_with_arity(args, "__index", 2)
      match pos_args[1] {
        @core.Expr::String(value=field_name, ..) => {
          // Record/Map field access by string key: linear search through
          // (name_ptr, value) pairs with stride 8.
          let obj_ptr = alloc_temp_local(ctx)
          let obj_len = alloc_temp_local(ctx)
          let loop_i = alloc_temp_local(ctx)
          let result_local = alloc_temp_local(ctx)
          let field_ptr = ctx.strings.intern(field_name)
          compile_expr_i32(ctx, buf, pos_args[0])
          emit_i64_const_raw(buf, (-4).to_int64())
          emit_i64_and(buf)
          emit_i32_wrap_i64(buf)
          emit_local_set(buf, obj_ptr)
          emit_local_get(buf, obj_ptr)
          emit_i32_load(buf, 4)
          emit_local_set(buf, obj_len)
          emit_i32_const_raw(buf, 0)
          emit_local_set(buf, loop_i)
          emit_i64_const_tagged(buf, 0L)
          emit_i32_wrap_i64(buf)
          emit_local_set(buf, result_local)
          // loop: compare name pointers, load value on match
          buf.push((3).to_byte()) // loop
          buf.push((64).to_byte()) // void
          emit_local_get(buf, loop_i)
          emit_local_get(buf, obj_len)
          emit_i32_lt_s(buf)
          buf.push((4).to_byte()) // if
          buf.push((64).to_byte()) // void
          // load name_ptr at obj_ptr + loop_i * 8 + 8
          emit_local_get(buf, obj_ptr)
          emit_local_get(buf, loop_i)
          emit_i32_const_raw(buf, 8)
          emit_i32_mul(buf)
          emit_i32_add(buf)
          emit_i32_load(buf, 8) // name_ptr
          emit_i32_const_raw(buf, field_ptr)
          emit_i32_eq(buf)
          buf.push((4).to_byte()) // if (name matches)
          buf.push((64).to_byte()) // void
          // load value at obj_ptr + loop_i * 8 + 12
          emit_local_get(buf, obj_ptr)
          emit_local_get(buf, loop_i)
          emit_i32_const_raw(buf, 8)
          emit_i32_mul(buf)
          emit_i32_add(buf)
          emit_i32_load(buf, 12) // value
          emit_local_set(buf, result_local)
          buf.push((11).to_byte()) // end if (name matches)
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
        }
        _ => {
          // Integer index: array-style direct access
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
      }
    }
    "__set_index" => {
      // __set_index(arr, idx, value) -> arr[idx] = value; return value
      // This is used by index-assignment desugaring (e.g. cursor[0] = x).
      let pos_args = extract_positional_exprs_with_arity(args, "__set_index", 3)
      let ptr_local = alloc_temp_local(ctx)
      let idx_local = alloc_temp_local(ctx)
      let value_local = alloc_temp_local_with_kind(ctx, ValueKind::I64)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_i64_const_raw(buf, (-4).to_int64())
      emit_i64_and(buf)
      emit_i32_wrap_i64(buf)
      emit_local_set(buf, ptr_local)
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_i64_const_raw(buf, 2L)
      emit_i64_shr_s(buf)
      emit_i32_wrap_i64(buf)
      emit_local_set(buf, idx_local)
      compile_expr_i32(ctx, buf, pos_args[2])
      emit_local_set(buf, value_local)
      emit_local_get(buf, ptr_local)
      emit_local_get(buf, idx_local)
      emit_i32_const_raw(buf, 4)
      emit_i32_mul(buf)
      emit_i32_add(buf)
      emit_local_get(buf, value_local)
      emit_i32_wrap_i64(buf)
      emit_i32_store(buf, 8)
      emit_local_get(buf, value_local)
    }
    "map_get" => {
      // map_get(map, key) -> linear search for key, return value
      let pos_args = extract_positional_exprs_with_arity(args, "map_get", 2)
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
      let pos_args = extract_positional_exprs_with_arity(args, "sleep", 1)
      // Compile the duration argument (tagged int)
      compile_expr_i32(ctx, buf, pos_args[0])
      // Call imported sleep function (host will untag: ms >> 2)
      buf.push((0x10).to_byte()) // call
      write_u32_leb(buf, ctx.sleep_import_index)
      // Return Unit (tagged 0)
      emit_i64_const_raw(buf, tag_int_value64(0L))
    }
    "stdout_write_char" => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "stdout_write_char", 1,
      )
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
      let pos_args = extract_positional_exprs_with_arity(
        args, "stdout_write_stream", 1,
      )
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
      let _ = extract_positional_exprs_with_arity(args, "stdin_read_char", 0)
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
      let pos_args = extract_positional_exprs_with_arity(
        args, "stdin_read_stream", 1,
      )
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
      let pos_args = extract_positional_exprs_with_arity(args, "fs_exists", 1)
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
      let pos_args = extract_positional_exprs_with_arity(
        args, "fs_read_file", 1,
      )
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
      let pos_args = extract_positional_exprs_with_arity(
        args, "fs_write_file", 2,
      )
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
      let pos_args = extract_positional_exprs_with_arity(
        args, "socket_tcp_connect", 2,
      )
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
      let pos_args = extract_positional_exprs_with_arity(
        args, "socket_tcp_read", 2,
      )
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
      let pos_args = extract_positional_exprs_with_arity(
        args, "socket_tcp_write", 2,
      )
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
      let pos_args = extract_positional_exprs_with_arity(
        args, "socket_tcp_close", 1,
      )
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
    | "http_respond" =>
      if ctx.need_http && ctx.http_host_imports {
        if ctx.use_js_strings {
          raise WasmGenError::Unsupported(
            "http host imports require --wasm backend",
          )
        }
        match name {
          "http_request" => {
            let pos_args = extract_positional_exprs_with_arity(
              args, "http_request", 4,
            )
            compile_expr(ctx, buf, pos_args[0])
            compile_expr(ctx, buf, pos_args[1])
            compile_expr(ctx, buf, pos_args[2])
            compile_expr(ctx, buf, pos_args[3])
            emit_call(buf, import_index_http_request(ctx))
          }
          "http_response_status" => {
            let pos_args = extract_positional_exprs_with_arity(
              args, "http_response_status", 1,
            )
            compile_expr(ctx, buf, pos_args[0])
            emit_call(buf, import_index_http_response_status(ctx))
          }
          "http_response_header" => {
            let pos_args = extract_positional_exprs_with_arity(
              args, "http_response_header", 2,
            )
            compile_expr(ctx, buf, pos_args[0])
            compile_expr(ctx, buf, pos_args[1])
            emit_call(buf, import_index_http_response_header(ctx))
          }
          "http_response_body" => {
            let pos_args = extract_positional_exprs_with_arity(
              args, "http_response_body", 1,
            )
            compile_expr(ctx, buf, pos_args[0])
            emit_call(buf, import_index_http_response_body(ctx))
          }
          "http_close" => {
            let pos_args = extract_positional_exprs_with_arity(
              args, "http_close", 1,
            )
            compile_expr(ctx, buf, pos_args[0])
            emit_call(buf, import_index_http_close(ctx))
            buf.push((26).to_byte()) // drop host return
            emit_i64_const_raw(buf, tag_int_value64(0L))
          }
          "http_listen" => {
            let pos_args = extract_positional_exprs_with_arity(
              args, "http_listen", 1,
            )
            compile_expr(ctx, buf, pos_args[0])
            emit_call(buf, import_index_http_listen(ctx))
          }
          "http_accept" => {
            let pos_args = extract_positional_exprs_with_arity(
              args, "http_accept", 1,
            )
            compile_expr(ctx, buf, pos_args[0])
            emit_call(buf, import_index_http_accept(ctx))
          }
          "http_request_method" => {
            let pos_args = extract_positional_exprs_with_arity(
              args, "http_request_method", 1,
            )
            compile_expr(ctx, buf, pos_args[0])
            emit_call(buf, import_index_http_request_method(ctx))
          }
          "http_request_url" => {
            let pos_args = extract_positional_exprs_with_arity(
              args, "http_request_url", 1,
            )
            compile_expr(ctx, buf, pos_args[0])
            emit_call(buf, import_index_http_request_url(ctx))
          }
          "http_request_header" => {
            let pos_args = extract_positional_exprs_with_arity(
              args, "http_request_header", 2,
            )
            compile_expr(ctx, buf, pos_args[0])
            compile_expr(ctx, buf, pos_args[1])
            emit_call(buf, import_index_http_request_header(ctx))
          }
          "http_request_body" => {
            let pos_args = extract_positional_exprs_with_arity(
              args, "http_request_body", 1,
            )
            compile_expr(ctx, buf, pos_args[0])
            emit_call(buf, import_index_http_request_body(ctx))
          }
          "http_respond" => {
            let pos_args = extract_positional_exprs_with_arity(
              args, "http_respond", 4,
            )
            compile_expr(ctx, buf, pos_args[0])
            compile_expr(ctx, buf, pos_args[1])
            compile_expr(ctx, buf, pos_args[2])
            compile_expr(ctx, buf, pos_args[3])
            emit_call(buf, import_index_http_respond(ctx))
            buf.push((26).to_byte()) // drop host return
            emit_i64_const_raw(buf, tag_int_value64(0L))
          }
          _ => raise WasmGenError::Unsupported("unknown http builtin: " + name)
        }
      } else {
        // WASI P3 HTTP is draft; emit raise with error message instead of
        // unreachable trap so the error is catchable by try/catch.
        let msg = name + " is not available on wasm target"
        if not(ctx.use_js_strings) && not(ctx.embed_error_strings) {
          emit_i64_const_tagged(buf, intern_error_code(ctx, msg).to_int64())
        } else if ctx.use_js_strings {
          emit_string_const(ctx, buf, msg)
        } else {
          emit_i64_const_raw(buf, tag_ptr64(ctx.strings.intern(msg), tag_obj))
        }
        buf.push((8).to_byte()) // throw
        write_u32_leb(buf, ctx.error_tag_index)
      }
    "char_to_int" => {
      let pos_args = extract_positional_exprs_with_arity(args, "char_to_int", 1)
      compile_expr(ctx, buf, pos_args[0])
    }
    "char_from_int" => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "char_from_int", 1,
      )
      compile_expr(ctx, buf, pos_args[0])
    }
    "__perform" => {
      let pos_args = extract_positional_exprs_with_arity(args, "__perform", 1)
      if ctx.use_js_strings {
        compile_expr(ctx, buf, pos_args[0])
      } else {
        compile_expr_i32(ctx, buf, pos_args[0])
      }
      buf.push((8).to_byte()) // throw
      write_u32_leb(buf, ctx.error_tag_index)
    }
    "__resume" => {
      let pos_args = extract_positional_exprs_with_arity(args, "__resume", 1)
      // Experimental fallback: encode resume as throw on wasm backend.
      // Proper continuation resume requires stack-switching-aware lowering.
      if ctx.use_js_strings {
        compile_expr(ctx, buf, pos_args[0])
      } else {
        compile_expr_i32(ctx, buf, pos_args[0])
      }
      buf.push((8).to_byte()) // throw
      write_u32_leb(buf, ctx.error_tag_index)
    }
    "string_from_char_code" => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "string_from_char_code", 1,
      )
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
    _ if not(is_user_fn) && is_wasm_runtime_fallback_builtin(name) =>
      emit_wasm_runtime_fallback_throw(ctx, buf, name)
    _ => raise WasmGenError::Unsupported(pre_user_builtin_unhandled_marker)
  }
}

///|
/// Emit WASM for string_replace / string_replace_all.
/// Uses string_builder-like buffer approach:
/// 1. Find match(es) of pattern in source
/// 2. Build result by copying segments + replacement
fn emit_string_replace_impl(
  ctx : CodegenCtx,
  buf : ByteBuf,
  pos_args : Array[@core.Expr],
  replace_all~ : Bool,
) -> Unit raise WasmGenError {
  require_heap(ctx)
  let str_ptr = alloc_temp_local(ctx)
  let str_len = alloc_temp_local(ctx)
  let pat_ptr = alloc_temp_local(ctx)
  let pat_len = alloc_temp_local(ctx)
  let rep_ptr = alloc_temp_local(ctx)
  let rep_len = alloc_temp_local(ctx)
  let match_count = alloc_temp_local(ctx)
  let scan_i = alloc_temp_local(ctx)
  let scan_j = alloc_temp_local(ctx)
  let scan_match = alloc_temp_local(ctx)
  let new_len = alloc_temp_local(ctx)
  let new_ptr = alloc_temp_local(ctx)
  let src_i = alloc_temp_local(ctx)
  let dst_i = alloc_temp_local(ctx)
  let copy_j = alloc_temp_local(ctx)
  // Untag source string
  compile_expr_i32(ctx, buf, pos_args[0])
  emit_i64_const_raw(buf, (-4).to_int64())
  emit_i64_and(buf)
  emit_i32_wrap_i64(buf)
  emit_local_set(buf, str_ptr)
  emit_local_get(buf, str_ptr)
  emit_i32_load(buf, 4)
  emit_local_set(buf, str_len)
  // Untag pattern string
  compile_expr_i32(ctx, buf, pos_args[1])
  emit_i64_const_raw(buf, (-4).to_int64())
  emit_i64_and(buf)
  emit_i32_wrap_i64(buf)
  emit_local_set(buf, pat_ptr)
  emit_local_get(buf, pat_ptr)
  emit_i32_load(buf, 4)
  emit_local_set(buf, pat_len)
  // Untag replacement string
  compile_expr_i32(ctx, buf, pos_args[2])
  emit_i64_const_raw(buf, (-4).to_int64())
  emit_i64_and(buf)
  emit_i32_wrap_i64(buf)
  emit_local_set(buf, rep_ptr)
  emit_local_get(buf, rep_ptr)
  emit_i32_load(buf, 4)
  emit_local_set(buf, rep_len)
  // Pass 1: Count matches
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, match_count)
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, scan_i)
  // Handle empty pattern: match_count = 0 (no replacement)
  emit_local_get(buf, pat_len)
  emit_i32_const_raw(buf, 0)
  emit_i32_gt_s(buf)
  emit_block(buf) // block $skip_count
  emit_br_if(buf, 0) // if pat_len > 0, skip the br that skips counting
  // pat_len == 0: skip counting, match_count stays 0
  emit_br(buf, 0)
  emit_end(buf) // end $skip_count — fall through means pat_len > 0
  // Count loop: scan for all occurrences
  emit_block(buf) // block $count_break
  emit_loop(buf) // loop $count_loop
  // if scan_i > str_len - pat_len, break
  emit_local_get(buf, scan_i)
  emit_local_get(buf, str_len)
  emit_local_get(buf, pat_len)
  emit_i32_sub(buf)
  emit_i32_gt_s(buf)
  emit_br_if(buf, 1) // break $count_break
  // Check if pattern matches at scan_i
  emit_i32_const_raw(buf, 1)
  emit_local_set(buf, scan_match)
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, scan_j)
  emit_block(buf) // block $match_break
  emit_loop(buf) // loop $match_loop
  emit_local_get(buf, scan_j)
  emit_local_get(buf, pat_len)
  emit_i32_ge_s(buf)
  emit_br_if(buf, 1) // break if j >= pat_len (all bytes matched)
  // Compare bytes
  emit_local_get(buf, str_ptr)
  emit_local_get(buf, scan_i)
  emit_i32_add(buf)
  emit_local_get(buf, scan_j)
  emit_i32_add(buf)
  emit_i32_load8_u(buf, 8)
  emit_local_get(buf, pat_ptr)
  emit_local_get(buf, scan_j)
  emit_i32_add(buf)
  emit_i32_load8_u(buf, 8)
  emit_i32_ne(buf)
  emit_block(buf) // block for mismatch
  emit_br_if(buf, 0) // if not equal, jump to mismatch handler
  // Equal: j++, continue
  emit_local_get(buf, scan_j)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, scan_j)
  emit_br(buf, 1) // continue $match_loop
  emit_end(buf) // end mismatch block — fall through means mismatch
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, scan_match)
  emit_br(buf, 1) // break $match_break
  emit_end(buf) // end $match_loop
  emit_end(buf) // end $match_break
  // If scan_match: count++, advance by pat_len
  emit_local_get(buf, scan_match)
  emit_block(buf) // block $no_match
  emit_i32_eqz(buf)
  emit_br_if(buf, 0) // if not matched, skip
  // Matched
  emit_local_get(buf, match_count)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, match_count)
  if not(replace_all) {
    // For replace (not replace_all), break after first match
    emit_br(buf, 2) // break $count_break
  } else {
    // Advance by pat_len to avoid overlapping matches
    emit_local_get(buf, scan_i)
    emit_local_get(buf, pat_len)
    emit_i32_add(buf)
    emit_local_set(buf, scan_i)
    emit_br(buf, 1) // continue $count_loop
  }
  emit_end(buf) // end $no_match
  // Not matched, advance by 1
  emit_local_get(buf, scan_i)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, scan_i)
  emit_br(buf, 0) // continue $count_loop
  emit_end(buf) // end $count_loop
  emit_end(buf) // end $count_break
  // Compute new_len = str_len + match_count * (rep_len - pat_len)
  emit_local_get(buf, str_len)
  emit_local_get(buf, match_count)
  emit_local_get(buf, rep_len)
  emit_local_get(buf, pat_len)
  emit_i32_sub(buf)
  emit_i32_mul(buf)
  emit_i32_add(buf)
  emit_local_set(buf, new_len)
  // Allocate new string
  let obj_size_local = alloc_temp_local(ctx)
  emit_local_get(buf, new_len)
  emit_i32_const_raw(buf, 8)
  emit_i32_add(buf)
  emit_local_set(buf, obj_size_local)
  emit_local_get(buf, obj_size_local)
  emit_i32_const_raw(buf, 3)
  emit_i32_add(buf)
  emit_i32_const_raw(buf, -4)
  emit_i32_and(buf)
  emit_local_set(buf, obj_size_local)
  emit_heap_alloc_local(ctx, buf, obj_size_local, new_ptr)
  // Set header
  emit_local_get(buf, new_ptr)
  emit_i32_const_raw(buf, obj_string)
  emit_i32_store(buf, 0)
  emit_local_get(buf, new_ptr)
  emit_local_get(buf, new_len)
  emit_i32_store(buf, 4)
  // Pass 2: Build result — copy source with replacements
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, src_i) // source read position
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, dst_i) // dest write position
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, match_count) // reuse as remaining matches
  // Build loop
  emit_block(buf) // block $build_break
  emit_loop(buf) // loop $build_loop
  // if src_i >= str_len, break
  emit_local_get(buf, src_i)
  emit_local_get(buf, str_len)
  emit_i32_ge_s(buf)
  emit_br_if(buf, 1) // break $build_break
  // Check for pattern match at src_i (only if pat_len > 0 and src_i + pat_len <= str_len)
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, scan_match) // default: no match
  emit_local_get(buf, pat_len)
  emit_i32_const_raw(buf, 0)
  emit_i32_gt_s(buf)
  emit_local_get(buf, src_i)
  emit_local_get(buf, pat_len)
  emit_i32_add(buf)
  emit_local_get(buf, str_len)
  emit_i32_le_s(buf)
  emit_i32_and(buf)
  emit_block(buf) // block $skip_match_check
  emit_i32_eqz(buf)
  emit_br_if(buf, 0) // skip if can't match
  // Check pattern
  emit_i32_const_raw(buf, 1)
  emit_local_set(buf, scan_match)
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, scan_j)
  emit_block(buf) // block $mc_break
  emit_loop(buf) // loop $mc_loop
  emit_local_get(buf, scan_j)
  emit_local_get(buf, pat_len)
  emit_i32_ge_s(buf)
  emit_br_if(buf, 1) // break if j >= pat_len
  emit_local_get(buf, str_ptr)
  emit_local_get(buf, src_i)
  emit_i32_add(buf)
  emit_local_get(buf, scan_j)
  emit_i32_add(buf)
  emit_i32_load8_u(buf, 8)
  emit_local_get(buf, pat_ptr)
  emit_local_get(buf, scan_j)
  emit_i32_add(buf)
  emit_i32_load8_u(buf, 8)
  emit_i32_ne(buf)
  emit_block(buf)
  emit_br_if(buf, 0) // mismatch
  emit_local_get(buf, scan_j)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, scan_j)
  emit_br(buf, 1) // continue $mc_loop
  emit_end(buf) // end mismatch block
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, scan_match)
  emit_br(buf, 1) // break $mc_break
  emit_end(buf) // end $mc_loop
  emit_end(buf) // end $mc_break
  emit_end(buf) // end $skip_match_check
  // If matched: copy replacement, advance src by pat_len
  emit_local_get(buf, scan_match)
  emit_block(buf) // block $no_replace
  emit_i32_eqz(buf)
  emit_br_if(buf, 0) // skip if no match
  // Copy replacement bytes
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, copy_j)
  emit_block(buf)
  emit_loop(buf)
  emit_local_get(buf, copy_j)
  emit_local_get(buf, rep_len)
  emit_i32_ge_s(buf)
  emit_br_if(buf, 1)
  emit_local_get(buf, new_ptr)
  emit_local_get(buf, dst_i)
  emit_i32_add(buf)
  emit_local_get(buf, rep_ptr)
  emit_local_get(buf, copy_j)
  emit_i32_add(buf)
  emit_i32_load8_u(buf, 8)
  emit_i32_store8(buf, 8)
  emit_local_get(buf, dst_i)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, dst_i)
  emit_local_get(buf, copy_j)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, copy_j)
  emit_br(buf, 0)
  emit_end(buf)
  emit_end(buf)
  // Advance src by pat_len
  emit_local_get(buf, src_i)
  emit_local_get(buf, pat_len)
  emit_i32_add(buf)
  emit_local_set(buf, src_i)
  // Track replacements done
  emit_local_get(buf, match_count)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, match_count)
  if not(replace_all) {
    // After first replacement, copy remaining bytes directly
    // Copy remaining: str[src_i..str_len] to dst
    emit_block(buf) // block $copy_rest_break
    emit_loop(buf) // loop $copy_rest_loop
    emit_local_get(buf, src_i)
    emit_local_get(buf, str_len)
    emit_i32_ge_s(buf)
    emit_br_if(buf, 1) // break
    emit_local_get(buf, new_ptr)
    emit_local_get(buf, dst_i)
    emit_i32_add(buf)
    emit_local_get(buf, str_ptr)
    emit_local_get(buf, src_i)
    emit_i32_add(buf)
    emit_i32_load8_u(buf, 8)
    emit_i32_store8(buf, 8)
    emit_local_get(buf, src_i)
    emit_i32_const_raw(buf, 1)
    emit_i32_add(buf)
    emit_local_set(buf, src_i)
    emit_local_get(buf, dst_i)
    emit_i32_const_raw(buf, 1)
    emit_i32_add(buf)
    emit_local_set(buf, dst_i)
    emit_br(buf, 0) // continue
    emit_end(buf) // end $copy_rest_loop
    emit_end(buf) // end $copy_rest_break
    emit_br(buf, 2) // break $build_break (done)
  }
  emit_br(buf, 1) // continue $build_loop
  emit_end(buf) // end $no_replace
  // No match: copy single byte
  emit_local_get(buf, new_ptr)
  emit_local_get(buf, dst_i)
  emit_i32_add(buf)
  emit_local_get(buf, str_ptr)
  emit_local_get(buf, src_i)
  emit_i32_add(buf)
  emit_i32_load8_u(buf, 8)
  emit_i32_store8(buf, 8)
  emit_local_get(buf, src_i)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, src_i)
  emit_local_get(buf, dst_i)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, dst_i)
  emit_br(buf, 0) // continue $build_loop
  emit_end(buf) // end $build_loop
  emit_end(buf) // end $build_break
  // Tag result as obj pointer
  emit_local_get(buf, new_ptr)
  emit_i64_extend_i32_u(buf)
  emit_i64_const_raw(buf, tag_obj.to_int64())
  emit_i64_or(buf)
}
