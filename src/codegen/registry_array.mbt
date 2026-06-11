///|
/// Phase B-1 (Issue #415): `Array::` namespace migrated off the two legacy
/// `match name` dispatchers (`wasm_codegen_builtin_collection.mbt` linear arms
/// and `wasm_gc_codegen.mbt::Call`) onto the shared `migrated_builtin` table in
/// `builtin_registry.mbt`. Array is the most complex namespace; only the
/// tractable ops that have a dedicated dispatch arm in BOTH backends are
/// migrated here (`length` / `get` / `set` / `truncate` / `with_capacity` /
/// `push`). Ops that only exist in one backend (`Array::push_all` / `slice` /
/// `concat` — wasm-gc only) stay legacy, and `Array::fold` keeps its
/// `prelude_fallback` divergence entry.
///
/// The linear bodies are inline byte-buffer codegen relocated verbatim from
/// the legacy arms; the wasm-gc bodies are relocated verbatim too, INCLUDING
/// the `infer_expr_kind_gc` / `gc_array_type_idx_from_kind` / builder-unwrap
/// setup (the gc Array arms are not thin delegates).

///|
fn compile_array_length_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  // array_length(arr) -> load len field, shift left 2 (tag as int)
  // Supports both obj_array (len at offset 4) and
  // obj_array_view (end - start, offsets 12 and 8)
  let pos_args = extract_positional_exprs_with_arity(args, "Array::length", 1)
  let arr_ptr = alloc_temp_local(ctx)
  compile_expr_i32(ctx, buf, pos_args[0])
  emit_untag_ptr_i32(buf)
  emit_local_set(buf, arr_ptr)
  emit_builder_follow_forwarding(ctx, buf, arr_ptr)
  emit_local_get(buf, arr_ptr)
  emit_i32_load(buf, 0) // obj_type
  emit_i32_const_raw(buf, obj_array_view)
  emit_i32_eq(buf)
  buf.push((4).to_byte()) // if (array_view)
  buf.push((126).to_byte()) // result i64
  // ArrayView: length = end - start
  emit_local_get(buf, arr_ptr)
  emit_i32_load(buf, 12) // end
  emit_local_get(buf, arr_ptr)
  emit_i32_load(buf, 8) // start
  emit_i32_sub(buf)
  emit_i64_extend_i32_s(buf)
  emit_i64_const_raw(buf, 2L)
  emit_i64_shl(buf)
  buf.push((5).to_byte()) // else (regular array)
  emit_local_get(buf, arr_ptr)
  emit_i32_load(buf, 4) // length field
  emit_i64_extend_i32_s(buf)
  emit_i64_const_raw(buf, 2L)
  emit_i64_shl(buf)
  buf.push((11).to_byte()) // end if
}

///|
fn compile_array_length_gc_arm(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  if pos_args.length() != 1 {
    raise WasmGenError::Unsupported("Array::length arity")
  }
  compile_len_gc(ctx, fctx, buf, pos_args[0])
}

///|
fn compile_array_get_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  // array_get(arr, idx) -> load arr[idx]
  // Supports both obj_array and obj_array_view
  let pos_args = extract_positional_exprs_with_arity(args, "Array::get", 2)
  let arr_ptr = alloc_temp_local(ctx)
  let idx_local = alloc_temp_local(ctx)
  compile_expr_i32(ctx, buf, pos_args[0])
  emit_untag_ptr_i32(buf)
  emit_local_set(buf, arr_ptr)
  emit_builder_follow_forwarding(ctx, buf, arr_ptr)
  compile_expr_i32(ctx, buf, pos_args[1])
  emit_untag_int_i32(buf)
  emit_local_set(buf, idx_local)
  emit_local_get(buf, arr_ptr)
  emit_i32_load(buf, 0) // obj_type
  emit_i32_const_raw(buf, obj_array_view)
  emit_i32_eq(buf)
  buf.push((4).to_byte()) // if (array_view)
  buf.push((126).to_byte()) // result i64
  // ArrayView: source[start + idx]
  emit_local_get(buf, arr_ptr)
  emit_i32_load(buf, 4) // source_ptr
  emit_local_get(buf, arr_ptr)
  emit_i32_load(buf, 8) // start
  emit_local_get(buf, idx_local)
  emit_i32_add(buf) // start + idx
  emit_i32_const_raw(buf, 4)
  emit_i32_mul(buf)
  emit_i32_add(buf) // source_ptr + (start + idx) * 4
  emit_i32_load(buf, 8) // load element
  emit_i64_extend_i32_s(buf)
  buf.push((5).to_byte()) // else (regular array)
  // bounds check: trap if idx < 0 || idx >= length
  emit_local_get(buf, idx_local)
  emit_i32_const_raw(buf, 0)
  emit_i32_lt_s(buf)
  emit_local_get(buf, idx_local)
  emit_local_get(buf, arr_ptr)
  emit_i32_load(buf, 4) // length
  emit_i32_ge_s(buf)
  emit_i32_or(buf)
  buf.push((4).to_byte()) // if (out of bounds)
  buf.push((64).to_byte()) // void
  buf.push((0).to_byte()) // unreachable (trap)
  buf.push((11).to_byte()) // end if
  // offset = 8 + idx * 4
  emit_local_get(buf, arr_ptr)
  emit_local_get(buf, idx_local)
  emit_i32_const_raw(buf, 4)
  emit_i32_mul(buf)
  emit_i32_add(buf)
  emit_i32_load(buf, 8)
  emit_i64_extend_i32_s(buf)
  buf.push((11).to_byte()) // end if
}

///|
fn compile_array_get_gc_arm(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  if pos_args.length() != 2 {
    raise WasmGenError::Unsupported("Array::get arity")
  }
  let arr_kind = infer_expr_kind_gc(ctx, fctx, pos_args[0])
  let type_idx = gc_array_type_idx_from_kind(ctx, arr_kind, "Array::get")
  compile_expr_gc(ctx, fctx, buf, pos_args[0])
  // If the receiver is the struct{len, data} wrapper
  // (Array::with_capacity / ArrayBuilder), unwrap to data first.
  match gc_is_array_builder_struct_kind(ctx, arr_kind) {
    Some(struct_idx) => emit_struct_get_gc(buf, struct_idx, 1)
    None => ()
  }
  compile_expr_gc(ctx, fctx, buf, pos_args[1])
  let ik = infer_expr_kind_gc(ctx, fctx, pos_args[1])
  if ik == GcValKind::I64 {
    emit_i32_wrap_i64_gc(buf)
  }
  emit_array_get_gc(buf, type_idx)
}

///|
fn compile_array_set_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  // array_set(arr, idx, value) -> arr[idx] = value
  // Supports both obj_array (length at offset 4) and obj_array_view
  // (writes through to source[start+idx]).
  let pos_args = extract_positional_exprs_with_arity(args, "Array::set", 3)
  let ptr_local = alloc_temp_local(ctx)
  let idx_local = alloc_temp_local(ctx)
  let val_local = alloc_temp_local(ctx)
  // Evaluate all arguments first (preserve evaluation order)
  compile_expr_i32(ctx, buf, pos_args[0])
  emit_untag_ptr_i32(buf)
  emit_local_set(buf, ptr_local)
  emit_builder_follow_forwarding(ctx, buf, ptr_local)
  compile_expr_i32(ctx, buf, pos_args[1])
  emit_untag_int_i32(buf)
  emit_local_set(buf, idx_local)
  compile_expr_i32(ctx, buf, pos_args[2])
  emit_i32_wrap_i64(buf)
  emit_local_set(buf, val_local)
  // Dispatch on obj_array_view vs obj_array
  emit_local_get(buf, ptr_local)
  emit_i32_load(buf, 0) // obj_type
  emit_i32_const_raw(buf, obj_array_view)
  emit_i32_eq(buf)
  buf.push((4).to_byte()) // if (array_view)
  buf.push((64).to_byte()) // void
  // ArrayView: bounds check using length = end - start
  emit_local_get(buf, idx_local)
  emit_i32_const_raw(buf, 0)
  emit_i32_lt_s(buf)
  emit_local_get(buf, idx_local)
  emit_local_get(buf, ptr_local)
  emit_i32_load(buf, 12) // end
  emit_local_get(buf, ptr_local)
  emit_i32_load(buf, 8) // start
  emit_i32_sub(buf) // end - start
  emit_i32_ge_s(buf)
  emit_i32_or(buf)
  buf.push((4).to_byte()) // if (OOB)
  buf.push((64).to_byte()) // void
  buf.push((0).to_byte()) // unreachable
  buf.push((11).to_byte()) // end if
  // Compute addr = source_ptr + (start + idx) * 4 + 8
  emit_local_get(buf, ptr_local)
  emit_i32_load(buf, 4) // source_ptr
  emit_local_get(buf, ptr_local)
  emit_i32_load(buf, 8) // start
  emit_local_get(buf, idx_local)
  emit_i32_add(buf) // start + idx
  emit_i32_const_raw(buf, 4)
  emit_i32_mul(buf)
  emit_i32_add(buf) // source_ptr + (start + idx) * 4
  emit_local_get(buf, val_local)
  emit_i32_store(buf, 8) // store with +8 offset
  buf.push((5).to_byte()) // else (regular array)
  // bounds check: trap if idx < 0 || idx >= length
  emit_local_get(buf, idx_local)
  emit_i32_const_raw(buf, 0)
  emit_i32_lt_s(buf)
  emit_local_get(buf, idx_local)
  emit_local_get(buf, ptr_local)
  emit_i32_load(buf, 4) // length
  emit_i32_ge_s(buf)
  emit_i32_or(buf)
  buf.push((4).to_byte()) // if (out of bounds)
  buf.push((64).to_byte()) // void
  buf.push((0).to_byte()) // unreachable (trap)
  buf.push((11).to_byte()) // end if
  // addr = ptr + 8 + idx * 4
  emit_local_get(buf, ptr_local)
  emit_local_get(buf, idx_local)
  emit_i32_const_raw(buf, 4)
  emit_i32_mul(buf)
  emit_i32_add(buf)
  emit_local_get(buf, val_local)
  emit_i32_store(buf, 8)
  buf.push((11).to_byte()) // end if
  emit_i64_const_tagged(buf, 0L) // return Unit
}

///|
fn compile_array_set_gc_arm(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  if pos_args.length() != 3 {
    raise WasmGenError::Unsupported("Array::set arity")
  }
  let arr_kind = infer_expr_kind_gc(ctx, fctx, pos_args[0])
  let type_idx = gc_array_type_idx_from_kind(ctx, arr_kind, "Array::set")
  compile_expr_gc(ctx, fctx, buf, pos_args[0])
  match gc_is_array_builder_struct_kind(ctx, arr_kind) {
    Some(struct_idx) => emit_struct_get_gc(buf, struct_idx, 1)
    None => ()
  }
  compile_expr_gc(ctx, fctx, buf, pos_args[1])
  let ik = infer_expr_kind_gc(ctx, fctx, pos_args[1])
  if ik == GcValKind::I64 {
    emit_i32_wrap_i64_gc(buf)
  }
  compile_expr_gc(ctx, fctx, buf, pos_args[2])
  emit_array_set_gc(buf, type_idx)
  emit_i32_const_gc(buf, 0)
}

///|
fn compile_array_truncate_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  // array_truncate(arr, new_len) -> set arr.len = new_len
  let pos_args = extract_positional_exprs_with_arity(args, "Array::truncate", 2)
  let ptr_local = alloc_temp_local(ctx)
  compile_expr_i32(ctx, buf, pos_args[0])
  emit_untag_ptr_i32(buf)
  emit_local_set(buf, ptr_local)
  emit_builder_follow_forwarding(ctx, buf, ptr_local)
  emit_local_get(buf, ptr_local)
  compile_expr_i32(ctx, buf, pos_args[1])
  emit_untag_int_i32(buf)
  emit_i32_store(buf, 4)
  emit_i64_const_tagged(buf, 0L)
}

///|
fn compile_array_truncate_gc_arm(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  // Array::truncate(arr_builder, new_len) -> set len field
  if pos_args.length() != 2 {
    raise WasmGenError::Unsupported("Array::truncate arity")
  }
  let builder_kind = infer_expr_kind_gc(ctx, fctx, pos_args[0])
  let builder_type = match builder_kind {
    GcValKind::Ref(idx) => idx
    _ => raise WasmGenError::Unsupported("Array::truncate kind")
  }
  let b_idx = alloc_local_gc(fctx, builder_kind)
  compile_expr_gc(ctx, fctx, buf, pos_args[0])
  emit_local_set_gc(buf, b_idx)
  emit_local_get_gc(buf, b_idx)
  compile_expr_gc(ctx, fctx, buf, pos_args[1])
  let idx_kind = infer_expr_kind_gc(ctx, fctx, pos_args[1])
  if idx_kind == GcValKind::I64 {
    emit_i32_wrap_i64_gc(buf)
  }
  emit_struct_set_gc(buf, builder_type, 0)
  emit_i32_const_gc(buf, 0)
}

///|
fn compile_array_with_capacity_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  // Array::with_capacity(cap) -> allocate empty array with reserved
  // capacity `cap`. Same layout as `array_new` but len=0 instead
  // of len=cap, and no cell initialization (cap*4 bytes left as
  // whatever the heap allocator gave us — bounds checks via len=0
  // prevent any reads of those cells).
  // Layout: [cap:i32][tag:i32][len:i32][data...]
  let pos_args = extract_positional_exprs_with_arity(
    args, "Array::with_capacity", 1,
  )
  require_heap(ctx)
  let cap_local = alloc_temp_local(ctx)
  let base_local = alloc_temp_local(ctx)
  let obj_local = alloc_temp_local(ctx)
  let alloc_size_local = alloc_temp_local(ctx)
  // Evaluate cap (tagged int -> raw)
  compile_expr_i32(ctx, buf, pos_args[0])
  emit_untag_int_i32(buf)
  emit_local_set(buf, cap_local)
  // Alloc: 4 (cap prefix) + 8 (header) + cap*4, aligned
  emit_local_get(buf, cap_local)
  emit_i32_const_raw(buf, 4)
  emit_i32_mul(buf)
  emit_i32_const_raw(buf, 4 + 8 + 3)
  emit_i32_add(buf)
  emit_i32_const_raw(buf, -4)
  emit_i32_and(buf)
  emit_local_set(buf, alloc_size_local)
  emit_heap_alloc_local(ctx, buf, alloc_size_local, base_local)
  // Write capacity at base[0]
  emit_local_get(buf, base_local)
  emit_local_get(buf, cap_local)
  emit_i32_store(buf, 0)
  // obj = base + 4
  emit_local_get(buf, base_local)
  emit_i32_const_raw(buf, 4)
  emit_i32_add(buf)
  emit_local_set(buf, obj_local)
  // Set header: tag=obj_array, len=0
  emit_local_get(buf, obj_local)
  emit_i32_const_raw(buf, obj_array)
  emit_i32_store(buf, 0)
  emit_local_get(buf, obj_local)
  emit_i32_const_raw(buf, 0)
  emit_i32_store(buf, 4)
  // Return tagged obj
  emit_local_get(buf, obj_local)
  emit_i64_extend_i32_u(buf)
  emit_i64_const_raw(buf, tag_obj.to_int64())
  emit_i64_or(buf)
}

///|
fn compile_array_with_capacity_gc_arm(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  // Same struct layout as ArrayBuilder. Caller-supplied
  // capacity is used for the initial data allocation; len=0.
  if pos_args.length() != 1 {
    raise WasmGenError::Unsupported("Array::with_capacity arity")
  }
  let arr_type = ensure_array_type(
    ctx.types,
    ctx.array_type_index,
    GcValKind::I64,
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
  // len = 0
  emit_i32_const_gc(buf, 0)
  // data = array.new_default(cap)
  compile_expr_gc(ctx, fctx, buf, pos_args[0])
  let cap_kind = infer_expr_kind_gc(ctx, fctx, pos_args[0])
  if cap_kind == GcValKind::I64 {
    emit_i32_wrap_i64_gc(buf)
  }
  emit_array_new_default_gc(buf, arr_type)
  emit_struct_new_gc(buf, builder_type)
}

///|
fn compile_array_push_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  // array_push(arr, value) -> store value at [ptr + 8 + len*4], increment len
  // All arrays now have hidden capacity prefix at ptr[-4], same layout as ArrayBuilder.
  let pos_args = extract_positional_exprs_with_arity(args, "Array::push", 2)
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
fn compile_array_push_gc_arm(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  // Two paths:
  //   1. Bare-array receiver (default Array[T] kind on wasm-gc):
  //      Allocate a fresh array of len+1, copy elements, append.
  //      O(N) per push.
  //   2. Struct-wrapped receiver (Array::with_capacity result,
  //      shares ArrayBuilder layout {len:i32, data:ref array}):
  //      ArrayBuilder-style: if len < cap, write data[len] = v
  //      and len++. If full, double cap, array.copy, then write.
  //      Amortized O(1) per push.
  // If the receiver is a bare local binding (`Array::push(arr,
  // v)` where `arr` is an Ident → local var), the new array (path
  // 1) is written back into the local. Path 2 mutates the struct
  // in place, so no rebind is needed.
  if pos_args.length() != 2 {
    raise WasmGenError::Unsupported("Array::push arity")
  }
  let arr_kind = infer_expr_kind_gc(ctx, fctx, pos_args[0])
  match gc_is_array_builder_struct_kind(ctx, arr_kind) {
    Some(builder_type) => {
      // Path 2: doubling push on struct{len, data}. Shared
      // with ArrayBuilder::push via compile_struct_array_push_gc.
      let arr_type = match ctx.types[builder_type] {
        GcTypeDef::Struct(fields~) =>
          match fields[1] {
            GcValKind::Ref(idx) => idx
            _ => raise WasmGenError::Unsupported("Array::push struct data kind")
          }
        _ => raise WasmGenError::Unsupported("Array::push struct kind")
      }
      compile_struct_array_push_gc(
        ctx,
        fctx,
        buf,
        pos_args[0],
        pos_args[1],
        arr_kind,
        builder_type,
        arr_type,
      )
    }
    None => {
      // Path 1: bare array, realloc-per-push (pre-existing
      // wasm-gc behavior).
      let type_idx = gc_array_type_idx_from_kind(ctx, arr_kind, "Array::push")
      let old_arr = alloc_local_gc(fctx, arr_kind)
      let new_arr = alloc_local_gc(fctx, arr_kind)
      let len_l = alloc_local_gc(fctx, GcValKind::I32)
      let i_l = alloc_local_gc(fctx, GcValKind::I32)
      compile_expr_gc(ctx, fctx, buf, pos_args[0])
      emit_local_set_gc(buf, old_arr)
      emit_local_get_gc(buf, old_arr)
      emit_array_len_gc(buf)
      emit_local_set_gc(buf, len_l)
      // new array of len+1
      emit_local_get_gc(buf, len_l)
      emit_i32_const_gc(buf, 1)
      emit_i32_add_gc(buf)
      emit_array_new_default_gc(buf, type_idx)
      emit_local_set_gc(buf, new_arr)
      // copy loop
      emit_i32_const_gc(buf, 0)
      emit_local_set_gc(buf, i_l)
      emit_block_gc(buf, None)
      emit_loop_gc(buf, None)
      emit_local_get_gc(buf, i_l)
      emit_local_get_gc(buf, len_l)
      emit_i32_ge_s_gc(buf)
      emit_br_if_gc(buf, 1)
      emit_local_get_gc(buf, new_arr)
      emit_local_get_gc(buf, i_l)
      emit_local_get_gc(buf, old_arr)
      emit_local_get_gc(buf, i_l)
      emit_array_get_gc(buf, type_idx)
      emit_array_set_gc(buf, type_idx)
      emit_local_get_gc(buf, i_l)
      emit_i32_const_gc(buf, 1)
      emit_i32_add_gc(buf)
      emit_local_set_gc(buf, i_l)
      emit_br_gc(buf, 0)
      emit_end_gc(buf)
      emit_end_gc(buf)
      // set last element
      emit_local_get_gc(buf, new_arr)
      emit_local_get_gc(buf, len_l)
      compile_expr_gc(ctx, fctx, buf, pos_args[1])
      emit_array_set_gc(buf, type_idx)
      // Write the new array back into the receiver's local so
      // the caller's binding observes the growth.
      match pos_args[0] {
        @core.Expr::Ident(name~, ..) =>
          match fctx.locals.get(name) {
            Some(info) => {
              emit_local_get_gc(buf, new_arr)
              emit_local_set_gc(buf, info.idx)
            }
            None => () // captured from outer scope: silently no-op (pre-existing wasm-gc gap)
          }
        _ => () // complex receiver: silently no-op
      }
      emit_i32_const_gc(buf, 0)
    }
  }
}
