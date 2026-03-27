///|
let post_user_builtin_unhandled_marker = "__post_user_builtin_unhandled__"

///|
fn compile_call_builtin_post_user(
  ctx : CodegenCtx,
  buf : ByteBuf,
  name : String,
  args : Array[@core.CallArg],
) -> Bool raise WasmGenError {
  let result : Result[Unit, WasmGenError] = try? compile_call_builtin_post_user_inner(
    ctx, buf, name, args,
  )
  match result {
    Ok(_) => true
    Err(WasmGenError::Unsupported(message)) =>
      if message == post_user_builtin_unhandled_marker {
        false
      } else {
        raise WasmGenError::Unsupported(message)
      }
    Err(err) => raise err
  }
}

///|
fn compile_call_builtin_post_user_inner(
  ctx : CodegenCtx,
  buf : ByteBuf,
  name : String,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  match name {
    "Path::ref" => {
      // path_ref(s) -> same as path(s), calls the host import vibe.path
      let pos_args = extract_positional_exprs_with_arity(args, "Path::ref", 1)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_heap_pre_call_sync(ctx, buf)
      emit_call(buf, import_index_path(ctx))
      emit_heap_post_call_sync(ctx, buf)
    }
    "Path::resolve" => {
      // dynamic_path_resolve(s) -> host import vibe.resolve_path
      let pos_args = extract_positional_exprs_with_arity(
        args, "Path::resolve", 1,
      )
      compile_expr(ctx, buf, pos_args[0])
      emit_heap_pre_call_sync(ctx, buf)
      emit_call(buf, import_index_dynamic_path_resolve(ctx))
      emit_heap_post_call_sync(ctx, buf)
    }
    "Path::is_absolute" => {
      // path_is_absolute(path) -> check if first byte is '/'
      // In wasm, Path and String share the same object representation
      let pos_args = extract_positional_exprs_with_arity(
        args, "Path::is_absolute", 1,
      )
      let str_ptr_local = alloc_temp_local(ctx)
      let str_len_local = alloc_temp_local(ctx)
      // Untag pointer (Path has same layout as String: tag_obj)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_i64_const_raw(buf, (-4).to_int64())
      emit_i64_and(buf)
      emit_i32_wrap_i64(buf)
      emit_local_set(buf, str_ptr_local)
      // Load string length
      emit_local_get(buf, str_ptr_local)
      emit_i32_load(buf, 4)
      emit_local_set(buf, str_len_local)
      // If length > 0 and first byte == '/' (47), return true
      emit_local_get(buf, str_len_local)
      emit_i32_const_raw(buf, 0)
      emit_i32_gt_s(buf)
      buf.push((4).to_byte()) // if
      buf.push((127).to_byte()) // result i32
      emit_local_get(buf, str_ptr_local)
      emit_i32_load8_u(buf, 8) // first byte at offset 8
      emit_i32_const_raw(buf, 47) // '/'
      emit_i32_eq(buf)
      buf.push((5).to_byte()) // else
      emit_i32_const_raw(buf, 0) // false
      buf.push((11).to_byte()) // end if
      // Tag as bool: 0 or 1 -> tagged
      emit_i64_extend_i32_s(buf)
      emit_i64_const_raw(buf, 2L)
      emit_i64_shl(buf)
      // tag_int = 0, i64.or is a no-op
    }
    "Path::to_string" => {
      // path_to_string(path) -> path is stored as string pointer in wasm, pass through
      let pos_args = extract_positional_exprs_with_arity(
        args, "Path::to_string", 1,
      )
      // In wasm, Path and String share the same object representation (string pointer)
      // so path_to_string is identity
      compile_expr(ctx, buf, pos_args[0])
    }
    "String::utf8_length" => {
      // string_utf8_length(s) -> in non-js-string mode, string_length IS utf8 length
      // because strings are stored as UTF-8 bytes
      let pos_args = extract_positional_exprs_with_arity(
        args, "String::utf8_length", 1,
      )
      if ctx.use_js_strings {
        // JS strings are UTF-16; need host import for UTF-8 byte counting
        raise WasmGenError::BackendLimit(
          backend="wasm-js-string",
          feature="String::utf8_length",
        )
      } else {
        // Non-js-string: strings are UTF-8, so length field = UTF-8 byte count
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_i64_const_raw(buf, (-4).to_int64())
        emit_i64_and(buf)
        emit_i32_wrap_i64(buf)
        emit_i32_load(buf, 4)
        emit_i64_extend_i32_s(buf)
        emit_i64_const_raw(buf, 2L)
        emit_i64_shl(buf)
        // tag_int = 0, i64.or is a no-op
      }
    }
    "String::utf16_length" | "String::unicode_length" => {
      // In non-js-string mode, strings are UTF-8 bytes.
      // string_utf16_length: count UTF-16 code units from UTF-8
      // string_unicode_length: count Unicode codepoints from UTF-8
      let pos_args = extract_positional_exprs_with_arity(args, name, 1)
      if ctx.use_js_strings {
        raise WasmGenError::BackendLimit(backend="wasm-js-string", feature=name)
      } else {
        let str_ptr_local = alloc_temp_local(ctx)
        let str_len_local = alloc_temp_local(ctx)
        let loop_i_local = alloc_temp_local(ctx)
        let count_local = alloc_temp_local(ctx)
        let byte_local = alloc_temp_local(ctx)
        // Untag string pointer
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_i64_const_raw(buf, (-4).to_int64())
        emit_i64_and(buf)
        emit_i32_wrap_i64(buf)
        emit_local_set(buf, str_ptr_local)
        // Load string byte length
        emit_local_get(buf, str_ptr_local)
        emit_i32_load(buf, 4)
        emit_local_set(buf, str_len_local)
        // Initialize loop variables
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, loop_i_local)
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, count_local)
        // Loop through UTF-8 bytes
        emit_block(buf) // block
        emit_loop(buf) // loop
        // if i >= len: break
        emit_local_get(buf, loop_i_local)
        emit_local_get(buf, str_len_local)
        emit_i32_ge_s(buf)
        emit_br_if(buf, 1) // break to block
        // Load byte at str_ptr + 8 + i
        emit_local_get(buf, str_ptr_local)
        emit_local_get(buf, loop_i_local)
        emit_i32_add(buf)
        emit_i32_load8_u(buf, 8)
        emit_local_set(buf, byte_local)
        // Check byte ranges to determine UTF-8 sequence length
        // if byte >= 0xF0: 4-byte sequence
        emit_local_get(buf, byte_local)
        emit_i32_const_raw(buf, 0xF0)
        emit_i32_ge_s(buf)
        buf.push((4).to_byte()) // if
        buf.push((64).to_byte()) // void
        // 4-byte: i += 4
        emit_local_get(buf, loop_i_local)
        emit_i32_const_raw(buf, 4)
        emit_i32_add(buf)
        emit_local_set(buf, loop_i_local)
        if name == "String::utf16_length" {
          // 4-byte UTF-8 = 2 UTF-16 code units (surrogate pair)
          emit_local_get(buf, count_local)
          emit_i32_const_raw(buf, 2)
          emit_i32_add(buf)
          emit_local_set(buf, count_local)
        } else {
          // unicode_length: 4-byte = 1 codepoint
          emit_local_get(buf, count_local)
          emit_i32_const_raw(buf, 1)
          emit_i32_add(buf)
          emit_local_set(buf, count_local)
        }
        buf.push((5).to_byte()) // else
        // if byte >= 0xE0: 3-byte sequence
        emit_local_get(buf, byte_local)
        emit_i32_const_raw(buf, 0xE0)
        emit_i32_ge_s(buf)
        buf.push((4).to_byte()) // if
        buf.push((64).to_byte()) // void
        emit_local_get(buf, loop_i_local)
        emit_i32_const_raw(buf, 3)
        emit_i32_add(buf)
        emit_local_set(buf, loop_i_local)
        emit_local_get(buf, count_local)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, count_local)
        buf.push((5).to_byte()) // else
        // if byte >= 0xC0: 2-byte sequence
        emit_local_get(buf, byte_local)
        emit_i32_const_raw(buf, 0xC0)
        emit_i32_ge_s(buf)
        buf.push((4).to_byte()) // if
        buf.push((64).to_byte()) // void
        emit_local_get(buf, loop_i_local)
        emit_i32_const_raw(buf, 2)
        emit_i32_add(buf)
        emit_local_set(buf, loop_i_local)
        emit_local_get(buf, count_local)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, count_local)
        buf.push((5).to_byte()) // else
        // 1-byte (ASCII)
        emit_local_get(buf, loop_i_local)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, loop_i_local)
        emit_local_get(buf, count_local)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, count_local)
        buf.push((11).to_byte()) // end if (>= 0xC0)
        buf.push((11).to_byte()) // end if (>= 0xE0)
        buf.push((11).to_byte()) // end if (>= 0xF0)
        emit_br(buf, 0) // continue loop
        emit_end(buf) // end loop
        emit_end(buf) // end block
        // Tag result as int
        emit_local_get(buf, count_local)
        emit_i64_extend_i32_s(buf)
        emit_i64_const_raw(buf, 2L)
        emit_i64_shl(buf)
        // tag_int = 0, i64.or is a no-op
      }
    }
    "Array::concat" => {
      // array_concat(xs, ys) -> new array with all elements from xs then ys
      // Uses memory.copy for bulk transfer instead of element-by-element loops.
      let pos_args = extract_positional_exprs_with_arity(
        args, "Array::concat", 2,
      )
      require_heap(ctx)
      let xs_ptr_local = alloc_temp_local(ctx)
      let xs_len_local = alloc_temp_local(ctx)
      let ys_ptr_local = alloc_temp_local(ctx)
      let ys_len_local = alloc_temp_local(ctx)
      let total_len_local = alloc_temp_local(ctx)
      let obj_local = alloc_temp_local(ctx)
      let alloc_size_local = alloc_temp_local(ctx)
      // Untag xs pointer
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_i64_const_raw(buf, (-4).to_int64())
      emit_i64_and(buf)
      emit_i32_wrap_i64(buf)
      emit_local_set(buf, xs_ptr_local)
      emit_local_get(buf, xs_ptr_local)
      emit_i32_load(buf, 4)
      emit_local_set(buf, xs_len_local)
      // Untag ys pointer
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_i64_const_raw(buf, (-4).to_int64())
      emit_i64_and(buf)
      emit_i32_wrap_i64(buf)
      emit_local_set(buf, ys_ptr_local)
      emit_local_get(buf, ys_ptr_local)
      emit_i32_load(buf, 4)
      emit_local_set(buf, ys_len_local)
      // total_len = xs_len + ys_len
      emit_local_get(buf, xs_len_local)
      emit_local_get(buf, ys_len_local)
      emit_i32_add(buf)
      emit_local_set(buf, total_len_local)
      // alloc_size = align4(8 + total_len * 4)
      emit_local_get(buf, total_len_local)
      emit_i32_const_raw(buf, 4)
      emit_i32_mul(buf)
      emit_i32_const_raw(buf, 8 + 3)
      emit_i32_add(buf)
      emit_i32_const_raw(buf, -4)
      emit_i32_and(buf)
      emit_local_set(buf, alloc_size_local)
      // Allocate
      emit_heap_alloc_local(ctx, buf, alloc_size_local, obj_local)
      // Set type = obj_array
      emit_local_get(buf, obj_local)
      emit_i32_const_raw(buf, obj_array)
      emit_i32_store(buf, 0)
      // Set length = total_len
      emit_local_get(buf, obj_local)
      emit_local_get(buf, total_len_local)
      emit_i32_store(buf, 4)
      // memory.copy xs: dst=obj+8, src=xs_ptr+8, len=xs_len*4
      emit_local_get(buf, obj_local)
      emit_i32_const_raw(buf, 8)
      emit_i32_add(buf)
      emit_local_get(buf, xs_ptr_local)
      emit_i32_const_raw(buf, 8)
      emit_i32_add(buf)
      emit_local_get(buf, xs_len_local)
      emit_i32_const_raw(buf, 4)
      emit_i32_mul(buf)
      emit_memory_copy(buf)
      // memory.copy ys: dst=obj+8+xs_len*4, src=ys_ptr+8, len=ys_len*4
      emit_local_get(buf, obj_local)
      emit_i32_const_raw(buf, 8)
      emit_i32_add(buf)
      emit_local_get(buf, xs_len_local)
      emit_i32_const_raw(buf, 4)
      emit_i32_mul(buf)
      emit_i32_add(buf)
      emit_local_get(buf, ys_ptr_local)
      emit_i32_const_raw(buf, 8)
      emit_i32_add(buf)
      emit_local_get(buf, ys_len_local)
      emit_i32_const_raw(buf, 4)
      emit_i32_mul(buf)
      emit_memory_copy(buf)
      // Return tagged pointer
      emit_local_get(buf, obj_local)
      emit_i64_extend_i32_u(buf)
      emit_i64_const_raw(buf, tag_obj.to_int64())
      emit_i64_or(buf)
    }
    "Array::push_all" => {
      // array_push_all(dst, src) -> Unit: append all elements of src to dst in-place
      // Uses memory.copy for bulk transfer instead of element-by-element loop.
      let pos_args = extract_positional_exprs_with_arity(
        args, "Array::push_all", 2,
      )
      let dst_ptr_local = alloc_temp_local(ctx)
      let dst_len_local = alloc_temp_local(ctx)
      let src_ptr_local = alloc_temp_local(ctx)
      let src_len_local = alloc_temp_local(ctx)
      // Untag dst pointer
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_i64_const_raw(buf, (-4).to_int64())
      emit_i64_and(buf)
      emit_i32_wrap_i64(buf)
      emit_local_set(buf, dst_ptr_local)
      emit_local_get(buf, dst_ptr_local)
      emit_i32_load(buf, 4) // dst.len
      emit_local_set(buf, dst_len_local)
      // Untag src pointer
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_i64_const_raw(buf, (-4).to_int64())
      emit_i64_and(buf)
      emit_i32_wrap_i64(buf)
      emit_local_set(buf, src_ptr_local)
      emit_local_get(buf, src_ptr_local)
      emit_i32_load(buf, 4) // src.len
      emit_local_set(buf, src_len_local)
      // memory.copy(dst_data + dst_len*4, src_data + 0, src_len*4)
      // dst = dst_ptr + 8 + dst_len * 4
      emit_local_get(buf, dst_ptr_local)
      emit_i32_const_raw(buf, 8)
      emit_i32_add(buf)
      emit_local_get(buf, dst_len_local)
      emit_i32_const_raw(buf, 4)
      emit_i32_mul(buf)
      emit_i32_add(buf)
      // src = src_ptr + 8
      emit_local_get(buf, src_ptr_local)
      emit_i32_const_raw(buf, 8)
      emit_i32_add(buf)
      // size = src_len * 4
      emit_local_get(buf, src_len_local)
      emit_i32_const_raw(buf, 4)
      emit_i32_mul(buf)
      // memory.copy
      emit_memory_copy(buf)
      // dst.len += src_len
      emit_local_get(buf, dst_ptr_local)
      emit_local_get(buf, dst_len_local)
      emit_local_get(buf, src_len_local)
      emit_i32_add(buf)
      emit_i32_store(buf, 4)
      // return Unit (tagged 0)
      emit_i64_const_tagged(buf, 0L)
    }
    "Array::slice" => {
      // array_slice(arr, start, end) -> new array with elements arr[start..end]
      let pos_args = extract_positional_exprs_with_arity(
        args, "Array::slice", 3,
      )
      require_heap(ctx)
      let arr_ptr_local = alloc_temp_local(ctx)
      let arr_len_local = alloc_temp_local(ctx)
      let start_local = alloc_temp_local(ctx)
      let end_local = alloc_temp_local(ctx)
      let slice_len_local = alloc_temp_local(ctx)
      let obj_local = alloc_temp_local(ctx)
      let _copy_i_local = alloc_temp_local(ctx)
      let alloc_size_local = alloc_temp_local(ctx)
      // Untag array pointer
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_i64_const_raw(buf, (-4).to_int64())
      emit_i64_and(buf)
      emit_i32_wrap_i64(buf)
      emit_local_set(buf, arr_ptr_local)
      // Load array length
      emit_local_get(buf, arr_ptr_local)
      emit_i32_load(buf, 4)
      emit_local_set(buf, arr_len_local)
      // Untag start
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_i64_const_raw(buf, 2L)
      emit_i64_shr_s(buf)
      emit_i32_wrap_i64(buf)
      emit_local_set(buf, start_local)
      // Untag end
      compile_expr_i32(ctx, buf, pos_args[2])
      emit_i64_const_raw(buf, 2L)
      emit_i64_shr_s(buf)
      emit_i32_wrap_i64(buf)
      emit_local_set(buf, end_local)
      // Clamp start: if start < 0 then start = 0
      emit_local_get(buf, start_local)
      emit_i32_const_raw(buf, 0)
      emit_i32_lt_s(buf)
      buf.push((4).to_byte()) // if
      buf.push((64).to_byte()) // void
      emit_i32_const_raw(buf, 0)
      emit_local_set(buf, start_local)
      buf.push((11).to_byte()) // end if
      // Clamp start: if start > len then start = len
      emit_local_get(buf, arr_len_local)
      emit_local_get(buf, start_local)
      emit_i32_lt_s(buf)
      buf.push((4).to_byte()) // if
      buf.push((64).to_byte()) // void
      emit_local_get(buf, arr_len_local)
      emit_local_set(buf, start_local)
      buf.push((11).to_byte()) // end if
      // Clamp end: if end < 0 then end = 0
      emit_local_get(buf, end_local)
      emit_i32_const_raw(buf, 0)
      emit_i32_lt_s(buf)
      buf.push((4).to_byte()) // if
      buf.push((64).to_byte()) // void
      emit_i32_const_raw(buf, 0)
      emit_local_set(buf, end_local)
      buf.push((11).to_byte()) // end if
      // Clamp end: if end > len then end = len
      emit_local_get(buf, arr_len_local)
      emit_local_get(buf, end_local)
      emit_i32_lt_s(buf)
      buf.push((4).to_byte()) // if
      buf.push((64).to_byte()) // void
      emit_local_get(buf, arr_len_local)
      emit_local_set(buf, end_local)
      buf.push((11).to_byte()) // end if
      // If start > end then start = end (empty slice)
      emit_local_get(buf, end_local)
      emit_local_get(buf, start_local)
      emit_i32_lt_s(buf)
      buf.push((4).to_byte()) // if
      buf.push((64).to_byte()) // void
      emit_local_get(buf, start_local)
      emit_local_set(buf, end_local)
      buf.push((11).to_byte()) // end if
      // slice_len = end - start
      emit_local_get(buf, end_local)
      emit_local_get(buf, start_local)
      emit_i32_sub(buf)
      emit_local_set(buf, slice_len_local)
      // alloc_size = align4(8 + max(slice_len, 16384) * 4)
      // Reserve extra capacity so that array_push can append without realloc
      // NOTE: array_push has no bounds check/realloc — this min_cap must be large
      // enough for all use cases. 16384 covers the selfhost parser (~12000 tokens).
      // TODO: implement proper capacity management with realloc in array_push.
      let min_cap = 16384
      emit_local_get(buf, slice_len_local)
      emit_i32_const_raw(buf, min_cap)
      emit_i32_gt_s(buf)
      buf.push((4).to_byte()) // if
      buf.push((127).to_byte()) // result i32
      emit_local_get(buf, slice_len_local)
      buf.push((5).to_byte()) // else
      emit_i32_const_raw(buf, min_cap)
      buf.push((11).to_byte()) // end if
      emit_i32_const_raw(buf, 4)
      emit_i32_mul(buf)
      emit_i32_const_raw(buf, 8 + 3) // header + alignment
      emit_i32_add(buf)
      emit_i32_const_raw(buf, -4)
      emit_i32_and(buf)
      emit_local_set(buf, alloc_size_local)
      // Allocate
      emit_heap_alloc_local(ctx, buf, alloc_size_local, obj_local)
      // Set type = obj_array
      emit_local_get(buf, obj_local)
      emit_i32_const_raw(buf, obj_array)
      emit_i32_store(buf, 0)
      // Set length
      emit_local_get(buf, obj_local)
      emit_local_get(buf, slice_len_local)
      emit_i32_store(buf, 4)
      // memory.copy: dst=obj+8, src=arr_ptr+8+start*4, len=slice_len*4
      emit_local_get(buf, obj_local)
      emit_i32_const_raw(buf, 8)
      emit_i32_add(buf)
      emit_local_get(buf, arr_ptr_local)
      emit_i32_const_raw(buf, 8)
      emit_i32_add(buf)
      emit_local_get(buf, start_local)
      emit_i32_const_raw(buf, 4)
      emit_i32_mul(buf)
      emit_i32_add(buf)
      emit_local_get(buf, slice_len_local)
      emit_i32_const_raw(buf, 4)
      emit_i32_mul(buf)
      emit_memory_copy(buf)
      // Return tagged pointer
      emit_local_get(buf, obj_local)
      emit_i64_extend_i32_u(buf)
      emit_i64_const_raw(buf, tag_obj.to_int64())
      emit_i64_or(buf)
    }
    _ => raise WasmGenError::Unsupported(post_user_builtin_unhandled_marker)
  }
}
