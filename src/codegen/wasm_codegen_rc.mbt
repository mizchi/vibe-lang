///|
/// Perceus RC codegen for WASM linear memory backend.
///
/// Object header layout (with RC):
///   offset 0: i32 obj_type   (existing)
///   offset 4: i32 rc_count   (NEW: reference count, starts at 1)
///   offset 8: ...            (existing metadata shifts by 4)
///
/// RC operations:
///   rc_dup(ptr):  rc_count += 1
///   rc_drop(ptr): rc_count -= 1; if rc_count == 0 → free(ptr)
///
/// For the prototype, "free" is a no-op (bump allocator).
/// Future: free-list or arena reclamation.

///|
/// Offset of the reference count field in the object header.
let rc_offset = 4

///|
/// Size added to each object header for the RC field.
pub let rc_header_extra : Int = 4

///|
/// RC-aware object header: type (4 bytes) + rc (4 bytes) = 8 bytes.
/// All existing metadata shifts right by rc_header_extra.
pub let rc_header_size : Int = 8

///|
/// Emit RC initialization for a freshly allocated object.
/// Assumes the object pointer is on top of the WASM stack.
/// After this, the pointer is consumed (stored to obj_local).
///
/// Generated WASM pseudo-code:
///   local.get $obj_local
///   i32.const 1
///   i32.store offset=4   ; rc_count = 1
fn emit_rc_init(buf : ByteBuf, obj_local : Int) -> Unit {
  emit_local_get(buf, obj_local)
  emit_i32_const_raw(buf, 1)
  emit_i32_store(buf, rc_offset)
}

///|
/// Emit rc_dup: increment the reference count of a heap object.
///
/// Generated WASM pseudo-code:
///   local.get $val
///   i32.const 3          ; tag_mask
///   i32.and
///   i32.const 1          ; tag_obj
///   i32.ne
///   br_if $skip          ; skip if not a heap object
///   local.get $val
///   i32.const -1         ; clear tag bit
///   i32.and              ; ptr = val & ~1
///   local.tee $tmp
///   local.get $tmp
///   i32.load offset=4    ; load rc_count
///   i32.const 1
///   i32.add
///   i32.store offset=4   ; rc_count += 1
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
  // ptr = val & ~tag_mask (clear low 2 bits)
  emit_local_get(buf, val_local)
  emit_i32_const_raw(buf, -4) // 0xFFFFFFFC: mask off low 2 bits
  emit_i32_and(buf)
  emit_local_set(buf, tmp_local)
  // rc_count = load(ptr + rc_offset) + 1
  emit_local_get(buf, tmp_local)
  emit_local_get(buf, tmp_local)
  emit_i32_load(buf, rc_offset)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_i32_store(buf, rc_offset)
  emit_end(buf) // end block
}

///|
/// Emit rc_drop: decrement the reference count of a heap object.
/// If rc reaches 0, the memory could be reclaimed (no-op in prototype).
///
/// Generated WASM pseudo-code:
///   local.get $val
///   i32.const 3
///   i32.and
///   i32.const 1
///   i32.ne
///   br_if $skip
///   local.get $val
///   i32.const -4
///   i32.and
///   local.tee $tmp
///   local.get $tmp
///   i32.load offset=4
///   i32.const 1
///   i32.sub
///   local.tee $new_rc
///   i32.store offset=4   ; rc_count -= 1
///   ;; if new_rc == 0 → could free (no-op for now)
///   $skip:
fn emit_rc_drop(
  buf : ByteBuf,
  val_local : Int,
  tmp_local : Int,
  _new_rc_local : Int,
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
  // ptr = val & ~tag_mask
  emit_local_get(buf, val_local)
  emit_i32_const_raw(buf, -4)
  emit_i32_and(buf)
  emit_local_set(buf, tmp_local)
  // new_rc = load(ptr + rc_offset) - 1
  emit_local_get(buf, tmp_local)
  emit_local_get(buf, tmp_local)
  emit_i32_load(buf, rc_offset)
  emit_i32_const_raw(buf, 1)
  emit_i32_sub(buf)
  // store new_rc back
  // Future: if new_rc == 0, add ptr to free list
  emit_i32_store(buf, rc_offset)
  emit_end(buf) // end block
}

///|
/// Summary of integration points for wiring Perceus actions into codegen:
///
/// 1. After each `emit_heap_alloc`, call `emit_rc_init` to set rc=1.
///
/// 2. At PerceusAction::Dup sites, emit `emit_rc_dup` on the local
///    holding the duplicated value.
///
/// 3. At PerceusAction::Drop sites, emit `emit_rc_drop` on the local
///    holding the dropped value.
///
/// 4. All object field offsets shift by +4 (rc_header_extra) to
///    accommodate the new RC field at offset 4.
///
/// 5. Mutable assignment (`Stmt::Assign`): emit rc_drop on old value
///    before storing new value, then emit rc_dup on new value if needed.
///
/// The Perceus analysis pass (`build_perceus_plan`) provides the exact
/// sites for dup/drop insertion as `Array[PerceusAction]`.
pub fn perceus_codegen_integration_notes() -> String {
  let notes = [
    "1. emit_rc_init after emit_heap_alloc (set rc=1)", "2. emit_rc_dup at PerceusAction::Dup sites",
    "3. emit_rc_drop at PerceusAction::Drop sites", "4. shift all field offsets by +4 for RC header",
    "5. Assign: rc_drop(old) before store, rc_dup(new) if needed",
  ]
  let mut result = ""
  for note in notes {
    result = result + note + "\n"
  }
  result
}
