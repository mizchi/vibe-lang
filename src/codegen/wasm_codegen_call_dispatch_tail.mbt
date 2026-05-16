///|
fn compile_call_enum_ctor_by_name(
  ctx : CodegenCtx,
  buf : ByteBuf,
  name : String,
  args : Array[@core.CallArg],
) -> Bool raise WasmGenError {
  if !ctx.enum_ctor_tags.contains(name) {
    return false
  }
  // Enum constructor call
  let tag = match ctx.enum_ctor_tags.get(name) {
    Some(t) => t
    None => 0
  }
  let arity = match ctx.enum_ctor_arities.get(name) {
    Some(a) => a
    None => 0
  }
  let pos_args = extract_positional_exprs(args, name)
  if arity == 0 {
    // Nullary ctor: use singleton from data section
    match ctx.enum_ctor_singletons.get(name) {
      Some(tagged_ptr) => emit_i64_const_raw(buf, tagged_ptr)
      None => {
        // Fallback for unregistered singletons
        require_heap(ctx)
        let size = align4(12)
        let obj_local = alloc_temp_local(ctx)
        emit_heap_alloc(ctx, buf, size, obj_local)
        emit_local_get(buf, obj_local)
        emit_i32_const_raw(buf, obj_enum)
        emit_i32_store(buf, 0)
        emit_local_get(buf, obj_local)
        emit_i32_const_raw(buf, 0) // arity = 0
        emit_i32_store(buf, 4)
        emit_local_get(buf, obj_local)
        emit_i32_const_raw(buf, tag)
        emit_i32_store(buf, 8)
        emit_local_get(buf, obj_local)
        emit_i64_extend_i32_u(buf)
        emit_i64_const_raw(buf, tag_obj.to_int64())
        emit_i64_or(buf)
      }
    }
  } else {
    // Ctor with args: heap object with type + arity + tag + payload
    require_heap(ctx)
    let size = align4(12 + arity * 4)
    let obj_local = alloc_temp_local(ctx)
    emit_heap_alloc(ctx, buf, size, obj_local)
    emit_local_get(buf, obj_local)
    emit_i32_const_raw(buf, obj_enum)
    emit_i32_store(buf, 0)
    emit_local_get(buf, obj_local)
    emit_i32_const_raw(buf, arity)
    emit_i32_store(buf, 4)
    emit_local_get(buf, obj_local)
    emit_i32_const_raw(buf, tag)
    emit_i32_store(buf, 8)
    for i in 0..<arity {
      let arg_kind = infer_expr_kind(ctx, pos_args[i])
      if ctx.use_js_strings && arg_kind == ValueKind::ExternRef {
        // Store externref in extern table, put slot index in payload
        ctx.need_extern_table = true
        let slot = ctx.extern_table_next_slot
        ctx.extern_table_next_slot += 1
        emit_i32_const_raw(buf, slot)
        compile_expr(ctx, buf, pos_args[i])
        emit_table_set(buf, ctx.extern_table_index)
        emit_local_get(buf, obj_local)
        emit_i32_const_raw(buf, slot)
        emit_i32_store(buf, 12 + i * 4)
      } else {
        emit_local_get(buf, obj_local)
        compile_expr_i32(ctx, buf, pos_args[i])
        emit_i32_wrap_i64(buf)
        emit_i32_store(buf, 12 + i * 4)
      }
    }
    emit_local_get(buf, obj_local)
    emit_i64_extend_i32_u(buf)
    emit_i64_const_raw(buf, tag_obj.to_int64())
    emit_i64_or(buf)
  }
  true
}

///|
fn compile_call_record_field_fallback_by_name(
  ctx : CodegenCtx,
  buf : ByteBuf,
  name : String,
  args : Array[@core.CallArg],
) -> Bool raise WasmGenError {
  if is_qualified_name(name) {
    return false
  }
  let pos_args = extract_positional_exprs(args, name)
  if !(pos_args.length() == 1 && ctx.known_record_fields.contains(name)) {
    return false
  }
  // Fallback for method-style record field access desugared as `field(record)`.
  let record_ptr_local = alloc_temp_local(ctx)
  let record_len_local = alloc_temp_local(ctx)
  let loop_i_local = alloc_temp_local(ctx)
  let result_local = alloc_temp_local(ctx)
  let found_local = alloc_temp_local(ctx)
  let field_name_ptr = ctx.strings.intern(name)
  compile_expr_i32(ctx, buf, pos_args[0])
  emit_i64_const_raw(buf, (-4).to_int64())
  emit_i64_and(buf)
  emit_i32_wrap_i64(buf)
  emit_local_set(buf, record_ptr_local)
  emit_local_get(buf, record_ptr_local)
  emit_i32_load(buf, 4)
  emit_local_set(buf, record_len_local)
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, loop_i_local)
  emit_i64_const_tagged(buf, 0L)
  emit_i32_wrap_i64(buf)
  emit_local_set(buf, result_local)
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, found_local)
  emit_block(buf)
  emit_loop(buf)
  emit_local_get(buf, loop_i_local)
  emit_local_get(buf, record_len_local)
  emit_i32_lt_s(buf)
  emit_i32_eqz(buf)
  emit_br_if(buf, 1)
  emit_local_get(buf, record_ptr_local)
  emit_local_get(buf, loop_i_local)
  emit_i32_const_raw(buf, 3)
  emit_i32_shl(buf)
  emit_i32_add(buf)
  emit_i32_load(buf, 8)
  emit_i32_const_raw(buf, field_name_ptr)
  emit_i32_eq(buf)
  buf.push((4).to_byte()) // if
  buf.push((64).to_byte()) // void
  emit_local_get(buf, record_ptr_local)
  emit_local_get(buf, loop_i_local)
  emit_i32_const_raw(buf, 3)
  emit_i32_shl(buf)
  emit_i32_add(buf)
  emit_i32_load(buf, 12)
  emit_local_set(buf, result_local)
  emit_i32_const_raw(buf, 1)
  emit_local_set(buf, found_local)
  emit_local_get(buf, record_len_local)
  emit_local_set(buf, loop_i_local)
  buf.push((11).to_byte()) // end if
  emit_local_get(buf, loop_i_local)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, loop_i_local)
  emit_br(buf, 0)
  emit_end(buf)
  emit_end(buf)
  emit_local_get(buf, found_local)
  emit_i32_eqz(buf)
  buf.push((4).to_byte()) // if
  buf.push((64).to_byte()) // void
  buf.push((0).to_byte()) // unreachable
  buf.push((11).to_byte()) // end if
  emit_local_get(buf, result_local)
  emit_i64_extend_i32_s(buf)
  true
}

///|
fn compile_call_by_name_unresolved(
  ctx : CodegenCtx,
  buf : ByteBuf,
  name : String,
) -> Unit raise WasmGenError {
  let _ = ctx
  let _ = buf
  if is_qualified_name(name) {
    raise WasmGenError::BackendLimit(
      backend="wasm",
      feature="qualified call: " + name,
    )
  }
  raise WasmGenError::BackendLimit(backend="wasm", feature="call: " + name)
}
