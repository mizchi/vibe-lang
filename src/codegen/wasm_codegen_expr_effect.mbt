///|
fn is_builtin_error_handler_name(name : String) -> Bool {
  name == "Error" || name == "Error::Throw" || name == "Throw"
}

///|
/// Extract the effect name (prefix before "::") from a qualified op key.
/// "Logger::Log" -> "Logger"; "Bare" -> "Bare" (used for enum-as-effect).
fn extract_effect_name_from_key(qualified : String) -> String {
  for i = 0; i + 1 < qualified.length(); i = i + 1 {
    if qualified[i] == ':' && qualified[i + 1] == ':' {
      return qualified[0:i].to_owned()
    }
  }
  qualified
}

///|
/// Look up the per-effect resume globals for a given effect name.
/// Returns (-1, -1, -1) when no handle in scope handles this effect.
fn get_effect_resume_globals(
  ctx : CodegenCtx,
  effect_name : String,
) -> (Int, Int, Int) {
  match ctx.effect_resume_globals.get(effect_name) {
    Some(t) => t
    None => (-1, -1, -1)
  }
}

///|
fn is_resume_effect_pat(pat : @core.Pat) -> Bool {
  match pat {
    @core.Pat::Ctor(name~, ..) =>
      name.contains("::") && !is_builtin_error_handler_name(name)
    _ => false
  }
}

///|
fn handle_arm_bind_name(pat : @core.Pat) -> String? {
  match pat {
    @core.Pat::Bind(name~, span~) => {
      let _ = span
      Some(name)
    }
    @core.Pat::Ctor(name~, args~, span~) => {
      let _ = span
      if is_builtin_error_handler_name(name) && args.length() == 1 {
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
    if is_resume_effect_pat(arm.pat) {
      effect_arms.push(arm)
    } else {
      error_arms.push(arm)
    }
  }
  if effect_arms.length() > 0 && ctx.need_effect_resume {
    compile_expr_handle_with_resume(
      ctx, buf, body, effect_arms, error_arms, span,
    )
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
  // Determine which effect this handle handles. One `with E { ... }` block
  // covers exactly one effect; pull the prefix off the first effect arm's
  // qualified key (e.g. "Logger::Log" -> "Logger"), and pick that effect's
  // (idx, count, buf) global triple.
  let handled_effect_name = match effect_arms[0].pat {
    @core.Pat::Ctor(name~, ..) => extract_effect_name_from_key(name)
    _ => ""
  }
  let (idx_g, count_g, buf_g) = get_effect_resume_globals(
    ctx, handled_effect_name,
  )
  // Save outer state for THIS effect to locals so a nested same-effect handle
  // (or a re-entry of a function that contains a handle) can re-read the
  // outer's resume buffer when this frame finishes. Without save/restore,
  // an outer handle's `count` would be permanently clobbered by inner init.
  let save_idx_local = alloc_temp_local(ctx)
  let save_count_local = alloc_temp_local(ctx)
  let save_buf_local = alloc_temp_local(ctx)
  emit_global_get(buf, idx_g)
  emit_local_set(buf, save_idx_local)
  emit_global_get(buf, count_g)
  emit_local_set(buf, save_count_local)
  emit_global_get(buf, buf_g)
  emit_local_set(buf, save_buf_local)
  // Allocate resume buffer on heap (max 64 slots = 512 bytes)
  let resume_buf_local = alloc_temp_local(ctx)
  emit_heap_alloc(ctx, buf, 512, resume_buf_local)
  // Initialize resume globals: idx=0, count=0, buf=allocated
  emit_i32_const_raw(buf, 0)
  emit_global_set(buf, idx_g)
  emit_i32_const_raw(buf, 0)
  emit_global_set(buf, count_g)
  emit_local_get(buf, resume_buf_local)
  emit_global_set(buf, buf_g)
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
  emit_global_set(buf, idx_g)
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
  // Handler code: error value (op key string) is on stack
  let caught_local = alloc_temp_local_with_kind(ctx, error_kind)
  emit_local_set(buf, caught_local)
  // Pre-allocate resume value local shared across all arms
  let resume_val_local = alloc_temp_local_with_kind(ctx, ValueKind::I64)
  if effect_arms.length() > 0 {
    // Dispatch: compare caught op key against each arm's pattern key
    for arm in effect_arms {
      let arm_key = match arm.pat {
        @core.Pat::Ctor(name~, ..) => name
        _ => continue
      }
      // Compare caught_local with arm's op key string
      if ctx.use_js_strings {
        ctx.need_js_equals = true
        emit_local_get(buf, caught_local)
        let str_idx = ctx.js_strings.intern(arm_key)
        emit_global_get(buf, str_idx)
        emit_call(buf, import_index_js_equals(ctx))
      } else {
        emit_local_get(buf, caught_local)
        let arm_key_expr = @core.Expr::String(value=arm_key, span=arm.span)
        compile_expr(ctx, buf, arm_key_expr)
        emit_i64_eq(buf)
      }
      buf.push((4).to_byte()) // if
      buf.push((64).to_byte()) // void
      adjust_loop_offsets(ctx, 1)
      // Save locals before compiling arm body so handler-param bindings and
      // prefix-stmt let bindings (from the Block branch below) do not leak
      // into later arms, where call resolution prefers ctx.locals over
      // globals and a stale binding could shadow an otherwise-global name.
      let saved_arm_locals = ctx.locals.copy()
      let saved_arm_local_kinds = ctx.local_kinds.copy()
      // Bind handler param from perform_arg global
      match arm.pat {
        @core.Pat::Ctor(args~, ..) if args.length() > 0 =>
          match args[0] {
            @core.Pat::Bind(name~, ..) => {
              let bind_local = alloc_temp_local_with_kind(ctx, ValueKind::I64)
              emit_global_get(buf, ctx.effect_perform_arg_global)
              emit_local_set(buf, bind_local)
              ctx.locals[name] = bind_local
              ctx.local_kinds[name] = ValueKind::I64
            }
            _ => ()
          }
        _ => ()
      }
      // Compile resume expression and store in shared local.
      // When the arm body is a Block ending in resume(...), the prefix stmts
      // establish bindings (`let v = ...`) and side effects that the resume
      // value expression references; compile them first, then extract the
      // final resume value so its locals are in scope.
      match arm.expr {
        @core.Expr::Block(body=arm_block, ..) => {
          let arm_stmts = arm_block.stmts
          let arm_len = arm_stmts.length()
          if arm_len > 0 {
            for i in 0..<(arm_len - 1) {
              compile_stmt(ctx, buf, arm_stmts[i], false)
            }
            let last_stmt = arm_stmts[arm_len - 1]
            let last_expr = match last_stmt {
              @core.Stmt::Expr(expr~, ..) => expr
              _ => arm.expr
            }
            let resume_expr = extract_resume_value_expr(last_expr)
            compile_expr(ctx, buf, resume_expr)
          } else {
            let resume_expr = extract_resume_value_expr(arm.expr)
            compile_expr(ctx, buf, resume_expr)
          }
        }
        _ => {
          let resume_expr = extract_resume_value_expr(arm.expr)
          compile_expr(ctx, buf, resume_expr)
        }
      }
      emit_local_set(buf, resume_val_local)
      ctx.locals = saved_arm_locals
      ctx.local_kinds = saved_arm_local_kinds
      buf.push((11).to_byte()) // end if
      adjust_loop_offsets(ctx, -1)
    }
    // Store resume value: buf[count * 8] = value
    emit_global_get(buf, buf_g)
    emit_global_get(buf, count_g)
    emit_i32_const_raw(buf, 8)
    emit_i32_mul(buf)
    emit_i32_add(buf)
    emit_local_get(buf, resume_val_local)
    emit_i64_store(buf, 0)
    // Increment count
    emit_global_get(buf, count_g)
    emit_i32_const_raw(buf, 1)
    emit_i32_add(buf)
    emit_global_set(buf, count_g)
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
  // Restore outer state for THIS effect from save_*. Result of handle is
  // already on the stack from $exit; restoring afterwards keeps it intact.
  // NOTE: this only fires on the success path (body→br $exit). When a perform
  // for a *different* effect throws past us, restoration of *that* effect's
  // globals is the responsibility of the outer handle that owns it; this
  // handle only manages its own.
  emit_local_get(buf, save_idx_local)
  emit_global_set(buf, idx_g)
  emit_local_get(buf, save_count_local)
  emit_global_set(buf, count_g)
  emit_local_get(buf, save_buf_local)
  emit_global_set(buf, buf_g)
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
    @core.Expr::If(cond~, then_body~, else_body~, span~) =>
      @core.Expr::If(
        cond~,
        then_body=extract_resume_module(then_body),
        else_body=extract_resume_module(else_body),
        span~,
      )
    @core.Expr::Match(scrutinee~, arms~, span~) => {
      let next_arms : Array[@core.MatchArm] = []
      for arm in arms {
        next_arms.push(@core.MatchArm::{
          pat: arm.pat,
          cond: arm.cond,
          expr: extract_resume_value_expr(arm.expr),
          span: arm.span,
        })
      }
      @core.Expr::Match(scrutinee~, arms=next_arms, span~)
    }
    _ => expr
  }
}

///|
/// Extract resume value from the last statement of a Module.
fn extract_resume_module(m : @core.Module) -> @core.Module {
  let stmts = m.stmts
  if stmts.length() > 0 {
    match stmts[stmts.length() - 1] {
      @core.Stmt::Expr(expr~, span~) => {
        let next_stmts : Array[@core.Stmt] = []
        for i = 0; i < stmts.length() - 1; i = i + 1 {
          next_stmts.push(stmts[i])
        }
        next_stmts.push(
          @core.Stmt::Expr(expr=extract_resume_value_expr(expr), span~),
        )
        @core.Module::{ stmts: next_stmts }
      }
      _ => m
    }
  } else {
    m
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
