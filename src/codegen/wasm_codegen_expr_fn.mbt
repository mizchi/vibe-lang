///|
fn compile_expr_fn(
  ctx : CodegenCtx,
  buf : ByteBuf,
  span : @core.Span,
) -> Unit raise WasmGenError {
  let key = span_key(span)
  let func_idx = match ctx.fn_closure_indices.get(key) {
    Some(idx) => idx
    None => raise WasmGenError::Unsupported("fn index")
  }
  let captures = match ctx.fn_closure_captures.get(key) {
    Some(list) => list
    None => []
  }
  if captures.length() == 0 {
    let slot = ensure_funcref_slot(ctx, func_idx)
    emit_i64_const_raw(buf, tag_fn_value64(slot.to_int64()))
  } else {
    require_heap(ctx)
    let len = captures.length()
    // All captures get env slots unconditionally.
    // Inner function bodies are compiled before the top-level run function,
    // so const_i64_values may not yet contain outer-scope constants when
    // the function prologue is generated. Skipping env stores here while
    // the prologue still emits env loads causes an index mismatch and
    // reads uninitialized memory. Always allocate and store to be safe.
    let size = align4(8 + len * 8)
    let obj_local = alloc_temp_local(ctx)
    emit_heap_alloc(ctx, buf, size, obj_local)
    emit_local_get(buf, obj_local)
    emit_i32_const_raw(buf, obj_fn)
    emit_i32_store(buf, 0)
    emit_local_get(buf, obj_local)
    let slot = ensure_funcref_slot(ctx, func_idx)
    emit_i32_const_raw(buf, slot)
    emit_i32_store(buf, 4)
    let capture_kinds : Array[ValueKind] = []
    let capture_is_ref_cell : Array[Bool] = []
    let mut effective_idx = 0
    for i in 0..<len {
      let name = captures[i]
      let is_ref_cell = ctx.mut_captured_vars.contains(name)
      capture_is_ref_cell.push(is_ref_cell)
      let cap_kind = if is_ref_cell {
        ValueKind::I32 // pointer
      } else {
        match ctx.local_kinds.get(name) {
          Some(kind) => kind
          None => ValueKind::I64
        }
      }
      capture_kinds.push(cap_kind)
      if is_ref_cell {
        // Ref cell capture: store i32 pointer as i64 in env slot
        emit_local_get(buf, obj_local)
        match ctx.locals.get(name) {
          Some(idx) => {
            emit_local_get(buf, idx) // i32 pointer
            emit_i64_extend_i32_u(buf) // → i64
          }
          None => raise WasmGenError::UnknownName(name)
        }
        emit_i64_store(buf, 8 + effective_idx * 8)
      } else if ctx.use_js_strings && cap_kind == ValueKind::ExternRef {
        // Store externref in extern table, put slot index in closure env
        ctx.need_extern_table = true
        let slot = ctx.extern_table_next_slot
        ctx.extern_table_next_slot += 1
        // table.set $extern_table slot externref_value
        emit_i32_const_raw(buf, slot)
        match ctx.locals.get(name) {
          Some(idx) => emit_local_get(buf, idx)
          None => raise WasmGenError::UnknownName(name)
        }
        emit_table_set(buf, ctx.extern_table_index)
        // Store slot index in closure env as i64
        emit_local_get(buf, obj_local)
        emit_i32_const_raw(buf, slot)
        emit_i64_extend_i32_u(buf)
        emit_i64_store(buf, 8 + effective_idx * 8)
      } else {
        emit_local_get(buf, obj_local)
        match ctx.locals.get(name) {
          Some(idx) => emit_local_get(buf, idx)
          None =>
            match ctx.fn_indices.get(name) {
              Some(idx) => {
                if fn_index_needs_env(ctx, idx) {
                  match ctx.exported_fn_env_globals.get(name) {
                    Some(global_idx) if global_idx >= 0 => {
                      emit_global_get(buf, global_idx)
                      emit_i64_extend_i32_u(buf)
                      emit_i64_const_raw(buf, tag_obj.to_int64())
                      emit_i64_or(buf)
                    }
                    _ =>
                      raise WasmGenError::Unsupported(
                        "closure capture requires env-backed function in scope: " +
                        name,
                      )
                  }
                } else {
                  let slot = ensure_funcref_slot(ctx, idx)
                  emit_i64_const_raw(buf, tag_fn_value64(slot.to_int64()))
                }
              }
              None => raise WasmGenError::UnknownName(name)
            }
        }
        // Store capture as i64 (all tagged values are i64)
        emit_i64_store(buf, 8 + effective_idx * 8)
      }
      effective_idx += 1
    }
    ctx.fn_closure_capture_kinds[key] = capture_kinds
    ctx.fn_closure_capture_is_ref_cell[key] = capture_is_ref_cell
    emit_local_get(buf, obj_local)
    emit_i64_extend_i32_u(buf)
    emit_i64_const_raw(buf, tag_obj.to_int64())
    emit_i64_or(buf)
  }
}
