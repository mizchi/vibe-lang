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
      // `perform(Ctor(args))` (function-call form) needs to behave like the
      // keyword form `perform Effect::Op(args)` so the surrounding handle
      // can dispatch on the ctor name as a string. Without this, the handler
      // compares a thrown enum-object pointer to a literal ctor-name string
      // and the dispatch never matches — the retry loop runs to OOB.
      let inner = pos_args[0]
      let ctor_payload : (String, Array[@core.Expr], @core.Span)? = match inner {
        @core.Expr::Call(name~, args=ctor_args, span~, ..) =>
          if @core.is_ctor_name(name) &&
            ctx.need_effect_resume &&
            ctx.effect_perform_arg_global >= 0 {
            let exprs = extract_positional_exprs(ctor_args, name)
            Some((name, exprs, span))
          } else {
            None
          }
        _ => None
      }
      match ctor_payload {
        Some((ctor_name, payload_exprs, ctor_span)) => {
          // Look up the qualified key "Effect::Ctor" the surrounding handle
          // expects. The scan pass populated `effect_handled_ops` with the
          // qualified ctor names from in-scope handle arms; pick the entry
          // ending in "::ctor_name". If no in-scope handle owns this op,
          // fall back to the bare ctor name (the handler will not match
          // and the throw will propagate, same as before).
          let suffix = "::" + ctor_name
          let mut qualified_key = ctor_name
          for handled_key, _ in ctx.effect_handled_ops {
            if handled_key.has_suffix(suffix) {
              qualified_key = handled_key
              break
            }
          }
          // Mirror Expr::Perform's flow: on retry-iteration, read from the
          // resume buffer instead of throwing. Without this branch the
          // handle's retry loop would re-throw forever and overflow the
          // 64-slot resume buffer — which surfaces as `memory access out
          // of bounds` from the i64.store at the next slot.
          if ctx.need_effect_resume && ctx.effect_resume_idx_global >= 0 {
            // if (resume_idx < resume_count) { return resume_buf[idx++ * 8] }
            emit_global_get(buf, ctx.effect_resume_idx_global)
            emit_global_get(buf, ctx.effect_resume_count_global)
            emit_i32_lt_s(buf)
            buf.push((4).to_byte()) // if
            buf.push((126).to_byte()) // result i64
            emit_global_get(buf, ctx.effect_resume_buf_global)
            emit_global_get(buf, ctx.effect_resume_idx_global)
            emit_i32_const_raw(buf, 8)
            emit_i32_mul(buf)
            emit_i32_add(buf)
            emit_i64_load(buf, 0)
            emit_global_get(buf, ctx.effect_resume_idx_global)
            emit_i32_const_raw(buf, 1)
            emit_i32_add(buf)
            emit_global_set(buf, ctx.effect_resume_idx_global)
            buf.push((5).to_byte()) // else
            // Store payload in effect_perform_arg_global, then throw key.
            if payload_exprs.length() == 0 {
              emit_i64_const_raw(buf, 0L)
            } else if payload_exprs.length() == 1 {
              compile_expr_i32(ctx, buf, payload_exprs[0])
            } else {
              let tuple_expr = @core.Expr::Tuple(
                items=payload_exprs, span=ctor_span,
              )
              compile_expr_i32(ctx, buf, tuple_expr)
            }
            emit_global_set(buf, ctx.effect_perform_arg_global)
            let tag_str = @core.Expr::String(
              value=qualified_key, span=ctor_span,
            )
            compile_expr_raise(ctx, buf, tag_str)
            buf.push((11).to_byte()) // end if
          } else {
            // No resume context: just store payload + throw.
            if payload_exprs.length() == 0 {
              emit_i64_const_raw(buf, 0L)
            } else if payload_exprs.length() == 1 {
              compile_expr_i32(ctx, buf, payload_exprs[0])
            } else {
              let tuple_expr = @core.Expr::Tuple(
                items=payload_exprs, span=ctor_span,
              )
              compile_expr_i32(ctx, buf, tuple_expr)
            }
            emit_global_set(buf, ctx.effect_perform_arg_global)
            let tag_str = @core.Expr::String(
              value=qualified_key, span=ctor_span,
            )
            compile_expr_raise(ctx, buf, tag_str)
          }
        }
        None => {
          // Fallback: throw the value directly (legacy behavior for
          // non-ctor payloads or when no resume-handler is in scope).
          if ctx.use_js_strings {
            compile_expr(ctx, buf, inner)
          } else {
            compile_expr_i32(ctx, buf, inner)
          }
          buf.push((8).to_byte()) // throw
          write_u32_leb(buf, ctx.error_tag_index)
        }
      }
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
