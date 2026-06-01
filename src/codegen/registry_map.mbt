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
