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
  if effect_arms.length() > 0 && ctx.need_effect_resume {
    compile_expr_handle_with_resume(ctx, buf, body, effect_arms, error_arms, span)
  } else {
    compile_expr_handle_error_only(ctx, buf, body, arms, span)
  }
}

///|
fn compile_expr_handle_error_only(
  ctx : CodegenCtx,
  buf : ByteBuf,
  body : @core.Module,
  arms : Array[@core.MatchArm],
  span : @core.Span,
) -> Unit raise WasmGenError {
  let catch_arm = if arms.length() > 0 {
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
  compile_handle_catch_body_expr(
    ctx, buf, catch_arm, catch_body_mod, error_kind, error_local,
  )
  buf.push((11).to_byte())
  adjust_loop_offsets(ctx, -2)
}

///|
/// Handle with effect resume loop:
/// block $exit (result i64) {
///   loop $retry {
///     try (result i64) { body; br $exit }
///     catch { handler → store resume value → br $retry }
///   }
/// }
fn compile_expr_handle_with_resume(
  ctx : CodegenCtx,
  buf : ByteBuf,
  body : @core.Module,
  effect_arms : Array[@core.MatchArm],
  _error_arms : Array[@core.MatchArm],
  _span : @core.Span,
) -> Unit raise WasmGenError {
  let error_kind = handle_error_kind(ctx)
  require_heap(ctx)
  // Allocate resume buffer on heap (max 64 slots = 512 bytes)
  let resume_buf_local = alloc_temp_local(ctx)
  emit_heap_alloc(ctx, buf, 512, resume_buf_local)
  // Initialize resume globals: idx=0, count=0, buf=allocated
  emit_i32_const_raw(buf, 0)
  emit_global_set(buf, ctx.effect_resume_idx_global)
  emit_i32_const_raw(buf, 0)
  emit_global_set(buf, ctx.effect_resume_count_global)
  emit_local_get(buf, resume_buf_local)
  emit_global_set(buf, ctx.effect_resume_buf_global)
  // Structure:
  // block $exit (result i64)                    ; depth 0
  //   loop $retry                               ; depth 1
  //     block $catch_target (result error_kind)  ; depth 2 — catch lands here
  //       try_table (result i64)                 ; depth 3
  //         (catch error_tag $catch_target)
  //         {body}
  //         br $exit                            ; success → exit
  //       end try_table                         ; depth 3
  //       br 1                                  ; skip catch → back to $exit via loop end
  //     end $catch_target                       ; depth 2 — error value on stack
  //     ← handler code here (error value in local)
  //     ← store resume value, br $retry
  //   end loop                                  ; depth 1
  //   unreachable                               ; loop doesn't produce value
  // end $exit                                   ; depth 0 — result on stack

  // block $exit (result i64)
  buf.push((2).to_byte()) // block
  buf.push((126).to_byte()) // result i64
  // loop $retry (void)
  buf.push((3).to_byte()) // loop
  buf.push((64).to_byte()) // void
  // Reset resume idx at start of each retry
  emit_i32_const_raw(buf, 0)
  emit_global_set(buf, ctx.effect_resume_idx_global)
  // block $catch_target (result error_kind)
  buf.push((2).to_byte()) // block
  buf.push(valtype_byte(error_kind)) // result error_kind
  // try_table (result i64) (catch error_tag $catch_target)
  buf.push((31).to_byte()) // try_table opcode
  buf.push((126).to_byte()) // result i64
  write_u32_leb(buf, 1) // 1 handler
  buf.push((0).to_byte()) // catch (not catch_ref)
  write_u32_leb(buf, ctx.error_tag_index) // tag index
  write_u32_leb(buf, 0) // branch to $catch_target (depth 0 = immediate outer block)
  adjust_loop_offsets(ctx, 4) // block + loop + block + try_table
  // {body}
  compile_block_expr(ctx, buf, body)
  // br $exit (success path — 4 levels up: try_table → catch_block → loop → exit)
  buf.push((12).to_byte()) // br
  write_u32_leb(buf, 3) // $exit
  // end try_table
  buf.push((11).to_byte())
  // br $exit (skip catch, exit with try_table result — shouldn't reach if body succeeds)
  buf.push((12).to_byte())
  write_u32_leb(buf, 2) // $exit = loop(1) → exit_block(2)
  // end $catch_target — error value now on stack
  buf.push((11).to_byte())
  // Handler code: error value is on stack
  let caught_local = alloc_temp_local_with_kind(ctx, error_kind)
  emit_local_set(buf, caught_local)
  if effect_arms.length() > 0 {
    let arm = effect_arms[0]
    let resume_expr = extract_resume_value_expr(arm.expr)
    // Bind handler param if present
    match arm.pat {
      @core.Pat::Ctor(args~, ..) if args.length() > 0 =>
        match args[0] {
          @core.Pat::Bind(name~, ..) => {
            let bind_local = alloc_temp_local_with_kind(ctx, error_kind)
            emit_local_get(buf, caught_local)
            emit_local_set(buf, bind_local)
            ctx.locals[name] = bind_local
            ctx.local_kinds[name] = error_kind
          }
          _ => ()
        }
      _ => ()
    }
    compile_expr(ctx, buf, resume_expr)
    // Store resume value: buf[count * 8] = value
    let resume_val_local = alloc_temp_local_with_kind(ctx, ValueKind::I64)
    emit_local_set(buf, resume_val_local)
    emit_global_get(buf, ctx.effect_resume_buf_global)
    emit_global_get(buf, ctx.effect_resume_count_global)
    emit_i32_const_raw(buf, 8)
    emit_i32_mul(buf)
    emit_i32_add(buf)
    emit_local_get(buf, resume_val_local)
    emit_i64_store(buf, 0)
    // Increment count
    emit_global_get(buf, ctx.effect_resume_count_global)
    emit_i32_const_raw(buf, 1)
    emit_i32_add(buf)
    emit_global_set(buf, ctx.effect_resume_count_global)
  }
  // br $retry (loop back — depth 0 from handler position = loop)
  buf.push((12).to_byte()) // br
  write_u32_leb(buf, 0) // $retry (loop)
  // end loop
  buf.push((11).to_byte())
  // unreachable (loop doesn't produce a value for the block)
  buf.push((0).to_byte()) // unreachable
  // end block $exit
  buf.push((11).to_byte())
  adjust_loop_offsets(ctx, -4)
}

///|
/// Extract the expression inside resume(...) from a handler body.
/// E.g., `resume(10)` → `Int(10)`, `{ buf.push(v); resume(()) }` → `Unit`
fn extract_resume_value_expr(expr : @core.Expr) -> @core.Expr {
  match expr {
    @core.Expr::Call(name=fn_name, args~, ..) if fn_name == "__resume" =>
      if args.length() >= 1 {
        args[0].expr
      } else {
        @core.Expr::Int(value=0L, span=expr.span())
      }
    @core.Expr::Block(body~, ..) => {
      let stmts = body.stmts
      if stmts.length() > 0 {
        match stmts[stmts.length() - 1] {
          @core.Stmt::Expr(expr=last_expr, ..) =>
            extract_resume_value_expr(last_expr)
          _ => @core.Expr::Int(value=0L, span=expr.span())
        }
      } else {
        @core.Expr::Int(value=0L, span=expr.span())
      }
    }
    _ => expr
  }
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
