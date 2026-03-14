///|
fn compile_expr_string(ctx : CodegenCtx, buf : ByteBuf, value : String) -> Unit {
  if ctx.use_js_strings {
    let idx = ctx.js_strings.intern(value)
    emit_global_get(buf, idx)
  } else {
    let offset = ctx.strings.intern(value)
    emit_i64_const_raw(buf, tag_ptr64(offset, tag_obj))
  }
}

///|
fn compile_expr_ident(
  ctx : CodegenCtx,
  buf : ByteBuf,
  name : String,
) -> Unit raise WasmGenError {
  if is_qualified_name(name) {
    raise WasmGenError::BackendLimit(
      backend="wasm",
      feature="qualified name: " + name,
    )
  }
  // Check locals first (parameters/bindings shadow constants)
  match ctx.locals.get(name) {
    Some(idx) =>
      if ctx.mut_captured_vars.contains(name) {
        // Ref cell: dereference pointer to read value
        emit_local_get(buf, idx) // i32 pointer
        emit_i64_load(buf, 0) // deref → i64 value
      } else {
        emit_local_get(buf, idx)
      }
    None =>
      // Check constant table (pre-tagged i64 values)
      match ctx.const_i64_values.get(name) {
        Some(tagged_val) => emit_i64_const_raw(buf, tagged_val)
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
}

///|
fn compile_expr_tuple_index(
  ctx : CodegenCtx,
  buf : ByteBuf,
  expr : @core.Expr,
  index : Int,
) -> Unit raise WasmGenError {
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

///| Check if a condition expression can be compiled directly as i32 (dry-run).
fn can_compile_cond_i32(
  ctx : CodegenCtx,
  cond : @core.Expr,
) -> Bool raise WasmGenError {
  match cond {
    @core.Expr::Bool(..) => true
    @core.Expr::Call(name~, args~, ..) => {
      let name = @core.lower_wasm_intrinsic_name(name)
      match name {
        "eq" | "__eq" | "lt" | "__lt" => {
          let pos_args = extract_positional_exprs(args, name)
          if pos_args.length() == 2 {
            let resolved_kind = resolve_numeric_kind(
              ctx, pos_args[0], pos_args[1],
            )
            resolved_kind == ValueKind::I32 || resolved_kind == ValueKind::I64
          } else {
            false
          }
        }
        "not" => {
          let pos_args = extract_positional_exprs(args, name)
          pos_args.length() == 1 && can_compile_cond_i32(ctx, pos_args[0])
        }
        "and" | "or" => {
          let pos_args = extract_positional_exprs(args, name)
          pos_args.length() == 2 &&
            can_compile_cond_i32(ctx, pos_args[0]) &&
            can_compile_cond_i32(ctx, pos_args[1])
        }
        _ => false
      }
    }
    _ => false
  }
}

///| Try to compile a condition expression directly as i32 (0 or 1),
/// bypassing the tagged bool encode/decode roundtrip.
/// Returns true if the shortcut was applied.
fn try_compile_cond_i32(
  ctx : CodegenCtx,
  buf : ByteBuf,
  cond : @core.Expr,
) -> Bool raise WasmGenError {
  match cond {
    @core.Expr::Bool(value~, ..) => {
      emit_i32_const_raw(buf, if value { 1 } else { 0 })
      true
    }
    @core.Expr::Call(name~, args~, ..) => {
      let name = @core.lower_wasm_intrinsic_name(name)
      match name {
        "eq" | "__eq" | "lt" | "__lt" => {
          let pos_args = extract_positional_exprs(args, name)
          if pos_args.length() == 2 {
            let resolved_kind = resolve_numeric_kind(
              ctx, pos_args[0], pos_args[1],
            )
            match resolved_kind {
              ValueKind::I32 | ValueKind::I64 => {
                compile_expr_i32(ctx, buf, pos_args[0])
                compile_expr_i32(ctx, buf, pos_args[1])
                match name {
                  "eq" | "__eq" => emit_i64_eq(buf)
                  _ => emit_i64_lt_s(buf)
                }
                true
              }
              _ => false
            }
          } else {
            false
          }
        }
        "not" => {
          let pos_args = extract_positional_exprs(args, name)
          if pos_args.length() == 1 &&
            try_compile_cond_i32(ctx, buf, pos_args[0]) {
            emit_i32_eqz(buf)
            true
          } else {
            false
          }
        }
        "and" => {
          let pos_args = extract_positional_exprs(args, name)
          if pos_args.length() == 2 &&
            can_compile_cond_i32(ctx, pos_args[0]) &&
            can_compile_cond_i32(ctx, pos_args[1]) {
            let _ = try_compile_cond_i32(ctx, buf, pos_args[0])
            let _ = try_compile_cond_i32(ctx, buf, pos_args[1])
            emit_i32_and(buf)
            true
          } else {
            false
          }
        }
        "or" => {
          let pos_args = extract_positional_exprs(args, name)
          if pos_args.length() == 2 &&
            can_compile_cond_i32(ctx, pos_args[0]) &&
            can_compile_cond_i32(ctx, pos_args[1]) {
            let _ = try_compile_cond_i32(ctx, buf, pos_args[0])
            let _ = try_compile_cond_i32(ctx, buf, pos_args[1])
            emit_i32_or(buf)
            true
          } else {
            false
          }
        }
        _ => false
      }
    }
    _ => false
  }
}

///|
fn compile_expr_if(
  ctx : CodegenCtx,
  buf : ByteBuf,
  expr : @core.Expr,
  cond : @core.Expr,
  then_body : @core.Module,
  else_body : @core.Module,
  span : @core.Span,
) -> Unit raise WasmGenError {
  let if_kind = if ctx.use_js_strings {
    infer_expr_kind(ctx, expr)
  } else {
    ValueKind::I64
  }
  // Optimization: if cond is an integer comparison, emit comparison directly
  // without going through tagged bool (tag → untag cancels out)
  if not(try_compile_cond_i32(ctx, buf, cond)) {
    compile_expr_i32(ctx, buf, cond)
    emit_i64_const_raw(buf, 2L)
    emit_i64_shr_u(buf)
    emit_i32_wrap_i64(buf)
  }
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

///|
fn compile_expr_match(
  ctx : CodegenCtx,
  buf : ByteBuf,
  scrutinee : @core.Expr,
  arms : Array[@core.MatchArm],
) -> Unit raise WasmGenError {
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
