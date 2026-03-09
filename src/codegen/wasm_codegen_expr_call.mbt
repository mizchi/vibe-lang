///|
fn compile_expr_call(
  ctx : CodegenCtx,
  buf : ByteBuf,
  expr : @core.Expr,
  name : String,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  let name = @core.lower_wasm_intrinsic_name(name)
  if ctx.fn_local_sigs.contains(name) &&
    ctx.locals.contains(name) &&
    not(ctx.enum_ctor_tags.contains(name)) {
    let sig = match ctx.fn_local_sigs.get(name) {
      Some(s) => s
      None =>
        raise WasmGenError::BackendLimit(
          backend="wasm",
          feature="call: " + name,
        )
    }
    let pos_args = extract_positional_exprs(args, name)
    let sig_param_len = if sig.params.length() > 0 {
      sig.params.length() - 1
    } else {
      0
    }
    if pos_args.length() != sig_param_len {
      raise WasmGenError::Unsupported("arity: " + name)
    }
    let fn_value_idx = match ctx.locals.get(name) {
      Some(idx) => idx
      None => raise WasmGenError::UnknownName(name)
    }
    compile_indirect_call(ctx, buf, name, sig, pos_args, fn_value_idx)
    // Multi-value re-boxing: only needed when the sig used for
    // call_indirect actually returns multiple values.
    if sig.results.length() > 1 {
      match ctx.fn_multivalue_results.get(name) {
        Some(mv_kinds) => emit_rebox_multivalue(ctx, buf, mv_kinds)
        None => ()
      }
    }
  } else if ctx.locals.contains(name) && not(ctx.enum_ctor_tags.contains(name)) {
    let pos_args = extract_positional_exprs(args, name)
    if not(ctx.fn_local_sigs.contains(name)) {
      let guessed_params : Array[ValueKind] = []
      for arg in pos_args {
        let arg_kind = if ctx.use_js_strings {
          infer_expr_kind(ctx, arg)
        } else {
          ValueKind::I64
        }
        if ctx.use_js_strings && arg_kind == ValueKind::ExternRef {
          guessed_params.push(ValueKind::ExternRef)
        } else {
          guessed_params.push(ValueKind::I64)
        }
      }
      let guessed_result = if ctx.use_js_strings {
        let kind = infer_expr_kind(ctx, expr)
        if kind == ValueKind::ExternRef {
          ValueKind::ExternRef
        } else {
          ValueKind::I64
        }
      } else {
        ValueKind::I64
      }
      ctx.fn_local_sigs[name] = func_sig_with_env(
        guessed_params, guessed_result,
      )
    }
    let sig = match ctx.fn_local_sigs.get(name) {
      Some(s) => s
      None =>
        raise WasmGenError::BackendLimit(
          backend="wasm",
          feature="call: " + name,
        )
    }
    let sig_param_len = if sig.params.length() > 0 {
      sig.params.length() - 1
    } else {
      0
    }
    if pos_args.length() != sig_param_len {
      raise WasmGenError::Unsupported("arity: " + name)
    }
    let fn_value_idx = match ctx.locals.get(name) {
      Some(idx) => idx
      None => raise WasmGenError::UnknownName(name)
    }
    compile_indirect_call_guessed(ctx, buf, sig, pos_args, fn_value_idx)
    // Multi-value re-boxing: only when the guessed sig actually returns multi-value
    if sig.results.length() > 1 {
      match ctx.fn_multivalue_results.get(name) {
        Some(mv_kinds) => emit_rebox_multivalue(ctx, buf, mv_kinds)
        None => ()
      }
    }
  } else {
    compile_call_by_name(ctx, buf, name, args)
  }
}

///|
fn compile_indirect_call(
  ctx : CodegenCtx,
  buf : ByteBuf,
  name : String,
  sig : FuncSig,
  pos_args : Array[@core.Expr],
  fn_value_idx : Int,
) -> Unit raise WasmGenError {
  ctx.need_funcref_table = true
  let sig_param_len = if sig.params.length() > 0 {
    sig.params.length() - 1
  } else {
    0
  }
  let env_idx = alloc_temp_local(ctx)
  let func_idx = alloc_temp_local(ctx)
  // Check if fn value is a bare function (tag_fn) or closure (tag_obj)
  emit_local_get(buf, fn_value_idx)
  emit_i64_const_raw(buf, tag_mask.to_int64())
  emit_i64_and(buf)
  emit_i64_const_raw(buf, tag_fn.to_int64())
  emit_i64_eq(buf)
  buf.push((4).to_byte())
  buf.push((64).to_byte())
  // Bare function: env = 0, extract func index from tagged i64
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, env_idx)
  emit_local_get(buf, fn_value_idx)
  emit_i64_const_raw(buf, tag_fn.to_int64())
  emit_i64_sub(buf)
  emit_i64_const_raw(buf, 2L)
  emit_i64_shr_u(buf)
  emit_i32_wrap_i64(buf)
  emit_local_set(buf, func_idx)
  buf.push((5).to_byte())
  // Closure: untag ptr, load func index from memory
  emit_untag_ptr(buf, fn_value_idx)
  emit_local_set(buf, env_idx)
  emit_local_get(buf, env_idx)
  emit_i32_load(buf, 4)
  emit_local_set(buf, func_idx)
  buf.push((11).to_byte())
  for i in 0..<sig_param_len {
    let kind = sig.params[i]
    if ctx.use_js_strings && kind == ValueKind::ExternRef {
      compile_expr_ref(ctx, buf, pos_args[i])
    } else {
      compile_expr_i32(ctx, buf, pos_args[i])
    }
  }
  emit_local_get(buf, env_idx)
  emit_local_get(buf, func_idx)
  let type_idx = match ctx.fn_sig_type_indices.get(func_sig_key(sig)) {
    Some(idx) => idx
    None =>
      raise WasmGenError::BackendLimit(backend="wasm", feature="call: " + name)
  }
  // Sync heap pointer to global before call so callee sees current heap
  if ctx.heap_local >= 0 && ctx.use_heap_global {
    emit_local_get(buf, ctx.heap_local)
    emit_global_set(buf, ctx.heap_global)
  }
  emit_call_indirect(buf, type_idx)
  // Reload heap pointer from global after call (callee may have bumped it)
  if ctx.heap_local >= 0 && ctx.use_heap_global {
    emit_global_get(buf, ctx.heap_global)
    emit_local_set(buf, ctx.heap_local)
  }
}

///|
fn compile_indirect_call_guessed(
  ctx : CodegenCtx,
  buf : ByteBuf,
  sig : FuncSig,
  pos_args : Array[@core.Expr],
  fn_value_idx : Int,
) -> Unit raise WasmGenError {
  ctx.need_funcref_table = true
  let sig_param_len = if sig.params.length() > 0 {
    sig.params.length() - 1
  } else {
    0
  }
  let env_idx = alloc_temp_local(ctx)
  let func_idx = alloc_temp_local(ctx)
  // Check if fn value is a bare function (tag_fn) or closure (tag_obj)
  emit_local_get(buf, fn_value_idx)
  emit_i64_const_raw(buf, tag_mask.to_int64())
  emit_i64_and(buf)
  emit_i64_const_raw(buf, tag_fn.to_int64())
  emit_i64_eq(buf)
  buf.push((4).to_byte())
  buf.push((64).to_byte())
  // Bare function: env = 0, extract func index from tagged i64
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, env_idx)
  emit_local_get(buf, fn_value_idx)
  emit_i64_const_raw(buf, tag_fn.to_int64())
  emit_i64_sub(buf)
  emit_i64_const_raw(buf, 2L)
  emit_i64_shr_u(buf)
  emit_i32_wrap_i64(buf)
  emit_local_set(buf, func_idx)
  buf.push((5).to_byte())
  // Closure: untag ptr, load func index from memory
  emit_untag_ptr(buf, fn_value_idx)
  emit_local_set(buf, env_idx)
  emit_local_get(buf, env_idx)
  emit_i32_load(buf, 4)
  emit_local_set(buf, func_idx)
  buf.push((11).to_byte())
  for i in 0..<sig_param_len {
    let kind = sig.params[i]
    if ctx.use_js_strings && kind == ValueKind::ExternRef {
      compile_expr_ref(ctx, buf, pos_args[i])
    } else {
      compile_expr_i32(ctx, buf, pos_args[i])
    }
  }
  emit_local_get(buf, env_idx)
  emit_local_get(buf, func_idx)
  let type_idx = match ctx.fn_sig_type_indices.get(func_sig_key(sig)) {
    Some(idx) => idx
    None => {
      let new_idx = ensure_sig_index(ctx, sig)
      ctx.fn_sig_type_indices[func_sig_key(sig)] = new_idx
      new_idx
    }
  }
  if ctx.heap_local >= 0 && ctx.use_heap_global {
    emit_local_get(buf, ctx.heap_local)
    emit_global_set(buf, ctx.heap_global)
  }
  emit_call_indirect(buf, type_idx)
  if ctx.heap_local >= 0 && ctx.use_heap_global {
    emit_global_get(buf, ctx.heap_global)
    emit_local_set(buf, ctx.heap_local)
  }
}
