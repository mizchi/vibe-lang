///| Perceus reference counting codegen for linear memory WASM backend.
///|
///| This module is ONLY used by the linear memory backend (wasm_codegen_*.mbt).
///| The wasm-gc backend (wasm_gc_codegen.mbt) does NOT use RC at all.
///|
///| To build a wasm-gc-only flavor, this file and perceus_poc.mbt can be
///| excluded from the link graph without affecting wasm-gc compilation.
///|
///| Controlled by: CodegenCtx.enable_rc flag

///|
/// Action to emit at a stmt boundary (pre or post).
pub(all) enum RcStmtActionKind {
  Dup
  Drop
} derive(Show, Eq)

///|
pub(all) struct RcStmtAction {
  kind : RcStmtActionKind
  name : String
} derive(Show, Eq)

///|
/// Perceus RC codegen for WASM linear memory backend.
///
/// Memory layout with RC (negative-offset design):
///   [rc_count@-4][type_id@0][length@4][data@8...]
///   obj_ptr points to type_id. All existing field offsets are unchanged.
///   emit_heap_alloc prepends 4 extra bytes and returns ptr past RC field.
///
/// RC operations:
///   rc_dup(ptr):  *(ptr-4) += 1
///   rc_drop(ptr): *(ptr-4) -= 1; if rc_count == 0 → free(ptr) (no-op in prototype)
///
/// For the prototype, "free" is a no-op (bump allocator).
/// Future: free-list or arena reclamation.

///|
/// Size added to each allocation block for the RC header.
/// Layout: [alloc_size@-8][rc_count@-4][type_id@0][length@4][data@8...]
pub let rc_header_extra : Int = 8

///|
/// Emit RC initialization for a freshly allocated object.
/// Writes both the allocation size and rc_count=1.
///
/// Memory layout with RC:
///   [alloc_size@-8][rc_count@-4][type_id@0][length@4][data@8...]
///   obj_ptr points to type_id (offset 0).
///
/// Generated WASM pseudo-code:
///   local.get $obj_local / i32.const 8 / i32.sub  ; base_ptr
///   local.get $obj_local / i32.const 8 / i32.sub
///   i32.const <alloc_size> / i32.store offset=0    ; alloc_size
///   local.get $obj_local / i32.const 4 / i32.sub
///   i32.const 1 / i32.store offset=0               ; rc_count = 1
/// Emit debug counter increment: global[idx] += 1
fn emit_rc_debug_increment(buf : ByteBuf, global_idx : Int) -> Unit {
  emit_global_get(buf, global_idx)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_global_set(buf, global_idx)
}

///|
fn emit_rc_init(
  buf : ByteBuf,
  obj_local : Int,
  alloc_size : Int,
  header_size? : Int = 8,
  debug_alloc_global? : Int = -1,
) -> Unit {
  // Write alloc_size at obj_ptr - header_size (only when free-list is enabled, header=8)
  if header_size > 4 {
    emit_local_get(buf, obj_local)
    emit_i32_const_raw(buf, header_size)
    emit_i32_sub(buf)
    emit_i32_const_raw(buf, alloc_size)
    emit_i32_store(buf, 0)
  }
  // Write rc_count = 1 at obj_ptr - 4
  emit_local_get(buf, obj_local)
  emit_i32_const_raw(buf, 4)
  emit_i32_sub(buf)
  emit_i32_const_raw(buf, 1)
  emit_i32_store(buf, 0)
  // Debug mode: increment alloc counter
  if debug_alloc_global >= 0 {
    emit_rc_debug_increment(buf, debug_alloc_global)
  }
}

///|
/// Emit RC initialization with dynamic alloc_size from a local variable.
/// Used for variable-length allocations where size is computed at runtime.
fn emit_rc_init_dynamic(
  buf : ByteBuf,
  obj_local : Int,
  size_local : Int,
  header_size? : Int = 8,
  debug_alloc_global? : Int = -1,
) -> Unit {
  // Write alloc_size at obj_ptr - header_size (only when free-list enabled, header=8)
  if header_size > 4 {
    emit_local_get(buf, obj_local)
    emit_i32_const_raw(buf, header_size)
    emit_i32_sub(buf)
    emit_local_get(buf, size_local) // dynamic size
    emit_i32_store(buf, 0)
  }
  // Write rc_count = 1 at obj_ptr - 4
  emit_local_get(buf, obj_local)
  emit_i32_const_raw(buf, 4)
  emit_i32_sub(buf)
  emit_i32_const_raw(buf, 1)
  emit_i32_store(buf, 0)
  // Debug mode: increment alloc counter
  if debug_alloc_global >= 0 {
    emit_rc_debug_increment(buf, debug_alloc_global)
  }
}

///|
/// Allocate from free-list or bump allocator.
/// Scans the free-list for a block with matching alloc_size (exact-fit).
/// If found, reuse it. Otherwise, bump-allocate.
///
/// Free-list: singly-linked via obj_ptr field in the global.
/// Each freed block: [alloc_size@-8][next_ptr@-4][type_id=0@0]
/// free_list_global stores the obj_ptr of the first free block (or 0).
fn emit_rc_alloc_with_free_list(
  ctx : CodegenCtx,
  buf : ByteBuf,
  obj_size : Int,
  total_size : Int,
  obj_local : Int,
) -> Unit {
  if ctx.rc_free_list_global < 0 {
    // No free-list global — just bump allocate
    emit_heap_reserve(ctx, buf, total_size)
    emit_local_get(buf, ctx.heap_local)
    emit_i32_const_raw(buf, ctx.rc_header_size)
    emit_i32_add(buf)
    emit_local_set(buf, obj_local)
    emit_local_get(buf, ctx.heap_local)
    emit_i32_const_raw(buf, total_size)
    emit_i32_add(buf)
    emit_local_set(buf, ctx.heap_local)
    ctx.heap_synced = false
    emit_rc_init(
      buf,
      obj_local,
      total_size,
      header_size=ctx.rc_header_size,
      debug_alloc_global=ctx.rc_debug_alloc_global,
    )
    return
  }
  // Try free-list first, then fall back to bump allocation
  // Strategy: scan list for exact-size match (first-fit by total_size)
  //
  // Generated pseudo-code:
  //   prev = 0; cur = global.get $free_list
  //   block $found
  //     loop $scan
  //       br_if $found (cur == 0)  ; end of list
  //       if load(cur - 8) == total_size:
  //         ; unlink: if prev==0 { global.set(load(cur-4)) } else { store(prev-4, load(cur-4)) }
  //         obj_local = cur
  //         br $found
  //       prev = cur; cur = load(cur - 4)
  //       br $scan
  //     end
  //   end
  //   ; if cur == 0: bump allocate
  //   if obj_local == 0: bump_alloc(...)
  //   rc_init(obj_local, total_size)
  //
  // This is complex inline WASM. For the prototype, use a simpler approach:
  // Check only the HEAD of the free list for exact size match.
  let _ = obj_size
  require_heap(ctx)
  let free_ptr = alloc_temp_local(ctx)
  // free_ptr = free_list_head
  emit_global_get(buf, ctx.rc_free_list_global)
  emit_local_set(buf, free_ptr)
  // if free_ptr != 0 && load(free_ptr - header_size) == total_size
  emit_local_get(buf, free_ptr)
  emit_i32_const_raw(buf, 0)
  emit_i32_ne(buf)
  emit_if(buf) // if free_ptr != 0
  emit_local_get(buf, free_ptr)
  emit_i32_const_raw(buf, ctx.rc_header_size) // header_size
  emit_i32_sub(buf)
  emit_i32_load(buf, 0) // load alloc_size
  emit_i32_const_raw(buf, total_size)
  emit_i32_eq(buf)
  emit_if(buf) // if size matches
  // Reuse: unlink from free list (head = next_ptr)
  emit_local_get(buf, free_ptr)
  emit_i32_const_raw(buf, 4)
  emit_i32_sub(buf)
  emit_i32_load(buf, 0) // load next_ptr
  emit_global_set(buf, ctx.rc_free_list_global) // free_list_head = next
  // obj_local = free_ptr (already points past RC header)
  emit_local_get(buf, free_ptr)
  emit_local_set(buf, obj_local)
  // Re-initialize RC
  emit_rc_init(
    buf,
    obj_local,
    total_size,
    header_size=ctx.rc_header_size,
    debug_alloc_global=ctx.rc_debug_alloc_global,
  )
  emit_else(buf) // size doesn't match → bump allocate
  emit_rc_bump_alloc(ctx, buf, total_size, obj_local)
  emit_end(buf) // end inner if
  emit_else(buf) // free list empty → bump allocate
  emit_rc_bump_alloc(ctx, buf, total_size, obj_local)
  emit_end(buf) // end outer if
}

///|
/// Bump-allocate with RC header.
fn emit_rc_bump_alloc(
  ctx : CodegenCtx,
  buf : ByteBuf,
  total_size : Int,
  obj_local : Int,
) -> Unit {
  emit_heap_reserve(ctx, buf, total_size)
  emit_local_get(buf, ctx.heap_local)
  emit_i32_const_raw(buf, ctx.rc_header_size)
  emit_i32_add(buf)
  emit_local_set(buf, obj_local)
  emit_local_get(buf, ctx.heap_local)
  emit_i32_const_raw(buf, total_size)
  emit_i32_add(buf)
  emit_local_set(buf, ctx.heap_local)
  ctx.heap_synced = false
  emit_rc_init(
    buf,
    obj_local,
    total_size,
    header_size=ctx.rc_header_size,
    debug_alloc_global=ctx.rc_debug_alloc_global,
  )
}

///|
/// Emit rc_dup: increment the reference count of a heap object.
/// RC count is at obj_ptr - 4.
///
/// Generated WASM pseudo-code:
///   local.get $val
///   i32.const 3          ; tag_mask
///   i32.and
///   i32.const 1          ; tag_obj
///   i32.ne
///   br_if $skip          ; skip if not a heap object
///   local.get $val
///   i32.const -4         ; clear tag bits
///   i32.and              ; obj_ptr = val & ~3
///   i32.const 4
///   i32.sub              ; rc_ptr = obj_ptr - 4
///   local.tee $tmp
///   local.get $tmp
///   i32.load offset=0    ; load rc_count
///   i32.const 1
///   i32.add
///   i32.store offset=0   ; rc_count += 1
///   $skip:
fn emit_rc_dup(buf : ByteBuf, val_local : Int, tmp_local : Int) -> Unit {
  // Check if value is a heap object (tag == tag_obj == 1)
  emit_local_get(buf, val_local)
  emit_i32_const_raw(buf, tag_mask)
  emit_i32_and(buf)
  emit_i32_const_raw(buf, tag_obj)
  emit_i32_ne(buf)
  // if (not heap object) → skip
  emit_block(buf) // block void
  emit_br_if(buf, 0) // br_if 0 → skip to end of block
  // obj_ptr = val & ~tag_mask (clear low 2 bits)
  emit_local_get(buf, val_local)
  emit_i32_const_raw(buf, -4) // 0xFFFFFFFC: mask off low 2 bits
  emit_i32_and(buf)
  // rc_ptr = obj_ptr - 4
  emit_i32_const_raw(buf, 4)
  emit_i32_sub(buf)
  emit_local_tee(buf, tmp_local)
  // rc_count = load(rc_ptr) + 1
  emit_local_get(buf, tmp_local)
  emit_i32_load(buf, 0)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_i32_store(buf, 0)
  emit_end(buf) // end block
}

///|
/// Emit rc_drop: decrement the reference count of a heap object.
/// RC count is at obj_ptr - 4. Alloc size is at obj_ptr - 8.
/// When rc reaches 0, prepends the block to the free-list and
/// zeroes the type_id field as a tombstone marker.
///
/// Free-list structure: singly-linked via the rc_count field (offset -4).
/// Each freed block: [alloc_size@-8][next_ptr@-4][type_id=0@0]
/// The free-list head is stored in a WASM global (rc_free_list_global).
fn emit_rc_drop(
  ctx : CodegenCtx,
  buf : ByteBuf,
  val_local : Int,
  tmp_local : Int,
  new_rc_local : Int,
  recursive? : Bool = true,
) -> Unit {
  // Check if value is a heap object
  emit_local_get(buf, val_local)
  emit_i32_const_raw(buf, tag_mask)
  emit_i32_and(buf)
  emit_i32_const_raw(buf, tag_obj)
  emit_i32_ne(buf)
  // if (not heap object) → skip
  emit_block(buf)
  emit_br_if(buf, 0)
  // obj_ptr = val & ~tag_mask
  emit_local_get(buf, val_local)
  emit_i32_const_raw(buf, -4)
  emit_i32_and(buf)
  // tmp = obj_ptr (not rc_ptr — we need obj_ptr for both rc and tombstone)
  emit_local_set(buf, tmp_local)
  // new_rc = load(obj_ptr - 4) - 1
  emit_local_get(buf, tmp_local)
  emit_i32_const_raw(buf, 4)
  emit_i32_sub(buf)
  emit_local_get(buf, tmp_local)
  emit_i32_const_raw(buf, 4)
  emit_i32_sub(buf)
  emit_i32_load(buf, 0) // load rc_count
  emit_i32_const_raw(buf, 1)
  emit_i32_sub(buf)
  emit_local_tee(buf, new_rc_local)
  // store new_rc at obj_ptr - 4
  emit_i32_store(buf, 0)
  // if new_rc == 0: recursively drop fields, then free the block
  emit_local_get(buf, new_rc_local)
  emit_i32_eqz(buf)
  emit_if(buf)
  // Recursively drop fields of container types (tuple, record, array)
  if recursive {
    emit_rc_drop_fields(ctx, buf, tmp_local)
  }
  // Debug mode: increment free counter
  if ctx.rc_debug_free_global >= 0 {
    emit_rc_debug_increment(buf, ctx.rc_debug_free_global)
  }
  // Tombstone: zero out type_id
  emit_local_get(buf, tmp_local)
  emit_i32_const_raw(buf, 0)
  emit_i32_store(buf, 0) // type_id = 0
  // Prepend to free-list: block.next = free_list_head; free_list_head = obj_ptr
  if ctx.rc_free_list_global >= 0 {
    // obj_ptr - 4 (rc slot) = current free_list_head
    emit_local_get(buf, tmp_local)
    emit_i32_const_raw(buf, 4)
    emit_i32_sub(buf)
    emit_global_get(buf, ctx.rc_free_list_global)
    emit_i32_store(buf, 0) // next_ptr = old head
    // free_list_head = obj_ptr
    emit_local_get(buf, tmp_local)
    emit_global_set(buf, ctx.rc_free_list_global)
  }
  emit_end(buf) // end if
  emit_end(buf) // end block
}

///|
/// Recursively drop fields of container types (inline version).
/// Called when RC reaches 0, before tombstone/free-list.
/// obj_local holds the obj_ptr (pointing to type_id).
///
/// Tuple(3), Array(5): i32 fields at 8+idx*4
/// Record(4), Map(6): values at 8+idx*8+4 (8-byte stride, skip keys)
/// Enum(10): i32 fields at 12+idx*4
fn emit_rc_drop_fields(
  ctx : CodegenCtx,
  buf : ByteBuf,
  obj_local : Int,
) -> Unit {
  let type_id_local = alloc_temp_local(ctx)
  let len_local = alloc_temp_local(ctx)
  let idx_local = alloc_temp_local(ctx)
  let field_val_local = alloc_temp_local(ctx)
  let field_tmp_local = alloc_temp_local(ctx)
  let field_rc_local = alloc_temp_local(ctx)
  // type_id = load(obj_ptr + 0)
  emit_local_get(buf, obj_local)
  emit_i32_load(buf, 0)
  emit_local_set(buf, type_id_local)
  // --- Tuple(3) or Array(5): i32 at 8+idx*4 ---
  emit_local_get(buf, type_id_local)
  emit_i32_const_raw(buf, 3)
  emit_i32_eq(buf)
  emit_local_get(buf, type_id_local)
  emit_i32_const_raw(buf, 5)
  emit_i32_eq(buf)
  emit_i32_or(buf)
  emit_if(buf)
  emit_local_get(buf, obj_local)
  emit_i32_load(buf, 4)
  emit_local_set(buf, len_local)
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, idx_local)
  emit_block(buf)
  emit_loop(buf)
  emit_local_get(buf, idx_local)
  emit_local_get(buf, len_local)
  emit_i32_ge_s(buf)
  emit_br_if(buf, 1)
  emit_local_get(buf, obj_local)
  emit_local_get(buf, idx_local)
  emit_i32_const_raw(buf, 4)
  emit_i32_mul(buf)
  emit_i32_add(buf)
  emit_i32_load(buf, 8)
  emit_local_set(buf, field_val_local)
  emit_rc_drop(
    ctx,
    buf,
    field_val_local,
    field_tmp_local,
    field_rc_local,
    recursive=false,
  )
  emit_local_get(buf, idx_local)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, idx_local)
  emit_br(buf, 0)
  emit_end(buf) // end loop
  emit_end(buf) // end block
  emit_end(buf) // end if tuple/array
  // --- Record(4) or Map(6): values at 8+idx*8+4 ---
  emit_local_get(buf, type_id_local)
  emit_i32_const_raw(buf, 4)
  emit_i32_eq(buf)
  emit_local_get(buf, type_id_local)
  emit_i32_const_raw(buf, 6)
  emit_i32_eq(buf)
  emit_i32_or(buf)
  emit_if(buf)
  emit_local_get(buf, obj_local)
  emit_i32_load(buf, 4)
  emit_local_set(buf, len_local)
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, idx_local)
  emit_block(buf)
  emit_loop(buf)
  emit_local_get(buf, idx_local)
  emit_local_get(buf, len_local)
  emit_i32_ge_s(buf)
  emit_br_if(buf, 1)
  // value at obj_ptr + 8 + idx*8 + 4
  emit_local_get(buf, obj_local)
  emit_local_get(buf, idx_local)
  emit_i32_const_raw(buf, 8)
  emit_i32_mul(buf)
  emit_i32_add(buf)
  emit_i32_load(buf, 12) // 8 + 4
  emit_local_set(buf, field_val_local)
  emit_rc_drop(
    ctx,
    buf,
    field_val_local,
    field_tmp_local,
    field_rc_local,
    recursive=false,
  )
  emit_local_get(buf, idx_local)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, idx_local)
  emit_br(buf, 0)
  emit_end(buf) // end loop
  emit_end(buf) // end block
  emit_end(buf) // end if record/map
  // --- Enum(10): i32 at 12+idx*4 ---
  emit_local_get(buf, type_id_local)
  emit_i32_const_raw(buf, 10)
  emit_i32_eq(buf)
  emit_if(buf)
  emit_local_get(buf, obj_local)
  emit_i32_load(buf, 4)
  emit_local_set(buf, len_local)
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, idx_local)
  emit_block(buf)
  emit_loop(buf)
  emit_local_get(buf, idx_local)
  emit_local_get(buf, len_local)
  emit_i32_ge_s(buf)
  emit_br_if(buf, 1)
  emit_local_get(buf, obj_local)
  emit_local_get(buf, idx_local)
  emit_i32_const_raw(buf, 4)
  emit_i32_mul(buf)
  emit_i32_add(buf)
  emit_i32_load(buf, 12)
  emit_local_set(buf, field_val_local)
  emit_rc_drop(
    ctx,
    buf,
    field_val_local,
    field_tmp_local,
    field_rc_local,
    recursive=false,
  )
  emit_local_get(buf, idx_local)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, idx_local)
  emit_br(buf, 0)
  emit_end(buf) // end loop
  emit_end(buf) // end block
  emit_end(buf) // end if enum
  // --- View types (11, 12, 14): parent_ptr at offset 4 ---
  emit_local_get(buf, type_id_local)
  emit_i32_const_raw(buf, 11) // obj_string_view
  emit_i32_eq(buf)
  emit_local_get(buf, type_id_local)
  emit_i32_const_raw(buf, 12) // obj_array_view
  emit_i32_eq(buf)
  emit_i32_or(buf)
  emit_local_get(buf, type_id_local)
  emit_i32_const_raw(buf, 14) // obj_bytes_view
  emit_i32_eq(buf)
  emit_i32_or(buf)
  emit_if(buf)
  // parent_ptr = load_i32(obj_ptr + 4)
  emit_local_get(buf, obj_local)
  emit_i32_load(buf, 4)
  emit_local_set(buf, field_val_local)
  emit_local_get(buf, field_val_local)
  emit_i32_const_raw(buf, 0)
  emit_i32_ne(buf)
  emit_if(buf)
  // Tag raw ptr as (ptr | tag_obj) for rc_drop
  let tagged_local = alloc_temp_local(ctx)
  emit_local_get(buf, field_val_local)
  emit_i32_const_raw(buf, tag_obj)
  emit_i32_or(buf)
  emit_local_set(buf, tagged_local)
  emit_rc_drop(
    ctx,
    buf,
    tagged_local,
    field_tmp_local,
    field_rc_local,
    recursive=false,
  )
  emit_end(buf) // end if ptr != 0
  emit_end(buf) // end if view type
}

///|
/// Ensure RC temp locals are allocated for this function.
fn ensure_rc_locals(ctx : CodegenCtx) -> Unit {
  if ctx.rc_tmp_local < 0 {
    ctx.rc_tmp_local = alloc_temp_local(ctx) // i32
    ctx.rc_new_rc_local = alloc_temp_local(ctx) // i32
  }
}

///|
/// Emit RC dup for an i64 local.
/// When helper function is available, emits a call; otherwise inlines.
fn emit_rc_dup_i64(ctx : CodegenCtx, buf : ByteBuf, local_idx : Int) -> Unit {
  if ctx.rc_dup_func_idx >= 0 {
    // Call the helper function: $rc_dup(i64) -> void
    emit_local_get(buf, local_idx)
    let abs_idx = func_import_count(ctx) + ctx.rc_dup_func_idx
    emit_call(buf, abs_idx)
    return
  }
  ensure_rc_locals(ctx)
  let val32 = alloc_temp_local(ctx)
  emit_local_get(buf, local_idx)
  emit_i32_wrap_i64(buf)
  emit_local_set(buf, val32)
  emit_rc_dup(buf, val32, ctx.rc_tmp_local)
}

///|
/// Emit RC drop for an i64 local.
/// When helper function is available, emits a call; otherwise inlines.
fn emit_rc_drop_i64(ctx : CodegenCtx, buf : ByteBuf, local_idx : Int) -> Unit {
  if ctx.rc_drop_func_idx >= 0 {
    // Call the helper function: $rc_drop(i64) -> void
    emit_local_get(buf, local_idx)
    let abs_idx = func_import_count(ctx) + ctx.rc_drop_func_idx
    emit_call(buf, abs_idx)
    return
  }
  ensure_rc_locals(ctx)
  let val32 = alloc_temp_local(ctx)
  emit_local_get(buf, local_idx)
  emit_i32_wrap_i64(buf)
  emit_local_set(buf, val32)
  emit_rc_drop(ctx, buf, val32, ctx.rc_tmp_local, ctx.rc_new_rc_local)
}

///|
/// Emit all RC actions for a given stmt index (pre or post).
fn emit_rc_actions(
  ctx : CodegenCtx,
  buf : ByteBuf,
  actions : Map[String, Map[Int, Array[RcStmtAction]]],
  stmt_idx : Int,
) -> Unit {
  let prefix_map = match actions.get(ctx.rc_action_prefix) {
    Some(m) => m
    None => return
  }
  match prefix_map.get(stmt_idx) {
    Some(acts) =>
      for act in acts {
        match ctx.locals.get(act.name) {
          Some(local_idx) =>
            match act.kind {
              RcStmtActionKind::Dup => emit_rc_dup_i64(ctx, buf, local_idx)
              RcStmtActionKind::Drop => emit_rc_drop_i64(ctx, buf, local_idx)
            }
          None => () // Variable not yet in scope; skip action
        }
      }
    None => ()
  }
}

///|
/// Build RC action maps from raw action tuples (site, is_dup, name).
/// Called by the pipeline layer which converts from PerceusAction.
///
/// Returns prefix-keyed maps: Map[prefix, Map[stmt_idx, actions]].
/// prefix="" for top-level, "stmt[2].expr.body" for nested blocks, etc.
pub fn build_rc_action_maps(
  actions : Array[(String, Bool, String)],
) -> (
  Map[String, Map[Int, Array[RcStmtAction]]],
  Map[String, Map[Int, Array[RcStmtAction]]],
) {
  let pre : Map[String, Map[Int, Array[RcStmtAction]]] = {}
  let post : Map[String, Map[Int, Array[RcStmtAction]]] = {}
  for action in actions {
    let (site, is_dup, name) = action
    let kind = if is_dup {
      RcStmtActionKind::Dup
    } else {
      RcStmtActionKind::Drop
    }
    let act = RcStmtAction::{ kind, name }
    let (prefix, idx) = parse_site_path(site)
    if idx < 0 {
      continue
    }
    // old_value drops go to pre-actions (before the stmt)
    if site.contains(".old_value") {
      let map = match pre.get(prefix) {
        Some(m) => m
        None => {
          let m : Map[Int, Array[RcStmtAction]] = {}
          pre[prefix] = m
          m
        }
      }
      match map.get(idx) {
        Some(arr) => arr.push(act)
        None => map[idx] = [act]
      }
    } else {
      let map = match post.get(prefix) {
        Some(m) => m
        None => {
          let m : Map[Int, Array[RcStmtAction]] = {}
          post[prefix] = m
          m
        }
      }
      match map.get(idx) {
        Some(arr) => arr.push(act)
        None => map[idx] = [act]
      }
    }
  }
  (pre, post)
}

///|
/// Parse a site path into (prefix, leaf_stmt_index).
/// "stmt[0].after" → ("", 0)
/// "stmt[2].expr.body.stmt[1].after" → ("stmt[2].expr.body", 1)
/// "stmt[3].else.stmt[0].old_value" → ("stmt[3].else", 0)
fn parse_site_path(site : String) -> (String, Int) {
  // Find the LAST occurrence of "stmt[" in the path
  let mut last_stmt_pos = -1
  for i = site.length() - 5; i >= 0; i = i - 1 {
    if i + 4 < site.length() &&
      site[i] == 's' &&
      site[i + 1] == 't' &&
      site[i + 2] == 'm' &&
      site[i + 3] == 't' &&
      site[i + 4] == '[' {
      last_stmt_pos = i
      break
    }
  }
  if last_stmt_pos < 0 {
    return ("", -1)
  }
  // Extract prefix: everything before the last "stmt["
  // e.g., "stmt[2].expr.body.stmt[1]" → prefix = "stmt[2].expr.body"
  let prefix = if last_stmt_pos == 0 {
    ""
  } else {
    // Remove trailing '.' from prefix
    site[:last_stmt_pos - 1].to_string()
  }
  // Extract index from "stmt[N]..."
  let mut i = last_stmt_pos + 5 // skip "stmt["
  let mut result = 0
  let mut found_digit = false
  while i < site.length() {
    let c = site[i]
    if c == ']' {
      break
    }
    if c >= '0' && c <= '9' {
      result = result * 10 + (c.to_int() - '0'.to_int())
      found_digit = true
    } else {
      return (prefix, -1)
    }
    i += 1
  }
  if not(found_digit) {
    return (prefix, -1)
  }
  (prefix, result)
}

///|
/// Summary of integration points for wiring Perceus actions into codegen:
///
/// 1. After each `emit_heap_alloc`, call `emit_rc_init` to set rc=1.
///    The RC field is prepended before the object: [rc@-4][type_id@0][data@4...]
///    `emit_heap_alloc` allocates extra 4 bytes and offsets obj_ptr past RC field,
///    so all existing field offsets remain unchanged.
///
/// 2. At PerceusAction::Dup sites, emit `emit_rc_dup` on the local
///    holding the duplicated value.
///
/// 3. At PerceusAction::Drop sites, emit `emit_rc_drop` on the local
///    holding the dropped value.
///
/// 4. Mutable assignment (`Stmt::Assign`): emit rc_drop on old value
///    before storing new value.
///
/// The Perceus analysis pass (`build_perceus_plan`) provides the exact
/// sites for dup/drop insertion as `Array[PerceusAction]`.
/// Compile a standalone WASM function for rc_dup.
/// Signature: (i64) -> void
/// Truncates i64 to i32, checks tag, increments RC at obj_ptr - 4.
fn compile_rc_dup_function(heap_start? : Int = 0) -> WasmFunc {
  let body = ByteBuf::new()
  // Locals: 0=param(i64), 1=rc_ptr(i32)
  // Tag check in i64 space eliminates val32 local.
  let param = 0
  let rc_ptr = 1
  // if (param & 3L) != 1L → skip (tag check in i64 space)
  emit_local_get(body, param)
  emit_i64_const_raw(body, tag_mask.to_int64())
  emit_i64_and(body)
  emit_i64_const_raw(body, tag_obj.to_int64())
  emit_i64_ne(body)
  emit_block(body)
  emit_br_if(body, 0)
  // obj_ptr = i32.wrap(param) & ~3
  emit_local_get(body, param)
  emit_i32_wrap_i64(body)
  emit_i32_const_raw(body, -4) // 0xFFFFFFFC
  emit_i32_and(body)
  // Static data guard: skip dup for data section pointers (below heap_start)
  if heap_start > 0 {
    emit_local_tee(body, rc_ptr) // save obj_ptr, keep on stack
    emit_i32_const_raw(body, heap_start)
    emit_i32_lt_u(body)
    emit_br_if(body, 0)
    emit_local_get(body, rc_ptr)
  }
  // rc_ptr = obj_ptr - 4
  emit_i32_const_raw(body, 4)
  emit_i32_sub(body)
  emit_local_tee(body, rc_ptr)
  // *rc_ptr = *rc_ptr + 1
  emit_local_get(body, rc_ptr)
  emit_i32_load(body, 0)
  emit_i32_const_raw(body, 1)
  emit_i32_add(body)
  emit_i32_store(body, 0)
  emit_end(body) // end block
  emit_end(body) // end func
  WasmFunc::{
    params: [ValueKind::I64],
    locals: [ValueKind::I32],
    results: [],
    body: body.to_array(),
  }
}

///|
/// Compile a standalone WASM function for rc_drop.
/// Signature: (i64) -> void
/// Truncates i64 to i32, checks tag, decrements RC.
/// When RC reaches 0: recursively drops container fields, tombstones type_id,
/// and prepends to free-list.
fn compile_rc_drop_function(
  _heap_global : Int,
  free_list_global : Int,
  self_func_abs_idx : Int,
  has_tuple_or_array? : Bool = true,
  has_record_or_map? : Bool = true,
  has_closure? : Bool = true,
  has_enum? : Bool = true,
  has_view? : Bool = true,
  heap_start? : Int = 0,
  debug_free_global? : Int = -1,
) -> WasmFunc {
  let body = ByteBuf::new()
  // Locals: 0=param(i64), 1=obj_ptr, 2=new_rc,
  //         3=type_id, 4=len, 5=idx
  // Tag check in i64 space eliminates val32 local.
  let param = 0
  let obj_ptr = 1
  let new_rc = 2
  let type_id = 3
  let len = 4
  let idx = 5
  // if (param & 3L) != 1L → skip (tag check in i64 space)
  emit_local_get(body, param)
  emit_i64_const_raw(body, tag_mask.to_int64())
  emit_i64_and(body)
  emit_i64_const_raw(body, tag_obj.to_int64())
  emit_i64_ne(body)
  emit_block(body)
  emit_br_if(body, 0)
  // obj_ptr = i32.wrap(param) & ~3
  emit_local_get(body, param)
  emit_i32_wrap_i64(body)
  emit_i32_const_raw(body, -4)
  emit_i32_and(body)
  emit_local_set(body, obj_ptr)
  // Static data guard: pointers in the data section (below heap_start)
  // have no RC headers and must not be dropped.
  if heap_start > 0 {
    emit_local_get(body, obj_ptr)
    emit_i32_const_raw(body, heap_start)
    emit_i32_lt_u(body)
    emit_br_if(body, 0) // skip if in data section
  }
  // rc_ptr = obj_ptr - 4; new_rc = load(rc_ptr) - 1; store(rc_ptr, new_rc)
  emit_local_get(body, obj_ptr)
  emit_i32_const_raw(body, 4)
  emit_i32_sub(body)
  emit_local_tee(body, new_rc) // new_rc = rc_ptr temporarily
  emit_local_get(body, new_rc) // rc_ptr on stack for store
  emit_i32_load(body, 0)
  emit_i32_const_raw(body, 1)
  emit_i32_sub(body)
  emit_local_tee(body, new_rc) // new_rc = rc_count - 1
  emit_i32_store(body, 0) // store new_rc at rc_ptr
  // if new_rc == 0: recursively drop fields, tombstone, free-list
  emit_local_get(body, new_rc)
  emit_i32_eqz(body)
  emit_if(body)
  // --- Recursive drop fields via self-call (deep recursion) ---
  let needs_type_dispatch = has_tuple_or_array ||
    has_record_or_map ||
    has_closure ||
    has_enum ||
    has_view
  // Count active type categories to decide if/else vs br_table
  let type_category_count = (if has_tuple_or_array { 1 } else { 0 }) +
    (if has_record_or_map { 1 } else { 0 }) +
    (if has_closure { 1 } else { 0 }) +
    (if has_enum { 1 } else { 0 }) +
    (if has_view { 1 } else { 0 })
  if needs_type_dispatch {
    emit_local_get(body, obj_ptr)
    emit_i32_load(body, 0)
    emit_local_set(body, type_id)
  }
  // Use br_table for type dispatch when 3+ categories are active.
  // Type IDs: 3=tuple, 4=record, 5=array, 6=map, 7=closure,
  //           10=enum, 11=string_view, 12=array_view, 14=bytes_view
  // br_table with range 3..14 (12 entries) dispatches in O(1).
  if type_category_count >= 3 {
    // br_table dispatch: subtract 3 from type_id (min relevant id),
    // then index into jump table of 12 entries (ids 3-14).
    //
    // Block nesting (outermost = highest label):
    //   block $done (label = N)
    //     block $view (label = N-1)
    //       block $enum (label = N-2)
    //         block $closure (label = N-3)
    //           block $record_map (label = N-4)
    //             block $tuple_array (label = N-5)
    //               br_table [...]
    //             end $tuple_array
    //             ... tuple/array code, br $done ...
    //           end $record_map
    //           ... record/map code, br $done ...
    //         end $closure
    //         ... closure code, br $done ...
    //       end $enum
    //       ... enum code, br $done ...
    //     end $view
    //     ... view code, br $done ...
    //   end $done
    //
    // Label indices (relative to br_table):
    //   0 = $tuple_array, 1 = $record_map, 2 = $closure,
    //   3 = $enum, 4 = $view, 5 = $done (default/skip)
    let lbl_tuple_array = 0
    let lbl_record_map = 1
    let lbl_closure = 2
    let lbl_enum = 3
    let lbl_view = 4
    let lbl_done = 5
    // Open blocks: $done, $view, $enum, $closure, $record_map, $tuple_array
    emit_block(body) // $done
    emit_block(body) // $view
    emit_block(body) // $enum
    emit_block(body) // $closure
    emit_block(body) // $record_map
    emit_block(body) // $tuple_array
    // br_table index = type_id - 3
    emit_local_get(body, type_id)
    emit_i32_const_raw(body, 3)
    emit_i32_sub(body)
    // Table for type_ids 3..14 (indices 0..11):
    // 0(3)=tuple, 1(4)=record, 2(5)=array, 3(6)=map, 4(7)=closure,
    // 5(8)=done, 6(9)=done, 7(10)=enum, 8(11)=view, 9(12)=view,
    // 10(13)=done, 11(14)=view
    let table : Array[Int] = [
      lbl_tuple_array, // 3: tuple
       lbl_record_map, // 4: record
       lbl_tuple_array, // 5: array
       lbl_record_map, // 6: map
       lbl_closure, // 7: closure
       lbl_done, // 8: unused
       lbl_done, // 9: unused
       lbl_enum, // 10: enum
       lbl_view, // 11: string_view
       lbl_view, // 12: array_view
       lbl_done, // 13: unused
       lbl_view, // 14: bytes_view
    ]
    emit_br_table(body, table, lbl_done) // default → $done
    emit_end(body) // end $tuple_array
    // --- Tuple(3)/Array(5): i32 fields at 8+idx*4 ---
    if has_tuple_or_array {
      emit_local_get(body, obj_ptr)
      emit_i32_load(body, 4)
      emit_local_set(body, len)
      emit_i32_const_raw(body, 0)
      emit_local_set(body, idx)
      emit_block(body) // block $break
      emit_loop(body) // loop $continue
      emit_local_get(body, idx)
      emit_local_get(body, len)
      emit_i32_ge_s(body)
      emit_br_if(body, 1) // br $break
      emit_local_get(body, obj_ptr)
      emit_local_get(body, idx)
      emit_i32_const_raw(body, 4)
      emit_i32_mul(body)
      emit_i32_add(body)
      emit_i32_load(body, 8)
      emit_i64_extend_i32_u(body)
      emit_call(body, self_func_abs_idx)
      emit_local_get(body, idx)
      emit_i32_const_raw(body, 1)
      emit_i32_add(body)
      emit_local_set(body, idx)
      emit_br(body, 0) // br $continue
      emit_end(body) // end loop
      emit_end(body) // end block $break
    }
    emit_br(body, lbl_done - lbl_tuple_array - 1) // br $done (adjusted for consumed blocks)
    emit_end(body) // end $record_map
    // --- Record(4)/Map(6): values at 8+idx*8+4 ---
    if has_record_or_map {
      emit_local_get(body, obj_ptr)
      emit_i32_load(body, 4)
      emit_local_set(body, len)
      emit_i32_const_raw(body, 0)
      emit_local_set(body, idx)
      emit_block(body) // block $break
      emit_loop(body) // loop $continue
      emit_local_get(body, idx)
      emit_local_get(body, len)
      emit_i32_ge_s(body)
      emit_br_if(body, 1) // br $break
      emit_local_get(body, obj_ptr)
      emit_local_get(body, idx)
      emit_i32_const_raw(body, 8)
      emit_i32_mul(body)
      emit_i32_add(body)
      emit_i32_load(body, 12)
      emit_i64_extend_i32_u(body)
      emit_call(body, self_func_abs_idx)
      emit_local_get(body, idx)
      emit_i32_const_raw(body, 1)
      emit_i32_add(body)
      emit_local_set(body, idx)
      emit_br(body, 0) // br $continue
      emit_end(body) // end loop
      emit_end(body) // end block $break
    }
    emit_br(body, lbl_done - lbl_record_map - 1) // br $done
    emit_end(body) // end $closure
    // --- Closure(7): i64 at 16+idx*8 ---
    if has_closure {
      emit_local_get(body, obj_ptr)
      emit_i32_load(body, 4)
      emit_local_set(body, len)
      emit_i32_const_raw(body, 0)
      emit_local_set(body, idx)
      emit_block(body) // block $break
      emit_loop(body) // loop $continue
      emit_local_get(body, idx)
      emit_local_get(body, len)
      emit_i32_ge_s(body)
      emit_br_if(body, 1) // br $break
      emit_local_get(body, obj_ptr)
      emit_local_get(body, idx)
      emit_i32_const_raw(body, 8)
      emit_i32_mul(body)
      emit_i32_add(body)
      emit_i64_load(body, 16)
      emit_call(body, self_func_abs_idx)
      emit_local_get(body, idx)
      emit_i32_const_raw(body, 1)
      emit_i32_add(body)
      emit_local_set(body, idx)
      emit_br(body, 0) // br $continue
      emit_end(body) // end loop
      emit_end(body) // end block $break
    }
    emit_br(body, lbl_done - lbl_closure - 1) // br $done
    emit_end(body) // end $enum
    // --- Enum(10): i32 at 12+idx*4 ---
    if has_enum {
      emit_local_get(body, obj_ptr)
      emit_i32_load(body, 4)
      emit_local_set(body, len)
      emit_i32_const_raw(body, 0)
      emit_local_set(body, idx)
      emit_block(body) // block $break
      emit_loop(body) // loop $continue
      emit_local_get(body, idx)
      emit_local_get(body, len)
      emit_i32_ge_s(body)
      emit_br_if(body, 1) // br $break
      emit_local_get(body, obj_ptr)
      emit_local_get(body, idx)
      emit_i32_const_raw(body, 4)
      emit_i32_mul(body)
      emit_i32_add(body)
      emit_i32_load(body, 12)
      emit_i64_extend_i32_u(body)
      emit_call(body, self_func_abs_idx)
      emit_local_get(body, idx)
      emit_i32_const_raw(body, 1)
      emit_i32_add(body)
      emit_local_set(body, idx)
      emit_br(body, 0) // br $continue
      emit_end(body) // end loop
      emit_end(body) // end block $break
    }
    emit_br(body, lbl_done - lbl_enum - 1) // br $done
    emit_end(body) // end $view
    // --- View types (11, 12, 14): parent_ptr at offset 4 ---
    if has_view {
      emit_local_get(body, obj_ptr)
      emit_i32_load(body, 4) // source_ptr
      emit_i32_const_raw(body, 0)
      emit_i32_ne(body)
      emit_if(body)
      emit_local_get(body, obj_ptr)
      emit_i32_load(body, 4) // reload source_ptr
      emit_i64_extend_i32_u(body)
      emit_i64_const_raw(body, tag_obj.to_int64())
      emit_i64_or(body)
      emit_call(body, self_func_abs_idx)
      emit_end(body) // end if ptr != 0
    }
    // br $done not needed — falls through to end
    emit_end(body) // end $done
  } else {
    // Few type categories: use sequential if/else (smaller for 1-2 types)
    if has_tuple_or_array {
      emit_local_get(body, type_id)
      emit_i32_const_raw(body, 3)
      emit_i32_eq(body)
      emit_local_get(body, type_id)
      emit_i32_const_raw(body, 5)
      emit_i32_eq(body)
      emit_i32_or(body)
      emit_if(body) // if tuple or array
      emit_local_get(body, obj_ptr)
      emit_i32_load(body, 4)
      emit_local_set(body, len)
      emit_i32_const_raw(body, 0)
      emit_local_set(body, idx)
      emit_block(body) // block $break
      emit_loop(body) // loop $continue
      emit_local_get(body, idx)
      emit_local_get(body, len)
      emit_i32_ge_s(body)
      emit_br_if(body, 1) // br $break
      emit_local_get(body, obj_ptr)
      emit_local_get(body, idx)
      emit_i32_const_raw(body, 4)
      emit_i32_mul(body)
      emit_i32_add(body)
      emit_i32_load(body, 8)
      emit_i64_extend_i32_u(body)
      emit_call(body, self_func_abs_idx)
      emit_local_get(body, idx)
      emit_i32_const_raw(body, 1)
      emit_i32_add(body)
      emit_local_set(body, idx)
      emit_br(body, 0) // br $continue
      emit_end(body) // end loop
      emit_end(body) // end block $break
      emit_end(body) // end if tuple or array
    }
    if has_record_or_map {
      emit_local_get(body, type_id)
      emit_i32_const_raw(body, 4) // obj_record
      emit_i32_eq(body)
      emit_local_get(body, type_id)
      emit_i32_const_raw(body, 6) // obj_map
      emit_i32_eq(body)
      emit_i32_or(body)
      emit_if(body) // if record or map
      emit_local_get(body, obj_ptr)
      emit_i32_load(body, 4)
      emit_local_set(body, len)
      emit_i32_const_raw(body, 0)
      emit_local_set(body, idx)
      emit_block(body) // block $break
      emit_loop(body) // loop $continue
      emit_local_get(body, idx)
      emit_local_get(body, len)
      emit_i32_ge_s(body)
      emit_br_if(body, 1) // br $break
      emit_local_get(body, obj_ptr)
      emit_local_get(body, idx)
      emit_i32_const_raw(body, 8)
      emit_i32_mul(body)
      emit_i32_add(body)
      emit_i32_load(body, 12)
      emit_i64_extend_i32_u(body)
      emit_call(body, self_func_abs_idx)
      emit_local_get(body, idx)
      emit_i32_const_raw(body, 1)
      emit_i32_add(body)
      emit_local_set(body, idx)
      emit_br(body, 0) // br $continue
      emit_end(body) // end loop
      emit_end(body) // end block $break
      emit_end(body) // end if record or map
    }
    if has_closure {
      emit_local_get(body, type_id)
      emit_i32_const_raw(body, 7) // obj_fn
      emit_i32_eq(body)
      emit_if(body) // if type_id == 7
      emit_local_get(body, obj_ptr)
      emit_i32_load(body, 4)
      emit_local_set(body, len)
      emit_i32_const_raw(body, 0)
      emit_local_set(body, idx)
      emit_block(body) // block $break
      emit_loop(body) // loop $continue
      emit_local_get(body, idx)
      emit_local_get(body, len)
      emit_i32_ge_s(body)
      emit_br_if(body, 1) // br $break
      emit_local_get(body, obj_ptr)
      emit_local_get(body, idx)
      emit_i32_const_raw(body, 8)
      emit_i32_mul(body)
      emit_i32_add(body)
      emit_i64_load(body, 16)
      emit_call(body, self_func_abs_idx)
      emit_local_get(body, idx)
      emit_i32_const_raw(body, 1)
      emit_i32_add(body)
      emit_local_set(body, idx)
      emit_br(body, 0) // br $continue
      emit_end(body) // end loop
      emit_end(body) // end block $break
      emit_end(body) // end if type_id == 7
    }
    if has_enum {
      emit_local_get(body, type_id)
      emit_i32_const_raw(body, 10) // obj_enum
      emit_i32_eq(body)
      emit_if(body) // if type_id == 10
      emit_local_get(body, obj_ptr)
      emit_i32_load(body, 4)
      emit_local_set(body, len)
      emit_i32_const_raw(body, 0)
      emit_local_set(body, idx)
      emit_block(body) // block $break
      emit_loop(body) // loop $continue
      emit_local_get(body, idx)
      emit_local_get(body, len)
      emit_i32_ge_s(body)
      emit_br_if(body, 1) // br $break
      emit_local_get(body, obj_ptr)
      emit_local_get(body, idx)
      emit_i32_const_raw(body, 4)
      emit_i32_mul(body)
      emit_i32_add(body)
      emit_i32_load(body, 12)
      emit_i64_extend_i32_u(body)
      emit_call(body, self_func_abs_idx)
      emit_local_get(body, idx)
      emit_i32_const_raw(body, 1)
      emit_i32_add(body)
      emit_local_set(body, idx)
      emit_br(body, 0) // br $continue
      emit_end(body) // end loop
      emit_end(body) // end block $break
      emit_end(body) // end if type_id == 10
    }
    if has_view {
      emit_local_get(body, type_id)
      emit_i32_const_raw(body, 11) // obj_string_view
      emit_i32_eq(body)
      emit_local_get(body, type_id)
      emit_i32_const_raw(body, 12) // obj_array_view
      emit_i32_eq(body)
      emit_i32_or(body)
      emit_local_get(body, type_id)
      emit_i32_const_raw(body, 14) // obj_bytes_view
      emit_i32_eq(body)
      emit_i32_or(body)
      emit_if(body) // if view type
      emit_local_get(body, obj_ptr)
      emit_i32_load(body, 4) // source_ptr
      emit_i32_const_raw(body, 0)
      emit_i32_ne(body)
      emit_if(body)
      emit_local_get(body, obj_ptr)
      emit_i32_load(body, 4) // reload source_ptr
      emit_i64_extend_i32_u(body)
      emit_i64_const_raw(body, tag_obj.to_int64())
      emit_i64_or(body)
      emit_call(body, self_func_abs_idx)
      emit_end(body) // end if ptr != 0
      emit_end(body) // end if view type
    }
  }
  // --- End recursive drop fields ---
  // Debug mode: increment free counter
  if debug_free_global >= 0 {
    emit_rc_debug_increment(body, debug_free_global)
  }
  // Tombstone: type_id = 0
  emit_local_get(body, obj_ptr)
  emit_i32_const_raw(body, 0)
  emit_i32_store(body, 0)
  // Free-list: next = head; head = obj_ptr
  if free_list_global >= 0 {
    emit_local_get(body, obj_ptr)
    emit_i32_const_raw(body, 4)
    emit_i32_sub(body)
    emit_global_get(body, free_list_global)
    emit_i32_store(body, 0)
    emit_local_get(body, obj_ptr)
    emit_global_set(body, free_list_global)
  }
  emit_end(body) // end if new_rc == 0
  emit_end(body) // end block (tag check skip)
  emit_end(body) // end func
  // Only declare locals that are actually used
  let locals : Array[ValueKind] = [
    ValueKind::I32, // obj_ptr
    ValueKind::I32, // new_rc
  ]
  if needs_type_dispatch {
    locals.push(ValueKind::I32) // type_id
    locals.push(ValueKind::I32) // len
    locals.push(ValueKind::I32) // idx
  }
  WasmFunc::{
    params: [ValueKind::I64],
    locals,
    results: [],
    body: body.to_array(),
  }
}

///|
/// Compile a standalone WASM function for rc_alloc.
/// Signature: (i32 total_size) -> i32 obj_ptr
/// Checks free-list head for exact-size match, otherwise bump-allocates.
/// Writes alloc_size and rc_count=1 to the RC header.
fn compile_rc_alloc_function(
  heap_global : Int,
  free_list_global : Int,
  header_size? : Int = 8,
  debug_alloc_global? : Int = -1,
) -> WasmFunc {
  let body = ByteBuf::new()
  // Locals: 0=total_size(param), 1=obj_ptr, 2=new_heap
  let total_size = 0
  let obj_ptr = 1
  let new_heap = 2
  // block $allocated — both paths set obj_ptr, then br here
  emit_block(body)
  if free_list_global >= 0 {
    // Head-only free-list check: if head != 0 && load(head-8) == total_size → reuse
    emit_global_get(body, free_list_global)
    emit_i32_const_raw(body, 0)
    emit_i32_ne(body)
    emit_if(body) // if head != 0
    emit_global_get(body, free_list_global)
    emit_i32_const_raw(body, 8)
    emit_i32_sub(body)
    emit_i32_load(body, 0) // load alloc_size
    emit_local_get(body, total_size)
    emit_i32_eq(body)
    emit_if(body) // if size matches
    // Reuse: obj_ptr = head; head = load(head - 4)
    emit_global_get(body, free_list_global)
    emit_local_set(body, obj_ptr)
    emit_local_get(body, obj_ptr)
    emit_i32_const_raw(body, 4)
    emit_i32_sub(body)
    emit_i32_load(body, 0)
    emit_global_set(body, free_list_global) // head = next
    // Write rc_count = 1
    emit_local_get(body, obj_ptr)
    emit_i32_const_raw(body, 4)
    emit_i32_sub(body)
    emit_i32_const_raw(body, 1)
    emit_i32_store(body, 0)
    emit_br(body, 2) // br $allocated
    emit_end(body) // end inner if (size match)
    emit_end(body) // end outer if (head != 0)
  }
  // Bump allocate: new_heap = heap + total_size
  emit_global_get(body, heap_global)
  emit_local_get(body, total_size)
  emit_i32_add(body)
  emit_local_set(body, new_heap)
  // Check memory.grow: if memory_size_bytes < new_heap → grow
  emit_memory_size(body)
  emit_i32_const_raw(body, 16)
  emit_i32_shl(body) // pages → bytes
  emit_local_get(body, new_heap)
  emit_i32_lt_s(body) // mem_bytes < new_heap
  emit_if(body)
  emit_i32_const_raw(body, 1)
  emit_memory_grow(body)
  emit_drop(body)
  emit_end(body)
  // obj_ptr = old_heap + header_size
  emit_global_get(body, heap_global)
  emit_i32_const_raw(body, header_size)
  emit_i32_add(body)
  emit_local_set(body, obj_ptr)
  // heap = new_heap
  emit_local_get(body, new_heap)
  emit_global_set(body, heap_global)
  // Write alloc_size at obj_ptr - header_size (only when free-list is enabled)
  if free_list_global >= 0 {
    emit_local_get(body, obj_ptr)
    emit_i32_const_raw(body, header_size)
    emit_i32_sub(body)
    emit_local_get(body, total_size)
    emit_i32_store(body, 0)
  }
  // Write rc_count = 1 at obj_ptr - 4
  emit_local_get(body, obj_ptr)
  emit_i32_const_raw(body, 4)
  emit_i32_sub(body)
  emit_i32_const_raw(body, 1)
  emit_i32_store(body, 0)
  emit_end(body) // end block $allocated
  // Debug mode: increment alloc counter
  if debug_alloc_global >= 0 {
    emit_rc_debug_increment(body, debug_alloc_global)
  }
  // Return obj_ptr
  emit_local_get(body, obj_ptr)
  emit_end(body) // end func
  WasmFunc::{
    params: [ValueKind::I32],
    locals: [ValueKind::I32, ValueKind::I32],
    results: [ValueKind::I32],
    body: body.to_array(),
  }
}

///|
/// Compile a standalone WASM function for rc_try_reuse.
/// Signature: (i64 val) -> i32 obj_ptr_or_0
/// If val is a heap object with RC==1, recursively drops children,
/// keeps RC at 1, and returns obj_ptr for in-place reuse.
/// Otherwise, does a normal rc_drop and returns 0.
fn compile_rc_try_reuse_function(
  rc_drop_abs_idx : Int,
  has_tuple_or_array? : Bool = true,
  has_record_or_map? : Bool = true,
  has_closure? : Bool = true,
  has_enum? : Bool = true,
  has_view? : Bool = true,
  heap_start? : Int = 0,
) -> WasmFunc {
  let body = ByteBuf::new()
  // Locals: 0=param(i64), 1=val32, 2=obj_ptr, 3=rc_count,
  //         4=type_id, 5=len, 6=idx
  let param = 0
  let val32 = 1
  let obj_ptr = 2
  let rc_count = 3
  let type_id = 4
  let len = 5
  let idx = 6
  // val32 = i32.wrap_i64(param)
  emit_local_get(body, param)
  emit_i32_wrap_i64(body)
  emit_local_set(body, val32)
  // block $done (result i32)
  emit_block_result_i32(body)
  // if (val32 & tag_mask) != tag_obj → drop, return 0
  emit_local_get(body, val32)
  emit_i32_const_raw(body, tag_mask)
  emit_i32_and(body)
  emit_i32_const_raw(body, tag_obj)
  emit_i32_ne(body)
  emit_if(body)
  // Not a heap object: call $rc_drop, return 0
  emit_local_get(body, param)
  emit_call(body, rc_drop_abs_idx)
  emit_i32_const_raw(body, 0)
  emit_br(body, 1) // br $done
  emit_end(body) // end if
  // obj_ptr = val32 & ~3
  emit_local_get(body, val32)
  emit_i32_const_raw(body, -4)
  emit_i32_and(body)
  emit_local_set(body, obj_ptr)
  // Static data guard: data section pointers can't be reused, return 0
  if heap_start > 0 {
    emit_local_get(body, obj_ptr)
    emit_i32_const_raw(body, heap_start)
    emit_i32_lt_u(body)
    emit_if(body)
    emit_i32_const_raw(body, 0)
    emit_br(body, 1) // br $done
    emit_end(body)
  }
  // rc_count = load(obj_ptr - 4)
  emit_local_get(body, obj_ptr)
  emit_i32_const_raw(body, 4)
  emit_i32_sub(body)
  emit_i32_load(body, 0)
  emit_local_set(body, rc_count)
  // if rc_count != 1 → normal drop, return 0
  emit_local_get(body, rc_count)
  emit_i32_const_raw(body, 1)
  emit_i32_ne(body)
  emit_if(body)
  emit_local_get(body, param)
  emit_call(body, rc_drop_abs_idx)
  emit_i32_const_raw(body, 0)
  emit_br(body, 1) // br $done
  emit_end(body) // end if
  // RC==1: reuse! Recursively drop children first.
  let needs_type_dispatch = has_tuple_or_array ||
    has_record_or_map ||
    has_closure ||
    has_enum ||
    has_view
  if needs_type_dispatch {
    emit_local_get(body, obj_ptr)
    emit_i32_load(body, 0)
    emit_local_set(body, type_id)
  }
  if has_tuple_or_array {
    emit_local_get(body, type_id)
    emit_i32_const_raw(body, 3)
    emit_i32_eq(body)
    emit_local_get(body, type_id)
    emit_i32_const_raw(body, 5)
    emit_i32_eq(body)
    emit_i32_or(body)
    emit_if(body)
    emit_local_get(body, obj_ptr)
    emit_i32_load(body, 4)
    emit_local_set(body, len)
    emit_i32_const_raw(body, 0)
    emit_local_set(body, idx)
    emit_block(body)
    emit_loop(body)
    emit_local_get(body, idx)
    emit_local_get(body, len)
    emit_i32_ge_s(body)
    emit_br_if(body, 1)
    emit_local_get(body, obj_ptr)
    emit_local_get(body, idx)
    emit_i32_const_raw(body, 4)
    emit_i32_mul(body)
    emit_i32_add(body)
    emit_i32_load(body, 8)
    emit_i64_extend_i32_u(body)
    emit_call(body, rc_drop_abs_idx)
    emit_local_get(body, idx)
    emit_i32_const_raw(body, 1)
    emit_i32_add(body)
    emit_local_set(body, idx)
    emit_br(body, 0)
    emit_end(body) // end loop
    emit_end(body) // end block
    emit_end(body) // end if tuple/array
  }
  if has_record_or_map {
    emit_local_get(body, type_id)
    emit_i32_const_raw(body, 4)
    emit_i32_eq(body)
    emit_local_get(body, type_id)
    emit_i32_const_raw(body, 6)
    emit_i32_eq(body)
    emit_i32_or(body)
    emit_if(body)
    emit_local_get(body, obj_ptr)
    emit_i32_load(body, 4)
    emit_local_set(body, len)
    emit_i32_const_raw(body, 0)
    emit_local_set(body, idx)
    emit_block(body)
    emit_loop(body)
    emit_local_get(body, idx)
    emit_local_get(body, len)
    emit_i32_ge_s(body)
    emit_br_if(body, 1)
    emit_local_get(body, obj_ptr)
    emit_local_get(body, idx)
    emit_i32_const_raw(body, 8)
    emit_i32_mul(body)
    emit_i32_add(body)
    emit_i32_load(body, 12)
    emit_i64_extend_i32_u(body)
    emit_call(body, rc_drop_abs_idx)
    emit_local_get(body, idx)
    emit_i32_const_raw(body, 1)
    emit_i32_add(body)
    emit_local_set(body, idx)
    emit_br(body, 0)
    emit_end(body) // end loop
    emit_end(body) // end block
    emit_end(body) // end if record/map
  }
  if has_closure {
    emit_local_get(body, type_id)
    emit_i32_const_raw(body, 7)
    emit_i32_eq(body)
    emit_if(body)
    emit_local_get(body, obj_ptr)
    emit_i32_load(body, 4)
    emit_local_set(body, len)
    emit_i32_const_raw(body, 0)
    emit_local_set(body, idx)
    emit_block(body)
    emit_loop(body)
    emit_local_get(body, idx)
    emit_local_get(body, len)
    emit_i32_ge_s(body)
    emit_br_if(body, 1)
    emit_local_get(body, obj_ptr)
    emit_local_get(body, idx)
    emit_i32_const_raw(body, 8)
    emit_i32_mul(body)
    emit_i32_add(body)
    emit_i64_load(body, 16)
    emit_call(body, rc_drop_abs_idx)
    emit_local_get(body, idx)
    emit_i32_const_raw(body, 1)
    emit_i32_add(body)
    emit_local_set(body, idx)
    emit_br(body, 0)
    emit_end(body) // end loop
    emit_end(body) // end block
    emit_end(body) // end if closure
  }
  if has_enum {
    emit_local_get(body, type_id)
    emit_i32_const_raw(body, 10)
    emit_i32_eq(body)
    emit_if(body)
    emit_local_get(body, obj_ptr)
    emit_i32_load(body, 4)
    emit_local_set(body, len)
    emit_i32_const_raw(body, 0)
    emit_local_set(body, idx)
    emit_block(body)
    emit_loop(body)
    emit_local_get(body, idx)
    emit_local_get(body, len)
    emit_i32_ge_s(body)
    emit_br_if(body, 1)
    emit_local_get(body, obj_ptr)
    emit_local_get(body, idx)
    emit_i32_const_raw(body, 4)
    emit_i32_mul(body)
    emit_i32_add(body)
    emit_i32_load(body, 12)
    emit_i64_extend_i32_u(body)
    emit_call(body, rc_drop_abs_idx)
    emit_local_get(body, idx)
    emit_i32_const_raw(body, 1)
    emit_i32_add(body)
    emit_local_set(body, idx)
    emit_br(body, 0)
    emit_end(body) // end loop
    emit_end(body) // end block
    emit_end(body) // end if enum
  }
  if has_view {
    emit_local_get(body, type_id)
    emit_i32_const_raw(body, 11)
    emit_i32_eq(body)
    emit_local_get(body, type_id)
    emit_i32_const_raw(body, 12)
    emit_i32_eq(body)
    emit_i32_or(body)
    emit_local_get(body, type_id)
    emit_i32_const_raw(body, 14)
    emit_i32_eq(body)
    emit_i32_or(body)
    emit_if(body) // if view type
    emit_local_get(body, obj_ptr)
    emit_i32_load(body, 4) // source_ptr
    emit_i32_const_raw(body, 0)
    emit_i32_ne(body)
    emit_if(body)
    emit_local_get(body, obj_ptr)
    emit_i32_load(body, 4) // reload source_ptr
    emit_i64_extend_i32_u(body)
    emit_i64_const_raw(body, tag_obj.to_int64())
    emit_i64_or(body)
    emit_call(body, rc_drop_abs_idx)
    emit_end(body) // end if ptr != 0
    emit_end(body) // end if view type
  }
  // Return obj_ptr (RC is already 1, ready for reuse)
  emit_local_get(body, obj_ptr)
  emit_end(body) // end block $done
  emit_end(body) // end func
  WasmFunc::{
    params: [ValueKind::I64],
    locals: [
      ValueKind::I32,
      ValueKind::I32,
      ValueKind::I32,
      ValueKind::I32,
      ValueKind::I32,
      ValueKind::I32,
    ],
    results: [ValueKind::I32],
    body: body.to_array(),
  }
}

///|
pub fn perceus_codegen_integration_notes() -> String {
  let notes = [
    "1. emit_rc_init after emit_heap_alloc (rc at ptr-4, offsets unchanged)", "2. emit_rc_dup at PerceusAction::Dup sites",
    "3. emit_rc_drop at PerceusAction::Drop sites", "4. Assign: rc_drop(old) before store",
  ]
  let mut result = ""
  for note in notes {
    result = result + note + "\n"
  }
  result
}
