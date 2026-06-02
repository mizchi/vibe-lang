///|
/// Phase B-1 (Issue #415): `Map::` namespace migrated off the two legacy
/// `match name` dispatchers (`wasm_codegen_builtin_collection.mbt` linear arms
/// and `wasm_gc_codegen.mbt::Call`) onto the shared `migrated_builtin` table in
/// `builtin_registry.mbt`. Map is the hardest namespace, so only the cleanly
/// tractable arms are migrated here; the rest stay legacy (see the parity gate
/// notes in `builtin_registry.mbt`).
///
/// For Map the wasm-gc bodies are inline in the legacy `match name`, so they
/// are relocated verbatim here (not thin delegates like `Bytes::`).

///|
fn compile_map_iter_length_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  // Map::iter_length(map) -> map length without allocating Map::keys.
  let pos_args = extract_positional_exprs_with_arity(
    args, "Map::iter_length", 1,
  )
  let map_ptr = alloc_temp_local(ctx)
  compile_expr_i32(ctx, buf, pos_args[0])
  emit_untag_ptr_i32(buf)
  emit_local_set(buf, map_ptr)
  emit_builder_follow_forwarding(ctx, buf, map_ptr)
  emit_local_get(buf, map_ptr)
  emit_i32_load(buf, 4)
  emit_i64_extend_i32_s(buf)
  emit_i64_const_raw(buf, 2L)
  emit_i64_shl(buf)
}

///|
fn compile_map_iter_length_gc_arm(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  if pos_args.length() != 1 {
    raise WasmGenError::Unsupported("Map::iter_length arity")
  }
  let (builder_type, _, _) = ensure_map_builder_type_gc(ctx)
  compile_expr_gc(ctx, fctx, buf, pos_args[0])
  emit_struct_get_gc(buf, builder_type, 0)
  emit_i64_extend_i32_s_gc(buf)
}

///|
fn compile_map_get_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  // map_get(map, key) -> linear search for key, return value
  let pos_args = extract_positional_exprs_with_arity(args, "Map::get", 2)
  let map_ptr = alloc_temp_local(ctx)
  let map_len = alloc_temp_local(ctx)
  let loop_i = alloc_temp_local(ctx)
  let result_local = alloc_temp_local(ctx)
  compile_expr_i32(ctx, buf, pos_args[0])
  emit_untag_ptr_i32(buf)
  emit_local_set(buf, map_ptr)
  emit_builder_follow_forwarding(ctx, buf, map_ptr)
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

///|
fn compile_map_get_gc_arm(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  // Map::get(map, key) -> eqref (null eqref if not found)
  if pos_args.length() != 2 {
    raise WasmGenError::Unsupported("Map::get arity")
  }
  let key_arr_type = ensure_array_type(
    ctx.types,
    ctx.array_type_index,
    GcValKind::EqRef,
  )
  let val_arr_type = ensure_array_type(
    ctx.types,
    ctx.array_type_index,
    GcValKind::EqRef,
  )
  let builder_fields : Array[GcValKind] = [
    GcValKind::I32,
    GcValKind::Ref(key_arr_type),
    GcValKind::Ref(val_arr_type),
  ]
  let builder_type = ensure_struct_type(
    ctx.types,
    ctx.struct_type_index,
    builder_fields,
  )
  let b_idx = alloc_local_gc(fctx, GcValKind::Ref(builder_type))
  let len_l = alloc_local_gc(fctx, GcValKind::I32)
  let keys_l = alloc_local_gc(fctx, GcValKind::Ref(key_arr_type))
  let vals_l = alloc_local_gc(fctx, GcValKind::Ref(val_arr_type))
  let i_l = alloc_local_gc(fctx, GcValKind::I32)
  let key_l = alloc_local_gc(fctx, GcValKind::EqRef)
  let result_l = alloc_local_gc(fctx, GcValKind::EqRef)
  compile_expr_gc(ctx, fctx, buf, pos_args[0])
  emit_local_set_gc(buf, b_idx)
  // Box key to eqref (handles int keys, string keys, etc.)
  let get_key_kind = infer_expr_kind_gc(ctx, fctx, pos_args[1])
  compile_expr_gc(ctx, fctx, buf, pos_args[1])
  emit_box_top_for_ref_kind_gc(ctx, buf, get_key_kind, GcValKind::EqRef)
  emit_local_set_gc(buf, key_l)
  emit_local_get_gc(buf, b_idx)
  emit_struct_get_gc(buf, builder_type, 0)
  emit_local_set_gc(buf, len_l)
  emit_local_get_gc(buf, b_idx)
  emit_struct_get_gc(buf, builder_type, 1)
  emit_local_set_gc(buf, keys_l)
  emit_local_get_gc(buf, b_idx)
  emit_struct_get_gc(buf, builder_type, 2)
  emit_local_set_gc(buf, vals_l)
  // Linear search with result in local
  // result_l defaults to null eqref (not found)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, i_l)
  // block $done
  emit_block_gc(buf, None)
  // loop $search
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, i_l)
  emit_local_get_gc(buf, len_l)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1) // br $done (not found)
  let cur_key_get = alloc_local_gc(fctx, GcValKind::EqRef)
  emit_local_get_gc(buf, keys_l)
  emit_local_get_gc(buf, i_l)
  emit_array_get_gc(buf, key_arr_type)
  emit_local_set_gc(buf, cur_key_get)
  emit_map_key_eq_gc(ctx, fctx, buf, cur_key_get, key_l)
  emit_if_gc(buf, None)
  // Found: store vals[i] and break
  emit_local_get_gc(buf, vals_l)
  emit_local_get_gc(buf, i_l)
  emit_array_get_gc(buf, val_arr_type)
  emit_local_set_gc(buf, result_l)
  emit_br_gc(buf, 2) // br $done
  emit_end_gc(buf) // end if
  emit_local_get_gc(buf, i_l)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, i_l)
  emit_br_gc(buf, 0) // br $search
  emit_end_gc(buf) // end loop
  emit_end_gc(buf) // end $done
  // result_l has the boxed value (or null eqref if not found)
  emit_local_get_gc(buf, result_l)
}

///|
fn compile_map_set_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  // Map::set(map, key, value) -> new map with key=value set (immutable)
  let pos_args = extract_positional_exprs_with_arity(args, "Map::set", 3)
  require_heap(ctx)
  let max_cap = 128
  let src_ptr = alloc_temp_local(ctx)
  let src_len = alloc_temp_local(ctx)
  let dst_ptr = alloc_temp_local(ctx)
  let loop_i = alloc_temp_local(ctx)
  let found_local = alloc_temp_local(ctx)
  let new_len = alloc_temp_local(ctx)
  let val_local = alloc_temp_local(ctx)
  // load source map
  compile_expr_i32(ctx, buf, pos_args[0])
  emit_untag_ptr_i32(buf)
  emit_local_set(buf, src_ptr)
  emit_local_get(buf, src_ptr)
  emit_i32_load(buf, 4)
  emit_local_set(buf, src_len)
  // capacity guard: trap if src_len >= max_cap
  emit_local_get(buf, src_len)
  emit_i32_const_raw(buf, max_cap)
  emit_i32_ge_s(buf)
  buf.push((4).to_byte()) // if
  buf.push((64).to_byte()) // void
  buf.push((0).to_byte()) // unreachable (trap)
  buf.push((11).to_byte()) // end if
  // pre-compile value to local
  compile_expr_i32(ctx, buf, pos_args[2])
  emit_i32_wrap_i64(buf)
  emit_local_set(buf, val_local)
  // allocate new map obj
  let size = align4(8 + max_cap * 8)
  emit_heap_alloc(ctx, buf, size, dst_ptr)
  // set tag
  emit_local_get(buf, dst_ptr)
  emit_i32_const_raw(buf, obj_map)
  emit_i32_store(buf, 0)
  // copy entries using memory.copy
  emit_local_get(buf, dst_ptr)
  emit_i32_const_raw(buf, 8)
  emit_i32_add(buf)
  emit_local_get(buf, src_ptr)
  emit_i32_const_raw(buf, 8)
  emit_i32_add(buf)
  emit_local_get(buf, src_len)
  emit_i32_const_raw(buf, 3)
  emit_i32_shl(buf)
  emit_memory_copy(buf)
  // search for existing key and update value if found
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
      // update value in copy
      emit_local_get(buf, dst_ptr)
      emit_local_get(buf, loop_i)
      emit_i32_const_raw(buf, 3)
      emit_i32_shl(buf)
      emit_i32_add(buf)
      emit_local_get(buf, val_local)
      emit_i32_store(buf, 12)
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
      emit_local_get(buf, dst_ptr)
      emit_local_get(buf, src_len)
      emit_i32_const_raw(buf, 3)
      emit_i32_shl(buf)
      emit_i32_add(buf)
      emit_local_get(buf, val_local)
      emit_i32_store(buf, 12)
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
      // update value in copy
      emit_local_get(buf, dst_ptr)
      emit_local_get(buf, loop_i)
      emit_i32_const_raw(buf, 3)
      emit_i32_shl(buf)
      emit_i32_add(buf)
      emit_local_get(buf, val_local)
      emit_i32_store(buf, 12)
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
      emit_local_get(buf, val_local)
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
    // Strip `tag_obj` to match the map literal's storage convention
    // (`compile_map_expr` stores `ctx.strings.intern(key)` raw). `__index`
    // compares the entry slot against the raw interned offset via
    // `i32.eq`, so any tagged value stored here would silently fail the
    // lookup (e.g. `Map::set(map { "a": 1 }, "b", 2)` then `m2["b"]`).
    emit_i32_const_raw(buf, -4)
    emit_i32_and(buf)
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
    // update value in copy
    emit_local_get(buf, dst_ptr)
    emit_local_get(buf, loop_i)
    emit_i32_const_raw(buf, 3)
    emit_i32_shl(buf)
    emit_i32_add(buf)
    emit_local_get(buf, val_local)
    emit_i32_store(buf, 12)
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
    emit_local_get(buf, val_local)
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

///|
fn compile_map_set_gc_arm(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  if pos_args.length() != 3 {
    raise WasmGenError::Unsupported("Map::set arity")
  }
  compile_map_set_gc(ctx, fctx, buf, pos_args)
}

///|
fn compile_map_delete_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  // Map::delete(map, key) -> new map without key (immutable)
  let pos_args = extract_positional_exprs_with_arity(args, "Map::delete", 2)
  require_heap(ctx)
  let max_cap = 128
  let src_ptr = alloc_temp_local(ctx)
  let src_len = alloc_temp_local(ctx)
  let dst_ptr = alloc_temp_local(ctx)
  let loop_i = alloc_temp_local(ctx)
  let dst_len = alloc_temp_local(ctx)
  // load source map
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

///|
fn compile_map_delete_gc_arm(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  if pos_args.length() != 2 {
    raise WasmGenError::Unsupported("Map::delete arity")
  }
  compile_map_delete_gc(ctx, fctx, buf, pos_args)
}

///|
fn compile_map_has_key_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  // map_has_key(map, key) -> linear search for key, return tagged bool
  let pos_args = extract_positional_exprs_with_arity(args, "Map::has_key", 2)
  let map_ptr = alloc_temp_local(ctx)
  let map_len = alloc_temp_local(ctx)
  let loop_i = alloc_temp_local(ctx)
  let found_local = alloc_temp_local(ctx)
  compile_expr_i32(ctx, buf, pos_args[0])
  emit_untag_ptr_i32(buf)
  emit_local_set(buf, map_ptr)
  emit_builder_follow_forwarding(ctx, buf, map_ptr)
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

///|
fn compile_map_has_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  // Map::has is alias for Map::has_key
  let pos_args = extract_positional_exprs_with_arity(args, "Map::has", 2)
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
      emit_i32_load(buf, 8)
      emit_table_get(buf, ctx.extern_table_index)
      emit_local_get(buf, key_local)
      emit_call(buf, import_index_js_equals(ctx))
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
    emit_local_get(buf, map_len)
    emit_i32_lt_s(buf)
    buf.push((4).to_byte()) // if
    buf.push((64).to_byte()) // void
    emit_local_get(buf, map_ptr)
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
  }
  emit_local_get(buf, found_local)
  emit_tag_bool_from_i32(buf)
}

///|
fn compile_map_keys_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
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
  emit_builder_follow_forwarding(ctx, buf, map_ptr)
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
  if !ctx.use_js_strings {
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

///|
fn compile_map_iter_get_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  // Map::iter_get only handles the non-js-strings case in the linear
  // backend; defer to the legacy path otherwise via the unhandled marker.
  if ctx.use_js_strings {
    raise WasmGenError::Unsupported(pre_user_builtin_unhandled_marker)
  }
  // Map::iter_get(map, idx) -> direct key slot read.
  // This preserves Map::keys element representation without allocating a
  // fresh key array for each Iterable access.
  let pos_args = extract_positional_exprs_with_arity(args, "Map::iter_get", 2)
  let map_ptr = alloc_temp_local(ctx)
  let map_len = alloc_temp_local(ctx)
  let idx_local = alloc_temp_local(ctx)
  compile_expr_i32(ctx, buf, pos_args[0])
  emit_untag_ptr_i32(buf)
  emit_local_set(buf, map_ptr)
  emit_builder_follow_forwarding(ctx, buf, map_ptr)
  emit_local_get(buf, map_ptr)
  emit_i32_load(buf, 4)
  emit_local_set(buf, map_len)
  compile_expr_i32(ctx, buf, pos_args[1])
  emit_untag_int_i32(buf)
  emit_local_set(buf, idx_local)
  emit_local_get(buf, idx_local)
  emit_i32_const_raw(buf, 0)
  emit_i32_lt_s(buf)
  emit_local_get(buf, idx_local)
  emit_local_get(buf, map_len)
  emit_i32_ge_s(buf)
  emit_i32_or(buf)
  buf.push((4).to_byte()) // if (out of bounds)
  buf.push((64).to_byte()) // void
  buf.push((0).to_byte()) // unreachable (trap)
  buf.push((11).to_byte()) // end if
  emit_local_get(buf, map_ptr)
  emit_local_get(buf, idx_local)
  emit_i32_const_raw(buf, 3)
  emit_i32_shl(buf)
  emit_i32_add(buf)
  emit_i32_load(buf, 8)
  emit_i64_extend_i32_u(buf)
  emit_i64_const_raw(buf, tag_obj.to_int64())
  emit_i64_or(buf)
}

///|
fn compile_map_values_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
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

///|
fn compile_map_iter_get_gc_arm(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  if pos_args.length() != 2 {
    raise WasmGenError::Unsupported("Map::iter_get arity")
  }
  let (builder_type, key_arr_type, _) = ensure_map_builder_type_gc(ctx)
  let b_idx = alloc_local_gc(fctx, GcValKind::Ref(builder_type))
  let len_l = alloc_local_gc(fctx, GcValKind::I32)
  let keys_l = alloc_local_gc(fctx, GcValKind::Ref(key_arr_type))
  let idx_l = alloc_local_gc(fctx, GcValKind::I32)
  compile_expr_gc(ctx, fctx, buf, pos_args[0])
  emit_local_set_gc(buf, b_idx)
  emit_local_get_gc(buf, b_idx)
  emit_struct_get_gc(buf, builder_type, 0)
  emit_local_set_gc(buf, len_l)
  emit_local_get_gc(buf, b_idx)
  emit_struct_get_gc(buf, builder_type, 1)
  emit_local_set_gc(buf, keys_l)
  compile_expr_gc(ctx, fctx, buf, pos_args[1])
  let idx_kind = infer_expr_kind_gc(ctx, fctx, pos_args[1])
  if idx_kind == GcValKind::I64 {
    emit_i32_wrap_i64_gc(buf)
  }
  emit_local_set_gc(buf, idx_l)
  emit_local_get_gc(buf, idx_l)
  emit_i32_const_gc(buf, 0)
  emit_i32_lt_s_gc(buf)
  emit_if_gc(buf, None)
  emit_unreachable_gc(buf)
  emit_end_gc(buf)
  emit_local_get_gc(buf, idx_l)
  emit_local_get_gc(buf, len_l)
  emit_i32_ge_s_gc(buf)
  emit_if_gc(buf, None)
  emit_unreachable_gc(buf)
  emit_end_gc(buf)
  emit_local_get_gc(buf, keys_l)
  emit_local_get_gc(buf, idx_l)
  emit_array_get_gc(buf, key_arr_type)
}

///|
/// Shared wasm-gc body for `Map::has_key` / `Map::has` — same semantics:
/// return I32 1 if the key exists, 0 otherwise (issue #414).
fn compile_map_has_gc_arm(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  if pos_args.length() != 2 {
    raise WasmGenError::Unsupported("Map::has_key arity")
  }
  let key_arr_type = ensure_array_type(
    ctx.types,
    ctx.array_type_index,
    GcValKind::EqRef,
  )
  let val_arr_type = ensure_array_type(
    ctx.types,
    ctx.array_type_index,
    GcValKind::EqRef,
  )
  let builder_fields : Array[GcValKind] = [
    GcValKind::I32,
    GcValKind::Ref(key_arr_type),
    GcValKind::Ref(val_arr_type),
  ]
  let builder_type = ensure_struct_type(
    ctx.types,
    ctx.struct_type_index,
    builder_fields,
  )
  let b_idx = alloc_local_gc(fctx, GcValKind::Ref(builder_type))
  let len_l = alloc_local_gc(fctx, GcValKind::I32)
  let keys_l = alloc_local_gc(fctx, GcValKind::Ref(key_arr_type))
  let i_l = alloc_local_gc(fctx, GcValKind::I32)
  let key_l = alloc_local_gc(fctx, GcValKind::EqRef)
  let result_l = alloc_local_gc(fctx, GcValKind::I32)
  compile_expr_gc(ctx, fctx, buf, pos_args[0])
  emit_local_set_gc(buf, b_idx)
  // Box key to eqref (handles int keys, string keys, etc.)
  let hk_key_kind = infer_expr_kind_gc(ctx, fctx, pos_args[1])
  compile_expr_gc(ctx, fctx, buf, pos_args[1])
  emit_box_top_for_ref_kind_gc(ctx, buf, hk_key_kind, GcValKind::EqRef)
  emit_local_set_gc(buf, key_l)
  emit_local_get_gc(buf, b_idx)
  emit_struct_get_gc(buf, builder_type, 0)
  emit_local_set_gc(buf, len_l)
  emit_local_get_gc(buf, b_idx)
  emit_struct_get_gc(buf, builder_type, 1)
  emit_local_set_gc(buf, keys_l)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, i_l)
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, i_l)
  emit_local_get_gc(buf, len_l)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1)
  let cur_key_has = alloc_local_gc(fctx, GcValKind::EqRef)
  emit_local_get_gc(buf, keys_l)
  emit_local_get_gc(buf, i_l)
  emit_array_get_gc(buf, key_arr_type)
  emit_local_set_gc(buf, cur_key_has)
  emit_map_key_eq_gc(ctx, fctx, buf, cur_key_has, key_l)
  emit_if_gc(buf, None)
  emit_i32_const_gc(buf, 1)
  emit_local_set_gc(buf, result_l)
  emit_br_gc(buf, 2)
  emit_end_gc(buf)
  emit_local_get_gc(buf, i_l)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, i_l)
  emit_br_gc(buf, 0)
  emit_end_gc(buf)
  emit_end_gc(buf)
  emit_local_get_gc(buf, result_l)
}

///|
/// Shared wasm-gc body for `Map::keys` / `Map::values`. `pick_values`
/// selects field 2 (values) vs field 1 (keys) of the map struct — this is
/// the keys-vs-values discriminator that the legacy combined arm baked into
/// `let pick_values = name == "Map::values"`. The two thin wrappers below
/// preserve it (the `compile_gc` field carries no `name`).
fn compile_map_keys_values_gc_body(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
  pick_values : Bool,
) -> Unit raise WasmGenError {
  if pos_args.length() != 1 {
    raise WasmGenError::Unsupported("Map::keys/values arity")
  }
  let key_arr_type = ensure_array_type(
    ctx.types,
    ctx.array_type_index,
    GcValKind::EqRef,
  )
  let val_arr_type = ensure_array_type(
    ctx.types,
    ctx.array_type_index,
    GcValKind::EqRef,
  )
  let builder_fields : Array[GcValKind] = [
    GcValKind::I32,
    GcValKind::Ref(key_arr_type),
    GcValKind::Ref(val_arr_type),
  ]
  let builder_type = ensure_struct_type(
    ctx.types,
    ctx.struct_type_index,
    builder_fields,
  )
  let src_field = if pick_values { 2 } else { 1 }
  let src_arr_type = if pick_values { val_arr_type } else { key_arr_type }
  let b_idx = alloc_local_gc(fctx, GcValKind::Ref(builder_type))
  let len_l = alloc_local_gc(fctx, GcValKind::I32)
  let src_l = alloc_local_gc(fctx, GcValKind::Ref(src_arr_type))
  let result_l = alloc_local_gc(fctx, GcValKind::Ref(src_arr_type))
  let i_l = alloc_local_gc(fctx, GcValKind::I32)
  compile_expr_gc(ctx, fctx, buf, pos_args[0])
  emit_local_set_gc(buf, b_idx)
  emit_local_get_gc(buf, b_idx)
  emit_struct_get_gc(buf, builder_type, 0)
  emit_local_set_gc(buf, len_l)
  emit_local_get_gc(buf, b_idx)
  emit_struct_get_gc(buf, builder_type, src_field)
  emit_local_set_gc(buf, src_l)
  emit_local_get_gc(buf, len_l)
  emit_array_new_default_gc(buf, src_arr_type)
  emit_local_set_gc(buf, result_l)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, i_l)
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, i_l)
  emit_local_get_gc(buf, len_l)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1)
  emit_local_get_gc(buf, result_l)
  emit_local_get_gc(buf, i_l)
  emit_local_get_gc(buf, src_l)
  emit_local_get_gc(buf, i_l)
  emit_array_get_gc(buf, src_arr_type)
  emit_array_set_gc(buf, src_arr_type)
  emit_local_get_gc(buf, i_l)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, i_l)
  emit_br_gc(buf, 0)
  emit_end_gc(buf)
  emit_end_gc(buf)
  emit_local_get_gc(buf, result_l)
}

///|
fn compile_map_keys_gc_arm(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  compile_map_keys_values_gc_body(ctx, fctx, buf, pos_args, false)
}

///|
fn compile_map_values_gc_arm(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  compile_map_keys_values_gc_body(ctx, fctx, buf, pos_args, true)
}
