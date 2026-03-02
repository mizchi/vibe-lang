///|
fn handle_arm_bind_name(pat : @core.Pat) -> String? {
  match pat {
    @core.Pat::Bind(name~, span~) => {
      let _ = span
      Some(name)
    }
    @core.Pat::Ctor(name~, args~, span~) => {
      let _ = span
      if name == "Error" && args.length() == 1 {
        match args[0] {
          @core.Pat::Bind(name=bind_name, span~) => {
            let _ = span
            Some(bind_name)
          }
          _ => None
        }
      } else {
        None
      }
    }
    _ => None
  }
}

///|
fn handle_catch_body_module(
  expr : @core.Expr,
  span : @core.Span,
) -> @core.Module {
  match expr {
    @core.Expr::Block(body=blk_body, ..) => blk_body
    other => @core.Module::{ stmts: [@core.Stmt::Expr(expr=other, span~)] }
  }
}

///|
fn handle_error_kind(ctx : CodegenCtx) -> ValueKind {
  if ctx.use_js_strings {
    ValueKind::ExternRef
  } else {
    ValueKind::I64
  }
}

///|
fn compile_handle_catch_body_expr(
  ctx : CodegenCtx,
  buf : ByteBuf,
  catch_arm : @core.MatchArm,
  catch_body_mod : @core.Module,
  error_kind : ValueKind,
  error_local : Int,
) -> Unit raise WasmGenError {
  match handle_arm_bind_name(catch_arm.pat) {
    Some(bind_name) => {
      let prev_local = ctx.locals.get(bind_name)
      let prev_kind = ctx.local_kinds.get(bind_name)
      let bind_local = alloc_temp_local_with_kind(ctx, error_kind)
      emit_local_get(buf, error_local)
      emit_local_set(buf, bind_local)
      ctx.locals[bind_name] = bind_local
      ctx.local_kinds[bind_name] = error_kind
      compile_block_expr(ctx, buf, catch_body_mod)
      match prev_local {
        Some(idx) => ctx.locals[bind_name] = idx
        None => ctx.locals.remove(bind_name)
      }
      match prev_kind {
        Some(kind) => ctx.local_kinds[bind_name] = kind
        None => ctx.local_kinds.remove(bind_name)
      }
    }
    None => compile_block_expr(ctx, buf, catch_body_mod)
  }
}

///|
fn compile_expr_handle(
  ctx : CodegenCtx,
  buf : ByteBuf,
  body : @core.Module,
  arms : Array[@core.MatchArm],
  span : @core.Span,
) -> Unit raise WasmGenError {
  // Phase 1: compile Handle like Try, using first arm's expr as catch_body
  let catch_arm = arms[0]
  let catch_body_mod = handle_catch_body_module(catch_arm.expr, span)
  let error_kind = handle_error_kind(ctx)
  let try_kind = if ctx.use_js_strings {
    infer_block_kind(ctx, body, ctx.local_kinds)
  } else {
    ValueKind::I64
  }
  adjust_loop_offsets(ctx, 3)
  buf.push((2).to_byte())
  buf.push(valtype_byte(try_kind))
  buf.push((2).to_byte())
  buf.push(valtype_byte(error_kind))
  buf.push((31).to_byte())
  buf.push(valtype_byte(try_kind))
  write_u32_leb(buf, 1)
  buf.push((0).to_byte())
  write_u32_leb(buf, ctx.error_tag_index)
  write_u32_leb(buf, 0)
  compile_block_expr(ctx, buf, body)
  buf.push((11).to_byte())
  buf.push((12).to_byte())
  write_u32_leb(buf, 1)
  buf.push((11).to_byte())
  adjust_loop_offsets(ctx, -1)
  let error_local = alloc_temp_local_with_kind(ctx, error_kind)
  emit_local_set(buf, error_local)
  compile_handle_catch_body_expr(
    ctx, buf, catch_arm, catch_body_mod, error_kind, error_local,
  )
  buf.push((11).to_byte())
  adjust_loop_offsets(ctx, -2)
}

///|
fn compile_expr_raise(
  ctx : CodegenCtx,
  buf : ByteBuf,
  value : @core.Expr,
) -> Unit raise WasmGenError {
  if not(ctx.use_js_strings) && not(ctx.embed_error_strings) {
    match value {
      @core.Expr::String(value=message, span~) => {
        let _ = span
        emit_i64_const_tagged(buf, intern_error_code(ctx, message).to_int64())
      }
      _ => compile_expr_i32(ctx, buf, value)
    }
  } else if ctx.use_js_strings {
    compile_expr(ctx, buf, value) // externref string on stack
  } else {
    compile_expr_i32(ctx, buf, value) // tagged i32 string on stack
  }
  buf.push((8).to_byte()) // throw opcode = 0x08
  write_u32_leb(buf, ctx.error_tag_index) // tag index
}

///|
fn compile_expr_yield(
  ctx : CodegenCtx,
  buf : ByteBuf,
  expr : @core.Expr,
) -> Unit raise WasmGenError {
  // Compile the expression to get the value to yield
  compile_expr_i32(ctx, buf, expr)
  // Emit suspend instruction with await tag (yield uses same tag)
  buf.push((0xe2).to_byte())
  write_u32_leb(buf, ctx.await_tag_index)
  // Yield returns Unit - the suspend result is dropped and we return 0
  buf.push((26).to_byte()) // drop the suspend result
  emit_i64_const_raw(buf, tag_int_value64(0L))
}
