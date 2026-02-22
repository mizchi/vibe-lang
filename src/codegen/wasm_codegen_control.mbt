///|
priv enum PatCont {
  Arm
  Tuple(Int, Array[@core.Pat], Int, PatCont) // raw_ptr, items, index, next
  Record(Int, Array[@core.RecordFieldPat], Int, PatCont) // raw_ptr, fields, index, next
  Ctor(Int, Array[@core.Pat], Int, String, PatCont) // raw_ptr, args, index, ctor_name, next
}

///|
fn compile_pat_cont(
  ctx : CodegenCtx,
  buf : ByteBuf,
  cont : PatCont,
  match_scrut_idx : Int,
  arms : Array[@core.MatchArm],
  start : Int,
  arm : @core.MatchArm,
  bindings : Map[String, Int],
) -> Unit raise WasmGenError {
  match cont {
    PatCont::Arm =>
      compile_guarded_arm_with_bindings(
        ctx, buf, match_scrut_idx, arms, start, arm, bindings,
      )
    PatCont::Tuple(tuple_idx, items, index, next) =>
      compile_tuple_items_cont(
        ctx, buf, tuple_idx, items, index, next, match_scrut_idx, arms, start, arm,
        bindings,
      )
    PatCont::Record(record_idx, fields, index, next) =>
      compile_record_fields_cont(
        ctx, buf, record_idx, fields, index, next, match_scrut_idx, arms, start,
        arm, bindings,
      )
    PatCont::Ctor(ctor_idx, args, index, ctor_name, next) =>
      compile_ctor_args_cont(
        ctx, buf, ctor_idx, args, index, ctor_name, next, match_scrut_idx, arms,
        start, arm, bindings,
      )
  }
}

///|
fn compile_pat_match(
  ctx : CodegenCtx,
  buf : ByteBuf,
  value_idx : Int,
  pat : @core.Pat,
  match_scrut_idx : Int,
  arms : Array[@core.MatchArm],
  start : Int,
  arm : @core.MatchArm,
  bindings : Map[String, Int],
  cont : PatCont,
) -> Unit raise WasmGenError {
  match pat {
    @core.Pat::Wildcard(span~) => {
      let _ = span
      compile_pat_cont(
        ctx, buf, cont, match_scrut_idx, arms, start, arm, bindings,
      )
    }
    @core.Pat::Bind(name~, span~) => {
      let _ = span
      let idx = bind_local(ctx, name)
      emit_local_get(buf, value_idx)
      emit_local_set(buf, idx)
      bindings[name] = idx
      compile_pat_cont(
        ctx, buf, cont, match_scrut_idx, arms, start, arm, bindings,
      )
    }
    @core.Pat::Int(value~, span~) => {
      let _ = value
      let _ = span
      emit_local_get(buf, value_idx)
      emit_pat_literal(ctx, buf, pat)
      emit_i64_eq(buf)
      buf.push((4).to_byte())
      buf.push((126).to_byte())
      adjust_loop_offsets(ctx, 1)
      compile_pat_cont(
        ctx, buf, cont, match_scrut_idx, arms, start, arm, bindings,
      )
      buf.push((5).to_byte())
      compile_match_chain(ctx, buf, match_scrut_idx, arms, start + 1)
      buf.push((11).to_byte())
      adjust_loop_offsets(ctx, -1)
    }
    @core.Pat::Char(value~, span~) => {
      let _ = value
      let _ = span
      emit_local_get(buf, value_idx)
      emit_pat_literal(ctx, buf, pat)
      emit_i64_eq(buf)
      buf.push((4).to_byte())
      buf.push((126).to_byte())
      adjust_loop_offsets(ctx, 1)
      compile_pat_cont(
        ctx, buf, cont, match_scrut_idx, arms, start, arm, bindings,
      )
      buf.push((5).to_byte())
      compile_match_chain(ctx, buf, match_scrut_idx, arms, start + 1)
      buf.push((11).to_byte())
      adjust_loop_offsets(ctx, -1)
    }
    @core.Pat::Float(value=n, span~) => {
      let _ = span
      // Combined check: tag_obj AND type==obj_float AND value==n
      emit_tag_obj_check(buf, value_idx)
      emit_load_obj_type(buf, value_idx)
      emit_i32_const_raw(buf, obj_float)
      emit_i32_eq(buf)
      emit_i32_and(buf)
      emit_untag_ptr(buf, value_idx)
      emit_f32_load(buf, 4)
      emit_f32_const(buf, n)
      emit_f32_eq(buf)
      emit_i32_and(buf)
      // Single if-else
      buf.push((4).to_byte()) // if
      buf.push((126).to_byte()) // result i64
      adjust_loop_offsets(ctx, 1)
      compile_pat_cont(
        ctx, buf, cont, match_scrut_idx, arms, start, arm, bindings,
      )
      buf.push((5).to_byte()) // else
      compile_match_chain(ctx, buf, match_scrut_idx, arms, start + 1)
      buf.push((11).to_byte()) // end
      adjust_loop_offsets(ctx, -1)
    }
    @core.Pat::Double(value=n, span~) => {
      let _ = span
      // Combined check: tag_obj AND type==obj_double AND value==n
      emit_tag_obj_check(buf, value_idx)
      emit_load_obj_type(buf, value_idx)
      emit_i32_const_raw(buf, obj_double)
      emit_i32_eq(buf)
      emit_i32_and(buf)
      emit_untag_ptr(buf, value_idx)
      emit_f64_load(buf, 4)
      emit_f64_const(buf, n)
      emit_f64_eq(buf)
      emit_i32_and(buf)
      // Single if-else
      buf.push((4).to_byte()) // if
      buf.push((126).to_byte()) // result i64
      adjust_loop_offsets(ctx, 1)
      compile_pat_cont(
        ctx, buf, cont, match_scrut_idx, arms, start, arm, bindings,
      )
      buf.push((5).to_byte()) // else
      compile_match_chain(ctx, buf, match_scrut_idx, arms, start + 1)
      buf.push((11).to_byte()) // end
      adjust_loop_offsets(ctx, -1)
    }
    @core.Pat::Bool(value~, span~) => {
      let _ = value
      let _ = span
      emit_local_get(buf, value_idx)
      emit_pat_literal(ctx, buf, pat)
      emit_i64_eq(buf)
      buf.push((4).to_byte())
      buf.push((126).to_byte())
      adjust_loop_offsets(ctx, 1)
      compile_pat_cont(
        ctx, buf, cont, match_scrut_idx, arms, start, arm, bindings,
      )
      buf.push((5).to_byte())
      compile_match_chain(ctx, buf, match_scrut_idx, arms, start + 1)
      buf.push((11).to_byte())
      adjust_loop_offsets(ctx, -1)
    }
    @core.Pat::String(value=s, span~) => {
      let _ = span
      if ctx.use_js_strings {
        // js-string mode: use js_equals to compare externref strings
        ctx.need_js_equals = true
        // Load scrutinee (externref)
        emit_local_get(buf, value_idx)
        // Load pattern string constant (externref from global)
        let str_idx = ctx.js_strings.intern(s)
        emit_global_get(buf, str_idx)
        // Call js_equals
        emit_call(buf, import_index_js_equals(ctx))
        // Result is i32 (0 or 1)
        buf.push((4).to_byte()) // if
        buf.push((126).to_byte()) // result i64
        adjust_loop_offsets(ctx, 1)
        compile_pat_cont(
          ctx, buf, cont, match_scrut_idx, arms, start, arm, bindings,
        )
        buf.push((5).to_byte())
        compile_match_chain(ctx, buf, match_scrut_idx, arms, start + 1)
        buf.push((11).to_byte())
        adjust_loop_offsets(ctx, -1)
      } else {
        // Non-js-string mode: compare tagged pointers
        emit_local_get(buf, value_idx)
        emit_pat_literal(ctx, buf, pat)
        emit_i64_eq(buf)
        buf.push((4).to_byte())
        buf.push((126).to_byte())
        adjust_loop_offsets(ctx, 1)
        compile_pat_cont(
          ctx, buf, cont, match_scrut_idx, arms, start, arm, bindings,
        )
        buf.push((5).to_byte())
        compile_match_chain(ctx, buf, match_scrut_idx, arms, start + 1)
        buf.push((11).to_byte())
        adjust_loop_offsets(ctx, -1)
      }
    }
    @core.Pat::Ctor(name~, args~, span~) => {
      let _ = span
      let tag = match ctx.enum_ctor_tags.get(name) {
        Some(t) => t
        None => raise WasmGenError::Unsupported("unknown ctor: " + name)
      }
      // Cache raw pointer for repeated use
      let raw_ptr = emit_untag_ptr_cached(ctx, buf, value_idx)
      // Combined header check: tag_obj AND type==obj_enum AND tag matches
      emit_tag_obj_check(buf, value_idx)
      emit_load_obj_type_raw(buf, raw_ptr)
      emit_i32_const_raw(buf, obj_enum)
      emit_i32_eq(buf)
      emit_i32_and(buf)
      emit_load_ctor_tag_raw(buf, raw_ptr)
      emit_i32_const_raw(buf, tag)
      emit_i32_eq(buf)
      emit_i32_and(buf)
      // Single if-else
      buf.push((4).to_byte()) // if
      buf.push((126).to_byte()) // result i64
      adjust_loop_offsets(ctx, 1)
      // Bind args
      if args.length() == 0 {
        compile_pat_cont(
          ctx, buf, cont, match_scrut_idx, arms, start, arm, bindings,
        )
      } else {
        compile_ctor_args_cont(
          ctx, buf, raw_ptr, args, 0, name, cont, match_scrut_idx, arms, start, arm,
          bindings,
        )
      }
      buf.push((5).to_byte()) // else
      compile_match_chain(ctx, buf, match_scrut_idx, arms, start + 1)
      buf.push((11).to_byte()) // end
      adjust_loop_offsets(ctx, -1)
    }
    @core.Pat::Tuple(items~, span~) => {
      let _ = span
      // Cache raw pointer for repeated use
      let raw_ptr = emit_untag_ptr_cached(ctx, buf, value_idx)
      // Combined header check: tag_obj AND type==obj_tuple AND length matches
      emit_tag_obj_check(buf, value_idx)
      emit_load_obj_type_raw(buf, raw_ptr)
      emit_i32_const_raw(buf, obj_tuple)
      emit_i32_eq(buf)
      emit_i32_and(buf)
      emit_load_obj_len_raw(buf, raw_ptr)
      emit_i32_const_raw(buf, items.length())
      emit_i32_eq(buf)
      emit_i32_and(buf)
      // Single if-else
      buf.push((4).to_byte()) // if
      buf.push((126).to_byte()) // result i64
      adjust_loop_offsets(ctx, 1)
      compile_tuple_items_cont(
        ctx, buf, raw_ptr, items, 0, cont, match_scrut_idx, arms, start, arm, bindings,
      )
      buf.push((5).to_byte()) // else
      compile_match_chain(ctx, buf, match_scrut_idx, arms, start + 1)
      buf.push((11).to_byte()) // end
      adjust_loop_offsets(ctx, -1)
    }
    @core.Pat::Record(fields~, span~) => {
      let _ = span
      let ordered = sort_record_fields_pat(fields)
      // Cache raw pointer for repeated use
      let raw_ptr = emit_untag_ptr_cached(ctx, buf, value_idx)
      // Combined header check: tag_obj AND type==obj_record AND length matches
      emit_tag_obj_check(buf, value_idx)
      emit_load_obj_type_raw(buf, raw_ptr)
      emit_i32_const_raw(buf, obj_record)
      emit_i32_eq(buf)
      emit_i32_and(buf)
      emit_load_obj_len_raw(buf, raw_ptr)
      emit_i32_const_raw(buf, ordered.length())
      emit_i32_eq(buf)
      emit_i32_and(buf)
      // Single if-else
      buf.push((4).to_byte()) // if
      buf.push((126).to_byte()) // result i64
      adjust_loop_offsets(ctx, 1)
      compile_record_fields_cont(
        ctx, buf, raw_ptr, ordered, 0, cont, match_scrut_idx, arms, start, arm, bindings,
      )
      buf.push((5).to_byte()) // else
      compile_match_chain(ctx, buf, match_scrut_idx, arms, start + 1)
      buf.push((11).to_byte()) // end
      adjust_loop_offsets(ctx, -1)
    }
    @core.Pat::Or(pats~, span~) => {
      let _ = span
      // Expand Or pattern: try each sub-pattern, first match wins
      // Create synthetic arms for each sub-pattern with the same body
      let expanded_arms : Array[@core.MatchArm] = []
      for p in pats {
        expanded_arms.push(@core.MatchArm::{
          pat: p,
          cond: arm.cond,
          expr: arm.expr,
          span: arm.span,
        })
      }
      // Add remaining arms after this one
      for i in (start + 1)..<arms.length() {
        expanded_arms.push(arms[i])
      }
      compile_match_chain(ctx, buf, match_scrut_idx, expanded_arms, 0)
    }
    @core.Pat::Struct(fields~, span~, ..) => {
      let _ = span
      // Struct pattern is same as Record pattern
      let ordered = sort_record_fields_pat(fields)
      let raw_ptr = alloc_temp_local(ctx)
      // Untag pointer and cache
      emit_local_get(buf, value_idx)
      emit_i64_const_raw(buf, (-4).to_int64())
      emit_i64_and(buf)
      emit_i32_wrap_i64(buf)
      emit_local_set(buf, raw_ptr)
      // Check object type
      emit_local_get(buf, value_idx)
      emit_i64_const_raw(buf, tag_mask.to_int64())
      emit_i64_and(buf)
      emit_i64_const_raw(buf, tag_obj.to_int64())
      emit_i64_eq(buf)
      // Single if-else
      buf.push((4).to_byte()) // if
      buf.push((126).to_byte()) // result i64
      adjust_loop_offsets(ctx, 1)
      compile_record_fields_cont(
        ctx, buf, raw_ptr, ordered, 0, cont, match_scrut_idx, arms, start, arm, bindings,
      )
      buf.push((5).to_byte()) // else
      compile_match_chain(ctx, buf, match_scrut_idx, arms, start + 1)
      buf.push((11).to_byte()) // end
      adjust_loop_offsets(ctx, -1)
    }
  }
}

///|
fn compile_ctor_args_cont(
  ctx : CodegenCtx,
  buf : ByteBuf,
  raw_ptr : Int, // cached untagged pointer
  args : Array[@core.Pat],
  index : Int,
  ctor_name : String,
  next : PatCont,
  match_scrut_idx : Int,
  arms : Array[@core.MatchArm],
  start : Int,
  arm : @core.MatchArm,
  bindings : Map[String, Int],
) -> Unit raise WasmGenError {
  if index >= args.length() {
    compile_pat_cont(
      ctx, buf, next, match_scrut_idx, arms, start, arm, bindings,
    )
    return
  }
  let arg_kinds = match ctx.enum_ctor_arg_kinds.get(ctor_name) {
    Some(kinds) => kinds
    None => []
  }
  let field_kind = if index < arg_kinds.length() {
    arg_kinds[index]
  } else {
    ValueKind::I32
  }
  if ctx.use_js_strings && field_kind == ValueKind::ExternRef {
    // ExternRef field: load table slot index, then table.get
    let tmp = alloc_temp_local_with_kind(ctx, ValueKind::ExternRef)
    emit_load_ctor_arg_raw(buf, raw_ptr, index)
    emit_table_get(buf, ctx.extern_table_index)
    emit_local_set(buf, tmp)
    let cont = PatCont::Ctor(raw_ptr, args, index + 1, ctor_name, next)
    compile_pat_match(
      ctx,
      buf,
      tmp,
      args[index],
      match_scrut_idx,
      arms,
      start,
      arm,
      bindings,
      cont,
    )
  } else {
    let tmp = alloc_temp_local_with_kind(ctx, ValueKind::I64)
    emit_load_ctor_arg_raw(buf, raw_ptr, index)
    emit_local_set(buf, tmp)
    let cont = PatCont::Ctor(raw_ptr, args, index + 1, ctor_name, next)
    compile_pat_match(
      ctx,
      buf,
      tmp,
      args[index],
      match_scrut_idx,
      arms,
      start,
      arm,
      bindings,
      cont,
    )
  }
}

///|
fn compile_tuple_items_cont(
  ctx : CodegenCtx,
  buf : ByteBuf,
  raw_ptr : Int, // cached untagged pointer
  items : Array[@core.Pat],
  index : Int,
  next : PatCont,
  match_scrut_idx : Int,
  arms : Array[@core.MatchArm],
  start : Int,
  arm : @core.MatchArm,
  bindings : Map[String, Int],
) -> Unit raise WasmGenError {
  if index >= items.length() {
    compile_pat_cont(
      ctx, buf, next, match_scrut_idx, arms, start, arm, bindings,
    )
    return
  }
  let tmp = alloc_temp_local_with_kind(ctx, ValueKind::I64)
  emit_load_tuple_elem_raw(buf, raw_ptr, index)
  emit_local_set(buf, tmp)
  let cont = PatCont::Tuple(raw_ptr, items, index + 1, next)
  compile_pat_match(
    ctx,
    buf,
    tmp,
    items[index],
    match_scrut_idx,
    arms,
    start,
    arm,
    bindings,
    cont,
  )
}

///|
fn compile_record_fields_cont(
  ctx : CodegenCtx,
  buf : ByteBuf,
  raw_ptr : Int, // cached untagged pointer
  fields : Array[@core.RecordFieldPat],
  index : Int,
  next : PatCont,
  match_scrut_idx : Int,
  arms : Array[@core.MatchArm],
  start : Int,
  arm : @core.MatchArm,
  bindings : Map[String, Int],
) -> Unit raise WasmGenError {
  if index >= fields.length() {
    compile_pat_cont(
      ctx, buf, next, match_scrut_idx, arms, start, arm, bindings,
    )
    return
  }
  let field = fields[index]
  let name_ptr = ctx.strings.intern(field.name)
  emit_load_record_name_raw(buf, raw_ptr, index)
  emit_i32_const_raw(buf, name_ptr)
  emit_i32_eq(buf)
  buf.push((4).to_byte())
  buf.push((126).to_byte())
  let tmp = alloc_temp_local_with_kind(ctx, ValueKind::I64)
  emit_load_record_value_raw(buf, raw_ptr, index)
  emit_local_set(buf, tmp)
  let cont = PatCont::Record(raw_ptr, fields, index + 1, next)
  compile_pat_match(
    ctx,
    buf,
    tmp,
    field.pat,
    match_scrut_idx,
    arms,
    start,
    arm,
    bindings,
    cont,
  )
  buf.push((5).to_byte())
  compile_match_chain(ctx, buf, match_scrut_idx, arms, start + 1)
  buf.push((11).to_byte())
}

///|
fn emit_pat_literal(
  ctx : CodegenCtx,
  buf : ByteBuf,
  pat : @core.Pat,
) -> Unit raise WasmGenError {
  match pat {
    @core.Pat::Wildcard(span~) => {
      let _ = span
      raise WasmGenError::Unsupported("wildcard literal")
    }
    @core.Pat::Bind(name~, span~) => {
      let _ = name
      let _ = span
      raise WasmGenError::Unsupported("bind literal")
    }
    @core.Pat::Ctor(name~, args~, span~) => {
      let _ = name
      let _ = args
      let _ = span
      raise WasmGenError::Unsupported("ctor literal")
    }
    @core.Pat::Tuple(items~, span~) => {
      let _ = items
      let _ = span
      raise WasmGenError::Unsupported("tuple literal")
    }
    @core.Pat::Record(fields~, span~) => {
      let _ = fields
      let _ = span
      raise WasmGenError::Unsupported("record literal")
    }
    @core.Pat::Int(value=n, span~) => {
      let _ = span
      emit_i64_const_tagged(buf, n)
    }
    @core.Pat::Char(value=c, span~) => {
      let _ = span
      emit_i64_const_tagged(buf, c.to_int().to_int64())
    }
    @core.Pat::Float(value~, span~) => {
      let _ = value
      let _ = span
      raise WasmGenError::Unsupported("float literal")
    }
    @core.Pat::Double(value~, span~) => {
      let _ = value
      let _ = span
      raise WasmGenError::Unsupported("double literal")
    }
    @core.Pat::Bool(value=b, span~) => {
      let _ = span
      emit_i64_const_raw(buf, tag_bool_value64(b))
    }
    @core.Pat::String(value=s, span~) => {
      let _ = span
      if ctx.use_js_strings {
        raise WasmGenError::BackendLimit(
          backend="wasm-js-string",
          feature="string pattern matching",
        )
      }
      let offset = ctx.strings.intern(s)
      emit_i64_const_raw(buf, tag_ptr64(offset, tag_obj))
    }
    @core.Pat::Or(pats~, span~) => {
      let _ = pats
      let _ = span
      raise WasmGenError::Unsupported("or pattern literal")
    }
    @core.Pat::Struct(fields~, span~, ..) => {
      let _ = fields
      let _ = span
      raise WasmGenError::Unsupported("struct pattern literal")
    }
  }
}

///|
fn compile_match_chain(
  ctx : CodegenCtx,
  buf : ByteBuf,
  scrut_idx : Int,
  arms : Array[@core.MatchArm],
  start : Int,
) -> Unit raise WasmGenError {
  if start >= arms.length() {
    emit_i64_const_tagged(buf, 0L)
    return
  }
  let arm = arms[start]
  let saved = ctx.locals.copy()
  let saved_kinds = ctx.local_kinds.copy()
  let bindings : Map[String, Int] = {}
  compile_pat_match(
    ctx,
    buf,
    scrut_idx,
    arm.pat,
    scrut_idx,
    arms,
    start,
    arm,
    bindings,
    PatCont::Arm,
  )
  restore_locals(ctx, saved)
  restore_local_kinds(ctx, saved_kinds)
}

///|
fn compile_guarded_arm_with_bindings(
  ctx : CodegenCtx,
  buf : ByteBuf,
  scrut_idx : Int,
  arms : Array[@core.MatchArm],
  index : Int,
  arm : @core.MatchArm,
  bindings : Map[String, Int],
) -> Unit raise WasmGenError {
  let saved = ctx.locals.copy()
  let saved_kinds = ctx.local_kinds.copy()
  let binding_kind = if ctx.use_js_strings {
    ValueKind::I32
  } else {
    ValueKind::I64
  }
  for name, idx in bindings {
    ctx.locals[name] = idx
    ctx.local_kinds[name] = binding_kind
  }
  match arm.cond {
    Some(c) => {
      compile_expr(ctx, buf, c)
      emit_i64_const_raw(buf, 2L)
      emit_i64_shr_u(buf)
      emit_i32_wrap_i64(buf)
      buf.push((4).to_byte())
      buf.push((126).to_byte())
      adjust_loop_offsets(ctx, 1)
      emit_coverage(ctx, buf, WasmCoveragePointKind::BranchMatchArm, arm.span)
      compile_expr(ctx, buf, arm.expr)
      buf.push((5).to_byte())
      restore_locals(ctx, saved)
      restore_local_kinds(ctx, saved_kinds)
      compile_match_chain(ctx, buf, scrut_idx, arms, index + 1)
      buf.push((11).to_byte())
      adjust_loop_offsets(ctx, -1)
      restore_locals(ctx, saved)
      restore_local_kinds(ctx, saved_kinds)
    }
    None => {
      emit_coverage(ctx, buf, WasmCoveragePointKind::BranchMatchArm, arm.span)
      compile_expr(ctx, buf, arm.expr)
      restore_locals(ctx, saved)
      restore_local_kinds(ctx, saved_kinds)
    }
  }
}

///|
fn bind_local(ctx : CodegenCtx, _name : String) -> Int {
  let idx = ctx.local_count
  ctx.local_count += 1
  ctx.local_types.push(ValueKind::I64)
  idx
}

///|
fn alloc_temp_local(ctx : CodegenCtx) -> Int {
  let idx = ctx.local_count
  ctx.local_count += 1
  ctx.local_types.push(ValueKind::I32)
  idx
}

///|
fn alloc_temp_local_with_kind(ctx : CodegenCtx, kind : ValueKind) -> Int {
  let idx = ctx.local_count
  ctx.local_count += 1
  ctx.local_types.push(kind)
  idx
}

///|
fn emit_tag_obj_check(buf : ByteBuf, scrut_idx : Int) -> Unit {
  emit_local_get(buf, scrut_idx)
  emit_i64_const_raw(buf, tag_mask.to_int64())
  emit_i64_and(buf)
  emit_i64_const_raw(buf, tag_obj.to_int64())
  emit_i64_eq(buf)
}

///|
fn emit_untag_ptr(buf : ByteBuf, scrut_idx : Int) -> Unit {
  emit_local_get(buf, scrut_idx)
  emit_i64_const_raw(buf, (-4).to_int64())
  emit_i64_and(buf)
  emit_i32_wrap_i64(buf)
}

///|
/// Compute untagged pointer and store in a new temp local, returning the local index
fn emit_untag_ptr_cached(
  ctx : CodegenCtx,
  buf : ByteBuf,
  scrut_idx : Int,
) -> Int {
  let raw_ptr = alloc_temp_local(ctx)
  emit_untag_ptr(buf, scrut_idx)
  emit_local_set(buf, raw_ptr)
  raw_ptr
}

///|
fn emit_load_obj_type(buf : ByteBuf, scrut_idx : Int) -> Unit {
  emit_untag_ptr(buf, scrut_idx)
  emit_i32_load(buf, 0)
}

///|
/// Load object type using cached raw pointer
fn emit_load_obj_type_raw(buf : ByteBuf, raw_ptr_idx : Int) -> Unit {
  emit_local_get(buf, raw_ptr_idx)
  emit_i32_load(buf, 0)
}

///|
/// Load object length using cached raw pointer
fn emit_load_obj_len_raw(buf : ByteBuf, raw_ptr_idx : Int) -> Unit {
  emit_local_get(buf, raw_ptr_idx)
  emit_i32_load(buf, 4)
}

///|
fn emit_load_tuple_elem(buf : ByteBuf, scrut_idx : Int, index : Int) -> Unit {
  emit_untag_ptr(buf, scrut_idx)
  emit_i32_load(buf, 8 + index * 4)
  emit_i64_extend_i32_s(buf)
}

///|
/// Load tuple element using cached raw pointer
fn emit_load_tuple_elem_raw(
  buf : ByteBuf,
  raw_ptr_idx : Int,
  index : Int,
) -> Unit {
  emit_local_get(buf, raw_ptr_idx)
  emit_i32_load(buf, 8 + index * 4)
  emit_i64_extend_i32_s(buf)
}

///|
/// Load record value (for let destructuring)
fn emit_load_record_value(buf : ByteBuf, scrut_idx : Int, index : Int) -> Unit {
  emit_untag_ptr(buf, scrut_idx)
  emit_i32_load(buf, 8 + index * 8 + 4)
  emit_i64_extend_i32_s(buf)
}

///|
/// Load record name using cached raw pointer
fn emit_load_record_name_raw(
  buf : ByteBuf,
  raw_ptr_idx : Int,
  index : Int,
) -> Unit {
  emit_local_get(buf, raw_ptr_idx)
  emit_i32_load(buf, 8 + index * 8)
}

///|
/// Load record value using cached raw pointer
fn emit_load_record_value_raw(
  buf : ByteBuf,
  raw_ptr_idx : Int,
  index : Int,
) -> Unit {
  emit_local_get(buf, raw_ptr_idx)
  emit_i32_load(buf, 8 + index * 8 + 4)
  emit_i64_extend_i32_s(buf)
}

///|
/// Load ctor tag using cached raw pointer
fn emit_load_ctor_tag_raw(buf : ByteBuf, raw_ptr_idx : Int) -> Unit {
  emit_local_get(buf, raw_ptr_idx)
  emit_i32_load(buf, 4)
}

///|
/// Load ctor arg using cached raw pointer
fn emit_load_ctor_arg_raw(
  buf : ByteBuf,
  raw_ptr_idx : Int,
  index : Int,
) -> Unit {
  emit_local_get(buf, raw_ptr_idx)
  emit_i32_load(buf, 8 + index * 4)
  emit_i64_extend_i32_s(buf)
}
