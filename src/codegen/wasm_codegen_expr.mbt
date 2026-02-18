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
      if ctx.use_js_strings {
        let idx = ctx.js_strings.intern(s)
        emit_global_get(buf, idx)
      } else {
        let offset = ctx.strings.intern(s)
        emit_i64_const_raw(buf, tag_ptr64(offset, tag_obj))
      }
    }
    @core.Expr::Ident(name~, span~) => {
      let _ = span
      if is_qualified_name(name) {
        raise WasmGenError::BackendLimit(
          backend="wasm",
          feature="qualified name: " + name,
        )
      }
      match ctx.locals.get(name) {
        Some(idx) => emit_local_get(buf, idx)
        None =>
          match ctx.fn_indices.get(name) {
            Some(idx) => {
              if fn_index_needs_env(ctx, idx) {
                raise WasmGenError::Unsupported(
                  "function value requires closure env in scope: " + name,
                )
              }
              let slot = ensure_funcref_slot(ctx, idx)
              emit_i64_const_raw(buf, tag_fn_value64(slot.to_int64()))
            }
            None =>
              if ctx.enum_ctor_tags.contains(name) {
                // Nullary enum constructor
                let tag = match ctx.enum_ctor_tags.get(name) {
                  Some(t) => t
                  None => 0
                }
                require_heap(ctx)
                let size = align4(8)
                let obj_local = alloc_temp_local(ctx)
                emit_heap_alloc(ctx, buf, size, obj_local)
                emit_local_get(buf, obj_local)
                emit_i32_const_raw(buf, obj_enum)
                emit_i32_store(buf, 0)
                emit_local_get(buf, obj_local)
                emit_i32_const_raw(buf, tag)
                emit_i32_store(buf, 4)
                emit_local_get(buf, obj_local)
                emit_i64_extend_i32_u(buf)
                emit_i64_const_raw(buf, tag_obj.to_int64())
                emit_i64_or(buf)
              } else {
                raise WasmGenError::UnknownName(name)
              }
          }
      }
    }
    @core.Expr::Placeholder(..) =>
      // Placeholder should be desugared before codegen
      raise WasmGenError::Unsupported("placeholder in codegen")
    @core.Expr::Call(name~, args~, span~, ..) => {
      let _ = span
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
            raise WasmGenError::BackendLimit(
              backend="wasm",
              feature="call: " + name,
            )
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
        // Multi-value re-boxing: only needed when the sig used for
        // call_indirect actually returns multiple values.
        if sig.results.length() > 1 {
          match ctx.fn_multivalue_results.get(name) {
            Some(mv_kinds) => emit_rebox_multivalue(ctx, buf, mv_kinds)
            None => ()
          }
        }
      } else if ctx.locals.contains(name) &&
        not(ctx.enum_ctor_tags.contains(name)) {
        let pos_args = extract_positional_exprs(args, name)
        if not(ctx.fn_local_sigs.contains(name)) {
          let guessed_params : Array[ValueKind] = []
          for arg in pos_args {
            let arg_kind = if ctx.use_js_strings {
              infer_expr_kind(ctx, arg)
            } else {
              ValueKind::I32
            }
            if ctx.use_js_strings && arg_kind == ValueKind::ExternRef {
              guessed_params.push(ValueKind::ExternRef)
            } else {
              guessed_params.push(ValueKind::I32)
            }
          }
          let guessed_result = if ctx.use_js_strings {
            let kind = infer_expr_kind(ctx, expr)
            if kind == ValueKind::ExternRef {
              ValueKind::ExternRef
            } else {
              ValueKind::I32
            }
          } else {
            ValueKind::I32
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
    @core.Expr::Tuple(items~, span~) => {
      let _ = span
      compile_tuple_expr(ctx, buf, items)
    }
    @core.Expr::TupleIndex(expr~, index~, span~) => {
      let _ = span
      match detect_multivalue_call(ctx, expr) {
        Some(kinds) => {
          compile_expr_multivalue_call(ctx, buf, expr)
          let n = kinds.length()
          let temps : Array[Int] = Array::make(n, 0)
          for i = n - 1; i >= 0; i = i - 1 {
            let tmp = alloc_temp_local_with_kind(ctx, ValueKind::I64)
            temps[i] = tmp
            emit_local_set(buf, tmp)
          }
          emit_local_get(buf, temps[index])
        }
        None => {
          compile_expr(ctx, buf, expr)
          emit_i64_const_raw(buf, (-4).to_int64())
          emit_i64_and(buf)
          emit_i32_wrap_i64(buf)
          emit_i32_load(buf, 8 + index * 4)
          emit_i64_extend_i32_s(buf)
        }
      }
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
      let _ = span
      let if_kind = if ctx.use_js_strings {
        infer_expr_kind(ctx, expr)
      } else {
        ValueKind::I64
      }
      compile_expr_i32(ctx, buf, cond)
      emit_i64_const_raw(buf, 2L)
      emit_i64_shr_u(buf)
      emit_i32_wrap_i64(buf)
      buf.push((4).to_byte()) // if
      buf.push(valtype_byte(if_kind))
      adjust_loop_offsets(ctx, 1)
      emit_coverage(ctx, buf, WasmCoveragePointKind::BranchIfThen, span)
      compile_block_expr(ctx, buf, then_body)
      buf.push((5).to_byte()) // else
      emit_coverage(ctx, buf, WasmCoveragePointKind::BranchIfElse, span)
      compile_block_expr(ctx, buf, else_body)
      buf.push((11).to_byte()) // end
      adjust_loop_offsets(ctx, -1)
    }
    @core.Expr::Block(body~, span~) => {
      let _ = span
      compile_block_expr(ctx, buf, body)
    }
    @core.Expr::Match(scrutinee~, arms~, span~) => {
      let _ = span
      let saved = ctx.locals.copy()
      let saved_kinds = ctx.local_kinds.copy()
      let scrut_idx = ctx.local_count
      ctx.local_count += 1
      ctx.local_types.push(ValueKind::I64)
      compile_expr_i32(ctx, buf, scrutinee)
      emit_local_set(buf, scrut_idx)
      compile_match_chain(ctx, buf, scrut_idx, arms, 0)
      restore_locals(ctx, saved)
      restore_local_kinds(ctx, saved_kinds)
    }
    @core.Expr::Do(body~, span~) => {
      let _ = span
      compile_block_expr(ctx, buf, body)
    }
    @core.Expr::Handle(body~, arms~, span~) => {
      // Phase 1: compile Handle like Try, using first arm's expr as catch_body
      let catch_body_mod : @core.Module = match arms[0].expr {
        @core.Expr::Block(body=blk_body, ..) => blk_body
        other => @core.Module::{ stmts: [@core.Stmt::Expr(expr=other, span~)] }
      }
      let try_kind = if ctx.use_js_strings {
        infer_block_kind(ctx, body, ctx.local_kinds)
      } else {
        ValueKind::I64
      }
      adjust_loop_offsets(ctx, 3)
      buf.push((2).to_byte())
      buf.push(valtype_byte(try_kind))
      buf.push((2).to_byte())
      buf.push((64).to_byte())
      buf.push((31).to_byte())
      buf.push(valtype_byte(try_kind))
      write_u32_leb(buf, 1)
      buf.push((2).to_byte())
      write_u32_leb(buf, 0)
      compile_block_expr(ctx, buf, body)
      buf.push((11).to_byte())
      buf.push((12).to_byte())
      write_u32_leb(buf, 1)
      buf.push((11).to_byte())
      adjust_loop_offsets(ctx, -1)
      compile_block_expr(ctx, buf, catch_body_mod)
      buf.push((11).to_byte())
      adjust_loop_offsets(ctx, -2)
    }
    @core.Expr::Fn(params~, ret~, effects~, body~, span~, ..) => {
      let _ = params
      let _ = ret
      let _ = effects
      let _ = body
      let key = span_key(span)
      let func_idx = match ctx.fn_closure_indices.get(key) {
        Some(idx) => idx
        None => raise WasmGenError::Unsupported("fn index")
      }
      let captures = match ctx.fn_closure_captures.get(key) {
        Some(list) => list
        None => []
      }
      if captures.length() == 0 {
        let slot = ensure_funcref_slot(ctx, func_idx)
        emit_i64_const_raw(buf, tag_fn_value64(slot.to_int64()))
      } else {
        require_heap(ctx)
        let len = captures.length()
        let size = align4(8 + len * 8)
        let obj_local = alloc_temp_local(ctx)
        emit_heap_alloc(ctx, buf, size, obj_local)
        emit_local_get(buf, obj_local)
        emit_i32_const_raw(buf, obj_fn)
        emit_i32_store(buf, 0)
        emit_local_get(buf, obj_local)
        let slot = ensure_funcref_slot(ctx, func_idx)
        emit_i32_const_raw(buf, slot)
        emit_i32_store(buf, 4)
        let capture_kinds : Array[ValueKind] = []
        for i in 0..<len {
          let name = captures[i]
          let cap_kind = match ctx.local_kinds.get(name) {
            Some(kind) => kind
            None => ValueKind::I64
          }
          capture_kinds.push(cap_kind)
          if ctx.use_js_strings && cap_kind == ValueKind::ExternRef {
            // Store externref in extern table, put slot index in closure env
            ctx.need_extern_table = true
            let slot = ctx.extern_table_next_slot
            ctx.extern_table_next_slot += 1
            // table.set $extern_table slot externref_value
            emit_i32_const_raw(buf, slot)
            match ctx.locals.get(name) {
              Some(idx) => emit_local_get(buf, idx)
              None => raise WasmGenError::UnknownName(name)
            }
            emit_table_set(buf, ctx.extern_table_index)
            // Store slot index in closure env as i64
            emit_local_get(buf, obj_local)
            emit_i32_const_raw(buf, slot)
            emit_i64_extend_i32_u(buf)
            emit_i64_store(buf, 8 + i * 8)
          } else {
            emit_local_get(buf, obj_local)
            match ctx.locals.get(name) {
              Some(idx) => emit_local_get(buf, idx)
              None =>
                match ctx.fn_indices.get(name) {
                  Some(idx) => {
                    if fn_index_needs_env(ctx, idx) {
                      raise WasmGenError::Unsupported(
                        "closure capture requires env-backed function in scope: " +
                        name,
                      )
                    }
                    let slot = ensure_funcref_slot(ctx, idx)
                    emit_i64_const_raw(buf, tag_fn_value64(slot.to_int64()))
                  }
                  None => raise WasmGenError::UnknownName(name)
                }
            }
            // Store capture as i64 (all tagged values are i64)
            emit_i64_store(buf, 8 + i * 8)
          }
        }
        ctx.fn_closure_capture_kinds[key] = capture_kinds
        emit_local_get(buf, obj_local)
        emit_i64_extend_i32_u(buf)
        emit_i64_const_raw(buf, tag_obj.to_int64())
        emit_i64_or(buf)
      }
    }
    @core.Expr::While(cond~, body~, span~) => {
      let _ = span
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
    @core.Expr::Break(value~, span~) => {
      let _ = span
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
    @core.Expr::Continue(args~, span~) => {
      let _ = span
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
    @core.Expr::Loop(params~, body~, span~) => {
      let _ = span
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
    @core.Expr::Raise(value~, span~) => {
      let _ = span
      if not(ctx.use_js_strings) && not(ctx.embed_error_strings) {
        match value {
          @core.Expr::String(value=message, span~) => {
            let _ = span
            emit_i64_const_tagged(
              buf,
              intern_error_code(ctx, message).to_int64(),
            )
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
    @core.Expr::Yield(expr~, span~) => {
      let _ = span
      // Compile the expression to get the value to yield
      compile_expr_i32(ctx, buf, expr)
      // Emit suspend instruction with await tag (yield uses same tag)
      buf.push((0xe2).to_byte())
      write_u32_leb(buf, ctx.await_tag_index)
      // Yield returns Unit - the suspend result is dropped and we return 0
      buf.push((26).to_byte()) // drop the suspend result
      emit_i64_const_raw(buf, tag_int_value64(0L))
    }
    @core.Expr::StructLit(fields~, span~, ..) => {
      let _ = span
      // StructLit is compiled as record - same memory layout
      compile_record_expr(ctx, buf, fields)
    }
  }
}
