///|
/// S5: Try to fold a binary integer operation at compile time.
/// Returns true if folding succeeded (result emitted), false otherwise.
fn try_fold_int_arith(
  buf : ByteBuf,
  name : String,
  left : @core.Expr,
  right : @core.Expr,
) -> Bool {
  match (left, right) {
    (Int(value=a, ..), Int(value=b, ..)) => {
      let result : Int64? = match name {
        "add" | "__add" => Some(a + b)
        "sub" | "__sub" => Some(a - b)
        "mul" | "__mul" => Some(a * b)
        "div" | "__div" => if b != 0L { Some(a / b) } else { None }
        "mod" | "__mod" => if b != 0L { Some(a % b) } else { None }
        _ => None
      }
      match result {
        Some(r) => {
          emit_i64_const_tagged(buf, r)
          true
        }
        None => false
      }
    }
    _ => false
  }
}

///|
/// S5: Try to fold a binary integer comparison at compile time.
/// Returns true if folding succeeded (result emitted), false otherwise.
fn _try_fold_int_cmp(
  buf : ByteBuf,
  name : String,
  left : @core.Expr,
  right : @core.Expr,
) -> Bool {
  match (left, right) {
    (Int(value=a, ..), Int(value=b, ..)) => {
      let result : Bool? = match name {
        "eq" | "__eq" => Some(a == b)
        "ne" | "__ne" | "neq" => Some(a != b)
        "lt" | "__lt" => Some(a < b)
        "gt" | "__gt" => Some(a > b)
        "le" | "__le" | "lte" => Some(a <= b)
        "ge" | "__ge" | "gte" => Some(a >= b)
        _ => None
      }
      match result {
        Some(r) => {
          emit_i64_const_raw(buf, tag_bool_value64(r))
          true
        }
        None => false
      }
    }
    _ => false
  }
}

///|
fn compile_i32_cmp_tagged(
  ctx : CodegenCtx,
  buf : ByteBuf,
  left : @core.Expr,
  right : @core.Expr,
  emit_cmp : (ByteBuf) -> Unit,
) -> Unit raise WasmGenError {
  // For tagged ints (tag_int = 0): comparison on tagged values
  // preserves ordering since (a<<2) < (b<<2) iff a < b
  compile_expr_i32(ctx, buf, left)
  compile_expr_i32(ctx, buf, right)
  emit_cmp(buf)
  emit_tag_bool_from_i32(buf)
}

///|
fn compile_i32_add_tagged(
  ctx : CodegenCtx,
  buf : ByteBuf,
  left : @core.Expr,
  right : @core.Expr,
) -> Unit raise WasmGenError {
  if try_fold_int_arith(buf, "add", left, right) {
    return
  }
  compile_expr_i32(ctx, buf, left)
  compile_expr_i32(ctx, buf, right)
  emit_i64_add(buf)
}

///|
fn compile_i32_sub_tagged(
  ctx : CodegenCtx,
  buf : ByteBuf,
  left : @core.Expr,
  right : @core.Expr,
) -> Unit raise WasmGenError {
  if try_fold_int_arith(buf, "sub", left, right) {
    return
  }
  compile_expr_i32(ctx, buf, left)
  compile_expr_i32(ctx, buf, right)
  emit_i64_sub(buf)
}

///|
fn compile_i32_mul_tagged(
  ctx : CodegenCtx,
  buf : ByteBuf,
  left : @core.Expr,
  right : @core.Expr,
) -> Unit raise WasmGenError {
  if try_fold_int_arith(buf, "mul", left, right) {
    return
  }
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
  // Retag result: (result << 2) — tag_int = 0 so i64.or is a no-op
  emit_i64_const_raw(buf, 2L)
  emit_i64_shl(buf)
}

///|
fn compile_i32_div_tagged(
  ctx : CodegenCtx,
  buf : ByteBuf,
  left : @core.Expr,
  right : @core.Expr,
) -> Unit raise WasmGenError {
  if try_fold_int_arith(buf, "div", left, right) {
    return
  }
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
  // Retag result: (result << 2) — tag_int = 0 so i64.or is a no-op
  emit_i64_const_raw(buf, 2L)
  emit_i64_shl(buf)
}

///|
fn compile_i32_mod_tagged(
  ctx : CodegenCtx,
  buf : ByteBuf,
  left : @core.Expr,
  right : @core.Expr,
) -> Unit raise WasmGenError {
  if try_fold_int_arith(buf, "mod", left, right) {
    return
  }
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
  // Retag result: (result << 2) — tag_int = 0 so i64.or is a no-op
  emit_i64_const_raw(buf, 2L)
  emit_i64_shl(buf)
}

///|
fn emit_tagged_i64_arith_from_locals(
  buf : ByteBuf,
  name : String,
  left_local : Int,
  right_local : Int,
) -> Unit raise WasmGenError {
  match name {
    "add" | "__add" => {
      emit_local_get(buf, left_local)
      emit_local_get(buf, right_local)
      emit_i64_add(buf)
    }
    "sub" | "__sub" => {
      emit_local_get(buf, left_local)
      emit_local_get(buf, right_local)
      emit_i64_sub(buf)
    }
    "mul" | "__mul" => {
      emit_local_get(buf, left_local)
      emit_i64_const_raw(buf, 2L)
      emit_i64_shr_s(buf)
      emit_local_get(buf, right_local)
      emit_i64_const_raw(buf, 2L)
      emit_i64_shr_s(buf)
      emit_i64_mul(buf)
      // Retag: (result << 2) — tag_int = 0 so i64.or is a no-op
      emit_i64_const_raw(buf, 2L)
      emit_i64_shl(buf)
    }
    "div" | "__div" => {
      emit_local_get(buf, left_local)
      emit_i64_const_raw(buf, 2L)
      emit_i64_shr_s(buf)
      emit_local_get(buf, right_local)
      emit_i64_const_raw(buf, 2L)
      emit_i64_shr_s(buf)
      emit_i64_div_s(buf)
      // Retag: (result << 2) — tag_int = 0 so i64.or is a no-op
      emit_i64_const_raw(buf, 2L)
      emit_i64_shl(buf)
    }
    _ => raise WasmGenError::Unsupported("dynamic numeric arith op: " + name)
  }
}

///|
fn _compile_dynamic_numeric_arith_op(
  ctx : CodegenCtx,
  buf : ByteBuf,
  name : String,
  args : Array[@core.CallArg],
  emit_f32 : (ByteBuf) -> Unit,
  emit_f64 : (ByteBuf) -> Unit,
) -> Unit raise WasmGenError {
  let pos_args = extract_positional_exprs_with_arity(args, name, 2)
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
  buf.push((126).to_byte()) // result i64
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
  buf.push((126).to_byte()) // result i64
  emit_boxed_f32_raise(ctx, buf, fn() {
    emit_local_get(buf, left_ptr_local)
    emit_f32_load(buf, 4)
    emit_local_get(buf, right_ptr_local)
    emit_f32_load(buf, 4)
    emit_f32(buf)
  })
  buf.push((5).to_byte()) // else
  emit_local_get(buf, left_type_local)
  emit_i32_const_raw(buf, obj_double)
  emit_i32_eq(buf)
  emit_local_get(buf, right_type_local)
  emit_i32_const_raw(buf, obj_double)
  emit_i32_eq(buf)
  emit_i32_and(buf)
  buf.push((4).to_byte()) // if
  buf.push((126).to_byte()) // result i64
  emit_boxed_f64_raise(ctx, buf, fn() {
    emit_local_get(buf, left_ptr_local)
    emit_f64_load(buf, 4)
    emit_local_get(buf, right_ptr_local)
    emit_f64_load(buf, 4)
    emit_f64(buf)
  })
  buf.push((5).to_byte()) // else
  emit_unreachable(buf)
  buf.push((11).to_byte()) // end if
  buf.push((11).to_byte()) // end if
  buf.push((5).to_byte()) // else
  emit_local_get(buf, left_tag_local)
  emit_i32_const_raw(buf, tag_int)
  emit_i32_eq(buf)
  emit_local_get(buf, right_tag_local)
  emit_i32_const_raw(buf, tag_int)
  emit_i32_eq(buf)
  emit_i32_and(buf)
  buf.push((4).to_byte()) // if
  buf.push((126).to_byte()) // result i64
  emit_tagged_i64_arith_from_locals(buf, name, left_local, right_local)
  buf.push((5).to_byte()) // else
  emit_unreachable(buf)
  buf.push((11).to_byte()) // end if
  buf.push((11).to_byte()) // end if
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
/// Lexicographic byte-wise compare of two `obj_string` values, then test the
/// resulting signed difference against 0 with the operator selected by `name`.
/// Leaves an i32 boolean (1 or 0) on the stack.
fn emit_string_lex_cmp_to_bool(
  buf : ByteBuf,
  name : String,
  left_ptr_local : Int,
  right_ptr_local : Int,
  left_len_local : Int,
  right_len_local : Int,
  loop_i_local : Int,
  diff_local : Int,
  chunk_end_local : Int,
  min_len_local : Int,
) -> Unit {
  // Load lengths from each obj_string header (offset 4).
  emit_local_get(buf, left_ptr_local)
  emit_i32_load(buf, 4)
  emit_local_set(buf, left_len_local)
  emit_local_get(buf, right_ptr_local)
  emit_i32_load(buf, 4)
  emit_local_set(buf, right_len_local)
  // diff_local accumulates the eventual signed lex difference; default to
  // length difference so an empty common prefix decides on length alone.
  emit_local_get(buf, left_len_local)
  emit_local_get(buf, right_len_local)
  emit_i32_sub(buf)
  emit_local_set(buf, diff_local)
  // Iterate min(left_len, right_len) bytes, breaking on the first mismatch.
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, loop_i_local)
  // SIMD fast path (ADR-0054): skip equal 16-byte chunks of the common
  // prefix, stopping at the first unequal chunk (or chunk_end). The scalar
  // loop below then locates the first differing byte and sets diff. Only the
  // common prefix is scanned, so diff's length-difference default survives.
  // min_len = min(left_len, right_len).
  emit_local_get(buf, left_len_local)
  emit_local_set(buf, min_len_local)
  emit_local_get(buf, right_len_local)
  emit_local_get(buf, left_len_local)
  emit_i32_lt_s(buf)
  buf.push((4).to_byte()) // if (right_len < left_len)
  buf.push((64).to_byte()) // void
  emit_local_get(buf, right_len_local)
  emit_local_set(buf, min_len_local)
  buf.push((11).to_byte()) // end if
  // chunk_end = min_len & ~15
  emit_local_get(buf, min_len_local)
  emit_i32_const_raw(buf, -16)
  emit_i32_and(buf)
  emit_local_set(buf, chunk_end_local)
  emit_block(buf)
  emit_loop(buf)
  emit_local_get(buf, loop_i_local)
  emit_local_get(buf, chunk_end_local)
  emit_i32_ge_s(buf)
  emit_br_if(buf, 1) // loop_i >= chunk_end: stop
  emit_local_get(buf, left_ptr_local)
  emit_local_get(buf, loop_i_local)
  emit_i32_add(buf)
  emit_v128_load_align(buf, 2, 8)
  emit_local_get(buf, right_ptr_local)
  emit_local_get(buf, loop_i_local)
  emit_i32_add(buf)
  emit_v128_load_align(buf, 2, 8)
  emit_i8x16_eq(buf)
  emit_i8x16_all_true(buf)
  emit_i32_eqz(buf) // 1 if this 16-byte chunk has a mismatch
  emit_br_if(buf, 1) // stop; scalar loop pinpoints the first differing byte
  emit_local_get(buf, loop_i_local)
  emit_i32_const_raw(buf, 16)
  emit_i32_add(buf)
  emit_local_set(buf, loop_i_local)
  emit_br(buf, 0)
  emit_end(buf) // end SIMD loop
  emit_end(buf) // end SIMD block
  emit_block(buf)
  emit_loop(buf)
  // if loop_i >= left_len: break
  emit_local_get(buf, loop_i_local)
  emit_local_get(buf, left_len_local)
  emit_i32_ge_s(buf)
  emit_br_if(buf, 1)
  // if loop_i >= right_len: break
  emit_local_get(buf, loop_i_local)
  emit_local_get(buf, right_len_local)
  emit_i32_ge_s(buf)
  emit_br_if(buf, 1)
  // byte_diff = left[loop_i] - right[loop_i]; both unsigned 0..255.
  emit_local_get(buf, left_ptr_local)
  emit_local_get(buf, loop_i_local)
  emit_i32_add(buf)
  emit_i32_load8_u(buf, 8)
  emit_local_get(buf, right_ptr_local)
  emit_local_get(buf, loop_i_local)
  emit_i32_add(buf)
  emit_i32_load8_u(buf, 8)
  emit_i32_sub(buf)
  // Stash byte_diff in min_len_local (no longer needed here) rather than
  // overwriting diff_local every iteration: on an all-equal common prefix we
  // must keep diff_local at its length-difference default, only replacing it
  // when an actual mismatch is found. (Fixes length tie-break, e.g.
  // "ab" < "abc", which the previous unconditional `tee diff_local` broke.)
  emit_local_tee(buf, min_len_local)
  emit_i32_eqz(buf)
  emit_i32_eqz(buf) // if byte_diff != 0
  buf.push((4).to_byte())
  buf.push((64).to_byte())
  emit_local_get(buf, min_len_local)
  emit_local_set(buf, diff_local) // diff = first differing byte's signed diff
  emit_br(buf, 2) // break out of loop+block
  buf.push((11).to_byte())
  // loop_i++
  emit_local_get(buf, loop_i_local)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, loop_i_local)
  emit_br(buf, 0)
  emit_end(buf) // end loop
  emit_end(buf) // end block
  // Compare diff against 0 with the requested op.
  emit_local_get(buf, diff_local)
  emit_i32_const_raw(buf, 0)
  if name == "lt" || name == "__lt" {
    emit_i32_lt_s(buf)
  } else if name == "le" || name == "__le" {
    emit_i32_le_s(buf)
  } else if name == "gt" || name == "__gt" {
    emit_i32_gt_s(buf)
  } else if name == "ge" || name == "__ge" {
    emit_i32_ge_s(buf)
  } else {
    // Fallback for unexpected names: treat as equality.
    emit_i32_eq(buf)
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
      let left_len_local = alloc_temp_local(ctx)
      let right_len_local = alloc_temp_local(ctx)
      let loop_i_local = alloc_temp_local(ctx)
      let eq_local = alloc_temp_local(ctx)
      // SIMD lex-compare scratch (ADR-0054): common-prefix chunk boundary
      // and min(left_len, right_len).
      let lex_chunk_end_local = alloc_temp_local(ctx)
      let lex_min_len_local = alloc_temp_local(ctx)
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
      if name == "eq" || name == "__eq" {
        emit_local_get(buf, left_type_local)
        emit_i32_const_raw(buf, obj_string)
        emit_i32_eq(buf)
        emit_local_get(buf, right_type_local)
        emit_i32_const_raw(buf, obj_string)
        emit_i32_eq(buf)
        emit_i32_and(buf)
        buf.push((4).to_byte()) // if
        buf.push((127).to_byte()) // result i32
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
        buf.push((5).to_byte()) // else
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
        // Check for StringView: obj_string_view(11) on either side
        emit_local_get(buf, left_type_local)
        emit_i32_const_raw(buf, obj_string_view)
        emit_i32_eq(buf)
        emit_local_get(buf, right_type_local)
        emit_i32_const_raw(buf, obj_string)
        emit_i32_eq(buf)
        emit_i32_and(buf)
        buf.push((4).to_byte()) // if (left=StringView, right=String)
        buf.push((127).to_byte()) // result i32
        // StringView: source_ptr at +4, start at +8, end at +12
        // String: length at +4, data at +8
        emit_string_view_eq(
          buf, left_ptr_local, right_ptr_local, left_len_local, right_len_local,
          loop_i_local, eq_local,
        )
        buf.push((5).to_byte()) // else
        // Check reverse: left=String, right=StringView
        emit_local_get(buf, left_type_local)
        emit_i32_const_raw(buf, obj_string)
        emit_i32_eq(buf)
        emit_local_get(buf, right_type_local)
        emit_i32_const_raw(buf, obj_string_view)
        emit_i32_eq(buf)
        emit_i32_and(buf)
        buf.push((4).to_byte()) // if (left=String, right=StringView)
        buf.push((127).to_byte()) // result i32
        emit_string_view_eq(
          buf, right_ptr_local, left_ptr_local, left_len_local, right_len_local,
          loop_i_local, eq_local,
        )
        buf.push((5).to_byte()) // else
        // Check both StringView
        emit_local_get(buf, left_type_local)
        emit_i32_const_raw(buf, obj_string_view)
        emit_i32_eq(buf)
        emit_local_get(buf, right_type_local)
        emit_i32_const_raw(buf, obj_string_view)
        emit_i32_eq(buf)
        emit_i32_and(buf)
        buf.push((4).to_byte()) // if (both StringView)
        buf.push((127).to_byte()) // result i32
        emit_string_view_view_eq(
          buf, left_ptr_local, right_ptr_local, left_len_local, right_len_local,
          loop_i_local, eq_local,
        )
        buf.push((5).to_byte()) // else
        // Check for record/struct: both obj_record(4)
        emit_local_get(buf, left_type_local)
        emit_i32_const_raw(buf, obj_record)
        emit_i32_eq(buf)
        emit_local_get(buf, right_type_local)
        emit_i32_const_raw(buf, obj_record)
        emit_i32_eq(buf)
        emit_i32_and(buf)
        buf.push((4).to_byte()) // if (both record)
        buf.push((127).to_byte()) // result i32
        // Compare field counts
        emit_local_get(buf, left_ptr_local)
        emit_i32_load(buf, 4)
        emit_local_set(buf, left_len_local)
        emit_local_get(buf, right_ptr_local)
        emit_i32_load(buf, 4)
        emit_local_set(buf, right_len_local)
        emit_local_get(buf, left_len_local)
        emit_local_get(buf, right_len_local)
        emit_i32_eq(buf)
        buf.push((4).to_byte()) // if (same field count)
        buf.push((127).to_byte()) // result i32
        // Compare field values: loop over i32 values at offset 8+i*8+4
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
        // Compute field offset: base + 8 + i*8 + 4 = base + 12 + i*8
        emit_local_get(buf, left_ptr_local)
        emit_local_get(buf, loop_i_local)
        emit_i32_const_raw(buf, 8)
        emit_i32_mul(buf)
        emit_i32_add(buf)
        emit_i32_load(buf, 12)
        emit_local_get(buf, right_ptr_local)
        emit_local_get(buf, loop_i_local)
        emit_i32_const_raw(buf, 8)
        emit_i32_mul(buf)
        emit_i32_add(buf)
        emit_i32_load(buf, 12)
        emit_i32_eq(buf)
        emit_i32_eqz(buf)
        buf.push((4).to_byte()) // if (values differ)
        buf.push((64).to_byte()) // void
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, eq_local)
        emit_local_get(buf, left_len_local)
        emit_local_set(buf, loop_i_local) // break loop
        buf.push((5).to_byte()) // else
        emit_local_get(buf, loop_i_local)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, loop_i_local)
        buf.push((11).to_byte()) // end if
        emit_br(buf, 0)
        emit_end(buf) // end loop
        emit_end(buf) // end block
        emit_local_get(buf, eq_local)
        buf.push((5).to_byte()) // else (different field count)
        emit_i32_const_raw(buf, 0)
        buf.push((11).to_byte()) // end if (same field count)
        buf.push((5).to_byte()) // else (not both record)
        // Check both obj_tuple — element-wise shallow compare (mirrors the
        // record-eq branch above). Unit `()` is the len=0 case, so the loop
        // skips and `eq` stays 1 — trivially self-equal.
        emit_local_get(buf, left_type_local)
        emit_i32_const_raw(buf, obj_tuple)
        emit_i32_eq(buf)
        emit_local_get(buf, right_type_local)
        emit_i32_const_raw(buf, obj_tuple)
        emit_i32_eq(buf)
        emit_i32_and(buf)
        buf.push((4).to_byte()) // if (both tuple)
        buf.push((127).to_byte()) // result i32
        emit_local_get(buf, left_ptr_local)
        emit_i32_load(buf, 4)
        emit_local_set(buf, left_len_local)
        emit_local_get(buf, right_ptr_local)
        emit_i32_load(buf, 4)
        emit_local_set(buf, right_len_local)
        emit_local_get(buf, left_len_local)
        emit_local_get(buf, right_len_local)
        emit_i32_eq(buf)
        buf.push((4).to_byte()) // if (same length)
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
        // Value offset: base + i*4, load i32 at +8
        emit_local_get(buf, left_ptr_local)
        emit_local_get(buf, loop_i_local)
        emit_i32_const_raw(buf, 4)
        emit_i32_mul(buf)
        emit_i32_add(buf)
        emit_i32_load(buf, 8)
        emit_local_get(buf, right_ptr_local)
        emit_local_get(buf, loop_i_local)
        emit_i32_const_raw(buf, 4)
        emit_i32_mul(buf)
        emit_i32_add(buf)
        emit_i32_load(buf, 8)
        emit_i32_eq(buf)
        emit_i32_eqz(buf)
        buf.push((4).to_byte()) // if (values differ)
        buf.push((64).to_byte()) // void
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, eq_local)
        emit_local_get(buf, left_len_local)
        emit_local_set(buf, loop_i_local) // break loop
        buf.push((5).to_byte()) // else
        emit_local_get(buf, loop_i_local)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, loop_i_local)
        buf.push((11).to_byte()) // end if
        emit_br(buf, 0)
        emit_end(buf) // end loop
        emit_end(buf) // end block
        emit_local_get(buf, eq_local)
        buf.push((5).to_byte()) // else (different length)
        emit_i32_const_raw(buf, 0)
        buf.push((11).to_byte()) // end if (same length)
        buf.push((5).to_byte()) // else (not both tuple)
        // Check both obj_enum — derive(Eq) for enums with payload. Layout:
        // obj_type @ 0, arity @ 4, ctor_tag @ 8, values @ 12+i*4. Equality
        // holds when both sides have the same ctor_tag and each payload i32
        // matches (shallow compare, matching the record/tuple branches).
        emit_local_get(buf, left_type_local)
        emit_i32_const_raw(buf, obj_enum)
        emit_i32_eq(buf)
        emit_local_get(buf, right_type_local)
        emit_i32_const_raw(buf, obj_enum)
        emit_i32_eq(buf)
        emit_i32_and(buf)
        buf.push((4).to_byte()) // if (both enum)
        buf.push((127).to_byte()) // result i32
        emit_local_get(buf, left_ptr_local)
        emit_i32_load(buf, 8)
        emit_local_get(buf, right_ptr_local)
        emit_i32_load(buf, 8)
        emit_i32_eq(buf)
        buf.push((4).to_byte()) // if (same ctor_tag)
        buf.push((127).to_byte()) // result i32
        emit_local_get(buf, left_ptr_local)
        emit_i32_load(buf, 4)
        emit_local_set(buf, left_len_local)
        emit_local_get(buf, right_ptr_local)
        emit_i32_load(buf, 4)
        emit_local_set(buf, right_len_local)
        emit_local_get(buf, left_len_local)
        emit_local_get(buf, right_len_local)
        emit_i32_eq(buf)
        buf.push((4).to_byte()) // if (same arity)
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
        // Payload offset: base + i*4, load i32 at +12. Sign-extend back to
        // i64 to recover the tagged value, then dispatch through the
        // value_eq helper so structurally-equal nested enum payloads
        // (different heap addresses) compare equal (#325).
        emit_local_get(buf, left_ptr_local)
        emit_local_get(buf, loop_i_local)
        emit_i32_const_raw(buf, 4)
        emit_i32_mul(buf)
        emit_i32_add(buf)
        emit_i32_load(buf, 12)
        emit_i64_extend_i32_s(buf)
        emit_local_get(buf, right_ptr_local)
        emit_local_get(buf, loop_i_local)
        emit_i32_const_raw(buf, 4)
        emit_i32_mul(buf)
        emit_i32_add(buf)
        emit_i32_load(buf, 12)
        emit_i64_extend_i32_s(buf)
        if ctx.need_value_eq && ctx.need_heap && ctx.value_eq_func_idx >= 0 {
          let value_eq_abs_idx = func_import_count(ctx) + ctx.value_eq_func_idx
          emit_call(buf, value_eq_abs_idx)
        } else {
          // Fallback when no helper is available (e.g. no `__eq` in user
          // code reaches scan_needs because the call was synthesised
          // post-scan): tagged i64 equality, equivalent to the prior
          // shallow compare for non-pointer payloads.
          emit_i64_eq(buf)
        }
        emit_i32_eqz(buf)
        buf.push((4).to_byte()) // if (values differ)
        buf.push((64).to_byte()) // void
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, eq_local)
        emit_local_get(buf, left_len_local)
        emit_local_set(buf, loop_i_local) // break loop
        buf.push((5).to_byte()) // else
        emit_local_get(buf, loop_i_local)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, loop_i_local)
        buf.push((11).to_byte()) // end if
        emit_br(buf, 0)
        emit_end(buf) // end loop
        emit_end(buf) // end block
        emit_local_get(buf, eq_local)
        buf.push((5).to_byte()) // else (arity mismatch)
        emit_i32_const_raw(buf, 0)
        buf.push((11).to_byte()) // end if (same arity)
        buf.push((5).to_byte()) // else (ctor_tag differs)
        emit_i32_const_raw(buf, 0)
        buf.push((11).to_byte()) // end if (same ctor_tag)
        buf.push((5).to_byte()) // else (not both enum)
        emit_local_get(buf, left_local)
        emit_local_get(buf, right_local)
        emit_i64_cmp(buf)
        buf.push((11).to_byte()) // end if (both enum)
        buf.push((11).to_byte()) // end if (both tuple)
        buf.push((11).to_byte()) // end if (both record)
        buf.push((11).to_byte()) // end if (both SV)
        buf.push((11).to_byte()) // end if (S, SV)
        buf.push((11).to_byte()) // end if (SV, S)
        buf.push((11).to_byte()) // end if
        buf.push((11).to_byte()) // end if
        buf.push((11).to_byte()) // end if
      } else {
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
        // Both strings: byte-wise lexicographic order. Compute a signed
        // i32 lex difference, then compare against 0 with the requested
        // op. Without this branch, `__lt`/`__le`/`__gt`/`__ge` on strings
        // fall through to a tagged-i64 pointer comparison and return
        // arbitrary results.
        emit_local_get(buf, left_type_local)
        emit_i32_const_raw(buf, obj_string)
        emit_i32_eq(buf)
        emit_local_get(buf, right_type_local)
        emit_i32_const_raw(buf, obj_string)
        emit_i32_eq(buf)
        emit_i32_and(buf)
        buf.push((4).to_byte()) // if both strings
        buf.push((127).to_byte()) // result i32
        emit_string_lex_cmp_to_bool(
          buf, name, left_ptr_local, right_ptr_local, left_len_local, right_len_local,
          loop_i_local, eq_local, lex_chunk_end_local, lex_min_len_local,
        )
        buf.push((5).to_byte()) // else (not both strings)
        // Compare tagged i64 values directly
        emit_local_get(buf, left_local)
        emit_local_get(buf, right_local)
        emit_i64_cmp(buf)
        buf.push((11).to_byte()) // end if (string)
        buf.push((11).to_byte()) // end if (double)
        buf.push((11).to_byte()) // end if (float)
      }
      buf.push((5).to_byte()) // else
      // Compare tagged i64 values directly
      emit_local_get(buf, left_local)
      emit_local_get(buf, right_local)
      emit_i64_cmp(buf)
      buf.push((11).to_byte()) // end if
      emit_tag_bool_from_i32(buf)
    }
    ValueKind::BoxedF32 => {
      emit_unbox_f32_expr(ctx, buf, pos_args[0])
      emit_unbox_f32_expr(ctx, buf, pos_args[1])
      emit_f32(buf)
      emit_tag_bool_from_i32(buf)
    }
    ValueKind::BoxedF64 => {
      emit_unbox_f64_expr(ctx, buf, pos_args[0])
      emit_unbox_f64_expr(ctx, buf, pos_args[1])
      emit_f64(buf)
      emit_tag_bool_from_i32(buf)
    }
    _ => raise WasmGenError::Unsupported("numeric kind")
  }
}

///|
fn emit_i32_result_as_tagged_int(buf : ByteBuf) -> Unit {
  emit_i64_extend_i32_s(buf)
  emit_i64_const_raw(buf, 2L)
  emit_i64_shl(buf)
  // tag_int = 0, i64.or is a no-op
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
  if !has_labeled {
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
  // Save tail position — args are not in tail position
  let saved_tail = ctx.is_tail_position
  ctx.is_tail_position = false
  for i in 0..<pos_args.length() {
    let kind = param_kinds[i]
    if ctx.use_js_strings && kind == ValueKind::ExternRef {
      compile_expr_ref(ctx, buf, pos_args[i])
    } else {
      compile_expr_i32(ctx, buf, pos_args[i])
    }
  }
  ctx.is_tail_position = saved_tail
  let fn_idx = match ctx.fn_indices.get(name) {
    Some(i) => i
    None => 0
  }
  // Direct call needs the callee's closure env when the function has captures.
  // Do not fall back to current function env; it may belong to another closure.
  // Skip closure env check for functions known to not need env at compile time.
  let known_no_env = !fn_index_needs_env(ctx, fn_idx)
  match ctx.locals.get(name) {
    Some(local_idx) if ctx.fn_local_sigs.contains(name) && !known_no_env => {
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
  // S4: Skip heap sync when callee is known to not use heap
  let callee_heap = match ctx.fn_needs_heap.get(name) {
    Some(false) => false
    _ => true // conservative: unknown or true
  }
  // S8: skip pre-call sync if heap_local already matches heap_global
  if callee_heap {
    emit_heap_pre_call_sync(ctx, buf)
  }
  let idx = func_import_count(ctx) + fn_idx
  // Tail call optimization: use return_call when in tail position
  // and no multi-value re-boxing is needed
  let has_multivalue = match ctx.fn_multivalue_results.get(name) {
    Some(_) => true
    None => false
  }
  if ctx.is_tail_position && !has_multivalue {
    emit_return_call(buf, idx)
  } else {
    emit_call(buf, idx)
    if callee_heap {
      emit_heap_post_call_sync(ctx, buf)
    }
    match ctx.fn_multivalue_results.get(name) {
      Some(mv_kinds) => emit_rebox_multivalue(ctx, buf, mv_kinds)
      None => ()
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
  // Check if name is a user function AND the call arity matches.
  // Without the arity check, a user variable named e.g. "mul" (1-param)
  // would shadow the builtin multiply operator "mul" (2-param) when the
  // core IR desugars `a * b` into `Call(name="mul", args=[a, b])`.
  // Linked imports take priority over builtins (user's "add" should call
  // the library function, not the arithmetic builtin).
  let is_linked_import = ctx.linked_fn_imports.contains(name)
  let is_user_fn = if is_linked_import {
    true
  } else if ctx.fn_indices.contains(name) {
    match ctx.fn_params.get(name) {
      Some(params) => args.length() == params.length()
      None => true
    }
  } else {
    false
  }
  if compile_call_builtin_pre_user(ctx, buf, name, args, is_user_fn) {
    return ()
  }
  if is_linked_import {
    // Linked imports: pre-compiled library functions (wasm import)
    match ctx.linked_fn_imports.get(name) {
      Some(import_idx) => {
        let return_count = match ctx.linked_fn_return_counts.get(name) {
          Some(rc) => rc
          None => 1
        }
        for arg in args {
          compile_expr(ctx, buf, arg.expr)
        }
        // Push closure env (i32 const 0, no captures for linked imports)
        buf.push((0x41).to_byte()) // i32.const
        buf.push((0).to_byte()) // 0
        emit_call(buf, import_idx)
        // Multivalue return: pack results into a tuple on heap
        if return_count > 1 {
          // Results are on stack: [v0, v1, ...]. Pack into tuple object.
          // Tuple layout: [tag:i32=6, len:i32=N, elem0:i64, elem1:i64, ...]
          let temp_locals : Array[Int] = []
          // Pop results into temp locals (reverse order)
          for _ in 0..<return_count {
            let tmp = alloc_temp_local_with_kind(ctx, ValueKind::I64)
            temp_locals.push(tmp)
            emit_local_set(buf, tmp)
          }
          // Allocate tuple on heap
          require_heap(ctx)
          let obj_size = 8 + return_count * 8
          emit_heap_reserve(ctx, buf, obj_size)
          let ptr_local = alloc_temp_local(ctx)
          emit_local_get(buf, ctx.heap_local)
          emit_local_set(buf, ptr_local)
          // Write tag = 6 (tuple)
          emit_local_get(buf, ptr_local)
          emit_i32_const_raw(buf, 6)
          buf.push((0x36).to_byte()) // i32.store
          buf.push((2).to_byte()) // align=4
          buf.push((0).to_byte()) // offset=0
          // Write length
          emit_local_get(buf, ptr_local)
          emit_i32_const_raw(buf, return_count)
          buf.push((0x36).to_byte()) // i32.store
          buf.push((2).to_byte()) // align=4
          buf.push((4).to_byte()) // offset=4
          // Write elements (reverse temp_locals to restore original order)
          for i = 0; i < return_count; i = i + 1 {
            emit_local_get(buf, ptr_local)
            emit_local_get(buf, temp_locals[return_count - 1 - i])
            buf.push((0x37).to_byte()) // i64.store
            buf.push((3).to_byte()) // align=8
            write_u32_leb(buf, 8 + i * 8) // offset
          }
          // Advance heap
          emit_local_get(buf, ctx.heap_local)
          emit_i32_const_raw(buf, obj_size)
          buf.push((0x6a).to_byte()) // i32.add
          emit_local_set(buf, ctx.heap_local)
          ctx.heap_synced = false
          // Return tagged pointer: (ptr << 2) | 1
          emit_local_get(buf, ptr_local)
          buf.push((0xad).to_byte()) // i64.extend_i32_u
          emit_i64_const_raw(buf, 2L)
          buf.push((0x86).to_byte()) // i64.shl
          emit_i64_const_raw(buf, 1L)
          buf.push((0x84).to_byte()) // i64.or
        }
        return ()
      }
      None => ()
    }
  } else if is_user_fn {
    compile_call_user_fn(ctx, buf, name, args)
    return ()
  }
  if compile_call_builtin_post_user(ctx, buf, name, args) {
    return ()
  }
  if compile_call_enum_ctor_by_name(ctx, buf, name, args) {
    return ()
  }
  if compile_call_record_field_fallback_by_name(ctx, buf, name, args) {
    return ()
  }
  compile_call_by_name_unresolved(ctx, buf, name)
}

///|
/// Emit StringView == String comparison.
/// sv_ptr: untagged ptr to StringView (obj_string_view)
/// str_ptr: untagged ptr to String (obj_string)
fn emit_string_view_eq(
  buf : ByteBuf,
  sv_ptr : Int,
  str_ptr : Int,
  len_a : Int,
  len_b : Int,
  loop_i : Int,
  eq_result : Int,
) -> Unit {
  // sv_len = sv.end - sv.start
  emit_local_get(buf, sv_ptr)
  emit_i32_load(buf, 12) // end
  emit_local_get(buf, sv_ptr)
  emit_i32_load(buf, 8) // start
  emit_i32_sub(buf)
  emit_local_set(buf, len_a)
  // str_len = str.length
  emit_local_get(buf, str_ptr)
  emit_i32_load(buf, 4) // length
  emit_local_set(buf, len_b)
  // if sv_len != str_len → 0
  emit_local_get(buf, len_a)
  emit_local_get(buf, len_b)
  emit_i32_eq(buf)
  buf.push((4).to_byte()) // if lengths match
  buf.push((127).to_byte()) // result i32
  // byte-by-byte compare: sv.source[sv.start + i] vs str[8 + i]
  emit_i32_const_raw(buf, 1)
  emit_local_set(buf, eq_result)
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, loop_i)
  emit_block(buf)
  emit_loop(buf)
  emit_local_get(buf, loop_i)
  emit_local_get(buf, len_a)
  emit_i32_lt_s(buf)
  emit_i32_eqz(buf)
  emit_br_if(buf, 1) // exit if i >= len
  // sv.source + sv.start + i
  emit_local_get(buf, sv_ptr)
  emit_i32_load(buf, 4) // source_ptr
  emit_local_get(buf, sv_ptr)
  emit_i32_load(buf, 8) // start
  emit_i32_add(buf)
  emit_local_get(buf, loop_i)
  emit_i32_add(buf)
  emit_i32_load8_u(buf, 8) // load byte at source_data + start + i
  // str + i
  emit_local_get(buf, str_ptr)
  emit_local_get(buf, loop_i)
  emit_i32_add(buf)
  emit_i32_load8_u(buf, 8) // load byte at str_data + i
  emit_i32_eq(buf)
  emit_i32_eqz(buf)
  buf.push((4).to_byte()) // if not equal
  buf.push((64).to_byte()) // void
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, eq_result)
  emit_local_get(buf, len_a)
  emit_local_set(buf, loop_i) // break loop
  buf.push((5).to_byte()) // else
  emit_local_get(buf, loop_i)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, loop_i)
  buf.push((11).to_byte()) // end if
  emit_br(buf, 0) // continue loop
  emit_end(buf) // end loop
  emit_end(buf) // end block
  emit_local_get(buf, eq_result)
  buf.push((5).to_byte()) // else (lengths differ)
  emit_i32_const_raw(buf, 0)
  buf.push((11).to_byte()) // end if
}

///|
/// Emit StringView == StringView comparison.
fn emit_string_view_view_eq(
  buf : ByteBuf,
  left_ptr : Int,
  right_ptr : Int,
  len_a : Int,
  len_b : Int,
  loop_i : Int,
  eq_result : Int,
) -> Unit {
  // left_len = left.end - left.start
  emit_local_get(buf, left_ptr)
  emit_i32_load(buf, 12)
  emit_local_get(buf, left_ptr)
  emit_i32_load(buf, 8)
  emit_i32_sub(buf)
  emit_local_set(buf, len_a)
  // right_len = right.end - right.start
  emit_local_get(buf, right_ptr)
  emit_i32_load(buf, 12)
  emit_local_get(buf, right_ptr)
  emit_i32_load(buf, 8)
  emit_i32_sub(buf)
  emit_local_set(buf, len_b)
  emit_local_get(buf, len_a)
  emit_local_get(buf, len_b)
  emit_i32_eq(buf)
  buf.push((4).to_byte())
  buf.push((127).to_byte())
  emit_i32_const_raw(buf, 1)
  emit_local_set(buf, eq_result)
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, loop_i)
  emit_block(buf)
  emit_loop(buf)
  emit_local_get(buf, loop_i)
  emit_local_get(buf, len_a)
  emit_i32_lt_s(buf)
  emit_i32_eqz(buf)
  emit_br_if(buf, 1)
  emit_local_get(buf, left_ptr)
  emit_i32_load(buf, 4)
  emit_local_get(buf, left_ptr)
  emit_i32_load(buf, 8)
  emit_i32_add(buf)
  emit_local_get(buf, loop_i)
  emit_i32_add(buf)
  emit_i32_load8_u(buf, 8)
  emit_local_get(buf, right_ptr)
  emit_i32_load(buf, 4)
  emit_local_get(buf, right_ptr)
  emit_i32_load(buf, 8)
  emit_i32_add(buf)
  emit_local_get(buf, loop_i)
  emit_i32_add(buf)
  emit_i32_load8_u(buf, 8)
  emit_i32_eq(buf)
  emit_i32_eqz(buf)
  buf.push((4).to_byte())
  buf.push((64).to_byte())
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, eq_result)
  emit_local_get(buf, len_a)
  emit_local_set(buf, loop_i)
  buf.push((5).to_byte())
  emit_local_get(buf, loop_i)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, loop_i)
  buf.push((11).to_byte())
  emit_br(buf, 0)
  emit_end(buf)
  emit_end(buf)
  emit_local_get(buf, eq_result)
  buf.push((5).to_byte())
  emit_i32_const_raw(buf, 0)
  buf.push((11).to_byte())
}
