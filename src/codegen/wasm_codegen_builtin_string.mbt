///|
fn compile_builtin_string(
  ctx : CodegenCtx,
  buf : ByteBuf,
  name : String,
  args : Array[@core.CallArg],
  is_user_fn : Bool,
) -> Unit raise WasmGenError {
  match name {
    "__to_string"
    | "Int::to_string"
    | "Float::to_string"
    | "Double::to_string"
    | "Bool::to_string" => {
      let pos_args = extract_positional_exprs_with_arity(args, name, 1)
      if ctx.use_js_strings {
        let arg_kind = infer_expr_kind(ctx, pos_args[0])
        if arg_kind == ValueKind::ExternRef {
          compile_expr_ref(ctx, buf, pos_args[0])
        } else {
          compile_expr_i32(ctx, buf, pos_args[0])
          emit_drop(buf)
          emit_string_const(ctx, buf, "")
        }
      } else {
        require_heap(ctx)
        let true_str = tag_ptr64(ctx.strings.intern("true"), tag_obj)
        let false_str = tag_ptr64(ctx.strings.intern("false"), tag_obj)
        let fallback_str = tag_ptr64(ctx.strings.intern("<value>"), tag_obj)
        let value_local = alloc_temp_local_with_kind(ctx, ValueKind::I64)
        let tag_local = alloc_temp_local(ctx)
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_local_set(buf, value_local)
        // Extract tag (i32) from i64 value
        emit_local_get(buf, value_local)
        emit_i64_const_raw(buf, tag_mask.to_int64())
        emit_i64_and(buf)
        emit_i32_wrap_i64(buf)
        emit_local_set(buf, tag_local)
        emit_local_get(buf, tag_local)
        emit_i32_const_raw(buf, tag_obj)
        emit_i32_eq(buf)
        buf.push((4).to_byte()) // if
        buf.push((126).to_byte()) // result i64
        let obj_ptr_local = alloc_temp_local(ctx)
        let obj_ty_local = alloc_temp_local(ctx)
        emit_local_get(buf, value_local)
        emit_untag_ptr_i32(buf)
        emit_local_set(buf, obj_ptr_local)
        emit_local_get(buf, obj_ptr_local)
        emit_i32_load(buf, 0)
        emit_local_set(buf, obj_ty_local)
        emit_local_get(buf, obj_ty_local)
        emit_i32_const_raw(buf, obj_string)
        emit_i32_eq(buf)
        buf.push((4).to_byte()) // if
        buf.push((126).to_byte()) // result i64
        emit_local_get(buf, value_local)
        buf.push((5).to_byte()) // else
        emit_local_get(buf, obj_ty_local)
        emit_i32_const_raw(buf, obj_float)
        emit_i32_eq(buf)
        emit_local_get(buf, obj_ty_local)
        emit_i32_const_raw(buf, obj_double)
        emit_i32_eq(buf)
        emit_i32_or(buf)
        buf.push((4).to_byte()) // if
        buf.push((126).to_byte()) // result i64
        emit_number_obj_to_string(
          ctx, buf, obj_ptr_local, obj_ty_local, fallback_str,
        )
        buf.push((5).to_byte()) // else
        emit_i64_const_raw(buf, fallback_str)
        buf.push((11).to_byte()) // end if
        buf.push((11).to_byte()) // end if
        buf.push((5).to_byte()) // else
        emit_local_get(buf, tag_local)
        emit_i32_const_raw(buf, tag_bool)
        emit_i32_eq(buf)
        buf.push((4).to_byte()) // if
        buf.push((126).to_byte()) // result i64
        emit_local_get(buf, value_local)
        emit_i64_const_raw(buf, tag_bool_value64(true))
        emit_i64_eq(buf)
        buf.push((4).to_byte()) // if
        buf.push((126).to_byte()) // result i64
        emit_i64_const_raw(buf, true_str)
        buf.push((5).to_byte()) // else
        emit_i64_const_raw(buf, false_str)
        buf.push((11).to_byte()) // end if
        buf.push((5).to_byte()) // else
        emit_local_get(buf, tag_local)
        emit_i32_const_raw(buf, tag_int)
        emit_i32_eq(buf)
        buf.push((4).to_byte()) // if
        buf.push((126).to_byte()) // result i64
        let n_local = alloc_temp_local(ctx)
        let is_neg_local = alloc_temp_local(ctx)
        let scratch_local = alloc_temp_local(ctx)
        let digit_len_local = alloc_temp_local(ctx)
        let digit_local = alloc_temp_local(ctx)
        let copy_i_local = alloc_temp_local(ctx)
        let obj_local = alloc_temp_local(ctx)
        let src_idx_local = alloc_temp_local(ctx)
        let alloc_size_local = alloc_temp_local(ctx)
        emit_local_get(buf, value_local)
        emit_untag_int_i32(buf)
        emit_local_set(buf, n_local)
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, is_neg_local)
        emit_local_get(buf, n_local)
        emit_i32_const_raw(buf, 0)
        emit_i32_lt_s(buf)
        buf.push((4).to_byte()) // if
        buf.push((64).to_byte()) // void
        emit_i32_const_raw(buf, 1)
        emit_local_set(buf, is_neg_local)
        emit_i32_const_raw(buf, 0)
        emit_local_get(buf, n_local)
        emit_i32_sub(buf)
        emit_local_set(buf, n_local)
        buf.push((11).to_byte()) // end if
        emit_heap_alloc(ctx, buf, 64, scratch_local)
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, digit_len_local)
        emit_local_get(buf, n_local)
        emit_i32_eqz(buf)
        buf.push((4).to_byte()) // if
        buf.push((64).to_byte()) // void
        emit_local_get(buf, scratch_local)
        emit_i32_const_raw(buf, 48)
        emit_i32_store8(buf, 0)
        emit_i32_const_raw(buf, 1)
        emit_local_set(buf, digit_len_local)
        buf.push((5).to_byte()) // else
        emit_block(buf)
        emit_loop(buf)
        emit_local_get(buf, n_local)
        emit_i32_eqz(buf)
        emit_br_if(buf, 1)
        emit_local_get(buf, n_local)
        emit_i32_const_raw(buf, 10)
        emit_i32_rem_s(buf)
        emit_local_set(buf, digit_local)
        emit_local_get(buf, n_local)
        emit_i32_const_raw(buf, 10)
        emit_i32_div_s(buf)
        emit_local_set(buf, n_local)
        emit_local_get(buf, scratch_local)
        emit_local_get(buf, digit_len_local)
        emit_i32_add(buf)
        emit_local_get(buf, digit_local)
        emit_i32_const_raw(buf, 48)
        emit_i32_add(buf)
        emit_i32_store8(buf, 0)
        emit_local_get(buf, digit_len_local)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, digit_len_local)
        emit_br(buf, 0)
        emit_end(buf)
        emit_end(buf)
        buf.push((11).to_byte()) // end if
        emit_local_get(buf, is_neg_local)
        emit_i32_eqz(buf)
        buf.push((4).to_byte()) // if
        buf.push((64).to_byte()) // void
        buf.push((5).to_byte()) // else
        emit_local_get(buf, scratch_local)
        emit_local_get(buf, digit_len_local)
        emit_i32_add(buf)
        emit_i32_const_raw(buf, 45)
        emit_i32_store8(buf, 0)
        emit_local_get(buf, digit_len_local)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, digit_len_local)
        buf.push((11).to_byte()) // end if
        emit_local_get(buf, digit_len_local)
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
        emit_local_get(buf, digit_len_local)
        emit_i32_store(buf, 4)
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, copy_i_local)
        emit_block(buf)
        emit_loop(buf)
        emit_local_get(buf, copy_i_local)
        emit_local_get(buf, digit_len_local)
        emit_i32_lt_s(buf)
        emit_i32_eqz(buf)
        emit_br_if(buf, 1)
        emit_local_get(buf, digit_len_local)
        emit_i32_const_raw(buf, 1)
        emit_i32_sub(buf)
        emit_local_get(buf, copy_i_local)
        emit_i32_sub(buf)
        emit_local_set(buf, src_idx_local)
        emit_local_get(buf, obj_local)
        emit_local_get(buf, copy_i_local)
        emit_i32_add(buf)
        emit_local_get(buf, scratch_local)
        emit_local_get(buf, src_idx_local)
        emit_i32_add(buf)
        emit_i32_load8_u(buf, 0)
        emit_i32_store8(buf, 8)
        emit_local_get(buf, copy_i_local)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, copy_i_local)
        emit_br(buf, 0)
        emit_end(buf)
        emit_end(buf)
        emit_local_get(buf, obj_local)
        emit_i64_extend_i32_u(buf)
        emit_i64_const_raw(buf, tag_obj.to_int64())
        emit_i64_or(buf)
        buf.push((5).to_byte()) // else
        emit_i64_const_raw(buf, fallback_str)
        buf.push((11).to_byte()) // end if
        buf.push((11).to_byte()) // end if
        buf.push((11).to_byte()) // end if
      }
    }
    "String::length" => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "String::length", 1,
      )
      if ctx.use_js_strings {
        ctx.need_js_length = true
        compile_expr_ref(ctx, buf, pos_args[0])
        emit_call(buf, import_index_js_length(ctx))
        emit_i64_extend_i32_s(buf)
        emit_i64_const_raw(buf, 2L)
        emit_i64_shl(buf)
      } else {
        // Untag pointer to i32, load length, tag as i64
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_untag_ptr_i32(buf)
        emit_i32_load(buf, 4)
        emit_i64_extend_i32_s(buf)
        emit_i64_const_raw(buf, 2L)
        emit_i64_shl(buf)
        // tag_int = 0, i64.or is a no-op
      }
    }
    "String::char_code_at" => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "String::char_code_at", 2,
      )
      if ctx.use_js_strings {
        ctx.need_js_char_code_at = true
        compile_expr_ref(ctx, buf, pos_args[0])
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_untag_int_i32(buf)
        emit_call(buf, import_index_js_char_code_at(ctx))
        emit_i64_extend_i32_s(buf)
        emit_i64_const_raw(buf, 2L)
        emit_i64_shl(buf)
      } else {
        let str_ptr_local = alloc_temp_local(ctx)
        let str_len_local = alloc_temp_local(ctx)
        let idx_local = alloc_temp_local(ctx)
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_untag_ptr_i32(buf)
        emit_local_set(buf, str_ptr_local)
        emit_local_get(buf, str_ptr_local)
        emit_i32_load(buf, 4)
        emit_local_set(buf, str_len_local)
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_untag_int_i32(buf)
        emit_local_set(buf, idx_local)
        emit_local_get(buf, idx_local)
        emit_i32_const_raw(buf, 0)
        emit_i32_lt_s(buf)
        emit_local_get(buf, idx_local)
        emit_local_get(buf, str_len_local)
        emit_i32_lt_s(buf)
        emit_i32_eqz(buf)
        emit_i32_or(buf)
        buf.push((4).to_byte()) // if
        buf.push((126).to_byte()) // result i64
        emit_i64_const_tagged(buf, -1L)
        buf.push((5).to_byte()) // else
        emit_local_get(buf, str_ptr_local)
        emit_local_get(buf, idx_local)
        emit_i32_add(buf)
        emit_i32_load8_u(buf, 8)
        emit_i64_extend_i32_s(buf)
        emit_i64_const_raw(buf, 2L)
        emit_i64_shl(buf)
        // tag_int = 0, i64.or is a no-op
        buf.push((11).to_byte()) // end if
      }
    }
    "Int::parse" => {
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
    "Double::parse" => {
      // Double::parse(s: String) -> Option[Double]
      // Returns Some(double) on success, None on failure.
      let pos_args = extract_positional_exprs_with_arity(
        args, "Double::parse", 1,
      )
      if ctx.use_js_strings {
        raise WasmGenError::Unsupported("Double::parse with js strings")
      } else {
        require_heap(ctx)
        // Native string mode: byte-iterate and accumulate
        let str_ptr_local = alloc_temp_local(ctx)
        let str_len_local = alloc_temp_local(ctx)
        let idx_local = alloc_temp_local(ctx)
        let int_part_local = alloc_temp_local(ctx) // integer part (i32)
        let frac_part_local = alloc_temp_local(ctx) // fractional part (i32)
        let frac_div_local = alloc_temp_local(ctx) // fractional divisor (i32)
        let neg_local = alloc_temp_local(ctx) // sign flag
        let byte_local = alloc_temp_local(ctx)
        let valid_local = alloc_temp_local(ctx) // validity flag
        let has_digit_local = alloc_temp_local(ctx) // has at least one digit
        let boxed_f64_local = alloc_temp_local_with_kind(ctx, ValueKind::I64) // boxed f64 tagged ptr (i64)
        let obj_local = alloc_temp_local(ctx) // Option enum heap object

        // Untag pointer
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_untag_ptr_i32(buf)
        emit_local_set(buf, str_ptr_local)

        // Load string length
        emit_local_get(buf, str_ptr_local)
        emit_i32_load(buf, 4)
        emit_local_set(buf, str_len_local)

        // Initialize
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, int_part_local)
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, frac_part_local)
        emit_i32_const_raw(buf, 1)
        emit_local_set(buf, frac_div_local)
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, idx_local)
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, neg_local)
        emit_i32_const_raw(buf, 1)
        emit_local_set(buf, valid_local)
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, has_digit_local)

        // Skip leading spaces
        emit_block(buf)
        emit_loop(buf)
        emit_local_get(buf, idx_local)
        emit_local_get(buf, str_len_local)
        emit_i32_ge_s(buf)
        emit_br_if(buf, 1)
        emit_local_get(buf, str_ptr_local)
        emit_local_get(buf, idx_local)
        emit_i32_add(buf)
        emit_i32_load8_u(buf, 8)
        emit_i32_const_raw(buf, 32)
        emit_i32_ne(buf)
        emit_br_if(buf, 1)
        emit_local_get(buf, idx_local)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, idx_local)
        emit_br(buf, 0)
        emit_end(buf)
        emit_end(buf)

        // Check sign
        emit_block(buf)
        emit_local_get(buf, idx_local)
        emit_local_get(buf, str_len_local)
        emit_i32_ge_s(buf)
        emit_br_if(buf, 0)
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
        emit_br(buf, 1)
        emit_end(buf)
        emit_local_get(buf, byte_local)
        emit_i32_const_raw(buf, 43) // '+'
        emit_i32_eq(buf)
        emit_if(buf)
        emit_local_get(buf, idx_local)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, idx_local)
        emit_end(buf)
        emit_end(buf)

        // Parse integer part (digits before '.')
        emit_block(buf)
        emit_loop(buf)
        emit_local_get(buf, idx_local)
        emit_local_get(buf, str_len_local)
        emit_i32_ge_s(buf)
        emit_br_if(buf, 1)
        emit_local_get(buf, str_ptr_local)
        emit_local_get(buf, idx_local)
        emit_i32_add(buf)
        emit_i32_load8_u(buf, 8)
        emit_local_set(buf, byte_local)
        // if byte == '.' (46), break to fraction part
        emit_local_get(buf, byte_local)
        emit_i32_const_raw(buf, 46)
        emit_i32_eq(buf)
        emit_br_if(buf, 1)
        // if byte == ' ' (32), break (trailing space)
        emit_local_get(buf, byte_local)
        emit_i32_const_raw(buf, 32)
        emit_i32_eq(buf)
        emit_br_if(buf, 1)
        // Check if digit: byte < '0' or byte > '9' => invalid
        emit_local_get(buf, byte_local)
        emit_i32_const_raw(buf, 48)
        emit_i32_lt_s(buf)
        emit_if(buf)
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, valid_local)
        emit_br(buf, 2) // br $digit_done
        emit_end(buf)
        emit_local_get(buf, byte_local)
        emit_i32_const_raw(buf, 57)
        emit_i32_gt_s(buf)
        emit_if(buf)
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, valid_local)
        emit_br(buf, 2) // br $digit_done
        emit_end(buf)
        // int_part = int_part * 10 + (byte - 48)
        emit_i32_const_raw(buf, 1)
        emit_local_set(buf, has_digit_local)
        emit_local_get(buf, int_part_local)
        emit_i32_const_raw(buf, 10)
        emit_i32_mul(buf)
        emit_local_get(buf, byte_local)
        emit_i32_const_raw(buf, 48)
        emit_i32_sub(buf)
        emit_i32_add(buf)
        emit_local_set(buf, int_part_local)
        // idx++
        emit_local_get(buf, idx_local)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, idx_local)
        emit_br(buf, 0)
        emit_end(buf)
        emit_end(buf)

        // Skip '.' if present, then parse fractional digits
        emit_block(buf)
        emit_local_get(buf, idx_local)
        emit_local_get(buf, str_len_local)
        emit_i32_ge_s(buf)
        emit_br_if(buf, 0) // no more chars
        emit_local_get(buf, str_ptr_local)
        emit_local_get(buf, idx_local)
        emit_i32_add(buf)
        emit_i32_load8_u(buf, 8)
        emit_i32_const_raw(buf, 46) // '.'
        emit_i32_ne(buf)
        emit_br_if(buf, 0) // not a dot, skip fraction
        // skip the '.'
        emit_local_get(buf, idx_local)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, idx_local)
        // Parse fractional digits
        emit_block(buf) // block $frac_done
        emit_loop(buf) // loop $frac_loop
        emit_local_get(buf, idx_local)
        emit_local_get(buf, str_len_local)
        emit_i32_ge_s(buf)
        emit_br_if(buf, 1)
        emit_local_get(buf, str_ptr_local)
        emit_local_get(buf, idx_local)
        emit_i32_add(buf)
        emit_i32_load8_u(buf, 8)
        emit_local_set(buf, byte_local)
        // if byte == ' ' (space), break
        emit_local_get(buf, byte_local)
        emit_i32_const_raw(buf, 32)
        emit_i32_eq(buf)
        emit_br_if(buf, 1)
        // Check if digit
        emit_local_get(buf, byte_local)
        emit_i32_const_raw(buf, 48)
        emit_i32_lt_s(buf)
        emit_if(buf)
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, valid_local)
        emit_br(buf, 2) // br $frac_done
        emit_end(buf)
        emit_local_get(buf, byte_local)
        emit_i32_const_raw(buf, 57)
        emit_i32_gt_s(buf)
        emit_if(buf)
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, valid_local)
        emit_br(buf, 2) // br $frac_done
        emit_end(buf)
        // frac_part = frac_part * 10 + (byte - 48)
        emit_i32_const_raw(buf, 1)
        emit_local_set(buf, has_digit_local)
        emit_local_get(buf, frac_part_local)
        emit_i32_const_raw(buf, 10)
        emit_i32_mul(buf)
        emit_local_get(buf, byte_local)
        emit_i32_const_raw(buf, 48)
        emit_i32_sub(buf)
        emit_i32_add(buf)
        emit_local_set(buf, frac_part_local)
        // frac_div = frac_div * 10
        emit_local_get(buf, frac_div_local)
        emit_i32_const_raw(buf, 10)
        emit_i32_mul(buf)
        emit_local_set(buf, frac_div_local)
        // idx++
        emit_local_get(buf, idx_local)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, idx_local)
        emit_br(buf, 0)
        emit_end(buf) // end loop
        emit_end(buf) // end block $frac_done
        emit_end(buf) // end block (dot check)

        // Check valid && has_digit
        emit_local_get(buf, valid_local)
        emit_local_get(buf, has_digit_local)
        emit_i32_and(buf)
        buf.push((4).to_byte()) // if
        buf.push((126).to_byte()) // result i64

        // Build f64 result: (int_part + frac_part / frac_div) * sign
        // Box the f64, store tagged ptr in boxed_f64_local
        emit_boxed_f64_raise(ctx, buf, fn() {
          // f64(int_part)
          emit_local_get(buf, int_part_local)
          emit_i64_extend_i32_s(buf)
          emit_f64_convert_i64_s(buf)
          // f64(frac_part) / f64(frac_div)
          emit_local_get(buf, frac_part_local)
          emit_i64_extend_i32_s(buf)
          emit_f64_convert_i64_s(buf)
          emit_local_get(buf, frac_div_local)
          emit_i64_extend_i32_s(buf)
          emit_f64_convert_i64_s(buf)
          emit_f64_div(buf)
          // add int + frac
          emit_f64_add(buf)
          // apply sign
          emit_f64_const(buf, 1.0)
          emit_local_get(buf, neg_local)
          emit_i64_extend_i32_s(buf)
          emit_f64_convert_i64_s(buf)
          emit_f64_const(buf, 2.0)
          emit_f64_mul(buf)
          emit_f64_sub(buf)
          emit_f64_mul(buf)
        })
        emit_local_set(buf, boxed_f64_local)

        // Wrap in Some: enum obj with tag=1, payload=boxed_f64
        let some_size = align4(12 + 4) // obj_type(4) + arity(4) + enum_tag(4) + payload(4)
        emit_heap_alloc(ctx, buf, some_size, obj_local)
        emit_local_get(buf, obj_local)
        emit_i32_const_raw(buf, obj_enum)
        emit_i32_store(buf, 0)
        emit_local_get(buf, obj_local)
        emit_i32_const_raw(buf, 1) // arity = 1
        emit_i32_store(buf, 4)
        emit_local_get(buf, obj_local)
        emit_i32_const_raw(buf, 1) // Some tag = 1
        emit_i32_store(buf, 8)
        emit_local_get(buf, obj_local)
        emit_local_get(buf, boxed_f64_local)
        emit_i32_wrap_i64(buf)
        emit_i32_store(buf, 12)
        // Return tagged pointer
        emit_local_get(buf, obj_local)
        emit_i64_extend_i32_u(buf)
        emit_i64_const_raw(buf, tag_obj.to_int64())
        emit_i64_or(buf)

        emit_else(buf) // else: produce None

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
    "String::substring" => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "String::substring", 3,
      )
      if ctx.use_js_strings {
        ctx.need_js_substring = true
        compile_expr_ref(ctx, buf, pos_args[0])
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_untag_int_i32(buf)
        compile_expr_i32(ctx, buf, pos_args[2])
        emit_untag_int_i32(buf)
        emit_call(buf, import_index_js_substring(ctx))
      } else {
        require_heap(ctx)
        let str_ptr_local = alloc_temp_local(ctx)
        let str_len_local = alloc_temp_local(ctx)
        let start_local = alloc_temp_local(ctx)
        let end_local = alloc_temp_local(ctx)
        let sub_len_local = alloc_temp_local(ctx)
        let obj_local = alloc_temp_local(ctx)
        let alloc_size_local = alloc_temp_local(ctx)
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_untag_ptr_i32(buf)
        emit_local_set(buf, str_ptr_local)
        emit_local_get(buf, str_ptr_local)
        emit_i32_load(buf, 4)
        emit_local_set(buf, str_len_local)
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_untag_int_i32(buf)
        emit_local_set(buf, start_local)
        compile_expr_i32(ctx, buf, pos_args[2])
        emit_untag_int_i32(buf)
        emit_local_set(buf, end_local)
        emit_local_get(buf, start_local)
        emit_i32_const_raw(buf, 0)
        emit_i32_lt_s(buf)
        buf.push((4).to_byte()) // if
        buf.push((64).to_byte()) // void
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, start_local)
        buf.push((11).to_byte()) // end if
        emit_local_get(buf, str_len_local)
        emit_local_get(buf, start_local)
        emit_i32_lt_s(buf)
        buf.push((4).to_byte()) // if
        buf.push((64).to_byte()) // void
        emit_local_get(buf, str_len_local)
        emit_local_set(buf, start_local)
        buf.push((11).to_byte()) // end if
        emit_local_get(buf, end_local)
        emit_i32_const_raw(buf, 0)
        emit_i32_lt_s(buf)
        buf.push((4).to_byte()) // if
        buf.push((64).to_byte()) // void
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, end_local)
        buf.push((11).to_byte()) // end if
        emit_local_get(buf, str_len_local)
        emit_local_get(buf, end_local)
        emit_i32_lt_s(buf)
        buf.push((4).to_byte()) // if
        buf.push((64).to_byte()) // void
        emit_local_get(buf, str_len_local)
        emit_local_set(buf, end_local)
        buf.push((11).to_byte()) // end if
        emit_local_get(buf, end_local)
        emit_local_get(buf, start_local)
        emit_i32_lt_s(buf)
        buf.push((4).to_byte()) // if
        buf.push((64).to_byte()) // void
        emit_local_get(buf, start_local)
        emit_local_set(buf, end_local)
        buf.push((11).to_byte()) // end if
        emit_local_get(buf, end_local)
        emit_local_get(buf, start_local)
        emit_i32_sub(buf)
        emit_local_set(buf, sub_len_local)
        emit_local_get(buf, sub_len_local)
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
        emit_local_get(buf, sub_len_local)
        emit_i32_store(buf, 4)
        // memory.copy: dst=obj+8, src=str_ptr+8+start, len=sub_len
        emit_local_get(buf, obj_local)
        emit_i32_const_raw(buf, 8)
        emit_i32_add(buf)
        emit_local_get(buf, str_ptr_local)
        emit_i32_const_raw(buf, 8)
        emit_i32_add(buf)
        emit_local_get(buf, start_local)
        emit_i32_add(buf)
        emit_local_get(buf, sub_len_local)
        emit_memory_copy(buf)
        emit_local_get(buf, obj_local)
        emit_i64_extend_i32_u(buf)
        emit_i64_const_raw(buf, tag_obj.to_int64())
        emit_i64_or(buf)
      }
    }
    "String::concat" => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "String::concat", 2,
      )
      if ctx.use_js_strings {
        ctx.need_js_concat = true
        compile_expr_ref(ctx, buf, pos_args[0])
        compile_expr_ref(ctx, buf, pos_args[1])
        emit_call(buf, import_index_js_concat(ctx))
      } else {
        require_heap(ctx)
        let left_ptr_local = alloc_temp_local(ctx)
        let left_len_local = alloc_temp_local(ctx)
        let right_ptr_local = alloc_temp_local(ctx)
        let right_len_local = alloc_temp_local(ctx)
        let total_len_local = alloc_temp_local(ctx)
        let obj_local = alloc_temp_local(ctx)
        let alloc_size_local = alloc_temp_local(ctx)
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_untag_ptr_i32(buf)
        emit_local_set(buf, left_ptr_local)
        emit_local_get(buf, left_ptr_local)
        emit_i32_load(buf, 4)
        emit_local_set(buf, left_len_local)
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_untag_ptr_i32(buf)
        emit_local_set(buf, right_ptr_local)
        emit_local_get(buf, right_ptr_local)
        emit_i32_load(buf, 4)
        emit_local_set(buf, right_len_local)
        emit_local_get(buf, left_len_local)
        emit_local_get(buf, right_len_local)
        emit_i32_add(buf)
        emit_local_set(buf, total_len_local)
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
        // memory.copy left string bytes: dst=obj+8, src=left_ptr+8, len=left_len
        emit_local_get(buf, obj_local)
        emit_i32_const_raw(buf, 8)
        emit_i32_add(buf)
        emit_local_get(buf, left_ptr_local)
        emit_i32_const_raw(buf, 8)
        emit_i32_add(buf)
        emit_local_get(buf, left_len_local)
        emit_memory_copy(buf)
        // memory.copy right string bytes: dst=obj+8+left_len, src=right_ptr+8, len=right_len
        emit_local_get(buf, obj_local)
        emit_i32_const_raw(buf, 8)
        emit_i32_add(buf)
        emit_local_get(buf, left_len_local)
        emit_i32_add(buf)
        emit_local_get(buf, right_ptr_local)
        emit_i32_const_raw(buf, 8)
        emit_i32_add(buf)
        emit_local_get(buf, right_len_local)
        emit_memory_copy(buf)
        emit_local_get(buf, obj_local)
        emit_i64_extend_i32_u(buf)
        emit_i64_const_raw(buf, tag_obj.to_int64())
        emit_i64_or(buf)
      }
    }
    "String::join" => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "String::join", 2,
      )
      if ctx.use_js_strings {
        raise WasmGenError::BackendLimit(
          backend="wasm-js-string",
          feature="String::join",
        )
      } else {
        require_heap(ctx)
        let arr_ptr_local = alloc_temp_local(ctx)
        let arr_len_local = alloc_temp_local(ctx)
        let sep_ptr_local = alloc_temp_local(ctx)
        let sep_len_local = alloc_temp_local(ctx)
        let loop_i_local = alloc_temp_local(ctx)
        let total_len_local = alloc_temp_local(ctx)
        let alloc_size_local = alloc_temp_local(ctx)
        let obj_local = alloc_temp_local(ctx)
        let out_pos_local = alloc_temp_local(ctx)
        let elem_slot_local = alloc_temp_local(ctx)
        let elem_ptr_local = alloc_temp_local(ctx)
        let elem_len_local = alloc_temp_local(ctx)
        // arr pointer / length
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_untag_ptr_i32(buf)
        emit_local_set(buf, arr_ptr_local)
        emit_local_get(buf, arr_ptr_local)
        emit_i32_load(buf, 4)
        emit_local_set(buf, arr_len_local)
        // sep pointer / length
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_untag_ptr_i32(buf)
        emit_local_set(buf, sep_ptr_local)
        emit_local_get(buf, sep_ptr_local)
        emit_i32_load(buf, 4)
        emit_local_set(buf, sep_len_local)
        // total_len = sum(elem lengths) + sep * (len - 1)
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, total_len_local)
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, loop_i_local)
        emit_block(buf)
        emit_loop(buf)
        emit_local_get(buf, loop_i_local)
        emit_local_get(buf, arr_len_local)
        emit_i32_lt_s(buf)
        emit_i32_eqz(buf)
        emit_br_if(buf, 1)
        emit_local_get(buf, loop_i_local)
        emit_i32_const_raw(buf, 0)
        emit_i32_gt_s(buf)
        buf.push((4).to_byte()) // if
        buf.push((64).to_byte()) // void
        emit_local_get(buf, total_len_local)
        emit_local_get(buf, sep_len_local)
        emit_i32_add(buf)
        emit_local_set(buf, total_len_local)
        buf.push((11).to_byte()) // end if
        // elem = arr[i]
        emit_local_get(buf, arr_ptr_local)
        emit_local_get(buf, loop_i_local)
        emit_i32_const_raw(buf, 4)
        emit_i32_mul(buf)
        emit_i32_add(buf)
        emit_i32_load(buf, 8)
        emit_local_set(buf, elem_slot_local)
        // elem_ptr = untag(elem)
        emit_local_get(buf, elem_slot_local)
        emit_i32_const_raw(buf, -4)
        emit_i32_and(buf)
        emit_local_set(buf, elem_ptr_local)
        emit_local_get(buf, elem_ptr_local)
        emit_i32_load(buf, 4)
        emit_local_set(buf, elem_len_local)
        emit_local_get(buf, total_len_local)
        emit_local_get(buf, elem_len_local)
        emit_i32_add(buf)
        emit_local_set(buf, total_len_local)
        emit_local_get(buf, loop_i_local)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, loop_i_local)
        emit_br(buf, 0)
        emit_end(buf)
        emit_end(buf)
        // alloc_size = align4(8 + total_len)
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
        // Copy pass
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, out_pos_local)
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, loop_i_local)
        emit_block(buf)
        emit_loop(buf)
        emit_local_get(buf, loop_i_local)
        emit_local_get(buf, arr_len_local)
        emit_i32_lt_s(buf)
        emit_i32_eqz(buf)
        emit_br_if(buf, 1)
        // Add separator for i > 0
        emit_local_get(buf, loop_i_local)
        emit_i32_const_raw(buf, 0)
        emit_i32_gt_s(buf)
        buf.push((4).to_byte()) // if
        buf.push((64).to_byte()) // void
        // memory.copy separator: dst=obj+8+out_pos, src=sep_ptr+8, len=sep_len
        emit_local_get(buf, obj_local)
        emit_i32_const_raw(buf, 8)
        emit_i32_add(buf)
        emit_local_get(buf, out_pos_local)
        emit_i32_add(buf)
        emit_local_get(buf, sep_ptr_local)
        emit_i32_const_raw(buf, 8)
        emit_i32_add(buf)
        emit_local_get(buf, sep_len_local)
        emit_memory_copy(buf)
        emit_local_get(buf, out_pos_local)
        emit_local_get(buf, sep_len_local)
        emit_i32_add(buf)
        emit_local_set(buf, out_pos_local)
        buf.push((11).to_byte()) // end if
        // elem = arr[i]
        emit_local_get(buf, arr_ptr_local)
        emit_local_get(buf, loop_i_local)
        emit_i32_const_raw(buf, 4)
        emit_i32_mul(buf)
        emit_i32_add(buf)
        emit_i32_load(buf, 8)
        emit_local_set(buf, elem_slot_local)
        emit_local_get(buf, elem_slot_local)
        emit_i32_const_raw(buf, -4)
        emit_i32_and(buf)
        emit_local_set(buf, elem_ptr_local)
        emit_local_get(buf, elem_ptr_local)
        emit_i32_load(buf, 4)
        emit_local_set(buf, elem_len_local)
        // memory.copy element: dst=obj+8+out_pos, src=elem_ptr+8, len=elem_len
        emit_local_get(buf, obj_local)
        emit_i32_const_raw(buf, 8)
        emit_i32_add(buf)
        emit_local_get(buf, out_pos_local)
        emit_i32_add(buf)
        emit_local_get(buf, elem_ptr_local)
        emit_i32_const_raw(buf, 8)
        emit_i32_add(buf)
        emit_local_get(buf, elem_len_local)
        emit_memory_copy(buf)
        emit_local_get(buf, out_pos_local)
        emit_local_get(buf, elem_len_local)
        emit_i32_add(buf)
        emit_local_set(buf, out_pos_local)
        emit_local_get(buf, loop_i_local)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, loop_i_local)
        emit_br(buf, 0)
        emit_end(buf)
        emit_end(buf)
        emit_local_get(buf, obj_local)
        emit_i64_extend_i32_u(buf)
        emit_i64_const_raw(buf, tag_obj.to_int64())
        emit_i64_or(buf)
      }
    }
    "String::equals" => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "String::equals", 2,
      )
      if ctx.use_js_strings {
        ctx.need_js_equals = true
        compile_expr_ref(ctx, buf, pos_args[0])
        compile_expr_ref(ctx, buf, pos_args[1])
        emit_call(buf, import_index_js_equals(ctx))
        emit_tag_bool_from_i32(buf)
      } else {
        let left_ptr_local = alloc_temp_local(ctx)
        let right_ptr_local = alloc_temp_local(ctx)
        let left_len_local = alloc_temp_local(ctx)
        let right_len_local = alloc_temp_local(ctx)
        let loop_i_local = alloc_temp_local(ctx)
        let eq_local = alloc_temp_local(ctx)
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_untag_ptr_i32(buf)
        emit_local_set(buf, left_ptr_local)
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_untag_ptr_i32(buf)
        emit_local_set(buf, right_ptr_local)
        emit_local_get(buf, left_ptr_local)
        emit_local_get(buf, right_ptr_local)
        emit_i32_eq(buf)
        buf.push((4).to_byte()) // if
        buf.push((127).to_byte()) // result i32
        emit_i32_const_raw(buf, 1)
        buf.push((5).to_byte()) // else
        emit_local_get(buf, left_ptr_local)
        emit_i32_load(buf, 4)
        emit_local_set(buf, left_len_local)
        emit_local_get(buf, right_ptr_local)
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
        emit_local_get(buf, left_ptr_local)
        emit_local_get(buf, loop_i_local)
        emit_i32_add(buf)
        emit_i32_load8_u(buf, 8)
        emit_local_get(buf, right_ptr_local)
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
        emit_tag_bool_from_i32(buf)
      }
    }
    "String::index_of" => {
      // string_index_of(str, sub) -> Int (byte offset or -1)
      let pos_args = extract_positional_exprs_with_arity(
        args, "String::index_of", 2,
      )
      if ctx.use_js_strings {
        raise WasmGenError::BackendLimit(
          backend="wasm-js-string",
          feature="String::index_of",
        )
      } else {
        let str_ptr = alloc_temp_local(ctx)
        let str_len = alloc_temp_local(ctx)
        let sub_ptr = alloc_temp_local(ctx)
        let sub_len = alloc_temp_local(ctx)
        let outer_i = alloc_temp_local(ctx)
        let inner_j = alloc_temp_local(ctx)
        let result_local = alloc_temp_local(ctx)
        let matched = alloc_temp_local(ctx)
        let limit_local = alloc_temp_local(ctx)
        // get str pointer and length
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_untag_ptr_i32(buf)
        emit_local_set(buf, str_ptr)
        emit_local_get(buf, str_ptr)
        emit_i32_load(buf, 4)
        emit_local_set(buf, str_len)
        // get sub pointer and length
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_untag_ptr_i32(buf)
        emit_local_set(buf, sub_ptr)
        emit_local_get(buf, sub_ptr)
        emit_i32_load(buf, 4)
        emit_local_set(buf, sub_len)
        // result = -1 (not found)
        emit_i32_const_raw(buf, -1)
        emit_local_set(buf, result_local)
        // limit = str_len - sub_len + 1
        emit_local_get(buf, str_len)
        emit_local_get(buf, sub_len)
        emit_i32_sub(buf)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, limit_local)
        // if sub_len > str_len, skip search (limit <= 0)
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, outer_i)
        emit_block(buf) // block (for breaking when found)
        emit_loop(buf) // outer loop
        // if outer_i >= limit, break
        emit_local_get(buf, outer_i)
        emit_local_get(buf, limit_local)
        emit_i32_lt_s(buf)
        emit_i32_eqz(buf)
        emit_br_if(buf, 1) // break to block
        // check if all sub bytes match at position outer_i
        emit_i32_const_raw(buf, 1)
        emit_local_set(buf, matched)
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, inner_j)
        emit_block(buf) // inner block (for breaking when mismatch)
        emit_loop(buf) // inner loop
        emit_local_get(buf, inner_j)
        emit_local_get(buf, sub_len)
        emit_i32_lt_s(buf)
        emit_i32_eqz(buf)
        emit_br_if(buf, 1) // break inner block (all matched)
        // compare str[outer_i + inner_j] == sub[inner_j]
        emit_local_get(buf, str_ptr)
        emit_local_get(buf, outer_i)
        emit_i32_add(buf)
        emit_local_get(buf, inner_j)
        emit_i32_add(buf)
        emit_i32_load8_u(buf, 8) // str byte
        emit_local_get(buf, sub_ptr)
        emit_local_get(buf, inner_j)
        emit_i32_add(buf)
        emit_i32_load8_u(buf, 8) // sub byte
        emit_i32_eq(buf)
        emit_i32_eqz(buf)
        buf.push((4).to_byte()) // if (not equal)
        buf.push((64).to_byte()) // void
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, matched)
        emit_br(buf, 2) // break inner block
        buf.push((11).to_byte()) // end if
        // inner_j++
        emit_local_get(buf, inner_j)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, inner_j)
        emit_br(buf, 0) // continue inner loop
        emit_end(buf) // end inner loop
        emit_end(buf) // end inner block
        // if matched, set result and break outer
        emit_local_get(buf, matched)
        buf.push((4).to_byte()) // if
        buf.push((64).to_byte()) // void
        emit_local_get(buf, outer_i)
        emit_local_set(buf, result_local)
        emit_br(buf, 2) // break outer block (depth: 0=if, 1=loop, 2=block)
        buf.push((11).to_byte()) // end if
        // outer_i++
        emit_local_get(buf, outer_i)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, outer_i)
        emit_br(buf, 0) // continue outer loop
        emit_end(buf) // end outer loop
        emit_end(buf) // end outer block
        // tag result as int
        emit_local_get(buf, result_local)
        emit_i64_extend_i32_s(buf)
        emit_i64_const_raw(buf, 2L)
        emit_i64_shl(buf)
        // tag_int = 0, i64.or is a no-op
      }
    }
    "String::contains" if not(is_user_fn) => {
      // string_contains(str, sub) -> Bool
      // Reuses the same substring search as string_index_of but returns bool.
      let pos_args = extract_positional_exprs_with_arity(
        args, "String::contains", 2,
      )
      if ctx.use_js_strings {
        raise WasmGenError::BackendLimit(
          backend="wasm-js-string",
          feature="String::contains",
        )
      } else {
        let str_ptr = alloc_temp_local(ctx)
        let str_len = alloc_temp_local(ctx)
        let sub_ptr = alloc_temp_local(ctx)
        let sub_len = alloc_temp_local(ctx)
        let outer_i = alloc_temp_local(ctx)
        let inner_j = alloc_temp_local(ctx)
        let result_local = alloc_temp_local(ctx)
        let matched = alloc_temp_local(ctx)
        let limit_local = alloc_temp_local(ctx)
        // get str pointer and length
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_untag_ptr_i32(buf)
        emit_local_set(buf, str_ptr)
        emit_local_get(buf, str_ptr)
        emit_i32_load(buf, 4)
        emit_local_set(buf, str_len)
        // get sub pointer and length
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_untag_ptr_i32(buf)
        emit_local_set(buf, sub_ptr)
        emit_local_get(buf, sub_ptr)
        emit_i32_load(buf, 4)
        emit_local_set(buf, sub_len)
        // result = 0 (not found / false)
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, result_local)
        // limit = str_len - sub_len + 1
        emit_local_get(buf, str_len)
        emit_local_get(buf, sub_len)
        emit_i32_sub(buf)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, limit_local)
        // if sub_len > str_len, skip search (limit <= 0)
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, outer_i)
        emit_block(buf) // block (for breaking when found)
        emit_loop(buf) // outer loop
        // if outer_i >= limit, break
        emit_local_get(buf, outer_i)
        emit_local_get(buf, limit_local)
        emit_i32_lt_s(buf)
        emit_i32_eqz(buf)
        emit_br_if(buf, 1) // break to block
        // check if all sub bytes match at position outer_i
        emit_i32_const_raw(buf, 1)
        emit_local_set(buf, matched)
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, inner_j)
        emit_block(buf) // inner block (for breaking when mismatch)
        emit_loop(buf) // inner loop
        emit_local_get(buf, inner_j)
        emit_local_get(buf, sub_len)
        emit_i32_lt_s(buf)
        emit_i32_eqz(buf)
        emit_br_if(buf, 1) // break inner block (all matched)
        // compare str[outer_i + inner_j] == sub[inner_j]
        emit_local_get(buf, str_ptr)
        emit_local_get(buf, outer_i)
        emit_i32_add(buf)
        emit_local_get(buf, inner_j)
        emit_i32_add(buf)
        emit_i32_load8_u(buf, 8) // str byte
        emit_local_get(buf, sub_ptr)
        emit_local_get(buf, inner_j)
        emit_i32_add(buf)
        emit_i32_load8_u(buf, 8) // sub byte
        emit_i32_eq(buf)
        emit_i32_eqz(buf)
        buf.push((4).to_byte()) // if (not equal)
        buf.push((64).to_byte()) // void
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, matched)
        emit_br(buf, 2) // break inner block
        buf.push((11).to_byte()) // end if
        // inner_j++
        emit_local_get(buf, inner_j)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, inner_j)
        emit_br(buf, 0) // continue inner loop
        emit_end(buf) // end inner loop
        emit_end(buf) // end inner block
        // if matched, set result=1 and break outer
        emit_local_get(buf, matched)
        buf.push((4).to_byte()) // if
        buf.push((64).to_byte()) // void
        emit_i32_const_raw(buf, 1)
        emit_local_set(buf, result_local)
        emit_br(buf, 2) // break outer block (depth: 0=if, 1=loop, 2=block)
        buf.push((11).to_byte()) // end if
        // outer_i++
        emit_local_get(buf, outer_i)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, outer_i)
        emit_br(buf, 0) // continue outer loop
        emit_end(buf) // end outer loop
        emit_end(buf) // end outer block
        // tag result as bool
        emit_local_get(buf, result_local)
        emit_tag_bool_from_i32(buf)
      }
    }
    "String::starts_with" if not(is_user_fn) => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "String::starts_with", 2,
      )
      if ctx.use_js_strings {
        raise WasmGenError::BackendLimit(
          backend="wasm-js-string",
          feature="String::starts_with",
        )
      } else {
        let str_ptr_local = alloc_temp_local(ctx)
        let str_len_local = alloc_temp_local(ctx)
        let prefix_ptr_local = alloc_temp_local(ctx)
        let prefix_len_local = alloc_temp_local(ctx)
        let loop_i_local = alloc_temp_local(ctx)
        let result_local = alloc_temp_local(ctx)
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_untag_ptr_i32(buf)
        emit_local_set(buf, str_ptr_local)
        emit_local_get(buf, str_ptr_local)
        emit_i32_load(buf, 4)
        emit_local_set(buf, str_len_local)
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_untag_ptr_i32(buf)
        emit_local_set(buf, prefix_ptr_local)
        emit_local_get(buf, prefix_ptr_local)
        emit_i32_load(buf, 4)
        emit_local_set(buf, prefix_len_local)
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, result_local)
        emit_local_get(buf, prefix_len_local)
        emit_local_get(buf, str_len_local)
        emit_i32_le_s(buf)
        buf.push((4).to_byte()) // if
        buf.push((64).to_byte()) // void
        emit_i32_const_raw(buf, 1)
        emit_local_set(buf, result_local)
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, loop_i_local)
        emit_block(buf)
        emit_loop(buf)
        emit_local_get(buf, loop_i_local)
        emit_local_get(buf, prefix_len_local)
        emit_i32_lt_s(buf)
        emit_i32_eqz(buf)
        emit_br_if(buf, 1)
        emit_local_get(buf, str_ptr_local)
        emit_local_get(buf, loop_i_local)
        emit_i32_add(buf)
        emit_i32_load8_u(buf, 8)
        emit_local_get(buf, prefix_ptr_local)
        emit_local_get(buf, loop_i_local)
        emit_i32_add(buf)
        emit_i32_load8_u(buf, 8)
        emit_i32_eq(buf)
        emit_i32_eqz(buf)
        buf.push((4).to_byte()) // if
        buf.push((64).to_byte()) // void
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, result_local)
        emit_local_get(buf, prefix_len_local)
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
        buf.push((11).to_byte()) // end if
        emit_local_get(buf, result_local)
        emit_tag_bool_from_i32(buf)
      }
    }
    "String::ends_with" if not(is_user_fn) => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "String::ends_with", 2,
      )
      if ctx.use_js_strings {
        raise WasmGenError::BackendLimit(
          backend="wasm-js-string",
          feature="String::ends_with",
        )
      } else {
        let str_ptr_local = alloc_temp_local(ctx)
        let str_len_local = alloc_temp_local(ctx)
        let suffix_ptr_local = alloc_temp_local(ctx)
        let suffix_len_local = alloc_temp_local(ctx)
        let start_local = alloc_temp_local(ctx)
        let loop_i_local = alloc_temp_local(ctx)
        let result_local = alloc_temp_local(ctx)
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_untag_ptr_i32(buf)
        emit_local_set(buf, str_ptr_local)
        emit_local_get(buf, str_ptr_local)
        emit_i32_load(buf, 4)
        emit_local_set(buf, str_len_local)
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_untag_ptr_i32(buf)
        emit_local_set(buf, suffix_ptr_local)
        emit_local_get(buf, suffix_ptr_local)
        emit_i32_load(buf, 4)
        emit_local_set(buf, suffix_len_local)
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, result_local)
        emit_local_get(buf, suffix_len_local)
        emit_local_get(buf, str_len_local)
        emit_i32_le_s(buf)
        buf.push((4).to_byte()) // if
        buf.push((64).to_byte()) // void
        emit_local_get(buf, str_len_local)
        emit_local_get(buf, suffix_len_local)
        emit_i32_sub(buf)
        emit_local_set(buf, start_local)
        emit_i32_const_raw(buf, 1)
        emit_local_set(buf, result_local)
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, loop_i_local)
        emit_block(buf)
        emit_loop(buf)
        emit_local_get(buf, loop_i_local)
        emit_local_get(buf, suffix_len_local)
        emit_i32_lt_s(buf)
        emit_i32_eqz(buf)
        emit_br_if(buf, 1)
        emit_local_get(buf, str_ptr_local)
        emit_local_get(buf, start_local)
        emit_i32_add(buf)
        emit_local_get(buf, loop_i_local)
        emit_i32_add(buf)
        emit_i32_load8_u(buf, 8)
        emit_local_get(buf, suffix_ptr_local)
        emit_local_get(buf, loop_i_local)
        emit_i32_add(buf)
        emit_i32_load8_u(buf, 8)
        emit_i32_eq(buf)
        emit_i32_eqz(buf)
        buf.push((4).to_byte()) // if
        buf.push((64).to_byte()) // void
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, result_local)
        emit_local_get(buf, suffix_len_local)
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
        buf.push((11).to_byte()) // end if
        emit_local_get(buf, result_local)
        emit_tag_bool_from_i32(buf)
      }
    }
    "String::last_index_of" if not(is_user_fn) => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "String::last_index_of", 2,
      )
      if ctx.use_js_strings {
        raise WasmGenError::BackendLimit(
          backend="wasm-js-string",
          feature="String::last_index_of",
        )
      } else {
        let str_ptr_local = alloc_temp_local(ctx)
        let str_len_local = alloc_temp_local(ctx)
        let sub_ptr_local = alloc_temp_local(ctx)
        let sub_len_local = alloc_temp_local(ctx)
        let loop_i_local = alloc_temp_local(ctx)
        let inner_j_local = alloc_temp_local(ctx)
        let matched_local = alloc_temp_local(ctx)
        let result_local = alloc_temp_local(ctx)
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_untag_ptr_i32(buf)
        emit_local_set(buf, str_ptr_local)
        emit_local_get(buf, str_ptr_local)
        emit_i32_load(buf, 4)
        emit_local_set(buf, str_len_local)
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_untag_ptr_i32(buf)
        emit_local_set(buf, sub_ptr_local)
        emit_local_get(buf, sub_ptr_local)
        emit_i32_load(buf, 4)
        emit_local_set(buf, sub_len_local)
        emit_i32_const_raw(buf, -1)
        emit_local_set(buf, result_local)
        emit_local_get(buf, sub_len_local)
        emit_local_get(buf, str_len_local)
        emit_i32_le_s(buf)
        buf.push((4).to_byte()) // if
        buf.push((64).to_byte()) // void
        emit_local_get(buf, sub_len_local)
        emit_i32_eqz(buf)
        buf.push((4).to_byte()) // if
        buf.push((64).to_byte()) // void
        emit_local_get(buf, str_len_local)
        emit_local_set(buf, result_local)
        buf.push((5).to_byte()) // else
        emit_local_get(buf, str_len_local)
        emit_local_get(buf, sub_len_local)
        emit_i32_sub(buf)
        emit_local_set(buf, loop_i_local)
        emit_block(buf)
        emit_loop(buf)
        emit_local_get(buf, loop_i_local)
        emit_i32_const_raw(buf, 0)
        emit_i32_lt_s(buf)
        emit_br_if(buf, 1)
        emit_i32_const_raw(buf, 1)
        emit_local_set(buf, matched_local)
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, inner_j_local)
        emit_block(buf)
        emit_loop(buf)
        emit_local_get(buf, inner_j_local)
        emit_local_get(buf, sub_len_local)
        emit_i32_lt_s(buf)
        emit_i32_eqz(buf)
        emit_br_if(buf, 1)
        emit_local_get(buf, str_ptr_local)
        emit_local_get(buf, loop_i_local)
        emit_i32_add(buf)
        emit_local_get(buf, inner_j_local)
        emit_i32_add(buf)
        emit_i32_load8_u(buf, 8)
        emit_local_get(buf, sub_ptr_local)
        emit_local_get(buf, inner_j_local)
        emit_i32_add(buf)
        emit_i32_load8_u(buf, 8)
        emit_i32_eq(buf)
        emit_i32_eqz(buf)
        buf.push((4).to_byte()) // if
        buf.push((64).to_byte()) // void
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, matched_local)
        emit_local_get(buf, sub_len_local)
        emit_local_set(buf, inner_j_local)
        buf.push((5).to_byte()) // else
        emit_local_get(buf, inner_j_local)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, inner_j_local)
        buf.push((11).to_byte()) // end if
        emit_br(buf, 0)
        emit_end(buf)
        emit_end(buf)
        emit_local_get(buf, matched_local)
        buf.push((4).to_byte()) // if
        buf.push((64).to_byte()) // void
        emit_local_get(buf, loop_i_local)
        emit_local_set(buf, result_local)
        emit_br(buf, 2)
        buf.push((11).to_byte()) // end if
        emit_local_get(buf, loop_i_local)
        emit_i32_const_raw(buf, 1)
        emit_i32_sub(buf)
        emit_local_set(buf, loop_i_local)
        emit_br(buf, 0)
        emit_end(buf)
        emit_end(buf)
        buf.push((11).to_byte()) // end if
        buf.push((11).to_byte()) // end if
        emit_local_get(buf, result_local)
        emit_i64_extend_i32_s(buf)
        emit_i64_const_raw(buf, 2L)
        emit_i64_shl(buf)
        // tag_int = 0, i64.or is a no-op
      }
    }
    "String::count" if not(is_user_fn) => {
      // string_count(str, sub) -> Int (non-overlapping count)
      let pos_args = extract_positional_exprs_with_arity(
        args, "String::count", 2,
      )
      if ctx.use_js_strings {
        raise WasmGenError::BackendLimit(
          backend="wasm-js-string",
          feature="String::count",
        )
      } else {
        let str_ptr = alloc_temp_local(ctx)
        let str_len = alloc_temp_local(ctx)
        let sub_ptr = alloc_temp_local(ctx)
        let sub_len = alloc_temp_local(ctx)
        let outer_i = alloc_temp_local(ctx)
        let inner_j = alloc_temp_local(ctx)
        let count_local = alloc_temp_local(ctx)
        let matched = alloc_temp_local(ctx)
        let limit_local = alloc_temp_local(ctx)
        // get str pointer and length
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_untag_ptr_i32(buf)
        emit_local_set(buf, str_ptr)
        emit_local_get(buf, str_ptr)
        emit_i32_load(buf, 4)
        emit_local_set(buf, str_len)
        // get sub pointer and length
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_untag_ptr_i32(buf)
        emit_local_set(buf, sub_ptr)
        emit_local_get(buf, sub_ptr)
        emit_i32_load(buf, 4)
        emit_local_set(buf, sub_len)
        // count = 0
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, count_local)
        // limit = str_len - sub_len + 1 (if sub_len == 0 or sub_len > str_len, skip)
        emit_local_get(buf, sub_len)
        emit_i32_eqz(buf)
        buf.push((4).to_byte()) // if sub_len == 0
        buf.push((64).to_byte()) // void
        // sub_len == 0 → count = 0, skip
        buf.push((5).to_byte()) // else
        emit_local_get(buf, str_len)
        emit_local_get(buf, sub_len)
        emit_i32_sub(buf)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, limit_local)
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, outer_i)
        emit_block(buf) // outer block (exit search)
        emit_loop(buf) // outer loop
        // if outer_i >= limit, break
        emit_local_get(buf, outer_i)
        emit_local_get(buf, limit_local)
        emit_i32_lt_s(buf)
        emit_i32_eqz(buf)
        emit_br_if(buf, 1) // break to outer block
        // check if all sub bytes match at position outer_i
        emit_i32_const_raw(buf, 1)
        emit_local_set(buf, matched)
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, inner_j)
        emit_block(buf) // inner block
        emit_loop(buf) // inner loop
        emit_local_get(buf, inner_j)
        emit_local_get(buf, sub_len)
        emit_i32_lt_s(buf)
        emit_i32_eqz(buf)
        emit_br_if(buf, 1) // break inner block (all matched)
        // compare str[outer_i + inner_j] == sub[inner_j]
        emit_local_get(buf, str_ptr)
        emit_local_get(buf, outer_i)
        emit_i32_add(buf)
        emit_local_get(buf, inner_j)
        emit_i32_add(buf)
        emit_i32_load8_u(buf, 8)
        emit_local_get(buf, sub_ptr)
        emit_local_get(buf, inner_j)
        emit_i32_add(buf)
        emit_i32_load8_u(buf, 8)
        emit_i32_eq(buf)
        emit_i32_eqz(buf)
        buf.push((4).to_byte()) // if (not equal)
        buf.push((64).to_byte()) // void
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, matched)
        emit_br(buf, 2) // break inner block
        buf.push((11).to_byte()) // end if
        // inner_j++
        emit_local_get(buf, inner_j)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, inner_j)
        emit_br(buf, 0) // continue inner loop
        emit_end(buf) // end inner loop
        emit_end(buf) // end inner block
        // if matched, count++ and advance by sub_len (non-overlapping)
        emit_local_get(buf, matched)
        buf.push((4).to_byte()) // if
        buf.push((64).to_byte()) // void
        emit_local_get(buf, count_local)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, count_local)
        emit_local_get(buf, outer_i)
        emit_local_get(buf, sub_len)
        emit_i32_add(buf)
        emit_local_set(buf, outer_i)
        emit_br(buf, 1) // continue outer loop (skip outer_i++ below)
        buf.push((11).to_byte()) // end if
        // outer_i++ (no match case)
        emit_local_get(buf, outer_i)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, outer_i)
        emit_br(buf, 0) // continue outer loop
        emit_end(buf) // end outer loop
        emit_end(buf) // end outer block
        buf.push((11).to_byte()) // end else (sub_len != 0)
        // tag count as int
        emit_local_get(buf, count_local)
        emit_i64_extend_i32_s(buf)
        emit_i64_const_raw(buf, 2L)
        emit_i64_shl(buf)
        // tag_int = 0, i64.or is a no-op
      }
    }
    "String::trim" if not(is_user_fn) => {
      // string_trim(str) -> String (trim ASCII whitespace from both ends)
      let pos_args = extract_positional_exprs_with_arity(
        args, "String::trim", 1,
      )
      if ctx.use_js_strings {
        raise WasmGenError::BackendLimit(
          backend="wasm-js-string",
          feature="String::trim",
        )
      } else {
        require_heap(ctx)
        let str_ptr = alloc_temp_local(ctx)
        let str_len = alloc_temp_local(ctx)
        let start_local = alloc_temp_local(ctx)
        let end_local = alloc_temp_local(ctx)
        let new_len = alloc_temp_local(ctx)
        let new_ptr = alloc_temp_local(ctx)
        let copy_i = alloc_temp_local(ctx)
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_untag_ptr_i32(buf)
        emit_local_set(buf, str_ptr)
        emit_local_get(buf, str_ptr)
        emit_i32_load(buf, 4)
        emit_local_set(buf, str_len)
        // start = 0; scan forward while whitespace
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, start_local)
        emit_block(buf)
        emit_loop(buf)
        emit_local_get(buf, start_local)
        emit_local_get(buf, str_len)
        emit_i32_lt_s(buf)
        emit_i32_eqz(buf)
        emit_br_if(buf, 1) // break if start >= len
        emit_local_get(buf, str_ptr)
        emit_local_get(buf, start_local)
        emit_i32_add(buf)
        emit_i32_load8_u(buf, 8)
        // check if byte <= 32 (space, tab, newline, cr)
        emit_i32_const_raw(buf, 32)
        emit_i32_gt_u(buf) // byte > 32 means non-whitespace
        emit_br_if(buf, 1) // break if non-whitespace
        emit_local_get(buf, start_local)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, start_local)
        emit_br(buf, 0)
        emit_end(buf)
        emit_end(buf)
        // end = str_len; scan backward while whitespace
        emit_local_get(buf, str_len)
        emit_local_set(buf, end_local)
        emit_block(buf)
        emit_loop(buf)
        emit_local_get(buf, end_local)
        emit_local_get(buf, start_local)
        emit_i32_gt_s(buf)
        emit_i32_eqz(buf)
        emit_br_if(buf, 1) // break if end <= start
        emit_local_get(buf, str_ptr)
        emit_local_get(buf, end_local)
        emit_i32_const_raw(buf, 1)
        emit_i32_sub(buf)
        emit_i32_add(buf)
        emit_i32_load8_u(buf, 8)
        emit_i32_const_raw(buf, 32)
        emit_i32_gt_u(buf)
        emit_br_if(buf, 1) // break if non-whitespace
        emit_local_get(buf, end_local)
        emit_i32_const_raw(buf, 1)
        emit_i32_sub(buf)
        emit_local_set(buf, end_local)
        emit_br(buf, 0)
        emit_end(buf)
        emit_end(buf)
        // new_len = end - start
        emit_local_get(buf, end_local)
        emit_local_get(buf, start_local)
        emit_i32_sub(buf)
        emit_local_set(buf, new_len)
        // allocate new string object: [type:i32, len:i32, bytes...]
        let obj_size_local = alloc_temp_local(ctx)
        emit_local_get(buf, new_len)
        emit_i32_const_raw(buf, 8) // header size
        emit_i32_add(buf)
        emit_local_set(buf, obj_size_local)
        emit_local_get(buf, obj_size_local)
        emit_i32_const_raw(buf, 3)
        emit_i32_add(buf)
        emit_i32_const_raw(buf, -4)
        emit_i32_and(buf)
        emit_local_set(buf, obj_size_local)
        emit_heap_alloc_local(ctx, buf, obj_size_local, new_ptr)
        // set type = obj_string
        emit_local_get(buf, new_ptr)
        emit_i32_const_raw(buf, obj_string)
        emit_i32_store(buf, 0)
        // set length
        emit_local_get(buf, new_ptr)
        emit_local_get(buf, new_len)
        emit_i32_store(buf, 4)
        // copy bytes
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, copy_i)
        emit_block(buf)
        emit_loop(buf)
        emit_local_get(buf, copy_i)
        emit_local_get(buf, new_len)
        emit_i32_lt_s(buf)
        emit_i32_eqz(buf)
        emit_br_if(buf, 1)
        emit_local_get(buf, new_ptr)
        emit_local_get(buf, copy_i)
        emit_i32_add(buf)
        emit_local_get(buf, str_ptr)
        emit_local_get(buf, start_local)
        emit_i32_add(buf)
        emit_local_get(buf, copy_i)
        emit_i32_add(buf)
        emit_i32_load8_u(buf, 8)
        emit_i32_store8(buf, 8)
        emit_local_get(buf, copy_i)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, copy_i)
        emit_br(buf, 0)
        emit_end(buf)
        emit_end(buf)
        // tag as obj pointer
        emit_local_get(buf, new_ptr)
        emit_i64_extend_i32_u(buf)
        emit_i64_const_raw(buf, tag_obj.to_int64())
        emit_i64_or(buf)
      }
    }
    "String::trim_start" if not(is_user_fn) => {
      // string_trim_start(str) -> String (trim leading whitespace)
      let pos_args = extract_positional_exprs_with_arity(
        args, "String::trim_start", 1,
      )
      if ctx.use_js_strings {
        raise WasmGenError::BackendLimit(
          backend="wasm-js-string",
          feature="String::trim_start",
        )
      } else {
        require_heap(ctx)
        let str_ptr = alloc_temp_local(ctx)
        let str_len = alloc_temp_local(ctx)
        let start_local = alloc_temp_local(ctx)
        let new_len = alloc_temp_local(ctx)
        let new_ptr = alloc_temp_local(ctx)
        let copy_i = alloc_temp_local(ctx)
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_untag_ptr_i32(buf)
        emit_local_set(buf, str_ptr)
        emit_local_get(buf, str_ptr)
        emit_i32_load(buf, 4)
        emit_local_set(buf, str_len)
        // start = 0; scan forward while whitespace
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, start_local)
        emit_block(buf)
        emit_loop(buf)
        emit_local_get(buf, start_local)
        emit_local_get(buf, str_len)
        emit_i32_lt_s(buf)
        emit_i32_eqz(buf)
        emit_br_if(buf, 1)
        emit_local_get(buf, str_ptr)
        emit_local_get(buf, start_local)
        emit_i32_add(buf)
        emit_i32_load8_u(buf, 8)
        emit_i32_const_raw(buf, 32)
        emit_i32_gt_u(buf)
        emit_br_if(buf, 1)
        emit_local_get(buf, start_local)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, start_local)
        emit_br(buf, 0)
        emit_end(buf)
        emit_end(buf)
        // new_len = str_len - start
        emit_local_get(buf, str_len)
        emit_local_get(buf, start_local)
        emit_i32_sub(buf)
        emit_local_set(buf, new_len)
        // allocate new string
        let obj_size_local = alloc_temp_local(ctx)
        emit_local_get(buf, new_len)
        emit_i32_const_raw(buf, 8)
        emit_i32_add(buf)
        emit_local_set(buf, obj_size_local)
        emit_local_get(buf, obj_size_local)
        emit_i32_const_raw(buf, 3)
        emit_i32_add(buf)
        emit_i32_const_raw(buf, -4)
        emit_i32_and(buf)
        emit_local_set(buf, obj_size_local)
        emit_heap_alloc_local(ctx, buf, obj_size_local, new_ptr)
        emit_local_get(buf, new_ptr)
        emit_i32_const_raw(buf, obj_string)
        emit_i32_store(buf, 0)
        emit_local_get(buf, new_ptr)
        emit_local_get(buf, new_len)
        emit_i32_store(buf, 4)
        // copy bytes
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, copy_i)
        emit_block(buf)
        emit_loop(buf)
        emit_local_get(buf, copy_i)
        emit_local_get(buf, new_len)
        emit_i32_lt_s(buf)
        emit_i32_eqz(buf)
        emit_br_if(buf, 1)
        emit_local_get(buf, new_ptr)
        emit_local_get(buf, copy_i)
        emit_i32_add(buf)
        emit_local_get(buf, str_ptr)
        emit_local_get(buf, start_local)
        emit_i32_add(buf)
        emit_local_get(buf, copy_i)
        emit_i32_add(buf)
        emit_i32_load8_u(buf, 8)
        emit_i32_store8(buf, 8)
        emit_local_get(buf, copy_i)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, copy_i)
        emit_br(buf, 0)
        emit_end(buf)
        emit_end(buf)
        emit_local_get(buf, new_ptr)
        emit_i64_extend_i32_u(buf)
        emit_i64_const_raw(buf, tag_obj.to_int64())
        emit_i64_or(buf)
      }
    }
    "String::trim_end" if not(is_user_fn) => {
      // string_trim_end(str) -> String (trim trailing whitespace)
      let pos_args = extract_positional_exprs_with_arity(
        args, "String::trim_end", 1,
      )
      if ctx.use_js_strings {
        raise WasmGenError::BackendLimit(
          backend="wasm-js-string",
          feature="String::trim_end",
        )
      } else {
        require_heap(ctx)
        let str_ptr = alloc_temp_local(ctx)
        let str_len = alloc_temp_local(ctx)
        let end_local = alloc_temp_local(ctx)
        let new_ptr = alloc_temp_local(ctx)
        let copy_i = alloc_temp_local(ctx)
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_untag_ptr_i32(buf)
        emit_local_set(buf, str_ptr)
        emit_local_get(buf, str_ptr)
        emit_i32_load(buf, 4)
        emit_local_set(buf, str_len)
        // end = str_len; scan backward while whitespace
        emit_local_get(buf, str_len)
        emit_local_set(buf, end_local)
        emit_block(buf)
        emit_loop(buf)
        emit_local_get(buf, end_local)
        emit_i32_const_raw(buf, 0)
        emit_i32_gt_s(buf)
        emit_i32_eqz(buf)
        emit_br_if(buf, 1) // break if end <= 0
        emit_local_get(buf, str_ptr)
        emit_local_get(buf, end_local)
        emit_i32_const_raw(buf, 1)
        emit_i32_sub(buf)
        emit_i32_add(buf)
        emit_i32_load8_u(buf, 8)
        emit_i32_const_raw(buf, 32)
        emit_i32_gt_u(buf)
        emit_br_if(buf, 1) // break if non-whitespace
        emit_local_get(buf, end_local)
        emit_i32_const_raw(buf, 1)
        emit_i32_sub(buf)
        emit_local_set(buf, end_local)
        emit_br(buf, 0)
        emit_end(buf)
        emit_end(buf)
        // allocate new string of length end
        let obj_size_local = alloc_temp_local(ctx)
        emit_local_get(buf, end_local)
        emit_i32_const_raw(buf, 8)
        emit_i32_add(buf)
        emit_local_set(buf, obj_size_local)
        emit_local_get(buf, obj_size_local)
        emit_i32_const_raw(buf, 3)
        emit_i32_add(buf)
        emit_i32_const_raw(buf, -4)
        emit_i32_and(buf)
        emit_local_set(buf, obj_size_local)
        emit_heap_alloc_local(ctx, buf, obj_size_local, new_ptr)
        emit_local_get(buf, new_ptr)
        emit_i32_const_raw(buf, obj_string)
        emit_i32_store(buf, 0)
        emit_local_get(buf, new_ptr)
        emit_local_get(buf, end_local)
        emit_i32_store(buf, 4)
        // copy bytes from start
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, copy_i)
        emit_block(buf)
        emit_loop(buf)
        emit_local_get(buf, copy_i)
        emit_local_get(buf, end_local)
        emit_i32_lt_s(buf)
        emit_i32_eqz(buf)
        emit_br_if(buf, 1)
        emit_local_get(buf, new_ptr)
        emit_local_get(buf, copy_i)
        emit_i32_add(buf)
        emit_local_get(buf, str_ptr)
        emit_local_get(buf, copy_i)
        emit_i32_add(buf)
        emit_i32_load8_u(buf, 8)
        emit_i32_store8(buf, 8)
        emit_local_get(buf, copy_i)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, copy_i)
        emit_br(buf, 0)
        emit_end(buf)
        emit_end(buf)
        emit_local_get(buf, new_ptr)
        emit_i64_extend_i32_u(buf)
        emit_i64_const_raw(buf, tag_obj.to_int64())
        emit_i64_or(buf)
      }
    }
    "String::to_upper" if not(is_user_fn) => {
      // string_to_upper(str) -> String (convert ASCII lowercase to uppercase)
      let pos_args = extract_positional_exprs_with_arity(
        args, "String::to_upper", 1,
      )
      if ctx.use_js_strings {
        raise WasmGenError::BackendLimit(
          backend="wasm-js-string",
          feature="String::to_upper",
        )
      } else {
        require_heap(ctx)
        let str_ptr = alloc_temp_local(ctx)
        let str_len = alloc_temp_local(ctx)
        let new_ptr = alloc_temp_local(ctx)
        let copy_i = alloc_temp_local(ctx)
        let byte_local = alloc_temp_local(ctx)
        // Untag and get source string pointer
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_untag_ptr_i32(buf)
        emit_local_set(buf, str_ptr)
        // Get source string length
        emit_local_get(buf, str_ptr)
        emit_i32_load(buf, 4)
        emit_local_set(buf, str_len)
        // Allocate new string: [type:i32, len:i32, bytes...]
        let obj_size_local = alloc_temp_local(ctx)
        emit_local_get(buf, str_len)
        emit_i32_const_raw(buf, 8)
        emit_i32_add(buf)
        emit_local_set(buf, obj_size_local)
        emit_local_get(buf, obj_size_local)
        emit_i32_const_raw(buf, 3)
        emit_i32_add(buf)
        emit_i32_const_raw(buf, -4)
        emit_i32_and(buf)
        emit_local_set(buf, obj_size_local)
        emit_heap_alloc_local(ctx, buf, obj_size_local, new_ptr)
        // Set type = obj_string
        emit_local_get(buf, new_ptr)
        emit_i32_const_raw(buf, obj_string)
        emit_i32_store(buf, 0)
        // Set length
        emit_local_get(buf, new_ptr)
        emit_local_get(buf, str_len)
        emit_i32_store(buf, 4)
        // Copy bytes, converting lowercase to uppercase
        // Branchless: new_byte = byte - 32 * ((byte >= 'a') & (byte <= 'z'))
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, copy_i)
        emit_block(buf)
        emit_loop(buf)
        emit_local_get(buf, copy_i)
        emit_local_get(buf, str_len)
        emit_i32_lt_s(buf)
        emit_i32_eqz(buf)
        emit_br_if(buf, 1)
        // Read source byte
        emit_local_get(buf, str_ptr)
        emit_local_get(buf, copy_i)
        emit_i32_add(buf)
        emit_i32_load8_u(buf, 8)
        emit_local_set(buf, byte_local)
        // Store address = new_ptr + copy_i
        emit_local_get(buf, new_ptr)
        emit_local_get(buf, copy_i)
        emit_i32_add(buf)
        // Compute: byte - 32 * (byte >= 97 && byte <= 122)
        emit_local_get(buf, byte_local)
        emit_i32_const_raw(buf, 32)
        emit_local_get(buf, byte_local)
        emit_i32_const_raw(buf, 97) // 'a'
        emit_i32_ge_s(buf)
        emit_local_get(buf, byte_local)
        emit_i32_const_raw(buf, 122) // 'z'
        emit_i32_le_s(buf)
        emit_i32_and(buf)
        emit_i32_mul(buf)
        emit_i32_sub(buf)
        emit_i32_store8(buf, 8)
        // i++
        emit_local_get(buf, copy_i)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, copy_i)
        emit_br(buf, 0)
        emit_end(buf)
        emit_end(buf)
        // Tag as obj pointer
        emit_local_get(buf, new_ptr)
        emit_i64_extend_i32_u(buf)
        emit_i64_const_raw(buf, tag_obj.to_int64())
        emit_i64_or(buf)
      }
    }
    "String::to_lower" if not(is_user_fn) => {
      // string_to_lower(str) -> String (convert ASCII uppercase to lowercase)
      let pos_args = extract_positional_exprs_with_arity(
        args, "String::to_lower", 1,
      )
      if ctx.use_js_strings {
        raise WasmGenError::BackendLimit(
          backend="wasm-js-string",
          feature="String::to_lower",
        )
      } else {
        require_heap(ctx)
        let str_ptr = alloc_temp_local(ctx)
        let str_len = alloc_temp_local(ctx)
        let new_ptr = alloc_temp_local(ctx)
        let copy_i = alloc_temp_local(ctx)
        let byte_local = alloc_temp_local(ctx)
        // Untag and get source string pointer
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_untag_ptr_i32(buf)
        emit_local_set(buf, str_ptr)
        // Get source string length
        emit_local_get(buf, str_ptr)
        emit_i32_load(buf, 4)
        emit_local_set(buf, str_len)
        // Allocate new string: [type:i32, len:i32, bytes...]
        let obj_size_local = alloc_temp_local(ctx)
        emit_local_get(buf, str_len)
        emit_i32_const_raw(buf, 8)
        emit_i32_add(buf)
        emit_local_set(buf, obj_size_local)
        emit_local_get(buf, obj_size_local)
        emit_i32_const_raw(buf, 3)
        emit_i32_add(buf)
        emit_i32_const_raw(buf, -4)
        emit_i32_and(buf)
        emit_local_set(buf, obj_size_local)
        emit_heap_alloc_local(ctx, buf, obj_size_local, new_ptr)
        // Set type = obj_string
        emit_local_get(buf, new_ptr)
        emit_i32_const_raw(buf, obj_string)
        emit_i32_store(buf, 0)
        // Set length
        emit_local_get(buf, new_ptr)
        emit_local_get(buf, str_len)
        emit_i32_store(buf, 4)
        // Copy bytes, converting uppercase to lowercase
        // Branchless: new_byte = byte + 32 * ((byte >= 'A') & (byte <= 'Z'))
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, copy_i)
        emit_block(buf)
        emit_loop(buf)
        emit_local_get(buf, copy_i)
        emit_local_get(buf, str_len)
        emit_i32_lt_s(buf)
        emit_i32_eqz(buf)
        emit_br_if(buf, 1)
        // Read source byte
        emit_local_get(buf, str_ptr)
        emit_local_get(buf, copy_i)
        emit_i32_add(buf)
        emit_i32_load8_u(buf, 8)
        emit_local_set(buf, byte_local)
        // Store address = new_ptr + copy_i
        emit_local_get(buf, new_ptr)
        emit_local_get(buf, copy_i)
        emit_i32_add(buf)
        // Compute: byte + 32 * (byte >= 65 && byte <= 90)
        emit_local_get(buf, byte_local)
        emit_i32_const_raw(buf, 32)
        emit_local_get(buf, byte_local)
        emit_i32_const_raw(buf, 65) // 'A'
        emit_i32_ge_s(buf)
        emit_local_get(buf, byte_local)
        emit_i32_const_raw(buf, 90) // 'Z'
        emit_i32_le_s(buf)
        emit_i32_and(buf)
        emit_i32_mul(buf)
        emit_i32_add(buf)
        emit_i32_store8(buf, 8)
        // i++
        emit_local_get(buf, copy_i)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, copy_i)
        emit_br(buf, 0)
        emit_end(buf)
        emit_end(buf)
        // Tag as obj pointer
        emit_local_get(buf, new_ptr)
        emit_i64_extend_i32_u(buf)
        emit_i64_const_raw(buf, tag_obj.to_int64())
        emit_i64_or(buf)
      }
    }
    "String::replace" if not(is_user_fn) => {
      // string_replace(str, pattern, replacement) -> String (replace first occurrence)
      let pos_args = extract_positional_exprs_with_arity(
        args, "String::replace", 3,
      )
      if ctx.use_js_strings {
        raise WasmGenError::BackendLimit(
          backend="wasm-js-string",
          feature="String::replace",
        )
      } else {
        emit_string_replace_impl(ctx, buf, pos_args, replace_all=false)
      }
    }
    "String::replace_all" if not(is_user_fn) => {
      // string_replace_all(str, pattern, replacement) -> String (replace all occurrences)
      let pos_args = extract_positional_exprs_with_arity(
        args, "String::replace_all", 3,
      )
      if ctx.use_js_strings {
        raise WasmGenError::BackendLimit(
          backend="wasm-js-string",
          feature="String::replace_all",
        )
      } else {
        emit_string_replace_impl(ctx, buf, pos_args, replace_all=true)
      }
    }
    "String::split" if not(is_user_fn) => {
      // string_split(str, delimiter) -> Array[String]
      let pos_args = extract_positional_exprs_with_arity(
        args, "String::split", 2,
      )
      if ctx.use_js_strings {
        raise WasmGenError::BackendLimit(
          backend="wasm-js-string",
          feature="String::split",
        )
      } else {
        emit_string_split_impl(ctx, buf, pos_args)
      }
    }
    "StringBuilder::new" => {
      // string_builder() -> allocate empty array obj with len=0 (same layout as array_builder)
      // Uses hidden capacity prefix at obj_ptr-4 for grow-on-overflow in push.
      let obj_local = alloc_temp_local(ctx)
      emit_builder_alloc(ctx, buf, builder_initial_cap, 4, obj_array, obj_local)
      emit_local_get(buf, obj_local)
      emit_i64_extend_i32_u(buf)
      emit_i64_const_raw(buf, tag_obj.to_int64())
      emit_i64_or(buf)
    }
    "StringBuilder::push" => {
      // string_builder_push(builder, value) -> same layout as array_builder_push
      // Grows capacity when full (heap-tip extension or trap).
      let pos_args = extract_positional_exprs_with_arity(
        args, "StringBuilder::push", 2,
      )
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
      // return unit
      emit_i64_const_tagged(buf, 0L)
    }
    "StringBuilder::freeze" => {
      // string_builder_freeze(builder) -> concatenate all stored strings
      // Two-pass: 1) sum total byte length, 2) allocate and copy
      let pos_args = extract_positional_exprs_with_arity(
        args, "StringBuilder::freeze", 1,
      )
      require_heap(ctx)
      let builder_ptr = alloc_temp_local(ctx)
      let num_strings = alloc_temp_local(ctx)
      let total_len = alloc_temp_local(ctx)
      let result_ptr = alloc_temp_local(ctx)
      let loop_i = alloc_temp_local(ctx)
      let str_ptr = alloc_temp_local(ctx)
      let str_len = alloc_temp_local(ctx)
      let write_offset = alloc_temp_local(ctx)
      let copy_j = alloc_temp_local(ctx)
      let alloc_size = alloc_temp_local(ctx)
      // untag builder pointer
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, builder_ptr)
      // Follow forwarding pointer if builder was relocated by push realloc
      emit_builder_follow_forwarding(ctx, buf, builder_ptr)
      // read number of strings
      emit_local_get(buf, builder_ptr)
      emit_i32_load(buf, 4)
      emit_local_set(buf, num_strings)
      // Pass 1: calculate total byte length
      emit_i32_const_raw(buf, 0)
      emit_local_set(buf, total_len)
      emit_i32_const_raw(buf, 0)
      emit_local_set(buf, loop_i)
      emit_block(buf)
      emit_loop(buf)
      emit_local_get(buf, loop_i)
      emit_local_get(buf, num_strings)
      emit_i32_ge_s(buf)
      emit_br_if(buf, 1) // break if i >= num_strings
      // load string ref at builder_ptr + 8 + i*4, untag to get str_ptr
      emit_local_get(buf, builder_ptr)
      emit_local_get(buf, loop_i)
      emit_i32_const_raw(buf, 4)
      emit_i32_mul(buf)
      emit_i32_add(buf)
      emit_i32_load(buf, 8)
      emit_i32_const_raw(buf, -4)
      emit_i32_and(buf)
      emit_local_set(buf, str_ptr)
      // total_len += str_ptr.len (at offset 4)
      emit_local_get(buf, total_len)
      emit_local_get(buf, str_ptr)
      emit_i32_load(buf, 4)
      emit_i32_add(buf)
      emit_local_set(buf, total_len)
      // i++
      emit_local_get(buf, loop_i)
      emit_i32_const_raw(buf, 1)
      emit_i32_add(buf)
      emit_local_set(buf, loop_i)
      emit_br(buf, 0)
      emit_end(buf)
      emit_end(buf)
      // Allocate result string: align4(8 + total_len)
      emit_local_get(buf, total_len)
      emit_i32_const_raw(buf, 11) // 8 + 3 for alignment
      emit_i32_add(buf)
      emit_i32_const_raw(buf, -4)
      emit_i32_and(buf)
      emit_local_set(buf, alloc_size)
      emit_heap_alloc_local(ctx, buf, alloc_size, result_ptr)
      emit_local_get(buf, result_ptr)
      emit_i32_const_raw(buf, obj_string)
      emit_i32_store(buf, 0)
      emit_local_get(buf, result_ptr)
      emit_local_get(buf, total_len)
      emit_i32_store(buf, 4)
      // Pass 2: copy bytes from each string into result
      emit_i32_const_raw(buf, 0)
      emit_local_set(buf, write_offset)
      emit_i32_const_raw(buf, 0)
      emit_local_set(buf, loop_i)
      emit_block(buf) // outer block
      emit_loop(buf) // outer loop
      emit_local_get(buf, loop_i)
      emit_local_get(buf, num_strings)
      emit_i32_ge_s(buf)
      emit_br_if(buf, 1) // break if i >= num_strings
      // load and untag string ptr
      emit_local_get(buf, builder_ptr)
      emit_local_get(buf, loop_i)
      emit_i32_const_raw(buf, 4)
      emit_i32_mul(buf)
      emit_i32_add(buf)
      emit_i32_load(buf, 8)
      emit_i32_const_raw(buf, -4)
      emit_i32_and(buf)
      emit_local_set(buf, str_ptr)
      emit_local_get(buf, str_ptr)
      emit_i32_load(buf, 4)
      emit_local_set(buf, str_len)
      // inner loop: copy str_len bytes
      emit_i32_const_raw(buf, 0)
      emit_local_set(buf, copy_j)
      emit_block(buf) // inner block
      emit_loop(buf) // inner loop
      emit_local_get(buf, copy_j)
      emit_local_get(buf, str_len)
      emit_i32_ge_s(buf)
      emit_br_if(buf, 1) // break if j >= str_len
      // result_ptr + 8 + write_offset + j
      emit_local_get(buf, result_ptr)
      emit_local_get(buf, write_offset)
      emit_i32_add(buf)
      emit_local_get(buf, copy_j)
      emit_i32_add(buf)
      // load byte from str_ptr + 8 + j
      emit_local_get(buf, str_ptr)
      emit_local_get(buf, copy_j)
      emit_i32_add(buf)
      emit_i32_load8_u(buf, 8)
      emit_i32_store8(buf, 8)
      // j++
      emit_local_get(buf, copy_j)
      emit_i32_const_raw(buf, 1)
      emit_i32_add(buf)
      emit_local_set(buf, copy_j)
      emit_br(buf, 0)
      emit_end(buf) // end inner loop
      emit_end(buf) // end inner block
      // write_offset += str_len
      emit_local_get(buf, write_offset)
      emit_local_get(buf, str_len)
      emit_i32_add(buf)
      emit_local_set(buf, write_offset)
      // i++
      emit_local_get(buf, loop_i)
      emit_i32_const_raw(buf, 1)
      emit_i32_add(buf)
      emit_local_set(buf, loop_i)
      emit_br(buf, 0)
      emit_end(buf) // end outer loop
      emit_end(buf) // end outer block
      // return tagged result
      emit_local_get(buf, result_ptr)
      emit_i64_extend_i32_u(buf)
      emit_i64_const_raw(buf, tag_obj.to_int64())
      emit_i64_or(buf)
    }
    "string_to_data" => {
      // string_to_data(str) -> Array[Int] of byte values
      // For WASM codegen, strings are stored as (offset, len) pairs in memory
      // This creates an array of character codes
      let pos_args = extract_positional_exprs_with_arity(
        args, "string_to_data", 1,
      )
      require_heap(ctx)
      let str_ptr = alloc_temp_local(ctx)
      let str_len = alloc_temp_local(ctx)
      let obj_local = alloc_temp_local(ctx)
      let idx_local = alloc_temp_local(ctx)
      // Get string tagged value and extract pointer
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_local_tee(buf, str_ptr)
      emit_i32_load(buf, 4) // string length
      emit_local_set(buf, str_len)
      emit_local_get(buf, str_ptr)
      emit_i32_const_raw(buf, 8)
      emit_i32_add(buf) // str_ptr = ptr + 8 (inline data start)
      emit_local_set(buf, str_ptr) // reuse as data ptr
      // Allocate array: header(8) + len*4
      // Compute alloc_size = align4(8 + str_len*4)
      let alloc_size_local = alloc_temp_local(ctx)
      emit_local_get(buf, str_len)
      emit_i32_const_raw(buf, 4)
      emit_i32_mul(buf)
      emit_i32_const_raw(buf, 11) // 8 + 3 for alignment
      emit_i32_add(buf)
      emit_i32_const_raw(buf, -4)
      emit_i32_and(buf)
      emit_local_set(buf, alloc_size_local)
      // Use heap_local-based allocator; bumping heap_global directly
      // here leaves ctx.heap_local stale and corrupts subsequent
      // allocations sharing the same memory range.
      emit_heap_alloc_local(ctx, buf, alloc_size_local, obj_local)
      // Set header
      emit_local_get(buf, obj_local)
      emit_i32_const_raw(buf, obj_array)
      emit_i32_store(buf, 0)
      emit_local_get(buf, obj_local)
      emit_local_get(buf, str_len)
      emit_i32_store(buf, 4)
      // Fill array with char codes (tagged ints)
      emit_i32_const_raw(buf, 0)
      emit_local_set(buf, idx_local)
      emit_block(buf)
      emit_loop(buf)
      emit_local_get(buf, idx_local)
      emit_local_get(buf, str_len)
      emit_i32_ge_s(buf)
      emit_br_if(buf, 1)
      // arr[idx] = tagged(memory[str_ptr + idx])
      emit_local_get(buf, obj_local)
      emit_local_get(buf, idx_local)
      emit_i32_const_raw(buf, 4)
      emit_i32_mul(buf)
      emit_i32_add(buf)
      // Load byte from string data
      emit_local_get(buf, str_ptr)
      emit_local_get(buf, idx_local)
      emit_i32_add(buf)
      emit_i32_load8_u(buf, 0)
      // Tag as int: val * 4 (equivalent to val << 2)
      emit_i32_const_raw(buf, 4)
      emit_i32_mul(buf)
      emit_i32_store(buf, 8)
      emit_local_get(buf, idx_local)
      emit_i32_const_raw(buf, 1)
      emit_i32_add(buf)
      emit_local_set(buf, idx_local)
      emit_br(buf, 0)
      emit_end(buf)
      emit_end(buf)
      // Return tagged array
      emit_local_get(buf, obj_local)
      emit_i64_extend_i32_u(buf)
      emit_i64_const_raw(buf, tag_obj.to_int64())
      emit_i64_or(buf)
    }
    "String::from_char_code" => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "String::from_char_code", 1,
      )
      require_heap(ctx)
      let raw_local = alloc_temp_local(ctx)
      let code_local = alloc_temp_local(ctx)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_int_i32(buf)
      emit_local_set(buf, code_local)
      emit_heap_alloc(ctx, buf, 12, raw_local)
      emit_local_get(buf, raw_local)
      emit_i32_const_raw(buf, obj_string)
      emit_i32_store(buf, 0)
      emit_local_get(buf, raw_local)
      emit_i32_const_raw(buf, 1)
      emit_i32_store(buf, 4)
      emit_local_get(buf, raw_local)
      emit_local_get(buf, code_local)
      emit_i32_store8(buf, 8)
      emit_local_get(buf, raw_local)
      emit_i64_extend_i32_u(buf)
      emit_i64_const_raw(buf, tag_obj.to_int64())
      emit_i64_or(buf)
    }
    _ => raise WasmGenError::Unsupported(pre_user_builtin_unhandled_marker)
  }
}

///|
/// Emit WASM for string_replace / string_replace_all.
/// Two-pass: 1) count matches, 2) build result with replacements.
/// Uses `if/end` for conditionals (same pattern as string_contains).
fn emit_string_replace_impl(
  ctx : CodegenCtx,
  buf : ByteBuf,
  pos_args : Array[@core.Expr],
  replace_all~ : Bool,
) -> Unit raise WasmGenError {
  require_heap(ctx)
  let str_ptr = alloc_temp_local(ctx)
  let str_len = alloc_temp_local(ctx)
  let pat_ptr = alloc_temp_local(ctx)
  let pat_len = alloc_temp_local(ctx)
  let rep_ptr = alloc_temp_local(ctx)
  let rep_len = alloc_temp_local(ctx)
  let match_count = alloc_temp_local(ctx)
  let scan_i = alloc_temp_local(ctx)
  let inner_j = alloc_temp_local(ctx)
  let new_len = alloc_temp_local(ctx)
  let new_ptr = alloc_temp_local(ctx)
  let src_i = alloc_temp_local(ctx)
  let dst_i = alloc_temp_local(ctx)
  let copy_j = alloc_temp_local(ctx)
  let matched = alloc_temp_local(ctx)
  let limit_local = alloc_temp_local(ctx)
  // Untag source string
  compile_expr_i32(ctx, buf, pos_args[0])
  emit_untag_ptr_i32(buf)
  emit_local_set(buf, str_ptr)
  emit_local_get(buf, str_ptr)
  emit_i32_load(buf, 4)
  emit_local_set(buf, str_len)
  // Untag pattern string
  compile_expr_i32(ctx, buf, pos_args[1])
  emit_untag_ptr_i32(buf)
  emit_local_set(buf, pat_ptr)
  emit_local_get(buf, pat_ptr)
  emit_i32_load(buf, 4)
  emit_local_set(buf, pat_len)
  // Untag replacement string
  compile_expr_i32(ctx, buf, pos_args[2])
  emit_untag_ptr_i32(buf)
  emit_local_set(buf, rep_ptr)
  emit_local_get(buf, rep_ptr)
  emit_i32_load(buf, 4)
  emit_local_set(buf, rep_len)
  // --- Pass 1: Count matches (same structure as string_contains) ---
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, match_count)
  // Only search if pat_len > 0
  emit_local_get(buf, pat_len)
  emit_i32_const_raw(buf, 0)
  emit_i32_gt_s(buf)
  emit_if(buf) // if pat_len > 0
  // limit = str_len - pat_len + 1
  emit_local_get(buf, str_len)
  emit_local_get(buf, pat_len)
  emit_i32_sub(buf)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, limit_local)
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, scan_i)
  emit_block(buf) // block $count_break
  emit_loop(buf) // loop $count_loop
  // if scan_i >= limit, break
  emit_local_get(buf, scan_i)
  emit_local_get(buf, limit_local)
  emit_i32_lt_s(buf)
  emit_i32_eqz(buf)
  emit_br_if(buf, 1) // break $count_break
  // Check if pattern matches at scan_i
  emit_i32_const_raw(buf, 1)
  emit_local_set(buf, matched)
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, inner_j)
  emit_block(buf) // block $cmp_done
  emit_loop(buf) // loop $cmp_loop
  emit_local_get(buf, inner_j)
  emit_local_get(buf, pat_len)
  emit_i32_lt_s(buf)
  emit_i32_eqz(buf)
  emit_br_if(buf, 1) // break if j >= pat_len (all matched)
  // Compare str[scan_i + inner_j + 8] vs pat[inner_j + 8]
  emit_local_get(buf, str_ptr)
  emit_local_get(buf, scan_i)
  emit_i32_add(buf)
  emit_local_get(buf, inner_j)
  emit_i32_add(buf)
  emit_i32_load8_u(buf, 8)
  emit_local_get(buf, pat_ptr)
  emit_local_get(buf, inner_j)
  emit_i32_add(buf)
  emit_i32_load8_u(buf, 8)
  emit_i32_eq(buf)
  emit_i32_eqz(buf) // not equal?
  emit_if(buf) // if not equal
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, matched)
  emit_br(buf, 2) // break $cmp_done
  emit_end(buf) // end if
  emit_local_get(buf, inner_j)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, inner_j)
  emit_br(buf, 0) // continue $cmp_loop
  emit_end(buf) // end $cmp_loop
  emit_end(buf) // end $cmp_done
  // If matched, count++ and maybe break
  emit_local_get(buf, matched)
  emit_if(buf) // if matched
  emit_local_get(buf, match_count)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, match_count)
  if not(replace_all) {
    emit_br(buf, 2) // break $count_break
  } else {
    // Advance by pat_len to avoid overlapping
    emit_local_get(buf, scan_i)
    emit_local_get(buf, pat_len)
    emit_i32_add(buf)
    emit_local_set(buf, scan_i)
    emit_br(buf, 1) // continue $count_loop
  }
  emit_end(buf) // end if matched
  // Not matched: scan_i++
  emit_local_get(buf, scan_i)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, scan_i)
  emit_br(buf, 0) // continue $count_loop
  emit_end(buf) // end $count_loop
  emit_end(buf) // end $count_break
  emit_end(buf) // end if pat_len > 0
  // --- Compute result length ---
  emit_local_get(buf, str_len)
  emit_local_get(buf, match_count)
  emit_local_get(buf, rep_len)
  emit_local_get(buf, pat_len)
  emit_i32_sub(buf)
  emit_i32_mul(buf)
  emit_i32_add(buf)
  emit_local_set(buf, new_len)
  // --- Allocate new string ---
  let obj_size_local = alloc_temp_local(ctx)
  emit_local_get(buf, new_len)
  emit_i32_const_raw(buf, 8)
  emit_i32_add(buf)
  emit_local_set(buf, obj_size_local)
  emit_local_get(buf, obj_size_local)
  emit_i32_const_raw(buf, 3)
  emit_i32_add(buf)
  emit_i32_const_raw(buf, -4)
  emit_i32_and(buf)
  emit_local_set(buf, obj_size_local)
  emit_heap_alloc_local(ctx, buf, obj_size_local, new_ptr)
  emit_local_get(buf, new_ptr)
  emit_i32_const_raw(buf, obj_string)
  emit_i32_store(buf, 0)
  emit_local_get(buf, new_ptr)
  emit_local_get(buf, new_len)
  emit_i32_store(buf, 4)
  // --- Pass 2: Build result ---
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, src_i)
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, dst_i)
  emit_block(buf) // block $build_done
  emit_loop(buf) // loop $build_loop
  emit_local_get(buf, src_i)
  emit_local_get(buf, str_len)
  emit_i32_ge_s(buf)
  emit_br_if(buf, 1) // break if src_i >= str_len
  // Try to match pattern at src_i
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, matched)
  // Guard: pat_len > 0
  emit_local_get(buf, pat_len)
  emit_i32_const_raw(buf, 0)
  emit_i32_gt_s(buf)
  emit_if(buf) // if pat_len > 0
  // Guard: src_i + pat_len <= str_len
  emit_local_get(buf, src_i)
  emit_local_get(buf, pat_len)
  emit_i32_add(buf)
  emit_local_get(buf, str_len)
  emit_i32_le_s(buf)
  emit_if(buf) // if src_i + pat_len <= str_len
  // Compare pattern (same inner loop as pass 1)
  emit_i32_const_raw(buf, 1)
  emit_local_set(buf, matched)
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, inner_j)
  emit_block(buf) // block $cmp2_done
  emit_loop(buf) // loop $cmp2_loop
  emit_local_get(buf, inner_j)
  emit_local_get(buf, pat_len)
  emit_i32_lt_s(buf)
  emit_i32_eqz(buf)
  emit_br_if(buf, 1) // break if j >= pat_len
  emit_local_get(buf, str_ptr)
  emit_local_get(buf, src_i)
  emit_i32_add(buf)
  emit_local_get(buf, inner_j)
  emit_i32_add(buf)
  emit_i32_load8_u(buf, 8)
  emit_local_get(buf, pat_ptr)
  emit_local_get(buf, inner_j)
  emit_i32_add(buf)
  emit_i32_load8_u(buf, 8)
  emit_i32_eq(buf)
  emit_i32_eqz(buf)
  emit_if(buf) // if not equal
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, matched)
  emit_br(buf, 2) // break $cmp2_done
  emit_end(buf) // end if
  emit_local_get(buf, inner_j)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, inner_j)
  emit_br(buf, 0) // continue $cmp2_loop
  emit_end(buf) // end $cmp2_loop
  emit_end(buf) // end $cmp2_done
  emit_end(buf) // end if src_i + pat_len <= str_len
  emit_end(buf) // end if pat_len > 0
  // Handle match or copy byte
  emit_local_get(buf, matched)
  emit_if(buf) // if matched
  // Copy replacement bytes
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, copy_j)
  emit_block(buf) // block $rep_done
  emit_loop(buf) // loop $rep_loop
  emit_local_get(buf, copy_j)
  emit_local_get(buf, rep_len)
  emit_i32_ge_s(buf)
  emit_br_if(buf, 1) // done
  emit_local_get(buf, new_ptr)
  emit_local_get(buf, dst_i)
  emit_i32_add(buf)
  emit_local_get(buf, rep_ptr)
  emit_local_get(buf, copy_j)
  emit_i32_add(buf)
  emit_i32_load8_u(buf, 8)
  emit_i32_store8(buf, 8)
  emit_local_get(buf, dst_i)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, dst_i)
  emit_local_get(buf, copy_j)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, copy_j)
  emit_br(buf, 0) // continue $rep_loop
  emit_end(buf) // end $rep_loop
  emit_end(buf) // end $rep_done
  // Advance src by pat_len
  emit_local_get(buf, src_i)
  emit_local_get(buf, pat_len)
  emit_i32_add(buf)
  emit_local_set(buf, src_i)
  if not(replace_all) {
    // Copy remaining bytes directly, then break
    emit_block(buf) // block $rest_done
    emit_loop(buf) // loop $rest_loop
    emit_local_get(buf, src_i)
    emit_local_get(buf, str_len)
    emit_i32_ge_s(buf)
    emit_br_if(buf, 1)
    emit_local_get(buf, new_ptr)
    emit_local_get(buf, dst_i)
    emit_i32_add(buf)
    emit_local_get(buf, str_ptr)
    emit_local_get(buf, src_i)
    emit_i32_add(buf)
    emit_i32_load8_u(buf, 8)
    emit_i32_store8(buf, 8)
    emit_local_get(buf, src_i)
    emit_i32_const_raw(buf, 1)
    emit_i32_add(buf)
    emit_local_set(buf, src_i)
    emit_local_get(buf, dst_i)
    emit_i32_const_raw(buf, 1)
    emit_i32_add(buf)
    emit_local_set(buf, dst_i)
    emit_br(buf, 0)
    emit_end(buf) // end $rest_loop
    emit_end(buf) // end $rest_done
    emit_br(buf, 2) // break $build_done
  }
  emit_br(buf, 1) // continue $build_loop
  emit_else(buf) // else (not matched)
  // Copy single byte
  emit_local_get(buf, new_ptr)
  emit_local_get(buf, dst_i)
  emit_i32_add(buf)
  emit_local_get(buf, str_ptr)
  emit_local_get(buf, src_i)
  emit_i32_add(buf)
  emit_i32_load8_u(buf, 8)
  emit_i32_store8(buf, 8)
  emit_local_get(buf, src_i)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, src_i)
  emit_local_get(buf, dst_i)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, dst_i)
  emit_end(buf) // end if/else matched
  emit_br(buf, 0) // continue $build_loop
  emit_end(buf) // end $build_loop
  emit_end(buf) // end $build_done
  // Tag result
  emit_local_get(buf, new_ptr)
  emit_i64_extend_i32_u(buf)
  emit_i64_const_raw(buf, tag_obj.to_int64())
  emit_i64_or(buf)
}

///|
/// Helper: allocate a substring of `sub_len` bytes starting at `seg_start`
/// from `str_ptr`, and push the tagged pointer into the array at `arr_ptr`.
/// Increments `arr_len`.
fn emit_alloc_substr_push(
  ctx : CodegenCtx,
  buf : ByteBuf,
  str_ptr : Int,
  seg_start : Int,
  sub_len : Int,
  arr_ptr : Int,
  arr_len : Int,
  sub_ptr : Int,
  copy_j : Int,
  obj_size_local : Int,
) -> Unit {
  // Compute aligned size: align4(8 + sub_len)
  emit_local_get(buf, sub_len)
  emit_i32_const_raw(buf, 8)
  emit_i32_add(buf)
  emit_local_set(buf, obj_size_local)
  emit_local_get(buf, obj_size_local)
  emit_i32_const_raw(buf, 3)
  emit_i32_add(buf)
  emit_i32_const_raw(buf, -4)
  emit_i32_and(buf)
  emit_local_set(buf, obj_size_local)
  emit_heap_alloc_local(ctx, buf, obj_size_local, sub_ptr)
  // Set string header
  emit_local_get(buf, sub_ptr)
  emit_i32_const_raw(buf, obj_string)
  emit_i32_store(buf, 0)
  emit_local_get(buf, sub_ptr)
  emit_local_get(buf, sub_len)
  emit_i32_store(buf, 4)
  // Copy bytes: sub_ptr[8+j] = str_ptr[8+seg_start+j] for j in [0, sub_len)
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, copy_j)
  emit_block(buf) // block $copy_done
  emit_loop(buf) // loop $copy_loop
  emit_local_get(buf, copy_j)
  emit_local_get(buf, sub_len)
  emit_i32_ge_s(buf)
  emit_br_if(buf, 1) // break $copy_done
  emit_local_get(buf, sub_ptr)
  emit_local_get(buf, copy_j)
  emit_i32_add(buf)
  emit_local_get(buf, str_ptr)
  emit_local_get(buf, seg_start)
  emit_i32_add(buf)
  emit_local_get(buf, copy_j)
  emit_i32_add(buf)
  emit_i32_load8_u(buf, 8)
  emit_i32_store8(buf, 8)
  emit_local_get(buf, copy_j)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, copy_j)
  emit_br(buf, 0) // continue $copy_loop
  emit_end(buf) // end $copy_loop
  emit_end(buf) // end $copy_done
  // Push tagged sub_ptr into array: arr_ptr[8 + arr_len*4] = sub_ptr | tag_obj
  emit_local_get(buf, arr_ptr)
  emit_local_get(buf, arr_len)
  emit_i32_const_raw(buf, 4)
  emit_i32_mul(buf)
  emit_i32_add(buf)
  emit_local_get(buf, sub_ptr)
  emit_i32_const_raw(buf, tag_obj)
  emit_i32_or(buf)
  emit_i32_store(buf, 8)
  // arr_len++
  emit_local_get(buf, arr_len)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, arr_len)
}

///|
/// string_split(source, delimiter) -> Array[String]
/// If delimiter is empty, splits into individual characters.
/// Otherwise, scans for delimiter matches and builds an array of substrings.
fn emit_string_split_impl(
  ctx : CodegenCtx,
  buf : ByteBuf,
  pos_args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  require_heap(ctx)
  let str_ptr = alloc_temp_local(ctx)
  let str_len = alloc_temp_local(ctx)
  let del_ptr = alloc_temp_local(ctx)
  let del_len = alloc_temp_local(ctx)
  let arr_ptr = alloc_temp_local(ctx)
  let arr_len = alloc_temp_local(ctx)
  let seg_start = alloc_temp_local(ctx)
  let scan_i = alloc_temp_local(ctx)
  let inner_j = alloc_temp_local(ctx)
  let matched = alloc_temp_local(ctx)
  let sub_ptr = alloc_temp_local(ctx)
  let sub_len = alloc_temp_local(ctx)
  let copy_j = alloc_temp_local(ctx)
  let obj_size_local = alloc_temp_local(ctx)
  let seg_count = alloc_temp_local(ctx)
  let arr_size_local = alloc_temp_local(ctx)
  // Untag source string
  compile_expr_i32(ctx, buf, pos_args[0])
  emit_untag_ptr_i32(buf)
  emit_local_set(buf, str_ptr)
  emit_local_get(buf, str_ptr)
  emit_i32_load(buf, 4)
  emit_local_set(buf, str_len)
  // Untag delimiter string
  compile_expr_i32(ctx, buf, pos_args[1])
  emit_untag_ptr_i32(buf)
  emit_local_set(buf, del_ptr)
  emit_local_get(buf, del_ptr)
  emit_i32_load(buf, 4)
  emit_local_set(buf, del_len)
  // ── Pass 1: Count segments ──
  emit_local_get(buf, del_len)
  emit_i32_eqz(buf)
  emit_if(buf) // if del_len == 0
  // Empty delimiter: count = str_len (one segment per character)
  emit_local_get(buf, str_len)
  emit_local_set(buf, seg_count)
  emit_else(buf) // else: del_len > 0
  // Count delimiter matches; segments = matches + 1
  emit_i32_const_raw(buf, 1) // start with 1 (final trailing segment)
  emit_local_set(buf, seg_count)
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, scan_i)
  emit_block(buf) // block $count_done
  emit_loop(buf) // loop $count_loop
  // if scan_i + del_len > str_len: break
  emit_local_get(buf, scan_i)
  emit_local_get(buf, del_len)
  emit_i32_add(buf)
  emit_local_get(buf, str_len)
  emit_i32_gt_s(buf)
  emit_br_if(buf, 1) // break $count_done
  // Try to match delimiter at scan_i
  emit_i32_const_raw(buf, 1)
  emit_local_set(buf, matched)
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, inner_j)
  emit_block(buf) // block $cmp_done
  emit_loop(buf) // loop $cmp_loop
  emit_local_get(buf, inner_j)
  emit_local_get(buf, del_len)
  emit_i32_ge_s(buf)
  emit_br_if(buf, 1) // break $cmp_done
  emit_local_get(buf, str_ptr)
  emit_local_get(buf, scan_i)
  emit_i32_add(buf)
  emit_local_get(buf, inner_j)
  emit_i32_add(buf)
  emit_i32_load8_u(buf, 8)
  emit_local_get(buf, del_ptr)
  emit_local_get(buf, inner_j)
  emit_i32_add(buf)
  emit_i32_load8_u(buf, 8)
  emit_i32_eq(buf)
  emit_i32_eqz(buf)
  emit_if(buf) // if not equal
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, matched)
  emit_br(buf, 2) // break $cmp_done
  emit_end(buf) // end if
  emit_local_get(buf, inner_j)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, inner_j)
  emit_br(buf, 0) // continue $cmp_loop
  emit_end(buf) // end $cmp_loop
  emit_end(buf) // end $cmp_done
  // If matched: count++, scan_i += del_len; else: scan_i++
  emit_local_get(buf, matched)
  emit_if(buf)
  emit_local_get(buf, seg_count)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, seg_count)
  emit_local_get(buf, scan_i)
  emit_local_get(buf, del_len)
  emit_i32_add(buf)
  emit_local_set(buf, scan_i)
  emit_else(buf)
  emit_local_get(buf, scan_i)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, scan_i)
  emit_end(buf) // end if matched
  emit_br(buf, 0) // continue $count_loop
  emit_end(buf) // end $count_loop
  emit_end(buf) // end $count_done
  emit_end(buf) // end if/else (del_len check)
  // ── Allocate exact-sized array: align4(8 + seg_count * 4) ──
  emit_local_get(buf, seg_count)
  emit_i32_const_raw(buf, 4)
  emit_i32_mul(buf)
  emit_i32_const_raw(buf, 8 + 3) // header + alignment padding
  emit_i32_add(buf)
  emit_i32_const_raw(buf, -4) // mask: 0xFFFFFFFC
  emit_i32_and(buf)
  emit_local_set(buf, arr_size_local)
  emit_heap_alloc_local(ctx, buf, arr_size_local, arr_ptr)
  emit_local_get(buf, arr_ptr)
  emit_i32_const_raw(buf, obj_array)
  emit_i32_store(buf, 0)
  // ── Pass 2: Populate ── (reuse existing scan logic)
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, arr_len)
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, scan_i)
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, seg_start)
  // Branch on delimiter length
  emit_local_get(buf, del_len)
  emit_i32_eqz(buf)
  emit_if(buf) // if del_len == 0: character-by-character split
  emit_block(buf) // block $char_done
  emit_loop(buf) // loop $char_loop
  emit_local_get(buf, scan_i)
  emit_local_get(buf, str_len)
  emit_i32_ge_s(buf)
  emit_br_if(buf, 1) // break $char_done
  // sub_len = 1, seg_start = scan_i
  emit_i32_const_raw(buf, 1)
  emit_local_set(buf, sub_len)
  emit_local_get(buf, scan_i)
  emit_local_set(buf, seg_start)
  emit_alloc_substr_push(
    ctx, buf, str_ptr, seg_start, sub_len, arr_ptr, arr_len, sub_ptr, copy_j, obj_size_local,
  )
  // scan_i++
  emit_local_get(buf, scan_i)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, scan_i)
  emit_br(buf, 0) // continue $char_loop
  emit_end(buf) // end $char_loop
  emit_end(buf) // end $char_done
  emit_else(buf) // else: del_len > 0, normal split
  // Main split loop
  emit_block(buf) // block $split_done
  emit_loop(buf) // loop $split_loop
  // if scan_i + del_len > str_len: break to final segment
  emit_local_get(buf, scan_i)
  emit_local_get(buf, del_len)
  emit_i32_add(buf)
  emit_local_get(buf, str_len)
  emit_i32_gt_s(buf)
  emit_br_if(buf, 1) // break $split_done
  // Try to match delimiter at scan_i
  emit_i32_const_raw(buf, 1)
  emit_local_set(buf, matched)
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, inner_j)
  emit_block(buf) // block $cmp_done
  emit_loop(buf) // loop $cmp_loop
  emit_local_get(buf, inner_j)
  emit_local_get(buf, del_len)
  emit_i32_ge_s(buf)
  emit_br_if(buf, 1) // break $cmp_done (all bytes matched)
  // Compare str[scan_i + inner_j + 8] vs del[inner_j + 8]
  emit_local_get(buf, str_ptr)
  emit_local_get(buf, scan_i)
  emit_i32_add(buf)
  emit_local_get(buf, inner_j)
  emit_i32_add(buf)
  emit_i32_load8_u(buf, 8)
  emit_local_get(buf, del_ptr)
  emit_local_get(buf, inner_j)
  emit_i32_add(buf)
  emit_i32_load8_u(buf, 8)
  emit_i32_eq(buf)
  emit_i32_eqz(buf) // not equal?
  emit_if(buf) // if not equal
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, matched)
  emit_br(buf, 2) // break $cmp_done
  emit_end(buf) // end if
  emit_local_get(buf, inner_j)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, inner_j)
  emit_br(buf, 0) // continue $cmp_loop
  emit_end(buf) // end $cmp_loop
  emit_end(buf) // end $cmp_done
  // If matched: extract segment, push to array, advance
  emit_local_get(buf, matched)
  emit_if(buf) // if matched
  // sub_len = scan_i - seg_start
  emit_local_get(buf, scan_i)
  emit_local_get(buf, seg_start)
  emit_i32_sub(buf)
  emit_local_set(buf, sub_len)
  emit_alloc_substr_push(
    ctx, buf, str_ptr, seg_start, sub_len, arr_ptr, arr_len, sub_ptr, copy_j, obj_size_local,
  )
  // scan_i += del_len
  emit_local_get(buf, scan_i)
  emit_local_get(buf, del_len)
  emit_i32_add(buf)
  emit_local_set(buf, scan_i)
  // seg_start = scan_i
  emit_local_get(buf, scan_i)
  emit_local_set(buf, seg_start)
  emit_br(buf, 1) // continue $split_loop (br to loop re-enters it)
  emit_end(buf) // end if matched
  // Not matched: scan_i++
  emit_local_get(buf, scan_i)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, scan_i)
  emit_br(buf, 0) // continue $split_loop
  emit_end(buf) // end $split_loop
  emit_end(buf) // end $split_done
  // Final segment: [seg_start, str_len)
  emit_local_get(buf, str_len)
  emit_local_get(buf, seg_start)
  emit_i32_sub(buf)
  emit_local_set(buf, sub_len)
  emit_alloc_substr_push(
    ctx, buf, str_ptr, seg_start, sub_len, arr_ptr, arr_len, sub_ptr, copy_j, obj_size_local,
  )
  emit_end(buf) // end if/else (del_len check)
  // Write final array length
  emit_local_get(buf, arr_ptr)
  emit_local_get(buf, arr_len)
  emit_i32_store(buf, 4)
  // Return tagged array pointer
  emit_local_get(buf, arr_ptr)
  emit_i64_extend_i32_u(buf)
  emit_i64_const_raw(buf, tag_obj.to_int64())
  emit_i64_or(buf)
}
