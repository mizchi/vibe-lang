///|
let pre_user_builtin_unhandled_marker = "__pre_user_builtin_unhandled__"

///|
fn emit_bytes_raw_load_header(
  buf : ByteBuf,
  ptr_local : Int,
  len_local : Int,
  cap_local : Int,
  data_local : Int,
) -> Unit {
  emit_local_get(buf, ptr_local)
  emit_i32_load(buf, 4)
  emit_local_set(buf, len_local)
  emit_local_get(buf, ptr_local)
  emit_i32_load(buf, 8)
  emit_local_set(buf, cap_local)
  emit_local_get(buf, ptr_local)
  emit_i32_load(buf, 12)
  emit_local_set(buf, data_local)
  // Negative cap means the raw bytes object is shared/frozen.
  // Decode: cap < 0 → 0 - cap - 1 (symmetric with emit_bytes_raw_mark_shared encode).
  emit_local_get(buf, cap_local)
  emit_i32_const_raw(buf, 0)
  emit_i32_lt_s(buf)
  buf.push((4).to_byte()) // if
  buf.push((127).to_byte()) // result i32
  emit_i32_const_raw(buf, 0)
  emit_local_get(buf, cap_local)
  emit_i32_sub(buf)
  emit_i32_const_raw(buf, 1)
  emit_i32_sub(buf)
  buf.push((5).to_byte()) // else
  emit_local_get(buf, cap_local)
  buf.push((11).to_byte()) // end if
  emit_local_set(buf, cap_local)
}

///|
fn emit_bytes_raw_mark_shared(
  ctx : CodegenCtx,
  buf : ByteBuf,
  ptr_local : Int,
) -> Unit {
  let raw_cap_local = alloc_temp_local(ctx)
  emit_local_get(buf, ptr_local)
  emit_i32_load(buf, 8)
  emit_local_set(buf, raw_cap_local)
  // Encode: cap >= 0 → 0 - cap - 1 (symmetric with emit_bytes_raw_load_header decode).
  emit_local_get(buf, raw_cap_local)
  emit_i32_const_raw(buf, 0)
  emit_i32_ge_s(buf)
  buf.push((4).to_byte()) // if
  buf.push((64).to_byte()) // void
  emit_local_get(buf, ptr_local)
  emit_i32_const_raw(buf, 0)
  emit_local_get(buf, raw_cap_local)
  emit_i32_sub(buf)
  emit_i32_const_raw(buf, 1)
  emit_i32_sub(buf)
  emit_i32_store(buf, 8)
  buf.push((11).to_byte()) // end if
}

///|
fn emit_bytes_load_header(
  ctx : CodegenCtx,
  buf : ByteBuf,
  ptr_local : Int,
  len_local : Int,
  cap_local : Int,
  data_local : Int,
) -> Unit {
  let obj_ty_local = alloc_temp_local(ctx)
  emit_local_get(buf, ptr_local)
  emit_i32_load(buf, 0)
  emit_local_set(buf, obj_ty_local)
  emit_local_get(buf, obj_ty_local)
  emit_i32_const_raw(buf, obj_bytes_view)
  emit_i32_eq(buf)
  buf.push((4).to_byte()) // if
  buf.push((64).to_byte()) // void
  let source_local = alloc_temp_local(ctx)
  let start_local = alloc_temp_local(ctx)
  emit_local_get(buf, ptr_local)
  emit_i32_load(buf, 4)
  emit_local_set(buf, source_local)
  emit_local_get(buf, ptr_local)
  emit_i32_load(buf, 8)
  emit_local_set(buf, start_local)
  emit_local_get(buf, ptr_local)
  emit_i32_load(buf, 12)
  emit_local_get(buf, start_local)
  emit_i32_sub(buf)
  emit_local_set(buf, len_local)
  emit_local_get(buf, len_local)
  emit_local_set(buf, cap_local)
  emit_local_get(buf, source_local)
  emit_i32_load(buf, 12)
  emit_local_get(buf, start_local)
  emit_i32_add(buf)
  emit_local_set(buf, data_local)
  buf.push((5).to_byte()) // else
  emit_bytes_raw_load_header(buf, ptr_local, len_local, cap_local, data_local)
  buf.push((11).to_byte()) // end if
}

///|
/// Allocate a new buffer, copy len bytes from data_local, rewrite ptr_local
/// header as a mutable raw bytes object.  data_local is updated to the new
/// allocation on return.
fn emit_bytes_cow_copy(
  ctx : CodegenCtx,
  buf : ByteBuf,
  ptr_local : Int,
  len_local : Int,
  cap_local : Int,
  data_local : Int,
) -> Unit {
  let alloc_size_local = alloc_temp_local(ctx)
  let new_data_local = alloc_temp_local(ctx)
  emit_local_get(buf, cap_local)
  emit_i32_const_raw(buf, 3)
  emit_i32_add(buf)
  emit_i32_const_raw(buf, -4)
  emit_i32_and(buf)
  emit_local_set(buf, alloc_size_local)
  emit_heap_alloc_local(ctx, buf, alloc_size_local, new_data_local)
  emit_local_get(buf, new_data_local)
  emit_local_get(buf, data_local)
  emit_local_get(buf, len_local)
  emit_memory_copy(buf)
  // Rewrite header as mutable raw bytes
  emit_local_get(buf, ptr_local)
  emit_i32_const_raw(buf, obj_bytes)
  emit_i32_store(buf, 0)
  emit_local_get(buf, ptr_local)
  emit_local_get(buf, len_local)
  emit_i32_store(buf, 4)
  emit_local_get(buf, ptr_local)
  emit_local_get(buf, cap_local)
  emit_i32_store(buf, 8)
  emit_local_get(buf, ptr_local)
  emit_local_get(buf, new_data_local)
  emit_i32_store(buf, 12)
  emit_local_get(buf, new_data_local)
  emit_local_set(buf, data_local)
}

///|
fn emit_untag_int_i32(buf : ByteBuf) -> Unit {
  emit_i64_const_raw(buf, 2L)
  emit_i64_shr_s(buf)
  emit_i32_wrap_i64(buf)
}

///|
fn emit_untag_ptr_i32(buf : ByteBuf) -> Unit {
  emit_i64_const_raw(buf, (-4).to_int64())
  emit_i64_and(buf)
  emit_i32_wrap_i64(buf)
}

///|
/// Resolve view/raw header into len/cap/data, then COW-copy if the object is
/// a view or a shared (frozen) raw bytes.
fn emit_bytes_ensure_mutable(
  ctx : CodegenCtx,
  buf : ByteBuf,
  ptr_local : Int,
  len_local : Int,
  cap_local : Int,
  data_local : Int,
) -> Unit {
  // Resolve view or raw → unified len/cap/data
  emit_bytes_load_header(ctx, buf, ptr_local, len_local, cap_local, data_local)
  // needs_cow = (obj_type == view) || (raw cap field < 0)
  // For view: field at +8 is "start" (not cap), but the OR covers it.
  // For raw: field at +8 is raw cap; negative means shared/frozen.
  let obj_ty_local = alloc_temp_local(ctx)
  let raw_cap_local = alloc_temp_local(ctx)
  emit_local_get(buf, ptr_local)
  emit_i32_load(buf, 0)
  emit_local_set(buf, obj_ty_local)
  emit_local_get(buf, ptr_local)
  emit_i32_load(buf, 8)
  emit_local_set(buf, raw_cap_local)
  emit_local_get(buf, obj_ty_local)
  emit_i32_const_raw(buf, obj_bytes_view)
  emit_i32_eq(buf)
  emit_local_get(buf, raw_cap_local)
  emit_i32_const_raw(buf, 0)
  emit_i32_lt_s(buf)
  emit_i32_or(buf)
  buf.push((4).to_byte()) // if
  buf.push((64).to_byte()) // void
  emit_bytes_cow_copy(ctx, buf, ptr_local, len_local, cap_local, data_local)
  buf.push((11).to_byte()) // end if
}

///|
fn emit_bytes_raw_alloc_with_cap_local(
  ctx : CodegenCtx,
  buf : ByteBuf,
  len_local : Int,
  cap_local : Int,
  obj_local : Int,
  data_local : Int,
) -> Unit {
  let data_size_local = alloc_temp_local(ctx)
  emit_local_get(buf, cap_local)
  emit_i32_const_raw(buf, 3)
  emit_i32_add(buf)
  emit_i32_const_raw(buf, -4)
  emit_i32_and(buf)
  emit_local_set(buf, data_size_local)
  emit_heap_alloc(ctx, buf, align4(16), obj_local)
  emit_heap_alloc_local(ctx, buf, data_size_local, data_local)
  emit_local_get(buf, obj_local)
  emit_i32_const_raw(buf, obj_bytes)
  emit_i32_store(buf, 0)
  emit_local_get(buf, obj_local)
  emit_local_get(buf, len_local)
  emit_i32_store(buf, 4)
  emit_local_get(buf, obj_local)
  emit_local_get(buf, cap_local)
  emit_i32_store(buf, 8)
  emit_local_get(buf, obj_local)
  emit_local_get(buf, data_local)
  emit_i32_store(buf, 12)
}

///|
fn emit_bytes_raw_ensure_capacity(
  ctx : CodegenCtx,
  buf : ByteBuf,
  ptr_local : Int,
  len_local : Int,
  add_local : Int,
  cap_local : Int,
  data_local : Int,
) -> Unit {
  let needed_local = alloc_temp_local(ctx)
  let doubled_cap_local = alloc_temp_local(ctx)
  let new_cap_local = alloc_temp_local(ctx)
  let data_size_local = alloc_temp_local(ctx)
  let new_data_local = alloc_temp_local(ctx)
  emit_local_get(buf, len_local)
  emit_local_get(buf, add_local)
  emit_i32_add(buf)
  emit_local_set(buf, needed_local)
  emit_local_get(buf, needed_local)
  emit_local_get(buf, cap_local)
  emit_i32_gt_u(buf)
  buf.push((4).to_byte()) // if
  buf.push((64).to_byte()) // void
  emit_local_get(buf, cap_local)
  emit_i32_const_raw(buf, 2)
  emit_i32_mul(buf)
  emit_local_set(buf, doubled_cap_local)
  emit_local_get(buf, doubled_cap_local)
  emit_local_get(buf, needed_local)
  emit_i32_gt_u(buf)
  buf.push((4).to_byte()) // if
  buf.push((127).to_byte()) // result i32
  emit_local_get(buf, doubled_cap_local)
  buf.push((5).to_byte()) // else
  emit_local_get(buf, needed_local)
  buf.push((11).to_byte()) // end if
  emit_local_set(buf, new_cap_local)
  emit_local_get(buf, new_cap_local)
  emit_i32_const_raw(buf, 3)
  emit_i32_add(buf)
  emit_i32_const_raw(buf, -4)
  emit_i32_and(buf)
  emit_local_set(buf, data_size_local)
  emit_heap_alloc_local(ctx, buf, data_size_local, new_data_local)
  emit_local_get(buf, new_data_local)
  emit_local_get(buf, data_local)
  emit_local_get(buf, len_local)
  emit_memory_copy(buf)
  emit_local_get(buf, ptr_local)
  emit_local_get(buf, new_cap_local)
  emit_i32_store(buf, 8)
  emit_local_get(buf, ptr_local)
  emit_local_get(buf, new_data_local)
  emit_i32_store(buf, 12)
  emit_local_get(buf, new_cap_local)
  emit_local_set(buf, cap_local)
  emit_local_get(buf, new_data_local)
  emit_local_set(buf, data_local)
  buf.push((11).to_byte()) // end if
}

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
fn emit_non_js_string_ptr_equals_i32(
  ctx : CodegenCtx,
  buf : ByteBuf,
  left_ptr_local : Int,
  right_ptr_local : Int,
) -> Unit {
  let left_base_local = alloc_temp_local(ctx)
  let right_base_local = alloc_temp_local(ctx)
  let left_len_local = alloc_temp_local(ctx)
  let right_len_local = alloc_temp_local(ctx)
  let loop_i_local = alloc_temp_local(ctx)
  let eq_local = alloc_temp_local(ctx)
  emit_local_get(buf, left_ptr_local)
  emit_i32_const_raw(buf, -4)
  emit_i32_and(buf)
  emit_local_set(buf, left_base_local)
  emit_local_get(buf, right_ptr_local)
  emit_i32_const_raw(buf, -4)
  emit_i32_and(buf)
  emit_local_set(buf, right_base_local)
  emit_local_get(buf, left_base_local)
  emit_local_get(buf, right_base_local)
  emit_i32_eq(buf)
  buf.push((4).to_byte()) // if
  buf.push((127).to_byte()) // result i32
  emit_i32_const_raw(buf, 1)
  buf.push((5).to_byte()) // else
  emit_local_get(buf, left_base_local)
  emit_i32_load(buf, 4)
  emit_local_set(buf, left_len_local)
  emit_local_get(buf, right_base_local)
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
  emit_local_get(buf, left_base_local)
  emit_local_get(buf, loop_i_local)
  emit_i32_add(buf)
  emit_i32_load8_u(buf, 8)
  emit_local_get(buf, right_base_local)
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
}

///|
fn emit_number_obj_to_string(
  ctx : CodegenCtx,
  buf : ByteBuf,
  obj_ptr_local : Int,
  obj_ty_local : Int,
  fallback_str : Int64,
) -> Unit {
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
      emit_untag_ptr_i32(buf)
      emit_call(buf, import_index_sh(ctx))
      emit_drop(buf)
      emit_i64_const_tagged(buf, 0L)
    }
    "path" => {
      let pos_args = extract_positional_exprs_with_arity(args, "path", 1)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_call(buf, import_index_path(ctx))
    }
    "Env::get" if not(is_user_fn) => {
      let pos_args = extract_positional_exprs_with_arity(args, "Env::get", 1)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_call(buf, import_index_env_get(ctx))
    }
    "Env::args_len" if not(is_user_fn) => {
      let _ = extract_positional_exprs_with_arity(args, "Env::args_len", 0)
      emit_call(buf, import_index_env_args_len(ctx))
    }
    "Env::args_get" if not(is_user_fn) => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "Env::args_get", 1,
      )
      compile_expr(ctx, buf, pos_args[0])
      emit_call(buf, import_index_env_args_get(ctx))
    }
    "add" if not(is_user_fn) || args.length() == 2 => {
      let pos_args = extract_positional_exprs_with_arity(args, "add", 2)
      let resolved_kind = resolve_numeric_kind(ctx, pos_args[0], pos_args[1])
      match resolved_kind {
        ValueKind::I32 | ValueKind::I64 =>
          if is_user_fn {
            raise WasmGenError::Unsupported(pre_user_builtin_unhandled_marker)
          } else {
            compile_i32_add_tagged(ctx, buf, pos_args[0], pos_args[1])
          }
        _ =>
          compile_binary_arith_op(
            ctx, buf, "add", args, emit_f32_add, emit_f64_add,
          )
      }
    }
    "sub" if not(is_user_fn) || args.length() == 2 => {
      let pos_args = extract_positional_exprs_with_arity(args, "sub", 2)
      let resolved_kind = resolve_numeric_kind(ctx, pos_args[0], pos_args[1])
      match resolved_kind {
        ValueKind::I32 | ValueKind::I64 =>
          if is_user_fn {
            raise WasmGenError::Unsupported(pre_user_builtin_unhandled_marker)
          } else {
            compile_i32_sub_tagged(ctx, buf, pos_args[0], pos_args[1])
          }
        _ =>
          compile_binary_arith_op(
            ctx, buf, "sub", args, emit_f32_sub, emit_f64_sub,
          )
      }
    }
    "mul" if not(is_user_fn) || args.length() == 2 => {
      let pos_args = extract_positional_exprs_with_arity(args, "mul", 2)
      let resolved_kind = resolve_numeric_kind(ctx, pos_args[0], pos_args[1])
      match resolved_kind {
        ValueKind::I32 | ValueKind::I64 =>
          if is_user_fn {
            raise WasmGenError::Unsupported(pre_user_builtin_unhandled_marker)
          } else {
            compile_i32_mul_tagged(ctx, buf, pos_args[0], pos_args[1])
          }
        _ =>
          compile_binary_arith_op(
            ctx, buf, "mul", args, emit_f32_mul, emit_f64_mul,
          )
      }
    }
    "div" if not(is_user_fn) || args.length() == 2 => {
      let pos_args = extract_positional_exprs_with_arity(args, "div", 2)
      let resolved_kind = resolve_numeric_kind(ctx, pos_args[0], pos_args[1])
      match resolved_kind {
        ValueKind::I32 | ValueKind::I64 =>
          if is_user_fn {
            raise WasmGenError::Unsupported(pre_user_builtin_unhandled_marker)
          } else {
            compile_i32_div_tagged(ctx, buf, pos_args[0], pos_args[1])
          }
        _ =>
          compile_binary_arith_op(
            ctx, buf, "div", args, emit_f32_div, emit_f64_div,
          )
      }
    }
    "eq" if not(is_user_fn) =>
      compile_binary_cmp_op(
        ctx, buf, "eq", args, emit_i64_eq, emit_f32_eq, emit_f64_eq,
      )
    "lt" if not(is_user_fn) => {
      let pos_args = extract_positional_exprs_with_arity(args, "lt", 2)
      let resolved_kind = resolve_numeric_kind(ctx, pos_args[0], pos_args[1])
      match resolved_kind {
        ValueKind::I32 | ValueKind::I64 =>
          compile_i32_cmp_tagged(
            ctx,
            buf,
            pos_args[0],
            pos_args[1],
            emit_i64_lt_s,
          )
        _ =>
          compile_binary_cmp_op(
            ctx, buf, "lt", args, emit_i64_lt_s, emit_f32_lt, emit_f64_lt,
          )
      }
    }
    "assert" | "assert_true" | "__assert" if not(is_user_fn) => {
      let builtin_name = name
      let pos_args = extract_positional_exprs_with_arity(args, builtin_name, 1)
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
    "assert_eq" | "__assert_eq" if not(is_user_fn) => {
      // assert_eq(a, b): compile __eq(a, b), then assert the result
      compile_binary_cmp_op(
        ctx, buf, "__eq", args, emit_i64_eq, emit_f32_eq, emit_f64_eq,
      )
      // compile_binary_cmp_op leaves tagged i64 bool on stack
      emit_i64_const_raw(buf, tag_bool_value64(true))
      emit_i64_eq(buf)
      emit_i32_eqz(buf)
      buf.push((4).to_byte()) // if (not equal)
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
      // tag_int = 0, i64.or is a no-op
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
      // tag_int = 0, i64.or is a no-op
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
      // tag_int = 0, i64.or is a no-op
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
    "__lt" => {
      let pos_args = extract_positional_exprs_with_arity(args, "__lt", 2)
      let resolved_kind = resolve_numeric_kind(ctx, pos_args[0], pos_args[1])
      match resolved_kind {
        ValueKind::I32 | ValueKind::I64 =>
          compile_i32_cmp_tagged(
            ctx,
            buf,
            pos_args[0],
            pos_args[1],
            emit_i64_lt_s,
          )
        _ =>
          compile_binary_cmp_op(
            ctx, buf, "__lt", args, emit_i64_lt_s, emit_f32_lt, emit_f64_lt,
          )
      }
    }
    "i32_eqz" if not(is_user_fn) => {
      let pos_args = extract_positional_exprs_with_arity(args, "i32_eqz", 1)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_int_i32(buf)
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
    "f32_neg"
    | "f32_abs"
    | "f32_ceil"
    | "f32_floor"
    | "f32_trunc"
    | "f32_nearest"
    | "f32_sqrt" => {
      let pos_args = extract_positional_exprs_with_arity(args, name, 1)
      let emit_op : (ByteBuf) -> Unit = match name {
        "f32_neg" => emit_f32_neg
        "f32_abs" => emit_f32_abs
        "f32_ceil" => emit_f32_ceil
        "f32_floor" => emit_f32_floor
        "f32_trunc" => emit_f32_trunc
        "f32_nearest" => emit_f32_nearest
        _ => emit_f32_sqrt
      }
      emit_boxed_f32_raise(ctx, buf, fn() raise WasmGenError {
        emit_unbox_f32_expr(ctx, buf, pos_args[0])
        emit_op(buf)
      })
    }
    "f64_neg"
    | "f64_abs"
    | "f64_ceil"
    | "f64_floor"
    | "f64_trunc"
    | "f64_nearest"
    | "f64_sqrt" => {
      let pos_args = extract_positional_exprs_with_arity(args, name, 1)
      let emit_op : (ByteBuf) -> Unit = match name {
        "f64_neg" => emit_f64_neg
        "f64_abs" => emit_f64_abs
        "f64_ceil" => emit_f64_ceil
        "f64_floor" => emit_f64_floor
        "f64_trunc" => emit_f64_trunc
        "f64_nearest" => emit_f64_nearest
        _ => emit_f64_sqrt
      }
      emit_boxed_f64_raise(ctx, buf, fn() raise WasmGenError {
        emit_unbox_f64_expr(ctx, buf, pos_args[0])
        emit_op(buf)
      })
    }
    "Int::to_float" | "f32_convert_i32_s" => {
      let pos_args = extract_positional_exprs_with_arity(args, name, 1)
      emit_boxed_f32_raise(ctx, buf, fn() raise WasmGenError {
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_untag_int_i32(buf)
        emit_f32_convert_i32_s(buf)
      })
    }
    "Int::to_double" | "f64_convert_i32_s" | "to_double" => {
      let pos_args = extract_positional_exprs_with_arity(args, name, 1)
      emit_boxed_f64_raise(ctx, buf, fn() raise WasmGenError {
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_i64_const_raw(buf, 2L)
        emit_i64_shr_s(buf)
        emit_f64_convert_i64_s(buf)
      })
    }
    "Float::to_int" | "i32_trunc_f32_s" => {
      let pos_args = extract_positional_exprs_with_arity(args, name, 1)
      emit_unbox_f32_expr(ctx, buf, pos_args[0])
      emit_i32_trunc_f32_s(buf)
      emit_i64_extend_i32_s(buf)
      emit_i64_const_raw(buf, 2L)
      emit_i64_shl(buf)
      // tag_int = 0, i64.or is a no-op
    }
    "Double::to_int" | "i32_trunc_f64_s" => {
      let pos_args = extract_positional_exprs_with_arity(args, name, 1)
      emit_unbox_f64_expr(ctx, buf, pos_args[0])
      emit_i64_trunc_f64_s(buf)
      emit_i64_const_raw(buf, 2L)
      emit_i64_shl(buf)
      // tag_int = 0, i64.or is a no-op
    }
    "Float::to_double" | "f64_promote_f32" => {
      let pos_args = extract_positional_exprs_with_arity(args, name, 1)
      emit_boxed_f64_raise(ctx, buf, fn() raise WasmGenError {
        emit_unbox_f32_expr(ctx, buf, pos_args[0])
        emit_f64_promote_f32(buf)
      })
    }
    "Double::to_float" | "f32_demote_f64" => {
      let pos_args = extract_positional_exprs_with_arity(args, name, 1)
      emit_boxed_f32_raise(ctx, buf, fn() raise WasmGenError {
        emit_unbox_f64_expr(ctx, buf, pos_args[0])
        emit_f32_demote_f64(buf)
      })
    }
    // ========== Integer math builtins ==========
    "Int::abs" if not(is_user_fn) => {
      // int_abs(x): if x < 0 then -x else x (operates on tagged i64 directly)
      let pos_args = extract_positional_exprs_with_arity(args, "Int::abs", 1)
      let tmp = alloc_temp_local_with_kind(ctx, ValueKind::I64)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_local_tee(buf, tmp) // stack: x, tmp = x
      emit_i64_const_raw(buf, 0L)
      emit_i64_lt_s(buf) // cond = x < 0 (i32)
      emit_if(buf) // if x < 0
      emit_i64_const_raw(buf, 0L)
      emit_local_get(buf, tmp)
      emit_i64_sub(buf) // -x (negate tagged value, tag 0 preserved)
      emit_local_set(buf, tmp)
      emit_end(buf) // end if
      emit_local_get(buf, tmp)
    }
    "Int::max" if not(is_user_fn) => {
      // int_max(a, b): works directly on tagged i64 values
      let pos_args = extract_positional_exprs_with_arity(args, "Int::max", 2)
      let a_local = alloc_temp_local_with_kind(ctx, ValueKind::I64)
      let b_local = alloc_temp_local_with_kind(ctx, ValueKind::I64)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_local_set(buf, a_local)
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_local_set(buf, b_local)
      // Push a, b, then (a > b) as i32 condition for select
      emit_local_get(buf, a_local)
      emit_local_get(buf, b_local)
      emit_local_get(buf, a_local)
      emit_local_get(buf, b_local)
      emit_i64_gt_s(buf) // a > b → 1:i32
      emit_select(buf) // select(a, b, a>b) → a if a>b else b
    }
    "Int::min" if not(is_user_fn) => {
      // int_min(a, b): works directly on tagged i64 values
      let pos_args = extract_positional_exprs_with_arity(args, "Int::min", 2)
      let a_local = alloc_temp_local_with_kind(ctx, ValueKind::I64)
      let b_local = alloc_temp_local_with_kind(ctx, ValueKind::I64)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_local_set(buf, a_local)
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_local_set(buf, b_local)
      emit_local_get(buf, a_local)
      emit_local_get(buf, b_local)
      emit_local_get(buf, a_local)
      emit_local_get(buf, b_local)
      emit_i64_lt_s(buf) // a < b → 1:i32
      emit_select(buf) // select(a, b, a<b) → a if a<b else b
    }
    "Int::clamp" if not(is_user_fn) => {
      // int_clamp(x, lo, hi): max(lo, min(x, hi))
      let pos_args = extract_positional_exprs_with_arity(args, "Int::clamp", 3)
      let x_local = alloc_temp_local_with_kind(ctx, ValueKind::I64)
      let lo_local = alloc_temp_local_with_kind(ctx, ValueKind::I64)
      let hi_local = alloc_temp_local_with_kind(ctx, ValueKind::I64)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_local_set(buf, x_local)
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_local_set(buf, lo_local)
      compile_expr_i32(ctx, buf, pos_args[2])
      emit_local_set(buf, hi_local)
      // min(x, hi): select(x, hi, x<hi)
      emit_local_get(buf, x_local)
      emit_local_get(buf, hi_local)
      emit_local_get(buf, x_local)
      emit_local_get(buf, hi_local)
      emit_i64_lt_s(buf)
      emit_select(buf) // min_val = min(x, hi)
      emit_local_set(buf, x_local)
      // max(lo, min_val): select(lo, min_val, lo>min_val)
      emit_local_get(buf, lo_local)
      emit_local_get(buf, x_local)
      emit_local_get(buf, lo_local)
      emit_local_get(buf, x_local)
      emit_i64_gt_s(buf)
      emit_select(buf) // max(lo, min(x, hi))
    }
    "Int::signum" if not(is_user_fn) => {
      // int_signum(x): -1 if x<0, 0 if x==0, 1 if x>0
      let pos_args = extract_positional_exprs_with_arity(args, "Int::signum", 1)
      let tmp = alloc_temp_local_with_kind(ctx, ValueKind::I64)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_local_set(buf, tmp)
      // Untag: x >> 2
      emit_local_get(buf, tmp)
      emit_i64_const_raw(buf, 2L)
      emit_i64_shr_s(buf)
      emit_local_set(buf, tmp) // tmp = untagged x
      // if x < 0: result = -1, elif x > 0: result = 1, else result = 0
      emit_local_get(buf, tmp)
      emit_i64_const_raw(buf, 0L)
      emit_i64_lt_s(buf)
      emit_if(buf) // if x < 0
      emit_i64_const_raw(buf, tag_int_value64(-1L))
      emit_local_set(buf, tmp)
      emit_else(buf) // else
      emit_local_get(buf, tmp)
      emit_i64_const_raw(buf, 0L)
      emit_i64_gt_s(buf)
      emit_if(buf) // if x > 0
      emit_i64_const_raw(buf, tag_int_value64(1L))
      emit_local_set(buf, tmp)
      emit_else(buf) // else (x == 0)
      emit_i64_const_raw(buf, tag_int_value64(0L))
      emit_local_set(buf, tmp)
      emit_end(buf) // end inner if
      emit_end(buf) // end outer if
      emit_local_get(buf, tmp)
    }
    "Int::is_even" if not(is_user_fn) => {
      // int_is_even(x): ((x >> 2) & 1) == 0 → tagged bool
      let pos_args = extract_positional_exprs_with_arity(
        args, "Int::is_even", 1,
      )
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_i64_const_raw(buf, 2L)
      emit_i64_shr_s(buf) // untag
      emit_i64_const_raw(buf, 1L)
      emit_i64_and(buf) // bit 0
      emit_i64_eqz(buf) // 1 if even, 0 if odd (i32 result)
      emit_i64_extend_i32_u(buf) // to i64
      emit_i64_const_raw(buf, 2L)
      emit_i64_shl(buf) // tag shift
      emit_i64_const_raw(buf, tag_bool.to_int64())
      emit_i64_or(buf) // tag as bool
    }
    "Int::is_odd" if not(is_user_fn) => {
      // int_is_odd(x): ((x >> 2) & 1) == 1 → tagged bool
      let pos_args = extract_positional_exprs_with_arity(args, "Int::is_odd", 1)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_i64_const_raw(buf, 2L)
      emit_i64_shr_s(buf) // untag
      emit_i64_const_raw(buf, 1L)
      emit_i64_and(buf) // bit 0: 1 if odd, 0 if even (i64)
      emit_i64_const_raw(buf, 2L)
      emit_i64_shl(buf) // tag shift
      emit_i64_const_raw(buf, tag_bool.to_int64())
      emit_i64_or(buf) // tag as bool
    }
    "i32_load" => {
      let pos_args = extract_positional_exprs_with_arity(args, "i32_load", 2)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_int_i32(buf)
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_untag_int_i32(buf)
      emit_i32_add(buf)
      emit_i32_load(buf, 0)
      emit_i64_extend_i32_s(buf)
      emit_i64_const_raw(buf, 2L)
      emit_i64_shl(buf)
      // tag_int = 0, i64.or is a no-op
    }
    "i32_load8_u" => {
      let pos_args = extract_positional_exprs_with_arity(args, "i32_load8_u", 2)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_int_i32(buf)
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_untag_int_i32(buf)
      emit_i32_add(buf)
      emit_i32_load8_u(buf, 0)
      emit_i64_extend_i32_s(buf)
      emit_i64_const_raw(buf, 2L)
      emit_i64_shl(buf)
      // tag_int = 0, i64.or is a no-op
    }
    "i32_store" => {
      let pos_args = extract_positional_exprs_with_arity(args, "i32_store", 3)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_int_i32(buf)
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_untag_int_i32(buf)
      emit_i32_add(buf)
      compile_expr_i32(ctx, buf, pos_args[2])
      emit_untag_int_i32(buf)
      emit_i32_store(buf, 0)
      emit_i64_const_tagged(buf, 0L)
    }
    "i32_store8" => {
      let pos_args = extract_positional_exprs_with_arity(args, "i32_store8", 3)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_int_i32(buf)
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_untag_int_i32(buf)
      emit_i32_add(buf)
      compile_expr_i32(ctx, buf, pos_args[2])
      emit_untag_int_i32(buf)
      emit_i32_store8(buf, 0)
      emit_i64_const_tagged(buf, 0L)
    }
    "f32_load" => {
      let pos_args = extract_positional_exprs_with_arity(args, "f32_load", 2)
      emit_boxed_f32_raise(ctx, buf, fn() raise WasmGenError {
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_untag_int_i32(buf)
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_untag_int_i32(buf)
        emit_i32_add(buf)
        emit_f32_load(buf, 0)
      })
    }
    "f64_load" => {
      let pos_args = extract_positional_exprs_with_arity(args, "f64_load", 2)
      emit_boxed_f64_raise(ctx, buf, fn() raise WasmGenError {
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_untag_int_i32(buf)
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_untag_int_i32(buf)
        emit_i32_add(buf)
        emit_f64_load(buf, 0)
      })
    }
    "f32_store" => {
      let pos_args = extract_positional_exprs_with_arity(args, "f32_store", 3)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_int_i32(buf)
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_untag_int_i32(buf)
      emit_i32_add(buf)
      emit_unbox_f32_expr(ctx, buf, pos_args[2])
      emit_f32_store(buf, 0)
      emit_i64_const_tagged(buf, 0L)
    }
    "f64_store" => {
      let pos_args = extract_positional_exprs_with_arity(args, "f64_store", 3)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_int_i32(buf)
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_untag_int_i32(buf)
      emit_i32_add(buf)
      emit_unbox_f64_expr(ctx, buf, pos_args[2])
      emit_f64_store(buf, 0)
      emit_i64_const_tagged(buf, 0L)
    }
    // --- SIMD V128 builtins ---
    "v128_load" => {
      // v128_load(bytes, offset) -> V128
      // Load raw Bytes data pointer, add offset, v128.load, box result
      let pos_args = extract_positional_exprs_with_arity(args, "v128_load", 2)
      let addr_local = alloc_temp_local(ctx)
      let v128_local = alloc_temp_local_with_kind(ctx, ValueKind::V128)
      // Compute base+offset as i32 address
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      // Load raw data pointer from Bytes object at offset 12
      emit_i32_load(buf, 12)
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_untag_int_i32(buf)
      emit_i32_add(buf)
      emit_v128_load(buf, 0)
      emit_local_set(buf, v128_local)
      // Box: allocate 20 bytes on heap (obj_type + v128)
      require_heap(ctx)
      emit_heap_alloc(ctx, buf, 20, addr_local)
      emit_local_get(buf, addr_local)
      emit_i32_const_raw(buf, obj_v128)
      emit_i32_store(buf, 0)
      emit_local_get(buf, addr_local)
      emit_local_get(buf, v128_local)
      emit_v128_store(buf, 4)
      // Return tagged pointer
      emit_local_get(buf, addr_local)
      emit_i64_extend_i32_u(buf)
      emit_i64_const_raw(buf, tag_obj.to_int64())
      emit_i64_or(buf)
    }
    "v128_store" => {
      // v128_store(bytes, offset, v128) -> Unit
      let pos_args = extract_positional_exprs_with_arity(args, "v128_store", 3)
      let v128_local = alloc_temp_local_with_kind(ctx, ValueKind::V128)
      // Unbox v128 arg
      compile_expr_i32(ctx, buf, pos_args[2])
      emit_untag_ptr_i32(buf)
      emit_v128_load(buf, 4)
      emit_local_set(buf, v128_local)
      // Compute Bytes data ptr + offset
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_i32_load(buf, 12)
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_untag_int_i32(buf)
      emit_i32_add(buf)
      // Store v128
      emit_local_get(buf, v128_local)
      emit_v128_store(buf, 0)
      emit_i64_const_tagged(buf, 0L)
    }
    "v128_splat_i8x16" => {
      // v128_splat_i8x16(int) -> V128
      let pos_args = extract_positional_exprs_with_arity(
        args, "v128_splat_i8x16", 1,
      )
      let addr_local = alloc_temp_local(ctx)
      let v128_local = alloc_temp_local_with_kind(ctx, ValueKind::V128)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_int_i32(buf)
      emit_i8x16_splat(buf)
      emit_local_set(buf, v128_local)
      require_heap(ctx)
      emit_heap_alloc(ctx, buf, 20, addr_local)
      emit_local_get(buf, addr_local)
      emit_i32_const_raw(buf, obj_v128)
      emit_i32_store(buf, 0)
      emit_local_get(buf, addr_local)
      emit_local_get(buf, v128_local)
      emit_v128_store(buf, 4)
      emit_local_get(buf, addr_local)
      emit_i64_extend_i32_u(buf)
      emit_i64_const_raw(buf, tag_obj.to_int64())
      emit_i64_or(buf)
    }
    "v128_eq_i8x16" => {
      // v128_eq_i8x16(V128, V128) -> V128
      let pos_args = extract_positional_exprs_with_arity(
        args, "v128_eq_i8x16", 2,
      )
      emit_v128_binary_op(ctx, buf, pos_args[0], pos_args[1], emit_i8x16_eq)
    }
    "v128_le_u_i8x16" => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "v128_le_u_i8x16", 2,
      )
      emit_v128_binary_op(ctx, buf, pos_args[0], pos_args[1], emit_i8x16_le_u)
    }
    "v128_ge_u_i8x16" => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "v128_ge_u_i8x16", 2,
      )
      emit_v128_binary_op(ctx, buf, pos_args[0], pos_args[1], emit_i8x16_ge_u)
    }
    "v128_and" => {
      let pos_args = extract_positional_exprs_with_arity(args, "v128_and", 2)
      emit_v128_binary_op(ctx, buf, pos_args[0], pos_args[1], emit_v128_and)
    }
    "v128_or" => {
      let pos_args = extract_positional_exprs_with_arity(args, "v128_or", 2)
      emit_v128_binary_op(ctx, buf, pos_args[0], pos_args[1], emit_v128_or)
    }
    "v128_not" => {
      // v128_not(V128) -> V128
      let pos_args = extract_positional_exprs_with_arity(args, "v128_not", 1)
      emit_v128_unary_op(ctx, buf, pos_args[0], emit_v128_not)
    }
    "v128_bitmask_i8x16" => {
      // v128_bitmask_i8x16(V128) -> Int
      let pos_args = extract_positional_exprs_with_arity(
        args, "v128_bitmask_i8x16", 1,
      )
      // Unbox v128
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_v128_load(buf, 4)
      // bitmask -> i32 result
      emit_i8x16_bitmask(buf)
      // Tag as Int
      emit_i64_extend_i32_s(buf)
      emit_i64_const_raw(buf, 2L)
      emit_i64_shl(buf)
    }
    "v128_any_true" => {
      // v128_any_true(V128) -> Bool
      let pos_args = extract_positional_exprs_with_arity(
        args, "v128_any_true", 1,
      )
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_v128_load(buf, 4)
      emit_v128_any_true(buf)
      emit_tag_bool_from_i32(buf)
    }
    "v128_all_true_i8x16" => {
      // v128_all_true_i8x16(V128) -> Bool
      let pos_args = extract_positional_exprs_with_arity(
        args, "v128_all_true_i8x16", 1,
      )
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_v128_load(buf, 4)
      emit_i8x16_all_true(buf)
      emit_tag_bool_from_i32(buf)
    }
    "int_ctz" => {
      // int_ctz(Int) -> Int
      let pos_args = extract_positional_exprs_with_arity(args, "int_ctz", 1)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_int_i32(buf)
      emit_i32_ctz(buf)
      emit_i64_extend_i32_s(buf)
      emit_i64_const_raw(buf, 2L)
      emit_i64_shl(buf)
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
        emit_untag_ptr_i32(buf)
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
        emit_untag_int_i32(buf)
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
    "Threads::probe_wat" => {
      let _ = extract_positional_exprs_with_arity(args, "Threads::probe_wat", 0)
      emit_string_const(ctx, buf, "(module)")
    }
    "Threads::runtime_hints" => {
      let _ = extract_positional_exprs_with_arity(
        args, "Threads::runtime_hints", 0,
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
    "Threads::channel_new" => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "Threads::channel_new", 1,
      )
      let cap_local = alloc_temp_local(ctx)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_int_i32(buf)
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
      // tag_int = 0, i64.or is a no-op
    }
    "Threads::spawn" => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "Threads::spawn", 2,
      )
      compile_expr(ctx, buf, pos_args[0])
      emit_drop(buf)
      compile_expr_i32(ctx, buf, pos_args[1])
    }
    "Threads::send" => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "Threads::send", 2,
      )
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_drop(buf)
      compile_expr(ctx, buf, pos_args[1])
      emit_drop(buf)
      emit_i64_const_raw(buf, tag_bool_value64(true))
    }
    "Threads::recv" => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "Threads::recv", 1,
      )
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_drop(buf)
      emit_string_const(ctx, buf, "")
    }
    "Threads::wait" => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "Threads::wait", 1,
      )
      compile_expr_i32(ctx, buf, pos_args[0])
    }
    "String::length" => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "String::length", 1,
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
        emit_untag_ptr_i32(buf)
        emit_i32_load(buf, 4)
        emit_i64_extend_i32_s(buf)
        emit_i64_const_raw(buf, 2L)
        emit_i64_shl(buf)
        // tag_int = 0, i64.or is a no-op
      }
    }
    "String::char_code_at" => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "String::char_code_at", 2,
      )
      if ctx.use_js_strings {
        ctx.need_js_char_code_at = true
        compile_expr_ref(ctx, buf, pos_args[0])
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_untag_int_i32(buf)
        emit_call(buf, import_index_js_char_code_at(ctx))
        emit_i64_extend_i32_s(buf)
        emit_i64_const_raw(buf, 2L)
        emit_i64_shl(buf)
      } else {
        let str_ptr_local = alloc_temp_local(ctx)
        let str_len_local = alloc_temp_local(ctx)
        let idx_local = alloc_temp_local(ctx)
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_untag_ptr_i32(buf)
        emit_local_set(buf, str_ptr_local)
        emit_local_get(buf, str_ptr_local)
        emit_i32_load(buf, 4)
        emit_local_set(buf, str_len_local)
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_untag_int_i32(buf)
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
        // tag_int = 0, i64.or is a no-op
        buf.push((11).to_byte()) // end if
      }
    }
    "Int::parse" => {
      // Int::parse(s: String) -> Option[Int]
      // Returns Some(int) on success, None on failure.
      let pos_args = extract_positional_exprs_with_arity(args, "Int::parse", 1)
      if ctx.use_js_strings {
        raise WasmGenError::Unsupported("Int::parse with js strings")
      } else {
        require_heap(ctx)
        // Native string mode: byte-iterate and accumulate
        let str_ptr_local = alloc_temp_local(ctx) // base pointer
        let str_len_local = alloc_temp_local(ctx) // string length
        let idx_local = alloc_temp_local(ctx) // current index
        let result_local = alloc_temp_local(ctx) // accumulator
        let neg_local = alloc_temp_local(ctx) // sign flag (0=pos, 1=neg)
        let byte_local = alloc_temp_local(ctx) // current byte
        let valid_local = alloc_temp_local(ctx) // validity flag (1=valid, 0=invalid)
        let has_digit_local = alloc_temp_local(ctx) // has at least one digit
        let obj_local = alloc_temp_local(ctx) // heap object for Option

        // Untag pointer, get base address
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_untag_ptr_i32(buf)
        emit_local_set(buf, str_ptr_local)

        // Load string length
        emit_local_get(buf, str_ptr_local)
        emit_i32_load(buf, 4)
        emit_local_set(buf, str_len_local)

        // Initialize: result=0, idx=0, neg=0, valid=1, has_digit=0
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, result_local)
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, idx_local)
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, neg_local)
        emit_i32_const_raw(buf, 1)
        emit_local_set(buf, valid_local)
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, has_digit_local)

        // Skip leading spaces (byte == 32)
        emit_block(buf) // block $skip_done
        emit_loop(buf) // loop $skip_loop
        emit_local_get(buf, idx_local)
        emit_local_get(buf, str_len_local)
        emit_i32_ge_s(buf)
        emit_br_if(buf, 1) // br $skip_done
        emit_local_get(buf, str_ptr_local)
        emit_local_get(buf, idx_local)
        emit_i32_add(buf)
        emit_i32_load8_u(buf, 8)
        emit_i32_const_raw(buf, 32) // space
        emit_i32_ne(buf)
        emit_br_if(buf, 1) // not space => break
        emit_local_get(buf, idx_local)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, idx_local)
        emit_br(buf, 0) // continue loop
        emit_end(buf) // end loop
        emit_end(buf) // end block

        // Check sign: '-' (45) or '+' (43)
        emit_block(buf) // block $sign_done
        emit_local_get(buf, idx_local)
        emit_local_get(buf, str_len_local)
        emit_i32_ge_s(buf)
        emit_br_if(buf, 0) // no chars left => skip sign check
        emit_local_get(buf, str_ptr_local)
        emit_local_get(buf, idx_local)
        emit_i32_add(buf)
        emit_i32_load8_u(buf, 8)
        emit_local_set(buf, byte_local)
        emit_local_get(buf, byte_local)
        emit_i32_const_raw(buf, 45) // '-'
        emit_i32_eq(buf)
        emit_if(buf)
        emit_i32_const_raw(buf, 1)
        emit_local_set(buf, neg_local)
        emit_local_get(buf, idx_local)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, idx_local)
        emit_br(buf, 1) // br $sign_done
        emit_end(buf) // end if
        emit_local_get(buf, byte_local)
        emit_i32_const_raw(buf, 43) // '+'
        emit_i32_eq(buf)
        emit_if(buf)
        emit_local_get(buf, idx_local)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, idx_local)
        emit_end(buf) // end if
        emit_end(buf) // end block $sign_done

        // Main digit loop: result = result * 10 + (byte - 48)
        // On non-digit (except trailing space), set valid=0 and break
        emit_block(buf) // block $digit_done
        emit_loop(buf) // loop $digit_loop
        emit_local_get(buf, idx_local)
        emit_local_get(buf, str_len_local)
        emit_i32_ge_s(buf)
        emit_br_if(buf, 1) // br $digit_done
        emit_local_get(buf, str_ptr_local)
        emit_local_get(buf, idx_local)
        emit_i32_add(buf)
        emit_i32_load8_u(buf, 8)
        emit_local_set(buf, byte_local)
        // Skip trailing spaces: if byte == 32, break
        emit_local_get(buf, byte_local)
        emit_i32_const_raw(buf, 32)
        emit_i32_eq(buf)
        emit_br_if(buf, 1) // br $digit_done
        // Check if digit: byte < '0' (48) or byte > '9' (57) => invalid
        emit_local_get(buf, byte_local)
        emit_i32_const_raw(buf, 48) // '0'
        emit_i32_lt_s(buf)
        emit_if(buf)
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, valid_local)
        emit_br(buf, 2) // br $digit_done (block depth: if=0, loop=1, block=2 => need 2)
        emit_end(buf) // end if
        emit_local_get(buf, byte_local)
        emit_i32_const_raw(buf, 57) // '9'
        emit_i32_gt_s(buf)
        emit_if(buf)
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, valid_local)
        emit_br(buf, 2) // br $digit_done
        emit_end(buf) // end if
        // Valid digit: result = result * 10 + (byte - 48)
        emit_i32_const_raw(buf, 1)
        emit_local_set(buf, has_digit_local)
        emit_local_get(buf, result_local)
        emit_i32_const_raw(buf, 10)
        emit_i32_mul(buf)
        emit_local_get(buf, byte_local)
        emit_i32_const_raw(buf, 48)
        emit_i32_sub(buf)
        emit_i32_add(buf)
        emit_local_set(buf, result_local)
        // idx++
        emit_local_get(buf, idx_local)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, idx_local)
        emit_br(buf, 0) // continue loop
        emit_end(buf) // end loop
        emit_end(buf) // end block

        // Check valid && has_digit: if not, produce None
        // valid = valid & has_digit
        emit_local_get(buf, valid_local)
        emit_local_get(buf, has_digit_local)
        emit_i32_and(buf)
        buf.push((4).to_byte()) // if
        buf.push((126).to_byte()) // result i64

        // Apply negation if neg_local == 1
        emit_local_get(buf, neg_local)
        emit_if(buf)
        emit_i32_const_raw(buf, 0)
        emit_local_get(buf, result_local)
        emit_i32_sub(buf)
        emit_local_set(buf, result_local)
        emit_end(buf) // end if

        // Tag result as i64 Int: (result << 2) | tag_int
        // Then wrap in Some: heap alloc enum obj with tag=1, payload=tagged_int
        // Some tag index = 1 (None=0, Some=1)
        let some_size = align4(8 + 8) // obj_type(4) + enum_tag(4) + payload(8)
        emit_heap_alloc(ctx, buf, some_size, obj_local)
        // Store obj_type = obj_enum (10)
        emit_local_get(buf, obj_local)
        emit_i32_const_raw(buf, obj_enum)
        emit_i32_store(buf, 0)
        // Store enum tag = 1 (Some)
        emit_local_get(buf, obj_local)
        emit_i32_const_raw(buf, 1)
        emit_i32_store(buf, 4)
        // Store payload: tagged int value at offset 8
        emit_local_get(buf, obj_local)
        emit_local_get(buf, result_local)
        emit_i64_extend_i32_s(buf)
        emit_i64_const_raw(buf, 2L)
        emit_i64_shl(buf)
        // tag_int = 0, i64.or is a no-op
        emit_i64_store(buf, 8)
        // Return tagged pointer: (obj_local as i64) | tag_obj
        emit_local_get(buf, obj_local)
        emit_i64_extend_i32_u(buf)
        emit_i64_const_raw(buf, tag_obj.to_int64())
        emit_i64_or(buf)

        emit_else(buf) // else: produce None

        // None: heap alloc enum obj with tag=0, no payload
        let none_size = align4(8) // obj_type(4) + enum_tag(4)
        emit_heap_alloc(ctx, buf, none_size, obj_local)
        emit_local_get(buf, obj_local)
        emit_i32_const_raw(buf, obj_enum)
        emit_i32_store(buf, 0)
        emit_local_get(buf, obj_local)
        emit_i32_const_raw(buf, 0) // None tag = 0
        emit_i32_store(buf, 4)
        emit_local_get(buf, obj_local)
        emit_i64_extend_i32_u(buf)
        emit_i64_const_raw(buf, tag_obj.to_int64())
        emit_i64_or(buf)

        emit_end(buf) // end if valid
      }
    }
    "Double::parse" => {
      // Double::parse(s: String) -> Option[Double]
      // Returns Some(double) on success, None on failure.
      let pos_args = extract_positional_exprs_with_arity(
        args, "Double::parse", 1,
      )
      if ctx.use_js_strings {
        raise WasmGenError::Unsupported("Double::parse with js strings")
      } else {
        require_heap(ctx)
        // Native string mode: byte-iterate and accumulate
        let str_ptr_local = alloc_temp_local(ctx)
        let str_len_local = alloc_temp_local(ctx)
        let idx_local = alloc_temp_local(ctx)
        let int_part_local = alloc_temp_local(ctx) // integer part (i32)
        let frac_part_local = alloc_temp_local(ctx) // fractional part (i32)
        let frac_div_local = alloc_temp_local(ctx) // fractional divisor (i32)
        let neg_local = alloc_temp_local(ctx) // sign flag
        let byte_local = alloc_temp_local(ctx)
        let valid_local = alloc_temp_local(ctx) // validity flag
        let has_digit_local = alloc_temp_local(ctx) // has at least one digit
        let boxed_f64_local = alloc_temp_local_with_kind(ctx, ValueKind::I64) // boxed f64 tagged ptr (i64)
        let obj_local = alloc_temp_local(ctx) // Option enum heap object

        // Untag pointer
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_untag_ptr_i32(buf)
        emit_local_set(buf, str_ptr_local)

        // Load string length
        emit_local_get(buf, str_ptr_local)
        emit_i32_load(buf, 4)
        emit_local_set(buf, str_len_local)

        // Initialize
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, int_part_local)
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, frac_part_local)
        emit_i32_const_raw(buf, 1)
        emit_local_set(buf, frac_div_local)
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, idx_local)
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, neg_local)
        emit_i32_const_raw(buf, 1)
        emit_local_set(buf, valid_local)
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, has_digit_local)

        // Skip leading spaces
        emit_block(buf)
        emit_loop(buf)
        emit_local_get(buf, idx_local)
        emit_local_get(buf, str_len_local)
        emit_i32_ge_s(buf)
        emit_br_if(buf, 1)
        emit_local_get(buf, str_ptr_local)
        emit_local_get(buf, idx_local)
        emit_i32_add(buf)
        emit_i32_load8_u(buf, 8)
        emit_i32_const_raw(buf, 32)
        emit_i32_ne(buf)
        emit_br_if(buf, 1)
        emit_local_get(buf, idx_local)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, idx_local)
        emit_br(buf, 0)
        emit_end(buf)
        emit_end(buf)

        // Check sign
        emit_block(buf)
        emit_local_get(buf, idx_local)
        emit_local_get(buf, str_len_local)
        emit_i32_ge_s(buf)
        emit_br_if(buf, 0)
        emit_local_get(buf, str_ptr_local)
        emit_local_get(buf, idx_local)
        emit_i32_add(buf)
        emit_i32_load8_u(buf, 8)
        emit_local_set(buf, byte_local)
        emit_local_get(buf, byte_local)
        emit_i32_const_raw(buf, 45) // '-'
        emit_i32_eq(buf)
        emit_if(buf)
        emit_i32_const_raw(buf, 1)
        emit_local_set(buf, neg_local)
        emit_local_get(buf, idx_local)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, idx_local)
        emit_br(buf, 1)
        emit_end(buf)
        emit_local_get(buf, byte_local)
        emit_i32_const_raw(buf, 43) // '+'
        emit_i32_eq(buf)
        emit_if(buf)
        emit_local_get(buf, idx_local)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, idx_local)
        emit_end(buf)
        emit_end(buf)

        // Parse integer part (digits before '.')
        emit_block(buf)
        emit_loop(buf)
        emit_local_get(buf, idx_local)
        emit_local_get(buf, str_len_local)
        emit_i32_ge_s(buf)
        emit_br_if(buf, 1)
        emit_local_get(buf, str_ptr_local)
        emit_local_get(buf, idx_local)
        emit_i32_add(buf)
        emit_i32_load8_u(buf, 8)
        emit_local_set(buf, byte_local)
        // if byte == '.' (46), break to fraction part
        emit_local_get(buf, byte_local)
        emit_i32_const_raw(buf, 46)
        emit_i32_eq(buf)
        emit_br_if(buf, 1)
        // if byte == ' ' (32), break (trailing space)
        emit_local_get(buf, byte_local)
        emit_i32_const_raw(buf, 32)
        emit_i32_eq(buf)
        emit_br_if(buf, 1)
        // Check if digit: byte < '0' or byte > '9' => invalid
        emit_local_get(buf, byte_local)
        emit_i32_const_raw(buf, 48)
        emit_i32_lt_s(buf)
        emit_if(buf)
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, valid_local)
        emit_br(buf, 2) // br $digit_done
        emit_end(buf)
        emit_local_get(buf, byte_local)
        emit_i32_const_raw(buf, 57)
        emit_i32_gt_s(buf)
        emit_if(buf)
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, valid_local)
        emit_br(buf, 2) // br $digit_done
        emit_end(buf)
        // int_part = int_part * 10 + (byte - 48)
        emit_i32_const_raw(buf, 1)
        emit_local_set(buf, has_digit_local)
        emit_local_get(buf, int_part_local)
        emit_i32_const_raw(buf, 10)
        emit_i32_mul(buf)
        emit_local_get(buf, byte_local)
        emit_i32_const_raw(buf, 48)
        emit_i32_sub(buf)
        emit_i32_add(buf)
        emit_local_set(buf, int_part_local)
        // idx++
        emit_local_get(buf, idx_local)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, idx_local)
        emit_br(buf, 0)
        emit_end(buf)
        emit_end(buf)

        // Skip '.' if present, then parse fractional digits
        emit_block(buf)
        emit_local_get(buf, idx_local)
        emit_local_get(buf, str_len_local)
        emit_i32_ge_s(buf)
        emit_br_if(buf, 0) // no more chars
        emit_local_get(buf, str_ptr_local)
        emit_local_get(buf, idx_local)
        emit_i32_add(buf)
        emit_i32_load8_u(buf, 8)
        emit_i32_const_raw(buf, 46) // '.'
        emit_i32_ne(buf)
        emit_br_if(buf, 0) // not a dot, skip fraction
        // skip the '.'
        emit_local_get(buf, idx_local)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, idx_local)
        // Parse fractional digits
        emit_block(buf) // block $frac_done
        emit_loop(buf) // loop $frac_loop
        emit_local_get(buf, idx_local)
        emit_local_get(buf, str_len_local)
        emit_i32_ge_s(buf)
        emit_br_if(buf, 1)
        emit_local_get(buf, str_ptr_local)
        emit_local_get(buf, idx_local)
        emit_i32_add(buf)
        emit_i32_load8_u(buf, 8)
        emit_local_set(buf, byte_local)
        // if byte == ' ' (space), break
        emit_local_get(buf, byte_local)
        emit_i32_const_raw(buf, 32)
        emit_i32_eq(buf)
        emit_br_if(buf, 1)
        // Check if digit
        emit_local_get(buf, byte_local)
        emit_i32_const_raw(buf, 48)
        emit_i32_lt_s(buf)
        emit_if(buf)
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, valid_local)
        emit_br(buf, 2) // br $frac_done
        emit_end(buf)
        emit_local_get(buf, byte_local)
        emit_i32_const_raw(buf, 57)
        emit_i32_gt_s(buf)
        emit_if(buf)
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, valid_local)
        emit_br(buf, 2) // br $frac_done
        emit_end(buf)
        // frac_part = frac_part * 10 + (byte - 48)
        emit_i32_const_raw(buf, 1)
        emit_local_set(buf, has_digit_local)
        emit_local_get(buf, frac_part_local)
        emit_i32_const_raw(buf, 10)
        emit_i32_mul(buf)
        emit_local_get(buf, byte_local)
        emit_i32_const_raw(buf, 48)
        emit_i32_sub(buf)
        emit_i32_add(buf)
        emit_local_set(buf, frac_part_local)
        // frac_div = frac_div * 10
        emit_local_get(buf, frac_div_local)
        emit_i32_const_raw(buf, 10)
        emit_i32_mul(buf)
        emit_local_set(buf, frac_div_local)
        // idx++
        emit_local_get(buf, idx_local)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, idx_local)
        emit_br(buf, 0)
        emit_end(buf) // end loop
        emit_end(buf) // end block $frac_done
        emit_end(buf) // end block (dot check)

        // Check valid && has_digit
        emit_local_get(buf, valid_local)
        emit_local_get(buf, has_digit_local)
        emit_i32_and(buf)
        buf.push((4).to_byte()) // if
        buf.push((126).to_byte()) // result i64

        // Build f64 result: (int_part + frac_part / frac_div) * sign
        // Box the f64, store tagged ptr in boxed_f64_local
        emit_boxed_f64_raise(ctx, buf, fn() {
          // f64(int_part)
          emit_local_get(buf, int_part_local)
          emit_i64_extend_i32_s(buf)
          emit_f64_convert_i64_s(buf)
          // f64(frac_part) / f64(frac_div)
          emit_local_get(buf, frac_part_local)
          emit_i64_extend_i32_s(buf)
          emit_f64_convert_i64_s(buf)
          emit_local_get(buf, frac_div_local)
          emit_i64_extend_i32_s(buf)
          emit_f64_convert_i64_s(buf)
          emit_f64_div(buf)
          // add int + frac
          emit_f64_add(buf)
          // apply sign
          emit_f64_const(buf, 1.0)
          emit_local_get(buf, neg_local)
          emit_i64_extend_i32_s(buf)
          emit_f64_convert_i64_s(buf)
          emit_f64_const(buf, 2.0)
          emit_f64_mul(buf)
          emit_f64_sub(buf)
          emit_f64_mul(buf)
        })
        emit_local_set(buf, boxed_f64_local)

        // Wrap in Some: enum obj with tag=1, payload=boxed_f64
        let some_size = align4(8 + 8) // obj_type(4) + enum_tag(4) + payload(8)
        emit_heap_alloc(ctx, buf, some_size, obj_local)
        emit_local_get(buf, obj_local)
        emit_i32_const_raw(buf, obj_enum)
        emit_i32_store(buf, 0)
        emit_local_get(buf, obj_local)
        emit_i32_const_raw(buf, 1) // Some tag = 1
        emit_i32_store(buf, 4)
        emit_local_get(buf, obj_local)
        emit_local_get(buf, boxed_f64_local)
        emit_i32_wrap_i64(buf)
        emit_i32_store(buf, 8)
        // Return tagged pointer
        emit_local_get(buf, obj_local)
        emit_i64_extend_i32_u(buf)
        emit_i64_const_raw(buf, tag_obj.to_int64())
        emit_i64_or(buf)

        emit_else(buf) // else: produce None

        let none_size = align4(8) // obj_type(4) + enum_tag(4)
        emit_heap_alloc(ctx, buf, none_size, obj_local)
        emit_local_get(buf, obj_local)
        emit_i32_const_raw(buf, obj_enum)
        emit_i32_store(buf, 0)
        emit_local_get(buf, obj_local)
        emit_i32_const_raw(buf, 0) // None tag = 0
        emit_i32_store(buf, 4)
        emit_local_get(buf, obj_local)
        emit_i64_extend_i32_u(buf)
        emit_i64_const_raw(buf, tag_obj.to_int64())
        emit_i64_or(buf)

        emit_end(buf) // end if valid
      }
    }
    "String::substring" => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "String::substring", 3,
      )
      if ctx.use_js_strings {
        ctx.need_js_substring = true
        compile_expr_ref(ctx, buf, pos_args[0])
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_untag_int_i32(buf)
        compile_expr_i32(ctx, buf, pos_args[2])
        emit_untag_int_i32(buf)
        emit_call(buf, import_index_js_substring(ctx))
      } else {
        require_heap(ctx)
        let str_ptr_local = alloc_temp_local(ctx)
        let str_len_local = alloc_temp_local(ctx)
        let start_local = alloc_temp_local(ctx)
        let end_local = alloc_temp_local(ctx)
        let sub_len_local = alloc_temp_local(ctx)
        let obj_local = alloc_temp_local(ctx)
        let alloc_size_local = alloc_temp_local(ctx)
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_untag_ptr_i32(buf)
        emit_local_set(buf, str_ptr_local)
        emit_local_get(buf, str_ptr_local)
        emit_i32_load(buf, 4)
        emit_local_set(buf, str_len_local)
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_untag_int_i32(buf)
        emit_local_set(buf, start_local)
        compile_expr_i32(ctx, buf, pos_args[2])
        emit_untag_int_i32(buf)
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
        // memory.copy: dst=obj+8, src=str_ptr+8+start, len=sub_len
        emit_local_get(buf, obj_local)
        emit_i32_const_raw(buf, 8)
        emit_i32_add(buf)
        emit_local_get(buf, str_ptr_local)
        emit_i32_const_raw(buf, 8)
        emit_i32_add(buf)
        emit_local_get(buf, start_local)
        emit_i32_add(buf)
        emit_local_get(buf, sub_len_local)
        emit_memory_copy(buf)
        emit_local_get(buf, obj_local)
        emit_i64_extend_i32_u(buf)
        emit_i64_const_raw(buf, tag_obj.to_int64())
        emit_i64_or(buf)
      }
    }
    "String::concat" => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "String::concat", 2,
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
        let alloc_size_local = alloc_temp_local(ctx)
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_untag_ptr_i32(buf)
        emit_local_set(buf, left_ptr_local)
        emit_local_get(buf, left_ptr_local)
        emit_i32_load(buf, 4)
        emit_local_set(buf, left_len_local)
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_untag_ptr_i32(buf)
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
        // memory.copy left string bytes: dst=obj+8, src=left_ptr+8, len=left_len
        emit_local_get(buf, obj_local)
        emit_i32_const_raw(buf, 8)
        emit_i32_add(buf)
        emit_local_get(buf, left_ptr_local)
        emit_i32_const_raw(buf, 8)
        emit_i32_add(buf)
        emit_local_get(buf, left_len_local)
        emit_memory_copy(buf)
        // memory.copy right string bytes: dst=obj+8+left_len, src=right_ptr+8, len=right_len
        emit_local_get(buf, obj_local)
        emit_i32_const_raw(buf, 8)
        emit_i32_add(buf)
        emit_local_get(buf, left_len_local)
        emit_i32_add(buf)
        emit_local_get(buf, right_ptr_local)
        emit_i32_const_raw(buf, 8)
        emit_i32_add(buf)
        emit_local_get(buf, right_len_local)
        emit_memory_copy(buf)
        emit_local_get(buf, obj_local)
        emit_i64_extend_i32_u(buf)
        emit_i64_const_raw(buf, tag_obj.to_int64())
        emit_i64_or(buf)
      }
    }
    "String::join" => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "String::join", 2,
      )
      if ctx.use_js_strings {
        raise WasmGenError::BackendLimit(
          backend="wasm-js-string",
          feature="String::join",
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
        let elem_slot_local = alloc_temp_local(ctx)
        let elem_ptr_local = alloc_temp_local(ctx)
        let elem_len_local = alloc_temp_local(ctx)
        // arr pointer / length
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_untag_ptr_i32(buf)
        emit_local_set(buf, arr_ptr_local)
        emit_local_get(buf, arr_ptr_local)
        emit_i32_load(buf, 4)
        emit_local_set(buf, arr_len_local)
        // sep pointer / length
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_untag_ptr_i32(buf)
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
        // memory.copy separator: dst=obj+8+out_pos, src=sep_ptr+8, len=sep_len
        emit_local_get(buf, obj_local)
        emit_i32_const_raw(buf, 8)
        emit_i32_add(buf)
        emit_local_get(buf, out_pos_local)
        emit_i32_add(buf)
        emit_local_get(buf, sep_ptr_local)
        emit_i32_const_raw(buf, 8)
        emit_i32_add(buf)
        emit_local_get(buf, sep_len_local)
        emit_memory_copy(buf)
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
        // memory.copy element: dst=obj+8+out_pos, src=elem_ptr+8, len=elem_len
        emit_local_get(buf, obj_local)
        emit_i32_const_raw(buf, 8)
        emit_i32_add(buf)
        emit_local_get(buf, out_pos_local)
        emit_i32_add(buf)
        emit_local_get(buf, elem_ptr_local)
        emit_i32_const_raw(buf, 8)
        emit_i32_add(buf)
        emit_local_get(buf, elem_len_local)
        emit_memory_copy(buf)
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
    "String::equals" => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "String::equals", 2,
      )
      if ctx.use_js_strings {
        ctx.need_js_equals = true
        compile_expr_ref(ctx, buf, pos_args[0])
        compile_expr_ref(ctx, buf, pos_args[1])
        emit_call(buf, import_index_js_equals(ctx))
        emit_tag_bool_from_i32(buf)
      } else {
        let left_ptr_local = alloc_temp_local(ctx)
        let right_ptr_local = alloc_temp_local(ctx)
        let left_len_local = alloc_temp_local(ctx)
        let right_len_local = alloc_temp_local(ctx)
        let loop_i_local = alloc_temp_local(ctx)
        let eq_local = alloc_temp_local(ctx)
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_untag_ptr_i32(buf)
        emit_local_set(buf, left_ptr_local)
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_untag_ptr_i32(buf)
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
        emit_tag_bool_from_i32(buf)
      }
    }
    "String::index_of" => {
      // string_index_of(str, sub) -> Int (byte offset or -1)
      let pos_args = extract_positional_exprs_with_arity(
        args, "String::index_of", 2,
      )
      if ctx.use_js_strings {
        raise WasmGenError::BackendLimit(
          backend="wasm-js-string",
          feature="String::index_of",
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
        emit_untag_ptr_i32(buf)
        emit_local_set(buf, str_ptr)
        emit_local_get(buf, str_ptr)
        emit_i32_load(buf, 4)
        emit_local_set(buf, str_len)
        // get sub pointer and length
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_untag_ptr_i32(buf)
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
        // tag_int = 0, i64.or is a no-op
      }
    }
    "String::contains" if not(is_user_fn) => {
      // string_contains(str, sub) -> Bool
      // Reuses the same substring search as string_index_of but returns bool.
      let pos_args = extract_positional_exprs_with_arity(
        args, "String::contains", 2,
      )
      if ctx.use_js_strings {
        raise WasmGenError::BackendLimit(
          backend="wasm-js-string",
          feature="String::contains",
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
        emit_untag_ptr_i32(buf)
        emit_local_set(buf, str_ptr)
        emit_local_get(buf, str_ptr)
        emit_i32_load(buf, 4)
        emit_local_set(buf, str_len)
        // get sub pointer and length
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_untag_ptr_i32(buf)
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
        emit_tag_bool_from_i32(buf)
      }
    }
    "String::starts_with" if not(is_user_fn) => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "String::starts_with", 2,
      )
      if ctx.use_js_strings {
        raise WasmGenError::BackendLimit(
          backend="wasm-js-string",
          feature="String::starts_with",
        )
      } else {
        let str_ptr_local = alloc_temp_local(ctx)
        let str_len_local = alloc_temp_local(ctx)
        let prefix_ptr_local = alloc_temp_local(ctx)
        let prefix_len_local = alloc_temp_local(ctx)
        let loop_i_local = alloc_temp_local(ctx)
        let result_local = alloc_temp_local(ctx)
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_untag_ptr_i32(buf)
        emit_local_set(buf, str_ptr_local)
        emit_local_get(buf, str_ptr_local)
        emit_i32_load(buf, 4)
        emit_local_set(buf, str_len_local)
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_untag_ptr_i32(buf)
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
        emit_tag_bool_from_i32(buf)
      }
    }
    "String::ends_with" if not(is_user_fn) => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "String::ends_with", 2,
      )
      if ctx.use_js_strings {
        raise WasmGenError::BackendLimit(
          backend="wasm-js-string",
          feature="String::ends_with",
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
        emit_untag_ptr_i32(buf)
        emit_local_set(buf, str_ptr_local)
        emit_local_get(buf, str_ptr_local)
        emit_i32_load(buf, 4)
        emit_local_set(buf, str_len_local)
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_untag_ptr_i32(buf)
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
        emit_tag_bool_from_i32(buf)
      }
    }
    "String::last_index_of" if not(is_user_fn) => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "String::last_index_of", 2,
      )
      if ctx.use_js_strings {
        raise WasmGenError::BackendLimit(
          backend="wasm-js-string",
          feature="String::last_index_of",
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
        emit_untag_ptr_i32(buf)
        emit_local_set(buf, str_ptr_local)
        emit_local_get(buf, str_ptr_local)
        emit_i32_load(buf, 4)
        emit_local_set(buf, str_len_local)
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_untag_ptr_i32(buf)
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
        // tag_int = 0, i64.or is a no-op
      }
    }
    "String::count" if not(is_user_fn) => {
      // string_count(str, sub) -> Int (non-overlapping count)
      let pos_args = extract_positional_exprs_with_arity(
        args, "String::count", 2,
      )
      if ctx.use_js_strings {
        raise WasmGenError::BackendLimit(
          backend="wasm-js-string",
          feature="String::count",
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
        emit_untag_ptr_i32(buf)
        emit_local_set(buf, str_ptr)
        emit_local_get(buf, str_ptr)
        emit_i32_load(buf, 4)
        emit_local_set(buf, str_len)
        // get sub pointer and length
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_untag_ptr_i32(buf)
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
        // tag_int = 0, i64.or is a no-op
      }
    }
    "String::trim" if not(is_user_fn) => {
      // string_trim(str) -> String (trim ASCII whitespace from both ends)
      let pos_args = extract_positional_exprs_with_arity(
        args, "String::trim", 1,
      )
      if ctx.use_js_strings {
        raise WasmGenError::BackendLimit(
          backend="wasm-js-string",
          feature="String::trim",
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
        emit_untag_ptr_i32(buf)
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
    "String::trim_start" if not(is_user_fn) => {
      // string_trim_start(str) -> String (trim leading whitespace)
      let pos_args = extract_positional_exprs_with_arity(
        args, "String::trim_start", 1,
      )
      if ctx.use_js_strings {
        raise WasmGenError::BackendLimit(
          backend="wasm-js-string",
          feature="String::trim_start",
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
        emit_untag_ptr_i32(buf)
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
    "String::trim_end" if not(is_user_fn) => {
      // string_trim_end(str) -> String (trim trailing whitespace)
      let pos_args = extract_positional_exprs_with_arity(
        args, "String::trim_end", 1,
      )
      if ctx.use_js_strings {
        raise WasmGenError::BackendLimit(
          backend="wasm-js-string",
          feature="String::trim_end",
        )
      } else {
        require_heap(ctx)
        let str_ptr = alloc_temp_local(ctx)
        let str_len = alloc_temp_local(ctx)
        let end_local = alloc_temp_local(ctx)
        let new_ptr = alloc_temp_local(ctx)
        let copy_i = alloc_temp_local(ctx)
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_untag_ptr_i32(buf)
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
    "String::to_upper" if not(is_user_fn) => {
      // string_to_upper(str) -> String (convert ASCII lowercase to uppercase)
      let pos_args = extract_positional_exprs_with_arity(
        args, "String::to_upper", 1,
      )
      if ctx.use_js_strings {
        raise WasmGenError::BackendLimit(
          backend="wasm-js-string",
          feature="String::to_upper",
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
        emit_untag_ptr_i32(buf)
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
    "String::to_lower" if not(is_user_fn) => {
      // string_to_lower(str) -> String (convert ASCII uppercase to lowercase)
      let pos_args = extract_positional_exprs_with_arity(
        args, "String::to_lower", 1,
      )
      if ctx.use_js_strings {
        raise WasmGenError::BackendLimit(
          backend="wasm-js-string",
          feature="String::to_lower",
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
        emit_untag_ptr_i32(buf)
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
    "String::replace" if not(is_user_fn) => {
      // string_replace(str, pattern, replacement) -> String (replace first occurrence)
      let pos_args = extract_positional_exprs_with_arity(
        args, "String::replace", 3,
      )
      if ctx.use_js_strings {
        raise WasmGenError::BackendLimit(
          backend="wasm-js-string",
          feature="String::replace",
        )
      } else {
        emit_string_replace_impl(ctx, buf, pos_args, replace_all=false)
      }
    }
    "String::replace_all" if not(is_user_fn) => {
      // string_replace_all(str, pattern, replacement) -> String (replace all occurrences)
      let pos_args = extract_positional_exprs_with_arity(
        args, "String::replace_all", 3,
      )
      if ctx.use_js_strings {
        raise WasmGenError::BackendLimit(
          backend="wasm-js-string",
          feature="String::replace_all",
        )
      } else {
        emit_string_replace_impl(ctx, buf, pos_args, replace_all=true)
      }
    }
    "String::split" if not(is_user_fn) => {
      // string_split(str, delimiter) -> Array[String]
      let pos_args = extract_positional_exprs_with_arity(
        args, "String::split", 2,
      )
      if ctx.use_js_strings {
        raise WasmGenError::BackendLimit(
          backend="wasm-js-string",
          feature="String::split",
        )
      } else {
        emit_string_split_impl(ctx, buf, pos_args)
      }
    }
    "StringBuilder::new" => {
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
    "StringBuilder::push" => {
      // string_builder_push(builder, value) -> same layout as array_builder_push
      let pos_args = extract_positional_exprs_with_arity(
        args, "StringBuilder::push", 2,
      )
      let builder_local = alloc_temp_local(ctx)
      let ptr_local = alloc_temp_local(ctx)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
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
    "StringBuilder::freeze" => {
      // string_builder_freeze(builder) -> concatenate all stored strings
      // Two-pass: 1) sum total byte length, 2) allocate and copy
      let pos_args = extract_positional_exprs_with_arity(
        args, "StringBuilder::freeze", 1,
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
      emit_untag_ptr_i32(buf)
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
    "ArrayBuilder::new" => {
      // array_builder() -> allocate empty array obj with len=0
      // Reserve max_capacity * 4 bytes after header for future pushes
      // NOTE: array_builder_push has no bounds check/realloc — this max_cap must
      // be large enough for all use cases. 16384 covers selfhost parser tokens.
      // TODO: implement proper capacity management with realloc.
      let max_cap = 16384
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
    "ArrayBuilder::push" => {
      // array_builder_push(builder, value) -> store value at [builder + 8 + len*4], increment len
      let pos_args = extract_positional_exprs_with_arity(
        args, "ArrayBuilder::push", 2,
      )
      let builder_local = alloc_temp_local(ctx)
      let ptr_local = alloc_temp_local(ctx)
      compile_expr_i32(ctx, buf, pos_args[0])
      // untag pointer
      emit_untag_ptr_i32(buf)
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
    "ArrayBuilder::freeze" => {
      // array_builder_freeze(builder) -> return builder as-is (it is already an array obj)
      let pos_args = extract_positional_exprs_with_arity(
        args, "ArrayBuilder::freeze", 1,
      )
      compile_expr_i32(ctx, buf, pos_args[0])
    }
    "Array::push" => {
      // array_push(arr, value) -> same as array_builder_push (arrays share layout)
      let pos_args = extract_positional_exprs_with_arity(args, "Array::push", 2)
      let builder_local = alloc_temp_local(ctx)
      let ptr_local = alloc_temp_local(ctx)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_local_tee(buf, builder_local)
      emit_local_set(buf, ptr_local)
      emit_local_get(buf, ptr_local)
      emit_local_get(buf, ptr_local)
      emit_i32_load(buf, 4) // len
      emit_i32_const_raw(buf, 4)
      emit_i32_mul(buf)
      emit_i32_add(buf)
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_i32_wrap_i64(buf)
      emit_i32_store(buf, 8)
      emit_local_get(buf, ptr_local)
      emit_local_get(buf, ptr_local)
      emit_i32_load(buf, 4)
      emit_i32_const_raw(buf, 1)
      emit_i32_add(buf)
      emit_i32_store(buf, 4)
      emit_i64_const_tagged(buf, 0L)
    }
    "array_new" => {
      // array_new(size, default_val) -> allocate array with given size, fill with default
      let pos_args = extract_positional_exprs_with_arity(args, "array_new", 2)
      require_heap(ctx)
      let size_local = alloc_temp_local(ctx)
      let val_local = alloc_temp_local(ctx)
      let obj_local = alloc_temp_local(ctx)
      let idx_local = alloc_temp_local(ctx)
      // Evaluate size (tagged int -> raw)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_int_i32(buf)
      emit_local_set(buf, size_local)
      // Evaluate default value
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_i32_wrap_i64(buf)
      emit_local_set(buf, val_local)
      // Alloc: header(8) + size*4
      emit_local_get(buf, size_local)
      emit_i32_const_raw(buf, 4)
      emit_i32_mul(buf)
      emit_i32_const_raw(buf, 8)
      emit_i32_add(buf)
      // align to 4
      emit_i32_const_raw(buf, 3)
      emit_i32_add(buf)
      emit_i32_const_raw(buf, -4)
      emit_i32_and(buf)
      let alloc_size_local = alloc_temp_local(ctx)
      emit_local_set(buf, alloc_size_local)
      // heap alloc
      emit_global_get(buf, ctx.heap_global)
      emit_local_tee(buf, obj_local)
      emit_local_get(buf, alloc_size_local)
      emit_i32_add(buf)
      emit_global_set(buf, ctx.heap_global)
      ctx.heap_synced = false
      // Set header: tag=obj_array, len=size
      emit_local_get(buf, obj_local)
      emit_i32_const_raw(buf, obj_array)
      emit_i32_store(buf, 0)
      emit_local_get(buf, obj_local)
      emit_local_get(buf, size_local)
      emit_i32_store(buf, 4)
      // Fill with default value
      emit_i32_const_raw(buf, 0)
      emit_local_set(buf, idx_local)
      // loop
      emit_block(buf)
      emit_loop(buf)
      emit_local_get(buf, idx_local)
      emit_local_get(buf, size_local)
      emit_i32_ge_s(buf)
      emit_br_if(buf, 1) // break if idx >= size
      emit_local_get(buf, obj_local)
      emit_local_get(buf, idx_local)
      emit_i32_const_raw(buf, 4)
      emit_i32_mul(buf)
      emit_i32_add(buf)
      emit_local_get(buf, val_local)
      emit_i32_store(buf, 8)
      emit_local_get(buf, idx_local)
      emit_i32_const_raw(buf, 1)
      emit_i32_add(buf)
      emit_local_set(buf, idx_local)
      emit_br(buf, 0) // continue
      emit_end(buf) // end loop
      emit_end(buf) // end block
      // Return tagged obj
      emit_local_get(buf, obj_local)
      emit_i64_extend_i32_u(buf)
      emit_i64_const_raw(buf, tag_obj.to_int64())
      emit_i64_or(buf)
    }
    "Array::truncate" => {
      // array_truncate(arr, new_len) -> set arr.len = new_len
      let pos_args = extract_positional_exprs_with_arity(
        args, "Array::truncate", 2,
      )
      let ptr_local = alloc_temp_local(ctx)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, ptr_local)
      emit_local_get(buf, ptr_local)
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_untag_int_i32(buf)
      emit_i32_store(buf, 4)
      emit_i64_const_tagged(buf, 0L)
    }
    "array_contains_str" => {
      // array_contains_str(arr, str) -> Bool
      // Linear scan: compare each element string with str using content comparison
      let pos_args = extract_positional_exprs_with_arity(
        args, "array_contains_str", 2,
      )
      require_heap(ctx)
      let arr_ptr = alloc_temp_local(ctx)
      let needle = alloc_temp_local_with_kind(ctx, ValueKind::I64)
      let len_local = alloc_temp_local(ctx)
      let idx_local = alloc_temp_local(ctx)
      let result_local = alloc_temp_local(ctx)
      let elem_local = alloc_temp_local_with_kind(ctx, ValueKind::I64)
      let needle_ptr = alloc_temp_local(ctx)
      let needle_len = alloc_temp_local(ctx)
      let elem_ptr = alloc_temp_local(ctx)
      let elem_len = alloc_temp_local(ctx)
      let cmp_i = alloc_temp_local(ctx)
      let str_eq = alloc_temp_local(ctx)
      // Get array pointer
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, arr_ptr)
      // Get needle string (tagged) and compute untagged pointer + length
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_local_set(buf, needle)
      emit_local_get(buf, needle)
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, needle_ptr)
      emit_local_get(buf, needle_ptr)
      emit_i32_load(buf, 4)
      emit_local_set(buf, needle_len)
      // array len
      emit_local_get(buf, arr_ptr)
      emit_i32_load(buf, 4)
      emit_local_set(buf, len_local)
      // result = false
      emit_i32_const_raw(buf, 0)
      emit_local_set(buf, result_local)
      emit_i32_const_raw(buf, 0)
      emit_local_set(buf, idx_local)
      // Loop over elements
      emit_block(buf)
      emit_loop(buf)
      emit_local_get(buf, idx_local)
      emit_local_get(buf, len_local)
      emit_i32_ge_s(buf)
      emit_br_if(buf, 1) // break if done
      // Load element (tagged i32 -> i64)
      emit_local_get(buf, arr_ptr)
      emit_local_get(buf, idx_local)
      emit_i32_const_raw(buf, 4)
      emit_i32_mul(buf)
      emit_i32_add(buf)
      emit_i32_load(buf, 8)
      emit_i64_extend_i32_u(buf)
      emit_local_set(buf, elem_local)
      // Get element untagged pointer
      emit_local_get(buf, elem_local)
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, elem_ptr)
      // Fast path: pointer equality
      emit_local_get(buf, elem_ptr)
      emit_local_get(buf, needle_ptr)
      emit_i32_eq(buf)
      emit_if(buf) // void if — pointers match
      emit_i32_const_raw(buf, 1)
      emit_local_set(buf, result_local)
      emit_local_get(buf, len_local)
      emit_local_set(buf, idx_local) // force break
      emit_else(buf)
      // Compare string lengths
      emit_local_get(buf, elem_ptr)
      emit_i32_load(buf, 4) // elem string length
      emit_local_set(buf, elem_len)
      emit_local_get(buf, elem_len)
      emit_local_get(buf, needle_len)
      emit_i32_eq(buf)
      emit_if(buf) // void if — lengths match, compare bytes
      emit_i32_const_raw(buf, 1)
      emit_local_set(buf, str_eq)
      emit_i32_const_raw(buf, 0)
      emit_local_set(buf, cmp_i)
      // Byte comparison loop
      emit_block(buf)
      emit_loop(buf)
      emit_local_get(buf, cmp_i)
      emit_local_get(buf, elem_len)
      emit_i32_ge_s(buf)
      emit_br_if(buf, 1) // break if all bytes compared
      emit_local_get(buf, elem_ptr)
      emit_local_get(buf, cmp_i)
      emit_i32_add(buf)
      emit_i32_load8_u(buf, 8) // elem byte at offset 8 + cmp_i
      emit_local_get(buf, needle_ptr)
      emit_local_get(buf, cmp_i)
      emit_i32_add(buf)
      emit_i32_load8_u(buf, 8) // needle byte at offset 8 + cmp_i
      emit_i32_eq(buf)
      emit_i32_eqz(buf)
      emit_if(buf) // void if — bytes differ
      emit_i32_const_raw(buf, 0)
      emit_local_set(buf, str_eq)
      emit_local_get(buf, elem_len) // force exit byte loop
      emit_local_set(buf, cmp_i)
      emit_else(buf)
      emit_local_get(buf, cmp_i)
      emit_i32_const_raw(buf, 1)
      emit_i32_add(buf)
      emit_local_set(buf, cmp_i)
      emit_end(buf) // end if (byte compare)
      emit_br(buf, 0) // continue byte loop
      emit_end(buf) // end loop (byte loop)
      emit_end(buf) // end block (byte loop)
      // If str_eq is still 1, we found a match
      emit_local_get(buf, str_eq)
      emit_if(buf) // void if — string content matches
      emit_i32_const_raw(buf, 1)
      emit_local_set(buf, result_local)
      emit_local_get(buf, len_local) // force break
      emit_local_set(buf, idx_local)
      emit_end(buf) // end if (str_eq)
      emit_end(buf) // end if (length match)
      // Increment index
      emit_local_get(buf, idx_local)
      emit_i32_const_raw(buf, 1)
      emit_i32_add(buf)
      emit_local_set(buf, idx_local)
      emit_end(buf) // end else (pointer mismatch)
      emit_br(buf, 0) // continue outer loop
      emit_end(buf) // end loop (outer)
      emit_end(buf) // end block (outer)
      // Return tagged bool (val << 2)
      emit_local_get(buf, result_local)
      emit_i64_extend_i32_u(buf)
      emit_i64_const_raw(buf, 2L)
      emit_i64_shl(buf)
    }
    "Double::to_i64_bits" => {
      // double_to_i64_bits(f64_tagged) -> i64 raw bits as tagged int
      let pos_args = extract_positional_exprs_with_arity(
        args, "Double::to_i64_bits", 1,
      )
      compile_expr_i32(ctx, buf, pos_args[0])
      // The value is an i64 that is actually f64 bits reinterpreted
      // In our runtime, floats are stored as i64 (f64 reinterpret)
      // We just need to return the raw bits as-is (already i64)
      // No tagging needed since this is used for raw bit manipulation
    }
    "Double::from_i64_bits" => {
      // i64_bits_to_double(int_tagged) -> boxed f64
      // Takes a tagged int, untags it to get raw i64 bits,
      // reinterprets those bits as f64, and boxes the result.
      let pos_args = extract_positional_exprs_with_arity(
        args, "Double::from_i64_bits", 1,
      )
      emit_boxed_f64_raise(ctx, buf, fn() raise WasmGenError {
        compile_expr_i32(ctx, buf, pos_args[0])
        // Untag: arithmetic right shift by 2 to get raw i64 bits
        emit_i64_const_raw(buf, 2L)
        emit_i64_shr_s(buf)
        // Reinterpret i64 bits as f64
        emit_f64_reinterpret_i64(buf)
      })
    }
    "string_to_data" => {
      // string_to_data(str) -> Array[Int] of byte values
      // For WASM codegen, strings are stored as (offset, len) pairs in memory
      // This creates an array of character codes
      let pos_args = extract_positional_exprs_with_arity(
        args, "string_to_data", 1,
      )
      require_heap(ctx)
      let str_ptr = alloc_temp_local(ctx)
      let str_len = alloc_temp_local(ctx)
      let obj_local = alloc_temp_local(ctx)
      let idx_local = alloc_temp_local(ctx)
      // Get string tagged value and extract pointer
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_local_tee(buf, str_ptr)
      emit_i32_load(buf, 4) // string length
      emit_local_set(buf, str_len)
      emit_local_get(buf, str_ptr)
      emit_i32_const_raw(buf, 8)
      emit_i32_add(buf) // str_ptr = ptr + 8 (inline data start)
      emit_local_set(buf, str_ptr) // reuse as data ptr
      // Allocate array: header(8) + len*4
      emit_global_get(buf, ctx.heap_global)
      emit_local_set(buf, obj_local)
      emit_local_get(buf, obj_local)
      emit_local_get(buf, str_len)
      emit_i32_const_raw(buf, 4)
      emit_i32_mul(buf)
      emit_i32_const_raw(buf, 11) // 8 + 3 for alignment
      emit_i32_add(buf)
      emit_i32_const_raw(buf, -4)
      emit_i32_and(buf)
      emit_i32_add(buf)
      emit_global_set(buf, ctx.heap_global)
      ctx.heap_synced = false
      // Set header
      emit_local_get(buf, obj_local)
      emit_i32_const_raw(buf, obj_array)
      emit_i32_store(buf, 0)
      emit_local_get(buf, obj_local)
      emit_local_get(buf, str_len)
      emit_i32_store(buf, 4)
      // Fill array with char codes (tagged ints)
      emit_i32_const_raw(buf, 0)
      emit_local_set(buf, idx_local)
      emit_block(buf)
      emit_loop(buf)
      emit_local_get(buf, idx_local)
      emit_local_get(buf, str_len)
      emit_i32_ge_s(buf)
      emit_br_if(buf, 1)
      // arr[idx] = tagged(memory[str_ptr + idx])
      emit_local_get(buf, obj_local)
      emit_local_get(buf, idx_local)
      emit_i32_const_raw(buf, 4)
      emit_i32_mul(buf)
      emit_i32_add(buf)
      // Load byte from string data
      emit_local_get(buf, str_ptr)
      emit_local_get(buf, idx_local)
      emit_i32_add(buf)
      emit_i32_load8_u(buf, 0)
      // Tag as int: val * 4 (equivalent to val << 2)
      emit_i32_const_raw(buf, 4)
      emit_i32_mul(buf)
      emit_i32_store(buf, 8)
      emit_local_get(buf, idx_local)
      emit_i32_const_raw(buf, 1)
      emit_i32_add(buf)
      emit_local_set(buf, idx_local)
      emit_br(buf, 0)
      emit_end(buf)
      emit_end(buf)
      // Return tagged array
      emit_local_get(buf, obj_local)
      emit_i64_extend_i32_u(buf)
      emit_i64_const_raw(buf, tag_obj.to_int64())
      emit_i64_or(buf)
    }
    "MapBuilder::new" => {
      // MapBuilder::new() -> allocate empty map obj with len=0
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
    "MapBuilder::set" => {
      // MapBuilder::set(builder, key, value) -> overwrite existing key or append new pair
      let pos_args = extract_positional_exprs_with_arity(
        args, "MapBuilder::set", 3,
      )
      let ptr_local = alloc_temp_local(ctx)
      let len_local = alloc_temp_local(ctx)
      let loop_i = alloc_temp_local(ctx)
      let found_local = alloc_temp_local(ctx)
      let offset_local = alloc_temp_local(ctx)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, ptr_local)
      emit_local_get(buf, ptr_local)
      emit_i32_load(buf, 4) // len
      emit_local_set(buf, len_local)
      emit_i32_const_raw(buf, 0)
      emit_local_set(buf, loop_i)
      emit_i32_const_raw(buf, -1)
      emit_local_set(buf, found_local)
      if ctx.use_js_strings {
        let key_kind = infer_expr_kind(ctx, pos_args[1])
        if key_kind == ValueKind::ExternRef {
          ctx.need_extern_table = true
          compile_expr(ctx, buf, pos_args[1])
          let key_local = alloc_temp_local_with_kind(ctx, ValueKind::ExternRef)
          emit_local_set(buf, key_local)
          ctx.need_js_equals = true
          buf.push((3).to_byte()) // loop
          buf.push((64).to_byte()) // void
          emit_local_get(buf, loop_i)
          emit_local_get(buf, len_local)
          emit_i32_lt_s(buf)
          buf.push((4).to_byte()) // if
          buf.push((64).to_byte()) // void
          emit_local_get(buf, ptr_local)
          emit_local_get(buf, loop_i)
          emit_i32_const_raw(buf, 3)
          emit_i32_shl(buf)
          emit_i32_add(buf)
          emit_i32_load(buf, 8) // slot index
          emit_table_get(buf, ctx.extern_table_index)
          emit_local_get(buf, key_local)
          emit_call(buf, import_index_js_equals(ctx))
          buf.push((4).to_byte()) // if (equals)
          buf.push((64).to_byte()) // void
          emit_local_get(buf, loop_i)
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
          emit_local_get(buf, found_local)
          emit_i32_const_raw(buf, 0)
          emit_i32_ge_s(buf)
          buf.push((4).to_byte()) // if
          buf.push((64).to_byte()) // void
          emit_local_get(buf, ptr_local)
          emit_local_get(buf, found_local)
          emit_i32_const_raw(buf, 3)
          emit_i32_shl(buf)
          emit_i32_add(buf)
          compile_expr_i32(ctx, buf, pos_args[2])
          emit_i32_wrap_i64(buf)
          emit_i32_store(buf, 12)
          buf.push((5).to_byte()) // else
          let slot = ctx.extern_table_next_slot
          ctx.extern_table_next_slot += 1
          emit_local_get(buf, len_local)
          emit_i32_const_raw(buf, 3)
          emit_i32_shl(buf)
          emit_local_set(buf, offset_local)
          emit_local_get(buf, ptr_local)
          emit_local_get(buf, offset_local)
          emit_i32_add(buf)
          emit_i32_const_raw(buf, slot)
          emit_local_get(buf, key_local)
          emit_table_set(buf, ctx.extern_table_index)
          emit_i32_const_raw(buf, slot)
          emit_i32_store(buf, 8)
          emit_local_get(buf, ptr_local)
          emit_local_get(buf, offset_local)
          emit_i32_add(buf)
          compile_expr_i32(ctx, buf, pos_args[2])
          emit_i32_wrap_i64(buf)
          emit_i32_store(buf, 12)
          emit_local_get(buf, ptr_local)
          emit_local_get(buf, len_local)
          emit_i32_const_raw(buf, 1)
          emit_i32_add(buf)
          emit_i32_store(buf, 4)
          buf.push((11).to_byte()) // end if
        } else {
          let key_local = alloc_temp_local(ctx)
          compile_expr_i32(ctx, buf, pos_args[1])
          emit_i32_wrap_i64(buf)
          emit_local_set(buf, key_local)
          buf.push((3).to_byte()) // loop
          buf.push((64).to_byte()) // void
          emit_local_get(buf, loop_i)
          emit_local_get(buf, len_local)
          emit_i32_lt_s(buf)
          buf.push((4).to_byte()) // if
          buf.push((64).to_byte()) // void
          emit_local_get(buf, ptr_local)
          emit_local_get(buf, loop_i)
          emit_i32_const_raw(buf, 3)
          emit_i32_shl(buf)
          emit_i32_add(buf)
          emit_i32_load(buf, 8) // key
          emit_local_get(buf, key_local)
          emit_i32_eq(buf)
          buf.push((4).to_byte()) // if
          buf.push((64).to_byte()) // void
          emit_local_get(buf, loop_i)
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
          emit_local_get(buf, found_local)
          emit_i32_const_raw(buf, 0)
          emit_i32_ge_s(buf)
          buf.push((4).to_byte()) // if
          buf.push((64).to_byte()) // void
          emit_local_get(buf, ptr_local)
          emit_local_get(buf, found_local)
          emit_i32_const_raw(buf, 3)
          emit_i32_shl(buf)
          emit_i32_add(buf)
          compile_expr_i32(ctx, buf, pos_args[2])
          emit_i32_wrap_i64(buf)
          emit_i32_store(buf, 12)
          buf.push((5).to_byte()) // else
          emit_local_get(buf, len_local)
          emit_i32_const_raw(buf, 3)
          emit_i32_shl(buf)
          emit_local_set(buf, offset_local)
          emit_local_get(buf, ptr_local)
          emit_local_get(buf, offset_local)
          emit_i32_add(buf)
          emit_local_get(buf, key_local)
          emit_i32_store(buf, 8)
          emit_local_get(buf, ptr_local)
          emit_local_get(buf, offset_local)
          emit_i32_add(buf)
          compile_expr_i32(ctx, buf, pos_args[2])
          emit_i32_wrap_i64(buf)
          emit_i32_store(buf, 12)
          emit_local_get(buf, ptr_local)
          emit_local_get(buf, len_local)
          emit_i32_const_raw(buf, 1)
          emit_i32_add(buf)
          emit_i32_store(buf, 4)
          buf.push((11).to_byte()) // end if
        }
      } else {
        let key_local = alloc_temp_local(ctx)
        let entry_key_local = alloc_temp_local(ctx)
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_i32_wrap_i64(buf)
        emit_local_set(buf, key_local)
        buf.push((3).to_byte()) // loop
        buf.push((64).to_byte()) // void
        emit_local_get(buf, loop_i)
        emit_local_get(buf, len_local)
        emit_i32_lt_s(buf)
        buf.push((4).to_byte()) // if
        buf.push((64).to_byte()) // void
        emit_local_get(buf, ptr_local)
        emit_local_get(buf, loop_i)
        emit_i32_const_raw(buf, 3)
        emit_i32_shl(buf)
        emit_i32_add(buf)
        emit_i32_load(buf, 8) // key
        emit_local_set(buf, entry_key_local)
        emit_non_js_string_ptr_equals_i32(ctx, buf, entry_key_local, key_local)
        buf.push((4).to_byte()) // if
        buf.push((64).to_byte()) // void
        emit_local_get(buf, loop_i)
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
        emit_local_get(buf, found_local)
        emit_i32_const_raw(buf, 0)
        emit_i32_ge_s(buf)
        buf.push((4).to_byte()) // if
        buf.push((64).to_byte()) // void
        emit_local_get(buf, ptr_local)
        emit_local_get(buf, found_local)
        emit_i32_const_raw(buf, 3)
        emit_i32_shl(buf)
        emit_i32_add(buf)
        compile_expr_i32(ctx, buf, pos_args[2])
        emit_i32_wrap_i64(buf)
        emit_i32_store(buf, 12)
        buf.push((5).to_byte()) // else
        emit_local_get(buf, len_local)
        emit_i32_const_raw(buf, 3)
        emit_i32_shl(buf)
        emit_local_set(buf, offset_local)
        emit_local_get(buf, ptr_local)
        emit_local_get(buf, offset_local)
        emit_i32_add(buf)
        emit_local_get(buf, key_local)
        emit_i32_store(buf, 8)
        emit_local_get(buf, ptr_local)
        emit_local_get(buf, offset_local)
        emit_i32_add(buf)
        compile_expr_i32(ctx, buf, pos_args[2])
        emit_i32_wrap_i64(buf)
        emit_i32_store(buf, 12)
        emit_local_get(buf, ptr_local)
        emit_local_get(buf, len_local)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_i32_store(buf, 4)
        buf.push((11).to_byte()) // end if
      }
      // return unit
      emit_i64_const_tagged(buf, 0L)
    }
    "MapBuilder::freeze" => {
      // MapBuilder::freeze(builder) -> return builder as-is (it is already a map obj)
      let pos_args = extract_positional_exprs_with_arity(
        args, "MapBuilder::freeze", 1,
      )
      compile_expr_i32(ctx, buf, pos_args[0])
    }
    "Set::new" => {
      // Set::new() -> allocate empty map obj with len=0 (same layout as Map)
      let _ = extract_positional_exprs_with_arity(args, "Set::new", 0)
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
    "Set::size" => {
      // Set::size(set) -> read length field from map obj, return as tagged int
      let pos_args = extract_positional_exprs_with_arity(args, "Set::size", 1)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_i32_load(buf, 4) // length
      emit_i64_extend_i32_u(buf)
      emit_i64_const_raw(buf, 2L)
      emit_i64_shl(buf)
      // tag_int = 0, so no OR needed
    }
    "Set::contains" => {
      // Set::contains(set, val) -> same as Map::has_key
      let pos_args = extract_positional_exprs_with_arity(
        args, "Set::contains", 2,
      )
      let map_ptr = alloc_temp_local(ctx)
      let map_len = alloc_temp_local(ctx)
      let loop_i = alloc_temp_local(ctx)
      let found_local = alloc_temp_local(ctx)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
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
          emit_i32_const_raw(buf, 3)
          emit_i32_shl(buf)
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
          emit_i32_const_raw(buf, 3)
          emit_i32_shl(buf)
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
        emit_i32_const_raw(buf, 3)
        emit_i32_shl(buf)
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
      emit_local_get(buf, found_local)
      emit_tag_bool_from_i32(buf)
    }
    "Set::add" => {
      // Set::add(set, val) -> new set with val added (immutable)
      // Allocate new map, copy all entries, add new entry if not exists
      let pos_args = extract_positional_exprs_with_arity(args, "Set::add", 2)
      require_heap(ctx)
      let max_cap = 128
      let src_ptr = alloc_temp_local(ctx)
      let src_len = alloc_temp_local(ctx)
      let dst_ptr = alloc_temp_local(ctx)
      let loop_i = alloc_temp_local(ctx)
      let found_local = alloc_temp_local(ctx)
      let new_len = alloc_temp_local(ctx)
      // load source set
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, src_ptr)
      emit_local_get(buf, src_ptr)
      emit_i32_load(buf, 4)
      emit_local_set(buf, src_len)
      // allocate new map obj
      let size = align4(8 + max_cap * 8)
      emit_heap_alloc(ctx, buf, size, dst_ptr)
      // set tag
      emit_local_get(buf, dst_ptr)
      emit_i32_const_raw(buf, obj_map)
      emit_i32_store(buf, 0)
      // copy entries using memory.copy: dst+8, src+8, src_len*8
      emit_local_get(buf, dst_ptr)
      emit_i32_const_raw(buf, 8)
      emit_i32_add(buf) // dst addr
      emit_local_get(buf, src_ptr)
      emit_i32_const_raw(buf, 8)
      emit_i32_add(buf) // src addr
      emit_local_get(buf, src_len)
      emit_i32_const_raw(buf, 3)
      emit_i32_shl(buf) // byte count = src_len * 8
      emit_memory_copy(buf)
      // check if val already exists in the set
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
          // search loop
          buf.push((3).to_byte()) // loop
          buf.push((64).to_byte()) // void
          emit_local_get(buf, loop_i)
          emit_local_get(buf, src_len)
          emit_i32_lt_s(buf)
          buf.push((4).to_byte()) // if
          buf.push((64).to_byte()) // void
          emit_local_get(buf, dst_ptr)
          emit_local_get(buf, loop_i)
          emit_i32_const_raw(buf, 3)
          emit_i32_shl(buf)
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
          // if not found, append new entry
          emit_local_get(buf, found_local)
          emit_i32_eqz(buf)
          buf.push((4).to_byte()) // if
          buf.push((64).to_byte()) // void
          // store key in extern table slot
          let slot = ctx.extern_table_next_slot
          ctx.extern_table_next_slot += 1
          emit_local_get(buf, dst_ptr)
          emit_local_get(buf, src_len)
          emit_i32_const_raw(buf, 3)
          emit_i32_shl(buf)
          emit_i32_add(buf)
          emit_i32_const_raw(buf, slot)
          emit_local_get(buf, key_local)
          emit_table_set(buf, ctx.extern_table_index)
          emit_i32_const_raw(buf, slot)
          emit_i32_store(buf, 8)
          // store value = tagged true (7 = (1 << 2) | 3)
          emit_local_get(buf, dst_ptr)
          emit_local_get(buf, src_len)
          emit_i32_const_raw(buf, 3)
          emit_i32_shl(buf)
          emit_i32_add(buf)
          emit_i32_const_raw(buf, 7)
          emit_i32_store(buf, 12)
          // new_len = src_len + 1
          emit_local_get(buf, src_len)
          emit_i32_const_raw(buf, 1)
          emit_i32_add(buf)
          emit_local_set(buf, new_len)
          buf.push((5).to_byte()) // else
          emit_local_get(buf, src_len)
          emit_local_set(buf, new_len)
          buf.push((11).to_byte()) // end if
        } else {
          let key_local = alloc_temp_local(ctx)
          compile_expr_i32(ctx, buf, pos_args[1])
          emit_i32_wrap_i64(buf)
          emit_local_set(buf, key_local)
          buf.push((3).to_byte()) // loop
          buf.push((64).to_byte()) // void
          emit_local_get(buf, loop_i)
          emit_local_get(buf, src_len)
          emit_i32_lt_s(buf)
          buf.push((4).to_byte()) // if
          buf.push((64).to_byte()) // void
          emit_local_get(buf, dst_ptr)
          emit_local_get(buf, loop_i)
          emit_i32_const_raw(buf, 3)
          emit_i32_shl(buf)
          emit_i32_add(buf)
          emit_i32_load(buf, 8)
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
          // if not found, append
          emit_local_get(buf, found_local)
          emit_i32_eqz(buf)
          buf.push((4).to_byte()) // if
          buf.push((64).to_byte()) // void
          emit_local_get(buf, dst_ptr)
          emit_local_get(buf, src_len)
          emit_i32_const_raw(buf, 3)
          emit_i32_shl(buf)
          emit_i32_add(buf)
          emit_local_get(buf, key_local)
          emit_i32_store(buf, 8)
          emit_local_get(buf, dst_ptr)
          emit_local_get(buf, src_len)
          emit_i32_const_raw(buf, 3)
          emit_i32_shl(buf)
          emit_i32_add(buf)
          emit_i32_const_raw(buf, 7) // tagged true
          emit_i32_store(buf, 12)
          emit_local_get(buf, src_len)
          emit_i32_const_raw(buf, 1)
          emit_i32_add(buf)
          emit_local_set(buf, new_len)
          buf.push((5).to_byte()) // else
          emit_local_get(buf, src_len)
          emit_local_set(buf, new_len)
          buf.push((11).to_byte()) // end if
        }
      } else {
        let key_local = alloc_temp_local(ctx)
        let entry_key_local = alloc_temp_local(ctx)
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_i32_wrap_i64(buf)
        emit_local_set(buf, key_local)
        buf.push((3).to_byte()) // loop
        buf.push((64).to_byte()) // void
        emit_local_get(buf, loop_i)
        emit_local_get(buf, src_len)
        emit_i32_lt_s(buf)
        buf.push((4).to_byte()) // if
        buf.push((64).to_byte()) // void
        emit_local_get(buf, dst_ptr)
        emit_local_get(buf, loop_i)
        emit_i32_const_raw(buf, 3)
        emit_i32_shl(buf)
        emit_i32_add(buf)
        emit_i32_load(buf, 8)
        emit_local_set(buf, entry_key_local)
        emit_non_js_string_ptr_equals_i32(ctx, buf, entry_key_local, key_local)
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
        emit_local_get(buf, found_local)
        emit_i32_eqz(buf)
        buf.push((4).to_byte()) // if
        buf.push((64).to_byte()) // void
        emit_local_get(buf, dst_ptr)
        emit_local_get(buf, src_len)
        emit_i32_const_raw(buf, 3)
        emit_i32_shl(buf)
        emit_i32_add(buf)
        emit_local_get(buf, key_local)
        emit_i32_store(buf, 8)
        emit_local_get(buf, dst_ptr)
        emit_local_get(buf, src_len)
        emit_i32_const_raw(buf, 3)
        emit_i32_shl(buf)
        emit_i32_add(buf)
        emit_i32_const_raw(buf, 7) // tagged true
        emit_i32_store(buf, 12)
        emit_local_get(buf, src_len)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, new_len)
        buf.push((5).to_byte()) // else
        emit_local_get(buf, src_len)
        emit_local_set(buf, new_len)
        buf.push((11).to_byte()) // end if
      }
      // set new length
      emit_local_get(buf, dst_ptr)
      emit_local_get(buf, new_len)
      emit_i32_store(buf, 4)
      // return tagged pointer
      emit_local_get(buf, dst_ptr)
      emit_i64_extend_i32_u(buf)
      emit_i64_const_raw(buf, tag_obj.to_int64())
      emit_i64_or(buf)
    }
    "Set::remove" => {
      // Set::remove(set, val) -> new set without val (immutable)
      // Allocate new map, copy entries that don't match val
      let pos_args = extract_positional_exprs_with_arity(args, "Set::remove", 2)
      require_heap(ctx)
      let max_cap = 128
      let src_ptr = alloc_temp_local(ctx)
      let src_len = alloc_temp_local(ctx)
      let dst_ptr = alloc_temp_local(ctx)
      let loop_i = alloc_temp_local(ctx)
      let dst_len = alloc_temp_local(ctx)
      // load source set
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, src_ptr)
      emit_local_get(buf, src_ptr)
      emit_i32_load(buf, 4)
      emit_local_set(buf, src_len)
      // allocate new map obj
      let size = align4(8 + max_cap * 8)
      emit_heap_alloc(ctx, buf, size, dst_ptr)
      emit_local_get(buf, dst_ptr)
      emit_i32_const_raw(buf, obj_map)
      emit_i32_store(buf, 0)
      emit_i32_const_raw(buf, 0)
      emit_local_set(buf, loop_i)
      emit_i32_const_raw(buf, 0)
      emit_local_set(buf, dst_len)
      if ctx.use_js_strings {
        let key_kind = infer_expr_kind(ctx, pos_args[1])
        if key_kind == ValueKind::ExternRef {
          ctx.need_extern_table = true
          ctx.need_js_equals = true
          let key_local = alloc_temp_local_with_kind(ctx, ValueKind::ExternRef)
          compile_expr(ctx, buf, pos_args[1])
          emit_local_set(buf, key_local)
          let entry_slot = alloc_temp_local(ctx)
          let entry_val = alloc_temp_local(ctx)
          buf.push((3).to_byte()) // loop
          buf.push((64).to_byte()) // void
          emit_local_get(buf, loop_i)
          emit_local_get(buf, src_len)
          emit_i32_lt_s(buf)
          buf.push((4).to_byte()) // if
          buf.push((64).to_byte()) // void
          // load entry key slot
          emit_local_get(buf, src_ptr)
          emit_local_get(buf, loop_i)
          emit_i32_const_raw(buf, 3)
          emit_i32_shl(buf)
          emit_i32_add(buf)
          emit_i32_load(buf, 8)
          emit_local_set(buf, entry_slot)
          // load entry value
          emit_local_get(buf, src_ptr)
          emit_local_get(buf, loop_i)
          emit_i32_const_raw(buf, 3)
          emit_i32_shl(buf)
          emit_i32_add(buf)
          emit_i32_load(buf, 12)
          emit_local_set(buf, entry_val)
          // compare
          emit_local_get(buf, entry_slot)
          emit_table_get(buf, ctx.extern_table_index)
          emit_local_get(buf, key_local)
          emit_call(buf, import_index_js_equals(ctx))
          emit_i32_eqz(buf)
          buf.push((4).to_byte()) // if (not equal = keep)
          buf.push((64).to_byte()) // void
          // copy entry to dst
          emit_local_get(buf, dst_ptr)
          emit_local_get(buf, dst_len)
          emit_i32_const_raw(buf, 3)
          emit_i32_shl(buf)
          emit_i32_add(buf)
          emit_local_get(buf, entry_slot)
          emit_i32_store(buf, 8)
          emit_local_get(buf, dst_ptr)
          emit_local_get(buf, dst_len)
          emit_i32_const_raw(buf, 3)
          emit_i32_shl(buf)
          emit_i32_add(buf)
          emit_local_get(buf, entry_val)
          emit_i32_store(buf, 12)
          emit_local_get(buf, dst_len)
          emit_i32_const_raw(buf, 1)
          emit_i32_add(buf)
          emit_local_set(buf, dst_len)
          buf.push((11).to_byte()) // end if (not equal)
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
          let entry_key = alloc_temp_local(ctx)
          let entry_val = alloc_temp_local(ctx)
          buf.push((3).to_byte()) // loop
          buf.push((64).to_byte()) // void
          emit_local_get(buf, loop_i)
          emit_local_get(buf, src_len)
          emit_i32_lt_s(buf)
          buf.push((4).to_byte()) // if
          buf.push((64).to_byte()) // void
          emit_local_get(buf, src_ptr)
          emit_local_get(buf, loop_i)
          emit_i32_const_raw(buf, 3)
          emit_i32_shl(buf)
          emit_i32_add(buf)
          emit_i32_load(buf, 8)
          emit_local_set(buf, entry_key)
          emit_local_get(buf, src_ptr)
          emit_local_get(buf, loop_i)
          emit_i32_const_raw(buf, 3)
          emit_i32_shl(buf)
          emit_i32_add(buf)
          emit_i32_load(buf, 12)
          emit_local_set(buf, entry_val)
          emit_local_get(buf, entry_key)
          emit_local_get(buf, key_local)
          emit_i32_eq(buf)
          emit_i32_eqz(buf) // not equal = keep
          buf.push((4).to_byte()) // if
          buf.push((64).to_byte()) // void
          emit_local_get(buf, dst_ptr)
          emit_local_get(buf, dst_len)
          emit_i32_const_raw(buf, 3)
          emit_i32_shl(buf)
          emit_i32_add(buf)
          emit_local_get(buf, entry_key)
          emit_i32_store(buf, 8)
          emit_local_get(buf, dst_ptr)
          emit_local_get(buf, dst_len)
          emit_i32_const_raw(buf, 3)
          emit_i32_shl(buf)
          emit_i32_add(buf)
          emit_local_get(buf, entry_val)
          emit_i32_store(buf, 12)
          emit_local_get(buf, dst_len)
          emit_i32_const_raw(buf, 1)
          emit_i32_add(buf)
          emit_local_set(buf, dst_len)
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
        let key_local = alloc_temp_local(ctx)
        let entry_key_local = alloc_temp_local(ctx)
        let entry_val = alloc_temp_local(ctx)
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_i32_wrap_i64(buf)
        emit_local_set(buf, key_local)
        buf.push((3).to_byte()) // loop
        buf.push((64).to_byte()) // void
        emit_local_get(buf, loop_i)
        emit_local_get(buf, src_len)
        emit_i32_lt_s(buf)
        buf.push((4).to_byte()) // if
        buf.push((64).to_byte()) // void
        emit_local_get(buf, src_ptr)
        emit_local_get(buf, loop_i)
        emit_i32_const_raw(buf, 3)
        emit_i32_shl(buf)
        emit_i32_add(buf)
        emit_i32_load(buf, 8)
        emit_local_set(buf, entry_key_local)
        emit_local_get(buf, src_ptr)
        emit_local_get(buf, loop_i)
        emit_i32_const_raw(buf, 3)
        emit_i32_shl(buf)
        emit_i32_add(buf)
        emit_i32_load(buf, 12)
        emit_local_set(buf, entry_val)
        emit_non_js_string_ptr_equals_i32(ctx, buf, entry_key_local, key_local)
        emit_i32_eqz(buf) // not equal = keep
        buf.push((4).to_byte()) // if
        buf.push((64).to_byte()) // void
        emit_local_get(buf, dst_ptr)
        emit_local_get(buf, dst_len)
        emit_i32_const_raw(buf, 3)
        emit_i32_shl(buf)
        emit_i32_add(buf)
        emit_local_get(buf, entry_key_local)
        emit_i32_store(buf, 8)
        emit_local_get(buf, dst_ptr)
        emit_local_get(buf, dst_len)
        emit_i32_const_raw(buf, 3)
        emit_i32_shl(buf)
        emit_i32_add(buf)
        emit_local_get(buf, entry_val)
        emit_i32_store(buf, 12)
        emit_local_get(buf, dst_len)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, dst_len)
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
      // set dst length
      emit_local_get(buf, dst_ptr)
      emit_local_get(buf, dst_len)
      emit_i32_store(buf, 4)
      // return tagged pointer
      emit_local_get(buf, dst_ptr)
      emit_i64_extend_i32_u(buf)
      emit_i64_const_raw(buf, tag_obj.to_int64())
      emit_i64_or(buf)
    }
    "Set::to_array" => {
      // Set::to_array(set) -> allocate array with keys from map (same as Map::keys)
      let pos_args = extract_positional_exprs_with_arity(
        args, "Set::to_array", 1,
      )
      require_heap(ctx)
      let map_ptr = alloc_temp_local(ctx)
      let map_len = alloc_temp_local(ctx)
      let arr_ptr = alloc_temp_local(ctx)
      let loop_i = alloc_temp_local(ctx)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, map_ptr)
      emit_local_get(buf, map_ptr)
      emit_i32_load(buf, 4)
      emit_local_set(buf, map_len)
      let max_cap = 128
      let arr_size = align4(8 + max_cap * 4)
      emit_heap_alloc(ctx, buf, arr_size, arr_ptr)
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
      emit_local_get(buf, arr_ptr)
      emit_local_get(buf, loop_i)
      emit_i32_const_raw(buf, 4)
      emit_i32_mul(buf)
      emit_i32_add(buf)
      // load key from map
      emit_local_get(buf, map_ptr)
      emit_local_get(buf, loop_i)
      emit_i32_const_raw(buf, 3)
      emit_i32_shl(buf)
      emit_i32_add(buf)
      emit_i32_load(buf, 8)
      if not(ctx.use_js_strings) {
        emit_i64_extend_i32_u(buf)
        emit_i64_const_raw(buf, tag_obj.to_int64())
        emit_i64_or(buf)
        emit_i32_wrap_i64(buf)
      }
      emit_i32_store(buf, 8)
      emit_local_get(buf, loop_i)
      emit_i32_const_raw(buf, 1)
      emit_i32_add(buf)
      emit_local_set(buf, loop_i)
      buf.push((12).to_byte()) // br
      write_u32_leb(buf, 1) // to loop
      buf.push((11).to_byte()) // end if
      buf.push((11).to_byte()) // end loop
      emit_local_get(buf, arr_ptr)
      emit_i64_extend_i32_u(buf)
      emit_i64_const_raw(buf, tag_obj.to_int64())
      emit_i64_or(buf)
    }
    "Set::from_array" => {
      // Set::from_array(arr) -> new set from array elements
      // Creates map where each array element is a key with value=true
      let pos_args = extract_positional_exprs_with_arity(
        args, "Set::from_array", 1,
      )
      require_heap(ctx)
      let max_cap = 128
      let arr_ptr = alloc_temp_local(ctx)
      let arr_len = alloc_temp_local(ctx)
      let dst_ptr = alloc_temp_local(ctx)
      let loop_i = alloc_temp_local(ctx)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, arr_ptr)
      emit_local_get(buf, arr_ptr)
      emit_i32_load(buf, 4)
      emit_local_set(buf, arr_len)
      let map_size = align4(8 + max_cap * 8)
      emit_heap_alloc(ctx, buf, map_size, dst_ptr)
      emit_local_get(buf, dst_ptr)
      emit_i32_const_raw(buf, obj_map)
      emit_i32_store(buf, 0)
      emit_local_get(buf, dst_ptr)
      emit_local_get(buf, arr_len)
      emit_i32_store(buf, 4)
      emit_i32_const_raw(buf, 0)
      emit_local_set(buf, loop_i)
      buf.push((3).to_byte()) // loop
      buf.push((64).to_byte()) // void
      emit_local_get(buf, loop_i)
      emit_local_get(buf, arr_len)
      emit_i32_lt_s(buf)
      buf.push((4).to_byte()) // if
      buf.push((64).to_byte()) // void
      // store key: dst[8 + i*8] = arr[8 + i*4]
      emit_local_get(buf, dst_ptr)
      emit_local_get(buf, loop_i)
      emit_i32_const_raw(buf, 3)
      emit_i32_shl(buf)
      emit_i32_add(buf)
      emit_local_get(buf, arr_ptr)
      emit_local_get(buf, loop_i)
      emit_i32_const_raw(buf, 4)
      emit_i32_mul(buf)
      emit_i32_add(buf)
      emit_i32_load(buf, 8)
      emit_i32_store(buf, 8)
      // store value: dst[12 + i*8] = tagged true (7)
      emit_local_get(buf, dst_ptr)
      emit_local_get(buf, loop_i)
      emit_i32_const_raw(buf, 3)
      emit_i32_shl(buf)
      emit_i32_add(buf)
      emit_i32_const_raw(buf, 7) // tagged true = (1 << 2) | 3
      emit_i32_store(buf, 12)
      emit_local_get(buf, loop_i)
      emit_i32_const_raw(buf, 1)
      emit_i32_add(buf)
      emit_local_set(buf, loop_i)
      buf.push((12).to_byte()) // br
      write_u32_leb(buf, 1) // to loop
      buf.push((11).to_byte()) // end if
      buf.push((11).to_byte()) // end loop
      emit_local_get(buf, dst_ptr)
      emit_i64_extend_i32_u(buf)
      emit_i64_const_raw(buf, tag_obj.to_int64())
      emit_i64_or(buf)
    }
    "Map::has_key" => {
      // map_has_key(map, key) -> linear search for key, return tagged bool
      let pos_args = extract_positional_exprs_with_arity(
        args, "Map::has_key", 2,
      )
      let map_ptr = alloc_temp_local(ctx)
      let map_len = alloc_temp_local(ctx)
      let loop_i = alloc_temp_local(ctx)
      let found_local = alloc_temp_local(ctx)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
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
          emit_i32_const_raw(buf, 3)
          emit_i32_shl(buf)
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
          emit_i32_const_raw(buf, 3)
          emit_i32_shl(buf)
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
        let entry_key_local = alloc_temp_local(ctx)
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
        emit_i32_const_raw(buf, 3)
        emit_i32_shl(buf)
        emit_i32_add(buf)
        emit_i32_load(buf, 8) // key
        emit_local_set(buf, entry_key_local)
        emit_non_js_string_ptr_equals_i32(ctx, buf, entry_key_local, key_local)
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
      emit_tag_bool_from_i32(buf)
    }
    "Map::keys" => {
      // map_keys(map) -> allocate new array with keys from map
      let pos_args = extract_positional_exprs_with_arity(args, "Map::keys", 1)
      require_heap(ctx)
      let map_ptr = alloc_temp_local(ctx)
      let map_len = alloc_temp_local(ctx)
      let arr_ptr = alloc_temp_local(ctx)
      let loop_i = alloc_temp_local(ctx)
      // get map pointer
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
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
      emit_i32_const_raw(buf, 3)
      emit_i32_shl(buf)
      emit_i32_add(buf)
      emit_i32_load(buf, 8)
      if not(ctx.use_js_strings) {
        emit_i64_extend_i32_u(buf)
        emit_i64_const_raw(buf, tag_obj.to_int64())
        emit_i64_or(buf)
        emit_i32_wrap_i64(buf)
      }
      // store to array
      emit_i32_store(buf, 8)
      // i++
      emit_local_get(buf, loop_i)
      emit_i32_const_raw(buf, 1)
      emit_i32_add(buf)
      emit_local_set(buf, loop_i)
      buf.push((12).to_byte()) // br
      write_u32_leb(buf, 1) // to loop
      buf.push((11).to_byte()) // end if
      buf.push((11).to_byte()) // end loop
      // return tagged arr_ptr
      emit_local_get(buf, arr_ptr)
      emit_i64_extend_i32_u(buf)
      emit_i64_const_raw(buf, tag_obj.to_int64())
      emit_i64_or(buf)
    }
    "Map::values" => {
      // map_values(map) -> allocate new array with values from map
      let pos_args = extract_positional_exprs_with_arity(args, "Map::values", 1)
      require_heap(ctx)
      let map_ptr = alloc_temp_local(ctx)
      let map_len = alloc_temp_local(ctx)
      let arr_ptr = alloc_temp_local(ctx)
      let loop_i = alloc_temp_local(ctx)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
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
      emit_i32_const_raw(buf, 3)
      emit_i32_shl(buf)
      emit_i32_add(buf)
      emit_i32_load(buf, 12) // value at key_offset + 4
      emit_i32_store(buf, 8)
      emit_local_get(buf, loop_i)
      emit_i32_const_raw(buf, 1)
      emit_i32_add(buf)
      emit_local_set(buf, loop_i)
      buf.push((12).to_byte()) // br
      write_u32_leb(buf, 1) // to loop
      buf.push((11).to_byte()) // end if
      buf.push((11).to_byte()) // end loop
      emit_local_get(buf, arr_ptr)
      emit_i64_extend_i32_u(buf)
      emit_i64_const_raw(buf, tag_obj.to_int64())
      emit_i64_or(buf)
    }
    "Array::length" => {
      // array_length(arr) -> load len field, shift left 2 (tag as int)
      // Supports both obj_array (len at offset 4) and
      // obj_array_view (end - start, offsets 12 and 8)
      let pos_args = extract_positional_exprs_with_arity(
        args, "Array::length", 1,
      )
      let arr_ptr = alloc_temp_local(ctx)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, arr_ptr)
      emit_local_get(buf, arr_ptr)
      emit_i32_load(buf, 0) // obj_type
      emit_i32_const_raw(buf, obj_array_view)
      emit_i32_eq(buf)
      buf.push((4).to_byte()) // if (array_view)
      buf.push((126).to_byte()) // result i64
      // ArrayView: length = end - start
      emit_local_get(buf, arr_ptr)
      emit_i32_load(buf, 12) // end
      emit_local_get(buf, arr_ptr)
      emit_i32_load(buf, 8) // start
      emit_i32_sub(buf)
      emit_i64_extend_i32_s(buf)
      emit_i64_const_raw(buf, 2L)
      emit_i64_shl(buf)
      buf.push((5).to_byte()) // else (regular array)
      emit_local_get(buf, arr_ptr)
      emit_i32_load(buf, 4) // length field
      emit_i64_extend_i32_s(buf)
      emit_i64_const_raw(buf, 2L)
      emit_i64_shl(buf)
      buf.push((11).to_byte()) // end if
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
      emit_untag_ptr_i32(buf)
      emit_i32_load(buf, 4)
      emit_i64_extend_i32_s(buf)
      emit_i64_const_raw(buf, 2L)
      emit_i64_shl(buf)
      // tag_int = 0, i64.or is a no-op
    }
    "iter_get" if not(is_user_fn) => {
      // iter_get(xs, idx) -> fallback to array_get(xs, idx)
      let pos_args = extract_positional_exprs_with_arity(args, "iter_get", 2)
      let ptr_local = alloc_temp_local(ctx)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, ptr_local)
      emit_local_get(buf, ptr_local)
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_untag_int_i32(buf)
      emit_i32_const_raw(buf, 4)
      emit_i32_mul(buf)
      emit_i32_add(buf)
      emit_i32_load(buf, 8)
      emit_i64_extend_i32_s(buf)
    }
    "Array::get" => {
      // array_get(arr, idx) -> load arr[idx]
      // Supports both obj_array and obj_array_view
      let pos_args = extract_positional_exprs_with_arity(args, "Array::get", 2)
      let arr_ptr = alloc_temp_local(ctx)
      let idx_local = alloc_temp_local(ctx)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, arr_ptr)
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_untag_int_i32(buf)
      emit_local_set(buf, idx_local)
      emit_local_get(buf, arr_ptr)
      emit_i32_load(buf, 0) // obj_type
      emit_i32_const_raw(buf, obj_array_view)
      emit_i32_eq(buf)
      buf.push((4).to_byte()) // if (array_view)
      buf.push((126).to_byte()) // result i64
      // ArrayView: source[start + idx]
      emit_local_get(buf, arr_ptr)
      emit_i32_load(buf, 4) // source_ptr
      emit_local_get(buf, arr_ptr)
      emit_i32_load(buf, 8) // start
      emit_local_get(buf, idx_local)
      emit_i32_add(buf) // start + idx
      emit_i32_const_raw(buf, 4)
      emit_i32_mul(buf)
      emit_i32_add(buf) // source_ptr + (start + idx) * 4
      emit_i32_load(buf, 8) // load element
      emit_i64_extend_i32_s(buf)
      buf.push((5).to_byte()) // else (regular array)
      // offset = 8 + idx * 4
      emit_local_get(buf, arr_ptr)
      emit_local_get(buf, idx_local)
      emit_i32_const_raw(buf, 4)
      emit_i32_mul(buf)
      emit_i32_add(buf)
      emit_i32_load(buf, 8)
      emit_i64_extend_i32_s(buf)
      buf.push((11).to_byte()) // end if
    }
    "Array::set" => {
      // array_set(arr, idx, value) -> arr[idx] = value
      let pos_args = extract_positional_exprs_with_arity(args, "Array::set", 3)
      let ptr_local = alloc_temp_local(ctx)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, ptr_local)
      // addr = ptr + 8 + (idx >> 2) * 4
      emit_local_get(buf, ptr_local)
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_untag_int_i32(buf)
      emit_i32_const_raw(buf, 4)
      emit_i32_mul(buf)
      emit_i32_add(buf)
      // store value
      compile_expr_i32(ctx, buf, pos_args[2])
      emit_i32_wrap_i64(buf)
      emit_i32_store(buf, 8)
      emit_i64_const_tagged(buf, 0L) // return Unit
    }
    "FixedArray::make" => {
      // FixedArray::make(size, default) -> same as array_new
      let pos_args = extract_positional_exprs_with_arity(
        args, "FixedArray::make", 2,
      )
      require_heap(ctx)
      let size_local = alloc_temp_local(ctx)
      let val_local = alloc_temp_local(ctx)
      let obj_local = alloc_temp_local(ctx)
      let idx_local = alloc_temp_local(ctx)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_int_i32(buf)
      emit_local_set(buf, size_local)
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_i32_wrap_i64(buf)
      emit_local_set(buf, val_local)
      emit_local_get(buf, size_local)
      emit_i32_const_raw(buf, 4)
      emit_i32_mul(buf)
      emit_i32_const_raw(buf, 8)
      emit_i32_add(buf)
      emit_i32_const_raw(buf, 3)
      emit_i32_add(buf)
      emit_i32_const_raw(buf, -4)
      emit_i32_and(buf)
      let alloc_size_local = alloc_temp_local(ctx)
      emit_local_set(buf, alloc_size_local)
      emit_global_get(buf, ctx.heap_global)
      emit_local_tee(buf, obj_local)
      emit_local_get(buf, alloc_size_local)
      emit_i32_add(buf)
      emit_global_set(buf, ctx.heap_global)
      ctx.heap_synced = false
      emit_local_get(buf, obj_local)
      emit_i32_const_raw(buf, obj_array)
      emit_i32_store(buf, 0)
      emit_local_get(buf, obj_local)
      emit_local_get(buf, size_local)
      emit_i32_store(buf, 4)
      emit_i32_const_raw(buf, 0)
      emit_local_set(buf, idx_local)
      emit_block(buf)
      emit_loop(buf)
      emit_local_get(buf, idx_local)
      emit_local_get(buf, size_local)
      emit_i32_ge_s(buf)
      emit_br_if(buf, 1)
      emit_local_get(buf, obj_local)
      emit_local_get(buf, idx_local)
      emit_i32_const_raw(buf, 4)
      emit_i32_mul(buf)
      emit_i32_add(buf)
      emit_local_get(buf, val_local)
      emit_i32_store(buf, 8)
      emit_local_get(buf, idx_local)
      emit_i32_const_raw(buf, 1)
      emit_i32_add(buf)
      emit_local_set(buf, idx_local)
      emit_br(buf, 0)
      emit_end(buf)
      emit_end(buf)
      emit_local_get(buf, obj_local)
      emit_i64_extend_i32_u(buf)
      emit_i64_const_raw(buf, tag_obj.to_int64())
      emit_i64_or(buf)
    }
    "FixedArray::length" => {
      // FixedArray::length(arr) -> read header length
      let pos_args = extract_positional_exprs_with_arity(
        args, "FixedArray::length", 1,
      )
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_i32_load(buf, 4)
      emit_i64_extend_i32_s(buf)
      emit_i64_const_raw(buf, 2L)
      emit_i64_shl(buf)
    }
    "FixedArray::get" => {
      // FixedArray::get(arr, idx) -> arr[idx]
      let pos_args = extract_positional_exprs_with_arity(
        args, "FixedArray::get", 2,
      )
      let ptr_local = alloc_temp_local(ctx)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, ptr_local)
      emit_local_get(buf, ptr_local)
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_untag_int_i32(buf)
      emit_i32_const_raw(buf, 4)
      emit_i32_mul(buf)
      emit_i32_add(buf)
      emit_i32_load(buf, 8)
      emit_i64_extend_i32_s(buf)
    }
    "FixedArray::set" | "FixedArray::unsafe_set" => {
      // FixedArray::set(arr, idx, val) / FixedArray::unsafe_set(arr, idx, val)
      // -> store val at arr[idx], no length update
      let pos_args = extract_positional_exprs_with_arity(args, name, 3)
      let ptr_local = alloc_temp_local(ctx)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, ptr_local)
      emit_local_get(buf, ptr_local)
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_untag_int_i32(buf)
      emit_i32_const_raw(buf, 4)
      emit_i32_mul(buf)
      emit_i32_add(buf)
      compile_expr_i32(ctx, buf, pos_args[2])
      emit_i32_wrap_i64(buf)
      emit_i32_store(buf, 8)
      emit_i64_const_tagged(buf, 0L)
    }
    "FixedArray::blit" => {
      // FixedArray::blit(dst, dst_off, src, src_off, len)
      // -> memory.copy(dst_addr, src_addr, byte_count)
      // dst_addr = untag(dst) + 8 + dst_off_raw * 4
      // src_addr = untag(src) + 8 + src_off_raw * 4
      // byte_count = len_raw * 4
      let pos_args = extract_positional_exprs_with_arity(
        args, "FixedArray::blit", 5,
      )
      let dst_ptr = alloc_temp_local(ctx)
      let src_ptr = alloc_temp_local(ctx)
      // dst ptr
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, dst_ptr)
      // src ptr
      compile_expr_i32(ctx, buf, pos_args[2])
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, src_ptr)
      // push dst_addr: dst_ptr + 8 + dst_off_raw * 4
      emit_local_get(buf, dst_ptr)
      emit_i32_const_raw(buf, 8)
      emit_i32_add(buf)
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_untag_int_i32(buf)
      emit_i32_const_raw(buf, 4)
      emit_i32_mul(buf)
      emit_i32_add(buf)
      // push src_addr: src_ptr + 8 + src_off_raw * 4
      emit_local_get(buf, src_ptr)
      emit_i32_const_raw(buf, 8)
      emit_i32_add(buf)
      compile_expr_i32(ctx, buf, pos_args[3])
      emit_untag_int_i32(buf)
      emit_i32_const_raw(buf, 4)
      emit_i32_mul(buf)
      emit_i32_add(buf)
      // push byte_count: len_raw * 4
      compile_expr_i32(ctx, buf, pos_args[4])
      emit_untag_int_i32(buf)
      emit_i32_const_raw(buf, 4)
      emit_i32_mul(buf)
      // memory.copy
      emit_memory_copy(buf)
      emit_i64_const_tagged(buf, 0L)
    }
    "__len" => {
      let pos_args = extract_positional_exprs_with_arity(args, "__len", 1)
      let ptr_local = alloc_temp_local(ctx)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, ptr_local)
      emit_local_get(buf, ptr_local)
      emit_i32_load(buf, 0)
      emit_i32_const_raw(buf, obj_string)
      emit_i32_eq(buf)
      buf.push((4).to_byte()) // if (string)
      buf.push((126).to_byte()) // result i64
      emit_local_get(buf, ptr_local)
      emit_i32_load(buf, 4)
      emit_i64_extend_i32_u(buf)
      emit_i64_const_raw(buf, 2L)
      emit_i64_shl(buf)
      buf.push((5).to_byte()) // else
      emit_local_get(buf, ptr_local)
      emit_i32_load(buf, 0)
      emit_i32_const_raw(buf, obj_bytes_view)
      emit_i32_eq(buf)
      emit_local_get(buf, ptr_local)
      emit_i32_load(buf, 0)
      emit_i32_const_raw(buf, obj_array_view)
      emit_i32_eq(buf)
      emit_i32_or(buf)
      buf.push((4).to_byte()) // if (bytes_view or array_view)
      buf.push((126).to_byte()) // result i64
      emit_local_get(buf, ptr_local)
      emit_i32_load(buf, 12)
      emit_local_get(buf, ptr_local)
      emit_i32_load(buf, 8)
      emit_i32_sub(buf)
      emit_i64_extend_i32_s(buf)
      emit_i64_const_raw(buf, 2L)
      emit_i64_shl(buf)
      buf.push((5).to_byte()) // else (bytes or array)
      emit_local_get(buf, ptr_local)
      emit_i32_load(buf, 4)
      emit_i64_extend_i32_u(buf)
      emit_i64_const_raw(buf, 2L)
      emit_i64_shl(buf)
      buf.push((11).to_byte()) // end if (view)
      buf.push((11).to_byte()) // end if (string)
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
          emit_untag_ptr_i32(buf)
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
          emit_i32_const_raw(buf, 3)
          emit_i32_shl(buf)
          emit_i32_add(buf)
          emit_i32_load(buf, 8) // name_ptr
          emit_i32_const_raw(buf, field_ptr)
          emit_i32_eq(buf)
          buf.push((4).to_byte()) // if (name matches)
          buf.push((64).to_byte()) // void
          // load value at obj_ptr + loop_i * 8 + 12
          emit_local_get(buf, obj_ptr)
          emit_local_get(buf, loop_i)
          emit_i32_const_raw(buf, 3)
          emit_i32_shl(buf)
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
          // Integer index: array access or string char access
          let obj_local = alloc_temp_local_with_kind(ctx, ValueKind::I64)
          let ptr_local = alloc_temp_local(ctx)
          compile_expr_i32(ctx, buf, pos_args[0])
          emit_local_set(buf, obj_local)
          emit_local_get(buf, obj_local)
          emit_untag_ptr_i32(buf)
          emit_local_set(buf, ptr_local)
          // Check obj_type: string (1) vs array (5)
          emit_local_get(buf, ptr_local)
          emit_i32_load(buf, 0) // obj_type
          emit_i32_const_raw(buf, obj_string)
          emit_i32_eq(buf)
          buf.push((4).to_byte()) // if (string)
          buf.push((126).to_byte()) // result i64
          // String path: emit substring(s, i, i+1) inline
          let _ = compile_call_builtin_pre_user(
            ctx,
            buf,
            "String::substring",
            [
              @core.CallArg::{
                label: None,
                expr: pos_args[0],
                span: pos_args[0].span(),
              },
              @core.CallArg::{
                label: None,
                expr: pos_args[1],
                span: pos_args[1].span(),
              },
              @core.CallArg::{
                label: None,
                expr: @core.Expr::Call(
                  name="__add",
                  type_args=[],
                  args=[
                    @core.CallArg::{
                      label: None,
                      expr: pos_args[1],
                      span: pos_args[1].span(),
                    },
                    @core.CallArg::{
                      label: None,
                      expr: @core.Expr::Int(value=1L, span=pos_args[1].span()),
                      span: pos_args[1].span(),
                    },
                  ],
                  span=pos_args[1].span(),
                ),
                span: pos_args[1].span(),
              },
            ],
            false,
          )
          buf.push((5).to_byte()) // else
          // Check for obj_bytes_view
          emit_local_get(buf, ptr_local)
          emit_i32_load(buf, 0)
          emit_i32_const_raw(buf, obj_bytes_view)
          emit_i32_eq(buf)
          buf.push((4).to_byte()) // if (bytes_view)
          buf.push((126).to_byte()) // result i64
          // BytesView: source_data[start + idx] load8_u, tag
          let bv_idx = alloc_temp_local(ctx)
          let bv_source_local = alloc_temp_local(ctx)
          compile_expr_i32(ctx, buf, pos_args[1])
          emit_untag_int_i32(buf)
          emit_local_set(buf, bv_idx)
          emit_local_get(buf, ptr_local)
          emit_i32_load(buf, 4) // source_ptr
          emit_local_set(buf, bv_source_local)
          emit_local_get(buf, bv_source_local)
          emit_i32_load(buf, 12) // source data_ptr
          emit_local_get(buf, ptr_local)
          emit_i32_load(buf, 8) // start
          emit_local_get(buf, bv_idx)
          emit_i32_add(buf)
          emit_i32_add(buf)
          emit_i32_load8_u(buf, 0) // load byte
          emit_i64_extend_i32_u(buf)
          emit_i64_const_raw(buf, 2L)
          emit_i64_shl(buf) // tag as int
          buf.push((5).to_byte()) // else (not bytes_view)
          // Check for obj_bytes
          emit_local_get(buf, ptr_local)
          emit_i32_load(buf, 0)
          emit_i32_const_raw(buf, obj_bytes)
          emit_i32_eq(buf)
          buf.push((4).to_byte()) // if (bytes)
          buf.push((126).to_byte()) // result i64
          // Bytes: data_ptr[idx] load8_u, tag
          emit_local_get(buf, ptr_local)
          emit_i32_load(buf, 12)
          compile_expr_i32(ctx, buf, pos_args[1])
          emit_untag_int_i32(buf)
          emit_i32_add(buf)
          emit_i32_load8_u(buf, 0) // load byte at [data_ptr + idx]
          emit_i64_extend_i32_u(buf)
          emit_i64_const_raw(buf, 2L)
          emit_i64_shl(buf) // tag as int
          buf.push((5).to_byte()) // else (not bytes)
          // Check for array_view
          emit_local_get(buf, ptr_local)
          emit_i32_load(buf, 0)
          emit_i32_const_raw(buf, obj_array_view)
          emit_i32_eq(buf)
          buf.push((4).to_byte()) // if (array_view)
          buf.push((126).to_byte()) // result i64
          // ArrayView: source[start + idx]
          let av_idx = alloc_temp_local(ctx)
          compile_expr_i32(ctx, buf, pos_args[1])
          emit_untag_int_i32(buf)
          emit_local_set(buf, av_idx)
          emit_local_get(buf, ptr_local)
          emit_i32_load(buf, 4) // source_ptr
          emit_local_get(buf, ptr_local)
          emit_i32_load(buf, 8) // start
          emit_local_get(buf, av_idx)
          emit_i32_add(buf)
          emit_i32_const_raw(buf, 4)
          emit_i32_mul(buf)
          emit_i32_add(buf)
          emit_i32_load(buf, 8)
          emit_i64_extend_i32_s(buf)
          buf.push((5).to_byte()) // else (regular array)
          // Array path: direct access at offset 8 + (idx >> 2) * 4
          emit_local_get(buf, ptr_local)
          compile_expr_i32(ctx, buf, pos_args[1])
          emit_untag_int_i32(buf)
          emit_i32_const_raw(buf, 4)
          emit_i32_mul(buf)
          emit_i32_add(buf)
          emit_i32_load(buf, 8)
          emit_i64_extend_i32_s(buf)
          buf.push((11).to_byte()) // end if (array_view)
          buf.push((11).to_byte()) // end if (bytes)
          buf.push((11).to_byte()) // end if (bytes_view)
          buf.push((11).to_byte()) // end if (string)
        }
      }
    }
    "__slice" => {
      // __slice(container, start, end) -> String/Bytes materialized copy,
      // Array view zero-copy.
      let pos_args = extract_positional_exprs_with_arity(args, "__slice", 3)
      require_heap(ctx)
      let source_local = alloc_temp_local_with_kind(ctx, ValueKind::I64)
      let ptr_local = alloc_temp_local(ctx)
      let obj_local = alloc_temp_local(ctx)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_local_set(buf, source_local)
      emit_local_get(buf, source_local)
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, ptr_local)
      // Allocate 16 bytes for view
      // Check if source is string or array
      emit_local_get(buf, ptr_local)
      emit_i32_load(buf, 0) // source obj_type
      emit_i32_const_raw(buf, obj_string) // 1
      emit_i32_eq(buf)
      buf.push((4).to_byte()) // if (string)
      buf.push((126).to_byte()) // result i64
      // String path: emit String::substring inline (materialized copy)
      let _ = compile_call_builtin_pre_user(
        ctx, buf, "String::substring", args, false,
      )
      buf.push((5).to_byte()) // else
      // Bytes/BytesView path: emit Bytes::slice inline (materialized copy)
      emit_local_get(buf, ptr_local)
      emit_i32_load(buf, 0) // source obj_type
      emit_i32_const_raw(buf, obj_bytes)
      emit_i32_eq(buf)
      emit_local_get(buf, ptr_local)
      emit_i32_load(buf, 0)
      emit_i32_const_raw(buf, obj_bytes_view)
      emit_i32_eq(buf)
      emit_i32_or(buf)
      buf.push((4).to_byte()) // if (bytes or bytes_view)
      buf.push((126).to_byte()) // result i64
      let _ = compile_call_builtin_pre_user(
        ctx, buf, "Bytes::slice", args, false,
      )
      buf.push((5).to_byte()) // else (array -> view zero-copy)
      let size = 16
      emit_heap_alloc(ctx, buf, size, obj_local)
      emit_local_get(buf, obj_local)
      emit_i32_const_raw(buf, obj_array_view)
      emit_i32_store(buf, 0)
      emit_local_get(buf, obj_local)
      emit_local_get(buf, ptr_local)
      emit_i32_store(buf, 4)
      emit_local_get(buf, obj_local)
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_untag_int_i32(buf)
      emit_i32_store(buf, 8)
      emit_local_get(buf, obj_local)
      compile_expr_i32(ctx, buf, pos_args[2])
      emit_untag_int_i32(buf)
      emit_i32_store(buf, 12)
      emit_local_get(buf, obj_local)
      emit_i64_extend_i32_u(buf)
      emit_i64_const_raw(buf, tag_obj.to_int64())
      emit_i64_or(buf)
      buf.push((11).to_byte()) // end if (bytes-like)
      buf.push((11).to_byte()) // end if (string)
    }
    "__set_index" => {
      // __set_index(arr, idx, value) -> arr[idx] = value; return value
      // This is used by index-assignment desugaring (e.g. cursor[0] = x).
      let pos_args = extract_positional_exprs_with_arity(args, "__set_index", 3)
      let ptr_local = alloc_temp_local(ctx)
      let idx_local = alloc_temp_local(ctx)
      let value_local = alloc_temp_local_with_kind(ctx, ValueKind::I64)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, ptr_local)
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_untag_int_i32(buf)
      emit_local_set(buf, idx_local)
      compile_expr_i32(ctx, buf, pos_args[2])
      emit_local_set(buf, value_local)
      // Check if target is Bytes (packed) or Array (4-byte stride)
      emit_local_get(buf, ptr_local)
      emit_i32_load(buf, 0)
      emit_i32_const_raw(buf, obj_bytes)
      emit_i32_eq(buf)
      buf.push((4).to_byte()) // if (bytes)
      buf.push((64).to_byte()) // void
      // Bytes: store8 at [data_ptr + idx], untag value
      emit_local_get(buf, ptr_local)
      emit_i32_load(buf, 12)
      emit_local_get(buf, idx_local)
      emit_i32_add(buf)
      emit_local_get(buf, value_local)
      emit_i64_const_raw(buf, 2L)
      emit_i64_shr_u(buf) // untag byte value
      emit_i32_wrap_i64(buf)
      emit_i32_store8(buf, 0)
      buf.push((5).to_byte()) // else (array)
      // Array: store i32 at [ptr + 8 + idx*4]
      emit_local_get(buf, ptr_local)
      emit_local_get(buf, idx_local)
      emit_i32_const_raw(buf, 4)
      emit_i32_mul(buf)
      emit_i32_add(buf)
      emit_local_get(buf, value_local)
      emit_i32_wrap_i64(buf)
      emit_i32_store(buf, 8)
      buf.push((11).to_byte()) // end if
      emit_local_get(buf, value_local)
    }
    "Map::get" => {
      // map_get(map, key) -> linear search for key, return value
      let pos_args = extract_positional_exprs_with_arity(args, "Map::get", 2)
      let map_ptr = alloc_temp_local(ctx)
      let map_len = alloc_temp_local(ctx)
      let loop_i = alloc_temp_local(ctx)
      let result_local = alloc_temp_local(ctx)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
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
          emit_i32_const_raw(buf, 3)
          emit_i32_shl(buf)
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
          emit_i32_const_raw(buf, 3)
          emit_i32_shl(buf)
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
          emit_i32_const_raw(buf, 3)
          emit_i32_shl(buf)
          emit_i32_add(buf)
          emit_i32_load(buf, 8) // key
          emit_local_get(buf, key_local)
          emit_i32_eq(buf)
          buf.push((4).to_byte()) // if
          buf.push((64).to_byte()) // void
          emit_local_get(buf, map_ptr)
          emit_local_get(buf, loop_i)
          emit_i32_const_raw(buf, 3)
          emit_i32_shl(buf)
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
        let entry_key_local = alloc_temp_local(ctx)
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
        emit_i32_const_raw(buf, 3)
        emit_i32_shl(buf)
        emit_i32_add(buf)
        emit_i32_load(buf, 8) // key
        emit_local_set(buf, entry_key_local)
        emit_non_js_string_ptr_equals_i32(ctx, buf, entry_key_local, key_local)
        buf.push((4).to_byte()) // if
        buf.push((64).to_byte()) // void
        emit_local_get(buf, map_ptr)
        emit_local_get(buf, loop_i)
        emit_i32_const_raw(buf, 3)
        emit_i32_shl(buf)
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
    "Stdout::write_char" => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "Stdout::write_char", 1,
      )
      require_heap(ctx)
      let code_local = alloc_temp_local(ctx)
      let out_stream_local = alloc_temp_local(ctx)
      let scratch_local = alloc_temp_local(ctx)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_int_i32(buf)
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
    "Stdout::write_stream" => {
      if ctx.use_js_strings {
        raise WasmGenError::Unsupported(
          "Stdout::write_stream requires --wasm backend",
        )
      }
      let pos_args = extract_positional_exprs_with_arity(
        args, "Stdout::write_stream", 1,
      )
      require_heap(ctx)
      let raw_local = alloc_temp_local(ctx)
      let len_local = alloc_temp_local(ctx)
      let out_stream_local = alloc_temp_local(ctx)
      let ret_area_local = alloc_temp_local(ctx)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
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
    "Stdin::read_char" => {
      let _ = extract_positional_exprs_with_arity(args, "Stdin::read_char", 0)
      require_heap(ctx)
      let in_stream_local = alloc_temp_local(ctx)
      let ret_area_local = alloc_temp_local(ctx)
      let data_ptr_local = alloc_temp_local(ctx)
      let data_len_local = alloc_temp_local(ctx)
      emit_call(buf, import_index_stdin_get_stream(ctx))
      emit_local_set(buf, in_stream_local)
      emit_heap_alloc(ctx, buf, align4(16), ret_area_local)
      // imported `blocking-read` may call cabi_realloc; sync local heap first.
      emit_heap_pre_call_sync(ctx, buf)
      emit_local_get(buf, in_stream_local)
      // i64.const 1 (len=1)
      buf.push((66).to_byte())
      buf.push((1).to_byte())
      emit_local_get(buf, ret_area_local)
      emit_call(buf, import_index_stdin_read_stream(ctx))
      // reload heap in case cabi_realloc bumped it.
      emit_heap_post_call_sync(ctx, buf)
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
      // tag_int = 0, i64.or is a no-op
      buf.push((11).to_byte()) // end if
      buf.push((5).to_byte()) // else
      emit_i64_const_raw(buf, tag_int_value64(-1L))
      buf.push((11).to_byte()) // end if
    }
    "Stdin::read_stream" => {
      if ctx.use_js_strings {
        raise WasmGenError::Unsupported(
          "Stdin::read_stream requires --wasm backend",
        )
      }
      let pos_args = extract_positional_exprs_with_arity(
        args, "Stdin::read_stream", 1,
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
      emit_untag_int_i32(buf)
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
      emit_heap_pre_call_sync(ctx, buf)
      emit_local_get(buf, in_stream_local)
      emit_local_get(buf, req_len_local)
      // i64.extend_i32_u
      buf.push((173).to_byte())
      emit_local_get(buf, ret_area_local)
      emit_call(buf, import_index_stdin_read_stream(ctx))
      // reload heap in case cabi_realloc bumped it.
      emit_heap_post_call_sync(ctx, buf)
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
    "Fs::exists" => {
      if ctx.use_js_strings {
        raise WasmGenError::Unsupported("Fs::exists requires --wasm backend")
      }
      if ctx.fs_host_imports {
        let pos_args = extract_positional_exprs_with_arity(args, "Fs::exists", 1)
        compile_expr(ctx, buf, pos_args[0])
        emit_call(buf, import_index_fs_host_exists(ctx))
      } else {
      let pos_args = extract_positional_exprs_with_arity(args, "Fs::exists", 1)
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
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, raw_local)
      emit_local_get(buf, raw_local)
      emit_i32_load(buf, 4) // len
      emit_local_set(buf, len_local)
      // Allocate retptr for stat-at result (needs ~96 bytes)
      emit_heap_alloc(ctx, buf, align4(96), ret_area_local)
      // Sync heap before WASI call
      emit_heap_pre_call_sync(ctx, buf)
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
      emit_heap_post_call_sync(ctx, buf)
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
      } // end else (WASI path)
    }
    "Fs::stat_token" => {
      if ctx.use_js_strings {
        raise WasmGenError::Unsupported(
          "Fs::stat_token requires --wasm backend",
        )
      }
      if ctx.fs_host_imports {
        let pos_args = extract_positional_exprs_with_arity(
          args, "Fs::stat_token", 1,
        )
        compile_expr(ctx, buf, pos_args[0])
        emit_call(buf, import_index_fs_host_stat_token(ctx))
      } else {
      let pos_args = extract_positional_exprs_with_arity(
        args, "Fs::stat_token", 1,
      )
      require_heap(ctx)
      let raw_local = alloc_temp_local(ctx)
      let len_local = alloc_temp_local(ctx)
      let ret_area_local = alloc_temp_local(ctx)
      let root_desc_local = alloc_temp_local(ctx)
      let fs_global = fs_root_descriptor_global_index(ctx)
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
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, raw_local)
      emit_local_get(buf, raw_local)
      emit_i32_load(buf, 4)
      emit_local_set(buf, len_local)
      emit_heap_alloc(ctx, buf, align4(24), ret_area_local)
      emit_heap_pre_call_sync(ctx, buf)
      emit_local_get(buf, root_desc_local)
      emit_i32_const_raw(buf, 0)
      emit_local_get(buf, raw_local)
      emit_i32_const_raw(buf, 8)
      emit_i32_add(buf)
      emit_local_get(buf, len_local)
      emit_local_get(buf, ret_area_local)
      emit_call(buf, import_index_fs_metadata_hash_at(ctx))
      emit_heap_post_call_sync(ctx, buf)
      emit_local_get(buf, ret_area_local)
      emit_i32_load8_u(buf, 0)
      emit_i32_eqz(buf)
      buf.push((4).to_byte()) // if
      buf.push((126).to_byte()) // result i64
      emit_local_get(buf, ret_area_local)
      emit_i64_load(buf, 8)
      emit_local_get(buf, ret_area_local)
      emit_i64_load(buf, 16)
      emit_i64_xor(buf)
      emit_i64_const_raw(buf, 2305843009213693951L)
      emit_i64_and(buf)
      emit_i64_const_raw(buf, 2L)
      emit_i64_shl(buf)
      buf.push((5).to_byte()) // else
      emit_i64_const_raw(buf, tag_int_value64(0L))
      buf.push((11).to_byte()) // end if
      } // end else (WASI path)
    }
    "Fs::read_file" => {
      if ctx.use_js_strings {
        raise WasmGenError::Unsupported("Fs::read_file requires --wasm backend")
      }
      if ctx.fs_host_imports {
        let pos_args = extract_positional_exprs_with_arity(
          args, "Fs::read_file", 1,
        )
        compile_expr(ctx, buf, pos_args[0])
        emit_call(buf, import_index_fs_host_read_file(ctx))
      } else {
      let pos_args = extract_positional_exprs_with_arity(
        args, "Fs::read_file", 1,
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
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, raw_local)
      emit_local_get(buf, raw_local)
      emit_i32_load(buf, 4) // len
      emit_local_set(buf, len_local)
      // Allocate retptr for open-at result
      emit_heap_alloc(ctx, buf, align4(16), ret_area_local)
      // Sync heap
      emit_heap_pre_call_sync(ctx, buf)
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
      emit_heap_post_call_sync(ctx, buf)
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
      emit_heap_pre_call_sync(ctx, buf)
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
      emit_heap_post_call_sync(ctx, buf)
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
      } // end else (WASI path)
    }
    "Fs::write_file" => {
      if ctx.use_js_strings {
        raise WasmGenError::Unsupported(
          "Fs::write_file requires --wasm backend",
        )
      }
      if ctx.fs_host_imports {
        let pos_args = extract_positional_exprs_with_arity(
          args, "Fs::write_file", 2,
        )
        compile_expr(ctx, buf, pos_args[0])
        compile_expr(ctx, buf, pos_args[1])
        emit_call(buf, import_index_fs_host_write_file(ctx))
      } else {
      let pos_args = extract_positional_exprs_with_arity(
        args, "Fs::write_file", 2,
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
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, path_raw_local)
      emit_local_get(buf, path_raw_local)
      emit_i32_load(buf, 4)
      emit_local_set(buf, path_len_local)
      // Extract content string
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, content_raw_local)
      emit_local_get(buf, content_raw_local)
      emit_i32_load(buf, 4)
      emit_local_set(buf, content_len_local)
      // Allocate retptr for open-at result
      emit_heap_alloc(ctx, buf, align4(16), ret_area_local)
      // Sync heap
      emit_heap_pre_call_sync(ctx, buf)
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
      emit_heap_post_call_sync(ctx, buf)
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
      emit_heap_pre_call_sync(ctx, buf)
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
      emit_heap_post_call_sync(ctx, buf)
      // resource-drop opened descriptor
      emit_local_get(buf, opened_desc_local)
      emit_call(buf, import_index_fs_resource_drop(ctx))
      // Return Unit
      emit_i64_const_raw(buf, tag_int_value64(0L))
      buf.push((5).to_byte()) // else (open error)
      emit_i64_const_raw(buf, tag_int_value64(0L))
      buf.push((11).to_byte()) // end if
      } // end else (WASI path for Fs::write_file)
    }
    "Bytes::from_array" => {
      // bytes_from_array(arr) -> Bytes
      let pos_args = extract_positional_exprs_with_arity(
        args, "Bytes::from_array", 1,
      )
      require_heap(ctx)
      let src_local = alloc_temp_local(ctx)
      let len_local = alloc_temp_local(ctx)
      let cap_local = alloc_temp_local(ctx)
      let obj_local = alloc_temp_local(ctx)
      let data_local = alloc_temp_local(ctx)
      let idx_local = alloc_temp_local(ctx)
      // Get source array ptr and length
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, src_local)
      emit_local_get(buf, src_local)
      emit_i32_load(buf, 4) // len
      emit_local_set(buf, len_local)
      emit_local_get(buf, len_local)
      emit_local_set(buf, cap_local)
      emit_bytes_raw_alloc_with_cap_local(
        ctx, buf, len_local, cap_local, obj_local, data_local,
      )
      // Loop: load i32 from src[8+idx*4], >>2, store8 to data[idx]
      emit_i32_const_raw(buf, 0)
      emit_local_set(buf, idx_local)
      emit_block(buf)
      emit_loop(buf)
      emit_local_get(buf, idx_local)
      emit_local_get(buf, len_local)
      emit_i32_ge_s(buf)
      emit_br_if(buf, 1)
      emit_local_get(buf, data_local)
      emit_local_get(buf, idx_local)
      emit_i32_add(buf)
      emit_local_get(buf, src_local)
      emit_local_get(buf, idx_local)
      emit_i32_const_raw(buf, 4)
      emit_i32_mul(buf)
      emit_i32_add(buf)
      emit_i32_load(buf, 8) // load tagged int from array
      emit_i32_const_raw(buf, 2)
      emit_i32_shr_u(buf) // untag
      emit_i32_store8(buf, 0) // store byte
      emit_local_get(buf, idx_local)
      emit_i32_const_raw(buf, 1)
      emit_i32_add(buf)
      emit_local_set(buf, idx_local)
      emit_br(buf, 0)
      emit_end(buf)
      emit_end(buf)
      // Return tagged obj
      emit_local_get(buf, obj_local)
      emit_i64_extend_i32_u(buf)
      emit_i64_const_raw(buf, tag_obj.to_int64())
      emit_i64_or(buf)
    }
    "Bytes::from_string" => {
      // Bytes::from_string(str) -> Bytes
      let pos_args = extract_positional_exprs_with_arity(
        args, "Bytes::from_string", 1,
      )
      require_heap(ctx)
      let src_local = alloc_temp_local(ctx)
      let len_local = alloc_temp_local(ctx)
      let cap_local = alloc_temp_local(ctx)
      let obj_local = alloc_temp_local(ctx)
      let data_local = alloc_temp_local(ctx)
      // src ptr (string)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, src_local)
      emit_local_get(buf, src_local)
      emit_i32_load(buf, 4) // len
      emit_local_set(buf, len_local)
      emit_local_get(buf, len_local)
      emit_local_set(buf, cap_local)
      emit_bytes_raw_alloc_with_cap_local(
        ctx, buf, len_local, cap_local, obj_local, data_local,
      )
      // memory.copy(data_ptr, src+8, len)
      emit_local_get(buf, data_local)
      emit_local_get(buf, src_local)
      emit_i32_const_raw(buf, 8)
      emit_i32_add(buf)
      emit_local_get(buf, len_local)
      emit_memory_copy(buf)
      // Return tagged obj
      emit_local_get(buf, obj_local)
      emit_i64_extend_i32_u(buf)
      emit_i64_const_raw(buf, tag_obj.to_int64())
      emit_i64_or(buf)
    }
    "Bytes::to_string" => {
      // Bytes::to_string(bytes) -> String (copy byte data)
      let pos_args = extract_positional_exprs_with_arity(
        args, "Bytes::to_string", 1,
      )
      require_heap(ctx)
      let src_local = alloc_temp_local(ctx)
      let len_local = alloc_temp_local(ctx)
      let cap_local = alloc_temp_local(ctx)
      let data_local = alloc_temp_local(ctx)
      let obj_local = alloc_temp_local(ctx)
      // src ptr (bytes)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, src_local)
      emit_bytes_load_header(
        ctx, buf, src_local, len_local, cap_local, data_local,
      )
      // Alloc: align4(8 + len)
      emit_local_get(buf, len_local)
      emit_i32_const_raw(buf, 8)
      emit_i32_add(buf)
      emit_i32_const_raw(buf, 3)
      emit_i32_add(buf)
      emit_i32_const_raw(buf, -4)
      emit_i32_and(buf)
      let alloc_size_local = alloc_temp_local(ctx)
      emit_local_set(buf, alloc_size_local)
      emit_global_get(buf, ctx.heap_global)
      emit_local_tee(buf, obj_local)
      emit_local_get(buf, alloc_size_local)
      emit_i32_add(buf)
      emit_global_set(buf, ctx.heap_global)
      ctx.heap_synced = false
      // header: obj_string, len
      emit_local_get(buf, obj_local)
      emit_i32_const_raw(buf, obj_string)
      emit_i32_store(buf, 0)
      emit_local_get(buf, obj_local)
      emit_local_get(buf, len_local)
      emit_i32_store(buf, 4)
      // memory.copy(dst+8, data_ptr, len)
      emit_local_get(buf, obj_local)
      emit_i32_const_raw(buf, 8)
      emit_i32_add(buf)
      emit_local_get(buf, data_local)
      emit_local_get(buf, len_local)
      emit_memory_copy(buf)
      // Return tagged obj
      emit_local_get(buf, obj_local)
      emit_i64_extend_i32_u(buf)
      emit_i64_const_raw(buf, tag_obj.to_int64())
      emit_i64_or(buf)
    }
    "Bytes::length" => {
      // bytes_length(bytes) -> Int (tagged)
      // Supports both raw Bytes and BytesView via emit_bytes_load_header
      let pos_args = extract_positional_exprs_with_arity(
        args, "Bytes::length", 1,
      )
      let ptr_local = alloc_temp_local(ctx)
      let len_local = alloc_temp_local(ctx)
      let cap_local = alloc_temp_local(ctx)
      let data_local = alloc_temp_local(ctx)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, ptr_local)
      emit_bytes_load_header(
        ctx, buf, ptr_local, len_local, cap_local, data_local,
      )
      emit_local_get(buf, len_local)
      emit_i64_extend_i32_u(buf)
      emit_i64_const_raw(buf, 2L)
      emit_i64_shl(buf) // tag as int
    }
    "Bytes::get" => {
      // bytes_get(bytes, idx) -> Int (tagged byte value)
      // Supports both raw Bytes and BytesView via emit_bytes_load_header
      let pos_args = extract_positional_exprs_with_arity(args, "Bytes::get", 2)
      let ptr_local = alloc_temp_local(ctx)
      let len_local = alloc_temp_local(ctx)
      let cap_local = alloc_temp_local(ctx)
      let data_local = alloc_temp_local(ctx)
      let idx_local = alloc_temp_local(ctx)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, ptr_local)
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_i64_const_raw(buf, 2L)
      emit_i64_shr_s(buf) // untag index
      emit_i32_wrap_i64(buf)
      emit_local_set(buf, idx_local)
      emit_bytes_load_header(
        ctx, buf, ptr_local, len_local, cap_local, data_local,
      )
      emit_local_get(buf, data_local)
      emit_local_get(buf, idx_local)
      emit_i32_add(buf)
      emit_i32_load8_u(buf, 0)
      emit_i64_extend_i32_u(buf)
      emit_i64_const_raw(buf, 2L)
      emit_i64_shl(buf) // tag as int
    }
    "Bytes::new" => {
      // Bytes::new() -> empty bytes with reserved packed byte storage
      require_heap(ctx)
      let len_local = alloc_temp_local(ctx)
      let cap_local = alloc_temp_local(ctx)
      let obj_local = alloc_temp_local(ctx)
      let data_local = alloc_temp_local(ctx)
      emit_i32_const_raw(buf, 0)
      emit_local_set(buf, len_local)
      emit_i32_const_raw(buf, 64)
      emit_local_set(buf, cap_local)
      emit_bytes_raw_alloc_with_cap_local(
        ctx, buf, len_local, cap_local, obj_local, data_local,
      )
      // Return tagged obj
      emit_local_get(buf, obj_local)
      emit_i64_extend_i32_u(buf)
      emit_i64_const_raw(buf, tag_obj.to_int64())
      emit_i64_or(buf)
    }
    "Bytes::push" => {
      // Bytes::push(bytes, byte_val) -> append one packed byte
      let pos_args = extract_positional_exprs_with_arity(args, "Bytes::push", 2)
      let ptr_local = alloc_temp_local(ctx)
      let len_local = alloc_temp_local(ctx)
      let cap_local = alloc_temp_local(ctx)
      let data_local = alloc_temp_local(ctx)
      let add_local = alloc_temp_local(ctx)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, ptr_local)
      emit_bytes_ensure_mutable(
        ctx, buf, ptr_local, len_local, cap_local, data_local,
      )
      emit_i32_const_raw(buf, 1)
      emit_local_set(buf, add_local)
      emit_bytes_raw_ensure_capacity(
        ctx, buf, ptr_local, len_local, add_local, cap_local, data_local,
      )
      emit_local_get(buf, data_local)
      emit_local_get(buf, len_local)
      emit_i32_add(buf)
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_i32_wrap_i64(buf)
      emit_i32_const_raw(buf, 2)
      emit_i32_shr_u(buf) // untag byte value
      emit_i32_store8(buf, 0) // store byte at [data_ptr + len]
      emit_local_get(buf, ptr_local)
      emit_local_get(buf, len_local)
      emit_i32_const_raw(buf, 1)
      emit_i32_add(buf)
      emit_i32_store(buf, 4) // len++
      emit_i64_const_tagged(buf, 0L) // return Unit
    }
    "Bytes::set" => {
      // Bytes::set(bytes, idx, val) -> overwrite one packed byte
      let pos_args = extract_positional_exprs_with_arity(args, "Bytes::set", 3)
      let ptr_local = alloc_temp_local(ctx)
      let len_local = alloc_temp_local(ctx)
      let cap_local = alloc_temp_local(ctx)
      let data_local = alloc_temp_local(ctx)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, ptr_local)
      emit_bytes_ensure_mutable(
        ctx, buf, ptr_local, len_local, cap_local, data_local,
      )
      emit_local_get(buf, data_local)
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_i64_const_raw(buf, 2L)
      emit_i64_shr_s(buf) // untag index
      emit_i32_wrap_i64(buf)
      emit_i32_add(buf)
      compile_expr_i32(ctx, buf, pos_args[2])
      emit_i32_wrap_i64(buf)
      emit_i32_const_raw(buf, 2)
      emit_i32_shr_u(buf) // untag byte value
      emit_i32_store8(buf, 0) // store byte at [data_ptr + idx]
      emit_i64_const_tagged(buf, 0L) // return Unit
    }
    "Bytes::append" => {
      // Bytes::append(dst, src) -> append all bytes from src to dst (mutating)
      // Uses memory.copy for efficiency
      let pos_args = extract_positional_exprs_with_arity(
        args, "Bytes::append", 2,
      )
      require_heap(ctx)
      let dst_local = alloc_temp_local(ctx)
      let src_local = alloc_temp_local(ctx)
      let dst_len_local = alloc_temp_local(ctx)
      let dst_cap_local = alloc_temp_local(ctx)
      let dst_data_local = alloc_temp_local(ctx)
      let src_len_local = alloc_temp_local(ctx)
      let src_data_local = alloc_temp_local(ctx)
      // dst ptr
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, dst_local)
      emit_bytes_ensure_mutable(
        ctx, buf, dst_local, dst_len_local, dst_cap_local, dst_data_local,
      )
      // src ptr
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, src_local)
      let src_cap_local = alloc_temp_local(ctx)
      emit_bytes_load_header(
        ctx, buf, src_local, src_len_local, src_cap_local, src_data_local,
      )
      emit_bytes_raw_ensure_capacity(
        ctx, buf, dst_local, dst_len_local, src_len_local, dst_cap_local, dst_data_local,
      )
      // memory.copy(dst_data + dst_len, src_data, src_len)
      emit_local_get(buf, dst_data_local)
      emit_local_get(buf, dst_len_local)
      emit_i32_add(buf)
      emit_local_get(buf, src_data_local)
      emit_local_get(buf, src_len_local) // size = src_len
      emit_memory_copy(buf)
      // Update dst length: dst_len + src_len
      emit_local_get(buf, dst_local)
      emit_local_get(buf, dst_len_local)
      emit_local_get(buf, src_len_local)
      emit_i32_add(buf)
      emit_i32_store(buf, 4)
      emit_i64_const_tagged(buf, 0L) // return Unit
    }
    "Bytes::blit" => {
      // Bytes::blit(dst, src, start, end) -> append src[start..end] to dst (mutating)
      let pos_args = extract_positional_exprs_with_arity(args, "Bytes::blit", 4)
      require_heap(ctx)
      let dst_local = alloc_temp_local(ctx)
      let src_local = alloc_temp_local(ctx)
      let start_local = alloc_temp_local(ctx)
      let copy_len_local = alloc_temp_local(ctx)
      let dst_len_local = alloc_temp_local(ctx)
      let dst_cap_local = alloc_temp_local(ctx)
      let dst_data_local = alloc_temp_local(ctx)
      let src_data_local = alloc_temp_local(ctx)
      // dst ptr
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, dst_local)
      emit_bytes_ensure_mutable(
        ctx, buf, dst_local, dst_len_local, dst_cap_local, dst_data_local,
      )
      // src ptr
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, src_local)
      let src_len_local = alloc_temp_local(ctx)
      let src_cap_local = alloc_temp_local(ctx)
      emit_bytes_load_header(
        ctx, buf, src_local, src_len_local, src_cap_local, src_data_local,
      )
      // start (untag)
      compile_expr_i32(ctx, buf, pos_args[2])
      emit_untag_int_i32(buf)
      emit_local_set(buf, start_local)
      // copy_len = end - start (untag end)
      compile_expr_i32(ctx, buf, pos_args[3])
      emit_untag_int_i32(buf)
      emit_local_get(buf, start_local)
      emit_i32_sub(buf)
      emit_local_set(buf, copy_len_local)
      emit_bytes_raw_ensure_capacity(
        ctx, buf, dst_local, dst_len_local, copy_len_local, dst_cap_local, dst_data_local,
      )
      // memory.copy(dst_data + dst_len, src_data + start, copy_len)
      emit_local_get(buf, dst_data_local)
      emit_local_get(buf, dst_len_local)
      emit_i32_add(buf)
      emit_local_get(buf, src_data_local)
      emit_local_get(buf, start_local)
      emit_i32_add(buf)
      emit_local_get(buf, copy_len_local)
      emit_memory_copy(buf)
      // Update dst length
      emit_local_get(buf, dst_local)
      emit_local_get(buf, dst_len_local)
      emit_local_get(buf, copy_len_local)
      emit_i32_add(buf)
      emit_i32_store(buf, 4)
      emit_i64_const_tagged(buf, 0L)
    }
    "Bytes::fill" => {
      // Bytes::fill(bytes, value, count) -> push value count times (mutating)
      // Uses memory.fill for efficiency
      let pos_args = extract_positional_exprs_with_arity(args, "Bytes::fill", 3)
      require_heap(ctx)
      let ptr_local = alloc_temp_local(ctx)
      let len_local = alloc_temp_local(ctx)
      let count_local = alloc_temp_local(ctx)
      let cap_local = alloc_temp_local(ctx)
      let data_local = alloc_temp_local(ctx)
      // ptr
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, ptr_local)
      emit_bytes_ensure_mutable(
        ctx, buf, ptr_local, len_local, cap_local, data_local,
      )
      // count (untag)
      compile_expr_i32(ctx, buf, pos_args[2])
      emit_untag_int_i32(buf)
      emit_local_set(buf, count_local)
      emit_bytes_raw_ensure_capacity(
        ctx, buf, ptr_local, len_local, count_local, cap_local, data_local,
      )
      // memory.fill(data_ptr + len, value, count)
      emit_local_get(buf, data_local)
      emit_local_get(buf, len_local)
      emit_i32_add(buf) // dst addr
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_i32_wrap_i64(buf)
      emit_i32_const_raw(buf, 2)
      emit_i32_shr_u(buf) // untag value
      emit_local_get(buf, count_local) // count
      emit_memory_fill(buf)
      // Update length: len + count
      emit_local_get(buf, ptr_local)
      emit_local_get(buf, len_local)
      emit_local_get(buf, count_local)
      emit_i32_add(buf)
      emit_i32_store(buf, 4)
      emit_i64_const_tagged(buf, 0L)
    }
    "Bytes::slice" => {
      // Bytes::slice(bytes, start, end) -> zero-copy BytesView.
      let pos_args = extract_positional_exprs_with_arity(
        args, "Bytes::slice", 3,
      )
      require_heap(ctx)
      let src_local = alloc_temp_local(ctx)
      let start_local = alloc_temp_local(ctx)
      let end_local = alloc_temp_local(ctx)
      let obj_local = alloc_temp_local(ctx)
      let source_local = alloc_temp_local(ctx)
      // src ptr
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, src_local)
      // start index (untag)
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_untag_int_i32(buf)
      emit_local_set(buf, start_local)
      // end index (untag)
      compile_expr_i32(ctx, buf, pos_args[2])
      emit_untag_int_i32(buf)
      emit_local_set(buf, end_local)
      emit_heap_alloc(ctx, buf, 16, obj_local)
      let src_ty_local = alloc_temp_local(ctx)
      emit_local_get(buf, src_local)
      emit_i32_load(buf, 0)
      emit_local_set(buf, src_ty_local)
      // Flatten nested views: if src is a view, rebase start/end onto the
      // ultimate source.  Otherwise source_local = src_local directly.
      emit_local_get(buf, src_ty_local)
      emit_i32_const_raw(buf, obj_bytes_view)
      emit_i32_eq(buf)
      buf.push((4).to_byte()) // if
      buf.push((64).to_byte()) // void
      let base_start_local = alloc_temp_local(ctx)
      emit_local_get(buf, src_local)
      emit_i32_load(buf, 4)
      emit_local_set(buf, source_local)
      emit_local_get(buf, src_local)
      emit_i32_load(buf, 8)
      emit_local_set(buf, base_start_local)
      emit_local_get(buf, base_start_local)
      emit_local_get(buf, start_local)
      emit_i32_add(buf)
      emit_local_set(buf, start_local)
      emit_local_get(buf, base_start_local)
      emit_local_get(buf, end_local)
      emit_i32_add(buf)
      emit_local_set(buf, end_local)
      buf.push((5).to_byte()) // else
      emit_local_get(buf, src_local)
      emit_local_set(buf, source_local)
      buf.push((11).to_byte()) // end if
      // Mark the ultimate source as shared (frozen) so mutations trigger COW.
      emit_bytes_raw_mark_shared(ctx, buf, source_local)
      emit_local_get(buf, obj_local)
      emit_i32_const_raw(buf, obj_bytes_view)
      emit_i32_store(buf, 0)
      emit_local_get(buf, obj_local)
      emit_local_get(buf, source_local)
      emit_i32_store(buf, 4)
      emit_local_get(buf, obj_local)
      emit_local_get(buf, start_local)
      emit_i32_store(buf, 8)
      emit_local_get(buf, obj_local)
      emit_local_get(buf, end_local)
      emit_i32_store(buf, 12)
      // Return tagged obj
      emit_local_get(buf, obj_local)
      emit_i64_extend_i32_u(buf)
      emit_i64_const_raw(buf, tag_obj.to_int64())
      emit_i64_or(buf)
    }
    "Bytes::concat" => {
      // Bytes::concat(a, b) -> new array with a's elements followed by b's
      let pos_args = extract_positional_exprs_with_arity(
        args, "Bytes::concat", 2,
      )
      require_heap(ctx)
      let a_local = alloc_temp_local(ctx)
      let b_local = alloc_temp_local(ctx)
      let a_len_local = alloc_temp_local(ctx)
      let b_len_local = alloc_temp_local(ctx)
      let a_cap_local = alloc_temp_local(ctx)
      let b_cap_local = alloc_temp_local(ctx)
      let a_data_local = alloc_temp_local(ctx)
      let b_data_local = alloc_temp_local(ctx)
      let cap_local = alloc_temp_local(ctx)
      let obj_local = alloc_temp_local(ctx)
      let data_local = alloc_temp_local(ctx)
      // a ptr + len
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, a_local)
      emit_bytes_load_header(
        ctx, buf, a_local, a_len_local, a_cap_local, a_data_local,
      )
      // b ptr + len
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, b_local)
      emit_bytes_load_header(
        ctx, buf, b_local, b_len_local, b_cap_local, b_data_local,
      )
      // total_len = a_len + b_len
      let total_len_local = alloc_temp_local(ctx)
      emit_local_get(buf, a_len_local)
      emit_local_get(buf, b_len_local)
      emit_i32_add(buf)
      emit_local_set(buf, total_len_local)
      emit_local_get(buf, total_len_local)
      emit_local_set(buf, cap_local)
      emit_bytes_raw_alloc_with_cap_local(
        ctx, buf, total_len_local, cap_local, obj_local, data_local,
      )
      // Copy a: memory.copy(data, a_data, a_len)
      emit_local_get(buf, data_local)
      emit_local_get(buf, a_data_local)
      emit_local_get(buf, a_len_local)
      emit_memory_copy(buf)
      // Copy b: memory.copy(data + a_len, b_data, b_len)
      emit_local_get(buf, data_local)
      emit_local_get(buf, a_len_local)
      emit_i32_add(buf)
      emit_local_get(buf, b_data_local)
      emit_local_get(buf, b_len_local)
      emit_memory_copy(buf)
      // Return tagged obj
      emit_local_get(buf, obj_local)
      emit_i64_extend_i32_u(buf)
      emit_i64_const_raw(buf, tag_obj.to_int64())
      emit_i64_or(buf)
    }
    "Bytes::to_array" => {
      // Bytes::to_array(bytes) -> Array[Int] (unpack: load8_u, <<2, store i32)
      let pos_args = extract_positional_exprs_with_arity(
        args, "Bytes::to_array", 1,
      )
      require_heap(ctx)
      let src_local = alloc_temp_local(ctx)
      let len_local = alloc_temp_local(ctx)
      let cap_local = alloc_temp_local(ctx)
      let data_local = alloc_temp_local(ctx)
      let dst_local = alloc_temp_local(ctx)
      let idx_local = alloc_temp_local(ctx)
      // Get source bytes ptr and length
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, src_local)
      emit_bytes_load_header(
        ctx, buf, src_local, len_local, cap_local, data_local,
      )
      // Alloc array: align4(8 + len*4)
      emit_local_get(buf, len_local)
      emit_i32_const_raw(buf, 4)
      emit_i32_mul(buf)
      emit_i32_const_raw(buf, 8)
      emit_i32_add(buf)
      emit_i32_const_raw(buf, 3)
      emit_i32_add(buf)
      emit_i32_const_raw(buf, -4)
      emit_i32_and(buf)
      let alloc_size_local = alloc_temp_local(ctx)
      emit_local_set(buf, alloc_size_local)
      emit_global_get(buf, ctx.heap_global)
      emit_local_tee(buf, dst_local)
      emit_local_get(buf, alloc_size_local)
      emit_i32_add(buf)
      emit_global_set(buf, ctx.heap_global)
      ctx.heap_synced = false
      // header: obj_array (target Array), len
      emit_local_get(buf, dst_local)
      emit_i32_const_raw(buf, obj_array)
      emit_i32_store(buf, 0)
      emit_local_get(buf, dst_local)
      emit_local_get(buf, len_local)
      emit_i32_store(buf, 4)
      // Loop: load8_u from src[8+idx], <<2, store i32 to dst[8+idx*4]
      emit_i32_const_raw(buf, 0)
      emit_local_set(buf, idx_local)
      emit_block(buf)
      emit_loop(buf)
      emit_local_get(buf, idx_local)
      emit_local_get(buf, len_local)
      emit_i32_ge_s(buf)
      emit_br_if(buf, 1)
      // dst[8+idx*4] = (data[idx] as u8) << 2
      emit_local_get(buf, dst_local)
      emit_local_get(buf, idx_local)
      emit_i32_const_raw(buf, 4)
      emit_i32_mul(buf)
      emit_i32_add(buf)
      emit_local_get(buf, data_local)
      emit_local_get(buf, idx_local)
      emit_i32_add(buf)
      emit_i32_load8_u(buf, 0) // load byte
      emit_i32_const_raw(buf, 2)
      emit_i32_shl(buf) // tag as int
      emit_i32_store(buf, 8) // store tagged int to array
      emit_local_get(buf, idx_local)
      emit_i32_const_raw(buf, 1)
      emit_i32_add(buf)
      emit_local_set(buf, idx_local)
      emit_br(buf, 0)
      emit_end(buf)
      emit_end(buf)
      // Return tagged obj
      emit_local_get(buf, dst_local)
      emit_i64_extend_i32_u(buf)
      emit_i64_const_raw(buf, tag_obj.to_int64())
      emit_i64_or(buf)
    }
    "Fs::write_bytes" => {
      // fs_write_bytes(path, bytes) -> Unit
      // Accept both raw Bytes and BytesView payloads.
      if ctx.use_js_strings {
        raise WasmGenError::Unsupported(
          "Fs::write_bytes requires --wasm backend",
        )
      }
      if ctx.fs_host_imports {
        let pos_args = extract_positional_exprs_with_arity(
          args, "Fs::write_bytes", 2,
        )
        compile_expr(ctx, buf, pos_args[0])
        compile_expr(ctx, buf, pos_args[1])
        emit_call(buf, import_index_fs_host_write_bytes(ctx))
      } else {
      let pos_args = extract_positional_exprs_with_arity(
        args, "Fs::write_bytes", 2,
      )
      require_heap(ctx)
      let path_raw_local = alloc_temp_local(ctx)
      let path_len_local = alloc_temp_local(ctx)
      let bytes_ptr_local = alloc_temp_local(ctx)
      let bytes_len_local = alloc_temp_local(ctx)
      let bytes_cap_local = alloc_temp_local(ctx)
      let data_size_local = alloc_temp_local(ctx)
      let data_ptr_local = alloc_temp_local(ctx)
      let ret_area_local = alloc_temp_local(ctx)
      let root_desc_local = alloc_temp_local(ctx)
      let opened_desc_local = alloc_temp_local(ctx)
      let _idx_local = alloc_temp_local(ctx) // reserved (packed bytes removed conversion loop)
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
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, path_raw_local)
      emit_local_get(buf, path_raw_local)
      emit_i32_load(buf, 4)
      emit_local_set(buf, path_len_local)
      // Resolve bytes header so raw Bytes and BytesView share one path.
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, bytes_ptr_local)
      emit_bytes_load_header(
        ctx, buf, bytes_ptr_local, bytes_len_local, bytes_cap_local, data_ptr_local,
      )
      emit_local_get(buf, bytes_len_local)
      emit_local_set(buf, data_size_local)
      // Allocate retptr for open-at result
      emit_heap_alloc(ctx, buf, align4(16), ret_area_local)
      // Sync heap
      emit_heap_pre_call_sync(ctx, buf)
      // open-at(root_desc, 0, path_ptr, path_len, 5, 2, retptr)
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
      emit_heap_post_call_sync(ctx, buf)
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
      emit_heap_pre_call_sync(ctx, buf)
      // write(opened_desc, data_ptr, bytes_len, offset=0, retptr)
      emit_local_get(buf, opened_desc_local)
      emit_local_get(buf, data_ptr_local)
      emit_local_get(buf, data_size_local)
      // i64.const 0 (offset)
      buf.push((66).to_byte())
      buf.push((0).to_byte())
      emit_local_get(buf, ret_area_local)
      emit_call(buf, import_index_fs_write(ctx))
      // Reload heap
      emit_heap_post_call_sync(ctx, buf)
      // resource-drop opened descriptor
      emit_local_get(buf, opened_desc_local)
      emit_call(buf, import_index_fs_resource_drop(ctx))
      // Return Unit
      emit_i64_const_raw(buf, tag_int_value64(0L))
      buf.push((5).to_byte()) // else (open error)
      emit_i64_const_raw(buf, tag_int_value64(0L))
      buf.push((11).to_byte()) // end if
      } // end else (WASI path)
    }
    "Socket::tcp_connect" => {
      if ctx.use_js_strings {
        raise WasmGenError::Unsupported(
          "Socket::tcp_connect requires --wasm backend",
        )
      }
      let pos_args = extract_positional_exprs_with_arity(
        args, "Socket::tcp_connect", 2,
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
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, host_raw_local)
      emit_local_get(buf, host_raw_local)
      emit_i32_load(buf, 4) // len
      emit_local_set(buf, host_len_local)
      // Extract port (untag)
      compile_expr(ctx, buf, pos_args[1])
      emit_untag_int_i32(buf)
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
      emit_heap_pre_call_sync(ctx, buf)
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
      emit_heap_post_call_sync(ctx, buf)
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
    "Socket::tcp_read" => {
      if ctx.use_js_strings {
        raise WasmGenError::Unsupported(
          "Socket::tcp_read requires --wasm backend",
        )
      }
      let pos_args = extract_positional_exprs_with_arity(
        args, "Socket::tcp_read", 2,
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
      emit_untag_int_i32(buf)
      emit_local_set(buf, handle_local)
      // Extract max_bytes (untag)
      compile_expr(ctx, buf, pos_args[1])
      emit_untag_int_i32(buf)
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
      emit_heap_pre_call_sync(ctx, buf)
      // blocking-read(input_stream, max_bytes as i64, retptr)
      emit_local_get(buf, input_stream_local)
      emit_local_get(buf, max_bytes_local)
      emit_i64_extend_i32_u(buf) // convert to i64
      emit_local_get(buf, ret_area_local)
      emit_call(buf, import_index_socket_stream_read(ctx))
      // Reload heap
      emit_heap_post_call_sync(ctx, buf)
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
    "Socket::tcp_write" => {
      if ctx.use_js_strings {
        raise WasmGenError::Unsupported(
          "Socket::tcp_write requires --wasm backend",
        )
      }
      let pos_args = extract_positional_exprs_with_arity(
        args, "Socket::tcp_write", 2,
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
      emit_untag_int_i32(buf)
      emit_local_set(buf, handle_local)
      // Extract data string
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_untag_ptr_i32(buf)
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
      emit_heap_pre_call_sync(ctx, buf)
      // blocking-write-and-flush(output_stream, data_ptr+8, data_len, retptr)
      emit_local_get(buf, output_stream_local)
      emit_local_get(buf, data_raw_local)
      emit_i32_const_raw(buf, 8)
      emit_i32_add(buf) // data ptr
      emit_local_get(buf, data_len_local)
      emit_local_get(buf, ret_area_local)
      emit_call(buf, import_index_socket_stream_write(ctx))
      // Reload heap
      emit_heap_post_call_sync(ctx, buf)
      // Return Unit (tagged 0)
      emit_i64_const_raw(buf, tag_int_value64(0L))
    }
    "Socket::tcp_close" => {
      if ctx.use_js_strings {
        raise WasmGenError::Unsupported(
          "Socket::tcp_close requires --wasm backend",
        )
      }
      let pos_args = extract_positional_exprs_with_arity(
        args, "Socket::tcp_close", 1,
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
      emit_untag_int_i32(buf)
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
    | "Http::respond" =>
      if ctx.need_http && ctx.http_host_imports {
        if ctx.use_js_strings {
          raise WasmGenError::Unsupported(
            "http host imports require --wasm backend",
          )
        }
        match name {
          "Http::request" => {
            let pos_args = extract_positional_exprs_with_arity(
              args, "Http::request", 4,
            )
            compile_expr(ctx, buf, pos_args[0])
            compile_expr(ctx, buf, pos_args[1])
            compile_expr(ctx, buf, pos_args[2])
            compile_expr(ctx, buf, pos_args[3])
            emit_call(buf, import_index_http_request(ctx))
          }
          "Http::response_status" => {
            let pos_args = extract_positional_exprs_with_arity(
              args, "Http::response_status", 1,
            )
            compile_expr(ctx, buf, pos_args[0])
            emit_call(buf, import_index_http_response_status(ctx))
          }
          "Http::response_header" => {
            let pos_args = extract_positional_exprs_with_arity(
              args, "Http::response_header", 2,
            )
            compile_expr(ctx, buf, pos_args[0])
            compile_expr(ctx, buf, pos_args[1])
            emit_call(buf, import_index_http_response_header(ctx))
          }
          "Http::response_body" => {
            let pos_args = extract_positional_exprs_with_arity(
              args, "Http::response_body", 1,
            )
            compile_expr(ctx, buf, pos_args[0])
            emit_call(buf, import_index_http_response_body(ctx))
          }
          "Http::close" => {
            let pos_args = extract_positional_exprs_with_arity(
              args, "Http::close", 1,
            )
            compile_expr(ctx, buf, pos_args[0])
            emit_call(buf, import_index_http_close(ctx))
            buf.push((26).to_byte()) // drop host return
            emit_i64_const_raw(buf, tag_int_value64(0L))
          }
          "Http::listen" => {
            let pos_args = extract_positional_exprs_with_arity(
              args, "Http::listen", 1,
            )
            compile_expr(ctx, buf, pos_args[0])
            emit_call(buf, import_index_http_listen(ctx))
          }
          "Http::accept" => {
            let pos_args = extract_positional_exprs_with_arity(
              args, "Http::accept", 1,
            )
            compile_expr(ctx, buf, pos_args[0])
            emit_call(buf, import_index_http_accept(ctx))
          }
          "Http::request_method" => {
            let pos_args = extract_positional_exprs_with_arity(
              args, "Http::request_method", 1,
            )
            compile_expr(ctx, buf, pos_args[0])
            emit_call(buf, import_index_http_request_method(ctx))
          }
          "Http::request_url" => {
            let pos_args = extract_positional_exprs_with_arity(
              args, "Http::request_url", 1,
            )
            compile_expr(ctx, buf, pos_args[0])
            emit_call(buf, import_index_http_request_url(ctx))
          }
          "Http::request_header" => {
            let pos_args = extract_positional_exprs_with_arity(
              args, "Http::request_header", 2,
            )
            compile_expr(ctx, buf, pos_args[0])
            compile_expr(ctx, buf, pos_args[1])
            emit_call(buf, import_index_http_request_header(ctx))
          }
          "Http::request_body" => {
            let pos_args = extract_positional_exprs_with_arity(
              args, "Http::request_body", 1,
            )
            compile_expr(ctx, buf, pos_args[0])
            emit_call(buf, import_index_http_request_body(ctx))
          }
          "Http::respond" => {
            let pos_args = extract_positional_exprs_with_arity(
              args, "Http::respond", 4,
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
    "Char::to_int" => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "Char::to_int", 1,
      )
      compile_expr(ctx, buf, pos_args[0])
    }
    "Char::from_int" => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "Char::from_int", 1,
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
    "String::from_char_code" => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "String::from_char_code", 1,
      )
      require_heap(ctx)
      let raw_local = alloc_temp_local(ctx)
      let code_local = alloc_temp_local(ctx)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_int_i32(buf)
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
    // Fs builtins that only have host import codegen (no WASI path)
    "Fs::readdir" if ctx.fs_host_imports => {
      let pos_args = extract_positional_exprs_with_arity(args, "Fs::readdir", 1)
      compile_expr(ctx, buf, pos_args[0])
      emit_call(buf, import_index_fs_host_readdir(ctx))
    }
    "Fs::getcwd" if ctx.fs_host_imports => {
      let _ = extract_positional_exprs_with_arity(args, "Fs::getcwd", 0)
      emit_call(buf, import_index_fs_host_getcwd(ctx))
    }
    "Fs::chdir" if ctx.fs_host_imports => {
      let pos_args = extract_positional_exprs_with_arity(args, "Fs::chdir", 1)
      compile_expr(ctx, buf, pos_args[0])
      emit_call(buf, import_index_fs_host_chdir(ctx))
    }
    "Fs::is_dir" if ctx.fs_host_imports => {
      let pos_args = extract_positional_exprs_with_arity(args, "Fs::is_dir", 1)
      compile_expr(ctx, buf, pos_args[0])
      emit_call(buf, import_index_fs_host_is_dir(ctx))
    }
    "Fs::is_file" if ctx.fs_host_imports => {
      let pos_args = extract_positional_exprs_with_arity(args, "Fs::is_file", 1)
      compile_expr(ctx, buf, pos_args[0])
      emit_call(buf, import_index_fs_host_is_file(ctx))
    }
    "Fs::mkdir" if ctx.fs_host_imports => {
      let pos_args = extract_positional_exprs_with_arity(args, "Fs::mkdir", 1)
      compile_expr(ctx, buf, pos_args[0])
      emit_call(buf, import_index_fs_host_mkdir(ctx))
    }
    "Fs::mkdir_p" if ctx.fs_host_imports => {
      let pos_args = extract_positional_exprs_with_arity(args, "Fs::mkdir_p", 1)
      compile_expr(ctx, buf, pos_args[0])
      emit_call(buf, import_index_fs_host_mkdir_p(ctx))
    }
    "Fs::remove" if ctx.fs_host_imports => {
      let pos_args = extract_positional_exprs_with_arity(args, "Fs::remove", 1)
      compile_expr(ctx, buf, pos_args[0])
      emit_call(buf, import_index_fs_host_remove(ctx))
    }
    "Fs::rename" if ctx.fs_host_imports => {
      let pos_args = extract_positional_exprs_with_arity(args, "Fs::rename", 2)
      compile_expr(ctx, buf, pos_args[0])
      compile_expr(ctx, buf, pos_args[1])
      emit_call(buf, import_index_fs_host_rename(ctx))
    }
    "Fs::copy" if ctx.fs_host_imports => {
      let pos_args = extract_positional_exprs_with_arity(args, "Fs::copy", 2)
      compile_expr(ctx, buf, pos_args[0])
      compile_expr(ctx, buf, pos_args[1])
      emit_call(buf, import_index_fs_host_copy(ctx))
    }
    "Fs::append" if ctx.fs_host_imports => {
      let pos_args = extract_positional_exprs_with_arity(args, "Fs::append", 2)
      compile_expr(ctx, buf, pos_args[0])
      compile_expr(ctx, buf, pos_args[1])
      emit_call(buf, import_index_fs_host_append(ctx))
    }
    _ if not(is_user_fn) && is_wasm_runtime_fallback_builtin(name) =>
      emit_wasm_runtime_fallback_throw(ctx, buf, name)
    _ => raise WasmGenError::Unsupported(pre_user_builtin_unhandled_marker)
  }
}

///|
/// Emit WASM for string_replace / string_replace_all.
/// Two-pass: 1) count matches, 2) build result with replacements.
/// Uses `if/end` for conditionals (same pattern as string_contains).
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
  let inner_j = alloc_temp_local(ctx)
  let new_len = alloc_temp_local(ctx)
  let new_ptr = alloc_temp_local(ctx)
  let src_i = alloc_temp_local(ctx)
  let dst_i = alloc_temp_local(ctx)
  let copy_j = alloc_temp_local(ctx)
  let matched = alloc_temp_local(ctx)
  let limit_local = alloc_temp_local(ctx)
  // Untag source string
  compile_expr_i32(ctx, buf, pos_args[0])
  emit_untag_ptr_i32(buf)
  emit_local_set(buf, str_ptr)
  emit_local_get(buf, str_ptr)
  emit_i32_load(buf, 4)
  emit_local_set(buf, str_len)
  // Untag pattern string
  compile_expr_i32(ctx, buf, pos_args[1])
  emit_untag_ptr_i32(buf)
  emit_local_set(buf, pat_ptr)
  emit_local_get(buf, pat_ptr)
  emit_i32_load(buf, 4)
  emit_local_set(buf, pat_len)
  // Untag replacement string
  compile_expr_i32(ctx, buf, pos_args[2])
  emit_untag_ptr_i32(buf)
  emit_local_set(buf, rep_ptr)
  emit_local_get(buf, rep_ptr)
  emit_i32_load(buf, 4)
  emit_local_set(buf, rep_len)
  // --- Pass 1: Count matches (same structure as string_contains) ---
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, match_count)
  // Only search if pat_len > 0
  emit_local_get(buf, pat_len)
  emit_i32_const_raw(buf, 0)
  emit_i32_gt_s(buf)
  emit_if(buf) // if pat_len > 0
  // limit = str_len - pat_len + 1
  emit_local_get(buf, str_len)
  emit_local_get(buf, pat_len)
  emit_i32_sub(buf)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, limit_local)
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, scan_i)
  emit_block(buf) // block $count_break
  emit_loop(buf) // loop $count_loop
  // if scan_i >= limit, break
  emit_local_get(buf, scan_i)
  emit_local_get(buf, limit_local)
  emit_i32_lt_s(buf)
  emit_i32_eqz(buf)
  emit_br_if(buf, 1) // break $count_break
  // Check if pattern matches at scan_i
  emit_i32_const_raw(buf, 1)
  emit_local_set(buf, matched)
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, inner_j)
  emit_block(buf) // block $cmp_done
  emit_loop(buf) // loop $cmp_loop
  emit_local_get(buf, inner_j)
  emit_local_get(buf, pat_len)
  emit_i32_lt_s(buf)
  emit_i32_eqz(buf)
  emit_br_if(buf, 1) // break if j >= pat_len (all matched)
  // Compare str[scan_i + inner_j + 8] vs pat[inner_j + 8]
  emit_local_get(buf, str_ptr)
  emit_local_get(buf, scan_i)
  emit_i32_add(buf)
  emit_local_get(buf, inner_j)
  emit_i32_add(buf)
  emit_i32_load8_u(buf, 8)
  emit_local_get(buf, pat_ptr)
  emit_local_get(buf, inner_j)
  emit_i32_add(buf)
  emit_i32_load8_u(buf, 8)
  emit_i32_eq(buf)
  emit_i32_eqz(buf) // not equal?
  emit_if(buf) // if not equal
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, matched)
  emit_br(buf, 2) // break $cmp_done
  emit_end(buf) // end if
  emit_local_get(buf, inner_j)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, inner_j)
  emit_br(buf, 0) // continue $cmp_loop
  emit_end(buf) // end $cmp_loop
  emit_end(buf) // end $cmp_done
  // If matched, count++ and maybe break
  emit_local_get(buf, matched)
  emit_if(buf) // if matched
  emit_local_get(buf, match_count)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, match_count)
  if not(replace_all) {
    emit_br(buf, 2) // break $count_break
  } else {
    // Advance by pat_len to avoid overlapping
    emit_local_get(buf, scan_i)
    emit_local_get(buf, pat_len)
    emit_i32_add(buf)
    emit_local_set(buf, scan_i)
    emit_br(buf, 1) // continue $count_loop
  }
  emit_end(buf) // end if matched
  // Not matched: scan_i++
  emit_local_get(buf, scan_i)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, scan_i)
  emit_br(buf, 0) // continue $count_loop
  emit_end(buf) // end $count_loop
  emit_end(buf) // end $count_break
  emit_end(buf) // end if pat_len > 0
  // --- Compute result length ---
  emit_local_get(buf, str_len)
  emit_local_get(buf, match_count)
  emit_local_get(buf, rep_len)
  emit_local_get(buf, pat_len)
  emit_i32_sub(buf)
  emit_i32_mul(buf)
  emit_i32_add(buf)
  emit_local_set(buf, new_len)
  // --- Allocate new string ---
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
  // --- Pass 2: Build result ---
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, src_i)
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, dst_i)
  emit_block(buf) // block $build_done
  emit_loop(buf) // loop $build_loop
  emit_local_get(buf, src_i)
  emit_local_get(buf, str_len)
  emit_i32_ge_s(buf)
  emit_br_if(buf, 1) // break if src_i >= str_len
  // Try to match pattern at src_i
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, matched)
  // Guard: pat_len > 0
  emit_local_get(buf, pat_len)
  emit_i32_const_raw(buf, 0)
  emit_i32_gt_s(buf)
  emit_if(buf) // if pat_len > 0
  // Guard: src_i + pat_len <= str_len
  emit_local_get(buf, src_i)
  emit_local_get(buf, pat_len)
  emit_i32_add(buf)
  emit_local_get(buf, str_len)
  emit_i32_le_s(buf)
  emit_if(buf) // if src_i + pat_len <= str_len
  // Compare pattern (same inner loop as pass 1)
  emit_i32_const_raw(buf, 1)
  emit_local_set(buf, matched)
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, inner_j)
  emit_block(buf) // block $cmp2_done
  emit_loop(buf) // loop $cmp2_loop
  emit_local_get(buf, inner_j)
  emit_local_get(buf, pat_len)
  emit_i32_lt_s(buf)
  emit_i32_eqz(buf)
  emit_br_if(buf, 1) // break if j >= pat_len
  emit_local_get(buf, str_ptr)
  emit_local_get(buf, src_i)
  emit_i32_add(buf)
  emit_local_get(buf, inner_j)
  emit_i32_add(buf)
  emit_i32_load8_u(buf, 8)
  emit_local_get(buf, pat_ptr)
  emit_local_get(buf, inner_j)
  emit_i32_add(buf)
  emit_i32_load8_u(buf, 8)
  emit_i32_eq(buf)
  emit_i32_eqz(buf)
  emit_if(buf) // if not equal
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, matched)
  emit_br(buf, 2) // break $cmp2_done
  emit_end(buf) // end if
  emit_local_get(buf, inner_j)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, inner_j)
  emit_br(buf, 0) // continue $cmp2_loop
  emit_end(buf) // end $cmp2_loop
  emit_end(buf) // end $cmp2_done
  emit_end(buf) // end if src_i + pat_len <= str_len
  emit_end(buf) // end if pat_len > 0
  // Handle match or copy byte
  emit_local_get(buf, matched)
  emit_if(buf) // if matched
  // Copy replacement bytes
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, copy_j)
  emit_block(buf) // block $rep_done
  emit_loop(buf) // loop $rep_loop
  emit_local_get(buf, copy_j)
  emit_local_get(buf, rep_len)
  emit_i32_ge_s(buf)
  emit_br_if(buf, 1) // done
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
  emit_br(buf, 0) // continue $rep_loop
  emit_end(buf) // end $rep_loop
  emit_end(buf) // end $rep_done
  // Advance src by pat_len
  emit_local_get(buf, src_i)
  emit_local_get(buf, pat_len)
  emit_i32_add(buf)
  emit_local_set(buf, src_i)
  if not(replace_all) {
    // Copy remaining bytes directly, then break
    emit_block(buf) // block $rest_done
    emit_loop(buf) // loop $rest_loop
    emit_local_get(buf, src_i)
    emit_local_get(buf, str_len)
    emit_i32_ge_s(buf)
    emit_br_if(buf, 1)
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
    emit_br(buf, 0)
    emit_end(buf) // end $rest_loop
    emit_end(buf) // end $rest_done
    emit_br(buf, 2) // break $build_done
  }
  emit_br(buf, 1) // continue $build_loop
  emit_else(buf) // else (not matched)
  // Copy single byte
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
  emit_end(buf) // end if/else matched
  emit_br(buf, 0) // continue $build_loop
  emit_end(buf) // end $build_loop
  emit_end(buf) // end $build_done
  // Tag result
  emit_local_get(buf, new_ptr)
  emit_i64_extend_i32_u(buf)
  emit_i64_const_raw(buf, tag_obj.to_int64())
  emit_i64_or(buf)
}

///|
/// Helper: allocate a substring of `sub_len` bytes starting at `seg_start`
/// from `str_ptr`, and push the tagged pointer into the array at `arr_ptr`.
/// Increments `arr_len`.
fn emit_alloc_substr_push(
  ctx : CodegenCtx,
  buf : ByteBuf,
  str_ptr : Int,
  seg_start : Int,
  sub_len : Int,
  arr_ptr : Int,
  arr_len : Int,
  sub_ptr : Int,
  copy_j : Int,
  obj_size_local : Int,
) -> Unit {
  // Compute aligned size: align4(8 + sub_len)
  emit_local_get(buf, sub_len)
  emit_i32_const_raw(buf, 8)
  emit_i32_add(buf)
  emit_local_set(buf, obj_size_local)
  emit_local_get(buf, obj_size_local)
  emit_i32_const_raw(buf, 3)
  emit_i32_add(buf)
  emit_i32_const_raw(buf, -4)
  emit_i32_and(buf)
  emit_local_set(buf, obj_size_local)
  emit_heap_alloc_local(ctx, buf, obj_size_local, sub_ptr)
  // Set string header
  emit_local_get(buf, sub_ptr)
  emit_i32_const_raw(buf, obj_string)
  emit_i32_store(buf, 0)
  emit_local_get(buf, sub_ptr)
  emit_local_get(buf, sub_len)
  emit_i32_store(buf, 4)
  // Copy bytes: sub_ptr[8+j] = str_ptr[8+seg_start+j] for j in [0, sub_len)
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, copy_j)
  emit_block(buf) // block $copy_done
  emit_loop(buf) // loop $copy_loop
  emit_local_get(buf, copy_j)
  emit_local_get(buf, sub_len)
  emit_i32_ge_s(buf)
  emit_br_if(buf, 1) // break $copy_done
  emit_local_get(buf, sub_ptr)
  emit_local_get(buf, copy_j)
  emit_i32_add(buf)
  emit_local_get(buf, str_ptr)
  emit_local_get(buf, seg_start)
  emit_i32_add(buf)
  emit_local_get(buf, copy_j)
  emit_i32_add(buf)
  emit_i32_load8_u(buf, 8)
  emit_i32_store8(buf, 8)
  emit_local_get(buf, copy_j)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, copy_j)
  emit_br(buf, 0) // continue $copy_loop
  emit_end(buf) // end $copy_loop
  emit_end(buf) // end $copy_done
  // Push tagged sub_ptr into array: arr_ptr[8 + arr_len*4] = sub_ptr | tag_obj
  emit_local_get(buf, arr_ptr)
  emit_local_get(buf, arr_len)
  emit_i32_const_raw(buf, 4)
  emit_i32_mul(buf)
  emit_i32_add(buf)
  emit_local_get(buf, sub_ptr)
  emit_i32_const_raw(buf, tag_obj)
  emit_i32_or(buf)
  emit_i32_store(buf, 8)
  // arr_len++
  emit_local_get(buf, arr_len)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, arr_len)
}

///|
/// string_split(source, delimiter) -> Array[String]
/// If delimiter is empty, splits into individual characters.
/// Otherwise, scans for delimiter matches and builds an array of substrings.
fn emit_string_split_impl(
  ctx : CodegenCtx,
  buf : ByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  require_heap(ctx)
  let str_ptr = alloc_temp_local(ctx)
  let str_len = alloc_temp_local(ctx)
  let del_ptr = alloc_temp_local(ctx)
  let del_len = alloc_temp_local(ctx)
  let arr_ptr = alloc_temp_local(ctx)
  let arr_len = alloc_temp_local(ctx)
  let seg_start = alloc_temp_local(ctx)
  let scan_i = alloc_temp_local(ctx)
  let inner_j = alloc_temp_local(ctx)
  let matched = alloc_temp_local(ctx)
  let sub_ptr = alloc_temp_local(ctx)
  let sub_len = alloc_temp_local(ctx)
  let copy_j = alloc_temp_local(ctx)
  let obj_size_local = alloc_temp_local(ctx)
  // Untag source string
  compile_expr_i32(ctx, buf, pos_args[0])
  emit_untag_ptr_i32(buf)
  emit_local_set(buf, str_ptr)
  emit_local_get(buf, str_ptr)
  emit_i32_load(buf, 4)
  emit_local_set(buf, str_len)
  // Untag delimiter string
  compile_expr_i32(ctx, buf, pos_args[1])
  emit_untag_ptr_i32(buf)
  emit_local_set(buf, del_ptr)
  emit_local_get(buf, del_ptr)
  emit_i32_load(buf, 4)
  emit_local_set(buf, del_len)
  // Allocate result array (max 4096 elements)
  let max_cap = 4096
  let arr_size = align4(8 + max_cap * 4)
  emit_heap_alloc(ctx, buf, arr_size, arr_ptr)
  emit_local_get(buf, arr_ptr)
  emit_i32_const_raw(buf, obj_array)
  emit_i32_store(buf, 0)
  // Initialize arr_len = 0, scan_i = 0, seg_start = 0
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, arr_len)
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, scan_i)
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, seg_start)
  // Branch on delimiter length
  emit_local_get(buf, del_len)
  emit_i32_eqz(buf)
  emit_if(buf) // if del_len == 0: character-by-character split
  emit_block(buf) // block $char_done
  emit_loop(buf) // loop $char_loop
  emit_local_get(buf, scan_i)
  emit_local_get(buf, str_len)
  emit_i32_ge_s(buf)
  emit_br_if(buf, 1) // break $char_done
  // sub_len = 1, seg_start = scan_i
  emit_i32_const_raw(buf, 1)
  emit_local_set(buf, sub_len)
  emit_local_get(buf, scan_i)
  emit_local_set(buf, seg_start)
  emit_alloc_substr_push(
    ctx, buf, str_ptr, seg_start, sub_len, arr_ptr, arr_len, sub_ptr, copy_j, obj_size_local,
  )
  // scan_i++
  emit_local_get(buf, scan_i)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, scan_i)
  emit_br(buf, 0) // continue $char_loop
  emit_end(buf) // end $char_loop
  emit_end(buf) // end $char_done
  emit_else(buf) // else: del_len > 0, normal split
  // Main split loop
  emit_block(buf) // block $split_done
  emit_loop(buf) // loop $split_loop
  // if scan_i + del_len > str_len: break to final segment
  emit_local_get(buf, scan_i)
  emit_local_get(buf, del_len)
  emit_i32_add(buf)
  emit_local_get(buf, str_len)
  emit_i32_gt_s(buf)
  emit_br_if(buf, 1) // break $split_done
  // Try to match delimiter at scan_i
  emit_i32_const_raw(buf, 1)
  emit_local_set(buf, matched)
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, inner_j)
  emit_block(buf) // block $cmp_done
  emit_loop(buf) // loop $cmp_loop
  emit_local_get(buf, inner_j)
  emit_local_get(buf, del_len)
  emit_i32_ge_s(buf)
  emit_br_if(buf, 1) // break $cmp_done (all bytes matched)
  // Compare str[scan_i + inner_j + 8] vs del[inner_j + 8]
  emit_local_get(buf, str_ptr)
  emit_local_get(buf, scan_i)
  emit_i32_add(buf)
  emit_local_get(buf, inner_j)
  emit_i32_add(buf)
  emit_i32_load8_u(buf, 8)
  emit_local_get(buf, del_ptr)
  emit_local_get(buf, inner_j)
  emit_i32_add(buf)
  emit_i32_load8_u(buf, 8)
  emit_i32_eq(buf)
  emit_i32_eqz(buf) // not equal?
  emit_if(buf) // if not equal
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, matched)
  emit_br(buf, 2) // break $cmp_done
  emit_end(buf) // end if
  emit_local_get(buf, inner_j)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, inner_j)
  emit_br(buf, 0) // continue $cmp_loop
  emit_end(buf) // end $cmp_loop
  emit_end(buf) // end $cmp_done
  // If matched: extract segment, push to array, advance
  emit_local_get(buf, matched)
  emit_if(buf) // if matched
  // sub_len = scan_i - seg_start
  emit_local_get(buf, scan_i)
  emit_local_get(buf, seg_start)
  emit_i32_sub(buf)
  emit_local_set(buf, sub_len)
  emit_alloc_substr_push(
    ctx, buf, str_ptr, seg_start, sub_len, arr_ptr, arr_len, sub_ptr, copy_j, obj_size_local,
  )
  // scan_i += del_len
  emit_local_get(buf, scan_i)
  emit_local_get(buf, del_len)
  emit_i32_add(buf)
  emit_local_set(buf, scan_i)
  // seg_start = scan_i
  emit_local_get(buf, scan_i)
  emit_local_set(buf, seg_start)
  emit_br(buf, 1) // continue $split_loop (br to loop re-enters it)
  emit_end(buf) // end if matched
  // Not matched: scan_i++
  emit_local_get(buf, scan_i)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, scan_i)
  emit_br(buf, 0) // continue $split_loop
  emit_end(buf) // end $split_loop
  emit_end(buf) // end $split_done
  // Final segment: [seg_start, str_len)
  emit_local_get(buf, str_len)
  emit_local_get(buf, seg_start)
  emit_i32_sub(buf)
  emit_local_set(buf, sub_len)
  emit_alloc_substr_push(
    ctx, buf, str_ptr, seg_start, sub_len, arr_ptr, arr_len, sub_ptr, copy_j, obj_size_local,
  )
  emit_end(buf) // end if/else (del_len check)
  // Write final array length
  emit_local_get(buf, arr_ptr)
  emit_local_get(buf, arr_len)
  emit_i32_store(buf, 4)
  // Return tagged array pointer
  emit_local_get(buf, arr_ptr)
  emit_i64_extend_i32_u(buf)
  emit_i64_const_raw(buf, tag_obj.to_int64())
  emit_i64_or(buf)
}
