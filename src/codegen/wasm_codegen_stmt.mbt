///|
fn compile_stmt(
  ctx : CodegenCtx,
  buf : ByteBuf,
  stmt : @core.Stmt,
  is_last : Bool,
) -> Unit raise WasmGenError {
  emit_coverage(ctx, buf, WasmCoveragePointKind::Line, stmt.span())
  match stmt {
    @core.Stmt::Let(rec~, name~, expr~, span~) => {
      let _ = span
      match expr {
        @core.Expr::Fn(
          params=fn_params,
          ret=fn_ret,
          effects~,
          body=fn_body,
          span=fn_span,
          ..
        ) => {
          let _ = effects
          let key = span_key(fn_span)
          let func_idx = match ctx.fn_closure_indices.get(key) {
            Some(i) => i
            None => -1
          }
          let kinds = param_kinds(ctx, fn_params)
          let ret_kind = match fn_ret {
            Some(r) => value_kind_from_type(ctx, r)
            None => ValueKind::I32
          }
          ctx.fn_local_sigs[name] = match ctx.fn_multivalue_results.get(name) {
            Some(results) => func_sig_with_env_multi(kinds, results)
            None => func_sig_with_env(kinds, ret_kind)
          }
          if func_idx >= 0 {
            // Register as callable function (direct call)
            ctx.fn_indices[name] = func_idx
            ctx.fn_params[name] = kinds
            // Save parameter names for labeled args resolution
            let names : Array[String] = []
            for p in fn_params {
              names.push(p.name)
            }
            ctx.fn_param_names[name] = names
            ctx.fn_returns[name] = ret_kind
            // Infer return signature if function returns a function type
            match fn_ret {
              Some(r) =>
                match func_sig_from_type(ctx, r) {
                  Some(sig) => ctx.fn_return_sigs[name] = sig
                  None => ()
                }
              None =>
                // Try to infer from body's last expression
                match infer_body_return_sig(ctx, fn_body) {
                  Some(sig) => ctx.fn_return_sigs[name] = sig
                  None => ()
                }
            }
          }
          let kind = infer_expr_kind(ctx, expr)
          let idx = ctx.local_count
          ctx.local_count += 1
          ctx.local_types.push(kind)
          ctx.locals[name] = idx
          ctx.local_kinds[name] = kind
          compile_expr(ctx, buf, expr)
          if is_last {
            emit_local_tee(buf, idx)
          } else {
            emit_local_set(buf, idx)
          }
          // Back-patch self-reference for recursive closures
          if rec {
            let captures = match ctx.fn_closure_captures.get(key) {
              Some(list) => list
              None => []
            }
            for i in 0..<captures.length() {
              if captures[i] == name {
                // Found self-reference capture at slot i
                // Load env pointer (untag obj ptr), write closure value to slot
                let env_local = alloc_temp_local(ctx)
                emit_local_get(buf, idx)
                emit_i64_const_raw(buf, (-4).to_int64())
                emit_i64_and(buf)
                emit_i32_wrap_i64(buf) // untag obj pointer to i32
                emit_local_set(buf, env_local)
                emit_local_get(buf, env_local)
                emit_local_get(buf, idx) // closure value (i64)
                emit_i32_wrap_i64(buf) // truncate to i32 for memory store
                emit_i32_store(buf, 8 + i * 4) // write to capture slot
                break
              }
            }
          }
        }
        _ => {
          let kind = infer_expr_kind(ctx, expr)
          let idx = ctx.local_count
          ctx.local_count += 1
          ctx.local_types.push(kind)
          ctx.locals[name] = idx
          ctx.local_kinds[name] = kind
          // If the expression is a Call that returns a function, register in fn_local_sigs
          match expr {
            @core.Expr::Ident(name=source_name, span~) => {
              let _ = span
              match ctx.fn_local_sigs.get(source_name) {
                Some(sig) => ctx.fn_local_sigs[name] = sig
                None => ()
              }
              match ctx.fn_indices.get(source_name) {
                Some(func_idx) => {
                  ctx.fn_indices[name] = func_idx
                  match ctx.fn_params.get(source_name) {
                    Some(kinds) => ctx.fn_params[name] = kinds
                    None => ()
                  }
                  match ctx.fn_param_names.get(source_name) {
                    Some(names) => ctx.fn_param_names[name] = names
                    None => ()
                  }
                  match ctx.fn_returns.get(source_name) {
                    Some(ret_kind) => ctx.fn_returns[name] = ret_kind
                    None => ()
                  }
                  match ctx.fn_return_sigs.get(source_name) {
                    Some(sig) => ctx.fn_return_sigs[name] = sig
                    None => ()
                  }
                }
                None => ()
              }
            }
            @core.Expr::Call(name=call_name, args~, span~, ..) => {
              let _ = args
              let _ = span
              match ctx.fn_return_sigs.get(call_name) {
                Some(sig) => ctx.fn_local_sigs[name] = sig
                None => ()
              }
            }
            _ => ()
          }
          compile_expr(ctx, buf, expr)
          // After compiling Block expressions (e.g. from declare export let with
          // type assertion wrapper), propagate fn_return_sigs from inner Call
          // to fn_local_sigs so the bound name is correctly typed when called.
          match expr {
            @core.Expr::Block(body=block_body, ..) => {
              let block_stmts = block_body.stmts
              if block_stmts.length() > 0 {
                match block_stmts[block_stmts.length() - 1] {
                  @core.Stmt::Expr(
                    expr=@core.Expr::Call(name=call_name, ..),
                    ..
                  ) =>
                    match ctx.fn_return_sigs.get(call_name) {
                      Some(sig) => ctx.fn_local_sigs[name] = sig
                      None => ()
                    }
                  _ => ()
                }
              }
            }
            _ => ()
          }
          if is_last {
            emit_local_tee(buf, idx)
          } else {
            emit_local_set(buf, idx)
          }
        }
      }
    }
    @core.Stmt::EnumDef(name~, params~, ctors~, span~) => {
      let _ = name
      let _ = params
      let _ = span
      for i in 0..<ctors.length() {
        let ctor = ctors[i]
        ctx.enum_ctor_tags[ctor.name] = i
        ctx.enum_ctor_arities[ctor.name] = ctor.args.length()
        if not(ctx.enum_ctor_arg_kinds.contains(ctor.name)) {
          let arg_kinds : Array[ValueKind] = []
          for arg in ctor.args {
            arg_kinds.push(value_kind_from_type(ctx, arg))
          }
          ctx.enum_ctor_arg_kinds[ctor.name] = arg_kinds
        }
      }
      if is_last {
        emit_i64_const_tagged(buf, 0L)
      }
    }
    @core.Stmt::TypeAlias(name~, params~, target~, span~) => {
      let _ = name
      let _ = params
      let _ = target
      let _ = span
      if is_last {
        emit_i64_const_tagged(buf, 0L)
      }
    }
    @core.Stmt::Expr(expr~, span~) => {
      let _ = span
      compile_expr(ctx, buf, expr)
      if not(is_last) {
        emit_drop(buf)
      }
    }
    @core.Stmt::Test(name~, body~, span~) => {
      let _ = name
      let _ = body
      let _ = span
      if is_last {
        emit_i64_const_tagged(buf, 0L)
      }
    }
    @core.Stmt::Bench(name~, body~, span~) => {
      let _ = name
      let _ = body
      let _ = span
      if is_last {
        emit_i64_const_tagged(buf, 0L)
      }
    }
    @core.Stmt::Import(spec~, source~, span~) => {
      let _ = spec
      let _ = source
      let _ = span
      raise WasmGenError::Unsupported("import")
    }
    @core.Stmt::ExportLet(rec~, name~, expr~, span~) =>
      // ExportLet is compiled like Let - the export is handled at module level
      compile_stmt(
        ctx,
        buf,
        @core.Stmt::Let(rec~, name~, expr~, span~),
        is_last,
      )
    @core.Stmt::ExportEnumDef(name~, params~, ctors~, span~) =>
      // ExportEnumDef is compiled like EnumDef for constructor metadata.
      compile_stmt(
        ctx,
        buf,
        @core.Stmt::EnumDef(name~, params~, ctors~, span~),
        is_last,
      )
    @core.Stmt::ExportTypeAlias(..) =>
      // Type exports have no runtime representation in WASM
      // If this is the last statement, push unit
      if is_last {
        emit_i64_const_tagged(buf, 0L)
      }
    @core.Stmt::Export(..)
    | @core.Stmt::ReExport(..)
    | @core.Stmt::TraitDef(..)
    | @core.Stmt::TraitImpl(..)
    | @core.Stmt::StructDef(..)
    | @core.Stmt::ExportStructDef(..) =>
      // export { ... } statements and struct definitions are handled during bundling/typechecking
      // At codegen time, they are no-ops
      if is_last {
        emit_i64_const_tagged(buf, 0L)
      }
    @core.Stmt::LetMut(name~, expr~, span~) => {
      let _ = span
      // LetMut is similar to Let, but the variable can be reassigned
      let kind = infer_expr_kind(ctx, expr)
      let idx = ctx.local_count
      ctx.local_count += 1
      ctx.local_types.push(kind)
      ctx.locals[name] = idx
      ctx.local_kinds[name] = kind
      compile_expr(ctx, buf, expr)
      if is_last {
        emit_local_tee(buf, idx)
      } else {
        emit_local_set(buf, idx)
      }
    }
    @core.Stmt::Assign(name~, expr~, span~) => {
      let _ = span
      // Assign updates an existing mutable variable
      match ctx.locals.get(name) {
        Some(idx) => {
          compile_expr(ctx, buf, expr)
          if is_last {
            emit_local_tee(buf, idx)
          } else {
            emit_local_set(buf, idx)
          }
        }
        None => raise UnknownName(name)
      }
    }
    @core.Stmt::IndexAssign(target~, index~, value~, span~) => {
      // IndexAssign: target[index] = value → __set_index(target, index, value)
      // Desugar to call expression
      let call_expr = @core.Expr::Call(
        name="__set_index",
        type_args=[],
        args=[
          @core.CallArg::{ label: None, expr: target, span: target.span() },
          @core.CallArg::{ label: None, expr: index, span: index.span() },
          @core.CallArg::{ label: None, expr: value, span: value.span() },
        ],
        span~,
      )
      compile_expr(ctx, buf, call_expr)
      if not(is_last) {
        emit_drop(buf)
      }
    }
    @core.Stmt::LetPat(pat~, expr~, span~) => {
      let _ = span
      match pat {
        @core.Pat::Tuple(items~, span=pat_span) => {
          let _ = pat_span
          let mv_call_kinds : Array[ValueKind]? = match
            detect_multivalue_call(ctx, expr) {
            Some(kinds) =>
              if kinds.length() == items.length() {
                Some(kinds)
              } else {
                None
              }
            None => None
          }
          match mv_call_kinds {
            Some(_) => {
              // Multi-value call: compile call WITHOUT re-boxing,
              // receive values directly from the stack.
              compile_expr_multivalue_call(ctx, buf, expr)
              // Stack has [val0, val1, ...] — store in reverse (top-of-stack first)
              let len = items.length()
              let temp_locals : Array[Int] = Array::make(len, 0)
              for i = len - 1; i >= 0; i = i - 1 {
                let tmp = alloc_temp_local_with_kind(ctx, ValueKind::I64)
                temp_locals[i] = tmp
                emit_local_set(buf, tmp)
              }
              // Now bind each value to the pattern variable
              for i in 0..<len {
                match items[i] {
                  @core.Pat::Bind(name~, span=bind_span) => {
                    let _ = bind_span
                    let local_idx = ctx.local_count
                    ctx.local_count += 1
                    ctx.local_types.push(ValueKind::I64)
                    ctx.locals[name] = local_idx
                    ctx.local_kinds[name] = ValueKind::I64
                    emit_local_get(buf, temp_locals[i])
                    if is_last && i == len - 1 {
                      emit_local_tee(buf, local_idx)
                    } else {
                      emit_local_set(buf, local_idx)
                    }
                  }
                  @core.Pat::Wildcard(..) =>
                    if is_last && i == len - 1 {
                      emit_local_get(buf, temp_locals[i])
                    }
                  _ => {
                    ctx.locals["\u0000mv_temp_" + i.to_string()] = temp_locals[i]
                    ctx.local_kinds["\u0000mv_temp_" + i.to_string()] = ValueKind::I64
                    compile_let_pat_nested(ctx, buf, items[i], temp_locals[i])
                  }
                }
              }
              if is_last && len == 0 {
                emit_i64_const_tagged(buf, 0L)
              }
            }
            None => {
              // Standard path: compile as heap-allocated tuple
              compile_expr_i32(ctx, buf, expr) // tuple pointer (tagged i64)
              let tuple_local = alloc_temp_local_with_kind(ctx, ValueKind::I64)
              emit_local_set(buf, tuple_local)
              let len = items.length()
              for i in 0..<len {
                match items[i] {
                  @core.Pat::Bind(name~, span=bind_span) => {
                    let _ = bind_span
                    let local_idx = ctx.local_count
                    ctx.local_count += 1
                    ctx.local_types.push(ValueKind::I64)
                    ctx.locals[name] = local_idx
                    ctx.local_kinds[name] = ValueKind::I64
                    emit_load_tuple_elem(buf, tuple_local, i)
                    if is_last && i == len - 1 {
                      emit_local_tee(buf, local_idx)
                    } else {
                      emit_local_set(buf, local_idx)
                    }
                  }
                  @core.Pat::Wildcard(..) =>
                    if is_last && i == len - 1 {
                      emit_load_tuple_elem(buf, tuple_local, i)
                    }
                  _ => {
                    // Nested pattern - load element and recursively destructure
                    let elem_local = alloc_temp_local_with_kind(
                      ctx,
                      ValueKind::I64,
                    )
                    emit_load_tuple_elem(buf, tuple_local, i)
                    emit_local_set(buf, elem_local)
                    compile_let_pat_nested(ctx, buf, items[i], elem_local)
                  }
                }
              }
              if is_last && len == 0 {
                emit_i64_const_tagged(buf, 0L)
              }
            }
          }
        }
        @core.Pat::Record(fields~, span=pat_span) => {
          let _ = pat_span
          compile_expr_i32(ctx, buf, expr) // record pointer (tagged i64)
          let record_local = alloc_temp_local_with_kind(ctx, ValueKind::I64)
          emit_local_set(buf, record_local)
          let sorted = sort_record_fields_pat(fields)
          let len = sorted.length()
          for i, field in sorted {
            match field.pat {
              @core.Pat::Bind(name~, span=bind_span) => {
                let _ = bind_span
                let local_idx = ctx.local_count
                ctx.local_count += 1
                ctx.local_types.push(ValueKind::I64)
                ctx.locals[name] = local_idx
                ctx.local_kinds[name] = ValueKind::I64
                // Record value is at offset 8 + i * 8 + 4 (key-value pairs)
                emit_load_record_value(buf, record_local, i)
                if is_last && i == len - 1 {
                  emit_local_tee(buf, local_idx)
                } else {
                  emit_local_set(buf, local_idx)
                }
              }
              @core.Pat::Wildcard(..) =>
                if is_last && i == len - 1 {
                  emit_load_record_value(buf, record_local, i)
                }
              _ => {
                // Nested pattern - load element and recursively destructure
                let elem_local = alloc_temp_local_with_kind(ctx, ValueKind::I64)
                emit_load_record_value(buf, record_local, i)
                emit_local_set(buf, elem_local)
                compile_let_pat_nested(ctx, buf, field.pat, elem_local)
              }
            }
          }
          if is_last && len == 0 {
            emit_i64_const_tagged(buf, 0L)
          }
        }
        @core.Pat::Ctor(name~, args~, span=pat_span) => {
          let _ = name
          let _ = pat_span
          compile_expr_i32(ctx, buf, expr) // enum pointer (tagged i64)
          let ctor_local = alloc_temp_local_with_kind(ctx, ValueKind::I64)
          emit_local_set(buf, ctor_local)
          let len = args.length()
          for i, arg_pat in args {
            match arg_pat {
              @core.Pat::Bind(name~, span=bind_span) => {
                let _ = bind_span
                let local_idx = ctx.local_count
                ctx.local_count += 1
                ctx.local_types.push(ValueKind::I64)
                ctx.locals[name] = local_idx
                ctx.local_kinds[name] = ValueKind::I64
                // Load from enum payload: offset 8 + i * 4
                emit_untag_ptr(buf, ctor_local)
                emit_i32_load(buf, 8 + i * 4)
                emit_i64_extend_i32_s(buf)
                if is_last && i == len - 1 {
                  emit_local_tee(buf, local_idx)
                } else {
                  emit_local_set(buf, local_idx)
                }
              }
              @core.Pat::Wildcard(..) =>
                if is_last && i == len - 1 {
                  emit_untag_ptr(buf, ctor_local)
                  emit_i32_load(buf, 8 + i * 4)
                  emit_i64_extend_i32_s(buf)
                }
              _ => {
                // Nested pattern
                let elem_local = alloc_temp_local_with_kind(ctx, ValueKind::I64)
                emit_untag_ptr(buf, ctor_local)
                emit_i32_load(buf, 8 + i * 4)
                emit_i64_extend_i32_s(buf)
                emit_local_set(buf, elem_local)
                compile_let_pat_nested(ctx, buf, arg_pat, elem_local)
              }
            }
          }
          if is_last && len == 0 {
            emit_i64_const_tagged(buf, 0L)
          }
        }
        _ => raise WasmGenError::Unsupported("let pat: non-tuple/record/ctor")
      }
    }
    @core.Stmt::LetPatElse(pat~, expr~, else_body~, span~) => {
      // Desugar to match: match expr { pat => unit, _ => else_body }
      let scrut_idx = ctx.local_count
      ctx.local_count += 1
      ctx.local_types.push(ValueKind::I64)
      compile_expr_i32(ctx, buf, expr)
      emit_local_set(buf, scrut_idx)
      // Build 2-arm match: success (bind + unit) and fallback (else_body)
      let success_arm = @core.MatchArm::{
        pat,
        cond: None,
        expr: @core.Expr::Tuple(items=[], span~),
        span,
      }
      let fallback_arm = @core.MatchArm::{
        pat: @core.Pat::Wildcard(span~),
        cond: None,
        expr: @core.Expr::Block(body=else_body, span~),
        span,
      }
      let arms = [success_arm, fallback_arm]
      compile_match_chain(ctx, buf, scrut_idx, arms, 0)
      // Drop the result if not last
      if not(is_last) {
        emit_drop(buf)
      }
    }
  }
}

///|
/// Recursively compile a let pattern element.
/// value_local contains the tagged i64 value to destructure.
fn compile_let_pat_nested(
  ctx : CodegenCtx,
  buf : ByteBuf,
  pat : @core.Pat,
  value_local : Int,
) -> Unit raise WasmGenError {
  match pat {
    @core.Pat::Bind(name~, span~) => {
      let _ = span
      let local_idx = ctx.local_count
      ctx.local_count += 1
      ctx.local_types.push(ValueKind::I64)
      ctx.locals[name] = local_idx
      ctx.local_kinds[name] = ValueKind::I64
      emit_local_get(buf, value_local)
      emit_local_set(buf, local_idx)
    }
    @core.Pat::Wildcard(..) => ()
    @core.Pat::Tuple(items~, span~) => {
      let _ = span
      // value_local contains tuple pointer (i64 tagged)
      for i, item in items {
        let elem_local = alloc_temp_local_with_kind(ctx, ValueKind::I64)
        emit_load_tuple_elem(buf, value_local, i)
        emit_local_set(buf, elem_local)
        compile_let_pat_nested(ctx, buf, item, elem_local)
      }
    }
    @core.Pat::Record(fields~, span~) => {
      let _ = span
      let sorted = sort_record_fields_pat(fields)
      for i, field in sorted {
        let elem_local = alloc_temp_local_with_kind(ctx, ValueKind::I64)
        emit_load_tuple_elem(buf, value_local, i)
        emit_local_set(buf, elem_local)
        compile_let_pat_nested(ctx, buf, field.pat, elem_local)
      }
    }
    @core.Pat::Ctor(name~, args~, span~) => {
      let _ = name
      let _ = span
      // Ctor payload starts at offset 8 (after obj_type and tag)
      // Each arg is at offset 8 + i * 4
      for i, arg_pat in args {
        let elem_local = alloc_temp_local_with_kind(ctx, ValueKind::I64)
        // Load from enum payload: untag ptr, load at offset 8 + i * 4
        emit_untag_ptr(buf, value_local)
        emit_i32_load(buf, 8 + i * 4)
        emit_i64_extend_i32_s(buf)
        emit_local_set(buf, elem_local)
        compile_let_pat_nested(ctx, buf, arg_pat, elem_local)
      }
    }
    _ => raise WasmGenError::Unsupported("let pat nested: unsupported pattern")
  }
}

///|
fn compile_block_expr(
  ctx : CodegenCtx,
  buf : ByteBuf,
  body : @core.Module,
) -> Unit raise WasmGenError {
  let saved = ctx.locals.copy()
  let saved_kinds = ctx.local_kinds.copy()
  let len = body.stmts.length()
  if len == 0 {
    emit_i64_const_tagged(buf, 0L)
  } else {
    for i in 0..<len {
      let is_last = i == len - 1
      compile_stmt(ctx, buf, body.stmts[i], is_last)
    }
  }
  restore_locals(ctx, saved)
  restore_local_kinds(ctx, saved_kinds)
}

///|
fn compile_block_multivalue(
  ctx : CodegenCtx,
  buf : ByteBuf,
  body : @core.Module,
  kinds : Array[ValueKind],
) -> Unit raise WasmGenError {
  let saved = ctx.locals.copy()
  let saved_kinds = ctx.local_kinds.copy()
  let len = body.stmts.length()
  if len == 0 {
    for kind in kinds {
      match kind {
        ValueKind::I64 | ValueKind::BoxedF32 | ValueKind::BoxedF64 =>
          emit_i64_const_raw(buf, 0L)
        ValueKind::I32 => emit_i32_const_raw(buf, 0)
        _ => emit_i64_const_raw(buf, 0L)
      }
    }
  } else {
    for i in 0..<(len - 1) {
      compile_stmt(ctx, buf, body.stmts[i], false)
    }
    let last = body.stmts[len - 1]
    match last {
      @core.Stmt::Expr(expr~, span~) => {
        let _ = span
        compile_expr_multivalue(ctx, buf, expr, kinds)
      }
      _ => compile_stmt(ctx, buf, last, true)
      // Should not happen — body_always_returns_tuple verified this
    }
  }
  restore_locals(ctx, saved)
  restore_local_kinds(ctx, saved_kinds)
}

///|
fn compile_expr_multivalue(
  ctx : CodegenCtx,
  buf : ByteBuf,
  expr : @core.Expr,
  kinds : Array[ValueKind],
) -> Unit raise WasmGenError {
  match expr {
    @core.Expr::Tuple(items~, span~) => {
      let _ = span
      for i in 0..<items.length() {
        compile_expr(ctx, buf, items[i])
      }
    }
    @core.Expr::If(cond~, then_body~, else_body~, span~) => {
      let _ = span
      compile_expr(ctx, buf, cond)
      // Untag bool to i32 for br_if
      emit_i64_const_raw(buf, (-4).to_int64())
      emit_i64_and(buf)
      emit_i32_wrap_i64(buf)
      buf.push((4).to_byte()) // if
      // Block type: multi-value via type index
      let sig = FuncSig::{ params: [], results: kinds }
      let type_idx = ensure_sig_index(ctx, sig)
      write_i32_leb(buf, type_idx)
      compile_block_multivalue(ctx, buf, then_body, kinds)
      buf.push((5).to_byte()) // else
      compile_block_multivalue(ctx, buf, else_body, kinds)
      buf.push((11).to_byte()) // end
    }
    @core.Expr::Block(body~, span~) => {
      let _ = span
      compile_block_multivalue(ctx, buf, body, kinds)
    }
    @core.Expr::Do(body~, span~) => {
      let _ = span
      compile_block_multivalue(ctx, buf, body, kinds)
    }
    @core.Expr::Try(try_body~, catch_body~, span~) => {
      let _ = span
      // Multi-value try: use type index for multi-value blocktype
      let sig = FuncSig::{ params: [], results: kinds }
      let type_idx = ensure_sig_index(ctx, sig)
      adjust_loop_offsets(ctx, 3)
      // (block $outer (type T)  ;; multi-value result
      buf.push((2).to_byte())
      write_i32_leb(buf, type_idx)
      //   (block $catch_target  ;; no result
      buf.push((2).to_byte())
      buf.push((64).to_byte())
      //     (try_table (type T) (catch_all 0)
      buf.push((31).to_byte())
      write_i32_leb(buf, type_idx)
      write_u32_leb(buf, 1)
      buf.push((2).to_byte())
      write_u32_leb(buf, 0)
      //       try_body as multi-value
      compile_block_multivalue(ctx, buf, try_body, kinds)
      buf.push((11).to_byte()) // end try_table
      buf.push((12).to_byte()) // br $outer
      write_u32_leb(buf, 1)
      buf.push((11).to_byte()) // end $catch_target
      adjust_loop_offsets(ctx, -1)
      // catch_body: may return multi-value or raise
      compile_block_multivalue(ctx, buf, catch_body, kinds)
      buf.push((11).to_byte()) // end $outer
      adjust_loop_offsets(ctx, -2)
    }
    @core.Expr::Raise(..) =>
      // Compile raise — never returns, wasm stack becomes unreachable
      compile_expr(ctx, buf, expr)
    @core.Expr::Call(name~, ..) =>
      // Forward multi-value from another multi-value function call
      match ctx.fn_multivalue_results.get(name) {
        Some(mv_kinds) =>
          if mv_kinds.length() == kinds.length() {
            compile_expr_multivalue_call(ctx, buf, expr)
          } else {
            emit_multivalue_from_tuple_expr(ctx, buf, expr, kinds)
          }
        None => emit_multivalue_from_tuple_expr(ctx, buf, expr, kinds)
      }
    _ =>
      // Fallback for Match and other complex expressions:
      // Compile as regular expression (produces heap-allocated tuple),
      // then extract elements for multi-value return.
      emit_multivalue_from_tuple_expr(ctx, buf, expr, kinds)
  }
}

///|
fn emit_multivalue_from_tuple_expr(
  ctx : CodegenCtx,
  buf : ByteBuf,
  expr : @core.Expr,
  kinds : Array[ValueKind],
) -> Unit raise WasmGenError {
  compile_expr(ctx, buf, expr)
  let tuple_local = alloc_temp_local_with_kind(ctx, ValueKind::I64)
  emit_local_set(buf, tuple_local)
  for i in 0..<kinds.length() {
    emit_load_tuple_elem(buf, tuple_local, i)
  }
}

///|
fn detect_multivalue_call(
  ctx : CodegenCtx,
  expr : @core.Expr,
) -> Array[ValueKind]? {
  match expr {
    @core.Expr::Call(name~, ..) => {
      let lowered = @core.lower_wasm_intrinsic_name(name)
      let is_direct = ctx.fn_indices.contains(lowered) &&
        not(ctx.fn_local_sigs.contains(lowered) && ctx.locals.contains(lowered))
      let indirect_mv = match ctx.fn_local_sigs.get(lowered) {
        Some(sig) => sig.results.length() > 1 && ctx.locals.contains(lowered)
        None => false
      }
      if is_direct || indirect_mv {
        ctx.fn_multivalue_results.get(name)
      } else {
        None
      }
    }
    _ => None
  }
}

///|
fn compile_expr_multivalue_call(
  ctx : CodegenCtx,
  buf : ByteBuf,
  expr : @core.Expr,
) -> Unit raise WasmGenError {
  // Compile a Call expression that returns multi-value WITHOUT re-boxing.
  // Temporarily remove the function from fn_multivalue_results so compile_expr
  // doesn't re-box, then restore it.
  match expr {
    @core.Expr::Call(name~, ..) => {
      let saved = ctx.fn_multivalue_results.get(name)
      ctx.fn_multivalue_results.remove(name)
      compile_expr(ctx, buf, expr)
      match saved {
        Some(kinds) => ctx.fn_multivalue_results[name] = kinds
        None => ()
      }
    }
    _ => compile_expr(ctx, buf, expr)
  }
}

///|
fn emit_rebox_multivalue(
  ctx : CodegenCtx,
  buf : ByteBuf,
  kinds : Array[ValueKind],
) -> Unit raise WasmGenError {
  // Store each multi-value result in a temp local
  let temp_locals : Array[Int] = []
  // Pop in reverse order (last result is on top of stack)
  for i = kinds.length() - 1; i >= 0; i = i - 1 {
    let tmp = alloc_temp_local_with_kind(ctx, ValueKind::I64)
    temp_locals.push(tmp)
    emit_local_set(buf, tmp)
  }
  // Now construct a heap tuple from the stored values
  require_heap(ctx)
  let len = kinds.length()
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
    emit_local_get(buf, obj_local)
    // temp_locals is in reverse order, so access accordingly
    emit_local_get(buf, temp_locals[len - 1 - i])
    emit_i32_wrap_i64(buf)
    emit_i32_store(buf, 8 + i * 4)
  }
  emit_local_get(buf, obj_local)
  emit_i64_extend_i32_u(buf)
  emit_i64_const_raw(buf, tag_obj.to_int64())
  emit_i64_or(buf)
}
