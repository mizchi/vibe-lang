///|
/// Phase B-1 (Issue #415): `Bytes::` namespace migrated off the two legacy
/// `match name` dispatchers (`wasm_codegen_builtin_io.mbt` linear arms and
/// `wasm_gc_codegen.mbt::Call`) onto the shared `migrated_builtin` table in
/// `builtin_registry.mbt`. The linear bodies are relocated verbatim from the
/// io.mbt arms; the wasm-gc bodies replicate each gc arm (arity check, if
/// present, then the delegated `compile_bytes_*_gc` call).

///|
fn compile_bytes_from_array_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
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

///|
fn compile_bytes_from_array_gc_arm(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  if pos_args.length() != 1 {
    raise WasmGenError::Unsupported("Bytes::from_array arity")
  }
  compile_bytes_from_array_gc(ctx, fctx, buf, pos_args[0])
}

///|
fn compile_bytes_from_string_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
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

///|
fn compile_bytes_from_string_gc_arm(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  if pos_args.length() != 1 {
    raise WasmGenError::Unsupported("Bytes::from_string arity")
  }
  compile_bytes_from_string_gc(ctx, fctx, buf, pos_args[0])
}

///|
fn compile_bytes_to_string_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
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
  emit_bytes_load_header(ctx, buf, src_local, len_local, cap_local, data_local)
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
  // Use heap_local; bumping heap_global directly desynchronizes
  // ctx.heap_local and overlaps subsequent allocations.
  emit_heap_alloc_local(ctx, buf, alloc_size_local, obj_local)
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

///|
fn compile_bytes_to_string_gc_arm(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  if pos_args.length() != 1 {
    raise WasmGenError::Unsupported("Bytes::to_string arity")
  }
  compile_bytes_to_string_gc(ctx, fctx, buf, pos_args[0])
}

///|
fn compile_bytes_length_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  // bytes_length(bytes) -> Int (tagged)
  // Supports both raw Bytes and BytesView via emit_bytes_load_header
  let pos_args = extract_positional_exprs_with_arity(args, "Bytes::length", 1)
  let ptr_local = alloc_temp_local(ctx)
  let len_local = alloc_temp_local(ctx)
  let cap_local = alloc_temp_local(ctx)
  let data_local = alloc_temp_local(ctx)
  compile_expr_i32(ctx, buf, pos_args[0])
  emit_untag_ptr_i32(buf)
  emit_local_set(buf, ptr_local)
  emit_bytes_load_header(ctx, buf, ptr_local, len_local, cap_local, data_local)
  emit_local_get(buf, len_local)
  emit_i64_extend_i32_u(buf)
  emit_i64_const_raw(buf, 2L)
  emit_i64_shl(buf) // tag as int
}

///|
fn compile_bytes_length_gc_arm(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  if pos_args.length() != 1 {
    raise WasmGenError::Unsupported("Bytes::length arity")
  }
  compile_bytes_length_gc(ctx, fctx, buf, pos_args[0])
}

///|
fn compile_bytes_get_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
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
  emit_bytes_load_header(ctx, buf, ptr_local, len_local, cap_local, data_local)
  emit_local_get(buf, data_local)
  emit_local_get(buf, idx_local)
  emit_i32_add(buf)
  emit_i32_load8_u(buf, 0)
  emit_i64_extend_i32_u(buf)
  emit_i64_const_raw(buf, 2L)
  emit_i64_shl(buf) // tag as int
}

///|
fn compile_bytes_get_gc_arm(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  if pos_args.length() != 2 {
    raise WasmGenError::Unsupported("Bytes::get arity")
  }
  compile_bytes_get_gc(ctx, fctx, buf, pos_args[0], pos_args[1])
}

///|
fn compile_bytes_new_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  _args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
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

///|
fn compile_bytes_new_gc_arm(
  ctx : GcCodegenCtx,
  _fctx : GcFuncCtx,
  buf : GcByteBuf,
  _pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  compile_bytes_new_gc(ctx, buf)
}

///|
fn compile_bytes_push_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
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

///|
fn compile_bytes_push_gc_arm(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  if pos_args.length() != 2 {
    raise WasmGenError::Unsupported("Bytes::push arity")
  }
  compile_bytes_push_gc(ctx, fctx, buf, pos_args[0], pos_args[1])
}

///|
fn compile_bytes_set_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
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

///|
fn compile_bytes_set_gc_arm(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  if pos_args.length() != 3 {
    raise WasmGenError::Unsupported("Bytes::set arity")
  }
  compile_bytes_set_gc(ctx, fctx, buf, pos_args[0], pos_args[1], pos_args[2])
}

///|
fn compile_bytes_append_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  // Bytes::append(dst, src) -> append all bytes from src to dst (mutating)
  // Uses memory.copy for efficiency
  let pos_args = extract_positional_exprs_with_arity(args, "Bytes::append", 2)
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

///|
fn compile_bytes_append_gc_arm(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  if pos_args.length() != 2 {
    raise WasmGenError::Unsupported("Bytes::append arity")
  }
  compile_bytes_append_gc(ctx, fctx, buf, pos_args[0], pos_args[1])
}

///|
fn compile_bytes_blit_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
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

///|
fn compile_bytes_blit_gc_arm(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  if pos_args.length() != 4 {
    raise WasmGenError::Unsupported("Bytes::blit arity")
  }
  compile_bytes_blit_gc(
    ctx,
    fctx,
    buf,
    pos_args[0],
    pos_args[1],
    pos_args[2],
    pos_args[3],
  )
}

///|
fn compile_bytes_fill_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
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

///|
fn compile_bytes_fill_gc_arm(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  if pos_args.length() != 3 {
    raise WasmGenError::Unsupported("Bytes::fill arity")
  }
  compile_bytes_fill_gc(ctx, fctx, buf, pos_args[0], pos_args[1], pos_args[2])
}

///|
fn compile_bytes_slice_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  // Bytes::slice(bytes, start, end) -> zero-copy BytesView.
  let pos_args = extract_positional_exprs_with_arity(args, "Bytes::slice", 3)
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

///|
fn compile_bytes_slice_gc_arm(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  if pos_args.length() != 3 {
    raise WasmGenError::Unsupported("Bytes::slice arity")
  }
  compile_bytes_slice_gc(ctx, fctx, buf, pos_args[0], pos_args[1], pos_args[2])
}

///|
fn compile_bytes_concat_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  // Bytes::concat(a, b) -> new array with a's elements followed by b's
  let pos_args = extract_positional_exprs_with_arity(args, "Bytes::concat", 2)
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

///|
fn compile_bytes_concat_gc_arm(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  if pos_args.length() != 2 {
    raise WasmGenError::Unsupported("Bytes::concat arity")
  }
  compile_bytes_concat_gc(ctx, fctx, buf, pos_args[0], pos_args[1])
}

///|
fn compile_bytes_to_array_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  // Bytes::to_array(bytes) -> Array[Int] (unpack: load8_u, <<2, store i32)
  let pos_args = extract_positional_exprs_with_arity(args, "Bytes::to_array", 1)
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
  emit_bytes_load_header(ctx, buf, src_local, len_local, cap_local, data_local)
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
  // See `Bytes::to_string` above — bumping heap_global directly
  // leaves ctx.heap_local stale.
  emit_heap_alloc_local(ctx, buf, alloc_size_local, dst_local)
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

///|
fn compile_bytes_to_array_gc_arm(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  if pos_args.length() != 1 {
    raise WasmGenError::Unsupported("Bytes::to_array arity")
  }
  compile_bytes_to_array_gc(ctx, fctx, buf, pos_args[0])
}
