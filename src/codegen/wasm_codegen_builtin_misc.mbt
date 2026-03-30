///|
fn compile_builtin_misc(
  ctx : CodegenCtx,
  buf : ByteBuf,
  name : String,
  args : Array[@core.CallArg],
  _is_user_fn : Bool,
) -> Unit raise WasmGenError {
  match name {
    "Threads::probe_wat" => {
      let _ = extract_positional_exprs_with_arity(args, "Threads::probe_wat", 0)
      emit_string_const(ctx, buf, "(module)")
    }
    "Threads::runtime_hints" => {
      let _ = extract_positional_exprs_with_arity(
        args, "Threads::runtime_hints", 0,
      )
      emit_i64_const_tagged(buf, 0L)
    }
    "wasm_env" => {
      let pos_args = extract_positional_exprs_with_arity(args, "wasm_env", 1)
      compile_expr(ctx, buf, pos_args[0])
      emit_drop(buf)
      emit_string_const(ctx, buf, "threads=y shared-memory=y")
    }
    "wasi_env" => {
      let pos_args = extract_positional_exprs_with_arity(args, "wasi_env", 1)
      compile_expr(ctx, buf, pos_args[0])
      emit_drop(buf)
      emit_string_const(ctx, buf, "threads=y")
    }
    "Threads::channel_new" => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "Threads::channel_new", 1,
      )
      let cap_local = alloc_temp_local(ctx)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_int_i32(buf)
      emit_local_set(buf, cap_local)
      emit_local_get(buf, cap_local)
      emit_i32_const_raw(buf, 0)
      emit_i32_lt_s(buf)
      buf.push((4).to_byte()) // if
      buf.push((127).to_byte()) // result i32
      emit_i32_const_raw(buf, 0)
      buf.push((5).to_byte()) // else
      emit_local_get(buf, cap_local)
      buf.push((11).to_byte()) // end if
      emit_i64_extend_i32_s(buf)
      emit_i64_const_raw(buf, 2L)
      emit_i64_shl(buf)
      // tag_int = 0, i64.or is a no-op
    }
    "Threads::spawn" => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "Threads::spawn", 2,
      )
      compile_expr(ctx, buf, pos_args[0])
      emit_drop(buf)
      compile_expr_i32(ctx, buf, pos_args[1])
    }
    "Threads::send" => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "Threads::send", 2,
      )
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_drop(buf)
      compile_expr(ctx, buf, pos_args[1])
      emit_drop(buf)
      emit_i64_const_raw(buf, tag_bool_value64(true))
    }
    "Threads::recv" => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "Threads::recv", 1,
      )
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_drop(buf)
      emit_string_const(ctx, buf, "")
    }
    "Threads::wait" => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "Threads::wait", 1,
      )
      compile_expr_i32(ctx, buf, pos_args[0])
    }
    "__perform" => {
      let pos_args = extract_positional_exprs_with_arity(args, "__perform", 1)
      if ctx.use_js_strings {
        compile_expr(ctx, buf, pos_args[0])
      } else {
        compile_expr_i32(ctx, buf, pos_args[0])
      }
      buf.push((8).to_byte()) // throw
      write_u32_leb(buf, ctx.error_tag_index)
    }
    "__resume" => {
      let pos_args = extract_positional_exprs_with_arity(args, "__resume", 1)
      // Experimental fallback: encode resume as throw on wasm backend.
      // Proper continuation resume requires stack-switching-aware lowering.
      if ctx.use_js_strings {
        compile_expr(ctx, buf, pos_args[0])
      } else {
        compile_expr_i32(ctx, buf, pos_args[0])
      }
      buf.push((8).to_byte()) // throw
      write_u32_leb(buf, ctx.error_tag_index)
    }
    _ => raise WasmGenError::Unsupported(pre_user_builtin_unhandled_marker)
  }
}
