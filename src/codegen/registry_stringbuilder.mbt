///|
/// Phase B-1 (Issue #415): `StringBuilder::` namespace migrated off the two
/// legacy `match name` dispatchers (`wasm_codegen_builtin_string.mbt` linear
/// arms and `wasm_gc_codegen.mbt::Call`) onto the shared `migrated_builtin`
/// table in `builtin_registry.mbt`. The linear bodies are relocated verbatim
/// from the string.mbt arms; the wasm-gc bodies are relocated verbatim from
/// the inline gc arms (NOT thin delegates — they carry the struct/array type
/// setup and grow/copy loops). No `!is_user_fn` guard (matches the legacy
/// arms), so `mig`.

///|
fn compile_string_builder_new_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  _args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  // string_builder() -> allocate empty array obj with len=0 (same layout as array_builder)
  // Uses hidden capacity prefix at obj_ptr-4 for grow-on-overflow in push.
  let obj_local = alloc_temp_local(ctx)
  emit_builder_alloc(ctx, buf, builder_initial_cap, 4, obj_array, obj_local)
  emit_local_get(buf, obj_local)
  emit_i64_extend_i32_u(buf)
  emit_i64_const_raw(buf, tag_obj.to_int64())
  emit_i64_or(buf)
}

///|
fn compile_string_builder_new_gc_arm(
  ctx : GcCodegenCtx,
  _fctx : GcFuncCtx,
  buf : GcByteBuf,
  _pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  let init_cap = 8
  let arr_type = ensure_array_type(
    ctx.types,
    ctx.array_type_index,
    GcValKind::Ref(ctx.string_type),
  )
  let builder_fields : Array[GcValKind] = [
    GcValKind::I32,
    GcValKind::Ref(arr_type),
  ]
  let builder_type = ensure_struct_type(
    ctx.types,
    ctx.struct_type_index,
    builder_fields,
  )
  let _ = builder_type
  emit_i32_const_gc(buf, 0)
  emit_i32_const_gc(buf, init_cap)
  emit_array_new_default_gc(buf, arr_type)
  emit_struct_new_gc(buf, builder_type)
}

///|
fn compile_string_builder_push_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  // string_builder_push(builder, value) -> same layout as array_builder_push
  // Grows capacity when full (heap-tip extension or trap).
  let pos_args = extract_positional_exprs_with_arity(
    args, "StringBuilder::push", 2,
  )
  let builder_local = alloc_temp_local(ctx)
  let ptr_local = alloc_temp_local(ctx)
  compile_expr_i32(ctx, buf, pos_args[0])
  emit_untag_ptr_i32(buf)
  emit_local_tee(buf, builder_local)
  emit_local_set(buf, ptr_local)
  // Bounds check + grow if needed (elem_size=4)
  emit_builder_grow_check(ctx, buf, ptr_local, 4)
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

///|
fn compile_string_builder_push_gc_arm(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  if pos_args.length() != 2 {
    raise WasmGenError::Unsupported("StringBuilder::push arity")
  }
  let arr_type = ensure_array_type(
    ctx.types,
    ctx.array_type_index,
    GcValKind::Ref(ctx.string_type),
  )
  let builder_fields : Array[GcValKind] = [
    GcValKind::I32,
    GcValKind::Ref(arr_type),
  ]
  let builder_type = ensure_struct_type(
    ctx.types,
    ctx.struct_type_index,
    builder_fields,
  )
  let builder_kind = GcValKind::Ref(builder_type)
  let b_l = alloc_local_gc(fctx, builder_kind)
  let len_l = alloc_local_gc(fctx, GcValKind::I32)
  let cap_l = alloc_local_gc(fctx, GcValKind::I32)
  let data_l = alloc_local_gc(fctx, GcValKind::Ref(arr_type))
  let new_data_l = alloc_local_gc(fctx, GcValKind::Ref(arr_type))
  let i_l = alloc_local_gc(fctx, GcValKind::I32)
  compile_expr_gc(ctx, fctx, buf, pos_args[0])
  emit_local_set_gc(buf, b_l)
  emit_local_get_gc(buf, b_l)
  emit_struct_get_gc(buf, builder_type, 0)
  emit_local_set_gc(buf, len_l)
  emit_local_get_gc(buf, b_l)
  emit_struct_get_gc(buf, builder_type, 1)
  emit_local_tee_gc(buf, data_l)
  emit_array_len_gc(buf)
  emit_local_set_gc(buf, cap_l)
  // grow if needed
  emit_local_get_gc(buf, len_l)
  emit_local_get_gc(buf, cap_l)
  emit_i32_ge_s_gc(buf)
  emit_if_gc(buf, None)
  // new_cap = max(cap * 2, 1)
  emit_local_get_gc(buf, cap_l)
  emit_i32_const_gc(buf, 2)
  emit_i32_mul_gc(buf)
  emit_local_tee_gc(buf, cap_l)
  emit_i32_const_gc(buf, 0)
  emit_i32_eq_gc(buf)
  emit_if_gc(buf, Some(GcValKind::I32))
  emit_i32_const_gc(buf, 1)
  emit_else_gc(buf)
  emit_local_get_gc(buf, cap_l)
  emit_end_gc(buf)
  emit_array_new_default_gc(buf, arr_type)
  emit_local_set_gc(buf, new_data_l)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, i_l)
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, i_l)
  emit_local_get_gc(buf, len_l)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1)
  emit_local_get_gc(buf, new_data_l)
  emit_local_get_gc(buf, i_l)
  emit_local_get_gc(buf, data_l)
  emit_local_get_gc(buf, i_l)
  emit_array_get_gc(buf, arr_type)
  emit_array_set_gc(buf, arr_type)
  emit_local_get_gc(buf, i_l)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, i_l)
  emit_br_gc(buf, 0)
  emit_end_gc(buf)
  emit_end_gc(buf)
  emit_local_get_gc(buf, b_l)
  emit_local_get_gc(buf, new_data_l)
  emit_struct_set_gc(buf, builder_type, 1)
  emit_local_get_gc(buf, new_data_l)
  emit_local_set_gc(buf, data_l)
  emit_end_gc(buf)
  // data[len] = value
  emit_local_get_gc(buf, data_l)
  emit_local_get_gc(buf, len_l)
  compile_expr_gc(ctx, fctx, buf, pos_args[1])
  emit_array_set_gc(buf, arr_type)
  // len += 1
  emit_local_get_gc(buf, b_l)
  emit_local_get_gc(buf, len_l)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_struct_set_gc(buf, builder_type, 0)
  // Unit result
  emit_i32_const_gc(buf, 0)
}

///|
fn compile_string_builder_freeze_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
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
  // Follow forwarding pointer if builder was relocated by push realloc
  emit_builder_follow_forwarding(ctx, buf, builder_ptr)
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

///|
fn compile_string_builder_freeze_gc_arm(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  if pos_args.length() != 1 {
    raise WasmGenError::Unsupported("StringBuilder::freeze arity")
  }
  let arr_type = ensure_array_type(
    ctx.types,
    ctx.array_type_index,
    GcValKind::Ref(ctx.string_type),
  )
  let builder_fields : Array[GcValKind] = [
    GcValKind::I32,
    GcValKind::Ref(arr_type),
  ]
  let builder_type = ensure_struct_type(
    ctx.types,
    ctx.struct_type_index,
    builder_fields,
  )
  let b_l = alloc_local_gc(fctx, GcValKind::Ref(builder_type))
  let len_l = alloc_local_gc(fctx, GcValKind::I32)
  let data_l = alloc_local_gc(fctx, GcValKind::Ref(arr_type))
  let total_l = alloc_local_gc(fctx, GcValKind::I32)
  let out_data_l = alloc_local_gc(fctx, GcValKind::Ref(ctx.array_i32_type))
  let i_l = alloc_local_gc(fctx, GcValKind::I32)
  let cur_s_l = alloc_local_gc(fctx, GcValKind::Ref(ctx.string_type))
  let cur_len_l = alloc_local_gc(fctx, GcValKind::I32)
  let cur_data_l = alloc_local_gc(fctx, GcValKind::Ref(ctx.array_i32_type))
  let write_l = alloc_local_gc(fctx, GcValKind::I32)
  let j_l = alloc_local_gc(fctx, GcValKind::I32)
  compile_expr_gc(ctx, fctx, buf, pos_args[0])
  emit_local_set_gc(buf, b_l)
  emit_local_get_gc(buf, b_l)
  emit_struct_get_gc(buf, builder_type, 0)
  emit_local_set_gc(buf, len_l)
  emit_local_get_gc(buf, b_l)
  emit_struct_get_gc(buf, builder_type, 1)
  emit_local_set_gc(buf, data_l)
  // Pass 1: total = sum of each string's len
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, total_l)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, i_l)
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, i_l)
  emit_local_get_gc(buf, len_l)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1)
  emit_local_get_gc(buf, data_l)
  emit_local_get_gc(buf, i_l)
  emit_array_get_gc(buf, arr_type)
  emit_local_tee_gc(buf, cur_s_l)
  emit_struct_get_gc(buf, ctx.string_type, 0)
  emit_local_get_gc(buf, total_l)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, total_l)
  emit_local_get_gc(buf, i_l)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, i_l)
  emit_br_gc(buf, 0)
  emit_end_gc(buf)
  emit_end_gc(buf)
  // Allocate output array<i32> of total_l codepoints
  emit_local_get_gc(buf, total_l)
  emit_array_new_default_gc(buf, ctx.array_i32_type)
  emit_local_set_gc(buf, out_data_l)
  // Pass 2: copy each string's data
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, write_l)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, i_l)
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, i_l)
  emit_local_get_gc(buf, len_l)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1)
  emit_local_get_gc(buf, data_l)
  emit_local_get_gc(buf, i_l)
  emit_array_get_gc(buf, arr_type)
  emit_local_set_gc(buf, cur_s_l)
  emit_local_get_gc(buf, cur_s_l)
  emit_struct_get_gc(buf, ctx.string_type, 0)
  emit_local_set_gc(buf, cur_len_l)
  emit_local_get_gc(buf, cur_s_l)
  emit_struct_get_gc(buf, ctx.string_type, 1)
  emit_local_set_gc(buf, cur_data_l)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, j_l)
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, j_l)
  emit_local_get_gc(buf, cur_len_l)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1)
  emit_local_get_gc(buf, out_data_l)
  emit_local_get_gc(buf, write_l)
  emit_local_get_gc(buf, j_l)
  emit_i32_add_gc(buf)
  emit_local_get_gc(buf, cur_data_l)
  emit_local_get_gc(buf, j_l)
  emit_array_get_gc(buf, ctx.array_i32_type)
  emit_array_set_gc(buf, ctx.array_i32_type)
  emit_local_get_gc(buf, j_l)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, j_l)
  emit_br_gc(buf, 0)
  emit_end_gc(buf)
  emit_end_gc(buf)
  emit_local_get_gc(buf, write_l)
  emit_local_get_gc(buf, cur_len_l)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, write_l)
  emit_local_get_gc(buf, i_l)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, i_l)
  emit_br_gc(buf, 0)
  emit_end_gc(buf)
  emit_end_gc(buf)
  // Construct result String { len, data }
  emit_local_get_gc(buf, total_l)
  emit_local_get_gc(buf, out_data_l)
  emit_struct_new_gc(buf, ctx.string_type)
}
