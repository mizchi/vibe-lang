///|
/// Phase B-1 (Issue #415): the `Set::` namespace migrated off the legacy
/// `match name` dispatcher in `wasm_codegen_builtin_collection.mbt` onto the
/// shared `migrated_builtin` table in `builtin_registry.mbt`. Set is
/// LINEAR-ONLY at the dispatch level: the linear backend has a dedicated arm
/// per op (relocated verbatim below), while wasm-gc has NO Set dispatch arm
/// and reaches the same behavior through the prelude (verified: set_test
/// passes on the wasm-gc backend). So each op uses `mig_linear_only`
/// (`compile_gc == None`, gc dispatch falls through) plus a
/// `prelude_fallback("Set::<op>", ..., has_linear=true)` parity entry.
///
/// The bodies are byte-buffer codegen relocated verbatim from the
/// collection.mbt arms (no `!is_user_fn` guard — the legacy arms were plain).

///|
fn compile_set_new_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
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

///|
fn compile_set_size_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
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

///|
fn compile_set_contains_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  // Set::contains(set, val) -> same as Map::has_key
  let pos_args = extract_positional_exprs_with_arity(args, "Set::contains", 2)
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

///|
fn compile_set_add_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
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
    // Match Set::contains' i32.eq. The shared
    // `emit_non_js_string_ptr_equals_i32` helper treats its operands as
    // `obj_string` pointers (loading length at `(int<<2)+4`), so for
    // tagged-int keys `Set::add(Set::add(Set::new(), 10), 20)` could
    // false-positive 20 vs 10 against memory garbage and silently skip
    // the append. Map ops keep the helper because their tests exercise
    // String keys where structural compare is required.
    emit_local_get(buf, entry_key_local)
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

///|
fn compile_set_remove_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
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
    // Match Set::contains / Set::add: tagged-int keys compare via i32.eq.
    // The shared `emit_non_js_string_ptr_equals_i32` helper would
    // dereference both operands as `obj_string` (load length at +4 of
    // `(int<<2)`), so for int keys `Set::remove(Set::add(Set::new(), 5),
    // 999)` previously hit a memory false-positive and removed the
    // wrong entry. Map ops keep the helper because their keys are
    // String pointers stored raw.
    emit_local_get(buf, entry_key_local)
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
fn compile_set_to_array_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  // Set::to_array(set) -> allocate array with keys from map (same as Map::keys)
  let pos_args = extract_positional_exprs_with_arity(args, "Set::to_array", 1)
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
  // Set slots store the i32-wrapped form of the tagged i64 value
  // (`Set::add` does `i32_wrap_i64` on the tagged input). For Int keys
  // that's the tagged-int representation already; for String keys it's
  // the tagged pointer. ORing `tag_obj` here would double-tag ints
  // (`40 | 1 = 41`, breaking the tag_int convention) — leave the slot
  // value as-is. Map::keys is symmetric but stores RAW string pointers,
  // so its OR is correct and stays.
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
fn compile_set_from_array_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  // Set::from_array(arr) -> new set from array elements with dedup.
  // Creates a map where each unique array element is a key with
  // value=true. Iterates the source array, linearly scanning the
  // partial dst for each candidate; only appends when not already
  // present so `Set::from_array([1, 2, 3, 2, 1])` has size 3.
  let pos_args = extract_positional_exprs_with_arity(args, "Set::from_array", 1)
  require_heap(ctx)
  let max_cap = 128
  let arr_ptr = alloc_temp_local(ctx)
  let arr_len = alloc_temp_local(ctx)
  let dst_ptr = alloc_temp_local(ctx)
  let dst_len = alloc_temp_local(ctx)
  let loop_i = alloc_temp_local(ctx)
  let inner_j = alloc_temp_local(ctx)
  let cand_key = alloc_temp_local(ctx)
  let found_local = alloc_temp_local(ctx)
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
  // dst length is finalised after the loop; start at 0.
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, dst_len)
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, loop_i)
  buf.push((3).to_byte()) // outer loop
  buf.push((64).to_byte()) // void
  emit_local_get(buf, loop_i)
  emit_local_get(buf, arr_len)
  emit_i32_lt_s(buf)
  buf.push((4).to_byte()) // if (i < arr_len)
  buf.push((64).to_byte()) // void
  // load candidate = arr[8 + i*4]
  emit_local_get(buf, arr_ptr)
  emit_local_get(buf, loop_i)
  emit_i32_const_raw(buf, 4)
  emit_i32_mul(buf)
  emit_i32_add(buf)
  emit_i32_load(buf, 8)
  emit_local_set(buf, cand_key)
  // dedup search: scan dst[0..dst_len] for cand_key
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, found_local)
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, inner_j)
  buf.push((3).to_byte()) // inner loop
  buf.push((64).to_byte()) // void
  emit_local_get(buf, inner_j)
  emit_local_get(buf, dst_len)
  emit_i32_lt_s(buf)
  buf.push((4).to_byte()) // if (j < dst_len)
  buf.push((64).to_byte()) // void
  emit_local_get(buf, dst_ptr)
  emit_local_get(buf, inner_j)
  emit_i32_const_raw(buf, 3)
  emit_i32_shl(buf)
  emit_i32_add(buf)
  emit_i32_load(buf, 8)
  emit_local_get(buf, cand_key)
  emit_i32_eq(buf)
  buf.push((4).to_byte()) // if (matches)
  buf.push((64).to_byte()) // void
  emit_i32_const_raw(buf, 1)
  emit_local_set(buf, found_local)
  buf.push((11).to_byte()) // end if (matches)
  emit_local_get(buf, inner_j)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, inner_j)
  buf.push((12).to_byte()) // br to inner loop
  write_u32_leb(buf, 1)
  buf.push((11).to_byte()) // end if (j < dst_len)
  buf.push((11).to_byte()) // end inner loop
  // append if not found
  emit_local_get(buf, found_local)
  emit_i32_eqz(buf)
  buf.push((4).to_byte()) // if (not found)
  buf.push((64).to_byte()) // void
  emit_local_get(buf, dst_ptr)
  emit_local_get(buf, dst_len)
  emit_i32_const_raw(buf, 3)
  emit_i32_shl(buf)
  emit_i32_add(buf)
  emit_local_get(buf, cand_key)
  emit_i32_store(buf, 8)
  emit_local_get(buf, dst_ptr)
  emit_local_get(buf, dst_len)
  emit_i32_const_raw(buf, 3)
  emit_i32_shl(buf)
  emit_i32_add(buf)
  emit_i32_const_raw(buf, 7) // tagged true = (1 << 2) | 3
  emit_i32_store(buf, 12)
  emit_local_get(buf, dst_len)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, dst_len)
  buf.push((11).to_byte()) // end if (not found)
  // outer i++
  emit_local_get(buf, loop_i)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, loop_i)
  buf.push((12).to_byte()) // br to outer loop
  write_u32_leb(buf, 1)
  buf.push((11).to_byte()) // end if (i < arr_len)
  buf.push((11).to_byte()) // end outer loop
  // finalise length
  emit_local_get(buf, dst_ptr)
  emit_local_get(buf, dst_len)
  emit_i32_store(buf, 4)
  emit_local_get(buf, dst_ptr)
  emit_i64_extend_i32_u(buf)
  emit_i64_const_raw(buf, tag_obj.to_int64())
  emit_i64_or(buf)
}
