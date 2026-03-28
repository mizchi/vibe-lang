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
fn emit_rc_init(buf : ByteBuf, obj_local : Int, alloc_size : Int) -> Unit {
  // Write alloc_size at obj_ptr - 8
  emit_local_get(buf, obj_local)
  emit_i32_const_raw(buf, rc_header_extra)
  emit_i32_sub(buf)
  emit_i32_const_raw(buf, alloc_size)
  emit_i32_store(buf, 0)
  // Write rc_count = 1 at obj_ptr - 4
  emit_local_get(buf, obj_local)
  emit_i32_const_raw(buf, 4)
  emit_i32_sub(buf)
  emit_i32_const_raw(buf, 1)
  emit_i32_store(buf, 0)
}

///|
/// Emit RC initialization with dynamic alloc_size from a local variable.
/// Used for variable-length allocations where size is computed at runtime.
fn emit_rc_init_dynamic(
  buf : ByteBuf,
  obj_local : Int,
  size_local : Int,
) -> Unit {
  // Write alloc_size at obj_ptr - 8
  emit_local_get(buf, obj_local)
  emit_i32_const_raw(buf, rc_header_extra)
  emit_i32_sub(buf)
  emit_local_get(buf, size_local) // dynamic size
  emit_i32_store(buf, 0)
  // Write rc_count = 1 at obj_ptr - 4
  emit_local_get(buf, obj_local)
  emit_i32_const_raw(buf, 4)
  emit_i32_sub(buf)
  emit_i32_const_raw(buf, 1)
  emit_i32_store(buf, 0)
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
    emit_i32_const_raw(buf, rc_header_extra)
    emit_i32_add(buf)
    emit_local_set(buf, obj_local)
    emit_local_get(buf, ctx.heap_local)
    emit_i32_const_raw(buf, total_size)
    emit_i32_add(buf)
    emit_local_set(buf, ctx.heap_local)
    ctx.heap_synced = false
    emit_rc_init(buf, obj_local, total_size)
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
  // if free_ptr != 0 && load(free_ptr - 8) == total_size
  emit_local_get(buf, free_ptr)
  emit_i32_const_raw(buf, 0)
  emit_i32_ne(buf)
  emit_if(buf) // if free_ptr != 0
  emit_local_get(buf, free_ptr)
  emit_i32_const_raw(buf, 8) // rc_header_extra
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
  emit_rc_init(buf, obj_local, total_size)
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
  emit_i32_const_raw(buf, rc_header_extra)
  emit_i32_add(buf)
  emit_local_set(buf, obj_local)
  emit_local_get(buf, ctx.heap_local)
  emit_i32_const_raw(buf, total_size)
  emit_i32_add(buf)
  emit_local_set(buf, ctx.heap_local)
  ctx.heap_synced = false
  emit_rc_init(buf, obj_local, total_size)
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
  emit_i32_const_raw(buf, rc_header_extra)
  emit_i32_sub(buf)
  emit_local_set(buf, tmp_local)
  // rc_count = load(rc_ptr) + 1
  emit_local_get(buf, tmp_local)
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
  emit_rc_drop(ctx, buf, field_val_local, field_tmp_local, field_rc_local, recursive=false)
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
  emit_rc_drop(ctx, buf, field_val_local, field_tmp_local, field_rc_local, recursive=false)
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
  emit_rc_drop(ctx, buf, field_val_local, field_tmp_local, field_rc_local, recursive=false)
  emit_local_get(buf, idx_local)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, idx_local)
  emit_br(buf, 0)
  emit_end(buf) // end loop
  emit_end(buf) // end block
  emit_end(buf) // end if enum
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
/// Parse "stmt[N]..." to extract N as Int. Returns -1 on failure.
/// Legacy: only extracts the first (outermost) stmt index.
fn parse_stmt_index(site : String) -> Int {
  let (_, idx) = parse_site_path(site)
  idx
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
fn compile_rc_dup_function() -> WasmFunc {
  let body = ByteBuf::new()
  // Locals: 0=param(i64), 1=val32(i32), 2=rc_ptr(i32)
  let param = 0
  let val32 = 1
  let rc_ptr = 2
  // val32 = i32.wrap_i64(param)
  emit_local_get(body, param)
  emit_i32_wrap_i64(body)
  emit_local_set(body, val32)
  // if (val32 & tag_mask) != tag_obj → return
  emit_local_get(body, val32)
  emit_i32_const_raw(body, tag_mask)
  emit_i32_and(body)
  emit_i32_const_raw(body, tag_obj)
  emit_i32_ne(body)
  emit_block(body)
  emit_br_if(body, 0)
  // obj_ptr = val32 & ~3
  emit_local_get(body, val32)
  emit_i32_const_raw(body, -4) // 0xFFFFFFFC
  emit_i32_and(body)
  // rc_ptr = obj_ptr - 4  (but we use -8 since rc_header_extra=8, rc is at -4 from obj)
  emit_i32_const_raw(body, 4)
  emit_i32_sub(body)
  emit_local_set(body, rc_ptr)
  // *rc_ptr = *rc_ptr + 1
  emit_local_get(body, rc_ptr)
  emit_local_get(body, rc_ptr)
  emit_i32_load(body, 0)
  emit_i32_const_raw(body, 1)
  emit_i32_add(body)
  emit_i32_store(body, 0)
  emit_end(body) // end block
  emit_end(body) // end func
  WasmFunc::{
    params: [ValueKind::I64],
    locals: [ValueKind::I32, ValueKind::I32],
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
) -> WasmFunc {
  let body = ByteBuf::new()
  // Locals: 0=param(i64), 1=val32, 2=obj_ptr, 3=new_rc,
  //         4=type_id, 5=len, 6=idx, 7=field_val, 8=field_i64
  let param = 0
  let val32 = 1
  let obj_ptr = 2
  let new_rc = 3
  let type_id = 4
  let len = 5
  let idx = 6
  let field_val = 7
  let field_i64 = 8
  // val32 = i32.wrap_i64(param)
  emit_local_get(body, param)
  emit_i32_wrap_i64(body)
  emit_local_set(body, val32)
  // if (val32 & tag_mask) != tag_obj → skip
  emit_local_get(body, val32)
  emit_i32_const_raw(body, tag_mask)
  emit_i32_and(body)
  emit_i32_const_raw(body, tag_obj)
  emit_i32_ne(body)
  emit_block(body)
  emit_br_if(body, 0)
  // obj_ptr = val32 & ~3
  emit_local_get(body, val32)
  emit_i32_const_raw(body, -4)
  emit_i32_and(body)
  emit_local_set(body, obj_ptr)
  // new_rc = load(obj_ptr - 4) - 1
  emit_local_get(body, obj_ptr)
  emit_i32_const_raw(body, 4)
  emit_i32_sub(body)
  emit_local_get(body, obj_ptr)
  emit_i32_const_raw(body, 4)
  emit_i32_sub(body)
  emit_i32_load(body, 0)
  emit_i32_const_raw(body, 1)
  emit_i32_sub(body)
  emit_local_tee(body, new_rc)
  emit_i32_store(body, 0) // store new_rc at obj_ptr - 4
  // if new_rc == 0: recursively drop fields, tombstone, free-list
  emit_local_get(body, new_rc)
  emit_i32_eqz(body)
  emit_if(body)
  // --- Recursive drop fields via self-call (deep recursion) ---
  // For tuple(3) and array(5): i32 fields at 8+idx*4
  emit_local_get(body, obj_ptr)
  emit_i32_load(body, 0)
  emit_local_set(body, type_id)
  // if type_id == 3 || type_id == 5
  emit_local_get(body, type_id)
  emit_i32_const_raw(body, 3)
  emit_i32_eq(body)
  emit_local_get(body, type_id)
  emit_i32_const_raw(body, 5)
  emit_i32_eq(body)
  emit_i32_or(body)
  emit_if(body) // if tuple or array
  // len = load(obj_ptr + 4)
  emit_local_get(body, obj_ptr)
  emit_i32_load(body, 4)
  emit_local_set(body, len)
  // idx = 0
  emit_i32_const_raw(body, 0)
  emit_local_set(body, idx)
  // loop: for each field, call $rc_drop(i64(field))
  emit_block(body) // block $break
  emit_loop(body) // loop $continue
  emit_local_get(body, idx)
  emit_local_get(body, len)
  emit_i32_ge_s(body)
  emit_br_if(body, 1) // br $break
  // field_val = load_i32(obj_ptr + 8 + idx * 4)
  emit_local_get(body, obj_ptr)
  emit_local_get(body, idx)
  emit_i32_const_raw(body, 4)
  emit_i32_mul(body)
  emit_i32_add(body)
  emit_i32_load(body, 8)
  emit_local_set(body, field_val)
  // Convert i32 field to i64 and call $rc_drop recursively
  emit_local_get(body, field_val)
  emit_i64_extend_i32_u(body)
  emit_local_set(body, field_i64)
  emit_local_get(body, field_i64)
  emit_call(body, self_func_abs_idx) // recursive call to $rc_drop
  // idx += 1
  emit_local_get(body, idx)
  emit_i32_const_raw(body, 1)
  emit_i32_add(body)
  emit_local_set(body, idx)
  emit_br(body, 0) // br $continue
  emit_end(body) // end loop
  emit_end(body) // end block $break
  emit_end(body) // end if tuple or array
  // --- Record(4) and Map(6): values at 8+idx*8+4, 8-byte stride ---
  emit_local_get(body, type_id)
  emit_i32_const_raw(body, 4) // obj_record
  emit_i32_eq(body)
  emit_local_get(body, type_id)
  emit_i32_const_raw(body, 6) // obj_map
  emit_i32_eq(body)
  emit_i32_or(body)
  emit_if(body) // if record or map
  // len = load(obj_ptr + 4) = field_count
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
  // field_val = load_i32(obj_ptr + 8 + idx * 8 + 4) — value part of key-value pair
  emit_local_get(body, obj_ptr)
  emit_local_get(body, idx)
  emit_i32_const_raw(body, 8)
  emit_i32_mul(body)
  emit_i32_add(body)
  emit_i32_load(body, 12) // 8 (base) + 4 (value offset) = 12
  emit_local_set(body, field_val)
  emit_local_get(body, field_val)
  emit_i64_extend_i32_u(body)
  emit_local_set(body, field_i64)
  emit_local_get(body, field_i64)
  emit_call(body, self_func_abs_idx) // recursive $rc_drop
  // idx += 1
  emit_local_get(body, idx)
  emit_i32_const_raw(body, 1)
  emit_i32_add(body)
  emit_local_set(body, idx)
  emit_br(body, 0) // br $continue
  emit_end(body) // end loop
  emit_end(body) // end block $break
  emit_end(body) // end if record or map
  // --- Closure captures (type_id=7): i64 at 16+idx*8 ---
  emit_local_get(body, type_id)
  emit_i32_const_raw(body, 7) // obj_fn
  emit_i32_eq(body)
  emit_if(body) // if type_id == 7
  // len = load(obj_ptr + 4) = capture_count
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
  // field_i64 = load_i64(obj_ptr + 16 + idx * 8)
  emit_local_get(body, obj_ptr)
  emit_local_get(body, idx)
  emit_i32_const_raw(body, 8)
  emit_i32_mul(body)
  emit_i32_add(body)
  emit_i64_load(body, 16)
  emit_local_set(body, field_i64)
  emit_local_get(body, field_i64)
  emit_call(body, self_func_abs_idx) // recursive $rc_drop
  // idx += 1
  emit_local_get(body, idx)
  emit_i32_const_raw(body, 1)
  emit_i32_add(body)
  emit_local_set(body, idx)
  emit_br(body, 0) // br $continue
  emit_end(body) // end loop
  emit_end(body) // end block $break
  emit_end(body) // end if type_id == 7
  // --- Enum payloads (type_id=10): i32 fields at 12+idx*4 ---
  emit_local_get(body, type_id)
  emit_i32_const_raw(body, 10) // obj_enum
  emit_i32_eq(body)
  emit_if(body) // if type_id == 10
  // len = load(obj_ptr + 4) = arity
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
  // field_val = load_i32(obj_ptr + 12 + idx * 4)
  emit_local_get(body, obj_ptr)
  emit_local_get(body, idx)
  emit_i32_const_raw(body, 4)
  emit_i32_mul(body)
  emit_i32_add(body)
  emit_i32_load(body, 12)
  emit_local_set(body, field_val)
  // Convert i32 field to i64 and call $rc_drop recursively
  emit_local_get(body, field_val)
  emit_i64_extend_i32_u(body)
  emit_local_set(body, field_i64)
  emit_local_get(body, field_i64)
  emit_call(body, self_func_abs_idx) // recursive $rc_drop
  // idx += 1
  emit_local_get(body, idx)
  emit_i32_const_raw(body, 1)
  emit_i32_add(body)
  emit_local_set(body, idx)
  emit_br(body, 0) // br $continue
  emit_end(body) // end loop
  emit_end(body) // end block $break
  emit_end(body) // end if type_id == 10
  // --- End recursive drop fields ---
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
  WasmFunc::{
    params: [ValueKind::I64],
    locals: [
      ValueKind::I32, ValueKind::I32, ValueKind::I32, ValueKind::I32,
      ValueKind::I32, ValueKind::I32, ValueKind::I32, ValueKind::I64,
    ],
    results: [],
    body: body.to_array(),
  }
}

///|
/// Compile a standalone WASM function for rc_alloc.
/// Signature: (i32 total_size) -> i32 obj_ptr
/// Scans free-list for exact-size match (first-fit), otherwise bump-allocates.
/// Writes alloc_size and rc_count=1 to the RC header.
fn compile_rc_alloc_function(
  heap_global : Int,
  free_list_global : Int,
) -> WasmFunc {
  let body = ByteBuf::new()
  // Locals: 0=total_size(param), 1=obj_ptr, 2=cur,
  //         3=new_heap, 4=cur_pages, 5=req_pages, 6=prev
  let total_size = 0
  let obj_ptr = 1
  let cur = 2
  let new_heap = 3
  let cur_pages = 4
  let req_pages = 5
  let prev = 6
  // block $allocated — both paths set obj_ptr, then br here
  emit_block(body)
  if free_list_global >= 0 {
    // Walk the free-list with prev/cur pointers to find exact-size match.
    // prev = 0 (sentinel: means cur is head)
    // cur = free_list_head
    emit_i32_const_raw(body, 0)
    emit_local_set(body, prev)
    emit_global_get(body, free_list_global)
    emit_local_set(body, cur)
    // block $found
    //   loop $scan
    //     if cur == 0: br $found (not found)
    //     if load(cur-8) == total_size: unlink, br $allocated
    //     prev = cur; cur = load(cur-4); br $scan
    //   end
    // end $found
    emit_block(body) // block $found
    emit_loop(body) // loop $scan
    // if cur == 0: break (end of list, not found)
    emit_local_get(body, cur)
    emit_i32_eqz(body)
    emit_br_if(body, 1) // br $found
    // if load(cur - 8) == total_size → match
    emit_local_get(body, cur)
    emit_i32_const_raw(body, 8)
    emit_i32_sub(body)
    emit_i32_load(body, 0)
    emit_local_get(body, total_size)
    emit_i32_eq(body)
    emit_if(body) // if size matches
    // next = load(cur - 4)
    // Unlink: if prev == 0: head = next; else: store(prev-4, next)
    emit_local_get(body, prev)
    emit_i32_eqz(body)
    emit_if(body) // if prev == 0 (cur is head)
    emit_local_get(body, cur)
    emit_i32_const_raw(body, 4)
    emit_i32_sub(body)
    emit_i32_load(body, 0) // next
    emit_global_set(body, free_list_global) // head = next
    emit_else(body)
    // prev.next = cur.next: store(prev-4, load(cur-4))
    emit_local_get(body, prev)
    emit_i32_const_raw(body, 4)
    emit_i32_sub(body) // &prev.next
    emit_local_get(body, cur)
    emit_i32_const_raw(body, 4)
    emit_i32_sub(body)
    emit_i32_load(body, 0) // cur.next
    emit_i32_store(body, 0) // prev.next = cur.next
    emit_end(body) // end if prev==0
    // obj_ptr = cur
    emit_local_get(body, cur)
    emit_local_set(body, obj_ptr)
    // Write rc_count = 1
    emit_local_get(body, obj_ptr)
    emit_i32_const_raw(body, 4)
    emit_i32_sub(body)
    emit_i32_const_raw(body, 1)
    emit_i32_store(body, 0)
    emit_br(body, 3) // br $allocated (if_size=0, loop=1, block_found=2, block_allocated=3)
    emit_end(body) // end if size matches
    // Advance: prev = cur; cur = load(cur - 4)
    emit_local_get(body, cur)
    emit_local_set(body, prev)
    emit_local_get(body, cur)
    emit_i32_const_raw(body, 4)
    emit_i32_sub(body)
    emit_i32_load(body, 0) // next
    emit_local_set(body, cur)
    emit_br(body, 0) // br $scan
    emit_end(body) // end loop $scan
    emit_end(body) // end block $found
  }
  // Bump allocate: check memory.grow, then advance heap
  emit_global_get(body, heap_global)
  emit_local_get(body, total_size)
  emit_i32_add(body)
  emit_local_set(body, new_heap)
  emit_memory_size(body)
  emit_local_set(body, cur_pages)
  emit_local_get(body, new_heap)
  emit_i32_const_raw(body, 65535)
  emit_i32_add(body)
  emit_i32_const_raw(body, 16)
  emit_i32_shr_u(body)
  emit_local_set(body, req_pages)
  emit_local_get(body, cur_pages)
  emit_local_get(body, req_pages)
  emit_i32_lt_s(body)
  emit_if(body)
  emit_local_get(body, req_pages)
  emit_local_get(body, cur_pages)
  emit_i32_sub(body)
  emit_memory_grow(body)
  emit_drop(body)
  emit_end(body)
  // obj_ptr = heap + 8
  emit_global_get(body, heap_global)
  emit_i32_const_raw(body, rc_header_extra)
  emit_i32_add(body)
  emit_local_set(body, obj_ptr)
  // heap = heap + total_size
  emit_global_get(body, heap_global)
  emit_local_get(body, total_size)
  emit_i32_add(body)
  emit_global_set(body, heap_global)
  // Write alloc_size at obj_ptr - 8
  emit_local_get(body, obj_ptr)
  emit_i32_const_raw(body, rc_header_extra)
  emit_i32_sub(body)
  emit_local_get(body, total_size)
  emit_i32_store(body, 0)
  // Write rc_count = 1 at obj_ptr - 4
  emit_local_get(body, obj_ptr)
  emit_i32_const_raw(body, 4)
  emit_i32_sub(body)
  emit_i32_const_raw(body, 1)
  emit_i32_store(body, 0)
  emit_end(body) // end block $allocated
  // Return obj_ptr
  emit_local_get(body, obj_ptr)
  emit_end(body) // end func
  WasmFunc::{
    params: [ValueKind::I32],
    locals: [
      ValueKind::I32, ValueKind::I32, ValueKind::I32, ValueKind::I32,
      ValueKind::I32, ValueKind::I32,
    ],
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
) -> WasmFunc {
  let body = ByteBuf::new()
  // Locals: 0=param(i64), 1=val32, 2=obj_ptr, 3=rc_count,
  //         4=type_id, 5=len, 6=idx, 7=field_val, 8=field_i64
  let param = 0
  let val32 = 1
  let obj_ptr = 2
  let rc_count = 3
  let type_id = 4
  let len = 5
  let idx = 6
  let field_val = 7
  let field_i64 = 8
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
  emit_local_get(body, obj_ptr)
  emit_i32_load(body, 0)
  emit_local_set(body, type_id)
  // --- Tuple(3) or Array(5): i32 at 8+idx*4 ---
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
  // --- Record(4) or Map(6): values at 8+idx*8+4 ---
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
  // --- Closure(7): i64 at 16+idx*8 ---
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
  // --- Enum(10): i32 at 12+idx*4 ---
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
  // Return obj_ptr (RC is already 1, ready for reuse)
  emit_local_get(body, obj_ptr)
  emit_end(body) // end block $done
  emit_end(body) // end func
  WasmFunc::{
    params: [ValueKind::I64],
    locals: [
      ValueKind::I32, ValueKind::I32, ValueKind::I32, ValueKind::I32,
      ValueKind::I32, ValueKind::I32, ValueKind::I32, ValueKind::I64,
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
