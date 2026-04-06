///|
let pre_user_builtin_unhandled_marker = "__pre_user_builtin_unhandled__"

///|
let builder_initial_cap = 256

///|
/// Emit code to allocate a builder with a hidden capacity prefix.
/// Layout: [cap:i32][tag:i32][len:i32][data...]
/// The returned obj_ptr points to the tag field (offset +4 from allocation start).
/// Callers see the standard [tag][len][data...] layout.
/// Capacity is stored at obj_ptr - 4 (hidden from consumers).
fn emit_builder_alloc(
  ctx : CodegenCtx,
  buf : ByteBuf,
  initial_cap : Int,
  elem_size : Int,
  type_tag : Int,
  obj_local : Int,
) -> Unit {
  require_heap(ctx)
  // Total allocation: 4 (cap prefix) + 8 (tag + len) + initial_cap * elem_size
  let alloc_size = align4(4 + 8 + initial_cap * elem_size)
  let base_local = alloc_temp_local(ctx)
  emit_heap_alloc(ctx, buf, alloc_size, base_local)
  // Write capacity at base[0]
  emit_local_get(buf, base_local)
  emit_i32_const_raw(buf, initial_cap)
  emit_i32_store(buf, 0)
  // obj_ptr = base + 4
  emit_local_get(buf, base_local)
  emit_i32_const_raw(buf, 4)
  emit_i32_add(buf)
  emit_local_set(buf, obj_local)
  // Write type tag at obj_ptr[0]
  emit_local_get(buf, obj_local)
  emit_i32_const_raw(buf, type_tag)
  emit_i32_store(buf, 0)
  // Write len=0 at obj_ptr[4]
  emit_local_get(buf, obj_local)
  emit_i32_const_raw(buf, 0)
  emit_i32_store(buf, 4)
}

///|
/// Emit bounds check + heap-tip growth for builder push operations.
/// Must be called BEFORE writing the new element.
/// ptr_local holds the untagged obj pointer (points to tag field).
/// elem_size is bytes per element (4 for array/string, 8 for map).
/// After this code, it is safe to write at [ptr + 8 + len * elem_size].
fn emit_builder_grow_check(
  ctx : CodegenCtx,
  buf : ByteBuf,
  ptr_local : Int,
  elem_size : Int,
) -> Unit {
  require_heap(ctx)
  let cap_local = alloc_temp_local(ctx)
  let len_local = alloc_temp_local(ctx)
  let old_end_local = alloc_temp_local(ctx)
  let new_cap_local = alloc_temp_local(ctx)
  let additional_local = alloc_temp_local(ctx)
  // Read capacity from hidden prefix at ptr - 4
  emit_local_get(buf, ptr_local)
  emit_i32_const_raw(buf, 4)
  emit_i32_sub(buf)
  emit_i32_load(buf, 0)
  emit_local_set(buf, cap_local)
  // Read current length
  emit_local_get(buf, ptr_local)
  emit_i32_load(buf, 4)
  emit_local_set(buf, len_local)
  // if len >= cap: need to grow
  emit_local_get(buf, len_local)
  emit_local_get(buf, cap_local)
  emit_i32_ge_s(buf)
  buf.push((4).to_byte()) // if
  buf.push((64).to_byte()) // void
  // Compute old_alloc_end = (ptr - 4) + align4(4 + 8 + cap * elem_size)
  // = ptr + align4(8 + cap * elem_size)
  // Simplification: since we used align4 at alloc time, old_end = ptr - 4 + alloc_size
  // But we don't know alloc_size. Recompute: alloc_size = align4(4 + 8 + cap * elem_size)
  emit_local_get(buf, cap_local)
  emit_i32_const_raw(buf, elem_size)
  emit_i32_mul(buf)
  emit_i32_const_raw(buf, 4 + 8 + 3) // 4(cap prefix) + 8(header) + 3(alignment)
  emit_i32_add(buf)
  emit_i32_const_raw(buf, -4)
  emit_i32_and(buf) // align4
  emit_local_get(buf, ptr_local)
  emit_i32_const_raw(buf, 4)
  emit_i32_sub(buf)
  emit_i32_add(buf)
  emit_local_set(buf, old_end_local)
  // Check if at heap tip: old_end == heap_local
  emit_local_get(buf, old_end_local)
  emit_local_get(buf, ctx.heap_local)
  emit_i32_eq(buf)
  buf.push((4).to_byte()) // if (at heap tip)
  buf.push((64).to_byte()) // void
  // new_cap = cap * 2
  emit_local_get(buf, cap_local)
  emit_i32_const_raw(buf, 1)
  emit_i32_shl(buf)
  emit_local_set(buf, new_cap_local)
  // additional bytes = (new_cap - cap) * elem_size
  emit_local_get(buf, new_cap_local)
  emit_local_get(buf, cap_local)
  emit_i32_sub(buf)
  emit_i32_const_raw(buf, elem_size)
  emit_i32_mul(buf)
  emit_local_set(buf, additional_local)
  // Reserve additional space (may grow WASM memory)
  emit_heap_reserve_local(ctx, buf, additional_local)
  // Advance heap pointer
  emit_local_get(buf, ctx.heap_local)
  emit_local_get(buf, additional_local)
  emit_i32_add(buf)
  emit_local_set(buf, ctx.heap_local)
  ctx.heap_synced = false
  // Update capacity in hidden prefix
  emit_local_get(buf, ptr_local)
  emit_i32_const_raw(buf, 4)
  emit_i32_sub(buf)
  emit_local_get(buf, new_cap_local)
  emit_i32_store(buf, 0)
  buf.push((5).to_byte()) // else (not at heap tip — full realloc)
  // new_cap = cap * 2
  emit_local_get(buf, cap_local)
  emit_i32_const_raw(buf, 1)
  emit_i32_shl(buf)
  emit_local_set(buf, new_cap_local)
  // Allocate new buffer: alloc_size = align4(4 + 8 + new_cap * elem_size)
  let new_alloc_size_local = alloc_temp_local(ctx)
  emit_local_get(buf, new_cap_local)
  emit_i32_const_raw(buf, elem_size)
  emit_i32_mul(buf)
  emit_i32_const_raw(buf, 4 + 8 + 3)
  emit_i32_add(buf)
  emit_i32_const_raw(buf, -4)
  emit_i32_and(buf)
  emit_local_set(buf, new_alloc_size_local)
  let new_base_local = alloc_temp_local(ctx)
  emit_heap_alloc_local(ctx, buf, new_alloc_size_local, new_base_local)
  // Write new_cap at new_base[0]
  emit_local_get(buf, new_base_local)
  emit_local_get(buf, new_cap_local)
  emit_i32_store(buf, 0)
  // Copy old data: memcpy(new_base + 4, ptr - 4 + 4, 8 + len * elem_size)
  // i.e., copy [tag][len][data...] from ptr to new_base+4
  let copy_size_local = alloc_temp_local(ctx)
  emit_local_get(buf, len_local)
  emit_i32_const_raw(buf, elem_size)
  emit_i32_mul(buf)
  emit_i32_const_raw(buf, 8)
  emit_i32_add(buf)
  emit_local_set(buf, copy_size_local)
  // Copy i32 words: dst=new_base+4, src=ptr_local, count=copy_size/4
  let copy_words_local = alloc_temp_local(ctx)
  emit_local_get(buf, copy_size_local)
  emit_i32_const_raw(buf, 2)
  emit_i32_shr_u(buf) // copy_size / 4
  emit_local_set(buf, copy_words_local)
  let copy_i_local = alloc_temp_local(ctx)
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, copy_i_local)
  emit_block(buf) // block $copy_done
  emit_loop(buf) // loop $copy_loop
  emit_local_get(buf, copy_i_local)
  emit_local_get(buf, copy_words_local)
  emit_i32_ge_s(buf)
  emit_br_if(buf, 1) // break $copy_done
  // dst[copy_i*4] = src[copy_i*4]
  emit_local_get(buf, new_base_local)
  emit_i32_const_raw(buf, 4)
  emit_i32_add(buf)
  emit_local_get(buf, copy_i_local)
  emit_i32_const_raw(buf, 4)
  emit_i32_mul(buf)
  emit_i32_add(buf)
  emit_local_get(buf, ptr_local)
  emit_local_get(buf, copy_i_local)
  emit_i32_const_raw(buf, 4)
  emit_i32_mul(buf)
  emit_i32_add(buf)
  emit_i32_load(buf, 0)
  emit_i32_store(buf, 0)
  emit_local_get(buf, copy_i_local)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, copy_i_local)
  emit_br(buf, 0) // continue $copy_loop
  emit_end(buf) // end $copy_loop
  emit_end(buf) // end $copy_done
  // Update ptr_local to point to new_base + 4
  emit_local_get(buf, new_base_local)
  emit_i32_const_raw(buf, 4)
  emit_i32_add(buf)
  emit_local_set(buf, ptr_local)
  buf.push((11).to_byte()) // end if (at heap tip)
  buf.push((11).to_byte()) // end if (len >= cap)
}

///|
/// Emit bulk capacity check for operations like push_all that add multiple elements.
/// Ensures cap >= needed_total (len + additional_count).
/// ptr_local may be updated if realloc occurs.
fn emit_builder_bulk_grow_check(
  ctx : CodegenCtx,
  buf : ByteBuf,
  ptr_local : Int,
  additional_count_local : Int,
  elem_size : Int,
) -> Unit {
  require_heap(ctx)
  let cap_local = alloc_temp_local(ctx)
  let len_local = alloc_temp_local(ctx)
  let needed_local = alloc_temp_local(ctx)
  let old_end_local = alloc_temp_local(ctx)
  let new_cap_local = alloc_temp_local(ctx)
  let additional_bytes_local = alloc_temp_local(ctx)
  // Read capacity from hidden prefix at ptr - 4
  emit_local_get(buf, ptr_local)
  emit_i32_const_raw(buf, 4)
  emit_i32_sub(buf)
  emit_i32_load(buf, 0)
  emit_local_set(buf, cap_local)
  // Read current length
  emit_local_get(buf, ptr_local)
  emit_i32_load(buf, 4)
  emit_local_set(buf, len_local)
  // needed = len + additional_count
  emit_local_get(buf, len_local)
  emit_local_get(buf, additional_count_local)
  emit_i32_add(buf)
  emit_local_set(buf, needed_local)
  // if needed > cap: grow
  emit_local_get(buf, needed_local)
  emit_local_get(buf, cap_local)
  emit_i32_gt_s(buf)
  buf.push((4).to_byte()) // if
  buf.push((64).to_byte()) // void
  // new_cap = max(cap * 2, needed)
  emit_local_get(buf, cap_local)
  emit_i32_const_raw(buf, 1)
  emit_i32_shl(buf)
  emit_local_set(buf, new_cap_local)
  emit_local_get(buf, new_cap_local)
  emit_local_get(buf, needed_local)
  emit_i32_lt_s(buf)
  buf.push((4).to_byte()) // if
  buf.push((64).to_byte()) // void
  emit_local_get(buf, needed_local)
  emit_local_set(buf, new_cap_local)
  buf.push((11).to_byte()) // end if
  // Compute old_alloc_end
  emit_local_get(buf, cap_local)
  emit_i32_const_raw(buf, elem_size)
  emit_i32_mul(buf)
  emit_i32_const_raw(buf, 4 + 8 + 3)
  emit_i32_add(buf)
  emit_i32_const_raw(buf, -4)
  emit_i32_and(buf)
  emit_local_get(buf, ptr_local)
  emit_i32_const_raw(buf, 4)
  emit_i32_sub(buf)
  emit_i32_add(buf)
  emit_local_set(buf, old_end_local)
  // Check if at heap tip
  emit_local_get(buf, old_end_local)
  emit_local_get(buf, ctx.heap_local)
  emit_i32_eq(buf)
  buf.push((4).to_byte()) // if (at heap tip)
  buf.push((64).to_byte()) // void
  // additional_bytes = (new_cap - cap) * elem_size
  emit_local_get(buf, new_cap_local)
  emit_local_get(buf, cap_local)
  emit_i32_sub(buf)
  emit_i32_const_raw(buf, elem_size)
  emit_i32_mul(buf)
  emit_local_set(buf, additional_bytes_local)
  emit_heap_reserve_local(ctx, buf, additional_bytes_local)
  emit_local_get(buf, ctx.heap_local)
  emit_local_get(buf, additional_bytes_local)
  emit_i32_add(buf)
  emit_local_set(buf, ctx.heap_local)
  ctx.heap_synced = false
  // Update capacity
  emit_local_get(buf, ptr_local)
  emit_i32_const_raw(buf, 4)
  emit_i32_sub(buf)
  emit_local_get(buf, new_cap_local)
  emit_i32_store(buf, 0)
  buf.push((5).to_byte()) // else (not at heap tip — full realloc)
  // Allocate new buffer
  let new_alloc_size_local = alloc_temp_local(ctx)
  emit_local_get(buf, new_cap_local)
  emit_i32_const_raw(buf, elem_size)
  emit_i32_mul(buf)
  emit_i32_const_raw(buf, 4 + 8 + 3)
  emit_i32_add(buf)
  emit_i32_const_raw(buf, -4)
  emit_i32_and(buf)
  emit_local_set(buf, new_alloc_size_local)
  let new_base_local = alloc_temp_local(ctx)
  emit_heap_alloc_local(ctx, buf, new_alloc_size_local, new_base_local)
  // Write new_cap at new_base[0]
  emit_local_get(buf, new_base_local)
  emit_local_get(buf, new_cap_local)
  emit_i32_store(buf, 0)
  // Copy old data: memcpy(new_base + 4, ptr, 8 + len * elem_size)
  let copy_size_local = alloc_temp_local(ctx)
  emit_local_get(buf, len_local)
  emit_i32_const_raw(buf, elem_size)
  emit_i32_mul(buf)
  emit_i32_const_raw(buf, 8)
  emit_i32_add(buf)
  emit_local_set(buf, copy_size_local)
  let copy_words_local = alloc_temp_local(ctx)
  emit_local_get(buf, copy_size_local)
  emit_i32_const_raw(buf, 2)
  emit_i32_shr_u(buf)
  emit_local_set(buf, copy_words_local)
  let copy_i_local = alloc_temp_local(ctx)
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, copy_i_local)
  emit_block(buf)
  emit_loop(buf)
  emit_local_get(buf, copy_i_local)
  emit_local_get(buf, copy_words_local)
  emit_i32_ge_s(buf)
  emit_br_if(buf, 1)
  emit_local_get(buf, new_base_local)
  emit_i32_const_raw(buf, 4)
  emit_i32_add(buf)
  emit_local_get(buf, copy_i_local)
  emit_i32_const_raw(buf, 4)
  emit_i32_mul(buf)
  emit_i32_add(buf)
  emit_local_get(buf, ptr_local)
  emit_local_get(buf, copy_i_local)
  emit_i32_const_raw(buf, 4)
  emit_i32_mul(buf)
  emit_i32_add(buf)
  emit_i32_load(buf, 0)
  emit_i32_store(buf, 0)
  emit_local_get(buf, copy_i_local)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, copy_i_local)
  emit_br(buf, 0)
  emit_end(buf)
  emit_end(buf)
  // Update ptr_local to new location
  emit_local_get(buf, new_base_local)
  emit_i32_const_raw(buf, 4)
  emit_i32_add(buf)
  emit_local_set(buf, ptr_local)
  buf.push((11).to_byte()) // end if (at heap tip)
  buf.push((11).to_byte()) // end if (needed > cap)
}

///|
fn emit_bytes_raw_load_header(
  buf : ByteBuf,
  ptr_local : Int,
  len_local : Int,
  cap_local : Int,
  data_local : Int,
) -> Unit {
  emit_local_get(buf, ptr_local)
  emit_i32_load(buf, 4)
  emit_local_set(buf, len_local)
  emit_local_get(buf, ptr_local)
  emit_i32_load(buf, 8)
  emit_local_set(buf, cap_local)
  emit_local_get(buf, ptr_local)
  emit_i32_load(buf, 12)
  emit_local_set(buf, data_local)
  // Negative cap means the raw bytes object is shared/frozen.
  // Decode: cap < 0 → 0 - cap - 1 (symmetric with emit_bytes_raw_mark_shared encode).
  emit_local_get(buf, cap_local)
  emit_i32_const_raw(buf, 0)
  emit_i32_lt_s(buf)
  buf.push((4).to_byte()) // if
  buf.push((127).to_byte()) // result i32
  emit_i32_const_raw(buf, 0)
  emit_local_get(buf, cap_local)
  emit_i32_sub(buf)
  emit_i32_const_raw(buf, 1)
  emit_i32_sub(buf)
  buf.push((5).to_byte()) // else
  emit_local_get(buf, cap_local)
  buf.push((11).to_byte()) // end if
  emit_local_set(buf, cap_local)
}

///|
fn emit_bytes_raw_mark_shared(
  ctx : CodegenCtx,
  buf : ByteBuf,
  ptr_local : Int,
) -> Unit {
  let raw_cap_local = alloc_temp_local(ctx)
  emit_local_get(buf, ptr_local)
  emit_i32_load(buf, 8)
  emit_local_set(buf, raw_cap_local)
  // Encode: cap >= 0 → 0 - cap - 1 (symmetric with emit_bytes_raw_load_header decode).
  emit_local_get(buf, raw_cap_local)
  emit_i32_const_raw(buf, 0)
  emit_i32_ge_s(buf)
  buf.push((4).to_byte()) // if
  buf.push((64).to_byte()) // void
  emit_local_get(buf, ptr_local)
  emit_i32_const_raw(buf, 0)
  emit_local_get(buf, raw_cap_local)
  emit_i32_sub(buf)
  emit_i32_const_raw(buf, 1)
  emit_i32_sub(buf)
  emit_i32_store(buf, 8)
  buf.push((11).to_byte()) // end if
}

///|
fn emit_bytes_load_header(
  ctx : CodegenCtx,
  buf : ByteBuf,
  ptr_local : Int,
  len_local : Int,
  cap_local : Int,
  data_local : Int,
) -> Unit {
  let obj_ty_local = alloc_temp_local(ctx)
  emit_local_get(buf, ptr_local)
  emit_i32_load(buf, 0)
  emit_local_set(buf, obj_ty_local)
  emit_local_get(buf, obj_ty_local)
  emit_i32_const_raw(buf, obj_bytes_view)
  emit_i32_eq(buf)
  buf.push((4).to_byte()) // if
  buf.push((64).to_byte()) // void
  let source_local = alloc_temp_local(ctx)
  let start_local = alloc_temp_local(ctx)
  emit_local_get(buf, ptr_local)
  emit_i32_load(buf, 4)
  emit_local_set(buf, source_local)
  emit_local_get(buf, ptr_local)
  emit_i32_load(buf, 8)
  emit_local_set(buf, start_local)
  emit_local_get(buf, ptr_local)
  emit_i32_load(buf, 12)
  emit_local_get(buf, start_local)
  emit_i32_sub(buf)
  emit_local_set(buf, len_local)
  emit_local_get(buf, len_local)
  emit_local_set(buf, cap_local)
  emit_local_get(buf, source_local)
  emit_i32_load(buf, 12)
  emit_local_get(buf, start_local)
  emit_i32_add(buf)
  emit_local_set(buf, data_local)
  buf.push((5).to_byte()) // else
  emit_bytes_raw_load_header(buf, ptr_local, len_local, cap_local, data_local)
  buf.push((11).to_byte()) // end if
}

///|
/// Allocate a new buffer, copy len bytes from data_local, rewrite ptr_local
/// header as a mutable raw bytes object.  data_local is updated to the new
/// allocation on return.
fn emit_bytes_cow_copy(
  ctx : CodegenCtx,
  buf : ByteBuf,
  ptr_local : Int,
  len_local : Int,
  cap_local : Int,
  data_local : Int,
) -> Unit {
  let alloc_size_local = alloc_temp_local(ctx)
  let new_data_local = alloc_temp_local(ctx)
  emit_local_get(buf, cap_local)
  emit_i32_const_raw(buf, 3)
  emit_i32_add(buf)
  emit_i32_const_raw(buf, -4)
  emit_i32_and(buf)
  emit_local_set(buf, alloc_size_local)
  emit_heap_alloc_local(ctx, buf, alloc_size_local, new_data_local)
  emit_local_get(buf, new_data_local)
  emit_local_get(buf, data_local)
  emit_local_get(buf, len_local)
  emit_memory_copy(buf)
  // Rewrite header as mutable raw bytes
  emit_local_get(buf, ptr_local)
  emit_i32_const_raw(buf, obj_bytes)
  emit_i32_store(buf, 0)
  emit_local_get(buf, ptr_local)
  emit_local_get(buf, len_local)
  emit_i32_store(buf, 4)
  emit_local_get(buf, ptr_local)
  emit_local_get(buf, cap_local)
  emit_i32_store(buf, 8)
  emit_local_get(buf, ptr_local)
  emit_local_get(buf, new_data_local)
  emit_i32_store(buf, 12)
  emit_local_get(buf, new_data_local)
  emit_local_set(buf, data_local)
}

///|
fn emit_untag_int_i32(buf : ByteBuf) -> Unit {
  emit_i64_const_raw(buf, 2L)
  emit_i64_shr_s(buf)
  emit_i32_wrap_i64(buf)
}

///|
fn emit_untag_ptr_i32(buf : ByteBuf) -> Unit {
  emit_i64_const_raw(buf, (-4).to_int64())
  emit_i64_and(buf)
  emit_i32_wrap_i64(buf)
}

///|
/// Resolve view/raw header into len/cap/data, then COW-copy if the object is
/// a view or a shared (frozen) raw bytes.
fn emit_bytes_ensure_mutable(
  ctx : CodegenCtx,
  buf : ByteBuf,
  ptr_local : Int,
  len_local : Int,
  cap_local : Int,
  data_local : Int,
) -> Unit {
  // Resolve view or raw → unified len/cap/data
  emit_bytes_load_header(ctx, buf, ptr_local, len_local, cap_local, data_local)
  // needs_cow = (obj_type == view) || (raw cap field < 0)
  // For view: field at +8 is "start" (not cap), but the OR covers it.
  // For raw: field at +8 is raw cap; negative means shared/frozen.
  let obj_ty_local = alloc_temp_local(ctx)
  let raw_cap_local = alloc_temp_local(ctx)
  emit_local_get(buf, ptr_local)
  emit_i32_load(buf, 0)
  emit_local_set(buf, obj_ty_local)
  emit_local_get(buf, ptr_local)
  emit_i32_load(buf, 8)
  emit_local_set(buf, raw_cap_local)
  emit_local_get(buf, obj_ty_local)
  emit_i32_const_raw(buf, obj_bytes_view)
  emit_i32_eq(buf)
  emit_local_get(buf, raw_cap_local)
  emit_i32_const_raw(buf, 0)
  emit_i32_lt_s(buf)
  emit_i32_or(buf)
  buf.push((4).to_byte()) // if
  buf.push((64).to_byte()) // void
  emit_bytes_cow_copy(ctx, buf, ptr_local, len_local, cap_local, data_local)
  buf.push((11).to_byte()) // end if
}

///|
fn emit_bytes_raw_alloc_with_cap_local(
  ctx : CodegenCtx,
  buf : ByteBuf,
  len_local : Int,
  cap_local : Int,
  obj_local : Int,
  data_local : Int,
) -> Unit {
  let data_size_local = alloc_temp_local(ctx)
  emit_local_get(buf, cap_local)
  emit_i32_const_raw(buf, 3)
  emit_i32_add(buf)
  emit_i32_const_raw(buf, -4)
  emit_i32_and(buf)
  emit_local_set(buf, data_size_local)
  emit_heap_alloc(ctx, buf, align4(16), obj_local)
  emit_heap_alloc_local(ctx, buf, data_size_local, data_local)
  emit_local_get(buf, obj_local)
  emit_i32_const_raw(buf, obj_bytes)
  emit_i32_store(buf, 0)
  emit_local_get(buf, obj_local)
  emit_local_get(buf, len_local)
  emit_i32_store(buf, 4)
  emit_local_get(buf, obj_local)
  emit_local_get(buf, cap_local)
  emit_i32_store(buf, 8)
  emit_local_get(buf, obj_local)
  emit_local_get(buf, data_local)
  emit_i32_store(buf, 12)
}

///|
fn emit_bytes_raw_ensure_capacity(
  ctx : CodegenCtx,
  buf : ByteBuf,
  ptr_local : Int,
  len_local : Int,
  add_local : Int,
  cap_local : Int,
  data_local : Int,
) -> Unit {
  let needed_local = alloc_temp_local(ctx)
  let doubled_cap_local = alloc_temp_local(ctx)
  let new_cap_local = alloc_temp_local(ctx)
  let data_size_local = alloc_temp_local(ctx)
  let new_data_local = alloc_temp_local(ctx)
  emit_local_get(buf, len_local)
  emit_local_get(buf, add_local)
  emit_i32_add(buf)
  emit_local_set(buf, needed_local)
  emit_local_get(buf, needed_local)
  emit_local_get(buf, cap_local)
  emit_i32_gt_u(buf)
  buf.push((4).to_byte()) // if
  buf.push((64).to_byte()) // void
  emit_local_get(buf, cap_local)
  emit_i32_const_raw(buf, 2)
  emit_i32_mul(buf)
  emit_local_set(buf, doubled_cap_local)
  emit_local_get(buf, doubled_cap_local)
  emit_local_get(buf, needed_local)
  emit_i32_gt_u(buf)
  buf.push((4).to_byte()) // if
  buf.push((127).to_byte()) // result i32
  emit_local_get(buf, doubled_cap_local)
  buf.push((5).to_byte()) // else
  emit_local_get(buf, needed_local)
  buf.push((11).to_byte()) // end if
  emit_local_set(buf, new_cap_local)
  emit_local_get(buf, new_cap_local)
  emit_i32_const_raw(buf, 3)
  emit_i32_add(buf)
  emit_i32_const_raw(buf, -4)
  emit_i32_and(buf)
  emit_local_set(buf, data_size_local)
  emit_heap_alloc_local(ctx, buf, data_size_local, new_data_local)
  emit_local_get(buf, new_data_local)
  emit_local_get(buf, data_local)
  emit_local_get(buf, len_local)
  emit_memory_copy(buf)
  emit_local_get(buf, ptr_local)
  emit_local_get(buf, new_cap_local)
  emit_i32_store(buf, 8)
  emit_local_get(buf, ptr_local)
  emit_local_get(buf, new_data_local)
  emit_i32_store(buf, 12)
  emit_local_get(buf, new_cap_local)
  emit_local_set(buf, cap_local)
  emit_local_get(buf, new_data_local)
  emit_local_set(buf, data_local)
  buf.push((11).to_byte()) // end if
}

///|
fn compile_call_builtin_pre_user(
  ctx : CodegenCtx,
  buf : ByteBuf,
  name : String,
  args : Array[@core.CallArg],
  is_user_fn : Bool,
) -> Bool raise WasmGenError {
  let result : Result[Unit, WasmGenError] = try? compile_call_builtin_pre_user_inner(
    ctx, buf, name, args, is_user_fn,
  )
  match result {
    Ok(_) => true
    Err(WasmGenError::Unsupported(message)) =>
      if message == pre_user_builtin_unhandled_marker {
        false
      } else {
        raise WasmGenError::Unsupported(message)
      }
    Err(err) => raise err
  }
}

///|
fn emit_load_obj_number_as_f64(
  buf : ByteBuf,
  obj_ptr_local : Int,
  obj_ty_local : Int,
) -> Unit {
  emit_local_get(buf, obj_ty_local)
  emit_i32_const_raw(buf, obj_float)
  emit_i32_eq(buf)
  buf.push((4).to_byte()) // if
  buf.push((124).to_byte()) // result f64
  emit_local_get(buf, obj_ptr_local)
  emit_f32_load(buf, 4)
  emit_f64_promote_f32(buf)
  buf.push((5).to_byte()) // else
  emit_local_get(buf, obj_ptr_local)
  emit_f64_load(buf, 4)
  buf.push((11).to_byte()) // end if
}

///|
fn emit_non_js_string_ptr_equals_i32(
  ctx : CodegenCtx,
  buf : ByteBuf,
  left_ptr_local : Int,
  right_ptr_local : Int,
) -> Unit {
  let left_base_local = alloc_temp_local(ctx)
  let right_base_local = alloc_temp_local(ctx)
  let left_len_local = alloc_temp_local(ctx)
  let right_len_local = alloc_temp_local(ctx)
  let loop_i_local = alloc_temp_local(ctx)
  let eq_local = alloc_temp_local(ctx)
  emit_local_get(buf, left_ptr_local)
  emit_i32_const_raw(buf, -4)
  emit_i32_and(buf)
  emit_local_set(buf, left_base_local)
  emit_local_get(buf, right_ptr_local)
  emit_i32_const_raw(buf, -4)
  emit_i32_and(buf)
  emit_local_set(buf, right_base_local)
  emit_local_get(buf, left_base_local)
  emit_local_get(buf, right_base_local)
  emit_i32_eq(buf)
  buf.push((4).to_byte()) // if
  buf.push((127).to_byte()) // result i32
  emit_i32_const_raw(buf, 1)
  buf.push((5).to_byte()) // else
  emit_local_get(buf, left_base_local)
  emit_i32_load(buf, 4)
  emit_local_set(buf, left_len_local)
  emit_local_get(buf, right_base_local)
  emit_i32_load(buf, 4)
  emit_local_set(buf, right_len_local)
  emit_local_get(buf, left_len_local)
  emit_local_get(buf, right_len_local)
  emit_i32_eq(buf)
  buf.push((4).to_byte()) // if
  buf.push((127).to_byte()) // result i32
  emit_i32_const_raw(buf, 1)
  emit_local_set(buf, eq_local)
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, loop_i_local)
  emit_block(buf)
  emit_loop(buf)
  emit_local_get(buf, loop_i_local)
  emit_local_get(buf, left_len_local)
  emit_i32_lt_s(buf)
  emit_i32_eqz(buf)
  emit_br_if(buf, 1)
  emit_local_get(buf, left_base_local)
  emit_local_get(buf, loop_i_local)
  emit_i32_add(buf)
  emit_i32_load8_u(buf, 8)
  emit_local_get(buf, right_base_local)
  emit_local_get(buf, loop_i_local)
  emit_i32_add(buf)
  emit_i32_load8_u(buf, 8)
  emit_i32_eq(buf)
  emit_i32_eqz(buf)
  buf.push((4).to_byte()) // if
  buf.push((64).to_byte()) // void
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, eq_local)
  emit_local_get(buf, left_len_local)
  emit_local_set(buf, loop_i_local)
  buf.push((5).to_byte()) // else
  emit_local_get(buf, loop_i_local)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, loop_i_local)
  buf.push((11).to_byte()) // end if
  emit_br(buf, 0)
  emit_end(buf)
  emit_end(buf)
  emit_local_get(buf, eq_local)
  buf.push((5).to_byte()) // else
  emit_i32_const_raw(buf, 0)
  buf.push((11).to_byte()) // end if
  buf.push((11).to_byte()) // end if
}

///|
fn emit_number_obj_to_string(
  ctx : CodegenCtx,
  buf : ByteBuf,
  obj_ptr_local : Int,
  obj_ty_local : Int,
  fallback_str : Int64,
) -> Unit {
  let is_neg_local = alloc_temp_local(ctx)
  let int_part_local = alloc_temp_local(ctx)
  let scaled_local = alloc_temp_local(ctx)
  let frac_tmp_local = alloc_temp_local(ctx)
  let int_len_local = alloc_temp_local(ctx)
  let frac_len_local = alloc_temp_local(ctx)
  let digit_local = alloc_temp_local(ctx)
  let copy_i_local = alloc_temp_local(ctx)
  let src_idx_local = alloc_temp_local(ctx)
  let total_len_local = alloc_temp_local(ctx)
  let alloc_size_local = alloc_temp_local(ctx)
  let obj_local = alloc_temp_local(ctx)
  let scratch_local = alloc_temp_local(ctx)
  let invalid_local = alloc_temp_local(ctx)

  emit_heap_alloc(ctx, buf, 96, scratch_local)

  // scratch[0..8): original value as f64
  emit_local_get(buf, scratch_local)
  emit_load_obj_number_as_f64(buf, obj_ptr_local, obj_ty_local)
  emit_f64_store(buf, 0)

  // is_neg = value < 0.0
  emit_local_get(buf, scratch_local)
  emit_f64_load(buf, 0)
  emit_f64_const(buf, 0.0)
  emit_f64_lt(buf)
  emit_local_set(buf, is_neg_local)

  // scratch[8..16): abs(value)
  emit_local_get(buf, scratch_local)
  emit_local_get(buf, is_neg_local)
  buf.push((4).to_byte()) // if
  buf.push((124).to_byte()) // result f64
  emit_f64_const(buf, 0.0)
  emit_local_get(buf, scratch_local)
  emit_f64_load(buf, 0)
  emit_f64_sub(buf)
  buf.push((5).to_byte()) // else
  emit_local_get(buf, scratch_local)
  emit_f64_load(buf, 0)
  buf.push((11).to_byte()) // end if
  emit_f64_store(buf, 8)

  // invalid = isnan(abs)
  emit_local_get(buf, scratch_local)
  emit_f64_load(buf, 8)
  emit_local_get(buf, scratch_local)
  emit_f64_load(buf, 8)
  emit_f64_eq(buf)
  emit_i32_eqz(buf)
  emit_local_set(buf, invalid_local)

  // invalid |= abs > 2147483647.0
  emit_local_get(buf, scratch_local)
  emit_f64_load(buf, 8)
  emit_f64_const(buf, 2147483647.0)
  emit_f64_gt(buf)
  emit_local_get(buf, invalid_local)
  emit_i32_or(buf)
  emit_local_set(buf, invalid_local)

  emit_local_get(buf, invalid_local)
  buf.push((4).to_byte()) // if
  buf.push((126).to_byte()) // result i64
  emit_i64_const_raw(buf, fallback_str)
  buf.push((5).to_byte()) // else

  // int_part = trunc(abs)
  emit_local_get(buf, scratch_local)
  emit_f64_load(buf, 8)
  emit_i64_trunc_f64_s(buf)
  emit_i32_wrap_i64(buf)
  emit_local_set(buf, int_part_local)

  // scratch[16..24): frac = abs - int_to_double(int_part)
  emit_local_get(buf, scratch_local)
  emit_local_get(buf, scratch_local)
  emit_f64_load(buf, 8)
  emit_local_get(buf, int_part_local)
  emit_i64_extend_i32_s(buf)
  emit_f64_convert_i64_s(buf)
  emit_f64_sub(buf)
  emit_f64_store(buf, 16)

  // scaled = trunc(frac * 1_000_000 + 0.5)
  emit_local_get(buf, scratch_local)
  emit_f64_load(buf, 16)
  emit_f64_const(buf, 1000000.0)
  emit_f64_mul(buf)
  emit_f64_const(buf, 0.5)
  emit_f64_add(buf)
  emit_i64_trunc_f64_s(buf)
  emit_i32_wrap_i64(buf)
  emit_local_set(buf, scaled_local)

  // Carry from fractional rounding.
  emit_local_get(buf, scaled_local)
  emit_i32_const_raw(buf, 1000000)
  emit_i32_eq(buf)
  buf.push((4).to_byte()) // if
  buf.push((64).to_byte()) // void
  emit_local_get(buf, int_part_local)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, int_part_local)
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, scaled_local)
  buf.push((11).to_byte()) // end if

  // Encode int digits in reverse into scratch+32.
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, int_len_local)
  emit_local_get(buf, int_part_local)
  emit_i32_eqz(buf)
  buf.push((4).to_byte()) // if
  buf.push((64).to_byte()) // void
  emit_local_get(buf, scratch_local)
  emit_i32_const_raw(buf, 48)
  emit_i32_store8(buf, 32)
  emit_i32_const_raw(buf, 1)
  emit_local_set(buf, int_len_local)
  buf.push((5).to_byte()) // else
  emit_block(buf)
  emit_loop(buf)
  emit_local_get(buf, int_part_local)
  emit_i32_eqz(buf)
  emit_br_if(buf, 1)
  emit_local_get(buf, int_part_local)
  emit_i32_const_raw(buf, 10)
  emit_i32_rem_s(buf)
  emit_local_set(buf, digit_local)
  emit_local_get(buf, int_part_local)
  emit_i32_const_raw(buf, 10)
  emit_i32_div_s(buf)
  emit_local_set(buf, int_part_local)
  emit_local_get(buf, scratch_local)
  emit_local_get(buf, int_len_local)
  emit_i32_add(buf)
  emit_local_get(buf, digit_local)
  emit_i32_const_raw(buf, 48)
  emit_i32_add(buf)
  emit_i32_store8(buf, 32)
  emit_local_get(buf, int_len_local)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, int_len_local)
  emit_br(buf, 0)
  emit_end(buf)
  emit_end(buf)
  buf.push((11).to_byte()) // end if

  // Encode fraction (zero-padded 6 digits) into scratch+48, then trim tail zeros.
  emit_local_get(buf, scaled_local)
  emit_i32_eqz(buf)
  buf.push((4).to_byte()) // if
  buf.push((64).to_byte()) // void
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, frac_len_local)
  buf.push((5).to_byte()) // else
  emit_local_get(buf, scaled_local)
  emit_local_set(buf, frac_tmp_local)
  emit_i32_const_raw(buf, 6)
  emit_local_set(buf, copy_i_local)
  emit_block(buf)
  emit_loop(buf)
  emit_local_get(buf, copy_i_local)
  emit_i32_eqz(buf)
  emit_br_if(buf, 1)
  emit_local_get(buf, copy_i_local)
  emit_i32_const_raw(buf, 1)
  emit_i32_sub(buf)
  emit_local_set(buf, copy_i_local)
  emit_local_get(buf, frac_tmp_local)
  emit_i32_const_raw(buf, 10)
  emit_i32_rem_s(buf)
  emit_local_set(buf, digit_local)
  emit_local_get(buf, frac_tmp_local)
  emit_i32_const_raw(buf, 10)
  emit_i32_div_s(buf)
  emit_local_set(buf, frac_tmp_local)
  emit_local_get(buf, scratch_local)
  emit_local_get(buf, copy_i_local)
  emit_i32_add(buf)
  emit_local_get(buf, digit_local)
  emit_i32_const_raw(buf, 48)
  emit_i32_add(buf)
  emit_i32_store8(buf, 48)
  emit_br(buf, 0)
  emit_end(buf)
  emit_end(buf)
  emit_i32_const_raw(buf, 6)
  emit_local_set(buf, frac_len_local)
  emit_block(buf)
  emit_loop(buf)
  emit_local_get(buf, frac_len_local)
  emit_i32_eqz(buf)
  emit_br_if(buf, 1)
  emit_local_get(buf, frac_len_local)
  emit_i32_const_raw(buf, 1)
  emit_i32_sub(buf)
  emit_local_set(buf, src_idx_local)
  emit_local_get(buf, scratch_local)
  emit_local_get(buf, src_idx_local)
  emit_i32_add(buf)
  emit_i32_load8_u(buf, 48)
  emit_i32_const_raw(buf, 48)
  emit_i32_eq(buf)
  emit_i32_eqz(buf)
  emit_br_if(buf, 1)
  emit_local_get(buf, frac_len_local)
  emit_i32_const_raw(buf, 1)
  emit_i32_sub(buf)
  emit_local_set(buf, frac_len_local)
  emit_br(buf, 0)
  emit_end(buf)
  emit_end(buf)
  buf.push((11).to_byte()) // end if

  // total_len = int_len + sign + (frac_len>0 ? 1 + frac_len : 0)
  emit_local_get(buf, int_len_local)
  emit_local_set(buf, total_len_local)
  emit_local_get(buf, is_neg_local)
  emit_i32_eqz(buf)
  buf.push((4).to_byte()) // if
  buf.push((64).to_byte()) // void
  buf.push((5).to_byte()) // else
  emit_local_get(buf, total_len_local)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, total_len_local)
  buf.push((11).to_byte()) // end if
  emit_local_get(buf, frac_len_local)
  emit_i32_eqz(buf)
  buf.push((4).to_byte()) // if
  buf.push((64).to_byte()) // void
  buf.push((5).to_byte()) // else
  emit_local_get(buf, total_len_local)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_get(buf, frac_len_local)
  emit_i32_add(buf)
  emit_local_set(buf, total_len_local)
  buf.push((11).to_byte()) // end if

  // Allocate output string object.
  emit_local_get(buf, total_len_local)
  emit_i32_const_raw(buf, 11)
  emit_i32_add(buf)
  emit_i32_const_raw(buf, -4)
  emit_i32_and(buf)
  emit_local_set(buf, alloc_size_local)
  emit_heap_alloc_local(ctx, buf, alloc_size_local, obj_local)
  emit_local_get(buf, obj_local)
  emit_i32_const_raw(buf, obj_string)
  emit_i32_store(buf, 0)
  emit_local_get(buf, obj_local)
  emit_local_get(buf, total_len_local)
  emit_i32_store(buf, 4)

  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, copy_i_local)

  // Optional leading '-'.
  emit_local_get(buf, is_neg_local)
  emit_i32_eqz(buf)
  buf.push((4).to_byte()) // if
  buf.push((64).to_byte()) // void
  buf.push((5).to_byte()) // else
  emit_local_get(buf, obj_local)
  emit_local_get(buf, copy_i_local)
  emit_i32_add(buf)
  emit_i32_const_raw(buf, 45)
  emit_i32_store8(buf, 8)
  emit_local_get(buf, copy_i_local)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, copy_i_local)
  buf.push((11).to_byte()) // end if

  // Copy integer digits in reverse order from scratch+32.
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, src_idx_local)
  emit_block(buf)
  emit_loop(buf)
  emit_local_get(buf, src_idx_local)
  emit_local_get(buf, int_len_local)
  emit_i32_lt_s(buf)
  emit_i32_eqz(buf)
  emit_br_if(buf, 1)
  emit_local_get(buf, int_len_local)
  emit_i32_const_raw(buf, 1)
  emit_i32_sub(buf)
  emit_local_get(buf, src_idx_local)
  emit_i32_sub(buf)
  emit_local_set(buf, digit_local)
  emit_local_get(buf, obj_local)
  emit_local_get(buf, copy_i_local)
  emit_i32_add(buf)
  emit_local_get(buf, scratch_local)
  emit_local_get(buf, digit_local)
  emit_i32_add(buf)
  emit_i32_load8_u(buf, 32)
  emit_i32_store8(buf, 8)
  emit_local_get(buf, copy_i_local)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, copy_i_local)
  emit_local_get(buf, src_idx_local)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, src_idx_local)
  emit_br(buf, 0)
  emit_end(buf)
  emit_end(buf)

  // Fractional part.
  emit_local_get(buf, frac_len_local)
  emit_i32_eqz(buf)
  buf.push((4).to_byte()) // if
  buf.push((64).to_byte()) // void
  buf.push((5).to_byte()) // else
  emit_local_get(buf, obj_local)
  emit_local_get(buf, copy_i_local)
  emit_i32_add(buf)
  emit_i32_const_raw(buf, 46)
  emit_i32_store8(buf, 8)
  emit_local_get(buf, copy_i_local)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, copy_i_local)
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, src_idx_local)
  emit_block(buf)
  emit_loop(buf)
  emit_local_get(buf, src_idx_local)
  emit_local_get(buf, frac_len_local)
  emit_i32_lt_s(buf)
  emit_i32_eqz(buf)
  emit_br_if(buf, 1)
  emit_local_get(buf, obj_local)
  emit_local_get(buf, copy_i_local)
  emit_i32_add(buf)
  emit_local_get(buf, scratch_local)
  emit_local_get(buf, src_idx_local)
  emit_i32_add(buf)
  emit_i32_load8_u(buf, 48)
  emit_i32_store8(buf, 8)
  emit_local_get(buf, copy_i_local)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, copy_i_local)
  emit_local_get(buf, src_idx_local)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, src_idx_local)
  emit_br(buf, 0)
  emit_end(buf)
  emit_end(buf)
  buf.push((11).to_byte()) // end if

  emit_local_get(buf, obj_local)
  emit_i64_extend_i32_u(buf)
  emit_i64_const_raw(buf, tag_obj.to_int64())
  emit_i64_or(buf)

  buf.push((11).to_byte()) // end if invalid
}

///|

///|
fn compile_call_builtin_pre_user_inner(
  ctx : CodegenCtx,
  buf : ByteBuf,
  name : String,
  args : Array[@core.CallArg],
  is_user_fn : Bool,
) -> Unit raise WasmGenError {
  // Try each domain-specific handler in turn.
  // Each handler raises WasmGenError::Unsupported(pre_user_builtin_unhandled_marker)
  // for names it does not recognise, so we catch that sentinel and try the next.
  let handlers : Array[
    (CodegenCtx, ByteBuf, String, Array[@core.CallArg], Bool) -> Unit raise WasmGenError,
  ] = [
    compile_builtin_numeric, compile_builtin_string, compile_builtin_collection,
    compile_builtin_io, compile_builtin_http, compile_builtin_misc,
  ]
  for i = 0; i < handlers.length(); i = i + 1 {
    let result : Result[Unit, WasmGenError] = try? handlers[i](
      ctx, buf, name, args, is_user_fn,
    )
    match result {
      Ok(_) => return
      Err(WasmGenError::Unsupported(message)) =>
        if message == pre_user_builtin_unhandled_marker {
          continue
        } else {
          raise WasmGenError::Unsupported(message)
        }
      Err(err) => raise err
    }
  }
  // No handler matched — check runtime fallback or raise unhandled
  if not(is_user_fn) && is_wasm_runtime_fallback_builtin(name) {
    emit_wasm_runtime_fallback_throw(ctx, buf, name)
  } else {
    raise WasmGenError::Unsupported(pre_user_builtin_unhandled_marker)
  }
}
