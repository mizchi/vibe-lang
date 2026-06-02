///|
/// SIMD-accelerated cell fill for the `obj_array` element region.
///
/// Stores `size` copies of the i32 `val_local` starting at `obj_local + 8`
/// (the element data offset shared by `array_new` and `FixedArray::make`).
/// The bulk of the array is filled four elements at a time with a single
/// `i32x4.splat` broadcast plus a 16-byte `v128.store`; a scalar tail handles
/// the trailing `size & 3` elements. `idx_local` is used as the running
/// element index and is left equal to `size` on exit.
///
/// vibe-lang assumes the wasm SIMD extension is always available (ADR-0054,
/// SIMD-first baseline), so this path is unconditional — there is no scalar
/// fallback variant of the fill loop.
fn emit_simd_fill_i32(
  ctx : CodegenCtx,
  buf : ByteBuf,
  obj_local : Int,
  size_local : Int,
  val_local : Int,
  idx_local : Int,
) -> Unit {
  let vec_local = alloc_temp_local_with_kind(ctx, ValueKind::V128)
  let vec_count_local = alloc_temp_local(ctx)
  // vec = i32x4.splat(val) — broadcast the fill value to all four lanes once.
  emit_local_get(buf, val_local)
  emit_i32x4_splat(buf)
  emit_local_set(buf, vec_local)
  // vec_count = size & ~3 — element count covered by full 16-byte stores.
  emit_local_get(buf, size_local)
  emit_i32_const_raw(buf, -4)
  emit_i32_and(buf)
  emit_local_set(buf, vec_count_local)
  // Vector loop: store 4 elements (16 bytes) per iteration.
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, idx_local)
  emit_block(buf)
  emit_loop(buf)
  emit_local_get(buf, idx_local)
  emit_local_get(buf, vec_count_local)
  emit_i32_ge_s(buf)
  emit_br_if(buf, 1)
  // addr = obj + idx*4; v128.store at memarg offset 8 (element base).
  emit_local_get(buf, obj_local)
  emit_local_get(buf, idx_local)
  emit_i32_const_raw(buf, 4)
  emit_i32_mul(buf)
  emit_i32_add(buf)
  emit_local_get(buf, vec_local)
  emit_v128_store_align(buf, 2, 8)
  emit_local_get(buf, idx_local)
  emit_i32_const_raw(buf, 4)
  emit_i32_add(buf)
  emit_local_set(buf, idx_local)
  emit_br(buf, 0)
  emit_end(buf) // end loop
  emit_end(buf) // end block
  // Scalar tail: idx already == vec_count, fill the remaining < 4 cells.
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
  emit_end(buf) // end loop
  emit_end(buf) // end block
}

///|
fn compile_builtin_collection(
  ctx : CodegenCtx,
  buf : ByteBuf,
  name : String,
  args : Array[@core.CallArg],
  is_user_fn : Bool,
) -> Unit raise WasmGenError {
  match name {
    // ArrayBuilder::new/push/freeze migrated to the builtin registry (Phase B-1, #415).
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
      // Fill with default value (SIMD-accelerated 16-byte stores + scalar tail).
      emit_simd_fill_i32(ctx, buf, obj_local, size_local, val_local, idx_local)
      // Return tagged obj
      emit_local_get(buf, obj_local)
      emit_i64_extend_i32_u(buf)
      emit_i64_const_raw(buf, tag_obj.to_int64())
      emit_i64_or(buf)
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
    // MapBuilder::new/set/freeze and the Set:: namespace (new/size/contains/
    // add/remove/to_array/from_array) migrated to the builtin registry
    // (Phase B-1, #415).
    "iter_require" if !is_user_fn => {
      // iter_require(xs) -> identity (prelude fallback for Array iteration)
      let pos_args = extract_positional_exprs_with_arity(
        args, "iter_require", 1,
      )
      compile_expr(ctx, buf, pos_args[0])
    }
    "iter_length" if !is_user_fn => {
      // iter_length(xs) -> Array::length(xs) semantics.
      // Mirrors Array::length so for-in over an ArrayView (Array slice)
      // works through the unified Iterable desugar (ADR-0044 Phase 2).
      let pos_args = extract_positional_exprs_with_arity(args, "iter_length", 1)
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
    "iter_get" if !is_user_fn => {
      // iter_get(xs, idx) -> Array::get(xs, idx) semantics.
      // Mirrors Array::get so for-in over an ArrayView (Array slice)
      // works through the unified Iterable desugar (ADR-0044 Phase 2).
      let pos_args = extract_positional_exprs_with_arity(args, "iter_get", 2)
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
      // Use the standard heap_local-based allocator. Bumping heap_global
      // directly here desynchronizes ctx.heap_local — subsequent
      // emit_heap_alloc / emit_heap_reserve calls then read a stale
      // heap_local and allocate on top of the FixedArray. (Reproduced
      // via `Array::push` to a literal `[]` allocated after
      // `FixedArray::make`.)
      emit_heap_alloc_local(ctx, buf, alloc_size_local, obj_local)
      emit_local_get(buf, obj_local)
      emit_i32_const_raw(buf, obj_array)
      emit_i32_store(buf, 0)
      emit_local_get(buf, obj_local)
      emit_local_get(buf, size_local)
      emit_i32_store(buf, 4)
      // Fill cells (SIMD-accelerated 16-byte stores + scalar tail).
      emit_simd_fill_i32(ctx, buf, obj_local, size_local, val_local, idx_local)
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
          //
          // Slot keys may be either an interned data-section pointer (record
          // fields, `compile_map_expr`, `Map::set`, `MapBuilder::set`) or a
          // heap-allocated runtime string (e.g. `Int::to_string(i)` used as a
          // MapBuilder key). Both layouts are `[obj_string][len][bytes...]`,
          // so we compare contents via `emit_non_js_string_ptr_equals_i32`,
          // which short-circuits on pointer equality for the record-field
          // fast path and falls back to byte-wise compare otherwise.
          let obj_ptr = alloc_temp_local(ctx)
          let obj_len = alloc_temp_local(ctx)
          let loop_i = alloc_temp_local(ctx)
          let result_local = alloc_temp_local(ctx)
          let entry_name_local = alloc_temp_local(ctx)
          let field_ptr_local = alloc_temp_local(ctx)
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
          emit_i32_const_raw(buf, field_ptr)
          emit_local_set(buf, field_ptr_local)
          // loop: compare name strings, load value on match
          buf.push((3).to_byte()) // loop
          buf.push((64).to_byte()) // void
          emit_local_get(buf, loop_i)
          emit_local_get(buf, obj_len)
          emit_i32_lt_s(buf)
          buf.push((4).to_byte()) // if
          buf.push((64).to_byte()) // void
          // load name_ptr at obj_ptr + loop_i * 8 + 8 into entry_name_local
          emit_local_get(buf, obj_ptr)
          emit_local_get(buf, loop_i)
          emit_i32_const_raw(buf, 3)
          emit_i32_shl(buf)
          emit_i32_add(buf)
          emit_i32_load(buf, 8) // name_ptr
          emit_local_set(buf, entry_name_local)
          emit_non_js_string_ptr_equals_i32(
            ctx, buf, entry_name_local, field_ptr_local,
          )
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
      // ADR-0052: when idx is a string literal, this is a struct field
      // assignment `r.field = value`. Use the same (name_ptr, value)
      // pair layout that `__index` reads from to do the linear search
      // and write the value slot in-place.
      match pos_args[1] {
        @core.Expr::String(value=field_name, ..) => {
          let r_ptr = alloc_temp_local(ctx)
          let r_len = alloc_temp_local(ctx)
          let r_loop_i = alloc_temp_local(ctx)
          let r_entry_name = alloc_temp_local(ctx)
          let r_field_ptr = alloc_temp_local(ctx)
          let r_value = alloc_temp_local_with_kind(ctx, ValueKind::I64)
          let field_ptr = ctx.strings.intern(field_name)
          // Stash value first (so we can both write the slot and return it).
          compile_expr(ctx, buf, pos_args[2])
          emit_local_set(buf, r_value)
          // Resolve record pointer.
          compile_expr_i32(ctx, buf, pos_args[0])
          emit_untag_ptr_i32(buf)
          emit_local_set(buf, r_ptr)
          emit_local_get(buf, r_ptr)
          emit_i32_load(buf, 4)
          emit_local_set(buf, r_len)
          emit_i32_const_raw(buf, 0)
          emit_local_set(buf, r_loop_i)
          emit_i32_const_raw(buf, field_ptr)
          emit_local_set(buf, r_field_ptr)
          buf.push((3).to_byte()) // loop
          buf.push((64).to_byte()) // void
          emit_local_get(buf, r_loop_i)
          emit_local_get(buf, r_len)
          emit_i32_lt_s(buf)
          buf.push((4).to_byte()) // if (i < len)
          buf.push((64).to_byte()) // void
          emit_local_get(buf, r_ptr)
          emit_local_get(buf, r_loop_i)
          emit_i32_const_raw(buf, 3)
          emit_i32_shl(buf)
          emit_i32_add(buf)
          emit_i32_load(buf, 8) // name_ptr
          emit_local_set(buf, r_entry_name)
          emit_non_js_string_ptr_equals_i32(ctx, buf, r_entry_name, r_field_ptr)
          buf.push((4).to_byte()) // if (name matches)
          buf.push((64).to_byte()) // void
          // store value at obj_ptr + loop_i * 8 + 12
          emit_local_get(buf, r_ptr)
          emit_local_get(buf, r_loop_i)
          emit_i32_const_raw(buf, 3)
          emit_i32_shl(buf)
          emit_i32_add(buf)
          emit_local_get(buf, r_value)
          emit_i32_wrap_i64(buf)
          emit_i32_store(buf, 12)
          buf.push((11).to_byte()) // end if (name matches)
          emit_local_get(buf, r_loop_i)
          emit_i32_const_raw(buf, 1)
          emit_i32_add(buf)
          emit_local_set(buf, r_loop_i)
          buf.push((12).to_byte()) // br
          write_u32_leb(buf, 1) // to loop
          buf.push((11).to_byte()) // end if (i < len)
          buf.push((11).to_byte()) // end loop
          // Leave the value on the stack (matches array path which
          // also returns the assigned value, caller drops it).
          emit_local_get(buf, r_value)
          return
        }
        _ => ()
      }
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
      buf.push((5).to_byte()) // else (array or array_view)
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
      emit_i32_add(buf)
      emit_local_get(buf, value_local)
      emit_i32_wrap_i64(buf)
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
      // Array: store i32 at [ptr + 8 + idx*4]
      emit_local_get(buf, ptr_local)
      emit_local_get(buf, idx_local)
      emit_i32_const_raw(buf, 4)
      emit_i32_mul(buf)
      emit_i32_add(buf)
      emit_local_get(buf, value_local)
      emit_i32_wrap_i64(buf)
      emit_i32_store(buf, 8)
      buf.push((11).to_byte()) // end if (view vs array)
      buf.push((11).to_byte()) // end if (bytes vs non-bytes)
      emit_local_get(buf, value_local)
    }
    _ => raise WasmGenError::Unsupported(pre_user_builtin_unhandled_marker)
  }
}
