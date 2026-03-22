///|
fn compile_expr_i32(
  ctx : CodegenCtx,
  buf : ByteBuf,
  expr : @core.Expr,
) -> Unit raise WasmGenError {
  if ctx.use_js_strings {
    let kind = infer_expr_kind(ctx, expr)
    if kind == ValueKind::ExternRef {
      raise WasmGenError::BackendLimit(
        backend="wasm-js-string",
        feature="i32 expression",
      )
    }
  }
  compile_expr(ctx, buf, expr)
}

///|
fn compile_expr_ref(
  ctx : CodegenCtx,
  buf : ByteBuf,
  expr : @core.Expr,
) -> Unit raise WasmGenError {
  if ctx.use_js_strings {
    let kind = infer_expr_kind(ctx, expr)
    if kind != ValueKind::ExternRef {
      raise WasmGenError::BackendLimit(
        backend="wasm-js-string",
        feature="ref expression",
      )
    }
  }
  compile_expr(ctx, buf, expr)
}

///|
fn compile_expr(
  ctx : CodegenCtx,
  buf : ByteBuf,
  expr : @core.Expr,
) -> Unit raise WasmGenError {
  // Save and reset tail position. Only Call, If, Match, Block will restore it.
  let saved_tail = ctx.is_tail_position
  ctx.is_tail_position = false
  match expr {
    @core.Expr::Int(value=n, span~) => {
      let _ = span
      emit_i64_const_tagged(buf, n)
    }
    @core.Expr::Float(value=n, span~) => {
      let _ = span
      emit_boxed_f32(ctx, buf, () => emit_f32_const(buf, n))
    }
    @core.Expr::Double(value=n, span~) => {
      let _ = span
      emit_boxed_f64(ctx, buf, () => emit_f64_const(buf, n))
    }
    @core.Expr::Bool(value=b, span~) => {
      let _ = span
      emit_i64_const_raw(buf, tag_bool_value64(b))
    }
    @core.Expr::Char(value=c, span~) => {
      let _ = span
      emit_i64_const_tagged(buf, c.to_int().to_int64())
    }
    @core.Expr::String(value=s, span~) => {
      let _ = span
      compile_expr_string(ctx, buf, s)
    }
    @core.Expr::Ident(name~, span~) => {
      let _ = span
      compile_expr_ident(ctx, buf, name)
    }
    @core.Expr::Placeholder(..) =>
      raise WasmGenError::Unsupported("placeholder in codegen")
    @core.Expr::Call(name~, args~, span~, ..) => {
      let _ = span
      ctx.is_tail_position = saved_tail // restore for tail call optimization
      compile_expr_call(ctx, buf, expr, name, args)
    }
    @core.Expr::Tuple(items~, span~) => {
      let _ = span
      compile_tuple_expr(ctx, buf, items)
    }
    @core.Expr::TupleIndex(expr=inner, index~, span~) => {
      let _ = span
      compile_expr_tuple_index(ctx, buf, inner, index)
    }
    @core.Expr::Record(fields~, span~) => {
      let _ = span
      compile_record_expr(ctx, buf, fields)
    }
    @core.Expr::Array(items~, span~) => {
      let _ = span
      compile_array_expr(ctx, buf, items)
    }
    @core.Expr::Map(fields~, span~) => {
      let _ = span
      compile_map_expr(ctx, buf, fields)
    }
    @core.Expr::If(cond~, then_body~, else_body~, span~) => {
      ctx.is_tail_position = saved_tail // propagate to branches
      compile_expr_if(ctx, buf, expr, cond, then_body, else_body, span)
    }
    @core.Expr::Block(body~, span~) => {
      let _ = span
      ctx.is_tail_position = saved_tail // propagate to last expression
      compile_block_expr(ctx, buf, body)
    }
    @core.Expr::Match(scrutinee~, arms~, span~) => {
      let _ = span
      ctx.is_tail_position = saved_tail // propagate to arms
      compile_expr_match(ctx, buf, scrutinee, arms)
    }
    @core.Expr::ForIn(value_name~, index_name~, iterable~, body~, span~) => {
      let desugared = @core.desugar_for_in(
        value_name, index_name, iterable, body, span,
      )
      compile_block_expr(ctx, buf, desugared)
    }
    @core.Expr::Perform(effect_name="Error", op_name="Throw", args~, span~) => {
      let value = if args.length() >= 1 {
        args[0].expr
      } else {
        @core.Expr::String(value="", span~)
      }
      compile_expr_raise(ctx, buf, value)
    }
    @core.Expr::Perform(effect_name~, op_name~, args~, span~) => {
      let key = effect_name + "::" + op_name
      // Check if this perform has a registered import (e.g. Fs::ReadFile)
      match ctx.effect_op_imports.get(key) {
        Some(idx) if idx >= 0 => {
          // External effect: call imported function
          for arg in args {
            compile_expr(ctx, buf, arg.expr)
          }
          buf.push((0x41).to_byte()) // i32.const 0 (closure env)
          buf.push((0).to_byte())
          emit_call(buf, idx)
        }
        _ => {
          // User-defined effect: check resume globals first, then throw.
          if ctx.need_effect_resume &&
            ctx.effect_resume_idx_global >= 0 {
            // if (resume_idx < resume_count) { return resume_buf[resume_idx++ * 8] }
            emit_global_get(buf, ctx.effect_resume_idx_global)
            emit_global_get(buf, ctx.effect_resume_count_global)
            emit_i32_lt_s(buf)
            buf.push((4).to_byte()) // if
            buf.push((126).to_byte()) // result i64
            // Read resume value: buf_ptr + idx * 8
            emit_global_get(buf, ctx.effect_resume_buf_global)
            emit_global_get(buf, ctx.effect_resume_idx_global)
            emit_i32_const_raw(buf, 8)
            emit_i32_mul(buf)
            emit_i32_add(buf)
            emit_i64_load(buf, 0)
            // Increment idx
            emit_global_get(buf, ctx.effect_resume_idx_global)
            emit_i32_const_raw(buf, 1)
            emit_i32_add(buf)
            emit_global_set(buf, ctx.effect_resume_idx_global)
            buf.push((5).to_byte()) // else
            // Throw for cross-function dispatch
            let tag_str = @core.Expr::String(value=key, span~)
            compile_expr_raise(ctx, buf, tag_str)
            buf.push((11).to_byte()) // end if
          } else {
            let tag_str = @core.Expr::String(value=key, span~)
            compile_expr_raise(ctx, buf, tag_str)
          }
        }
      }
    }
    @core.Expr::Handle(body~, arms~, span~) =>
      compile_expr_handle(ctx, buf, body, arms, span)
    @core.Expr::Fn(span~, ..) => compile_expr_fn(ctx, buf, span)
    @core.Expr::While(cond~, body~, span~) => {
      let _ = span
      compile_expr_while(ctx, buf, cond, body)
    }
    @core.Expr::Break(value~, span~) => {
      let _ = span
      compile_expr_break(ctx, buf, value)
    }
    @core.Expr::Continue(args~, span~) => {
      let _ = span
      compile_expr_continue(ctx, buf, args)
    }
    @core.Expr::Loop(params~, body~, span~) => {
      let _ = span
      compile_expr_loop(ctx, buf, params, body)
    }
    @core.Expr::Yield(expr=inner, span~) => {
      let _ = span
      compile_expr_yield(ctx, buf, inner)
    }
    @core.Expr::StructLit(fields~, span~, ..) => {
      let _ = span
      compile_record_expr(ctx, buf, fields)
    }
    @core.Expr::Spread(span~, ..) => {
      let _ = span
      raise WasmGenError::Unsupported("spread outside array literal")
    }
    // StringInterp is lowered in desugar; should never reach codegen
    @core.Expr::StringInterp(span~, ..) => {
      let _ = span
      raise WasmGenError::Unsupported("StringInterp should have been desugared")
    }
  }
}
