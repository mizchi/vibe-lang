///|
fn emit_boxed_f32(
  ctx : CodegenCtx,
  buf : ByteBuf,
  emit_value : () -> Unit,
) -> Unit raise WasmGenError {
  emit_boxed_float_raise(
    ctx,
    buf,
    align4(8),
    obj_float,
    fn() { emit_value() },
    emit_f32_store,
  )
}

///|
fn emit_boxed_f64(
  ctx : CodegenCtx,
  buf : ByteBuf,
  emit_value : () -> Unit,
) -> Unit raise WasmGenError {
  emit_boxed_float_raise(
    ctx,
    buf,
    align4(12),
    obj_double,
    fn() { emit_value() },
    emit_f64_store,
  )
}

///|
fn emit_boxed_f32_raise(
  ctx : CodegenCtx,
  buf : ByteBuf,
  emit_value : () -> Unit raise WasmGenError,
) -> Unit raise WasmGenError {
  emit_boxed_float_raise(
    ctx,
    buf,
    align4(8),
    obj_float,
    emit_value,
    emit_f32_store,
  )
}

///|
fn emit_boxed_f64_raise(
  ctx : CodegenCtx,
  buf : ByteBuf,
  emit_value : () -> Unit raise WasmGenError,
) -> Unit raise WasmGenError {
  emit_boxed_float_raise(
    ctx,
    buf,
    align4(12),
    obj_double,
    emit_value,
    emit_f64_store,
  )
}

///|
fn emit_boxed_float_raise(
  ctx : CodegenCtx,
  buf : ByteBuf,
  size : Int,
  obj_type : Int,
  emit_value : () -> Unit raise WasmGenError,
  emit_store : (ByteBuf, Int) -> Unit,
) -> Unit raise WasmGenError {
  require_heap(ctx)
  let obj_local = alloc_temp_local(ctx)
  emit_heap_alloc(ctx, buf, size, obj_local)
  emit_local_get(buf, obj_local)
  emit_i32_const_raw(buf, obj_type)
  emit_i32_store(buf, 0)
  emit_local_get(buf, obj_local)
  emit_value()
  emit_store(buf, 4)
  emit_local_get(buf, obj_local)
  emit_i64_extend_i32_u(buf)
  emit_i64_const_raw(buf, tag_obj.to_int64())
  emit_i64_or(buf)
}

///|
fn emit_unbox_f32_expr(
  ctx : CodegenCtx,
  buf : ByteBuf,
  expr : @core.Expr,
) -> Unit raise WasmGenError {
  let tmp = alloc_temp_local_with_kind(ctx, ValueKind::I64)
  compile_expr_i32(ctx, buf, expr)
  emit_local_set(buf, tmp)
  emit_untag_ptr(buf, tmp)
  emit_f32_load(buf, 4)
}

///|
fn emit_unbox_f64_expr(
  ctx : CodegenCtx,
  buf : ByteBuf,
  expr : @core.Expr,
) -> Unit raise WasmGenError {
  let tmp = alloc_temp_local_with_kind(ctx, ValueKind::I64)
  compile_expr_i32(ctx, buf, expr)
  emit_local_set(buf, tmp)
  emit_untag_ptr(buf, tmp)
  emit_f64_load(buf, 4)
}

///|
fn require_heap(ctx : CodegenCtx) -> Unit {
  if ctx.heap_local < 0 {
    // Lazy heap initialization: allocate heap_local on first demand.
    // This handles cases where scan_needs/needs_heap_block didn't
    // detect the requirement (e.g., prelude builtins called transitively).
    ctx.need_heap = true
    ctx.heap_local = ctx.local_count
    ctx.local_count += 1
    ctx.local_types.push(ValueKind::I32)
    ctx.heap_synced = false
    // Also ensure heap_global is set (build_module needs it for global section)
    if not(ctx.use_heap_global) {
      ctx.use_heap_global = true
      // In linked mode, __heap_ptr is imported global index 0.
      // Otherwise, it'll be global index 0 in the defined globals section.
      ctx.heap_global = 0
    }
  }
}

///|
fn emit_heap_reserve(ctx : CodegenCtx, buf : ByteBuf, size : Int) -> Unit {
  require_heap(ctx)
  if size <= 0 {
    return
  }
  let new_heap_local = alloc_temp_local(ctx)
  let current_pages_local = alloc_temp_local(ctx)
  let required_pages_local = alloc_temp_local(ctx)
  emit_local_get(buf, ctx.heap_local)
  emit_i32_const_raw(buf, size)
  emit_i32_add(buf)
  emit_local_set(buf, new_heap_local)
  emit_memory_size(buf)
  emit_local_set(buf, current_pages_local)
  emit_local_get(buf, new_heap_local)
  emit_i32_const_raw(buf, 65535)
  emit_i32_add(buf)
  emit_i32_const_raw(buf, 16)
  emit_i32_shr_u(buf)
  emit_local_set(buf, required_pages_local)
  emit_local_get(buf, current_pages_local)
  emit_local_get(buf, required_pages_local)
  emit_i32_lt_s(buf)
  buf.push((4).to_byte()) // if
  buf.push((64).to_byte()) // empty
  emit_local_get(buf, required_pages_local)
  emit_local_get(buf, current_pages_local)
  emit_i32_sub(buf)
  emit_memory_grow(buf)
  emit_drop(buf)
  buf.push((11).to_byte()) // end
}

///|
/// S8: Sync heap_local -> heap_global before a call, skipping if already synced.
fn emit_heap_pre_call_sync(ctx : CodegenCtx, buf : ByteBuf) -> Unit {
  // Always sync before calls. The heap_synced optimization is fragile
  // and causes heap corruption when sync state leaks across control
  // flow boundaries (if/else, match, while, let rec).
  if ctx.heap_local >= 0 && ctx.use_heap_global {
    emit_local_get(buf, ctx.heap_local)
    emit_global_set(buf, ctx.heap_global)
  }
}

///|
/// S8: Reload heap_global -> heap_local after a call, marking as synced.
fn emit_heap_post_call_sync(ctx : CodegenCtx, buf : ByteBuf) -> Unit {
  if ctx.heap_local >= 0 && ctx.use_heap_global {
    emit_global_get(buf, ctx.heap_global)
    emit_local_set(buf, ctx.heap_local)
    ctx.heap_synced = true
  }
}

///|
fn emit_heap_alloc(
  ctx : CodegenCtx,
  buf : ByteBuf,
  size : Int,
  obj_local : Int,
) -> Unit {
  if ctx.enable_rc {
    // Allocate size + 8 bytes: [alloc_size(4)][rc_count(4)][object(size)]
    // obj_local points past the RC header so all field offsets are unchanged
    let total_size = size + rc_header_extra
    emit_rc_alloc_with_free_list(ctx, buf, size, total_size, obj_local)
  } else {
    emit_heap_reserve(ctx, buf, size)
    emit_local_get(buf, ctx.heap_local)
    emit_local_set(buf, obj_local)
    emit_local_get(buf, ctx.heap_local)
    emit_i32_const_raw(buf, size)
    emit_i32_add(buf)
    emit_local_set(buf, ctx.heap_local)
    ctx.heap_synced = false
  }
}

///|
/// Bump-only heap allocation without bounds checking.
/// Safe for small, fixed-size allocations (e.g. 8-byte ref cells) where
/// the initial memory page (64KB) provides sufficient headroom and
/// subsequent checked allocations will trigger memory.grow if needed.
fn emit_heap_alloc_unchecked(
  ctx : CodegenCtx,
  buf : ByteBuf,
  size : Int,
  obj_local : Int,
) -> Unit {
  require_heap(ctx)
  emit_local_get(buf, ctx.heap_local)
  emit_local_set(buf, obj_local)
  emit_local_get(buf, ctx.heap_local)
  emit_i32_const_raw(buf, size)
  emit_i32_add(buf)
  emit_local_set(buf, ctx.heap_local)
  ctx.heap_synced = false
}

///|
fn emit_heap_reserve_local(
  ctx : CodegenCtx,
  buf : ByteBuf,
  size_local : Int,
) -> Unit {
  require_heap(ctx)
  let new_heap_local = alloc_temp_local(ctx)
  let current_pages_local = alloc_temp_local(ctx)
  let required_pages_local = alloc_temp_local(ctx)
  emit_local_get(buf, ctx.heap_local)
  emit_local_get(buf, size_local)
  emit_i32_add(buf)
  emit_local_set(buf, new_heap_local)
  emit_memory_size(buf)
  emit_local_set(buf, current_pages_local)
  emit_local_get(buf, new_heap_local)
  emit_i32_const_raw(buf, 65535)
  emit_i32_add(buf)
  emit_i32_const_raw(buf, 16)
  emit_i32_shr_u(buf)
  emit_local_set(buf, required_pages_local)
  emit_local_get(buf, current_pages_local)
  emit_local_get(buf, required_pages_local)
  emit_i32_lt_s(buf)
  buf.push((4).to_byte()) // if
  buf.push((64).to_byte()) // empty
  emit_local_get(buf, required_pages_local)
  emit_local_get(buf, current_pages_local)
  emit_i32_sub(buf)
  emit_memory_grow(buf)
  emit_drop(buf)
  buf.push((11).to_byte()) // end
}

///|
fn emit_heap_alloc_local(
  ctx : CodegenCtx,
  buf : ByteBuf,
  size_local : Int,
  obj_local : Int,
) -> Unit {
  if ctx.enable_rc {
    // Add rc_header_extra to size_local for the prepended RC field
    emit_local_get(buf, size_local)
    emit_i32_const_raw(buf, rc_header_extra)
    emit_i32_add(buf)
    emit_local_set(buf, size_local)
  }
  emit_heap_reserve_local(ctx, buf, size_local)
  emit_local_get(buf, ctx.heap_local)
  if ctx.enable_rc {
    emit_i32_const_raw(buf, rc_header_extra)
    emit_i32_add(buf)
  }
  emit_local_set(buf, obj_local)
  emit_local_get(buf, ctx.heap_local)
  emit_local_get(buf, size_local)
  emit_i32_add(buf)
  emit_local_set(buf, ctx.heap_local)
  ctx.heap_synced = false
  if ctx.enable_rc {
    // Dynamic-size alloc: write actual alloc_size from size_local
    emit_rc_init_dynamic(buf, obj_local, size_local)
  }
}

///|
fn compile_tuple_expr(
  ctx : CodegenCtx,
  buf : ByteBuf,
  items : Array[@core.Expr],
) -> Unit raise WasmGenError {
  require_heap(ctx)
  let len = items.length()
  let size = align4(8 + len * 4)
  let obj_local = alloc_temp_local(ctx)
  emit_heap_alloc(ctx, buf, size, obj_local)
  emit_local_get(buf, obj_local)
  emit_i32_const_raw(buf, obj_tuple)
  emit_i32_store(buf, 0)
  emit_local_get(buf, obj_local)
  emit_i32_const_raw(buf, len)
  emit_i32_store(buf, 4)
  for i in 0..<len {
    let item_kind = if ctx.use_js_strings {
      infer_expr_kind(ctx, items[i])
    } else {
      ValueKind::I32
    }
    if ctx.use_js_strings && item_kind == ValueKind::ExternRef {
      // Store externref in extern table, put slot index in tuple
      ctx.need_extern_table = true
      let slot = ctx.extern_table_next_slot
      ctx.extern_table_next_slot += 1
      emit_i32_const_raw(buf, slot)
      compile_expr(ctx, buf, items[i])
      emit_table_set(buf, ctx.extern_table_index)
      emit_local_get(buf, obj_local)
      emit_i32_const_raw(buf, slot)
      emit_i32_store(buf, 8 + i * 4)
    } else {
      emit_local_get(buf, obj_local)
      compile_expr_i32(ctx, buf, items[i])
      emit_i32_wrap_i64(buf)
      emit_i32_store(buf, 8 + i * 4)
    }
  }
  emit_local_get(buf, obj_local)
  emit_i64_extend_i32_u(buf)
  emit_i64_const_raw(buf, tag_obj.to_int64())
  emit_i64_or(buf)
}

///|
fn compile_record_expr(
  ctx : CodegenCtx,
  buf : ByteBuf,
  fields : Array[@core.RecordFieldExpr],
) -> Unit raise WasmGenError {
  require_heap(ctx)
  let ordered = sort_record_fields_expr(fields)
  let len = ordered.length()
  let size = align4(8 + len * 8)
  let obj_local = alloc_temp_local(ctx)
  emit_heap_alloc(ctx, buf, size, obj_local)
  emit_local_get(buf, obj_local)
  emit_i32_const_raw(buf, obj_record)
  emit_i32_store(buf, 0)
  emit_local_get(buf, obj_local)
  emit_i32_const_raw(buf, len)
  emit_i32_store(buf, 4)
  for i in 0..<len {
    let field = ordered[i]
    let name_ptr = ctx.strings.intern(field.name)
    emit_local_get(buf, obj_local)
    emit_i32_const_raw(buf, name_ptr)
    emit_i32_store(buf, 8 + i * 8)
    emit_local_get(buf, obj_local)
    compile_expr_i32(ctx, buf, field.expr)
    emit_i32_wrap_i64(buf)
    emit_i32_store(buf, 8 + i * 8 + 4)
  }
  emit_local_get(buf, obj_local)
  emit_i64_extend_i32_u(buf)
  emit_i64_const_raw(buf, tag_obj.to_int64())
  emit_i64_or(buf)
}

///|
fn compile_array_expr(
  ctx : CodegenCtx,
  buf : ByteBuf,
  items : Array[@core.Expr],
) -> Unit raise WasmGenError {
  require_heap(ctx)
  // Check if any item is a Spread
  let has_spread = items
    .iter()
    .any(fn(item) {
      match item {
        @core.Expr::Spread(..) => true
        _ => false
      }
    })
  if has_spread {
    // Desugar spread into Array::concat chain, then compile
    let zero_span = @core.Span::{ start: 0, end: 0 }
    // Group consecutive non-spread items into Array literals,
    // spread items become their inner expr.
    // Then fold with Array::concat calls.
    let segments : Array[@core.Expr] = []
    let buf_items : Array[@core.Expr] = []
    for item in items {
      match item {
        @core.Expr::Spread(expr~, ..) => {
          if buf_items.length() > 0 {
            segments.push(
              @core.Expr::Array(items=buf_items.copy(), span=zero_span),
            )
            buf_items.clear()
          }
          segments.push(expr)
        }
        _ => buf_items.push(item)
      }
    }
    if buf_items.length() > 0 {
      segments.push(@core.Expr::Array(items=buf_items.copy(), span=zero_span))
    }
    // Fold segments with Array::concat
    let mut acc = segments[0]
    for i in 1..<segments.length() {
      acc = @core.Expr::Call(
        name="Array::concat",
        type_args=[],
        args=[
          @core.CallArg::{ label: None, expr: acc, span: zero_span },
          @core.CallArg::{ label: None, expr: segments[i], span: zero_span },
        ],
        span=zero_span,
      )
    }
    compile_expr(ctx, buf, acc)
  } else {
    // Static path: direct heap allocation
    let len = items.length()
    // Over-allocate: arrays may grow via array_push; reserve capacity to avoid
    // writing past the end of the allocated block and corrupting adjacent objects.
    let min_cap = 65536
    let cap = if len < min_cap { min_cap } else { len }
    let size = align4(8 + cap * 4)
    let obj_local = alloc_temp_local(ctx)
    emit_heap_alloc(ctx, buf, size, obj_local)
    emit_local_get(buf, obj_local)
    emit_i32_const_raw(buf, obj_array)
    emit_i32_store(buf, 0)
    emit_local_get(buf, obj_local)
    emit_i32_const_raw(buf, len)
    emit_i32_store(buf, 4)
    for i in 0..<len {
      emit_local_get(buf, obj_local)
      compile_expr_i32(ctx, buf, items[i])
      emit_i32_wrap_i64(buf)
      emit_i32_store(buf, 8 + i * 4)
    }
    emit_local_get(buf, obj_local)
    emit_i64_extend_i32_u(buf)
    emit_i64_const_raw(buf, tag_obj.to_int64())
    emit_i64_or(buf)
  }
}

///|
fn compile_map_expr(
  ctx : CodegenCtx,
  buf : ByteBuf,
  fields : Array[@core.MapFieldExpr],
) -> Unit raise WasmGenError {
  require_heap(ctx)
  let len = fields.length()
  let size = align4(8 + len * 8)
  let obj_local = alloc_temp_local(ctx)
  emit_heap_alloc(ctx, buf, size, obj_local)
  emit_local_get(buf, obj_local)
  emit_i32_const_raw(buf, obj_map)
  emit_i32_store(buf, 0)
  emit_local_get(buf, obj_local)
  emit_i32_const_raw(buf, len)
  emit_i32_store(buf, 4)
  for i in 0..<len {
    let field = fields[i]
    let key_ptr = ctx.strings.intern(field.key)
    emit_local_get(buf, obj_local)
    emit_i32_const_raw(buf, key_ptr)
    emit_i32_store(buf, 8 + i * 8)
    emit_local_get(buf, obj_local)
    compile_expr_i32(ctx, buf, field.expr)
    emit_i32_wrap_i64(buf)
    emit_i32_store(buf, 8 + i * 8 + 4)
  }
  emit_local_get(buf, obj_local)
  emit_i64_extend_i32_u(buf)
  emit_i64_const_raw(buf, tag_obj.to_int64())
  emit_i64_or(buf)
}

///|
fn sort_record_fields_expr(
  fields : Array[@core.RecordFieldExpr],
) -> Array[@core.RecordFieldExpr] {
  let out : Array[@core.RecordFieldExpr] = []
  for field in fields {
    out.push(field)
    let mut i = out.length() - 1
    while i > 0 && out[i].name < out[i - 1].name {
      let tmp = out[i - 1]
      out[i - 1] = out[i]
      out[i] = tmp
      i -= 1
    }
  }
  out
}

///|
fn sort_record_fields_pat(
  fields : Array[@core.RecordFieldPat],
) -> Array[@core.RecordFieldPat] {
  let out : Array[@core.RecordFieldPat] = []
  for field in fields {
    out.push(field)
    let mut i = out.length() - 1
    while i > 0 && out[i].name < out[i - 1].name {
      let tmp = out[i - 1]
      out[i - 1] = out[i]
      out[i] = tmp
      i -= 1
    }
  }
  out
}

///|
fn compile_func_body(
  ctx : CodegenCtx,
  ast : @core.Module,
  result_kind : ValueKind,
  need_heap : Bool,
  prelude : Array[Byte],
  multivalue_kinds? : Array[ValueKind]? = None,
  emit_rc_stmt_actions? : Bool = false,
) -> Array[Byte] raise WasmGenError {
  let instr = ByteBuf::new()
  if multivalue_kinds is None &&
    ctx.use_js_strings &&
    result_kind != ValueKind::I32 {
    let inferred = infer_block_kind(ctx, ast, ctx.local_kinds)
    if inferred != result_kind {
      raise WasmGenError::BackendLimit(
        backend="wasm-js-string",
        feature="return kind mismatch",
      )
    }
  }
  ctx.need_heap = need_heap || ctx.coverage_enabled
  if ctx.need_heap {
    ctx.heap_local = ctx.local_count
    ctx.local_count += 1
    ctx.local_types.push(ValueKind::I32)
    ctx.heap_synced = true
  }
  // Tail call optimization: only enabled when explicitly requested
  // (wite optimizer and some wasm-opt versions don't support return_call)
  if ctx.enable_tail_call {
    ctx.is_tail_position = true
  }
  match multivalue_kinds {
    Some(kinds) => compile_block_multivalue(ctx, instr, ast, kinds)
    None => compile_block_expr(ctx, instr, ast, emit_rc_stmt_actions~)
  }
  ctx.is_tail_position = false
  if ctx.need_heap && ctx.use_heap_global {
    emit_local_get(instr, ctx.heap_local)
    emit_global_set(instr, ctx.heap_global)
  }
  instr.push((11).to_byte())
  if ctx.need_heap || prelude.length() > 0 {
    let prologue = ByteBuf::new()
    if ctx.need_heap {
      if ctx.use_heap_global {
        emit_global_get(prologue, ctx.heap_global)
        emit_local_set(prologue, ctx.heap_local)
      } else {
        let coverage_bytes = if ctx.coverage_enabled {
          ctx.coverage_points.length() * 4
        } else {
          0
        }
        let heap_start = align4(ctx.strings.next_offset + coverage_bytes)
        emit_i32_const_raw(prologue, heap_start)
        emit_local_set(prologue, ctx.heap_local)
      }
    }
    if prelude.length() > 0 {
      prologue.extend(prelude)
    }
    prologue.extend_buf(instr)
    prologue.to_array()
  } else {
    instr.to_array()
  }
}

///|
fn compile_function(
  ctx : CodegenCtx,
  self_name : String?,
  params : Array[@core.FuncParam],
  param_kinds : Array[ValueKind],
  result_kind : ValueKind,
  body : @core.Module,
  need_heap : Bool,
  captures : Array[String],
  capture_kinds : Array[ValueKind],
  with_env : Bool,
  capture_is_ref_cell? : Array[Bool] = [],
  emit_rc_stmt_actions? : Bool = false,
) -> WasmFunc raise WasmGenError {
  let saved_locals = ctx.locals
  let saved_kinds = ctx.local_kinds
  let saved_types = ctx.local_types
  let saved_count = ctx.local_count
  let saved_need_heap = ctx.need_heap
  let saved_heap_local = ctx.heap_local
  let saved_heap_synced = ctx.heap_synced
  let saved_current_env_idx = ctx.current_env_idx
  let saved_fn_locals = ctx.fn_local_sigs
  let saved_mut_captured = ctx.mut_captured_vars
  let saved_cached_untag_ptrs = ctx.cached_untag_ptrs
  let saved_cached_obj_types = ctx.cached_obj_types
  let saved_const_i64 = ctx.const_i64_values
  ctx.locals = {}
  ctx.cached_untag_ptrs = {}
  ctx.cached_obj_types = {}
  ctx.local_kinds = {}
  ctx.local_types = []
  ctx.local_count = 0
  ctx.need_heap = false
  ctx.heap_local = -1
  ctx.heap_synced = false
  ctx.fn_local_sigs = {}
  ctx.const_i64_values = {}
  let param_len = if params.length() < param_kinds.length() {
    params.length()
  } else {
    param_kinds.length()
  }
  for i in 0..<param_len {
    ctx.locals[params[i].name] = i
    ctx.local_kinds[params[i].name] = param_kinds[i]
    ctx.local_count += 1
    match func_sig_from_type(ctx, params[i].ty) {
      Some(sig) => ctx.fn_local_sigs[params[i].name] = sig
      None => ()
    }
  }
  match self_name {
    Some(name) =>
      // Keep self signature visible while compiling this function body.
      // This is required for recursive local closures where `name` is both
      // in fn_indices (direct call target) and in locals (captured closure).
      match ctx.fn_multivalue_results.get(name) {
        Some(results) =>
          ctx.fn_local_sigs[name] = func_sig_with_env_multi(
            param_kinds, results,
          )
        None =>
          ctx.fn_local_sigs[name] = func_sig_with_env(param_kinds, result_kind)
      }
    None => ()
  }
  let env_idx = if with_env {
    let idx = ctx.local_count
    ctx.local_count += 1
    idx
  } else {
    -1
  }
  ctx.current_env_idx = env_idx
  let prelude = ByteBuf::new()
  match self_name {
    Some(name) =>
      if with_env && captures.length() > 0 {
        match ctx.fn_indices.get(name) {
          Some(_) => {
            // Materialize current function value so nested closures can capture
            // the correct closure (including env), not a bare function slot.
            let self_local = ctx.local_count
            ctx.local_count += 1
            ctx.local_types.push(ValueKind::I64)
            ctx.locals[name] = self_local
            ctx.local_kinds[name] = ValueKind::I64
            emit_local_get(prelude, env_idx)
            emit_i64_extend_i32_u(prelude)
            emit_i64_const_raw(prelude, tag_obj.to_int64())
            emit_i64_or(prelude)
            emit_local_set(prelude, self_local)
          }
          None => ()
        }
      }
    None => ()
  }
  // Compute mut_captured_vars for this function's body
  ctx.mut_captured_vars = compute_mut_captured_for_block(
    body.stmts,
    ctx.fn_closure_captures,
  )
  // Env=0 fallback: when an exported function with captures is called
  // externally (env=0), load the real env from a pre-stored global.
  if with_env && captures.length() > 0 {
    match self_name {
      Some(fn_name) =>
        match ctx.exported_fn_env_globals.get(fn_name) {
          Some(global_idx) =>
            if global_idx >= 0 {
              emit_local_get(prelude, env_idx)
              emit_i32_eqz(prelude)
              emit_if(prelude)
              emit_global_get(prelude, global_idx)
              emit_local_set(prelude, env_idx)
              emit_end(prelude)
            }
          None => ()
        }
      None => ()
    }
  }
  if with_env && captures.length() > 0 {
    let mut effective_idx = 0
    for i in 0..<captures.length() {
      let name = captures[i]
      let is_ref = effective_idx < capture_is_ref_cell.length() &&
        capture_is_ref_cell[effective_idx]
      let kind = if is_ref {
        ValueKind::I32
      } else if effective_idx < capture_kinds.length() {
        capture_kinds[effective_idx]
      } else {
        ValueKind::I64
      }
      let idx = ctx.local_count
      ctx.local_count += 1
      match saved_fn_locals.get(name) {
        Some(sig) => ctx.fn_local_sigs[name] = sig
        None =>
          match ctx.fn_params.get(name) {
            Some(param_kinds) =>
              match ctx.fn_returns.get(name) {
                Some(ret_kind) =>
                  ctx.fn_local_sigs[name] = match
                    ctx.fn_multivalue_results.get(name) {
                    Some(results) =>
                      func_sig_with_env_multi(param_kinds, results)
                    None => func_sig_with_env(param_kinds, ret_kind)
                  }
                None => ()
              }
            None => ()
          }
      }
      if is_ref {
        // Ref cell capture: load pointer from env, store as i32 local
        ctx.local_types.push(ValueKind::I32)
        ctx.locals[name] = idx
        ctx.local_kinds[name] = ValueKind::I32
        emit_local_get(prelude, env_idx)
        emit_i64_load(prelude, 8 + effective_idx * 8) // load pointer as i64
        emit_i32_wrap_i64(prelude) // → i32
        emit_local_set(prelude, idx)
        // Propagate ref cell status so nested closures work
        ctx.mut_captured_vars[name] = true
      } else if ctx.use_js_strings && kind == ValueKind::ExternRef {
        // ExternRef capture: load table slot index from env, then table.get
        ctx.local_types.push(ValueKind::ExternRef)
        ctx.locals[name] = idx
        ctx.local_kinds[name] = ValueKind::ExternRef
        emit_local_get(prelude, env_idx)
        emit_i64_load(prelude, 8 + effective_idx * 8) // load slot index as i64
        emit_i32_wrap_i64(prelude) // wrap to i32 for table.get
        emit_table_get(prelude, ctx.extern_table_index)
        emit_local_set(prelude, idx)
      } else {
        ctx.local_types.push(ValueKind::I64)
        ctx.locals[name] = idx
        ctx.local_kinds[name] = kind
        emit_local_get(prelude, env_idx)
        emit_i64_load(prelude, 8 + effective_idx * 8)
        emit_local_set(prelude, idx)
      }
      effective_idx += 1
    }
  }
  let mv_kinds : Array[ValueKind]? = match self_name {
    Some(name) =>
      match ctx.fn_multivalue_results.get(name) {
        Some(kinds) => Some(kinds)
        None => None
      }
    None => None
  }
  let body_bytes = compile_func_body(
    ctx,
    body,
    result_kind,
    need_heap,
    prelude.to_array(),
    multivalue_kinds=mv_kinds,
    emit_rc_stmt_actions~,
  )
  let locals = ctx.local_types
  let params_with_env : Array[ValueKind] = []
  for kind in param_kinds {
    params_with_env.push(kind)
  }
  if with_env {
    params_with_env.push(ValueKind::I32)
  }
  let multi_results : Array[ValueKind] = match self_name {
    Some(name) =>
      match ctx.fn_multivalue_results.get(name) {
        Some(kinds) => kinds
        None => [result_kind]
      }
    None => [result_kind]
  }
  let func = WasmFunc::{
    params: params_with_env,
    locals,
    results: multi_results,
    body: body_bytes,
  }
  ctx.locals = saved_locals
  ctx.local_kinds = saved_kinds
  ctx.local_types = saved_types
  ctx.local_count = saved_count
  ctx.need_heap = saved_need_heap
  ctx.heap_local = saved_heap_local
  ctx.heap_synced = saved_heap_synced
  ctx.current_env_idx = saved_current_env_idx
  ctx.fn_local_sigs = saved_fn_locals
  ctx.mut_captured_vars = saved_mut_captured
  ctx.cached_untag_ptrs = saved_cached_untag_ptrs
  ctx.cached_obj_types = saved_cached_obj_types
  ctx.const_i64_values = saved_const_i64
  func
}

///|
fn compile_cabi_realloc_function(
  ctx : CodegenCtx,
) -> WasmFunc raise WasmGenError {
  if ctx.heap_global < 0 {
    raise WasmGenError::Unsupported("cabi_realloc requires heap global")
  }
  let body = ByteBuf::new()
  let ptr_local = 4
  let align_mask_local = 5
  // if new_size == 0: return align
  emit_local_get(body, 3)
  emit_i32_eqz(body)
  body.push((4).to_byte()) // if
  body.push((127).to_byte()) // result i32
  emit_local_get(body, 2)
  body.push((5).to_byte()) // else
  emit_global_get(body, ctx.heap_global)
  emit_local_set(body, ptr_local)
  // canonical ABI passes an alignment (power of two) in param[2].
  emit_local_get(body, 2)
  emit_i32_const_raw(body, 1)
  emit_i32_sub(body)
  emit_local_set(body, align_mask_local)
  emit_local_get(body, align_mask_local)
  emit_i32_eqz(body)
  body.push((4).to_byte()) // if
  body.push((64).to_byte()) // empty block
  body.push((5).to_byte()) // else
  emit_local_get(body, ptr_local)
  emit_local_get(body, align_mask_local)
  emit_i32_add(body)
  emit_local_get(body, align_mask_local)
  emit_i32_const_raw(body, -1)
  emit_i32_xor(body)
  emit_i32_and(body)
  emit_local_set(body, ptr_local)
  body.push((11).to_byte()) // end if
  emit_local_get(body, ptr_local)
  emit_local_get(body, 3)
  emit_i32_add(body)
  emit_i32_const_raw(body, 3)
  emit_i32_add(body)
  emit_i32_const_raw(body, -4)
  emit_i32_and(body)
  emit_global_set(body, ctx.heap_global)
  emit_local_get(body, ptr_local)
  body.push((11).to_byte()) // end if
  body.push((11).to_byte()) // end func
  WasmFunc::{
    params: [ValueKind::I32, ValueKind::I32, ValueKind::I32, ValueKind::I32],
    locals: [ValueKind::I32, ValueKind::I32],
    results: [ValueKind::I32],
    body: body.to_array(),
  }
}

///|
fn compile_http_host_string_new_function(
  ctx : CodegenCtx,
) -> WasmFunc raise WasmGenError {
  if ctx.heap_global < 0 {
    raise WasmGenError::Unsupported(
      "vibe_http_host_string_new requires heap global",
    )
  }
  let body = ByteBuf::new()
  let len_local = 1
  let obj_local = 2
  // len = max(len, 0)
  emit_local_get(body, 0)
  emit_local_set(body, len_local)
  emit_local_get(body, len_local)
  emit_i32_const_raw(body, 0)
  emit_i32_lt_s(body)
  body.push((4).to_byte()) // if
  body.push((64).to_byte()) // empty block
  emit_i32_const_raw(body, 0)
  emit_local_set(body, len_local)
  body.push((11).to_byte()) // end if
  // obj = heap
  emit_global_get(body, ctx.heap_global)
  emit_local_set(body, obj_local)
  // obj.ty = obj_string
  emit_local_get(body, obj_local)
  emit_i32_const_raw(body, obj_string)
  emit_i32_store(body, 0)
  // obj.len = len
  emit_local_get(body, obj_local)
  emit_local_get(body, len_local)
  emit_i32_store(body, 4)
  // heap = obj + align4(8 + len)
  emit_local_get(body, obj_local)
  emit_local_get(body, len_local)
  emit_i32_const_raw(body, 11)
  emit_i32_add(body)
  emit_i32_const_raw(body, -4)
  emit_i32_and(body)
  emit_i32_add(body)
  emit_global_set(body, ctx.heap_global)
  // return tagged string object pointer
  emit_local_get(body, obj_local)
  emit_i64_extend_i32_u(body)
  emit_i64_const_raw(body, tag_obj.to_int64())
  emit_i64_or(body)
  body.push((11).to_byte()) // end func
  WasmFunc::{
    params: [ValueKind::I32],
    locals: [ValueKind::I32, ValueKind::I32],
    results: [ValueKind::I64],
    body: body.to_array(),
  }
}
