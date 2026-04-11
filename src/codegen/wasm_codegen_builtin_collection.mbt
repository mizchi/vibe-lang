///|
fn compile_builtin_collection(
  ctx : CodegenCtx,
  buf : ByteBuf,
  name : String,
  args : Array[@core.CallArg],
  is_user_fn : Bool,
) -> Unit raise WasmGenError {
  match name {
    "ArrayBuilder::new" => {
      // array_builder() -> allocate empty array obj with len=0
      // Uses hidden capacity prefix at obj_ptr-4 for grow-on-overflow in push.
      let obj_local = alloc_temp_local(ctx)
      emit_builder_alloc(ctx, buf, builder_initial_cap, 4, obj_array, obj_local)
      emit_local_get(buf, obj_local)
      emit_i64_extend_i32_u(buf)
      emit_i64_const_raw(buf, tag_obj.to_int64())
      emit_i64_or(buf)
    }
    "ArrayBuilder::push" => {
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
      // Write updated pointer back to caller local if realloc happened (see #285).
      emit_writeback_builder_ptr_if_local(ctx, buf, pos_args[0], ptr_local)
      // return unit
      emit_i64_const_tagged(buf, 0L)
    }
    "ArrayBuilder::freeze" => {
      // array_builder_freeze(builder) -> return builder as-is (it is already an array obj)
      let pos_args = extract_positional_exprs_with_arity(
        args, "ArrayBuilder::freeze", 1,
      )
      compile_expr_i32(ctx, buf, pos_args[0])
    }
    "Array::push" => {
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
      // Write updated pointer back to caller local if realloc happened (see #285).
      emit_writeback_builder_ptr_if_local(ctx, buf, pos_args[0], ptr_local)
      // return unit
      emit_i64_const_tagged(buf, 0L)
    }
    "array_new" => {
      // array_new(size, default_val) -> allocate array with given size, fill with default
      // Layout: [cap:i32][tag:i32][len:i32][data...] — cap prefix for grow-on-push.
      // obj_local points to tag field (base + 4).
      let pos_args = extract_positional_exprs_with_arity(args, "array_new", 2)
      require_heap(ctx)
      let size_local = alloc_temp_local(ctx)
      let val_local = alloc_temp_local(ctx)
      let base_local = alloc_temp_local(ctx)
      let obj_local = alloc_temp_local(ctx)
      let idx_local = alloc_temp_local(ctx)
      let alloc_size_local = alloc_temp_local(ctx)
      // Evaluate size (tagged int -> raw)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_int_i32(buf)
      emit_local_set(buf, size_local)
      // Evaluate default value
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_i32_wrap_i64(buf)
      emit_local_set(buf, val_local)
      // Alloc: 4 (cap prefix) + 8 (header) + size*4, aligned
      emit_local_get(buf, size_local)
      emit_i32_const_raw(buf, 4)
      emit_i32_mul(buf)
      emit_i32_const_raw(buf, 4 + 8 + 3) // cap prefix + header + alignment
      emit_i32_add(buf)
      emit_i32_const_raw(buf, -4)
      emit_i32_and(buf)
      emit_local_set(buf, alloc_size_local)
      // heap alloc
      emit_heap_alloc_local(ctx, buf, alloc_size_local, base_local)
      // Write capacity at base[0]
      emit_local_get(buf, base_local)
      emit_local_get(buf, size_local)
      emit_i32_store(buf, 0)
      // obj = base + 4
      emit_local_get(buf, base_local)
      emit_i32_const_raw(buf, 4)
      emit_i32_add(buf)
      emit_local_set(buf, obj_local)
      // Set header: tag=obj_array, len=size
      emit_local_get(buf, obj_local)
      emit_i32_const_raw(buf, obj_array)
      emit_i32_store(buf, 0)
      emit_local_get(buf, obj_local)
      emit_local_get(buf, size_local)
      emit_i32_store(buf, 4)
      // Fill with default value
      emit_i32_const_raw(buf, 0)
      emit_local_set(buf, idx_local)
      // loop
      emit_block(buf)
      emit_loop(buf)
      emit_local_get(buf, idx_local)
      emit_local_get(buf, size_local)
      emit_i32_ge_s(buf)
      emit_br_if(buf, 1) // break if idx >= size
      emit_local_get(buf, obj_local)
      emit_local_get(buf, idx_local)
      emit_i32_const_raw(buf, 4)
      emit_i32_mul(buf)
      emit_i32_add(buf)
      emit_local_get(buf, val_local)
      emit_i32_store(buf, 8)
      emit_local_get(buf, idx_local)
      emit_i32_const_raw(buf, 1)
      emit_i32_add(buf)
      emit_local_set(buf, idx_local)
      emit_br(buf, 0) // continue
      emit_end(buf) // end loop
      emit_end(buf) // end block
      // Return tagged obj
      emit_local_get(buf, obj_local)
      emit_i64_extend_i32_u(buf)
      emit_i64_const_raw(buf, tag_obj.to_int64())
      emit_i64_or(buf)
    }
    "Array::truncate" => {
      // array_truncate(arr, new_len) -> set arr.len = new_len
      let pos_args = extract_positional_exprs_with_arity(
        args, "Array::truncate", 2,
      )
      let ptr_local = alloc_temp_local(ctx)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, ptr_local)
      emit_local_get(buf, ptr_local)
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_untag_int_i32(buf)
      emit_i32_store(buf, 4)
      emit_i64_const_tagged(buf, 0L)
    }
    "array_contains_str" => {
      // array_contains_str(arr, str) -> Bool
      // Linear scan: compare each element string with str using content comparison
      let pos_args = extract_positional_exprs_with_arity(
        args, "array_contains_str", 2,
      )
      require_heap(ctx)
      let arr_ptr = alloc_temp_local(ctx)
      let needle = alloc_temp_local_with_kind(ctx, ValueKind::I64)
      let len_local = alloc_temp_local(ctx)
      let idx_local = alloc_temp_local(ctx)
      let result_local = alloc_temp_local(ctx)
      let elem_local = alloc_temp_local_with_kind(ctx, ValueKind::I64)
      let needle_ptr = alloc_temp_local(ctx)
      let needle_len = alloc_temp_local(ctx)
      let elem_ptr = alloc_temp_local(ctx)
      let elem_len = alloc_temp_local(ctx)
      let cmp_i = alloc_temp_local(ctx)
      let str_eq = alloc_temp_local(ctx)
      // Get array pointer
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, arr_ptr)
      // Get needle string (tagged) and compute untagged pointer + length
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_local_set(buf, needle)
      emit_local_get(buf, needle)
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, needle_ptr)
      emit_local_get(buf, needle_ptr)
      emit_i32_load(buf, 4)
      emit_local_set(buf, needle_len)
      // array len
      emit_local_get(buf, arr_ptr)
      emit_i32_load(buf, 4)
      emit_local_set(buf, len_local)
      // result = false
      emit_i32_const_raw(buf, 0)
      emit_local_set(buf, result_local)
      emit_i32_const_raw(buf, 0)
      emit_local_set(buf, idx_local)
      // Loop over elements
      emit_block(buf)
      emit_loop(buf)
      emit_local_get(buf, idx_local)
      emit_local_get(buf, len_local)
      emit_i32_ge_s(buf)
      emit_br_if(buf, 1) // break if done
      // Load element (tagged i32 -> i64)
      emit_local_get(buf, arr_ptr)
      emit_local_get(buf, idx_local)
      emit_i32_const_raw(buf, 4)
      emit_i32_mul(buf)
      emit_i32_add(buf)
      emit_i32_load(buf, 8)
      emit_i64_extend_i32_u(buf)
      emit_local_set(buf, elem_local)
      // Get element untagged pointer
      emit_local_get(buf, elem_local)
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, elem_ptr)
      // Fast path: pointer equality
      emit_local_get(buf, elem_ptr)
      emit_local_get(buf, needle_ptr)
      emit_i32_eq(buf)
      emit_if(buf) // void if — pointers match
      emit_i32_const_raw(buf, 1)
      emit_local_set(buf, result_local)
      emit_local_get(buf, len_local)
      emit_local_set(buf, idx_local) // force break
      emit_else(buf)
      // Compare string lengths
      emit_local_get(buf, elem_ptr)
      emit_i32_load(buf, 4) // elem string length
      emit_local_set(buf, elem_len)
      emit_local_get(buf, elem_len)
      emit_local_get(buf, needle_len)
      emit_i32_eq(buf)
      emit_if(buf) // void if — lengths match, compare bytes
      emit_i32_const_raw(buf, 1)
      emit_local_set(buf, str_eq)
      emit_i32_const_raw(buf, 0)
      emit_local_set(buf, cmp_i)
      // Byte comparison loop
      emit_block(buf)
      emit_loop(buf)
      emit_local_get(buf, cmp_i)
      emit_local_get(buf, elem_len)
      emit_i32_ge_s(buf)
      emit_br_if(buf, 1) // break if all bytes compared
      emit_local_get(buf, elem_ptr)
      emit_local_get(buf, cmp_i)
      emit_i32_add(buf)
      emit_i32_load8_u(buf, 8) // elem byte at offset 8 + cmp_i
      emit_local_get(buf, needle_ptr)
      emit_local_get(buf, cmp_i)
      emit_i32_add(buf)
      emit_i32_load8_u(buf, 8) // needle byte at offset 8 + cmp_i
      emit_i32_eq(buf)
      emit_i32_eqz(buf)
      emit_if(buf) // void if — bytes differ
      emit_i32_const_raw(buf, 0)
      emit_local_set(buf, str_eq)
      emit_local_get(buf, elem_len) // force exit byte loop
      emit_local_set(buf, cmp_i)
      emit_else(buf)
      emit_local_get(buf, cmp_i)
      emit_i32_const_raw(buf, 1)
      emit_i32_add(buf)
      emit_local_set(buf, cmp_i)
      emit_end(buf) // end if (byte compare)
      emit_br(buf, 0) // continue byte loop
      emit_end(buf) // end loop (byte loop)
      emit_end(buf) // end block (byte loop)
      // If str_eq is still 1, we found a match
      emit_local_get(buf, str_eq)
      emit_if(buf) // void if — string content matches
      emit_i32_const_raw(buf, 1)
      emit_local_set(buf, result_local)
      emit_local_get(buf, len_local) // force break
      emit_local_set(buf, idx_local)
      emit_end(buf) // end if (str_eq)
      emit_end(buf) // end if (length match)
      // Increment index
      emit_local_get(buf, idx_local)
      emit_i32_const_raw(buf, 1)
      emit_i32_add(buf)
      emit_local_set(buf, idx_local)
      emit_end(buf) // end else (pointer mismatch)
      emit_br(buf, 0) // continue outer loop
      emit_end(buf) // end loop (outer)
      emit_end(buf) // end block (outer)
      // Return tagged bool (val << 2)
      emit_local_get(buf, result_local)
      emit_i64_extend_i32_u(buf)
      emit_i64_const_raw(buf, 2L)
      emit_i64_shl(buf)
    }
    "MapBuilder::new" => {
      // MapBuilder::new() -> allocate empty map obj with len=0
      // Uses hidden capacity prefix at obj_ptr-4 for grow-on-overflow in set.
      let obj_local = alloc_temp_local(ctx)
      emit_builder_alloc(ctx, buf, builder_initial_cap, 8, obj_map, obj_local)
      emit_local_get(buf, obj_local)
      emit_i64_extend_i32_u(buf)
      emit_i64_const_raw(buf, tag_obj.to_int64())
      emit_i64_or(buf)
    }
    "MapBuilder::set" => {
      // MapBuilder::set(builder, key, value) -> overwrite existing key or append new pair
      // Grows capacity when full (heap-tip extension or trap).
      let pos_args = extract_positional_exprs_with_arity(
        args, "MapBuilder::set", 3,
      )
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
      // Write updated pointer back to caller local if realloc happened (see #285).
      emit_writeback_builder_ptr_if_local(ctx, buf, pos_args[0], ptr_local)
      // return unit
      emit_i64_const_tagged(buf, 0L)
    }
    "MapBuilder::freeze" => {
      // MapBuilder::freeze(builder) -> return builder as-is (it is already a map obj)
      let pos_args = extract_positional_exprs_with_arity(
        args, "MapBuilder::freeze", 1,
      )
      compile_expr_i32(ctx, buf, pos_args[0])
    }
    "Set::new" => {
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
    "Set::size" => {
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
    "Set::contains" => {
      // Set::contains(set, val) -> same as Map::has_key
      let pos_args = extract_positional_exprs_with_arity(
        args, "Set::contains", 2,
      )
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
    "Set::add" => {
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
    "Set::remove" => {
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
    "Set::to_array" => {
      // Set::to_array(set) -> allocate array with keys from map (same as Map::keys)
      let pos_args = extract_positional_exprs_with_arity(
        args, "Set::to_array", 1,
      )
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
      if not(ctx.use_js_strings) {
        emit_i64_extend_i32_u(buf)
        emit_i64_const_raw(buf, tag_obj.to_int64())
        emit_i64_or(buf)
        emit_i32_wrap_i64(buf)
      }
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
    "Set::from_array" => {
      // Set::from_array(arr) -> new set from array elements
      // Creates map where each array element is a key with value=true
      let pos_args = extract_positional_exprs_with_arity(
        args, "Set::from_array", 1,
      )
      require_heap(ctx)
      let max_cap = 128
      let arr_ptr = alloc_temp_local(ctx)
      let arr_len = alloc_temp_local(ctx)
      let dst_ptr = alloc_temp_local(ctx)
      let loop_i = alloc_temp_local(ctx)
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
      emit_local_get(buf, dst_ptr)
      emit_local_get(buf, arr_len)
      emit_i32_store(buf, 4)
      emit_i32_const_raw(buf, 0)
      emit_local_set(buf, loop_i)
      buf.push((3).to_byte()) // loop
      buf.push((64).to_byte()) // void
      emit_local_get(buf, loop_i)
      emit_local_get(buf, arr_len)
      emit_i32_lt_s(buf)
      buf.push((4).to_byte()) // if
      buf.push((64).to_byte()) // void
      // store key: dst[8 + i*8] = arr[8 + i*4]
      emit_local_get(buf, dst_ptr)
      emit_local_get(buf, loop_i)
      emit_i32_const_raw(buf, 3)
      emit_i32_shl(buf)
      emit_i32_add(buf)
      emit_local_get(buf, arr_ptr)
      emit_local_get(buf, loop_i)
      emit_i32_const_raw(buf, 4)
      emit_i32_mul(buf)
      emit_i32_add(buf)
      emit_i32_load(buf, 8)
      emit_i32_store(buf, 8)
      // store value: dst[12 + i*8] = tagged true (7)
      emit_local_get(buf, dst_ptr)
      emit_local_get(buf, loop_i)
      emit_i32_const_raw(buf, 3)
      emit_i32_shl(buf)
      emit_i32_add(buf)
      emit_i32_const_raw(buf, 7) // tagged true = (1 << 2) | 3
      emit_i32_store(buf, 12)
      emit_local_get(buf, loop_i)
      emit_i32_const_raw(buf, 1)
      emit_i32_add(buf)
      emit_local_set(buf, loop_i)
      buf.push((12).to_byte()) // br
      write_u32_leb(buf, 1) // to loop
      buf.push((11).to_byte()) // end if
      buf.push((11).to_byte()) // end loop
      emit_local_get(buf, dst_ptr)
      emit_i64_extend_i32_u(buf)
      emit_i64_const_raw(buf, tag_obj.to_int64())
      emit_i64_or(buf)
    }
    "Map::has_key" => {
      // map_has_key(map, key) -> linear search for key, return tagged bool
      let pos_args = extract_positional_exprs_with_arity(
        args, "Map::has_key", 2,
      )
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
    "Map::has" => {
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
    "Map::set" => {
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
    "Map::delete" => {
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
    "Map::keys" => {
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
      if not(ctx.use_js_strings) {
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
    "Map::values" => {
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
    "Array::length" => {
      // array_length(arr) -> load len field, shift left 2 (tag as int)
      // Supports both obj_array (len at offset 4) and
      // obj_array_view (end - start, offsets 12 and 8)
      let pos_args = extract_positional_exprs_with_arity(
        args, "Array::length", 1,
      )
      let arr_ptr = alloc_temp_local(ctx)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, arr_ptr)
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
    "iter_require" if not(is_user_fn) => {
      // iter_require(xs) -> identity (prelude fallback for Array iteration)
      let pos_args = extract_positional_exprs_with_arity(
        args, "iter_require", 1,
      )
      compile_expr(ctx, buf, pos_args[0])
    }
    "iter_length" if not(is_user_fn) => {
      // iter_length(xs) -> fallback to array_length(xs)
      let pos_args = extract_positional_exprs_with_arity(args, "iter_length", 1)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_i32_load(buf, 4)
      emit_i64_extend_i32_s(buf)
      emit_i64_const_raw(buf, 2L)
      emit_i64_shl(buf)
      // tag_int = 0, i64.or is a no-op
    }
    "iter_get" if not(is_user_fn) => {
      // iter_get(xs, idx) -> fallback to array_get(xs, idx)
      let pos_args = extract_positional_exprs_with_arity(args, "iter_get", 2)
      let ptr_local = alloc_temp_local(ctx)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, ptr_local)
      emit_local_get(buf, ptr_local)
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_untag_int_i32(buf)
      emit_i32_const_raw(buf, 4)
      emit_i32_mul(buf)
      emit_i32_add(buf)
      emit_i32_load(buf, 8)
      emit_i64_extend_i32_s(buf)
    }
    "Array::get" => {
      // array_get(arr, idx) -> load arr[idx]
      // Supports both obj_array and obj_array_view
      let pos_args = extract_positional_exprs_with_arity(args, "Array::get", 2)
      let arr_ptr = alloc_temp_local(ctx)
      let idx_local = alloc_temp_local(ctx)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, arr_ptr)
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
    "Array::set" => {
      // array_set(arr, idx, value) -> arr[idx] = value
      let pos_args = extract_positional_exprs_with_arity(args, "Array::set", 3)
      let ptr_local = alloc_temp_local(ctx)
      let idx_local = alloc_temp_local(ctx)
      let val_local = alloc_temp_local(ctx)
      // Evaluate all arguments first (preserve evaluation order)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, ptr_local)
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_untag_int_i32(buf)
      emit_local_set(buf, idx_local)
      compile_expr_i32(ctx, buf, pos_args[2])
      emit_i32_wrap_i64(buf)
      emit_local_set(buf, val_local)
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
      emit_i64_const_tagged(buf, 0L) // return Unit
    }
    "FixedArray::make" => {
      // FixedArray::make(size, default) -> same as array_new
      let pos_args = extract_positional_exprs_with_arity(
        args, "FixedArray::make", 2,
      )
      require_heap(ctx)
      let size_local = alloc_temp_local(ctx)
      let val_local = alloc_temp_local(ctx)
      let obj_local = alloc_temp_local(ctx)
      let idx_local = alloc_temp_local(ctx)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_int_i32(buf)
      emit_local_set(buf, size_local)
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_i32_wrap_i64(buf)
      emit_local_set(buf, val_local)
      emit_local_get(buf, size_local)
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
      emit_global_get(buf, ctx.heap_global)
      emit_local_tee(buf, obj_local)
      emit_local_get(buf, alloc_size_local)
      emit_i32_add(buf)
      emit_global_set(buf, ctx.heap_global)
      ctx.heap_synced = false
      emit_local_get(buf, obj_local)
      emit_i32_const_raw(buf, obj_array)
      emit_i32_store(buf, 0)
      emit_local_get(buf, obj_local)
      emit_local_get(buf, size_local)
      emit_i32_store(buf, 4)
      emit_i32_const_raw(buf, 0)
      emit_local_set(buf, idx_local)
      emit_block(buf)
      emit_loop(buf)
      emit_local_get(buf, idx_local)
      emit_local_get(buf, size_local)
      emit_i32_ge_s(buf)
      emit_br_if(buf, 1)
      emit_local_get(buf, obj_local)
      emit_local_get(buf, idx_local)
      emit_i32_const_raw(buf, 4)
      emit_i32_mul(buf)
      emit_i32_add(buf)
      emit_local_get(buf, val_local)
      emit_i32_store(buf, 8)
      emit_local_get(buf, idx_local)
      emit_i32_const_raw(buf, 1)
      emit_i32_add(buf)
      emit_local_set(buf, idx_local)
      emit_br(buf, 0)
      emit_end(buf)
      emit_end(buf)
      emit_local_get(buf, obj_local)
      emit_i64_extend_i32_u(buf)
      emit_i64_const_raw(buf, tag_obj.to_int64())
      emit_i64_or(buf)
    }
    "FixedArray::length" => {
      // FixedArray::length(arr) -> read header length
      let pos_args = extract_positional_exprs_with_arity(
        args, "FixedArray::length", 1,
      )
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_i32_load(buf, 4)
      emit_i64_extend_i32_s(buf)
      emit_i64_const_raw(buf, 2L)
      emit_i64_shl(buf)
    }
    "FixedArray::get" => {
      // FixedArray::get(arr, idx) -> arr[idx]
      let pos_args = extract_positional_exprs_with_arity(
        args, "FixedArray::get", 2,
      )
      let ptr_local = alloc_temp_local(ctx)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, ptr_local)
      emit_local_get(buf, ptr_local)
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_untag_int_i32(buf)
      emit_i32_const_raw(buf, 4)
      emit_i32_mul(buf)
      emit_i32_add(buf)
      emit_i32_load(buf, 8)
      emit_i64_extend_i32_s(buf)
    }
    "FixedArray::set" | "FixedArray::unsafe_set" => {
      // FixedArray::set(arr, idx, val) / FixedArray::unsafe_set(arr, idx, val)
      // -> store val at arr[idx], no length update
      let pos_args = extract_positional_exprs_with_arity(args, name, 3)
      let ptr_local = alloc_temp_local(ctx)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, ptr_local)
      emit_local_get(buf, ptr_local)
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_untag_int_i32(buf)
      emit_i32_const_raw(buf, 4)
      emit_i32_mul(buf)
      emit_i32_add(buf)
      compile_expr_i32(ctx, buf, pos_args[2])
      emit_i32_wrap_i64(buf)
      emit_i32_store(buf, 8)
      emit_i64_const_tagged(buf, 0L)
    }
    "FixedArray::blit" => {
      // FixedArray::blit(dst, dst_off, src, src_off, len)
      // -> memory.copy(dst_addr, src_addr, byte_count)
      // dst_addr = untag(dst) + 8 + dst_off_raw * 4
      // src_addr = untag(src) + 8 + src_off_raw * 4
      // byte_count = len_raw * 4
      let pos_args = extract_positional_exprs_with_arity(
        args, "FixedArray::blit", 5,
      )
      let dst_ptr = alloc_temp_local(ctx)
      let src_ptr = alloc_temp_local(ctx)
      // dst ptr
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, dst_ptr)
      // src ptr
      compile_expr_i32(ctx, buf, pos_args[2])
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, src_ptr)
      // push dst_addr: dst_ptr + 8 + dst_off_raw * 4
      emit_local_get(buf, dst_ptr)
      emit_i32_const_raw(buf, 8)
      emit_i32_add(buf)
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_untag_int_i32(buf)
      emit_i32_const_raw(buf, 4)
      emit_i32_mul(buf)
      emit_i32_add(buf)
      // push src_addr: src_ptr + 8 + src_off_raw * 4
      emit_local_get(buf, src_ptr)
      emit_i32_const_raw(buf, 8)
      emit_i32_add(buf)
      compile_expr_i32(ctx, buf, pos_args[3])
      emit_untag_int_i32(buf)
      emit_i32_const_raw(buf, 4)
      emit_i32_mul(buf)
      emit_i32_add(buf)
      // push byte_count: len_raw * 4
      compile_expr_i32(ctx, buf, pos_args[4])
      emit_untag_int_i32(buf)
      emit_i32_const_raw(buf, 4)
      emit_i32_mul(buf)
      // memory.copy
      emit_memory_copy(buf)
      emit_i64_const_tagged(buf, 0L)
    }
    "__len" => {
      let pos_args = extract_positional_exprs_with_arity(args, "__len", 1)
      let ptr_local = alloc_temp_local(ctx)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, ptr_local)
      emit_local_get(buf, ptr_local)
      emit_i32_load(buf, 0)
      emit_i32_const_raw(buf, obj_string)
      emit_i32_eq(buf)
      buf.push((4).to_byte()) // if (string)
      buf.push((126).to_byte()) // result i64
      emit_local_get(buf, ptr_local)
      emit_i32_load(buf, 4)
      emit_i64_extend_i32_u(buf)
      emit_i64_const_raw(buf, 2L)
      emit_i64_shl(buf)
      buf.push((5).to_byte()) // else
      emit_local_get(buf, ptr_local)
      emit_i32_load(buf, 0)
      emit_i32_const_raw(buf, obj_bytes_view)
      emit_i32_eq(buf)
      emit_local_get(buf, ptr_local)
      emit_i32_load(buf, 0)
      emit_i32_const_raw(buf, obj_array_view)
      emit_i32_eq(buf)
      emit_i32_or(buf)
      buf.push((4).to_byte()) // if (bytes_view or array_view)
      buf.push((126).to_byte()) // result i64
      emit_local_get(buf, ptr_local)
      emit_i32_load(buf, 12)
      emit_local_get(buf, ptr_local)
      emit_i32_load(buf, 8)
      emit_i32_sub(buf)
      emit_i64_extend_i32_s(buf)
      emit_i64_const_raw(buf, 2L)
      emit_i64_shl(buf)
      buf.push((5).to_byte()) // else (bytes or array)
      emit_local_get(buf, ptr_local)
      emit_i32_load(buf, 4)
      emit_i64_extend_i32_u(buf)
      emit_i64_const_raw(buf, 2L)
      emit_i64_shl(buf)
      buf.push((11).to_byte()) // end if (view)
      buf.push((11).to_byte()) // end if (string)
    }
    "__index" => {
      // __index(obj, key) -> record/map field access when key is string,
      //                      array_get when key is integer
      let pos_args = extract_positional_exprs_with_arity(args, "__index", 2)
      match pos_args[1] {
        @core.Expr::String(value=field_name, ..) => {
          // Record/Map field access by string key: linear search through
          // (name_ptr, value) pairs with stride 8.
          let obj_ptr = alloc_temp_local(ctx)
          let obj_len = alloc_temp_local(ctx)
          let loop_i = alloc_temp_local(ctx)
          let result_local = alloc_temp_local(ctx)
          let field_ptr = ctx.strings.intern(field_name)
          compile_expr_i32(ctx, buf, pos_args[0])
          emit_untag_ptr_i32(buf)
          emit_local_set(buf, obj_ptr)
          emit_local_get(buf, obj_ptr)
          emit_i32_load(buf, 4)
          emit_local_set(buf, obj_len)
          emit_i32_const_raw(buf, 0)
          emit_local_set(buf, loop_i)
          emit_i64_const_tagged(buf, 0L)
          emit_i32_wrap_i64(buf)
          emit_local_set(buf, result_local)
          // loop: compare name pointers, load value on match
          buf.push((3).to_byte()) // loop
          buf.push((64).to_byte()) // void
          emit_local_get(buf, loop_i)
          emit_local_get(buf, obj_len)
          emit_i32_lt_s(buf)
          buf.push((4).to_byte()) // if
          buf.push((64).to_byte()) // void
          // load name_ptr at obj_ptr + loop_i * 8 + 8
          emit_local_get(buf, obj_ptr)
          emit_local_get(buf, loop_i)
          emit_i32_const_raw(buf, 3)
          emit_i32_shl(buf)
          emit_i32_add(buf)
          emit_i32_load(buf, 8) // name_ptr
          emit_i32_const_raw(buf, field_ptr)
          emit_i32_eq(buf)
          buf.push((4).to_byte()) // if (name matches)
          buf.push((64).to_byte()) // void
          // load value at obj_ptr + loop_i * 8 + 12
          emit_local_get(buf, obj_ptr)
          emit_local_get(buf, loop_i)
          emit_i32_const_raw(buf, 3)
          emit_i32_shl(buf)
          emit_i32_add(buf)
          emit_i32_load(buf, 12) // value
          emit_local_set(buf, result_local)
          buf.push((11).to_byte()) // end if (name matches)
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
        }
        _ => {
          // Integer index: array access or string char access
          let obj_local = alloc_temp_local_with_kind(ctx, ValueKind::I64)
          let ptr_local = alloc_temp_local(ctx)
          compile_expr_i32(ctx, buf, pos_args[0])
          emit_local_set(buf, obj_local)
          emit_local_get(buf, obj_local)
          emit_untag_ptr_i32(buf)
          emit_local_set(buf, ptr_local)
          // Check obj_type: string (1) vs array (5)
          emit_local_get(buf, ptr_local)
          emit_i32_load(buf, 0) // obj_type
          emit_i32_const_raw(buf, obj_string)
          emit_i32_eq(buf)
          buf.push((4).to_byte()) // if (string)
          buf.push((126).to_byte()) // result i64
          // String path: emit substring(s, i, i+1) inline
          let _ = compile_call_builtin_pre_user(
            ctx,
            buf,
            "String::substring",
            [
              @core.CallArg::{
                label: None,
                expr: pos_args[0],
                span: pos_args[0].span(),
              },
              @core.CallArg::{
                label: None,
                expr: pos_args[1],
                span: pos_args[1].span(),
              },
              @core.CallArg::{
                label: None,
                expr: @core.Expr::Call(
                  name="__add",
                  type_args=[],
                  args=[
                    @core.CallArg::{
                      label: None,
                      expr: pos_args[1],
                      span: pos_args[1].span(),
                    },
                    @core.CallArg::{
                      label: None,
                      expr: @core.Expr::Int(value=1L, span=pos_args[1].span()),
                      span: pos_args[1].span(),
                    },
                  ],
                  span=pos_args[1].span(),
                ),
                span: pos_args[1].span(),
              },
            ],
            false,
          )
          buf.push((5).to_byte()) // else
          // Check for obj_bytes_view
          emit_local_get(buf, ptr_local)
          emit_i32_load(buf, 0)
          emit_i32_const_raw(buf, obj_bytes_view)
          emit_i32_eq(buf)
          buf.push((4).to_byte()) // if (bytes_view)
          buf.push((126).to_byte()) // result i64
          // BytesView: source_data[start + idx] load8_u, tag
          let bv_idx = alloc_temp_local(ctx)
          let bv_source_local = alloc_temp_local(ctx)
          compile_expr_i32(ctx, buf, pos_args[1])
          emit_untag_int_i32(buf)
          emit_local_set(buf, bv_idx)
          emit_local_get(buf, ptr_local)
          emit_i32_load(buf, 4) // source_ptr
          emit_local_set(buf, bv_source_local)
          emit_local_get(buf, bv_source_local)
          emit_i32_load(buf, 12) // source data_ptr
          emit_local_get(buf, ptr_local)
          emit_i32_load(buf, 8) // start
          emit_local_get(buf, bv_idx)
          emit_i32_add(buf)
          emit_i32_add(buf)
          emit_i32_load8_u(buf, 0) // load byte
          emit_i64_extend_i32_u(buf)
          emit_i64_const_raw(buf, 2L)
          emit_i64_shl(buf) // tag as int
          buf.push((5).to_byte()) // else (not bytes_view)
          // Check for obj_bytes
          emit_local_get(buf, ptr_local)
          emit_i32_load(buf, 0)
          emit_i32_const_raw(buf, obj_bytes)
          emit_i32_eq(buf)
          buf.push((4).to_byte()) // if (bytes)
          buf.push((126).to_byte()) // result i64
          // Bytes: data_ptr[idx] load8_u, tag
          emit_local_get(buf, ptr_local)
          emit_i32_load(buf, 12)
          compile_expr_i32(ctx, buf, pos_args[1])
          emit_untag_int_i32(buf)
          emit_i32_add(buf)
          emit_i32_load8_u(buf, 0) // load byte at [data_ptr + idx]
          emit_i64_extend_i32_u(buf)
          emit_i64_const_raw(buf, 2L)
          emit_i64_shl(buf) // tag as int
          buf.push((5).to_byte()) // else (not bytes)
          // Check for array_view
          emit_local_get(buf, ptr_local)
          emit_i32_load(buf, 0)
          emit_i32_const_raw(buf, obj_array_view)
          emit_i32_eq(buf)
          buf.push((4).to_byte()) // if (array_view)
          buf.push((126).to_byte()) // result i64
          // ArrayView: source[start + idx]
          let av_idx = alloc_temp_local(ctx)
          compile_expr_i32(ctx, buf, pos_args[1])
          emit_untag_int_i32(buf)
          emit_local_set(buf, av_idx)
          emit_local_get(buf, ptr_local)
          emit_i32_load(buf, 4) // source_ptr
          emit_local_get(buf, ptr_local)
          emit_i32_load(buf, 8) // start
          emit_local_get(buf, av_idx)
          emit_i32_add(buf)
          emit_i32_const_raw(buf, 4)
          emit_i32_mul(buf)
          emit_i32_add(buf)
          emit_i32_load(buf, 8)
          emit_i64_extend_i32_s(buf)
          buf.push((5).to_byte()) // else (regular array)
          // Array path: bounds check + access at offset 8 + idx * 4
          let arr_idx = alloc_temp_local(ctx)
          compile_expr_i32(ctx, buf, pos_args[1])
          emit_untag_int_i32(buf)
          emit_local_set(buf, arr_idx)
          // bounds check: trap if idx < 0 || idx >= length
          emit_local_get(buf, arr_idx)
          emit_i32_const_raw(buf, 0)
          emit_i32_lt_s(buf)
          emit_local_get(buf, arr_idx)
          emit_local_get(buf, ptr_local)
          emit_i32_load(buf, 4) // length
          emit_i32_ge_s(buf)
          emit_i32_or(buf)
          buf.push((4).to_byte()) // if (out of bounds)
          buf.push((64).to_byte()) // void
          buf.push((0).to_byte()) // unreachable (trap)
          buf.push((11).to_byte()) // end if
          emit_local_get(buf, ptr_local)
          emit_local_get(buf, arr_idx)
          emit_i32_const_raw(buf, 4)
          emit_i32_mul(buf)
          emit_i32_add(buf)
          emit_i32_load(buf, 8)
          emit_i64_extend_i32_s(buf)
          buf.push((11).to_byte()) // end if (array_view)
          buf.push((11).to_byte()) // end if (bytes)
          buf.push((11).to_byte()) // end if (bytes_view)
          buf.push((11).to_byte()) // end if (string)
        }
      }
    }
    "__slice" => {
      // __slice(container, start, end) -> String/Bytes materialized copy,
      // Array view zero-copy.
      let pos_args = extract_positional_exprs_with_arity(args, "__slice", 3)
      require_heap(ctx)
      let source_local = alloc_temp_local_with_kind(ctx, ValueKind::I64)
      let ptr_local = alloc_temp_local(ctx)
      let obj_local = alloc_temp_local(ctx)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_local_set(buf, source_local)
      emit_local_get(buf, source_local)
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, ptr_local)
      // Allocate 16 bytes for view
      // Check if source is string or array
      emit_local_get(buf, ptr_local)
      emit_i32_load(buf, 0) // source obj_type
      emit_i32_const_raw(buf, obj_string) // 1
      emit_i32_eq(buf)
      buf.push((4).to_byte()) // if (string)
      buf.push((126).to_byte()) // result i64
      // String path: emit String::substring inline (materialized copy)
      let _ = compile_call_builtin_pre_user(
        ctx, buf, "String::substring", args, false,
      )
      buf.push((5).to_byte()) // else
      // Bytes/BytesView path: emit Bytes::slice inline (materialized copy)
      emit_local_get(buf, ptr_local)
      emit_i32_load(buf, 0) // source obj_type
      emit_i32_const_raw(buf, obj_bytes)
      emit_i32_eq(buf)
      emit_local_get(buf, ptr_local)
      emit_i32_load(buf, 0)
      emit_i32_const_raw(buf, obj_bytes_view)
      emit_i32_eq(buf)
      emit_i32_or(buf)
      buf.push((4).to_byte()) // if (bytes or bytes_view)
      buf.push((126).to_byte()) // result i64
      let _ = compile_call_builtin_pre_user(
        ctx, buf, "Bytes::slice", args, false,
      )
      buf.push((5).to_byte()) // else (array -> view zero-copy)
      let size = 16
      emit_heap_alloc(ctx, buf, size, obj_local)
      emit_local_get(buf, obj_local)
      emit_i32_const_raw(buf, obj_array_view)
      emit_i32_store(buf, 0)
      emit_local_get(buf, obj_local)
      emit_local_get(buf, ptr_local)
      emit_i32_store(buf, 4)
      emit_local_get(buf, obj_local)
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_untag_int_i32(buf)
      emit_i32_store(buf, 8)
      emit_local_get(buf, obj_local)
      compile_expr_i32(ctx, buf, pos_args[2])
      emit_untag_int_i32(buf)
      emit_i32_store(buf, 12)
      emit_local_get(buf, obj_local)
      emit_i64_extend_i32_u(buf)
      emit_i64_const_raw(buf, tag_obj.to_int64())
      emit_i64_or(buf)
      buf.push((11).to_byte()) // end if (bytes-like)
      buf.push((11).to_byte()) // end if (string)
    }
    "__set_index" => {
      // __set_index(arr, idx, value) -> arr[idx] = value; return value
      // This is used by index-assignment desugaring (e.g. cursor[0] = x).
      let pos_args = extract_positional_exprs_with_arity(args, "__set_index", 3)
      let ptr_local = alloc_temp_local(ctx)
      let idx_local = alloc_temp_local(ctx)
      let value_local = alloc_temp_local_with_kind(ctx, ValueKind::I64)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, ptr_local)
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_untag_int_i32(buf)
      emit_local_set(buf, idx_local)
      compile_expr_i32(ctx, buf, pos_args[2])
      emit_local_set(buf, value_local)
      // Check if target is Bytes (packed) or Array (4-byte stride)
      emit_local_get(buf, ptr_local)
      emit_i32_load(buf, 0)
      emit_i32_const_raw(buf, obj_bytes)
      emit_i32_eq(buf)
      buf.push((4).to_byte()) // if (bytes)
      buf.push((64).to_byte()) // void
      // Bytes: store8 at [data_ptr + idx], untag value
      emit_local_get(buf, ptr_local)
      emit_i32_load(buf, 12)
      emit_local_get(buf, idx_local)
      emit_i32_add(buf)
      emit_local_get(buf, value_local)
      emit_i64_const_raw(buf, 2L)
      emit_i64_shr_u(buf) // untag byte value
      emit_i32_wrap_i64(buf)
      emit_i32_store8(buf, 0)
      buf.push((5).to_byte()) // else (array)
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
      // Array: store i32 at [ptr + 8 + idx*4]
      emit_local_get(buf, ptr_local)
      emit_local_get(buf, idx_local)
      emit_i32_const_raw(buf, 4)
      emit_i32_mul(buf)
      emit_i32_add(buf)
      emit_local_get(buf, value_local)
      emit_i32_wrap_i64(buf)
      emit_i32_store(buf, 8)
      buf.push((11).to_byte()) // end if
      emit_local_get(buf, value_local)
    }
    "Map::get" => {
      // map_get(map, key) -> linear search for key, return value
      let pos_args = extract_positional_exprs_with_arity(args, "Map::get", 2)
      let map_ptr = alloc_temp_local(ctx)
      let map_len = alloc_temp_local(ctx)
      let loop_i = alloc_temp_local(ctx)
      let result_local = alloc_temp_local(ctx)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, map_ptr)
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
    _ => raise WasmGenError::Unsupported(pre_user_builtin_unhandled_marker)
  }
}
