///|
/// Check if a Fn expression is a simple forwarding call:
///   (x, y) => { g(x, y) }
/// Returns Some(target_name) if the body is a single Call expression
/// that passes all parameters in the same order.
fn is_forwarding_call(
  params : Array[@core.FuncParam],
  body : @core.Module,
) -> String? {
  // Body must be exactly one statement: Expr(Call(...))
  if body.stmts.length() != 1 {
    return None
  }
  match body.stmts[0] {
    @core.Stmt::Expr(expr=@core.Expr::Call(name=target_name, args~, ..), ..) => {
      // Argument count must match parameter count
      if args.length() != params.length() {
        return None
      }
      // Each argument must be Ident matching the corresponding parameter
      for i in 0..<args.length() {
        match args[i].expr {
          @core.Expr::Ident(name=arg_name, ..) =>
            if arg_name != params[i].name {
              return None
            }
          _ => return None
        }
      }
      Some(target_name)
    }
    _ => None
  }
}

///|
/// Unwrap a type-assertion identity block:
///   { let __vibe_local_type_assert_N = fn(v) { v }; __assert(inner_expr) }
/// Returns the inner_expr argument if the pattern matches, otherwise the original expr.
fn unwrap_type_assert_block(expr : @core.Expr) -> @core.Expr {
  match expr {
    @core.Expr::Block(body~, ..) =>
      if body.stmts.length() == 2 {
        match (body.stmts[0], body.stmts[1]) {
          (
            @core.Stmt::Let(
              name=assert_name,
              expr=@core.Expr::Fn(params=fn_params, body=fn_body, ..),
              ..
            ),
            @core.Stmt::Expr(
              expr=@core.Expr::Call(name=call_name, args=call_args, ..),
              ..
            ),
          ) => {
            // Check: call target matches the local type-assert function
            if assert_name != call_name ||
              not(assert_name.has_prefix("__vibe_local_type_assert_")) {
              return expr
            }
            // Check: the function is a single-param identity (body = param)
            if fn_params.length() != 1 {
              return expr
            }
            let param_name = fn_params[0].name
            let is_identity = match fn_body.stmts {
              [@core.Stmt::Expr(expr=@core.Expr::Ident(name=ret_name, ..), ..)] =>
                ret_name == param_name
              _ => false
            }
            if not(is_identity) {
              return expr
            }
            // Check: exactly one argument
            if call_args.length() != 1 {
              return expr
            }
            // Return the inner expression (argument to the type-assert call)
            call_args[0].expr
          }
          _ => expr
        }
      } else {
        expr
      }
    _ => expr
  }
}

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
          let key = span_key_unique(fn_span, fn_params)
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
          // Store the closure env pointer for named top-level functions with
          // captures so other closures can re-tag the same object later.
          match ctx.exported_fn_env_globals.get(name) {
            Some(global_idx) =>
              if global_idx >= 0 {
                emit_local_get(buf, idx)
                emit_i64_const_raw(buf, (-4).to_int64())
                emit_i64_and(buf)
                emit_i32_wrap_i64(buf)
                emit_global_set(buf, global_idx)
              }
            None => ()
          }
          // Back-patch self-reference for recursive closures
          let is_forward_fn = match fn_ret {
            Some(_) => true
            None => false
          }
          if rec || is_forward_fn {
            let captures = match ctx.fn_closure_captures.get(key) {
              Some(list) => list
              None => []
            }
            let mut bp_effective_idx = 0
            for i in 0..<captures.length() {
              let cap_name = captures[i]
              if cap_name == name {
                // Self-reference capture at effective slot
                let env_local = alloc_temp_local(ctx)
                emit_local_get(buf, idx)
                emit_i64_const_raw(buf, (-4).to_int64())
                emit_i64_and(buf)
                emit_i32_wrap_i64(buf) // untag obj pointer to i32
                emit_local_set(buf, env_local)
                emit_local_get(buf, env_local)
                emit_local_get(buf, idx) // closure value (i64)
                emit_i64_store(buf, 16 + bp_effective_idx * 8) // write to capture slot
              } else if is_forward_fn && ctx.forward_fn_keys.contains(cap_name) {
                // Mutual reference: capture of another forward function
                match ctx.locals.get(cap_name) {
                  Some(cap_local) => {
                    // Already compiled — patch this capture slot
                    let env_local = alloc_temp_local(ctx)
                    emit_local_get(buf, idx)
                    emit_i64_const_raw(buf, (-4).to_int64())
                    emit_i64_and(buf)
                    emit_i32_wrap_i64(buf)
                    emit_local_set(buf, env_local)
                    emit_local_get(buf, env_local)
                    emit_local_get(buf, cap_local)
                    emit_i64_store(buf, 16 + bp_effective_idx * 8)
                  }
                  None => () // Not yet compiled — will be patched by reverse pass below
                }
              }
              bp_effective_idx += 1
            }
            // Reverse back-patch: patch previously compiled forward functions
            // that capture THIS function
            if is_forward_fn {
              for other_name, other_key in ctx.forward_fn_keys {
                if other_name == name {
                  continue
                }
                match ctx.locals.get(other_name) {
                  Some(other_local) => {
                    let other_captures = match
                      ctx.fn_closure_captures.get(other_key) {
                      Some(list) => list
                      None => []
                    }
                    let mut rbp_effective_idx = 0
                    for j in 0..<other_captures.length() {
                      if other_captures[j] == name {
                        let env_local = alloc_temp_local(ctx)
                        emit_local_get(buf, other_local)
                        emit_i64_const_raw(buf, (-4).to_int64())
                        emit_i64_and(buf)
                        emit_i32_wrap_i64(buf)
                        emit_local_set(buf, env_local)
                        emit_local_get(buf, env_local)
                        emit_local_get(buf, idx)
                        emit_i64_store(buf, 16 + rbp_effective_idx * 8)
                      }
                      rbp_effective_idx += 1
                    }
                  }
                  None => ()
                }
              }
              // Register this forward function for future back-patches
              ctx.forward_fn_keys[name] = key
            }
          }
        }
        _ => {
          // Function alias optimization: skip local allocation for `let x = fn_name`
          // when x is only used as a call target (not captured, not is_last).
          // compile_expr_ident falls back to fn_indices when locals[name] is absent.
          //
          // Also handles type-annotation wrappers:
          //   let x = { let __assert = fn(v) { v }; __assert(fn_name) }
          // by unwrapping to extract the inner fn_name Ident.
          let effective_expr = unwrap_type_assert_block(expr)
          match effective_expr {
            @core.Expr::Ident(name=source_name, span~) =>
              match ctx.fn_indices.get(source_name) {
                Some(func_idx) => {
                  let _ = span
                  ctx.fn_indices[name] = func_idx
                  match ctx.fn_local_sigs.get(source_name) {
                    Some(sig) => ctx.fn_local_sigs[name] = sig
                    None => ()
                  }
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
                  // Skip only when: not is_last, not captured, and
                  // the target function doesn't need a closure env
                  // (env-needing functions require a local to pass the env pointer)
                  let needs_env = fn_index_needs_env(ctx, func_idx)
                  let mut is_captured = false
                  for _key, captures in ctx.fn_closure_captures {
                    if captures.contains(name) {
                      is_captured = true
                      break
                    }
                  }
                  if not(is_last) && not(is_captured) && not(needs_env) {
                    return
                  }
                }
                None =>
                  // Check linked imports (library functions from --preload)
                  match ctx.linked_fn_imports.get(source_name) {
                    Some(import_idx) => {
                      ctx.linked_fn_imports[name] = import_idx
                      let param_count = match
                        ctx.linked_fn_param_counts.get(source_name) {
                        Some(pc) => pc
                        None => 0
                      }
                      ctx.linked_fn_param_counts[name] = param_count
                      let return_count = match
                        ctx.linked_fn_return_counts.get(source_name) {
                        Some(rc) => rc
                        None => 1
                      }
                      ctx.linked_fn_return_counts[name] = return_count
                      let param_kinds : Array[ValueKind] = []
                      for _ in 0..<param_count {
                        param_kinds.push(ValueKind::I64)
                      }
                      if return_count > 1 {
                        let result_kinds : Array[ValueKind] = []
                        for _ in 0..<return_count {
                          result_kinds.push(ValueKind::I64)
                        }
                        ctx.fn_local_sigs[name] = func_sig_with_env_multi(
                          param_kinds, result_kinds,
                        )
                        ctx.fn_multivalue_results[name] = result_kinds
                      } else {
                        ctx.fn_local_sigs[name] = func_sig_with_env(
                          param_kinds,
                          ValueKind::I64,
                        )
                        ctx.fn_returns[name] = ValueKind::I64
                      }
                      let mut is_captured = false
                      for _key, captures in ctx.fn_closure_captures {
                        if captures.contains(name) {
                          is_captured = true
                          break
                        }
                      }
                      if not(is_last) && not(is_captured) {
                        return
                      }
                      let idx = ctx.local_count
                      ctx.local_count += 1
                      ctx.local_types.push(ValueKind::I64)
                      ctx.locals[name] = idx
                      ctx.local_kinds[name] = ValueKind::I64
                      let slot = ensure_funcref_slot(
                        ctx,
                        linked_funcref_key(import_idx),
                      )
                      emit_i64_const_raw(buf, tag_fn_value64(slot.to_int64()))
                      if is_last {
                        emit_local_tee(buf, idx)
                      } else {
                        emit_local_set(buf, idx)
                      }
                      return
                    }
                    None => ()
                  }
              }
            // Forwarding function alias: let f = (x) { g(x) }
            // → treat as alias of g (skip generating a separate function)
            @core.Expr::Fn(params=fn_params, body=fn_body, ..) =>
              match is_forwarding_call(fn_params, fn_body) {
                Some(target_name) =>
                  match ctx.fn_indices.get(target_name) {
                    Some(func_idx) => {
                      ctx.fn_indices[name] = func_idx
                      match ctx.fn_local_sigs.get(target_name) {
                        Some(sig) => ctx.fn_local_sigs[name] = sig
                        None => ()
                      }
                      match ctx.fn_params.get(target_name) {
                        Some(kinds) => ctx.fn_params[name] = kinds
                        None => ()
                      }
                      match ctx.fn_param_names.get(target_name) {
                        Some(names) => ctx.fn_param_names[name] = names
                        None => ()
                      }
                      match ctx.fn_returns.get(target_name) {
                        Some(ret_kind) => ctx.fn_returns[name] = ret_kind
                        None => ()
                      }
                      match ctx.fn_return_sigs.get(target_name) {
                        Some(sig) => ctx.fn_return_sigs[name] = sig
                        None => ()
                      }
                      let needs_env = fn_index_needs_env(ctx, func_idx)
                      let mut is_captured = false
                      for _key, captures in ctx.fn_closure_captures {
                        if captures.contains(name) {
                          is_captured = true
                          break
                        }
                      }
                      if not(is_last) && not(is_captured) && not(needs_env) {
                        return
                      }
                    }
                    None => ()
                  }
                None => ()
              }
            _ => ()
          }
          // Constant inlining: for non-recursive `let x = <int-literal>` or
          // `let x = <bool-literal>`, register in const_i64_values (pre-tagged)
          // and skip local allocation. References to x will emit i64.const
          // directly instead of local.get.
          // When captured by a closure, still register (for inline in closure body)
          // but don't skip local allocation (closure construction needs the local).
          if not(rec) {
            let const_tagged : Int64? = match effective_expr {
              @core.Expr::Int(value=int_val, ..) =>
                Some(tag_int_value64(int_val))
              @core.Expr::Bool(value=bool_val, ..) =>
                Some(tag_bool_value64(bool_val))
              _ => None
            }
            match const_tagged {
              Some(tagged) => {
                ctx.const_i64_values[name] = tagged
                let mut is_captured = false
                for _key, captures in ctx.fn_closure_captures {
                  if captures.contains(name) {
                    is_captured = true
                    break
                  }
                }
                if not(is_captured) {
                  if is_last {
                    emit_i64_const_raw(buf, tagged)
                  }
                  return
                }
              }
              None => ()
            }
          }
          // Use effective_expr (type-assert unwrapped) for kind inference,
          // sig propagation, and code generation so that identity wrappers
          // like { let __assert = fn(v){v}; __assert(inner) } compile as
          // just `inner`, avoiding the identity stub call overhead.
          let kind = infer_expr_kind(ctx, effective_expr)
          let idx = ctx.local_count
          ctx.local_count += 1
          ctx.local_types.push(kind)
          ctx.locals[name] = idx
          ctx.local_kinds[name] = kind
          // If the expression is a Call that returns a function, register in fn_local_sigs
          match effective_expr {
            @core.Expr::Ident(name=source_name, span~) => {
              let _ = span
              match ctx.fn_local_sigs.get(source_name) {
                Some(sig) => ctx.fn_local_sigs[name] = sig
                None => ()
              }
              // fn_indices metadata already copied in optimization check above
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
          compile_expr(ctx, buf, effective_expr)
          // After compiling Block expressions, propagate fn_return_sigs
          // from inner Call to fn_local_sigs so the bound name is correctly
          // typed when called. (Only needed when effective_expr is still a Block.)
          match effective_expr {
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
    @core.Stmt::EnumDef(name=enum_name, params~, ctors~, span~) => {
      let _ = params
      let _ = span
      for i in 0..<ctors.length() {
        let ctor = ctors[i]
        if not(ctx.enum_ctor_tags.contains(ctor.name)) {
          ctx.enum_ctor_tags[ctor.name] = ctx.next_ctor_tag
          ctx.next_ctor_tag += 1
        }
        ctx.enum_ctor_arities[ctor.name] = ctor.args.length()
        if not(ctx.enum_ctor_arg_kinds.contains(ctor.name)) {
          let arg_kinds : Array[ValueKind] = []
          for arg in ctor.args {
            arg_kinds.push(value_kind_from_type(ctx, arg))
          }
          ctx.enum_ctor_arg_kinds[ctor.name] = arg_kinds
        }
        // Also register qualified form: EnumName::CtorName
        let qualified_ctor = enum_name + "::" + ctor.name
        if not(ctx.enum_ctor_tags.contains(qualified_ctor)) {
          ctx.enum_ctor_tags[qualified_ctor] = ctx.enum_ctor_tags[ctor.name]
          ctx.enum_ctor_arities[qualified_ctor] = ctor.args.length()
          if ctx.enum_ctor_arg_kinds.contains(ctor.name) {
            ctx.enum_ctor_arg_kinds[qualified_ctor] = ctx.enum_ctor_arg_kinds[ctor.name]
          }
        }
        // Register singleton for 0-arg enum constructors
        if ctor.args.length() == 0 &&
          not(ctx.enum_ctor_singletons.contains(ctor.name)) {
          let offset = ctx.strings.intern_enum_singleton(
            ctor.name,
            ctx.enum_ctor_tags[ctor.name],
          )
          ctx.enum_ctor_singletons[ctor.name] = tag_ptr64(offset, tag_obj)
          ctx.enum_ctor_singletons[qualified_ctor] = tag_ptr64(offset, tag_obj)
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
      // Tail position propagates only for the last expression in a block
      // compile_expr will save/reset is_tail_position itself
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
    @core.Stmt::ExternLet(name~, ty~, span~) => {
      let _ = name
      let _ = ty
      let _ = span
      // extern declarations are host-linked symbols; no runtime statement.
      if is_last {
        emit_i64_const_tagged(buf, 0L)
      }
    }
    @core.Stmt::ExportLet(rec~, name~, expr~, span~) =>
      // ExportLet is compiled like Let - the export is handled at module level
      compile_stmt(
        ctx,
        buf,
        @core.Stmt::Let(rec~, name~, expr~, span~),
        is_last,
      )
    @core.Stmt::InternalExportLet(rec~, name~, expr~, span~) =>
      // InternalExportLet is compiled like Let - visibility is handled in runtime import resolution.
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
    @core.Stmt::InternalExportEnumDef(name~, params~, ctors~, span~) =>
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
    @core.Stmt::InternalExportTypeAlias(..) =>
      if is_last {
        emit_i64_const_tagged(buf, 0L)
      }
    @core.Stmt::Export(..)
    | @core.Stmt::ReExport(..)
    | @core.Stmt::TraitDef(..)
    | @core.Stmt::InternalTraitDef(..)
    | @core.Stmt::TraitImpl(..)
    | @core.Stmt::StructDef(..)
    | @core.Stmt::ExportStructDef(..)
    | @core.Stmt::InternalExportStructDef(..)
    | @core.Stmt::EffectDef(..)
    | @core.Stmt::ExportEffectDef(..)
    | @core.Stmt::AliasDecl(..) =>
      // export { ... } statements, struct definitions, and alias declarations
      // are handled during bundling/typechecking. At codegen time, they are no-ops
      if is_last {
        emit_i64_const_tagged(buf, 0L)
      }
    @core.Stmt::LetMut(name~, expr~, span~) => {
      let _ = span
      if ctx.mut_captured_vars.contains(name) {
        // Ref cell: allocate 8 bytes on heap, store pointer as i32 local
        require_heap(ctx)
        let ptr_local = ctx.local_count
        ctx.local_count += 1
        ctx.local_types.push(ValueKind::I32)
        ctx.locals[name] = ptr_local
        ctx.local_kinds[name] = ValueKind::I32
        emit_heap_alloc_unchecked(ctx, buf, 8, ptr_local)
        // Store initial value into ref cell
        emit_local_get(buf, ptr_local) // i32 addr
        compile_expr(ctx, buf, expr) // i64 value
        emit_i64_store(buf, 0) // mem[addr] = value
        if is_last {
          // Leave the value on the stack
          emit_local_get(buf, ptr_local)
          emit_i64_load(buf, 0)
        }
      } else {
        // Standard path: regular local
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
    }
    @core.Stmt::Assign(name~, expr~, span~) => {
      let _ = span
      // Assign updates an existing mutable variable
      match ctx.locals.get(name) {
        Some(idx) =>
          if ctx.mut_captured_vars.contains(name) {
            // Ref cell: write through pointer
            // Put addr on stack first, then value — avoids temp local
            emit_local_get(buf, idx) // i32 addr
            compile_expr(ctx, buf, expr) // i64 value
            emit_i64_store(buf, 0) // mem[addr] = value
            if is_last {
              emit_local_get(buf, idx) // re-read
              emit_i64_load(buf, 0)
            }
          } else {
            // RC: drop old value before overwriting
            if ctx.enable_rc {
              emit_rc_drop_i64(ctx, buf, idx)
            }
            compile_expr(ctx, buf, expr)
            if is_last {
              emit_local_tee(buf, idx)
            } else {
              emit_local_set(buf, idx)
            }
          }
        None => raise UnknownName("" + name)
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
        emit_load_record_value(buf, value_local, i)
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
  emit_rc_stmt_actions? : Bool = false,
  rc_prefix? : String = "",
) -> Unit raise WasmGenError {
  let saved = ctx.locals.copy()
  let saved_kinds = ctx.local_kinds.copy()
  let saved_prefix = ctx.rc_action_prefix
  if emit_rc_stmt_actions && rc_prefix.length() > 0 {
    ctx.rc_action_prefix = rc_prefix
  }
  let len = body.stmts.length()
  if len == 0 {
    emit_i64_const_tagged(buf, 0L)
  } else {
    for i in 0..<len {
      let is_last = i == len - 1
      if emit_rc_stmt_actions {
        emit_rc_actions(ctx, buf, ctx.rc_pre_actions, i)
      }
      compile_stmt(ctx, buf, body.stmts[i], is_last)
      if emit_rc_stmt_actions {
        emit_rc_actions(ctx, buf, ctx.rc_post_actions, i)
      }
    }
  }
  ctx.rc_action_prefix = saved_prefix
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
fn compile_handle_catch_body_multivalue(
  ctx : CodegenCtx,
  buf : ByteBuf,
  catch_arm : @core.MatchArm,
  catch_body_mod : @core.Module,
  error_kind : ValueKind,
  error_local : Int,
  kinds : Array[ValueKind],
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
      compile_block_multivalue(ctx, buf, catch_body_mod, kinds)
      match prev_local {
        Some(idx) => ctx.locals[bind_name] = idx
        None => ctx.locals.remove(bind_name)
      }
      match prev_kind {
        Some(kind) => ctx.local_kinds[bind_name] = kind
        None => ctx.local_kinds.remove(bind_name)
      }
    }
    None => compile_block_multivalue(ctx, buf, catch_body_mod, kinds)
  }
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
      let emit_len = if items.length() < kinds.length() {
        items.length()
      } else {
        kinds.length()
      }
      for i in 0..<emit_len {
        compile_expr(ctx, buf, items[i])
      }
      // Pad missing tuple fields when the expected multivalue arity is larger.
      for i in emit_len..<kinds.length() {
        match kinds[i] {
          ValueKind::I32 => emit_i32_const_raw(buf, 0)
          _ => emit_i64_const_raw(buf, 0L)
        }
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
    @core.Expr::Handle(body~, arms~, span~) => {
      // Phase 1: compile Handle like Try multivalue, using first arm's expr as catch_body
      let catch_arm = arms[0]
      let catch_body_mod = handle_catch_body_module(catch_arm.expr, span)
      let sig = FuncSig::{ params: [], results: kinds }
      let type_idx = ensure_sig_index(ctx, sig)
      let error_kind = handle_error_kind(ctx)
      emit_handle_try_header_with_type_idx(ctx, buf, type_idx, error_kind)
      compile_block_multivalue(ctx, buf, body, kinds)
      emit_handle_try_success_to_catch(buf)
      adjust_loop_offsets(ctx, -1)
      let error_local = alloc_temp_local_with_kind(ctx, error_kind)
      emit_local_set(buf, error_local)
      compile_handle_catch_body_multivalue(
        ctx, buf, catch_arm, catch_body_mod, error_kind, error_local, kinds,
      )
      buf.push((11).to_byte())
      adjust_loop_offsets(ctx, -2)
    }
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
) -> Unit {
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
