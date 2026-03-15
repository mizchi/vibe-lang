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
    @core.Expr::Raise(value~, span~) => {
      let _ = span
      compile_expr_raise(ctx, buf, value)
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
  }
}
