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
  // if new_rc == 0: free the block
  emit_local_get(buf, new_rc_local)
  emit_i32_eqz(buf)
  emit_if(buf)
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
/// Ensure RC temp locals are allocated for this function.
fn ensure_rc_locals(ctx : CodegenCtx) -> Unit {
  if ctx.rc_tmp_local < 0 {
    ctx.rc_tmp_local = alloc_temp_local(ctx) // i32
    ctx.rc_new_rc_local = alloc_temp_local(ctx) // i32
  }
}

///|
/// Emit RC dup for an i64 local (truncates to i32 internally).
fn emit_rc_dup_i64(ctx : CodegenCtx, buf : ByteBuf, local_idx : Int) -> Unit {
  ensure_rc_locals(ctx)
  // Truncate i64 to i32 into rc_tmp_local, then do dup on that
  let val32 = alloc_temp_local(ctx)
  emit_local_get(buf, local_idx)
  emit_i32_wrap_i64(buf)
  emit_local_set(buf, val32)
  emit_rc_dup(buf, val32, ctx.rc_tmp_local)
}

///|
/// Emit RC drop for an i64 local (truncates to i32 internally).
fn emit_rc_drop_i64(ctx : CodegenCtx, buf : ByteBuf, local_idx : Int) -> Unit {
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
  actions : Map[Int, Array[RcStmtAction]],
  stmt_idx : Int,
) -> Unit {
  match actions.get(stmt_idx) {
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
pub fn build_rc_action_maps(
  actions : Array[(String, Bool, String)],
) -> (Map[Int, Array[RcStmtAction]], Map[Int, Array[RcStmtAction]]) {
  let pre : Map[Int, Array[RcStmtAction]] = {}
  let post : Map[Int, Array[RcStmtAction]] = {}
  for action in actions {
    let (site, is_dup, name) = action
    let kind = if is_dup { RcStmtActionKind::Dup } else { RcStmtActionKind::Drop }
    let act = RcStmtAction::{ kind, name }
    let idx = parse_stmt_index(site)
    if idx < 0 {
      continue
    }
    // old_value drops go to pre-actions (before the stmt)
    if site.contains(".old_value") {
      match pre.get(idx) {
        Some(arr) => arr.push(act)
        None => pre[idx] = [act]
      }
    } else {
      match post.get(idx) {
        Some(arr) => arr.push(act)
        None => post[idx] = [act]
      }
    }
  }
  (pre, post)
}

///|
/// Parse "stmt[N]..." to extract N as Int. Returns -1 on failure.
fn parse_stmt_index(site : String) -> Int {
  // Expected format: "stmt[0]...", "stmt[12].old_value", etc.
  if site.length() < 6 {
    return -1
  }
  // Check prefix "stmt["
  if not(site.has_prefix("stmt[")) {
    return -1
  }
  let mut i = 5 // skip "stmt["
  let mut result = 0
  while i < site.length() {
    let c = site[i]
    if c == ']' {
      break
    }
    if c >= '0' && c <= '9' {
      result = result * 10 + (c.to_int() - '0'.to_int())
    } else {
      return -1
    }
    i += 1
  }
  if i == 5 {
    return -1
  }
  result
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
pub fn perceus_codegen_integration_notes() -> String {
  let notes = [
    "1. emit_rc_init after emit_heap_alloc (rc at ptr-4, offsets unchanged)",
    "2. emit_rc_dup at PerceusAction::Dup sites",
    "3. emit_rc_drop at PerceusAction::Drop sites",
    "4. Assign: rc_drop(old) before store",
  ]
  let mut result = ""
  for note in notes {
    result = result + note + "\n"
  }
  result
}
