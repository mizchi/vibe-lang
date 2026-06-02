///|
/// Phase B-1 (Issue #415): `Int::parse` migrated off the two legacy `match
/// name` dispatchers (`wasm_codegen_builtin_numeric.mbt` linear arm — the one
/// that actually runs, since the numeric handler is tried before the string
/// handler — and `wasm_gc_codegen.mbt::Call`) onto the shared
/// `migrated_builtin` table in `builtin_registry.mbt`. `Int::parse` is a
/// core-namespace builtin present on BOTH backends, so it uses `mig` /
/// `registry_both`.
///
/// The linear body is byte-buffer codegen relocated verbatim from the
/// numeric.mbt arm; the wasm-gc body is a thin delegate to
/// `compile_int_parse_gc`, relocated verbatim from the gc inline arm. Both
/// raise `Unsupported("Int::parse with js strings")` under `use_js_strings`
/// (a real error, not the unhandled marker).

///|
fn compile_int_parse_linear(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  // Int::parse(s: String) -> Option[Int]
  // Returns Some(int) on success, None on failure.
  let pos_args = extract_positional_exprs_with_arity(args, "Int::parse", 1)
  if ctx.use_js_strings {
    raise WasmGenError::Unsupported("Int::parse with js strings")
  } else {
    require_heap(ctx)
    // Native string mode: byte-iterate and accumulate
    let str_ptr_local = alloc_temp_local(ctx) // base pointer
    let str_len_local = alloc_temp_local(ctx) // string length
    let idx_local = alloc_temp_local(ctx) // current index
    let result_local = alloc_temp_local(ctx) // accumulator
    let neg_local = alloc_temp_local(ctx) // sign flag (0=pos, 1=neg)
    let byte_local = alloc_temp_local(ctx) // current byte
    let valid_local = alloc_temp_local(ctx) // validity flag (1=valid, 0=invalid)
    let has_digit_local = alloc_temp_local(ctx) // has at least one digit
    let obj_local = alloc_temp_local(ctx) // heap object for Option

    // Untag pointer, get base address
    compile_expr_i32(ctx, buf, pos_args[0])
    emit_untag_ptr_i32(buf)
    emit_local_set(buf, str_ptr_local)

    // Load string length
    emit_local_get(buf, str_ptr_local)
    emit_i32_load(buf, 4)
    emit_local_set(buf, str_len_local)

    // Initialize: result=0, idx=0, neg=0, valid=1, has_digit=0
    emit_i32_const_raw(buf, 0)
    emit_local_set(buf, result_local)
    emit_i32_const_raw(buf, 0)
    emit_local_set(buf, idx_local)
    emit_i32_const_raw(buf, 0)
    emit_local_set(buf, neg_local)
    emit_i32_const_raw(buf, 1)
    emit_local_set(buf, valid_local)
    emit_i32_const_raw(buf, 0)
    emit_local_set(buf, has_digit_local)

    // Skip leading spaces (byte == 32)
    emit_block(buf) // block $skip_done
    emit_loop(buf) // loop $skip_loop
    emit_local_get(buf, idx_local)
    emit_local_get(buf, str_len_local)
    emit_i32_ge_s(buf)
    emit_br_if(buf, 1) // br $skip_done
    emit_local_get(buf, str_ptr_local)
    emit_local_get(buf, idx_local)
    emit_i32_add(buf)
    emit_i32_load8_u(buf, 8)
    emit_i32_const_raw(buf, 32) // space
    emit_i32_ne(buf)
    emit_br_if(buf, 1) // not space => break
    emit_local_get(buf, idx_local)
    emit_i32_const_raw(buf, 1)
    emit_i32_add(buf)
    emit_local_set(buf, idx_local)
    emit_br(buf, 0) // continue loop
    emit_end(buf) // end loop
    emit_end(buf) // end block

    // Check sign: '-' (45) or '+' (43)
    emit_block(buf) // block $sign_done
    emit_local_get(buf, idx_local)
    emit_local_get(buf, str_len_local)
    emit_i32_ge_s(buf)
    emit_br_if(buf, 0) // no chars left => skip sign check
    emit_local_get(buf, str_ptr_local)
    emit_local_get(buf, idx_local)
    emit_i32_add(buf)
    emit_i32_load8_u(buf, 8)
    emit_local_set(buf, byte_local)
    emit_local_get(buf, byte_local)
    emit_i32_const_raw(buf, 45) // '-'
    emit_i32_eq(buf)
    emit_if(buf)
    emit_i32_const_raw(buf, 1)
    emit_local_set(buf, neg_local)
    emit_local_get(buf, idx_local)
    emit_i32_const_raw(buf, 1)
    emit_i32_add(buf)
    emit_local_set(buf, idx_local)
    emit_br(buf, 1) // br $sign_done
    emit_end(buf) // end if
    emit_local_get(buf, byte_local)
    emit_i32_const_raw(buf, 43) // '+'
    emit_i32_eq(buf)
    emit_if(buf)
    emit_local_get(buf, idx_local)
    emit_i32_const_raw(buf, 1)
    emit_i32_add(buf)
    emit_local_set(buf, idx_local)
    emit_end(buf) // end if
    emit_end(buf) // end block $sign_done

    // Main digit loop: result = result * 10 + (byte - 48)
    // On non-digit (except trailing space), set valid=0 and break
    emit_block(buf) // block $digit_done
    emit_loop(buf) // loop $digit_loop
    emit_local_get(buf, idx_local)
    emit_local_get(buf, str_len_local)
    emit_i32_ge_s(buf)
    emit_br_if(buf, 1) // br $digit_done
    emit_local_get(buf, str_ptr_local)
    emit_local_get(buf, idx_local)
    emit_i32_add(buf)
    emit_i32_load8_u(buf, 8)
    emit_local_set(buf, byte_local)
    // Skip trailing spaces: if byte == 32, break
    emit_local_get(buf, byte_local)
    emit_i32_const_raw(buf, 32)
    emit_i32_eq(buf)
    emit_br_if(buf, 1) // br $digit_done
    // Check if digit: byte < '0' (48) or byte > '9' (57) => invalid
    emit_local_get(buf, byte_local)
    emit_i32_const_raw(buf, 48) // '0'
    emit_i32_lt_s(buf)
    emit_if(buf)
    emit_i32_const_raw(buf, 0)
    emit_local_set(buf, valid_local)
    emit_br(buf, 2) // br $digit_done (block depth: if=0, loop=1, block=2 => need 2)
    emit_end(buf) // end if
    emit_local_get(buf, byte_local)
    emit_i32_const_raw(buf, 57) // '9'
    emit_i32_gt_s(buf)
    emit_if(buf)
    emit_i32_const_raw(buf, 0)
    emit_local_set(buf, valid_local)
    emit_br(buf, 2) // br $digit_done
    emit_end(buf) // end if
    // Valid digit: result = result * 10 + (byte - 48)
    emit_i32_const_raw(buf, 1)
    emit_local_set(buf, has_digit_local)
    emit_local_get(buf, result_local)
    emit_i32_const_raw(buf, 10)
    emit_i32_mul(buf)
    emit_local_get(buf, byte_local)
    emit_i32_const_raw(buf, 48)
    emit_i32_sub(buf)
    emit_i32_add(buf)
    emit_local_set(buf, result_local)
    // idx++
    emit_local_get(buf, idx_local)
    emit_i32_const_raw(buf, 1)
    emit_i32_add(buf)
    emit_local_set(buf, idx_local)
    emit_br(buf, 0) // continue loop
    emit_end(buf) // end loop
    emit_end(buf) // end block

    // Check valid && has_digit: if not, produce None
    // valid = valid & has_digit
    emit_local_get(buf, valid_local)
    emit_local_get(buf, has_digit_local)
    emit_i32_and(buf)
    buf.push((4).to_byte()) // if
    buf.push((126).to_byte()) // result i64

    // Apply negation if neg_local == 1
    emit_local_get(buf, neg_local)
    emit_if(buf)
    emit_i32_const_raw(buf, 0)
    emit_local_get(buf, result_local)
    emit_i32_sub(buf)
    emit_local_set(buf, result_local)
    emit_end(buf) // end if

    // Tag result as i64 Int: (result << 2) | tag_int
    // Then wrap in Some: heap alloc enum obj with tag=1, payload=tagged_int
    // Some tag index = 1 (None=0, Some=1)
    let some_size = align4(12 + 8) // obj_type(4) + arity(4) + enum_tag(4) + payload(8)
    emit_heap_alloc(ctx, buf, some_size, obj_local)
    // Store obj_type = obj_enum (10)
    emit_local_get(buf, obj_local)
    emit_i32_const_raw(buf, obj_enum)
    emit_i32_store(buf, 0)
    // Store arity = 1
    emit_local_get(buf, obj_local)
    emit_i32_const_raw(buf, 1)
    emit_i32_store(buf, 4)
    // Store enum tag = 1 (Some)
    emit_local_get(buf, obj_local)
    emit_i32_const_raw(buf, 1)
    emit_i32_store(buf, 8)
    // Store payload: tagged int value at offset 12
    emit_local_get(buf, obj_local)
    emit_local_get(buf, result_local)
    emit_i64_extend_i32_s(buf)
    emit_i64_const_raw(buf, 2L)
    emit_i64_shl(buf)
    // tag_int = 0, i64.or is a no-op
    emit_i64_store(buf, 12)
    // Return tagged pointer: (obj_local as i64) | tag_obj
    emit_local_get(buf, obj_local)
    emit_i64_extend_i32_u(buf)
    emit_i64_const_raw(buf, tag_obj.to_int64())
    emit_i64_or(buf)

    emit_else(buf) // else: produce None

    // None: heap alloc enum obj with tag=0, no payload
    let none_size = align4(12) // obj_type(4) + arity(4) + enum_tag(4)
    emit_heap_alloc(ctx, buf, none_size, obj_local)
    emit_local_get(buf, obj_local)
    emit_i32_const_raw(buf, obj_enum)
    emit_i32_store(buf, 0)
    emit_local_get(buf, obj_local)
    emit_i32_const_raw(buf, 0) // arity = 0
    emit_i32_store(buf, 4)
    emit_local_get(buf, obj_local)
    emit_i32_const_raw(buf, 0) // None tag = 0
    emit_i32_store(buf, 8)
    emit_local_get(buf, obj_local)
    emit_i64_extend_i32_u(buf)
    emit_i64_const_raw(buf, tag_obj.to_int64())
    emit_i64_or(buf)

    emit_end(buf) // end if valid
  }
}

///|
fn compile_int_parse_gc_arm(
  ctx : GcCodegenCtx,
  fctx : GcFuncCtx,
  buf : GcByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  if pos_args.length() != 1 {
    raise WasmGenError::Unsupported("Int::parse arity")
  }
  compile_int_parse_gc(ctx, fctx, buf, pos_args[0])
}
