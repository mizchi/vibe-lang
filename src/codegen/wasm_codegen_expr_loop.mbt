///|
fn compile_expr_while(
  ctx : CodegenCtx,
  buf : ByteBuf,
  cond : @core.Expr,
  body : @core.Module,
) -> Unit raise WasmGenError {
  // Save loop offsets for nesting
  let saved_break = ctx.loop_break_offset
  let saved_continue = ctx.loop_continue_offset
  let saved_param_locals = ctx.loop_param_locals

  emit_block(buf) // block $exit (label 1)
  emit_loop(buf) // loop $continue (label 0)

  // Set offsets: from inside loop body, break=1 (outer block), continue=0 (inner loop)
  ctx.loop_break_offset = 1
  ctx.loop_continue_offset = 0
  ctx.loop_param_locals = []

  // Evaluate condition
  compile_expr_i32(ctx, buf, cond)
  // Extract bool value: (tagged >> 2) & 1
  emit_i64_const_raw(buf, 2L)
  emit_i64_shr_u(buf)
  emit_i32_wrap_i64(buf)
  emit_i32_const_raw(buf, 1)
  emit_i32_and(buf)
  // If condition is 0, exit loop
  emit_i32_eqz(buf)
  emit_br_if(buf, 1) // br_if $exit (label 1 = outer block)

  // Execute body
  for i in 0..<body.stmts.length() {
    compile_stmt(ctx, buf, body.stmts[i], false)
  }

  // Loop back to continue
  emit_br(buf, 0) // br $continue (label 0 = inner loop)
  emit_end(buf) // end loop
  emit_end(buf) // end block

  // Restore loop offsets
  ctx.loop_break_offset = saved_break
  ctx.loop_continue_offset = saved_continue
  ctx.loop_param_locals = saved_param_locals

  // While expression returns unit
  emit_i64_const_tagged(buf, 0L)
}

///|
fn compile_expr_break(
  ctx : CodegenCtx,
  buf : ByteBuf,
  value : @core.Expr?,
) -> Unit raise WasmGenError {
  if ctx.loop_break_offset < 0 {
    raise WasmGenError::Unsupported("break outside loop")
  }
  match value {
    Some(expr) => compile_expr(ctx, buf, expr)
    None => emit_i64_const_tagged(buf, 0L)
  }
  emit_br(buf, ctx.loop_break_offset)
  emit_unreachable(buf)
}

///|
fn compile_expr_continue(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.Expr],
) -> Unit raise WasmGenError {
  if ctx.loop_continue_offset < 0 {
    raise WasmGenError::Unsupported("continue outside loop")
  }
  // For parameterized loop: set args to temp locals, then copy to param locals
  if args.length() > 0 {
    let param_locals = ctx.loop_param_locals
    if args.length() != param_locals.length() {
      raise WasmGenError::Unsupported("continue arity mismatch")
    }
    // Compile all args to temp locals first (avoid mutual overwrite)
    let temps : Array[Int] = []
    for arg in args {
      let tmp = ctx.local_count
      ctx.local_count += 1
      ctx.local_types.push(ValueKind::I64)
      compile_expr(ctx, buf, arg)
      emit_local_set(buf, tmp)
      temps.push(tmp)
    }
    // Copy temps to param locals
    for i in 0..<temps.length() {
      emit_local_get(buf, temps[i])
      emit_local_set(buf, param_locals[i])
    }
  }
  emit_br(buf, ctx.loop_continue_offset)
  emit_unreachable(buf)
}

///|
fn compile_expr_loop(
  ctx : CodegenCtx,
  buf : ByteBuf,
  params : Array[@core.LoopParam],
  body : @core.Module,
) -> Unit raise WasmGenError {
  // Save loop offsets for nesting
  let saved_break = ctx.loop_break_offset
  let saved_continue = ctx.loop_continue_offset
  let saved_param_locals = ctx.loop_param_locals
  let saved_locals = ctx.locals.copy()
  let saved_kinds = ctx.local_kinds.copy()

  // Allocate locals for loop params and compile init expressions
  let param_locals : Array[Int] = []
  for param in params {
    let idx = ctx.local_count
    ctx.local_count += 1
    ctx.local_types.push(ValueKind::I64)
    compile_expr(ctx, buf, param.init)
    emit_local_set(buf, idx)
    ctx.locals[param.name] = idx
    ctx.local_kinds[param.name] = if ctx.use_js_strings {
      ValueKind::I32
    } else {
      ValueKind::I64
    }
    param_locals.push(idx)
  }
  ctx.loop_param_locals = param_locals

  // block $exit (result i64)  -- break value lands here
  //   loop $continue          -- continue jumps here
  //     <body>
  //   end
  // end
  emit_block_i64(buf) // block $exit (result i64)
  emit_loop(buf) // loop $continue

  // Set offsets: break=1 (outer block), continue=0 (inner loop)
  ctx.loop_break_offset = 1
  ctx.loop_continue_offset = 0

  // Compile body
  let len = body.stmts.length()
  if len == 0 {
    emit_i64_const_tagged(buf, 0L)
  } else {
    for i in 0..<len {
      let is_last = i == len - 1
      compile_stmt(ctx, buf, body.stmts[i], is_last)
    }
  }

  emit_end(buf) // end loop
  emit_end(buf) // end block

  // Restore
  ctx.loop_break_offset = saved_break
  ctx.loop_continue_offset = saved_continue
  ctx.loop_param_locals = saved_param_locals
  restore_locals(ctx, saved_locals)
  restore_local_kinds(ctx, saved_kinds)
}
