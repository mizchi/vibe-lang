///|
/// Phase B-1 (Issue #415): `String::` namespace migrated off the two legacy
/// `match name` dispatchers (`wasm_codegen_builtin_string.mbt` linear arms and
/// `wasm_gc_codegen.mbt::Call`) onto the shared `migrated_builtin` table in
/// `builtin_registry.mbt`. The linear bodies are relocated verbatim from the
/// string.mbt arms; the wasm-gc bodies replicate each gc arm (arity check,
/// if present, then the delegated `compile_string_*` call).
///
/// Excluded (still legacy, by design):
/// - `String::compare` / `string_compare` — linear has a single-pass SIMD arm
///   (ADR-0054); wasm-gc reaches the same result via the prelude. Recorded as
///   a `prelude_fallback` divergence in `builtins()`.
/// - `String::replace_all` — linear has a dedicated arm but wasm-gc routes
///   through the prelude (no dedicated `Call` arm), so it is not a
///   `registry_both` builtin.
/// - `String::unicode_length` — wasm-gc-only; no linear arm exists.

///|
fn compile_string_length_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  let pos_args = extract_positional_exprs_with_arity(args, "String::length", 1)
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

///|
fn compile_string_length_gc_arm(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  if pos_args.length() != 1 {
    raise WasmGenError::Unsupported("String::length arity")
  }
  compile_len_gc(ctx, fctx, buf, pos_args[0])
}

///|
fn compile_string_char_code_at_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
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

///|
fn compile_string_char_code_at_gc_arm(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  if pos_args.length() != 2 {
    raise WasmGenError::Unsupported("String::char_code_at arity")
  }
  compile_string_char_code_at(ctx, fctx, buf, pos_args[0], pos_args[1])
}

///|
fn compile_string_substring_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
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

///|
fn compile_string_substring_gc_arm(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  if pos_args.length() != 3 {
    raise WasmGenError::Unsupported("String::substring arity")
  }
  compile_string_substring(
    ctx,
    fctx,
    buf,
    pos_args[0],
    pos_args[1],
    pos_args[2],
  )
}

///|
fn compile_string_concat_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  let pos_args = extract_positional_exprs_with_arity(args, "String::concat", 2)
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

///|
fn compile_string_concat_gc_arm(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  if pos_args.length() != 2 {
    raise WasmGenError::Unsupported("String::concat arity")
  }
  compile_string_concat(ctx, fctx, buf, pos_args[0], pos_args[1])
}

///|
fn compile_string_join_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  let pos_args = extract_positional_exprs_with_arity(args, "String::join", 2)
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

///|
fn compile_string_join_gc_arm(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  if pos_args.length() != 2 {
    raise WasmGenError::Unsupported("String::join arity")
  }
  compile_string_join(ctx, fctx, buf, pos_args[0], pos_args[1])
}

///|
fn compile_string_equals_gc_arm(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  if pos_args.length() != 2 {
    raise WasmGenError::Unsupported("String::equals arity")
  }
  compile_string_equals(ctx, fctx, buf, pos_args[0], pos_args[1])
}

///|
fn compile_string_index_of_gc_arm(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  if pos_args.length() != 2 {
    raise WasmGenError::Unsupported("String::index_of arity")
  }
  compile_string_index_of(ctx, fctx, buf, pos_args[0], pos_args[1])
}

///|
fn compile_string_last_index_of_gc_arm(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  if pos_args.length() != 2 {
    raise WasmGenError::Unsupported("String::last_index_of arity")
  }
  compile_string_last_index_of(ctx, fctx, buf, pos_args[0], pos_args[1])
}

///|
fn compile_string_contains_gc_arm(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  if pos_args.length() != 2 {
    raise WasmGenError::Unsupported("String::contains arity")
  }
  compile_string_contains(ctx, fctx, buf, pos_args[0], pos_args[1])
}

///|
fn compile_string_starts_with_gc_arm(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  if pos_args.length() != 2 {
    raise WasmGenError::Unsupported("String::starts_with arity")
  }
  compile_string_starts_with(ctx, fctx, buf, pos_args[0], pos_args[1])
}

///|
fn compile_string_ends_with_gc_arm(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  if pos_args.length() != 2 {
    raise WasmGenError::Unsupported("String::ends_with arity")
  }
  compile_string_ends_with(ctx, fctx, buf, pos_args[0], pos_args[1])
}

///|
fn compile_string_trim_gc_arm(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  if pos_args.length() != 1 {
    raise WasmGenError::Unsupported("String::trim arity")
  }
  compile_string_trim(ctx, fctx, buf, pos_args[0])
}

///|
fn compile_string_trim_start_gc_arm(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  if pos_args.length() != 1 {
    raise WasmGenError::Unsupported("String::trim_start arity")
  }
  compile_string_trim_start_gc(ctx, fctx, buf, pos_args[0])
}

///|
fn compile_string_trim_end_gc_arm(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  if pos_args.length() != 1 {
    raise WasmGenError::Unsupported("String::trim_end arity")
  }
  compile_string_trim_end_gc(ctx, fctx, buf, pos_args[0])
}

///|
fn compile_string_to_lower_gc_arm(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  if pos_args.length() != 1 {
    raise WasmGenError::Unsupported("String::to_lower arity")
  }
  compile_string_case_gc(ctx, fctx, buf, pos_args[0], 65, 90, 32)
}

///|
fn compile_string_to_upper_gc_arm(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  if pos_args.length() != 1 {
    raise WasmGenError::Unsupported("String::to_upper arity")
  }
  compile_string_case_gc(ctx, fctx, buf, pos_args[0], 97, 122, -32)
}

///|
fn compile_string_count_gc_arm(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  if pos_args.length() != 2 {
    raise WasmGenError::Unsupported("String::count arity")
  }
  compile_string_count_gc(ctx, fctx, buf, pos_args[0], pos_args[1])
}

///|
fn compile_string_replace_gc_arm(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  if pos_args.length() != 3 {
    raise WasmGenError::Unsupported("String::replace arity")
  }
  compile_string_replace(ctx, fctx, buf, pos_args[0], pos_args[1], pos_args[2])
}

///|
fn compile_string_split_gc_arm(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  if pos_args.length() != 2 {
    raise WasmGenError::Unsupported("String::split arity")
  }
  compile_string_split(ctx, fctx, buf, pos_args[0], pos_args[1])
}

///|
fn compile_string_from_char_code_gc_arm(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  compile_string_from_char_code_gc_inline(ctx, fctx, buf, pos_args)
}

///|
fn compile_string_from_char_codes_gc_arm(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  if pos_args.length() != 1 {
    raise WasmGenError::Unsupported("String::from_char_codes arity")
  }
  compile_string_from_char_codes_gc(ctx, fctx, buf, pos_args[0])
}

///|
/// Inline wasm-gc body for `String::from_char_code` (no dedicated impl fn).
fn compile_string_from_char_code_gc_inline(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  // Build 1-char string: struct(len=1, data=array[charcode])
  compile_expr_gc(ctx, fctx, buf, pos_args[0])
  let ck = infer_expr_kind_gc(ctx, fctx, pos_args[0])
  if ck == GcValKind::I64 {
    emit_i32_wrap_i64_gc(buf)
  }
  emit_array_new_fixed_gc(buf, ctx.array_i32_type, 1)
  let arr_idx = alloc_local_gc(fctx, GcValKind::Ref(ctx.array_i32_type))
  emit_local_set_gc(buf, arr_idx)
  emit_i32_const_gc(buf, 1)
  emit_local_get_gc(buf, arr_idx)
  emit_struct_new_gc(buf, ctx.string_type)
}

///|
fn compile_string_equals_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  let pos_args = extract_positional_exprs_with_arity(args, "String::equals", 2)
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
    // End of the 16-byte SIMD chunk region: left_len & ~15 (ADR-0054).
    let chunk_end_local = alloc_temp_local(ctx)
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
    // SIMD fast path (ADR-0054): compare 16 bytes per iteration with
    // v128.load + i8x16.eq + i8x16.all_true. On the first mismatching
    // chunk, set eq=0 and loop_i=left_len so both this loop and the
    // scalar tail exit. The chunk region is left_len & ~15; the trailing
    // (left_len & 15) bytes fall through to the scalar tail. The string
    // bytes live at memarg offset 8 (obj_string: tag@0, len@4, data@8).
    emit_local_get(buf, left_len_local)
    emit_i32_const_raw(buf, -16)
    emit_i32_and(buf)
    emit_local_set(buf, chunk_end_local)
    emit_block(buf)
    emit_loop(buf)
    emit_local_get(buf, loop_i_local)
    emit_local_get(buf, chunk_end_local)
    emit_i32_lt_s(buf)
    emit_i32_eqz(buf)
    emit_br_if(buf, 1)
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
    emit_i32_eqz(buf) // 1 if any byte in the chunk differs
    buf.push((4).to_byte()) // if (chunk mismatch)
    buf.push((64).to_byte()) // void
    emit_i32_const_raw(buf, 0)
    emit_local_set(buf, eq_local)
    emit_local_get(buf, left_len_local)
    emit_local_set(buf, loop_i_local)
    buf.push((5).to_byte()) // else
    emit_local_get(buf, loop_i_local)
    emit_i32_const_raw(buf, 16)
    emit_i32_add(buf)
    emit_local_set(buf, loop_i_local)
    buf.push((11).to_byte()) // end if
    emit_br(buf, 0)
    emit_end(buf) // end SIMD loop
    emit_end(buf) // end SIMD block
    // Scalar tail: remaining (left_len & 15) bytes one at a time.
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

///|
fn compile_string_index_of_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
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
    // SIMD memchr (ADR-0054): broadcast vector of the needle's first byte.
    let v_first_local = alloc_temp_local_with_kind(ctx, ValueKind::V128)
    // Flag: 1 when the current 16-byte window contains no candidate byte.
    let no_cand_local = alloc_temp_local(ctx)
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
    // SIMD memchr setup: broadcast the needle's first byte to all lanes.
    emit_local_get(buf, sub_ptr)
    emit_i32_load8_u(buf, 8)
    emit_i8x16_splat(buf)
    emit_local_set(buf, v_first_local)
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
    // SIMD memchr (ADR-0054): when sub_len>=1 and a full 16-byte window
    // fits, set no_cand=1 if none of its bytes equals sub[0]. Kept as a
    // single-level `if` (no branch out of nested ifs) so the value stack
    // and block nesting stay simple across the loop-continue below.
    emit_i32_const_raw(buf, 0)
    emit_local_set(buf, no_cand_local)
    emit_local_get(buf, sub_len)
    emit_i32_const_raw(buf, 1)
    emit_i32_ge_s(buf)
    emit_local_get(buf, outer_i)
    emit_i32_const_raw(buf, 16)
    emit_i32_add(buf)
    emit_local_get(buf, str_len)
    emit_i32_le_s(buf)
    emit_i32_and(buf)
    buf.push((4).to_byte()) // if (SIMD window applicable)
    buf.push((64).to_byte()) // void
    emit_local_get(buf, str_ptr)
    emit_local_get(buf, outer_i)
    emit_i32_add(buf)
    emit_v128_load_align(buf, 2, 8)
    emit_local_get(buf, v_first_local)
    emit_i8x16_eq(buf)
    emit_v128_any_true(buf)
    emit_i32_eqz(buf) // 1 if no byte in the window equals sub[0]
    emit_local_set(buf, no_cand_local)
    buf.push((11).to_byte()) // end if (SIMD window)
    // If the window has no candidate, skip 16 bytes and continue.
    emit_local_get(buf, no_cand_local)
    buf.push((4).to_byte()) // if (no candidate)
    buf.push((64).to_byte()) // void
    emit_local_get(buf, outer_i)
    emit_i32_const_raw(buf, 16)
    emit_i32_add(buf)
    emit_local_set(buf, outer_i)
    emit_br(buf, 1) // continue outer loop (if=0, loop=1)
    buf.push((11).to_byte()) // end if (no candidate)
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

///|
fn compile_string_contains_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
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
    // SIMD memchr (ADR-0054): broadcast vector of the needle's first byte.
    let v_first_local = alloc_temp_local_with_kind(ctx, ValueKind::V128)
    // Flag: 1 when the current 16-byte window contains no candidate byte.
    let no_cand_local = alloc_temp_local(ctx)
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
    // SIMD memchr setup: broadcast the needle's first byte to all lanes.
    emit_local_get(buf, sub_ptr)
    emit_i32_load8_u(buf, 8)
    emit_i8x16_splat(buf)
    emit_local_set(buf, v_first_local)
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
    // SIMD memchr (ADR-0054): when sub_len>=1 and a full 16-byte window
    // fits, set no_cand=1 if none of its bytes equals sub[0]. Kept as a
    // single-level `if` (no branch out of nested ifs) so the value stack
    // and block nesting stay simple across the loop-continue below.
    emit_i32_const_raw(buf, 0)
    emit_local_set(buf, no_cand_local)
    emit_local_get(buf, sub_len)
    emit_i32_const_raw(buf, 1)
    emit_i32_ge_s(buf)
    emit_local_get(buf, outer_i)
    emit_i32_const_raw(buf, 16)
    emit_i32_add(buf)
    emit_local_get(buf, str_len)
    emit_i32_le_s(buf)
    emit_i32_and(buf)
    buf.push((4).to_byte()) // if (SIMD window applicable)
    buf.push((64).to_byte()) // void
    emit_local_get(buf, str_ptr)
    emit_local_get(buf, outer_i)
    emit_i32_add(buf)
    emit_v128_load_align(buf, 2, 8)
    emit_local_get(buf, v_first_local)
    emit_i8x16_eq(buf)
    emit_v128_any_true(buf)
    emit_i32_eqz(buf) // 1 if no byte in the window equals sub[0]
    emit_local_set(buf, no_cand_local)
    buf.push((11).to_byte()) // end if (SIMD window)
    // If the window has no candidate, skip 16 bytes and continue.
    emit_local_get(buf, no_cand_local)
    buf.push((4).to_byte()) // if (no candidate)
    buf.push((64).to_byte()) // void
    emit_local_get(buf, outer_i)
    emit_i32_const_raw(buf, 16)
    emit_i32_add(buf)
    emit_local_set(buf, outer_i)
    emit_br(buf, 1) // continue outer loop (if=0, loop=1)
    buf.push((11).to_byte()) // end if (no candidate)
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

///|
fn compile_string_starts_with_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
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
    // SIMD chunk boundary: prefix_len & ~15 (ADR-0054).
    let chunk_end_local = alloc_temp_local(ctx)
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
    // SIMD fast path (ADR-0054): compare 16 bytes/iteration of the prefix.
    emit_local_get(buf, prefix_len_local)
    emit_i32_const_raw(buf, -16)
    emit_i32_and(buf)
    emit_local_set(buf, chunk_end_local)
    emit_block(buf)
    emit_loop(buf)
    emit_local_get(buf, loop_i_local)
    emit_local_get(buf, chunk_end_local)
    emit_i32_lt_s(buf)
    emit_i32_eqz(buf)
    emit_br_if(buf, 1)
    emit_local_get(buf, str_ptr_local)
    emit_local_get(buf, loop_i_local)
    emit_i32_add(buf)
    emit_v128_load_align(buf, 2, 8)
    emit_local_get(buf, prefix_ptr_local)
    emit_local_get(buf, loop_i_local)
    emit_i32_add(buf)
    emit_v128_load_align(buf, 2, 8)
    emit_i8x16_eq(buf)
    emit_i8x16_all_true(buf)
    emit_i32_eqz(buf) // 1 if any byte in the chunk differs
    buf.push((4).to_byte()) // if (chunk mismatch)
    buf.push((64).to_byte())
    emit_i32_const_raw(buf, 0)
    emit_local_set(buf, result_local)
    emit_local_get(buf, prefix_len_local)
    emit_local_set(buf, loop_i_local)
    buf.push((5).to_byte()) // else
    emit_local_get(buf, loop_i_local)
    emit_i32_const_raw(buf, 16)
    emit_i32_add(buf)
    emit_local_set(buf, loop_i_local)
    buf.push((11).to_byte()) // end if
    emit_br(buf, 0)
    emit_end(buf) // end SIMD loop
    emit_end(buf) // end SIMD block
    // Scalar tail: remaining (prefix_len & 15) bytes.
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

///|
fn compile_string_ends_with_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
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
    // SIMD chunk boundary: suffix_len & ~15 (ADR-0054).
    let chunk_end_local = alloc_temp_local(ctx)
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
    // SIMD fast path (ADR-0054): compare 16 bytes/iteration of the suffix
    // (str window starts at start_local = str_len - suffix_len).
    emit_local_get(buf, suffix_len_local)
    emit_i32_const_raw(buf, -16)
    emit_i32_and(buf)
    emit_local_set(buf, chunk_end_local)
    emit_block(buf)
    emit_loop(buf)
    emit_local_get(buf, loop_i_local)
    emit_local_get(buf, chunk_end_local)
    emit_i32_lt_s(buf)
    emit_i32_eqz(buf)
    emit_br_if(buf, 1)
    emit_local_get(buf, str_ptr_local)
    emit_local_get(buf, start_local)
    emit_i32_add(buf)
    emit_local_get(buf, loop_i_local)
    emit_i32_add(buf)
    emit_v128_load_align(buf, 2, 8)
    emit_local_get(buf, suffix_ptr_local)
    emit_local_get(buf, loop_i_local)
    emit_i32_add(buf)
    emit_v128_load_align(buf, 2, 8)
    emit_i8x16_eq(buf)
    emit_i8x16_all_true(buf)
    emit_i32_eqz(buf) // 1 if any byte in the chunk differs
    buf.push((4).to_byte()) // if (chunk mismatch)
    buf.push((64).to_byte())
    emit_i32_const_raw(buf, 0)
    emit_local_set(buf, result_local)
    emit_local_get(buf, suffix_len_local)
    emit_local_set(buf, loop_i_local)
    buf.push((5).to_byte()) // else
    emit_local_get(buf, loop_i_local)
    emit_i32_const_raw(buf, 16)
    emit_i32_add(buf)
    emit_local_set(buf, loop_i_local)
    buf.push((11).to_byte()) // end if
    emit_br(buf, 0)
    emit_end(buf) // end SIMD loop
    emit_end(buf) // end SIMD block
    // Scalar tail: remaining (suffix_len & 15) bytes.
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

///|
fn compile_string_last_index_of_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
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

///|
fn compile_string_count_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  // string_count(str, sub) -> Int (non-overlapping count)
  let pos_args = extract_positional_exprs_with_arity(args, "String::count", 2)
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

///|
fn compile_string_trim_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  // string_trim(str) -> String (trim ASCII whitespace from both ends)
  let pos_args = extract_positional_exprs_with_arity(args, "String::trim", 1)
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

///|
fn compile_string_trim_start_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
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

///|
fn compile_string_trim_end_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
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

///|
fn compile_string_to_upper_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
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

///|
fn compile_string_to_lower_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
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

///|
fn compile_string_replace_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  // string_replace(str, pattern, replacement) -> String (replace first occurrence)
  let pos_args = extract_positional_exprs_with_arity(args, "String::replace", 3)
  if ctx.use_js_strings {
    raise WasmGenError::BackendLimit(
      backend="wasm-js-string",
      feature="String::replace",
    )
  } else {
    emit_string_replace_impl(ctx, buf, pos_args, replace_all=false)
  }
}

///|
fn compile_string_split_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  // string_split(str, delimiter) -> Array[String]
  let pos_args = extract_positional_exprs_with_arity(args, "String::split", 2)
  if ctx.use_js_strings {
    raise WasmGenError::BackendLimit(
      backend="wasm-js-string",
      feature="String::split",
    )
  } else {
    emit_string_split_impl(ctx, buf, pos_args)
  }
}

///|
fn compile_string_from_char_code_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
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

///|
fn compile_string_from_char_codes_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  let pos_args = extract_positional_exprs_with_arity(
    args, "String::from_char_codes", 1,
  )
  require_heap(ctx)
  let arr_ptr_local = alloc_temp_local(ctx)
  let data_ptr_local = alloc_temp_local(ctx)
  let start_local = alloc_temp_local(ctx)
  let arr_len_local = alloc_temp_local(ctx)
  let alloc_size_local = alloc_temp_local(ctx)
  let obj_local = alloc_temp_local(ctx)
  let loop_i_local = alloc_temp_local(ctx)
  compile_expr_i32(ctx, buf, pos_args[0])
  emit_untag_ptr_i32(buf)
  emit_local_set(buf, arr_ptr_local)
  emit_local_get(buf, arr_ptr_local)
  emit_i32_load(buf, 0)
  emit_i32_const_raw(buf, obj_array_view)
  emit_i32_eq(buf)
  buf.push((4).to_byte()) // if array view
  buf.push((64).to_byte()) // void
  emit_local_get(buf, arr_ptr_local)
  emit_i32_load(buf, 4)
  emit_local_set(buf, data_ptr_local)
  emit_local_get(buf, arr_ptr_local)
  emit_i32_load(buf, 8)
  emit_local_set(buf, start_local)
  emit_local_get(buf, arr_ptr_local)
  emit_i32_load(buf, 12)
  emit_local_get(buf, start_local)
  emit_i32_sub(buf)
  emit_local_set(buf, arr_len_local)
  buf.push((5).to_byte()) // else regular array
  emit_local_get(buf, arr_ptr_local)
  emit_local_set(buf, data_ptr_local)
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, start_local)
  emit_local_get(buf, arr_ptr_local)
  emit_i32_load(buf, 4)
  emit_local_set(buf, arr_len_local)
  buf.push((11).to_byte()) // end if
  emit_local_get(buf, arr_len_local)
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
  emit_local_get(buf, arr_len_local)
  emit_i32_store(buf, 4)
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, loop_i_local)
  emit_block(buf)
  emit_loop(buf)
  emit_local_get(buf, loop_i_local)
  emit_local_get(buf, arr_len_local)
  emit_i32_ge_s(buf)
  emit_br_if(buf, 1)
  emit_local_get(buf, obj_local)
  emit_i32_const_raw(buf, 8)
  emit_i32_add(buf)
  emit_local_get(buf, loop_i_local)
  emit_i32_add(buf)
  emit_local_get(buf, data_ptr_local)
  emit_local_get(buf, start_local)
  emit_local_get(buf, loop_i_local)
  emit_i32_add(buf)
  emit_i32_const_raw(buf, 4)
  emit_i32_mul(buf)
  emit_i32_add(buf)
  emit_i32_load(buf, 8)
  emit_i64_extend_i32_s(buf)
  emit_untag_int_i32(buf)
  emit_i32_store8(buf, 0)
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
