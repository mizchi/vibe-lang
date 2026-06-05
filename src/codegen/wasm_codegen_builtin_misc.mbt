///|
fn threads_codegen_span() -> @core.Span {
  @core.Span::empty(0)
}

///|
fn threads_string_expr(value : String, span : @core.Span) -> @core.Expr {
  @core.Expr::String(value~, span~)
}

///|
fn threads_string_array_expr(
  values : Array[String],
  span : @core.Span,
) -> @core.Expr {
  let items : Array[@core.Expr] = []
  for value in values {
    items.push(threads_string_expr(value, span))
  }
  @core.Expr::Array(items~, span~)
}

///|
fn threads_record_field(
  name : String,
  expr : @core.Expr,
  span : @core.Span,
) -> @core.RecordFieldExpr {
  @core.RecordFieldExpr::{ name, expr, span }
}

///|
fn threads_runtime_hints_expr_for_backend(
  backend : @threads.ThreadBackend,
) -> @core.Expr {
  let span = threads_codegen_span()
  let wasm_flags = @threads.thread_backend_wasm_flags(backend)
  let wasi_flags = @threads.thread_backend_wasi_flags(backend)
  @core.Expr::Record(
    fields=[
      threads_record_field(
        "wasm_flags",
        threads_string_array_expr(wasm_flags, span),
        span,
      ),
      threads_record_field(
        "wasi_flags",
        threads_string_array_expr(wasi_flags, span),
        span,
      ),
      threads_record_field(
        "wasm_env",
        threads_string_expr(@threads.flags_to_env_value(wasm_flags), span),
        span,
      ),
      threads_record_field(
        "wasi_env",
        threads_string_expr(@threads.flags_to_env_value(wasi_flags), span),
        span,
      ),
    ],
    span~,
  )
}

///|
fn threads_backend_for_codegen_ctx(
  ctx : CodegenCtx,
) -> @threads.ThreadBackend raise WasmGenError {
  match @threads.thread_backend_from_id(ctx.thread_backend_id) {
    Some(backend) => backend
    None =>
      raise WasmGenError::Unsupported(
        "unknown Threads backend: " + ctx.thread_backend_id,
      )
  }
}

///|
fn threads_runtime_hints_expr(
  ctx : CodegenCtx,
) -> @core.Expr raise WasmGenError {
  threads_runtime_hints_expr_for_backend(threads_backend_for_codegen_ctx(ctx))
}

///|
fn require_linear_local_threads_backend(
  ctx : CodegenCtx,
  builtin_name : String,
) -> Unit raise WasmGenError {
  let backend = threads_backend_for_codegen_ctx(ctx)
  let lowering = @threads.thread_backend_compiled_stateful_lowering(backend)
  if lowering == @threads.ThreadCompiledStatefulLowering::LinearLocalStateful {
    return
  }
  raise WasmGenError::Unsupported(
    builtin_name +
    " is only connected for Threads backend " +
    @threads.thread_compiled_stateful_lowering_id(
      @threads.ThreadCompiledStatefulLowering::LinearLocalStateful,
    ) +
    "; selected backend " +
    @threads.thread_backend_id(backend) +
    " has stateful lowering " +
    @threads.thread_compiled_stateful_lowering_id(lowering),
  )
}

///|
fn emit_threads_int_handle_from_ptr(buf : ByteBuf, ptr_local : Int) -> Unit {
  emit_local_get(buf, ptr_local)
  emit_i64_extend_i32_u(buf)
  emit_i64_const_raw(buf, 2L)
  emit_i64_shl(buf)
}

///|
fn compile_threads_channel_new(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  let pos_args = extract_positional_exprs_with_arity(
    args, "Threads::channel_new", 1,
  )
  require_linear_local_threads_backend(ctx, "Threads::channel_new")
  require_heap(ctx)
  let abi = @threads.linear_thread_channel_abi()
  let ch_local = alloc_temp_local(ctx)
  let capacity_local = alloc_temp_local(ctx)
  emit_heap_alloc(ctx, buf, abi.size, ch_local)
  compile_expr_i32(ctx, buf, pos_args[0])
  emit_untag_int_i32(buf)
  emit_local_set(buf, capacity_local)
  emit_local_get(buf, ch_local)
  emit_local_get(buf, capacity_local)
  emit_i32_store(buf, abi.capacity_offset)
  emit_local_get(buf, ch_local)
  emit_i32_const_raw(buf, 0)
  emit_i32_store(buf, abi.length_offset)
  emit_local_get(buf, ch_local)
  emit_i32_const_raw(buf, 0)
  emit_i32_store(buf, abi.head_offset)
  emit_local_get(buf, ch_local)
  emit_i32_const_raw(buf, 0)
  emit_i32_store(buf, abi.tail_offset)
  emit_threads_int_handle_from_ptr(buf, ch_local)
}

///|
fn emit_threads_channel_full_check(buf : ByteBuf, ch_local : Int) -> Unit {
  let abi = @threads.linear_thread_channel_abi()
  emit_local_get(buf, ch_local)
  emit_i32_load(buf, abi.capacity_offset)
  emit_i32_const_raw(buf, 0)
  emit_i32_gt_s(buf)
  emit_local_get(buf, ch_local)
  emit_i32_load(buf, abi.length_offset)
  emit_local_get(buf, ch_local)
  emit_i32_load(buf, abi.capacity_offset)
  emit_i32_ge_s(buf)
  emit_i32_and(buf)
}

///|
fn emit_threads_channel_push_success(
  ctx : CodegenCtx,
  buf : ByteBuf,
  ch_local : Int,
  message_expr : @core.Expr,
) -> Unit raise WasmGenError {
  let abi = @threads.linear_thread_channel_abi()
  let msg_local = alloc_temp_local(ctx)
  let node_local = alloc_temp_local(ctx)
  let tail_local = alloc_temp_local(ctx)
  compile_expr_i32(ctx, buf, message_expr)
  emit_i32_wrap_i64(buf)
  emit_local_set(buf, msg_local)
  emit_heap_alloc(ctx, buf, abi.node_size, node_local)
  emit_local_get(buf, node_local)
  emit_i32_const_raw(buf, 0)
  emit_i32_store(buf, abi.node_next_offset)
  emit_local_get(buf, node_local)
  emit_local_get(buf, msg_local)
  emit_i32_store(buf, abi.node_value_offset)
  emit_local_get(buf, ch_local)
  emit_i32_load(buf, abi.tail_offset)
  emit_local_set(buf, tail_local)
  emit_local_get(buf, tail_local)
  emit_i32_const_raw(buf, 0)
  emit_i32_eq(buf)
  emit_if(buf)
  emit_local_get(buf, ch_local)
  emit_local_get(buf, node_local)
  emit_i32_store(buf, abi.head_offset)
  emit_else(buf)
  emit_local_get(buf, tail_local)
  emit_local_get(buf, node_local)
  emit_i32_store(buf, abi.node_next_offset)
  emit_end(buf)
  emit_local_get(buf, ch_local)
  emit_local_get(buf, node_local)
  emit_i32_store(buf, abi.tail_offset)
  emit_local_get(buf, ch_local)
  emit_local_get(buf, ch_local)
  emit_i32_load(buf, abi.length_offset)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_i32_store(buf, abi.length_offset)
  emit_i64_const_raw(buf, tag_bool_value64(true))
}

///|
fn compile_threads_channel_send(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  let pos_args = extract_positional_exprs_with_arity(args, "Threads::send", 2)
  require_linear_local_threads_backend(ctx, "Threads::send")
  require_heap(ctx)
  let ch_local = alloc_temp_local(ctx)
  compile_expr_i32(ctx, buf, pos_args[0])
  emit_untag_int_i32(buf)
  emit_local_set(buf, ch_local)
  emit_threads_channel_full_check(buf, ch_local)
  buf.push((4).to_byte()) // if
  buf.push((126).to_byte()) // result i64
  emit_i64_const_raw(buf, tag_bool_value64(false))
  emit_else(buf)
  emit_threads_channel_push_success(ctx, buf, ch_local, pos_args[1])
  emit_end(buf)
}

///|
fn emit_threads_channel_empty_recv(ctx : CodegenCtx, buf : ByteBuf) -> Unit {
  emit_string_const(ctx, buf, "")
}

///|
fn emit_threads_channel_pop_success(
  ctx : CodegenCtx,
  buf : ByteBuf,
  ch_local : Int,
  head_local : Int,
) -> Unit {
  let abi = @threads.linear_thread_channel_abi()
  let next_local = alloc_temp_local(ctx)
  let msg_local = alloc_temp_local(ctx)
  emit_local_get(buf, head_local)
  emit_i32_load(buf, abi.node_next_offset)
  emit_local_set(buf, next_local)
  emit_local_get(buf, head_local)
  emit_i32_load(buf, abi.node_value_offset)
  emit_local_set(buf, msg_local)
  emit_local_get(buf, ch_local)
  emit_local_get(buf, next_local)
  emit_i32_store(buf, abi.head_offset)
  emit_local_get(buf, next_local)
  emit_i32_const_raw(buf, 0)
  emit_i32_eq(buf)
  emit_if(buf)
  emit_local_get(buf, ch_local)
  emit_i32_const_raw(buf, 0)
  emit_i32_store(buf, abi.tail_offset)
  emit_end(buf)
  emit_local_get(buf, ch_local)
  emit_local_get(buf, ch_local)
  emit_i32_load(buf, abi.length_offset)
  emit_i32_const_raw(buf, 1)
  emit_i32_sub(buf)
  emit_i32_store(buf, abi.length_offset)
  emit_local_get(buf, msg_local)
  emit_i64_extend_i32_u(buf)
}

///|
fn compile_threads_channel_recv(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  let pos_args = extract_positional_exprs_with_arity(args, "Threads::recv", 1)
  require_linear_local_threads_backend(ctx, "Threads::recv")
  require_heap(ctx)
  let abi = @threads.linear_thread_channel_abi()
  let ch_local = alloc_temp_local(ctx)
  let head_local = alloc_temp_local(ctx)
  compile_expr_i32(ctx, buf, pos_args[0])
  emit_untag_int_i32(buf)
  emit_local_set(buf, ch_local)
  emit_local_get(buf, ch_local)
  emit_i32_load(buf, abi.head_offset)
  emit_local_set(buf, head_local)
  emit_local_get(buf, head_local)
  emit_i32_const_raw(buf, 0)
  emit_i32_eq(buf)
  buf.push((4).to_byte()) // if
  buf.push((126).to_byte()) // result i64
  emit_threads_channel_empty_recv(ctx, buf)
  emit_else(buf)
  emit_threads_channel_pop_success(ctx, buf, ch_local, head_local)
  emit_end(buf)
}

///|
fn compile_threads_task_spawn(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  let pos_args = extract_positional_exprs_with_arity(args, "Threads::spawn", 2)
  require_linear_local_threads_backend(ctx, "Threads::spawn")
  require_heap(ctx)
  let abi = @threads.linear_thread_task_abi()
  let channel_local = alloc_temp_local(ctx)
  let task_local = alloc_temp_local(ctx)
  compile_expr_i32(ctx, buf, pos_args[0])
  emit_drop(buf)
  compile_expr_i32(ctx, buf, pos_args[1])
  emit_untag_int_i32(buf)
  emit_local_set(buf, channel_local)
  emit_heap_alloc(ctx, buf, abi.size, task_local)
  emit_local_get(buf, task_local)
  emit_i32_const_raw(
    buf,
    @threads.thread_task_state_code(@threads.ThreadTaskState::Terminal),
  )
  emit_i32_store(buf, abi.state_offset)
  emit_local_get(buf, task_local)
  emit_i32_const_raw(
    buf,
    @threads.thread_terminal_status_code(
      @threads.ThreadTerminalStatus::Completed,
    ),
  )
  emit_i32_store(buf, abi.terminal_code_offset)
  emit_local_get(buf, task_local)
  emit_local_get(buf, channel_local)
  emit_i32_store(buf, abi.channel_offset)
  emit_local_get(buf, task_local)
  emit_i32_const_raw(buf, 0)
  emit_i32_store(buf, abi.payload_offset)
  emit_threads_int_handle_from_ptr(buf, task_local)
}

///|
fn compile_threads_task_wait(
  ctx : CodegenCtx,
  buf : ByteBuf,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  let pos_args = extract_positional_exprs_with_arity(args, "Threads::wait", 1)
  require_linear_local_threads_backend(ctx, "Threads::wait")
  require_heap(ctx)
  let abi = @threads.linear_thread_task_abi()
  compile_expr_i32(ctx, buf, pos_args[0])
  emit_untag_int_i32(buf)
  emit_i32_load(buf, abi.terminal_code_offset)
  emit_i32_result_as_tagged_int(buf)
}

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
      emit_string_const(ctx, buf, @threads.probe_wat())
    }
    "Threads::runtime_hints" => {
      let _ = extract_positional_exprs_with_arity(
        args, "Threads::runtime_hints", 0,
      )
      compile_expr(ctx, buf, threads_runtime_hints_expr(ctx))
    }
    "Threads::channel_new" => compile_threads_channel_new(ctx, buf, args)
    "Threads::send" => compile_threads_channel_send(ctx, buf, args)
    "Threads::recv" => compile_threads_channel_recv(ctx, buf, args)
    "Threads::spawn" => compile_threads_task_spawn(ctx, buf, args)
    "Threads::wait" => compile_threads_task_wait(ctx, buf, args)
    "__perform" => {
      let pos_args = extract_positional_exprs_with_arity(args, "__perform", 1)
      // `perform(Ctor(args))` (function-call form) needs to behave like the
      // keyword form `perform Effect::Op(args)` so the surrounding handle
      // can dispatch on the qualified op key as a string. Without this, the
      // handler compares a thrown enum-object pointer to a literal ctor-name
      // string and the dispatch never matches — the retry loop runs to OOB.
      let inner = pos_args[0]
      let ctor_payload : (String, Array[@core.Expr], @core.Span)? = match
        inner {
        @core.Expr::Call(name~, args=ctor_args, span~, ..) =>
          if @core.is_ctor_name(name) && ctx.need_effect_resume {
            let exprs = extract_positional_exprs(ctor_args, name)
            Some((name, exprs, span))
          } else {
            None
          }
        _ => None
      }
      match ctor_payload {
        Some((ctor_name, payload_exprs, ctor_span)) => {
          // Look up the qualified key the surrounding handle expects. Scan
          // populated `effect_handled_ops` with qualified keys ("Eff::Op");
          // pick the entry ending in "::ctor_name". Fallback is the bare ctor
          // name (handler won't match → throw propagates, same as before).
          let suffix = "::" + ctor_name
          let mut qualified_key = ctor_name
          for handled_key, _ in ctx.effect_handled_ops {
            if handled_key.has_suffix(suffix) {
              qualified_key = handled_key
              break
            }
          }
          let effect_name = extract_effect_name_from_key(qualified_key)
          let (idx_g, count_g, buf_g) = get_effect_resume_globals(
            ctx, effect_name,
          )
          // Mirror Expr::Perform: on retry-iteration, read from the resume
          // buffer instead of throwing. Without this branch the handle's
          // retry loop would re-throw forever and overflow the 64-slot
          // buffer (memory access OOB on i64.store at the next slot).
          if ctx.need_effect_resume && idx_g >= 0 {
            // if (resume_idx < resume_count) { return resume_buf[idx++ * 8] }
            emit_global_get(buf, idx_g)
            emit_global_get(buf, count_g)
            emit_i32_lt_s(buf)
            buf.push((4).to_byte()) // if
            buf.push((126).to_byte()) // result i64
            emit_global_get(buf, buf_g)
            emit_global_get(buf, idx_g)
            emit_i32_const_raw(buf, 8)
            emit_i32_mul(buf)
            emit_i32_add(buf)
            emit_i64_load(buf, 0)
            emit_global_get(buf, idx_g)
            emit_i32_const_raw(buf, 1)
            emit_i32_add(buf)
            emit_global_set(buf, idx_g)
            buf.push((5).to_byte()) // else
            // Store payload in effect_perform_arg_global, then throw key.
            if payload_exprs.length() == 0 {
              emit_i64_const_raw(buf, 0L)
            } else if payload_exprs.length() == 1 {
              compile_expr_i32(ctx, buf, payload_exprs[0])
            } else {
              let tuple_expr = @core.Expr::Tuple(
                items=payload_exprs,
                span=ctor_span,
              )
              compile_expr_i32(ctx, buf, tuple_expr)
            }
            emit_global_set(buf, ctx.effect_perform_arg_global)
            let tag_str = @core.Expr::String(
              value=qualified_key,
              span=ctor_span,
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
                items=payload_exprs,
                span=ctor_span,
              )
              compile_expr_i32(ctx, buf, tuple_expr)
            }
            emit_global_set(buf, ctx.effect_perform_arg_global)
            let tag_str = @core.Expr::String(
              value=qualified_key,
              span=ctor_span,
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
