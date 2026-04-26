///|
/// Compile a standalone WASM helper function that compares two tagged i64
/// values for structural equality, recursing through nested heap-allocated
/// `obj_enum` payloads.
///
/// Signature: `(left : i64, right : i64) -> i32`  (1 = equal, 0 = not equal)
///
/// The inline `__eq` in `compile_binary_cmp_op` handles top-level dispatch
/// (string content, float/double, record/tuple/enum shallow). For
/// `obj_enum` it emits `i32.eq` per payload slot, which only matches when
/// both payloads share the same heap address. Two structurally equal but
/// separately allocated values (e.g.
/// `Tree::Node(Tree::Leaf(1), Tree::Leaf(2)) ==
///  Tree::Node(Tree::Leaf(1), Tree::Leaf(2))`) miscompare with that
/// shallow path. Replacing the per-payload `i32.eq` with a call to this
/// helper restores deep structural equality (#325).
///
/// Dispatch summary:
///   - non-obj tags (`tag_int`, `tag_bool`, `tag_fn`): `i64.eq`
///   - `tag_obj` + `tag_obj`: untag pointers
///       - same pointer: `1`
///       - different pointers, both `obj_enum`, same `ctor_tag` and arity:
///           recurse on each payload (sign-extending the stored i32 back to
///           the original tagged i64).
///       - any other obj layout / ctor mismatch: `0` (we already proved
///           pointer inequality, so e.g. two distinct `obj_string` heap
///           strings stored as enum payload would still miscompare —
///           callers that need string content compare go through the inline
///           top-level `__eq` path instead).
///   - mixed tag (one obj, one not): `0`
fn compile_value_eq_function(self_func_abs_idx : Int) -> WasmFunc {
  let body = ByteBuf::new()
  // Param locals
  let left = 0
  let right = 1
  // Extra locals (declared in `locals` array order, indices follow params).
  let left_ptr = 2
  let right_ptr = 3
  let left_type = 4
  let arity = 5
  let i = 6
  let eq = 7
  // Both tags == tag_obj?
  emit_local_get(body, left)
  emit_i64_const_raw(body, tag_mask.to_int64())
  emit_i64_and(body)
  emit_i64_const_raw(body, tag_obj.to_int64())
  emit_i64_eq(body)
  emit_local_get(body, right)
  emit_i64_const_raw(body, tag_mask.to_int64())
  emit_i64_and(body)
  emit_i64_const_raw(body, tag_obj.to_int64())
  emit_i64_eq(body)
  emit_i32_and(body)
  body.push(b'\x04') // if
  body.push(b'\x7f') // result i32
  // Untag pointers
  emit_local_get(body, left)
  emit_i64_const_raw(body, (-4).to_int64())
  emit_i64_and(body)
  emit_i32_wrap_i64(body)
  emit_local_set(body, left_ptr)
  emit_local_get(body, right)
  emit_i64_const_raw(body, (-4).to_int64())
  emit_i64_and(body)
  emit_i32_wrap_i64(body)
  emit_local_set(body, right_ptr)
  // Pointer-eq fast path
  emit_local_get(body, left_ptr)
  emit_local_get(body, right_ptr)
  emit_i32_eq(body)
  body.push(b'\x04') // if
  body.push(b'\x7f') // result i32
  emit_i32_const_raw(body, 1)
  body.push(b'\x05') // else
  // Compare obj types — both must be obj_enum
  emit_local_get(body, left_ptr)
  emit_i32_load(body, 0)
  emit_local_set(body, left_type)
  emit_local_get(body, left_type)
  emit_i32_const_raw(body, obj_enum)
  emit_i32_eq(body)
  emit_local_get(body, right_ptr)
  emit_i32_load(body, 0)
  emit_i32_const_raw(body, obj_enum)
  emit_i32_eq(body)
  emit_i32_and(body)
  body.push(b'\x04') // if (both obj_enum)
  body.push(b'\x7f') // result i32
  // ctor_tag must match
  emit_local_get(body, left_ptr)
  emit_i32_load(body, 8)
  emit_local_get(body, right_ptr)
  emit_i32_load(body, 8)
  emit_i32_eq(body)
  body.push(b'\x04') // if (same ctor_tag)
  body.push(b'\x7f') // result i32
  // arity must match
  emit_local_get(body, left_ptr)
  emit_i32_load(body, 4)
  emit_local_set(body, arity)
  emit_local_get(body, arity)
  emit_local_get(body, right_ptr)
  emit_i32_load(body, 4)
  emit_i32_eq(body)
  body.push(b'\x04') // if (same arity)
  body.push(b'\x7f') // result i32
  // Loop over payloads, recurse on each
  emit_i32_const_raw(body, 1)
  emit_local_set(body, eq)
  emit_i32_const_raw(body, 0)
  emit_local_set(body, i)
  emit_block(body)
  emit_loop(body)
  emit_local_get(body, i)
  emit_local_get(body, arity)
  emit_i32_lt_s(body)
  emit_i32_eqz(body)
  emit_br_if(body, 1)
  // left payload[i] : i32 → sign-extend to i64
  emit_local_get(body, left_ptr)
  emit_local_get(body, i)
  emit_i32_const_raw(body, 4)
  emit_i32_mul(body)
  emit_i32_add(body)
  emit_i32_load(body, 12)
  emit_i64_extend_i32_s(body)
  // right payload[i] : i32 → sign-extend to i64
  emit_local_get(body, right_ptr)
  emit_local_get(body, i)
  emit_i32_const_raw(body, 4)
  emit_i32_mul(body)
  emit_i32_add(body)
  emit_i32_load(body, 12)
  emit_i64_extend_i32_s(body)
  // Recurse
  emit_call(body, self_func_abs_idx)
  emit_i32_eqz(body)
  body.push(b'\x04') // if (recursive cmp said unequal)
  body.push(b'\x40') // void
  emit_i32_const_raw(body, 0)
  emit_local_set(body, eq)
  // Break: set i = arity so the next lt_s test fails
  emit_local_get(body, arity)
  emit_local_set(body, i)
  body.push(b'\x05') // else
  emit_local_get(body, i)
  emit_i32_const_raw(body, 1)
  emit_i32_add(body)
  emit_local_set(body, i)
  body.push(b'\x0b') // end if
  emit_br(body, 0)
  emit_end(body) // end loop
  emit_end(body) // end block
  emit_local_get(body, eq)
  body.push(b'\x05') // else (arity mismatch)
  emit_i32_const_raw(body, 0)
  body.push(b'\x0b') // end if (same arity)
  body.push(b'\x05') // else (ctor_tag differs)
  emit_i32_const_raw(body, 0)
  body.push(b'\x0b') // end if (same ctor_tag)
  body.push(b'\x05') // else (not both obj_enum)
  // Different obj layouts / non-enum heap object: pointer-eq already failed,
  // so report inequality. Top-level inline `__eq` handles string/float/etc.
  emit_i32_const_raw(body, 0)
  body.push(b'\x0b') // end if (both obj_enum)
  body.push(b'\x0b') // end if (ptr-eq fast path)
  body.push(b'\x05') // else (mixed tag — at least one is non-obj)
  // Both non-obj: i64.eq directly. Mixed (one obj, one tagged scalar) gives
  // false because their tag bits differ. i64.eq covers both cases.
  emit_local_get(body, left)
  emit_local_get(body, right)
  emit_i64_eq(body)
  body.push(b'\x0b') // end if (both obj)
  emit_end(body) // end function
  WasmFunc::{
    params: [ValueKind::I64, ValueKind::I64],
    locals: [
      ValueKind::I32, // left_ptr
      ValueKind::I32, // right_ptr
      ValueKind::I32, // left_type
      ValueKind::I32, // arity
      ValueKind::I32, // i
      ValueKind::I32, // eq
    ],
    results: [ValueKind::I32],
    body: body.to_array(),
  }
}
