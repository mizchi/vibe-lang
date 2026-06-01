///|
fn compile_builtin_numeric(
  ctx : CodegenCtx,
  buf : ByteBuf,
  name : String,
  args : Array[@core.CallArg],
  is_user_fn : Bool,
) -> Unit raise WasmGenError {
  match name {
    "add" if !is_user_fn || args.length() == 2 => {
      let pos_args = extract_positional_exprs_with_arity(args, "add", 2)
      let resolved_kind = resolve_numeric_kind(ctx, pos_args[0], pos_args[1])
      match resolved_kind {
        ValueKind::I32 | ValueKind::I64 =>
          if is_user_fn {
            raise WasmGenError::Unsupported(pre_user_builtin_unhandled_marker)
          } else {
            compile_i32_add_tagged(ctx, buf, pos_args[0], pos_args[1])
          }
        _ =>
          compile_binary_arith_op(
            ctx, buf, "add", args, emit_f32_add, emit_f64_add,
          )
      }
    }
    "sub" if !is_user_fn || args.length() == 2 => {
      let pos_args = extract_positional_exprs_with_arity(args, "sub", 2)
      let resolved_kind = resolve_numeric_kind(ctx, pos_args[0], pos_args[1])
      match resolved_kind {
        ValueKind::I32 | ValueKind::I64 =>
          if is_user_fn {
            raise WasmGenError::Unsupported(pre_user_builtin_unhandled_marker)
          } else {
            compile_i32_sub_tagged(ctx, buf, pos_args[0], pos_args[1])
          }
        _ =>
          compile_binary_arith_op(
            ctx, buf, "sub", args, emit_f32_sub, emit_f64_sub,
          )
      }
    }
    "mul" if !is_user_fn || args.length() == 2 => {
      let pos_args = extract_positional_exprs_with_arity(args, "mul", 2)
      let resolved_kind = resolve_numeric_kind(ctx, pos_args[0], pos_args[1])
      match resolved_kind {
        ValueKind::I32 | ValueKind::I64 =>
          if is_user_fn {
            raise WasmGenError::Unsupported(pre_user_builtin_unhandled_marker)
          } else {
            compile_i32_mul_tagged(ctx, buf, pos_args[0], pos_args[1])
          }
        _ =>
          compile_binary_arith_op(
            ctx, buf, "mul", args, emit_f32_mul, emit_f64_mul,
          )
      }
    }
    "div" if !is_user_fn || args.length() == 2 => {
      let pos_args = extract_positional_exprs_with_arity(args, "div", 2)
      let resolved_kind = resolve_numeric_kind(ctx, pos_args[0], pos_args[1])
      match resolved_kind {
        ValueKind::I32 | ValueKind::I64 =>
          if is_user_fn {
            raise WasmGenError::Unsupported(pre_user_builtin_unhandled_marker)
          } else {
            compile_i32_div_tagged(ctx, buf, pos_args[0], pos_args[1])
          }
        _ =>
          compile_binary_arith_op(
            ctx, buf, "div", args, emit_f32_div, emit_f64_div,
          )
      }
    }
    "eq" if !is_user_fn =>
      compile_binary_cmp_op(
        ctx, buf, "eq", args, emit_i64_eq, emit_f32_eq, emit_f64_eq,
      )
    "lt" if !is_user_fn =>
      // Route through compile_binary_cmp_op so the runtime obj_string
      // branch handles lexicographic comparison; for tagged ints the
      // fallback there is a plain i64 lt_s on the tagged values, which
      // preserves order since (a<<2) < (b<<2) iff a < b.
      compile_binary_cmp_op(
        ctx, buf, "lt", args, emit_i64_lt_s, emit_f32_lt, emit_f64_lt,
      )
    "assert" | "assert_true" | "__assert" if !is_user_fn => {
      let builtin_name = name
      let pos_args = extract_positional_exprs_with_arity(args, builtin_name, 1)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_i64_const_raw(buf, tag_bool_value64(true))
      emit_i64_eq(buf)
      emit_i32_eqz(buf)
      buf.push((4).to_byte()) // if
      buf.push((64).to_byte()) // empty result
      buf.push((0).to_byte()) // unreachable (trap)
      buf.push((11).to_byte()) // end if
      emit_i64_const_tagged(buf, 0L)
    }
    "assert_eq" | "__assert_eq" if !is_user_fn => {
      // assert_eq(a, b): compile __eq(a, b), then assert the result
      compile_binary_cmp_op(
        ctx, buf, "__eq", args, emit_i64_eq, emit_f32_eq, emit_f64_eq,
      )
      // compile_binary_cmp_op leaves tagged i64 bool on stack
      emit_i64_const_raw(buf, tag_bool_value64(true))
      emit_i64_eq(buf)
      emit_i32_eqz(buf)
      buf.push((4).to_byte()) // if (not equal)
      buf.push((64).to_byte()) // empty result
      buf.push((0).to_byte()) // unreachable (trap)
      buf.push((11).to_byte()) // end if
      emit_i64_const_tagged(buf, 0L)
    }
    "__add" => {
      let pos_args = extract_positional_exprs_with_arity(args, "__add", 2)
      let resolved_kind = resolve_numeric_kind(ctx, pos_args[0], pos_args[1])
      match resolved_kind {
        ValueKind::I32 | ValueKind::I64 =>
          compile_i32_add_tagged(ctx, buf, pos_args[0], pos_args[1])
        _ =>
          compile_binary_arith_op(
            ctx, buf, "__add", args, emit_f32_add, emit_f64_add,
          )
      }
    }
    "__sub" => {
      let pos_args = extract_positional_exprs_with_arity(args, "__sub", 2)
      let resolved_kind = resolve_numeric_kind(ctx, pos_args[0], pos_args[1])
      match resolved_kind {
        ValueKind::I32 | ValueKind::I64 =>
          compile_i32_sub_tagged(ctx, buf, pos_args[0], pos_args[1])
        _ =>
          compile_binary_arith_op(
            ctx, buf, "__sub", args, emit_f32_sub, emit_f64_sub,
          )
      }
    }
    "__mul" => {
      let pos_args = extract_positional_exprs_with_arity(args, "__mul", 2)
      let resolved_kind = resolve_numeric_kind(ctx, pos_args[0], pos_args[1])
      match resolved_kind {
        ValueKind::I32 | ValueKind::I64 =>
          compile_i32_mul_tagged(ctx, buf, pos_args[0], pos_args[1])
        _ =>
          compile_binary_arith_op(
            ctx, buf, "__mul", args, emit_f32_mul, emit_f64_mul,
          )
      }
    }
    "__div" => {
      let pos_args = extract_positional_exprs_with_arity(args, "__div", 2)
      let resolved_kind = resolve_numeric_kind(ctx, pos_args[0], pos_args[1])
      match resolved_kind {
        ValueKind::I32 | ValueKind::I64 =>
          compile_i32_div_tagged(ctx, buf, pos_args[0], pos_args[1])
        _ =>
          compile_binary_arith_op(
            ctx, buf, "__div", args, emit_f32_div, emit_f64_div,
          )
      }
    }
    "__mod" => {
      let pos_args = extract_positional_exprs_with_arity(args, "__mod", 2)
      let resolved_kind = resolve_numeric_kind(ctx, pos_args[0], pos_args[1])
      match resolved_kind {
        ValueKind::I32 | ValueKind::I64 =>
          compile_i32_mod_tagged(ctx, buf, pos_args[0], pos_args[1])
        _ => raise WasmGenError::Unsupported("__mod for float types")
      }
    }
    "__lshift" => {
      let pos_args = extract_positional_exprs_with_arity(args, "__lshift", 2)
      // (a >> 2) << (b >> 2), then tag result
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_i64_const_raw(buf, 2L)
      emit_i64_shr_s(buf)
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_i64_const_raw(buf, 2L)
      emit_i64_shr_s(buf)
      emit_i64_shl(buf)
      emit_i64_const_raw(buf, 2L)
      emit_i64_shl(buf)
      // tag_int = 0, i64.or is a no-op
    }
    "__rshift" => {
      let pos_args = extract_positional_exprs_with_arity(args, "__rshift", 2)
      // (a >> 2) >> (b >> 2), then tag result
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_i64_const_raw(buf, 2L)
      emit_i64_shr_s(buf)
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_i64_const_raw(buf, 2L)
      emit_i64_shr_s(buf)
      emit_i64_shr_s(buf)
      emit_i64_const_raw(buf, 2L)
      emit_i64_shl(buf)
      // tag_int = 0, i64.or is a no-op
    }
    "i32_shr_u" => {
      let pos_args = extract_positional_exprs_with_arity(args, "i32_shr_u", 2)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_i64_const_raw(buf, 2L)
      emit_i64_shr_s(buf)
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_i64_const_raw(buf, 2L)
      emit_i64_shr_s(buf)
      emit_i64_shr_u(buf)
      emit_i64_const_raw(buf, 2L)
      emit_i64_shl(buf)
      // tag_int = 0, i64.or is a no-op
    }
    "__bit_and" => {
      let pos_args = extract_positional_exprs_with_arity(args, "__bit_and", 2)
      // Tagged ints: (a & b) works directly since tag bits are 0
      compile_expr_i32(ctx, buf, pos_args[0])
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_i64_and(buf)
    }
    "__bit_or" => {
      let pos_args = extract_positional_exprs_with_arity(args, "__bit_or", 2)
      // Tagged ints: (a | b) works directly since tag bits are 0
      compile_expr_i32(ctx, buf, pos_args[0])
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_i64_or(buf)
    }
    "__bit_xor" => {
      let pos_args = extract_positional_exprs_with_arity(args, "__bit_xor", 2)
      // Tagged ints: (a ^ b) works directly since tag bits are 0
      compile_expr_i32(ctx, buf, pos_args[0])
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_i64_xor(buf)
    }
    "__eq" =>
      compile_binary_cmp_op(
        ctx, buf, "__eq", args, emit_i64_eq, emit_f32_eq, emit_f64_eq,
      )
    "__lt" =>
      // See `lt`: always route through compile_binary_cmp_op so strings
      // get lex compare and tagged ints fall back to i64 lt_s (correct
      // because tagging preserves ordering).
      compile_binary_cmp_op(
        ctx, buf, "__lt", args, emit_i64_lt_s, emit_f32_lt, emit_f64_lt,
      )
    "i32_eqz" if !is_user_fn => {
      let pos_args = extract_positional_exprs_with_arity(args, "i32_eqz", 1)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_int_i32(buf)
      emit_i32_eqz(buf)
      emit_i32_result_as_tagged_int(buf)
    }
    "i32_eq" if !is_user_fn =>
      compile_i32_cmp_to_tagged_int(ctx, buf, "i32_eq", args, emit_i32_eq)
    "i32_ne" if !is_user_fn =>
      compile_i32_cmp_to_tagged_int(ctx, buf, "i32_ne", args, emit_i32_ne)
    "i32_lt_s" if !is_user_fn =>
      compile_i32_cmp_to_tagged_int(ctx, buf, "i32_lt_s", args, emit_i32_lt_s)
    "i32_gt_s" if !is_user_fn =>
      compile_i32_cmp_to_tagged_int(ctx, buf, "i32_gt_s", args, emit_i32_gt_s)
    "i32_le_s" if !is_user_fn =>
      compile_i32_cmp_to_tagged_int(ctx, buf, "i32_le_s", args, emit_i32_le_s)
    "i32_ge_s" if !is_user_fn =>
      compile_i32_cmp_to_tagged_int(ctx, buf, "i32_ge_s", args, emit_i32_ge_s)
    "f32_eq" if !is_user_fn =>
      compile_f32_cmp_to_tagged_int(ctx, buf, "f32_eq", args, emit_f32_eq)
    "f32_ne" if !is_user_fn =>
      compile_f32_cmp_to_tagged_int(ctx, buf, "f32_ne", args, emit_f32_ne)
    "f32_lt" if !is_user_fn =>
      compile_f32_cmp_to_tagged_int(ctx, buf, "f32_lt", args, emit_f32_lt)
    "f32_gt" if !is_user_fn =>
      compile_f32_cmp_to_tagged_int(ctx, buf, "f32_gt", args, emit_f32_gt)
    "f32_le" if !is_user_fn =>
      compile_f32_cmp_to_tagged_int(ctx, buf, "f32_le", args, emit_f32_le)
    "f32_ge" if !is_user_fn =>
      compile_f32_cmp_to_tagged_int(ctx, buf, "f32_ge", args, emit_f32_ge)
    "f64_eq" if !is_user_fn =>
      compile_f64_cmp_to_tagged_int(ctx, buf, "f64_eq", args, emit_f64_eq)
    "f64_ne" if !is_user_fn =>
      compile_f64_cmp_to_tagged_int(ctx, buf, "f64_ne", args, emit_f64_ne)
    "f64_lt" if !is_user_fn =>
      compile_f64_cmp_to_tagged_int(ctx, buf, "f64_lt", args, emit_f64_lt)
    "f64_gt" if !is_user_fn =>
      compile_f64_cmp_to_tagged_int(ctx, buf, "f64_gt", args, emit_f64_gt)
    "f64_le" if !is_user_fn =>
      compile_f64_cmp_to_tagged_int(ctx, buf, "f64_le", args, emit_f64_le)
    "f64_ge" if !is_user_fn =>
      compile_f64_cmp_to_tagged_int(ctx, buf, "f64_ge", args, emit_f64_ge)
    "__neg" => {
      let pos_args = extract_positional_exprs_with_arity(args, "__neg", 1)
      let kind = infer_expr_kind(ctx, pos_args[0])
      match kind {
        ValueKind::I32 | ValueKind::I64 => {
          emit_i64_const_raw(buf, tag_int_value64(0L))
          compile_expr_i32(ctx, buf, pos_args[0])
          emit_i64_sub(buf)
        }
        ValueKind::BoxedF32 =>
          emit_boxed_f32_raise(ctx, buf, fn() raise WasmGenError {
            emit_unbox_f32_expr(ctx, buf, pos_args[0])
            emit_f32_neg(buf)
          })
        ValueKind::BoxedF64 =>
          emit_boxed_f64_raise(ctx, buf, fn() raise WasmGenError {
            emit_unbox_f64_expr(ctx, buf, pos_args[0])
            emit_f64_neg(buf)
          })
        _ => raise WasmGenError::Unsupported("numeric kind")
      }
    }
    "f32_neg"
    | "f32_abs"
    | "f32_ceil"
    | "f32_floor"
    | "f32_trunc"
    | "f32_nearest"
    | "f32_sqrt" => {
      let pos_args = extract_positional_exprs_with_arity(args, name, 1)
      let emit_op : (ByteBuf) -> Unit = match name {
        "f32_neg" => emit_f32_neg
        "f32_abs" => emit_f32_abs
        "f32_ceil" => emit_f32_ceil
        "f32_floor" => emit_f32_floor
        "f32_trunc" => emit_f32_trunc
        "f32_nearest" => emit_f32_nearest
        _ => emit_f32_sqrt
      }
      emit_boxed_f32_raise(ctx, buf, fn() raise WasmGenError {
        emit_unbox_f32_expr(ctx, buf, pos_args[0])
        emit_op(buf)
      })
    }
    "f64_neg"
    | "f64_abs"
    | "f64_ceil"
    | "f64_floor"
    | "f64_trunc"
    | "f64_nearest"
    | "f64_sqrt" => {
      let pos_args = extract_positional_exprs_with_arity(args, name, 1)
      let emit_op : (ByteBuf) -> Unit = match name {
        "f64_neg" => emit_f64_neg
        "f64_abs" => emit_f64_abs
        "f64_ceil" => emit_f64_ceil
        "f64_floor" => emit_f64_floor
        "f64_trunc" => emit_f64_trunc
        "f64_nearest" => emit_f64_nearest
        _ => emit_f64_sqrt
      }
      emit_boxed_f64_raise(ctx, buf, fn() raise WasmGenError {
        emit_unbox_f64_expr(ctx, buf, pos_args[0])
        emit_op(buf)
      })
    }
    // Numeric conversions migrated to the builtin registry (Phase B-1,
    // #415). The namespaced names (`Int::to_float`, ...) are dispatched
    // via `migrated_builtin`; the bare wasm-intrinsic aliases below stay
    // here and delegate to the same registry compile fns.
    "f32_convert_i32_s" => compile_int_to_float_linear(ctx, buf, args)
    "f64_convert_i32_s" | "to_double" =>
      compile_int_to_double_linear(ctx, buf, args)
    "i32_trunc_f32_s" => compile_float_to_int_linear(ctx, buf, args)
    "i32_trunc_f64_s" => compile_double_to_int_linear(ctx, buf, args)
    "f64_promote_f32" => compile_float_to_double_linear(ctx, buf, args)
    "f32_demote_f64" => compile_double_to_float_linear(ctx, buf, args)
    // ========== Integer math builtins ==========
    "Int::abs" if !is_user_fn => {
      // int_abs(x): if x < 0 then -x else x (operates on tagged i64 directly)
      let pos_args = extract_positional_exprs_with_arity(args, "Int::abs", 1)
      let tmp = alloc_temp_local_with_kind(ctx, ValueKind::I64)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_local_tee(buf, tmp) // stack: x, tmp = x
      emit_i64_const_raw(buf, 0L)
      emit_i64_lt_s(buf) // cond = x < 0 (i32)
      emit_if(buf) // if x < 0
      emit_i64_const_raw(buf, 0L)
      emit_local_get(buf, tmp)
      emit_i64_sub(buf) // -x (negate tagged value, tag 0 preserved)
      emit_local_set(buf, tmp)
      emit_end(buf) // end if
      emit_local_get(buf, tmp)
    }
    "Int::max" if !is_user_fn => {
      // int_max(a, b): works directly on tagged i64 values
      let pos_args = extract_positional_exprs_with_arity(args, "Int::max", 2)
      let a_local = alloc_temp_local_with_kind(ctx, ValueKind::I64)
      let b_local = alloc_temp_local_with_kind(ctx, ValueKind::I64)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_local_set(buf, a_local)
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_local_set(buf, b_local)
      // Push a, b, then (a > b) as i32 condition for select
      emit_local_get(buf, a_local)
      emit_local_get(buf, b_local)
      emit_local_get(buf, a_local)
      emit_local_get(buf, b_local)
      emit_i64_gt_s(buf) // a > b → 1:i32
      emit_select(buf) // select(a, b, a>b) → a if a>b else b
    }
    "Int::min" if !is_user_fn => {
      // int_min(a, b): works directly on tagged i64 values
      let pos_args = extract_positional_exprs_with_arity(args, "Int::min", 2)
      let a_local = alloc_temp_local_with_kind(ctx, ValueKind::I64)
      let b_local = alloc_temp_local_with_kind(ctx, ValueKind::I64)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_local_set(buf, a_local)
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_local_set(buf, b_local)
      emit_local_get(buf, a_local)
      emit_local_get(buf, b_local)
      emit_local_get(buf, a_local)
      emit_local_get(buf, b_local)
      emit_i64_lt_s(buf) // a < b → 1:i32
      emit_select(buf) // select(a, b, a<b) → a if a<b else b
    }
    "Int::clamp" if !is_user_fn => {
      // int_clamp(x, lo, hi): max(lo, min(x, hi))
      let pos_args = extract_positional_exprs_with_arity(args, "Int::clamp", 3)
      let x_local = alloc_temp_local_with_kind(ctx, ValueKind::I64)
      let lo_local = alloc_temp_local_with_kind(ctx, ValueKind::I64)
      let hi_local = alloc_temp_local_with_kind(ctx, ValueKind::I64)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_local_set(buf, x_local)
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_local_set(buf, lo_local)
      compile_expr_i32(ctx, buf, pos_args[2])
      emit_local_set(buf, hi_local)
      // min(x, hi): select(x, hi, x<hi)
      emit_local_get(buf, x_local)
      emit_local_get(buf, hi_local)
      emit_local_get(buf, x_local)
      emit_local_get(buf, hi_local)
      emit_i64_lt_s(buf)
      emit_select(buf) // min_val = min(x, hi)
      emit_local_set(buf, x_local)
      // max(lo, min_val): select(lo, min_val, lo>min_val)
      emit_local_get(buf, lo_local)
      emit_local_get(buf, x_local)
      emit_local_get(buf, lo_local)
      emit_local_get(buf, x_local)
      emit_i64_gt_s(buf)
      emit_select(buf) // max(lo, min(x, hi))
    }
    "Int::signum" if !is_user_fn => {
      // int_signum(x): -1 if x<0, 0 if x==0, 1 if x>0
      let pos_args = extract_positional_exprs_with_arity(args, "Int::signum", 1)
      let tmp = alloc_temp_local_with_kind(ctx, ValueKind::I64)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_local_set(buf, tmp)
      // Untag: x >> 2
      emit_local_get(buf, tmp)
      emit_i64_const_raw(buf, 2L)
      emit_i64_shr_s(buf)
      emit_local_set(buf, tmp) // tmp = untagged x
      // if x < 0: result = -1, elif x > 0: result = 1, else result = 0
      emit_local_get(buf, tmp)
      emit_i64_const_raw(buf, 0L)
      emit_i64_lt_s(buf)
      emit_if(buf) // if x < 0
      emit_i64_const_raw(buf, tag_int_value64(-1L))
      emit_local_set(buf, tmp)
      emit_else(buf) // else
      emit_local_get(buf, tmp)
      emit_i64_const_raw(buf, 0L)
      emit_i64_gt_s(buf)
      emit_if(buf) // if x > 0
      emit_i64_const_raw(buf, tag_int_value64(1L))
      emit_local_set(buf, tmp)
      emit_else(buf) // else (x == 0)
      emit_i64_const_raw(buf, tag_int_value64(0L))
      emit_local_set(buf, tmp)
      emit_end(buf) // end inner if
      emit_end(buf) // end outer if
      emit_local_get(buf, tmp)
    }
    "Int::is_even" if !is_user_fn => {
      // int_is_even(x): ((x >> 2) & 1) == 0 → tagged bool
      let pos_args = extract_positional_exprs_with_arity(
        args, "Int::is_even", 1,
      )
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_i64_const_raw(buf, 2L)
      emit_i64_shr_s(buf) // untag
      emit_i64_const_raw(buf, 1L)
      emit_i64_and(buf) // bit 0
      emit_i64_eqz(buf) // 1 if even, 0 if odd (i32 result)
      emit_i64_extend_i32_u(buf) // to i64
      emit_i64_const_raw(buf, 2L)
      emit_i64_shl(buf) // tag shift
      emit_i64_const_raw(buf, tag_bool.to_int64())
      emit_i64_or(buf) // tag as bool
    }
    "Int::is_odd" if !is_user_fn => {
      // int_is_odd(x): ((x >> 2) & 1) == 1 → tagged bool
      let pos_args = extract_positional_exprs_with_arity(args, "Int::is_odd", 1)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_i64_const_raw(buf, 2L)
      emit_i64_shr_s(buf) // untag
      emit_i64_const_raw(buf, 1L)
      emit_i64_and(buf) // bit 0: 1 if odd, 0 if even (i64)
      emit_i64_const_raw(buf, 2L)
      emit_i64_shl(buf) // tag shift
      emit_i64_const_raw(buf, tag_bool.to_int64())
      emit_i64_or(buf) // tag as bool
    }
    "i32_load" => {
      let pos_args = extract_positional_exprs_with_arity(args, "i32_load", 2)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_int_i32(buf)
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_untag_int_i32(buf)
      emit_i32_add(buf)
      emit_i32_load(buf, 0)
      emit_i64_extend_i32_s(buf)
      emit_i64_const_raw(buf, 2L)
      emit_i64_shl(buf)
      // tag_int = 0, i64.or is a no-op
    }
    "i32_load8_u" => {
      let pos_args = extract_positional_exprs_with_arity(args, "i32_load8_u", 2)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_int_i32(buf)
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_untag_int_i32(buf)
      emit_i32_add(buf)
      emit_i32_load8_u(buf, 0)
      emit_i64_extend_i32_s(buf)
      emit_i64_const_raw(buf, 2L)
      emit_i64_shl(buf)
      // tag_int = 0, i64.or is a no-op
    }
    "i32_store" => {
      let pos_args = extract_positional_exprs_with_arity(args, "i32_store", 3)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_int_i32(buf)
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_untag_int_i32(buf)
      emit_i32_add(buf)
      compile_expr_i32(ctx, buf, pos_args[2])
      emit_untag_int_i32(buf)
      emit_i32_store(buf, 0)
      emit_i64_const_tagged(buf, 0L)
    }
    "i32_store8" => {
      let pos_args = extract_positional_exprs_with_arity(args, "i32_store8", 3)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_int_i32(buf)
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_untag_int_i32(buf)
      emit_i32_add(buf)
      compile_expr_i32(ctx, buf, pos_args[2])
      emit_untag_int_i32(buf)
      emit_i32_store8(buf, 0)
      emit_i64_const_tagged(buf, 0L)
    }
    "f32_load" => {
      let pos_args = extract_positional_exprs_with_arity(args, "f32_load", 2)
      emit_boxed_f32_raise(ctx, buf, fn() raise WasmGenError {
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_untag_int_i32(buf)
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_untag_int_i32(buf)
        emit_i32_add(buf)
        emit_f32_load(buf, 0)
      })
    }
    "f64_load" => {
      let pos_args = extract_positional_exprs_with_arity(args, "f64_load", 2)
      emit_boxed_f64_raise(ctx, buf, fn() raise WasmGenError {
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_untag_int_i32(buf)
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_untag_int_i32(buf)
        emit_i32_add(buf)
        emit_f64_load(buf, 0)
      })
    }
    "f32_store" => {
      let pos_args = extract_positional_exprs_with_arity(args, "f32_store", 3)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_int_i32(buf)
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_untag_int_i32(buf)
      emit_i32_add(buf)
      emit_unbox_f32_expr(ctx, buf, pos_args[2])
      emit_f32_store(buf, 0)
      emit_i64_const_tagged(buf, 0L)
    }
    "f64_store" => {
      let pos_args = extract_positional_exprs_with_arity(args, "f64_store", 3)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_int_i32(buf)
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_untag_int_i32(buf)
      emit_i32_add(buf)
      emit_unbox_f64_expr(ctx, buf, pos_args[2])
      emit_f64_store(buf, 0)
      emit_i64_const_tagged(buf, 0L)
    }
    // --- SIMD V128 builtins ---
    "v128_load" => {
      // v128_load(bytes, offset) -> V128
      // Load raw Bytes data pointer, add offset, v128.load, box result
      let pos_args = extract_positional_exprs_with_arity(args, "v128_load", 2)
      let addr_local = alloc_temp_local(ctx)
      let v128_local = alloc_temp_local_with_kind(ctx, ValueKind::V128)
      // Compute base+offset as i32 address
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      // Load raw data pointer from Bytes object at offset 12
      emit_i32_load(buf, 12)
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_untag_int_i32(buf)
      emit_i32_add(buf)
      emit_v128_load(buf, 0)
      emit_local_set(buf, v128_local)
      // Box: allocate 20 bytes on heap (obj_type + v128)
      require_heap(ctx)
      emit_heap_alloc(ctx, buf, 20, addr_local)
      emit_local_get(buf, addr_local)
      emit_i32_const_raw(buf, obj_v128)
      emit_i32_store(buf, 0)
      emit_local_get(buf, addr_local)
      emit_local_get(buf, v128_local)
      emit_v128_store(buf, 4)
      // Return tagged pointer
      emit_local_get(buf, addr_local)
      emit_i64_extend_i32_u(buf)
      emit_i64_const_raw(buf, tag_obj.to_int64())
      emit_i64_or(buf)
    }
    "v128_store" => {
      // v128_store(bytes, offset, v128) -> Unit
      let pos_args = extract_positional_exprs_with_arity(args, "v128_store", 3)
      let v128_local = alloc_temp_local_with_kind(ctx, ValueKind::V128)
      // Unbox v128 arg
      compile_expr_i32(ctx, buf, pos_args[2])
      emit_untag_ptr_i32(buf)
      emit_v128_load(buf, 4)
      emit_local_set(buf, v128_local)
      // Compute Bytes data ptr + offset
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_i32_load(buf, 12)
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_untag_int_i32(buf)
      emit_i32_add(buf)
      // Store v128
      emit_local_get(buf, v128_local)
      emit_v128_store(buf, 0)
      emit_i64_const_tagged(buf, 0L)
    }
    "v128_splat_i8x16" => {
      // v128_splat_i8x16(int) -> V128
      let pos_args = extract_positional_exprs_with_arity(
        args, "v128_splat_i8x16", 1,
      )
      let addr_local = alloc_temp_local(ctx)
      let v128_local = alloc_temp_local_with_kind(ctx, ValueKind::V128)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_int_i32(buf)
      emit_i8x16_splat(buf)
      emit_local_set(buf, v128_local)
      require_heap(ctx)
      emit_heap_alloc(ctx, buf, 20, addr_local)
      emit_local_get(buf, addr_local)
      emit_i32_const_raw(buf, obj_v128)
      emit_i32_store(buf, 0)
      emit_local_get(buf, addr_local)
      emit_local_get(buf, v128_local)
      emit_v128_store(buf, 4)
      emit_local_get(buf, addr_local)
      emit_i64_extend_i32_u(buf)
      emit_i64_const_raw(buf, tag_obj.to_int64())
      emit_i64_or(buf)
    }
    "v128_eq_i8x16" => {
      // v128_eq_i8x16(V128, V128) -> V128
      let pos_args = extract_positional_exprs_with_arity(
        args, "v128_eq_i8x16", 2,
      )
      emit_v128_binary_op(ctx, buf, pos_args[0], pos_args[1], emit_i8x16_eq)
    }
    "v128_le_u_i8x16" => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "v128_le_u_i8x16", 2,
      )
      emit_v128_binary_op(ctx, buf, pos_args[0], pos_args[1], emit_i8x16_le_u)
    }
    "v128_ge_u_i8x16" => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "v128_ge_u_i8x16", 2,
      )
      emit_v128_binary_op(ctx, buf, pos_args[0], pos_args[1], emit_i8x16_ge_u)
    }
    "v128_and" => {
      let pos_args = extract_positional_exprs_with_arity(args, "v128_and", 2)
      emit_v128_binary_op(ctx, buf, pos_args[0], pos_args[1], emit_v128_and)
    }
    "v128_or" => {
      let pos_args = extract_positional_exprs_with_arity(args, "v128_or", 2)
      emit_v128_binary_op(ctx, buf, pos_args[0], pos_args[1], emit_v128_or)
    }
    "v128_not" => {
      // v128_not(V128) -> V128
      let pos_args = extract_positional_exprs_with_arity(args, "v128_not", 1)
      emit_v128_unary_op(ctx, buf, pos_args[0], emit_v128_not)
    }
    "v128_bitmask_i8x16" => {
      // v128_bitmask_i8x16(V128) -> Int
      let pos_args = extract_positional_exprs_with_arity(
        args, "v128_bitmask_i8x16", 1,
      )
      // Unbox v128
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_v128_load(buf, 4)
      // bitmask -> i32 result
      emit_i8x16_bitmask(buf)
      // Tag as Int
      emit_i64_extend_i32_s(buf)
      emit_i64_const_raw(buf, 2L)
      emit_i64_shl(buf)
    }
    "v128_any_true" => {
      // v128_any_true(V128) -> Bool
      let pos_args = extract_positional_exprs_with_arity(
        args, "v128_any_true", 1,
      )
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_v128_load(buf, 4)
      emit_v128_any_true(buf)
      emit_tag_bool_from_i32(buf)
    }
    "v128_all_true_i8x16" => {
      // v128_all_true_i8x16(V128) -> Bool
      let pos_args = extract_positional_exprs_with_arity(
        args, "v128_all_true_i8x16", 1,
      )
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_v128_load(buf, 4)
      emit_i8x16_all_true(buf)
      emit_tag_bool_from_i32(buf)
    }
    "int_ctz" => {
      // int_ctz(Int) -> Int
      let pos_args = extract_positional_exprs_with_arity(args, "int_ctz", 1)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_int_i32(buf)
      emit_i32_ctz(buf)
      emit_i64_extend_i32_s(buf)
      emit_i64_const_raw(buf, 2L)
      emit_i64_shl(buf)
    }
    "not" | "__not" if !is_user_fn => {
      let pos_args = extract_positional_exprs_with_arity(args, "not", 1)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_i64_const_raw(buf, 4L)
      emit_i64_xor(buf)
    }
    "and" if !is_user_fn => {
      let pos_args = extract_positional_exprs_with_arity(args, "and", 2)
      compile_expr_i32(ctx, buf, pos_args[0])
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_i64_and(buf)
    }
    "or" | "__or" if !is_user_fn => {
      let pos_args = extract_positional_exprs_with_arity(args, "or", 2)
      compile_expr_i32(ctx, buf, pos_args[0])
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_i64_or(buf)
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
    "Double::to_i64_bits" => {
      // double_to_i64_bits(f64_tagged) -> i64 raw bits as tagged int
      let pos_args = extract_positional_exprs_with_arity(
        args, "Double::to_i64_bits", 1,
      )
      compile_expr_i32(ctx, buf, pos_args[0])
      // The value is an i64 that is actually f64 bits reinterpreted
      // In our runtime, floats are stored as i64 (f64 reinterpret)
      // We just need to return the raw bits as-is (already i64)
      // No tagging needed since this is used for raw bit manipulation
    }
    "Double::from_i64_bits" => {
      // i64_bits_to_double(int_tagged) -> boxed f64
      // Takes a tagged int, untags it to get raw i64 bits,
      // reinterprets those bits as f64, and boxes the result.
      let pos_args = extract_positional_exprs_with_arity(
        args, "Double::from_i64_bits", 1,
      )
      emit_boxed_f64_raise(ctx, buf, fn() raise WasmGenError {
        compile_expr_i32(ctx, buf, pos_args[0])
        // Untag: arithmetic right shift by 2 to get raw i64 bits
        emit_i64_const_raw(buf, 2L)
        emit_i64_shr_s(buf)
        // Reinterpret i64 bits as f64
        emit_f64_reinterpret_i64(buf)
      })
    }
    // Char::to_int / Char::from_int migrated to the builtin registry
    // (Phase B-1, #415) — see builtin_registry.mbt.
    _ => raise WasmGenError::Unsupported(pre_user_builtin_unhandled_marker)
  }
}
