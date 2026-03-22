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
fn emit_handle_try_header_with_valtype(
  ctx : CodegenCtx,
  buf : ByteBuf,
  result_kind : ValueKind,
  error_kind : ValueKind,
) -> Unit {
  adjust_loop_offsets(ctx, 3)
  buf.push((2).to_byte())
  buf.push(valtype_byte(result_kind))
  buf.push((2).to_byte())
  buf.push(valtype_byte(error_kind))
  buf.push((31).to_byte())
  buf.push(valtype_byte(result_kind))
  write_u32_leb(buf, 1)
  buf.push((0).to_byte())
  write_u32_leb(buf, ctx.error_tag_index)
  write_u32_leb(buf, 0)
}

///|
fn emit_handle_try_header_with_type_idx(
  ctx : CodegenCtx,
  buf : ByteBuf,
  type_idx : Int,
  error_kind : ValueKind,
) -> Unit {
  adjust_loop_offsets(ctx, 3)
  buf.push((2).to_byte())
  write_i32_leb(buf, type_idx)
  buf.push((2).to_byte())
  buf.push(valtype_byte(error_kind))
  buf.push((31).to_byte())
  write_i32_leb(buf, type_idx)
  write_u32_leb(buf, 1)
  buf.push((0).to_byte())
  write_u32_leb(buf, ctx.error_tag_index)
  write_u32_leb(buf, 0)
}

///|
fn emit_handle_try_success_to_catch(buf : ByteBuf) -> Unit {
  buf.push((11).to_byte())
  buf.push((12).to_byte())
  write_u32_leb(buf, 1)
  buf.push((11).to_byte())
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
  // Separate effect arms (Effect::Op pattern) from error arms
  let effect_arms : Array[@core.MatchArm] = []
  let error_arms : Array[@core.MatchArm] = []
  for arm in arms {
    match arm.pat {
      @core.Pat::Ctor(name~, ..) if name.contains("::") =>
        effect_arms.push(arm)
      _ => error_arms.push(arm)
    }
  }
  // Use first error arm as catch handler (backward compatible)
  let catch_arm = if error_arms.length() > 0 {
    error_arms[0]
  } else if arms.length() > 0 {
    arms[0]
  } else {
    raise WasmGenError::Unsupported("handle with no arms")
  }
  let catch_body_mod = handle_catch_body_module(catch_arm.expr, span)
  let error_kind = handle_error_kind(ctx)
  let try_kind = if ctx.use_js_strings {
    infer_block_kind(ctx, body, ctx.local_kinds)
  } else {
    ValueKind::I64
  }
  emit_handle_try_header_with_valtype(ctx, buf, try_kind, error_kind)
  compile_block_expr(ctx, buf, body)
  emit_handle_try_success_to_catch(buf)
  adjust_loop_offsets(ctx, -1)
  let error_local = alloc_temp_local_with_kind(ctx, error_kind)
  emit_local_set(buf, error_local)
  if effect_arms.length() > 0 && error_arms.length() > 0 {
    // Both effect and error arms: dispatch by checking caught value
    // Effect arms get the thrown tag string; error arms get the error value
    // For now, delegate to error arm (effect cross-function handled by interpreter)
    compile_handle_catch_body_expr(
      ctx, buf, catch_arm, catch_body_mod, error_kind, error_local,
    )
  } else {
    compile_handle_catch_body_expr(
      ctx, buf, catch_arm, catch_body_mod, error_kind, error_local,
    )
  }
  buf.push((11).to_byte())
  adjust_loop_offsets(ctx, -2)
}

///|
fn compile_expr_raise(
  ctx : CodegenCtx,
  buf : ByteBuf,
  value : @core.Expr,
) -> Unit raise WasmGenError {
  if ctx.use_js_strings {
    compile_expr(ctx, buf, value) // externref string on stack
  } else {
    // Always emit the full tagged string value so catch handlers
    // can inspect/compare the error payload as a real string.
    compile_expr(ctx, buf, value)
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
