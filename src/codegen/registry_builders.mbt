///|
/// Phase B-1 (Issue #415): `ArrayBuilder::` / `MapBuilder::` namespaces
/// migrated off the two legacy `match name` dispatchers
/// (`wasm_codegen_builtin_collection.mbt` linear arms and
/// `wasm_gc_codegen.mbt::Call`) onto the shared `migrated_builtin` table in
/// `builtin_registry.mbt`. The linear bodies are inline byte-buffer / builder
/// codegen relocated verbatim from the collection.mbt arms; the wasm-gc bodies
/// are relocated verbatim from the inline gc arms (NOT thin delegates — they
/// carry the struct/array type setup and grow/copy loops). No `!is_user_fn`
/// guard (matches the legacy arms), so `mig`.
///
/// Note: the synthetic `MapBuilder::new` / `MapBuilder::set` Call exprs that
/// `compile_map_literal_gc` builds route through `migrated_builtin` →
/// `compile_map_builder_*_gc_arm` here, so map-literal behavior is preserved
/// because these gc fns are exact verbatim copies of the old inline arms.

///|
fn compile_array_builder_new_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  _args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  // array_builder() -> allocate empty array obj with len=0
  // Uses hidden capacity prefix at obj_ptr-4 for grow-on-overflow in push.
  let obj_local = alloc_temp_local(ctx)
  emit_builder_alloc(ctx, buf, builder_initial_cap, 4, obj_array, obj_local)
  emit_local_get(buf, obj_local)
  emit_i64_extend_i32_u(buf)
  emit_i64_const_raw(buf, tag_obj.to_int64())
  emit_i64_or(buf)
}

///|
fn compile_array_builder_new_gc_arm(
  ctx : GcCodegenCtx,
  _fctx : GcFuncCtx,
  buf : GcByteBuf,
  _pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  // Create struct { len: i32, data: ref array<eqref> }.
  // Default to eqref element storage so the same builder
  // shape works for both primitive (`ArrayBuilder[Int]`,
  // boxed on push via `emit_coerce_top_gc`) and reference
  // (`ArrayBuilder[Json]`) element types. Explicit
  // `ArrayBuilder[T]` annotations still pick `T`'s exact
  // kind via the `gc_val_kind_from_type` path.
  let init_cap = 8
  let arr_type = ensure_array_type(
    ctx.types,
    ctx.array_type_index,
    GcValKind::EqRef,
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
  emit_i32_const_gc(buf, 0)
  emit_i32_const_gc(buf, init_cap)
  emit_array_new_default_gc(buf, arr_type)
  emit_struct_new_gc(buf, builder_type)
}

///|
fn compile_array_builder_push_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  // array_builder_push(builder, value) -> store value at [builder + 8 + len*4], increment len
  // Grows capacity when full (heap-tip extension or trap).
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
fn compile_array_builder_push_gc_arm(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  if pos_args.length() != 2 {
    raise WasmGenError::Unsupported("ArrayBuilder::push arity")
  }
  let builder_kind = infer_expr_kind_gc(ctx, fctx, pos_args[0])
  let builder_type = match builder_kind {
    GcValKind::Ref(idx) => idx
    _ => {
      // Default ArrayBuilder type: {len: i32, data: ref array<i64>}
      let arr_type = ensure_array_type(
        ctx.types,
        ctx.array_type_index,
        GcValKind::I64,
      )
      ensure_struct_type(ctx.types, ctx.struct_type_index, [
        GcValKind::I32,
        GcValKind::Ref(arr_type),
      ])
    }
  }
  let arr_type = match ctx.types[builder_type] {
    GcTypeDef::Struct(fields~) =>
      match fields[1] {
        GcValKind::Ref(idx) => idx
        _ => ensure_array_type(ctx.types, ctx.array_type_index, GcValKind::I64)
      }
    _ => ensure_array_type(ctx.types, ctx.array_type_index, GcValKind::I64)
  }
  compile_struct_array_push_gc(
    ctx,
    fctx,
    buf,
    pos_args[0],
    pos_args[1],
    builder_kind,
    builder_type,
    arr_type,
  )
}

///|
fn compile_array_builder_freeze_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  // array_builder_freeze(builder) -> return builder as-is (it is already an array obj)
  // Follow forwarding pointer in case push triggered realloc
  let pos_args = extract_positional_exprs_with_arity(
    args, "ArrayBuilder::freeze", 1,
  )
  let ptr_local = alloc_temp_local(ctx)
  compile_expr_i32(ctx, buf, pos_args[0])
  emit_untag_ptr_i32(buf)
  emit_local_set(buf, ptr_local)
  emit_builder_follow_forwarding(ctx, buf, ptr_local)
  emit_local_get(buf, ptr_local)
  emit_i64_extend_i32_u(buf)
  emit_i64_const_raw(buf, tag_obj.to_int64())
  emit_i64_or(buf)
}

///|
fn compile_array_builder_freeze_gc_arm(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  if pos_args.length() != 1 {
    raise WasmGenError::Unsupported("ArrayBuilder::freeze arity")
  }
  let builder_kind = infer_expr_kind_gc(ctx, fctx, pos_args[0])
  let builder_type = match builder_kind {
    GcValKind::Ref(idx) => idx
    _ => {
      let arr_type = ensure_array_type(
        ctx.types,
        ctx.array_type_index,
        GcValKind::I64,
      )
      ensure_struct_type(ctx.types, ctx.struct_type_index, [
        GcValKind::I32,
        GcValKind::Ref(arr_type),
      ])
    }
  }
  let arr_type = match ctx.types[builder_type] {
    GcTypeDef::Struct(fields~) =>
      match fields[1] {
        GcValKind::Ref(idx) => idx
        _ => ensure_array_type(ctx.types, ctx.array_type_index, GcValKind::I64)
      }
    _ => ensure_array_type(ctx.types, ctx.array_type_index, GcValKind::I64)
  }
  let b_idx = alloc_local_gc(fctx, builder_kind)
  let len_l = alloc_local_gc(fctx, GcValKind::I32)
  let src_l = alloc_local_gc(fctx, GcValKind::Ref(arr_type))
  let dst_l = alloc_local_gc(fctx, GcValKind::Ref(arr_type))
  let i_l = alloc_local_gc(fctx, GcValKind::I32)
  compile_expr_gc(ctx, fctx, buf, pos_args[0])
  emit_local_set_gc(buf, b_idx)
  emit_local_get_gc(buf, b_idx)
  emit_struct_get_gc(buf, builder_type, 0)
  emit_local_set_gc(buf, len_l)
  emit_local_get_gc(buf, b_idx)
  emit_struct_get_gc(buf, builder_type, 1)
  emit_local_set_gc(buf, src_l)
  emit_local_get_gc(buf, len_l)
  emit_array_new_default_gc(buf, arr_type)
  emit_local_set_gc(buf, dst_l)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, i_l)
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, i_l)
  emit_local_get_gc(buf, len_l)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1)
  emit_local_get_gc(buf, dst_l)
  emit_local_get_gc(buf, i_l)
  emit_local_get_gc(buf, src_l)
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
  emit_local_get_gc(buf, dst_l)
}

///|
fn compile_map_builder_new_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  _args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  // MapBuilder::new() -> allocate empty map obj with len=0
  // Uses hidden capacity prefix at obj_ptr-4 for grow-on-overflow in set.
  let obj_local = alloc_temp_local(ctx)
  emit_builder_alloc(ctx, buf, builder_initial_cap, 8, obj_map, obj_local)
  emit_local_get(buf, obj_local)
  emit_i64_extend_i32_u(buf)
  emit_i64_const_raw(buf, tag_obj.to_int64())
  emit_i64_or(buf)
}

///|
fn compile_map_builder_new_gc_arm(
  ctx : GcCodegenCtx,
  _fctx : GcFuncCtx,
  buf : GcByteBuf,
  _pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  // Map: struct { len: i32, keys: ref array<eqref>, vals: ref array<eqref> }
  let init_cap = 8
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
  emit_i32_const_gc(buf, 0) // len = 0
  emit_i32_const_gc(buf, init_cap)
  emit_array_new_default_gc(buf, key_arr_type)
  emit_i32_const_gc(buf, init_cap)
  emit_array_new_default_gc(buf, val_arr_type)
  emit_struct_new_gc(buf, builder_type)
}

///|
fn compile_map_builder_set_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  // MapBuilder::set(builder, key, value) -> overwrite existing key or append new pair
  // Grows capacity when full (heap-tip extension or trap).
  let pos_args = extract_positional_exprs_with_arity(args, "MapBuilder::set", 3)
  let ptr_local = alloc_temp_local(ctx)
  let len_local = alloc_temp_local(ctx)
  let loop_i = alloc_temp_local(ctx)
  let found_local = alloc_temp_local(ctx)
  let offset_local = alloc_temp_local(ctx)
  compile_expr_i32(ctx, buf, pos_args[0])
  emit_untag_ptr_i32(buf)
  emit_local_set(buf, ptr_local)
  // Bounds check + grow if needed (elem_size=8) before search loop
  emit_builder_grow_check(ctx, buf, ptr_local, 8)
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
    // Strip `tag_obj` to match the map literal / `Map::set` storage
    // convention (`compile_map_expr` stores `ctx.strings.intern(key)`
    // raw). Without this, `m["k"]` lookup via `__index` compares the
    // tagged stored slot against the raw interned offset and silently
    // misses (#325 map_advanced repro).
    emit_i32_const_raw(buf, -4)
    emit_i32_and(buf)
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

///|
fn compile_map_builder_set_gc_arm(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  // MapBuilder::set(builder, key, value)
  if pos_args.length() != 3 {
    raise WasmGenError::Unsupported("MapBuilder::set arity")
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
  let cap_l = alloc_local_gc(fctx, GcValKind::I32)
  let keys_l = alloc_local_gc(fctx, GcValKind::Ref(key_arr_type))
  let vals_l = alloc_local_gc(fctx, GcValKind::Ref(val_arr_type))
  let new_keys = alloc_local_gc(fctx, GcValKind::Ref(key_arr_type))
  let new_vals = alloc_local_gc(fctx, GcValKind::Ref(val_arr_type))
  let i_l = alloc_local_gc(fctx, GcValKind::I32)
  let key_l = alloc_local_gc(fctx, GcValKind::EqRef)
  compile_expr_gc(ctx, fctx, buf, pos_args[0])
  emit_local_set_gc(buf, b_idx)
  // Box key to eqref (handles int keys, string keys, etc.)
  let key_kind = infer_expr_kind_gc(ctx, fctx, pos_args[1])
  compile_expr_gc(ctx, fctx, buf, pos_args[1])
  emit_box_top_for_ref_kind_gc(ctx, buf, key_kind, GcValKind::EqRef)
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
  emit_local_get_gc(buf, keys_l)
  emit_array_len_gc(buf)
  emit_local_set_gc(buf, cap_l)
  let found_l = alloc_local_gc(fctx, GcValKind::I32) // 1 if found
  let val_l = alloc_local_gc(fctx, GcValKind::EqRef)
  // Compile value once, box to eqref, and save to local
  let val_kind = infer_expr_kind_gc(ctx, fctx, pos_args[2])
  compile_expr_gc(ctx, fctx, buf, pos_args[2])
  emit_box_top_for_ref_kind_gc(ctx, buf, val_kind, GcValKind::EqRef)
  emit_local_set_gc(buf, val_l)
  // Search for existing key
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, i_l)
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, found_l)
  // block $done
  emit_block_gc(buf, None)
  // loop $search
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, i_l)
  emit_local_get_gc(buf, len_l)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1) // br $done
  let cur_key_l = alloc_local_gc(fctx, GcValKind::EqRef)
  emit_local_get_gc(buf, keys_l)
  emit_local_get_gc(buf, i_l)
  emit_array_get_gc(buf, key_arr_type)
  emit_local_set_gc(buf, cur_key_l)
  emit_map_key_eq_gc(ctx, fctx, buf, cur_key_l, key_l)
  emit_if_gc(buf, None)
  // Found: update value and break
  emit_local_get_gc(buf, vals_l)
  emit_local_get_gc(buf, i_l)
  emit_local_get_gc(buf, val_l)
  emit_array_set_gc(buf, val_arr_type)
  emit_i32_const_gc(buf, 1)
  emit_local_set_gc(buf, found_l)
  emit_br_gc(buf, 2) // br $done
  emit_end_gc(buf) // end if
  emit_local_get_gc(buf, i_l)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, i_l)
  emit_br_gc(buf, 0) // br $search
  emit_end_gc(buf) // end loop
  emit_end_gc(buf) // end $done
  // If not found, append
  emit_local_get_gc(buf, found_l)
  emit_i32_eqz_gc(buf)
  emit_if_gc(buf, None)
  // Grow if needed
  emit_local_get_gc(buf, len_l)
  emit_local_get_gc(buf, cap_l)
  emit_i32_ge_s_gc(buf)
  emit_if_gc(buf, None)
  emit_local_get_gc(buf, cap_l)
  emit_i32_const_gc(buf, 2)
  emit_i32_mul_gc(buf)
  emit_array_new_default_gc(buf, key_arr_type)
  emit_local_set_gc(buf, new_keys)
  emit_local_get_gc(buf, cap_l)
  emit_i32_const_gc(buf, 2)
  emit_i32_mul_gc(buf)
  emit_array_new_default_gc(buf, val_arr_type)
  emit_local_set_gc(buf, new_vals)
  // copy old to new
  emit_i32_const_gc(buf, 0)
  emit_local_set_gc(buf, i_l)
  emit_block_gc(buf, None)
  emit_loop_gc(buf, None)
  emit_local_get_gc(buf, i_l)
  emit_local_get_gc(buf, len_l)
  emit_i32_ge_s_gc(buf)
  emit_br_if_gc(buf, 1)
  emit_local_get_gc(buf, new_keys)
  emit_local_get_gc(buf, i_l)
  emit_local_get_gc(buf, keys_l)
  emit_local_get_gc(buf, i_l)
  emit_array_get_gc(buf, key_arr_type)
  emit_array_set_gc(buf, key_arr_type)
  emit_local_get_gc(buf, new_vals)
  emit_local_get_gc(buf, i_l)
  emit_local_get_gc(buf, vals_l)
  emit_local_get_gc(buf, i_l)
  emit_array_get_gc(buf, val_arr_type)
  emit_array_set_gc(buf, val_arr_type)
  emit_local_get_gc(buf, i_l)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_local_set_gc(buf, i_l)
  emit_br_gc(buf, 0)
  emit_end_gc(buf) // end copy loop
  emit_end_gc(buf) // end copy block
  emit_local_get_gc(buf, b_idx)
  emit_local_get_gc(buf, new_keys)
  emit_struct_set_gc(buf, builder_type, 1)
  emit_local_get_gc(buf, b_idx)
  emit_local_get_gc(buf, new_vals)
  emit_struct_set_gc(buf, builder_type, 2)
  emit_local_get_gc(buf, new_keys)
  emit_local_set_gc(buf, keys_l)
  emit_local_get_gc(buf, new_vals)
  emit_local_set_gc(buf, vals_l)
  emit_end_gc(buf) // end if grow
  // Append: keys[len] = key, vals[len] = val
  emit_local_get_gc(buf, keys_l)
  emit_local_get_gc(buf, len_l)
  emit_local_get_gc(buf, key_l)
  emit_array_set_gc(buf, key_arr_type)
  emit_local_get_gc(buf, vals_l)
  emit_local_get_gc(buf, len_l)
  emit_local_get_gc(buf, val_l)
  emit_array_set_gc(buf, val_arr_type)
  // len++
  emit_local_get_gc(buf, b_idx)
  emit_local_get_gc(buf, len_l)
  emit_i32_const_gc(buf, 1)
  emit_i32_add_gc(buf)
  emit_struct_set_gc(buf, builder_type, 0)
  emit_end_gc(buf) // end if !found
  emit_i32_const_gc(buf, 0) // return Unit
}

///|
fn compile_map_builder_freeze_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  // MapBuilder::freeze(builder) -> return builder as-is (it is already a map obj)
  // Follow forwarding pointer in case set triggered realloc (mirrors
  // ArrayBuilder::freeze).
  let pos_args = extract_positional_exprs_with_arity(
    args, "MapBuilder::freeze", 1,
  )
  let ptr_local = alloc_temp_local(ctx)
  compile_expr_i32(ctx, buf, pos_args[0])
  emit_untag_ptr_i32(buf)
  emit_local_set(buf, ptr_local)
  emit_builder_follow_forwarding(ctx, buf, ptr_local)
  emit_local_get(buf, ptr_local)
  emit_i64_extend_i32_u(buf)
  emit_i64_const_raw(buf, tag_obj.to_int64())
  emit_i64_or(buf)
}

///|
fn compile_map_builder_freeze_gc_arm(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  // freeze returns builder as-is (same representation)
  if pos_args.length() != 1 {
    raise WasmGenError::Unsupported("MapBuilder::freeze arity")
  }
  compile_expr_gc(ctx, fctx, buf, pos_args[0])
}
