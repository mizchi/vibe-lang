///|
pub fn type_check(ast : @core.Module) -> TypeEnv raise TypeError {
  type_check_with_aliases(ast, {})
}

///|
pub fn type_check_with_profile(
  ast : @core.Module,
) -> (TypeEnv, ScopedRefProfile) raise TypeError {
  type_check_with_aliases_profile(ast, {})
}

///|
pub fn type_check_with_aliases_profile(
  ast : @core.Module,
  aliases : Map[String, @core.Ref],
) -> (TypeEnv, ScopedRefProfile) raise TypeError {
  let env = get_cached_prelude_env_for_module()
  env.set_scoped_ref_profile_enabled(true)
  env.set_scoped_ref_checks_enabled(module_may_use_scoped_ref(ast))
  let exported_names = collect_exported_names(ast.stmts)
  let typed = type_check_stmts(
    env,
    ast.stmts,
    aliases,
    effect_scope_all(),
    false,
    exported_names,
  ) catch {
    e => raise e.resolve_vars(env)
  }
  (typed, typed.get_scoped_ref_profile())
}

///|
/// @core.Type check with import aliases (qualified names treated as external).
pub fn type_check_with_aliases(
  ast : @core.Module,
  aliases : Map[String, @core.Ref],
) -> TypeEnv raise TypeError {
  let env = get_cached_prelude_env_for_module()
  env.set_scoped_ref_checks_enabled(module_may_use_scoped_ref(ast))
  let exported_names = collect_exported_names(ast.stmts)
  type_check_stmts(
    env,
    ast.stmts,
    aliases,
    effect_scope_all(),
    false,
    exported_names,
  ) catch {
    e => raise e.resolve_vars(env)
  }
}

///|
fn ensure_prelude_seed(session : TypecheckSession) -> TypeEnv raise TypeError {
  match session.cached_prelude_env.val {
    Some(seed) => seed
    None => {
      let seed = session.new_env()
      ensure_prelude_option(seed)
      ensure_prelude_functions(seed, {})
      session.cached_prelude_env.val = Some(seed)
      seed
    }
  }
}

///|
pub fn get_cached_prelude_env_for_module() -> TypeEnv raise TypeError {
  get_cached_prelude_env_for_module_with_session(default_typecheck_session)
}

///|
fn get_cached_prelude_env_for_module_with_session(
  session : TypecheckSession,
) -> TypeEnv raise TypeError {
  match session.cached_builtins_env.val {
    Some(seed) => seed.clone_for_module()
    None => {
      let prelude_seed = ensure_prelude_seed(session)
      let builtins_seed = prelude_seed.clone_for_module()
      ensure_builtin_modules(builtins_seed, {})
      session.cached_builtins_env.val = Some(builtins_seed)
      builtins_seed.clone_for_module()
    }
  }
}

///|
pub fn get_prelude_only_env_for_module() -> TypeEnv raise TypeError {
  let seed = ensure_prelude_seed(default_typecheck_session)
  seed.clone_for_module()
}

///|
pub fn get_default_typecheck_session() -> TypecheckSession {
  default_typecheck_session
}

///|
pub fn type_check_with_env(
  env : TypeEnv,
  ast : @core.Module,
  aliases : Map[String, @core.Ref],
) -> TypeEnv raise TypeError {
  ensure_prelude_option(env)
  ensure_prelude_functions(env, aliases)
  env.set_scoped_ref_checks_enabled(module_may_use_scoped_ref(ast))
  let exported_names = collect_exported_names(ast.stmts)
  type_check_stmts(
    env,
    ast.stmts,
    aliases,
    effect_scope_all(),
    false,
    exported_names,
  ) catch {
    e => raise e.resolve_vars(env)
  }
}

///|
fn module_may_use_scoped_ref(ast : @core.Module) -> Bool {
  for stmt in ast.stmts {
    if stmt_may_use_scoped_ref(stmt) {
      return true
    }
  }
  false
}

///|
fn stmt_may_use_scoped_ref(stmt : @core.Stmt) -> Bool {
  match stmt {
    @core.Stmt::Let(expr~, ..)
    | @core.Stmt::Expr(expr~, ..)
    | @core.Stmt::ExportLet(expr~, ..) => expr_may_use_scoped_ref(expr)
    @core.Stmt::LetMut(..)
    | @core.Stmt::Assign(..)
    | @core.Stmt::IndexAssign(..) => true
    @core.Stmt::LetPat(expr~, ..) => expr_may_use_scoped_ref(expr)
    @core.Stmt::LetPatElse(expr~, else_body~, ..) =>
      expr_may_use_scoped_ref(expr) || module_may_use_scoped_ref(else_body)
    @core.Stmt::EnumDef(ctors~, ..) | @core.Stmt::ExportEnumDef(ctors~, ..) => {
      for ctor in ctors {
        for arg_ty in ctor.args {
          if type_may_contain_scoped_ref_hint(arg_ty) {
            return true
          }
        }
      }
      false
    }
    @core.Stmt::TypeAlias(target~, ..)
    | @core.Stmt::ExportTypeAlias(target~, ..) =>
      type_may_contain_scoped_ref_hint(target)
    @core.Stmt::TraitImpl(target~, ..) =>
      type_may_contain_scoped_ref_hint(target)
    @core.Stmt::StructDef(fields~, ..)
    | @core.Stmt::ExportStructDef(fields~, ..) => {
      for field in fields {
        if type_may_contain_scoped_ref_hint(field.ty) {
          return true
        }
      }
      false
    }
    @core.Stmt::Test(body~, ..) | @core.Stmt::Bench(body~, ..) =>
      module_may_use_scoped_ref(body)
    @core.Stmt::TraitDef(..)
    | @core.Stmt::Import(..)
    | @core.Stmt::Export(..)
    | @core.Stmt::ReExport(..) => false
  }
}

///|
fn expr_may_use_scoped_ref(expr : @core.Expr) -> Bool {
  match expr {
    @core.Expr::Int(..)
    | @core.Expr::Float(..)
    | @core.Expr::Double(..)
    | @core.Expr::Bool(..)
    | @core.Expr::Char(..)
    | @core.Expr::String(..)
    | @core.Expr::Ident(..)
    | @core.Expr::Placeholder(..) => false
    @core.Expr::Call(type_args~, args~, ..) => {
      for ty in type_args {
        if type_may_contain_scoped_ref_hint(ty) {
          return true
        }
      }
      for arg in args {
        if expr_may_use_scoped_ref(arg.expr) {
          return true
        }
      }
      false
    }
    @core.Expr::Tuple(items~, ..) | @core.Expr::Array(items~, ..) => {
      for item in items {
        if expr_may_use_scoped_ref(item) {
          return true
        }
      }
      false
    }
    @core.Expr::Continue(args~, ..) => {
      for item in args {
        if expr_may_use_scoped_ref(item) {
          return true
        }
      }
      false
    }
    @core.Expr::TupleIndex(expr~, ..) | @core.Expr::Yield(expr~, ..) =>
      expr_may_use_scoped_ref(expr)
    @core.Expr::Record(fields~, ..) => {
      for field in fields {
        if expr_may_use_scoped_ref(field.expr) {
          return true
        }
      }
      false
    }
    @core.Expr::Map(fields~, ..) => {
      for field in fields {
        if expr_may_use_scoped_ref(field.expr) {
          return true
        }
      }
      false
    }
    @core.Expr::If(cond~, then_body~, else_body~, ..) =>
      expr_may_use_scoped_ref(cond) ||
      module_may_use_scoped_ref(then_body) ||
      module_may_use_scoped_ref(else_body)
    @core.Expr::Block(body~, ..) | @core.Expr::Do(body~, ..) =>
      module_may_use_scoped_ref(body)
    @core.Expr::Match(scrutinee~, arms~, ..) =>
      expr_may_use_scoped_ref(scrutinee) || match_arms_may_use_scoped_ref(arms)
    @core.Expr::Fn(params~, ret~, body~, ..) => {
      for param in params {
        if type_may_contain_scoped_ref_hint(param.ty) {
          return true
        }
      }
      match ret {
        Some(ret_ty) =>
          if type_may_contain_scoped_ref_hint(ret_ty) {
            return true
          }
        None => ()
      }
      module_may_use_scoped_ref(body)
    }
    @core.Expr::While(cond~, body~, ..) =>
      expr_may_use_scoped_ref(cond) || module_may_use_scoped_ref(body)
    @core.Expr::Loop(params~, body~, ..) => {
      for param in params {
        if expr_may_use_scoped_ref(param.init) {
          return true
        }
      }
      module_may_use_scoped_ref(body)
    }
    @core.Expr::Break(value~, ..) =>
      match value {
        Some(v) => expr_may_use_scoped_ref(v)
        None => false
      }
    @core.Expr::Raise(value~, ..) => expr_may_use_scoped_ref(value)
    @core.Expr::Handle(body~, arms~, ..) =>
      module_may_use_scoped_ref(body) || match_arms_may_use_scoped_ref(arms)
    @core.Expr::StructLit(type_args~, fields~, ..) => {
      for ty in type_args {
        if type_may_contain_scoped_ref_hint(ty) {
          return true
        }
      }
      for field in fields {
        if expr_may_use_scoped_ref(field.expr) {
          return true
        }
      }
      false
    }
  }
}

///|
fn match_arms_may_use_scoped_ref(arms : Array[@core.MatchArm]) -> Bool {
  for arm in arms {
    match arm.cond {
      Some(cond) => if expr_may_use_scoped_ref(cond) { return true }
      None => ()
    }
    if expr_may_use_scoped_ref(arm.expr) {
      return true
    }
  }
  false
}

///|
fn type_check_stmts(
  env : TypeEnv,
  stmts : Array[@core.Stmt],
  aliases : Map[String, @core.Ref],
  effects : EffectScope,
  allow_effect : Bool,
  exported_names : Map[String, Bool],
) -> TypeEnv raise TypeError {
  let declared_in_scope : Map[String, Bool] = {}
  let has_exports = not(exported_names.is_empty())
  let ensure_fresh_value_binding = fn(
    name : String,
    span : @core.Span,
  ) -> Unit raise TypeError {
    if name == "_" {
      return
    }
    if declared_in_scope.contains(name) {
      raise TypeError::DuplicateDecl(name~, span~)
    }
  }
  let record_value_binding = fn(name : String) {
    if name == "_" {
      return
    }
    declared_in_scope[name] = true
  }
  // ── Pre-scan: register provisional types for forward-declarable functions ──
  // Save type var counter before pre-scan to restore afterwards.
  // Pre-scan type vars are only used inside generalized schemes (replaced on
  // instantiation), so reusing the same IDs in the main loop is safe.
  let forward_fns : Map[String, Bool] = {}
  let saved_next_type_var = env.session_state.type_var_counter
  let saved_env_next_var = env.next_var
  for stmt in stmts {
    let fn_info : (String, @core.Expr)? = match stmt {
      @core.Stmt::Let(rec~, name~, expr~, ..) =>
        if not(rec) && name != "_" {
          Some((name, expr))
        } else {
          None
        }
      @core.Stmt::ExportLet(rec~, name~, expr~, ..) =>
        if not(rec) && name != "_" {
          Some((name, expr))
        } else {
          None
        }
      _ => None
    }
    match fn_info {
      Some((name, expr)) =>
        // Only pre-register if name is not already in env (avoids
        // overwriting schemes from previous passes, e.g. version tracking)
        if env.get_scheme(name) is None {
          match expr {
            @core.Expr::Fn(
              type_params~,
              type_bounds~,
              params~,
              ret=Some(r),
              effects=fn_effects,
              span=fn_span,
              ..
            ) => {
              // Try to build provisional type; skip on failure (e.g. trait not
              // yet defined during prelude loading).
              let result : Result[TypeScheme, TypeError] = try? build_forward_fn_scheme(
                env, type_params, type_bounds, params, r, fn_effects, fn_span,
              )
              match result {
                Ok(scheme) => {
                  env.set_scheme(name, scheme)
                  env.set_purity_tier(name, TopLevelPurityTier::Pure)
                  forward_fns[name] = true
                }
                Err(_) => ()
              }
            }
            _ => ()
          }
        }
      None => ()
    }
  }
  // Clean up pre-scan artifacts from env (trait_bounds, num_vars) for
  // IDs that will be re-allocated by the main loop.
  let pre_scan_end = env.session_state.type_var_counter
  for id = saved_next_type_var; id < pre_scan_end; id = id + 1 {
    env.var_trait_bounds.remove(id)
    env.num_vars.remove(id)
  }
  // Restore counters so the main loop starts from the same IDs as before.
  env.session_state.type_var_counter = saved_next_type_var
  env.next_var = saved_env_next_var
  for stmt in stmts {
    match stmt {
      @core.Stmt::Let(rec~, name~, expr~, span~) => {
        ensure_fresh_value_binding(name, span)
        let effective_rec = rec || forward_fns.contains(name)
        let scheme = type_let_expr(
          env, effective_rec, name, expr, span, aliases, effects, allow_effect,
        )
        ensure_type_member_decl_receiver_contract(env, name, scheme.ty, span)
        ensure_no_toplevel_scoped_ref_escape(env, scheme.ty, span)
        if name != "_" {
          if has_exports && exported_names.contains(name) {
            if forward_fns.contains(name) {
              env.bindings.remove(name)
            }
            env.set_exported_scheme(name, scheme)
          } else {
            env.set_scheme(name, scheme)
          }
          let info = purity_for_let(env, effective_rec, name, expr)
          env.set_purity_tier(name, info.value_tier)
          record_value_binding(name)
        }
      }
      @core.Stmt::EnumDef(name~, params~, ctors~, span~) =>
        register_enum_def(env, name, params, ctors, span)
      @core.Stmt::TypeAlias(name~, params~, target~, span~) =>
        register_type_alias(env, name, params, target, span)
      @core.Stmt::TraitDef(name~, supertraits~, open_impl~, exported~, span~) =>
        register_trait_def(env, name, supertraits, open_impl, exported, span)
      @core.Stmt::TraitImpl(
        type_params~,
        type_bounds~,
        trait_name~,
        target~,
        span~
      ) =>
        register_trait_impl(
          env, type_params, type_bounds, trait_name, target, span,
        )
      @core.Stmt::Expr(expr~, span~) => {
        let _ = span
        let _ = type_expr_eff(env, expr, aliases, effects, allow_effect)
      }
      @core.Stmt::Import(..) => ()
      @core.Stmt::ExportLet(rec~, name~, expr~, span~) => {
        ensure_fresh_value_binding(name, span)
        let effective_rec = rec || forward_fns.contains(name)
        let scheme = type_let_expr(
          env, effective_rec, name, expr, span, aliases, effects, allow_effect,
        )
        ensure_type_member_decl_receiver_contract(env, name, scheme.ty, span)
        ensure_no_toplevel_scoped_ref_escape(env, scheme.ty, span)
        if name != "_" {
          // If this is a forward function, remove the provisional pre-scan
          // binding so set_exported_scheme sees it as a fresh registration
          // (avoids spurious version bump from pre-scan provisional type).
          if forward_fns.contains(name) {
            env.bindings.remove(name)
          }
          env.set_exported_scheme(name, scheme)
          let info = purity_for_let(env, effective_rec, name, expr)
          env.set_purity_tier(name, info.value_tier)
          record_value_binding(name)
        }
      }
      @core.Stmt::ExportEnumDef(name~, params~, ctors~, span~) =>
        register_enum_def(env, name, params, ctors, span)
      @core.Stmt::ExportTypeAlias(name~, params~, target~, span~) =>
        register_type_alias(env, name, params, target, span)
      @core.Stmt::Export(..) | @core.Stmt::ReExport(..) => ()
      @core.Stmt::Test(name~, body~, span~) => {
        let _ = span
        let _ = name
        let _ = type_check_stmts(
          clone_env(env),
          body.stmts,
          aliases,
          effects,
          true,
          {},
        )
      }
      @core.Stmt::Bench(name~, body~, span~) => {
        let _ = span
        let _ = name
        let _ = type_check_stmts(
          clone_env(env),
          body.stmts,
          aliases,
          effects,
          true,
          {},
        )
      }
      @core.Stmt::LetMut(name~, expr~, span~) => {
        ensure_fresh_value_binding(name, span)
        let ty = type_expr_eff(env, expr, aliases, effects, allow_effect)
        ensure_no_toplevel_scoped_ref_escape(env, ty, span)
        if name != "_" {
          let scheme = TypeScheme::{
            vars: [],
            num_vars: [],
            effect_vars: [],
            trait_bounds: {},
            ty,
          }
          if has_exports && exported_names.contains(name) {
            env.set_exported_scheme(name, scheme)
          } else {
            env.set_scheme(name, scheme)
          }
          env.set_purity_tier(name, TopLevelPurityTier::StateLocal)
          record_value_binding(name)
        }
      }
      @core.Stmt::LetPat(pat~, expr~, span~) => {
        let _ = span
        let ty = type_expr_eff(env, expr, aliases, effects, allow_effect)
        ensure_no_toplevel_scoped_ref_escape(env, ty, span)
        let bindings = collect_pattern_bindings(env, pat, ty)
        for name, bound_ty in bindings {
          ensure_fresh_value_binding(name, span)
          ensure_no_toplevel_scoped_ref_escape(env, bound_ty, span)
          let scheme = TypeScheme::{
            vars: [],
            num_vars: [],
            effect_vars: [],
            trait_bounds: {},
            ty: bound_ty,
          }
          if has_exports && exported_names.contains(name) {
            env.set_exported_scheme(name, scheme)
          } else {
            env.set_scheme(name, scheme)
          }
          env.set_purity_tier(name, TopLevelPurityTier::Pure)
          record_value_binding(name)
        }
      }
      @core.Stmt::LetPatElse(pat~, expr~, else_body~, span~) => {
        let _ = span
        let ty = type_expr_eff(env, expr, aliases, effects, allow_effect)
        ensure_no_toplevel_scoped_ref_escape(env, ty, span)
        let bindings = collect_pattern_bindings(env, pat, ty)
        for name, bound_ty in bindings {
          ensure_fresh_value_binding(name, span)
          ensure_no_toplevel_scoped_ref_escape(env, bound_ty, span)
          let scheme = TypeScheme::{
            vars: [],
            num_vars: [],
            effect_vars: [],
            trait_bounds: {},
            ty: bound_ty,
          }
          if has_exports && exported_names.contains(name) {
            env.set_exported_scheme(name, scheme)
          } else {
            env.set_scheme(name, scheme)
          }
          env.set_purity(name, false)
          record_value_binding(name)
        }
        type_block(env, else_body, aliases, effects, allow_effect) |> ignore
      }
      @core.Stmt::Assign(name~, expr~, span~) => {
        let ty = type_expr_eff(env, expr, aliases, effects, allow_effect)
        match env.get_scheme(name) {
          Some(scheme) => {
            let expected = instantiate_scheme(env, scheme)
            if not(type_equal(env, expected, ty)) {
              raise TypeError::Mismatch(
                expected~,
                actual=ty,
                span~,
                context=Some("assignment"),
              )
            }
          }
          None =>
            raise TypeError::UnknownName(
              name~,
              span~,
              suggestion=find_name_suggestion(env, aliases, name),
            )
        }
      }
      @core.Stmt::IndexAssign(target~, index~, value~, span~) => {
        // Type check target[index] = value as __set_index(target, index, value)
        let _ = type_expr_eff(env, target, aliases, effects, allow_effect)
        let _ = type_expr_eff(env, index, aliases, effects, allow_effect)
        let _ = type_expr_eff(env, value, aliases, effects, allow_effect)
        let _ = span
        // For now, just check that all sub-expressions type check
        // More precise checking would verify target is array/map compatible
      }
      @core.Stmt::StructDef(name~, params~, fields~, span~) =>
        register_struct_def(env, name, params, fields, span)
      @core.Stmt::ExportStructDef(name~, params~, fields~, span~) =>
        register_struct_def(env, name, params, fields, span)
    }
  }
  env
}

///|
fn collect_exported_names(stmts : Array[@core.Stmt]) -> Map[String, Bool] {
  let exports : Map[String, Bool] = {}
  let mut has_late_exports = false
  for stmt in stmts {
    match stmt {
      @core.Stmt::ExportLet(rec~, name~, ..) => {
        let _ = rec
        exports[name] = true
      }
      @core.Stmt::ExportEnumDef(name~, ctors~, ..) => {
        exports[name] = true
        for ctor in ctors {
          exports[ctor.name] = true
        }
      }
      @core.Stmt::ExportTypeAlias(name~, ..) => exports[name] = true
      @core.Stmt::ExportStructDef(name~, ..) => exports[name] = true
      @core.Stmt::Export(..) | @core.Stmt::ReExport(..) =>
        has_late_exports = true
      _ => ()
    }
  }
  if not(has_late_exports) {
    return exports
  }
  let defined : Map[String, Bool] = {}
  for stmt in stmts {
    match stmt {
      @core.Stmt::Let(rec~, name~, ..) => {
        let _ = rec
        defined[name] = true
      }
      @core.Stmt::LetMut(name~, ..) => defined[name] = true
      @core.Stmt::EnumDef(name~, ..) => defined[name] = true
      @core.Stmt::TypeAlias(name~, ..) => defined[name] = true
      @core.Stmt::TraitDef(name~, ..) => defined[name] = true
      @core.Stmt::StructDef(name~, ..) => defined[name] = true
      @core.Stmt::ExportLet(rec~, name~, ..) => {
        let _ = rec
        defined[name] = true
      }
      @core.Stmt::ExportEnumDef(name~, ctors~, ..) => {
        defined[name] = true
        for ctor in ctors {
          defined[ctor.name] = true
        }
      }
      @core.Stmt::ExportTypeAlias(name~, ..) => defined[name] = true
      @core.Stmt::ExportStructDef(name~, ..) => defined[name] = true
      _ => ()
    }
  }
  for stmt in stmts {
    match stmt {
      @core.Stmt::Export(names~, ..) =>
        for name in names {
          if defined.contains(name) {
            exports[name] = true
          }
        }
      @core.Stmt::ReExport(names~, ..) =>
        for name in names {
          exports[name] = true
        }
      _ => ()
    }
  }
  exports
}

///|
fn record_expr_type(env : TypeEnv, span : @core.Span, ty : @core.Type) -> Unit {
  let resolved = resolve_type(env, ty)
  let normalized = normalize_type(env, resolved) catch { _ => resolved }
  env.expr_types[span_key(span)] = normalized
}

///|
fn trait_is_subtrait_inner(
  env : TypeEnv,
  sub_trait : String,
  super_trait : String,
  visiting : Map[String, Bool],
) -> Bool {
  if sub_trait == super_trait {
    return true
  }
  if visiting.contains(sub_trait) {
    return false
  }
  match env.get_trait_info(sub_trait) {
    Some(info) => {
      let next_visiting = visiting.copy()
      next_visiting[sub_trait] = true
      for parent in info.supertraits {
        if parent == super_trait {
          return true
        }
        if trait_is_subtrait_inner(env, parent, super_trait, next_visiting) {
          return true
        }
      }
      false
    }
    None => false
  }
}

///|
fn trait_is_subtrait(
  env : TypeEnv,
  sub_trait : String,
  super_trait : String,
) -> Bool {
  trait_is_subtrait_inner(env, sub_trait, super_trait, {})
}

///|
fn trait_bound_satisfied(
  env : TypeEnv,
  available : Array[String],
  required : String,
) -> Bool {
  for bound in available {
    if trait_is_subtrait(env, bound, required) {
      return true
    }
  }
  false
}

///|
fn ensure_traits_defined(
  env : TypeEnv,
  bounds : Array[String],
  span : @core.Span,
) -> Unit raise TypeError {
  let deduped = dedup_trait_bounds(bounds)
  for bound in deduped {
    if not(env.has_trait(bound)) {
      raise TypeError::BadTypeDef(message="unknown trait: " + bound, span~)
    }
  }
}

///|
fn register_trait_def(
  env : TypeEnv,
  name : String,
  supertraits : Array[String],
  open_impl : Bool,
  exported : Bool,
  span : @core.Span,
) -> Unit raise TypeError {
  if open_impl && not(exported) {
    raise TypeError::BadTypeDef(
      message="`open trait` is only allowed with export",
      span~,
    )
  }
  if env.has_trait(name) {
    if env.session_state.lenient_mode {
      return
    }
    raise TypeError::BadTypeDef(message="duplicate trait: " + name, span~)
  }
  let normalized_supertraits = dedup_trait_bounds(supertraits)
  for supertrait in normalized_supertraits {
    if supertrait == name {
      raise TypeError::BadTypeDef(
        message="trait cannot inherit itself: " + name,
        span~,
      )
    }
  }
  ensure_traits_defined(env, normalized_supertraits, span)
  env.set_trait_info(name, TraitDefInfo::{
    supertraits: normalized_supertraits,
    open_impl,
    is_local: true,
  })
}

///|
fn type_matches_impl_target(
  env : TypeEnv,
  pattern : @core.Type,
  actual : @core.Type,
  mapping : Map[String, @core.Type],
) -> Bool {
  let p = resolve_type(env, pattern)
  let a = resolve_type(env, actual)
  match p {
    @core.Type::Param(name) =>
      match mapping.get(name) {
        Some(bound_ty) => type_equal(env, bound_ty, a) catch { _ => false }
        None => {
          mapping[name] = a
          true
        }
      }
    @core.Type::Named(name=pn, args=pa) =>
      match a {
        @core.Type::Named(name=an, args=aa) =>
          if pn != an || pa.length() != aa.length() {
            false
          } else {
            let mut ok = true
            for i in 0..<pa.length() {
              if not(type_matches_impl_target(env, pa[i], aa[i], mapping)) {
                ok = false
                break
              }
            }
            ok
          }
        _ =>
          match env.namespace_root(a) {
            Some(root_name) =>
              if root_name != pn {
                false
              } else {
                let normalized_pattern : Result[@core.Type, TypeError] = try? normalize_type(
                  env, p,
                )
                match normalized_pattern {
                  Ok(expanded_pattern) =>
                    if expanded_pattern == p {
                      false
                    } else {
                      type_matches_impl_target(
                        env, expanded_pattern, a, mapping,
                      )
                    }
                  Err(_) => false
                }
              }
            None => false
          }
      }
    @core.Type::Tuple(ps) =>
      match a {
        @core.Type::Tuple(actual_items) =>
          if ps.length() != actual_items.length() {
            false
          } else {
            let mut ok = true
            for i in 0..<ps.length() {
              if not(
                  type_matches_impl_target(env, ps[i], actual_items[i], mapping),
                ) {
                ok = false
                break
              }
            }
            ok
          }
        _ => false
      }
    @core.Type::Record(pf) =>
      match a {
        @core.Type::Record(af) =>
          if pf.length() != af.length() {
            false
          } else {
            let mut ok = true
            for name, p_ty in pf {
              match af.get(name) {
                Some(a_ty) =>
                  if not(type_matches_impl_target(env, p_ty, a_ty, mapping)) {
                    ok = false
                    break
                  }
                None => {
                  ok = false
                  break
                }
              }
            }
            ok
          }
        _ => false
      }
    @core.Type::Array(inner) =>
      match a {
        @core.Type::Array(actual_inner) =>
          type_matches_impl_target(env, inner, actual_inner, mapping)
        _ => false
      }
    @core.Type::Map(inner) =>
      match a {
        @core.Type::Map(actual_inner) =>
          type_matches_impl_target(env, inner, actual_inner, mapping)
        _ => false
      }
    @core.Type::ArrayBuilder(inner) =>
      match a {
        @core.Type::ArrayBuilder(actual_inner) =>
          type_matches_impl_target(env, inner, actual_inner, mapping)
        _ => false
      }
    @core.Type::MapBuilder(inner) =>
      match a {
        @core.Type::MapBuilder(actual_inner) =>
          type_matches_impl_target(env, inner, actual_inner, mapping)
        _ => false
      }
    @core.Type::Variant(pf) =>
      match a {
        @core.Type::Variant(af) =>
          if pf.length() != af.length() {
            false
          } else {
            let mut ok = true
            for name, p_ty in pf {
              match af.get(name) {
                Some(a_ty) =>
                  if not(type_matches_impl_target(env, p_ty, a_ty, mapping)) {
                    ok = false
                    break
                  }
                None => {
                  ok = false
                  break
                }
              }
            }
            ok
          }
        _ => false
      }
    @core.Type::Func(params=pp, ret=pr, ..) =>
      match a {
        @core.Type::Func(params=ap, ret=ar, ..) =>
          if pp.length() != ap.length() {
            false
          } else {
            let mut ok = true
            for i in 0..<pp.length() {
              if pp[i].label != ap[i].label ||
                not(type_matches_impl_target(env, pp[i].ty, ap[i].ty, mapping)) {
                ok = false
                break
              }
            }
            ok && type_matches_impl_target(env, pr, ar, mapping)
          }
        _ => false
      }
    _ => type_equal(env, p, a) catch { _ => false }
  }
}

///|
fn type_implements_trait(
  env : TypeEnv,
  ty : @core.Type,
  trait_name : String,
) -> Bool {
  let resolved = resolve_type(env, ty)
  match resolved {
    @core.Type::Var(id) =>
      match env.var_trait_bounds.get(id) {
        Some(bounds) => trait_bound_satisfied(env, bounds, trait_name)
        None => false
      }
    _ => {
      if type_implements_trait_from_impls(
          env,
          resolved,
          env.trait_impls_for(trait_name),
        ) {
        return true
      }
      for impl_trait_name in env.trait_names() {
        if impl_trait_name == trait_name {
          continue
        }
        if not(trait_is_subtrait(env, impl_trait_name, trait_name)) {
          continue
        }
        if type_implements_trait_from_impls(
            env,
            resolved,
            env.trait_impls_for(impl_trait_name),
          ) {
          return true
        }
      }
      false
    }
  }
}

///|
fn type_implements_trait_from_impls(
  env : TypeEnv,
  resolved : @core.Type,
  impls : Array[TraitImplDef],
) -> Bool {
  for impl_def in impls {
    let mapping : Map[String, @core.Type] = {}
    if type_matches_impl_target(env, impl_def.target, resolved, mapping) {
      let mut ok = true
      for param in impl_def.type_params {
        match mapping.get(param) {
          Some(actual_ty) =>
            match impl_def.type_bounds.get(param) {
              Some(bounds) =>
                for bound in bounds {
                  if not(type_implements_trait(env, actual_ty, bound)) {
                    ok = false
                    break
                  }
                }
              None => ()
            }
          None => ()
        }
        if not(ok) {
          break
        }
      }
      if ok {
        return true
      }
    }
  }
  false
}

///|
fn ensure_type_satisfies_bounds(
  env : TypeEnv,
  ty : @core.Type,
  bounds : Array[String],
  span : @core.Span,
  context : String,
) -> Bool raise TypeError {
  let deduped = dedup_trait_bounds(bounds)
  if deduped.is_empty() {
    return true
  }
  ensure_traits_defined(env, deduped, span)
  let resolved = resolve_type(env, ty)
  match resolved {
    @core.Type::Var(id) => {
      add_var_trait_bounds(env, id, deduped)
      true
    }
    _ => {
      for bound in deduped {
        if not(type_implements_trait(env, resolved, bound)) {
          raise TypeError::Mismatch(
            expected=@core.Type::Named(name=bound, args=[]),
            actual=resolved,
            span~,
            context=Some(context),
          )
        }
      }
      true
    }
  }
}

///|
fn register_trait_impl(
  env : TypeEnv,
  type_params : Array[String],
  type_bounds : Map[String, Array[String]],
  trait_name : String,
  target : @core.Type,
  span : @core.Span,
) -> Unit raise TypeError {
  if not(env.has_trait(trait_name)) {
    raise TypeError::BadTypeDef(message="unknown trait: " + trait_name, span~)
  }
  if not(env.trait_is_local(trait_name)) && not(env.trait_is_open(trait_name)) {
    raise TypeError::TraitSealed(trait_name~, span~)
  }
  ensure_unique_params(type_params, span)
  let normalized_type_bounds : Map[String, Array[String]] = {}
  for type_param in type_params {
    match type_bounds.get(type_param) {
      Some(bounds) => {
        let deduped = dedup_trait_bounds(bounds)
        ensure_traits_defined(env, deduped, span)
        normalized_type_bounds[type_param] = deduped
      }
      None => ()
    }
  }
  let normalized_target = resolve_type(env, target)
  let incoming = TraitImplDef::{
    type_params,
    type_bounds: normalized_type_bounds,
    target: normalized_target,
  }
  for impl_def in env.trait_impls_for(trait_name) {
    if trait_impls_overlap(env, impl_def, incoming) {
      if env.session_state.lenient_mode {
        return
      }
      raise TypeError::TraitImplOverlap(trait_name~, span~)
    }
  }
  env.add_trait_impl(trait_name, incoming)
}

///|
fn instantiate_trait_impl_target(
  env : TypeEnv,
  impl_def : TraitImplDef,
) -> @core.Type {
  let mapping : Map[String, @core.Type] = {}
  for type_param in impl_def.type_params {
    let tv = fresh_type_var(env)
    mapping[type_param] = tv
    match tv {
      @core.Type::Var(id) =>
        match impl_def.type_bounds.get(type_param) {
          Some(bounds) => add_var_trait_bounds(env, id, bounds)
          None => ()
        }
      _ => ()
    }
  }
  substitute_type_params(impl_def.target, mapping)
}

///|
fn trait_impl_targets_may_overlap_many(
  left : Array[@core.Type],
  right : Array[@core.Type],
) -> Bool {
  if left.length() != right.length() {
    return false
  }
  let mut i = 0
  while i < left.length() {
    if not(trait_impl_targets_may_overlap(left[i], right[i])) {
      return false
    }
    i += 1
  }
  true
}

///|
fn trait_impl_targets_may_overlap(
  left : @core.Type,
  right : @core.Type,
) -> Bool {
  match left {
    @core.Type::Param(_) | @core.Type::Var(_) => true
    _ =>
      match right {
        @core.Type::Param(_) | @core.Type::Var(_) => true
        _ => trait_impl_targets_may_overlap_concrete(left, right)
      }
  }
}

///|
fn trait_impl_targets_may_overlap_concrete(
  left : @core.Type,
  right : @core.Type,
) -> Bool {
  match left {
    @core.Type::Int =>
      match right {
        @core.Type::Int => true
        _ => false
      }
    @core.Type::Float =>
      match right {
        @core.Type::Float => true
        _ => false
      }
    @core.Type::Double =>
      match right {
        @core.Type::Double => true
        _ => false
      }
    @core.Type::Bool =>
      match right {
        @core.Type::Bool => true
        _ => false
      }
    @core.Type::Char =>
      match right {
        @core.Type::Char => true
        _ => false
      }
    @core.Type::String =>
      match right {
        @core.Type::String => true
        _ => false
      }
    @core.Type::Path =>
      match right {
        @core.Type::Path => true
        _ => false
      }
    @core.Type::PromptText =>
      match right {
        @core.Type::PromptText => true
        _ => false
      }
    @core.Type::Unit =>
      match right {
        @core.Type::Unit => true
        _ => false
      }
    @core.Type::StringBuilder =>
      match right {
        @core.Type::StringBuilder => true
        _ => false
      }
    @core.Type::Never =>
      match right {
        @core.Type::Never => true
        _ => false
      }
    @core.Type::Tuple(left_items) =>
      match right {
        @core.Type::Tuple(right_items) =>
          trait_impl_targets_may_overlap_many(left_items, right_items)
        _ => false
      }
    @core.Type::Array(left_item) =>
      match right {
        @core.Type::Array(right_item) =>
          trait_impl_targets_may_overlap(left_item, right_item)
        _ => false
      }
    @core.Type::Map(left_item) =>
      match right {
        @core.Type::Map(right_item) =>
          trait_impl_targets_may_overlap(left_item, right_item)
        _ => false
      }
    @core.Type::ArrayBuilder(left_item) =>
      match right {
        @core.Type::ArrayBuilder(right_item) =>
          trait_impl_targets_may_overlap(left_item, right_item)
        _ => false
      }
    @core.Type::MapBuilder(left_item) =>
      match right {
        @core.Type::MapBuilder(right_item) =>
          trait_impl_targets_may_overlap(left_item, right_item)
        _ => false
      }
    @core.Type::Named(name=left_name, args=left_args) =>
      match right {
        @core.Type::Named(name=right_name, args=right_args) =>
          left_name == right_name &&
          trait_impl_targets_may_overlap_many(left_args, right_args)
        _ => false
      }
    @core.Type::Func(params=left_params, ret=left_ret, ..) =>
      match right {
        @core.Type::Func(params=right_params, ret=right_ret, ..) => {
          if left_params.length() != right_params.length() {
            return false
          }
          let mut i = 0
          while i < left_params.length() {
            if not(
                trait_impl_targets_may_overlap(
                  left_params[i].ty,
                  right_params[i].ty,
                ),
              ) {
              return false
            }
            i += 1
          }
          trait_impl_targets_may_overlap(left_ret, right_ret)
        }
        _ => false
      }
    @core.Type::Record(_) =>
      match right {
        @core.Type::Record(_) => true
        _ => false
      }
    @core.Type::Variant(_) =>
      match right {
        @core.Type::Variant(_) => true
        _ => false
      }
    @core.Type::Param(_) | @core.Type::Var(_) => true
  }
}

///|
fn trait_impls_overlap(
  env : TypeEnv,
  left : TraitImplDef,
  right : TraitImplDef,
) -> Bool {
  if not(trait_impl_targets_may_overlap(left.target, right.target)) {
    return false
  }
  let overlap_env = clone_env(env)
  let left_target = instantiate_trait_impl_target(overlap_env, left)
  let right_target = instantiate_trait_impl_target(overlap_env, right)
  let result : Result[Bool, TypeError] = try? unify_types(
    overlap_env, left_target, right_target,
  )
  match result {
    Ok(v) => v
    Err(_) => false
  }
}

///|
fn register_enum_def(
  env : TypeEnv,
  name : String,
  params : Array[String],
  ctors : Array[@core.TypeCtor],
  span : @core.Span,
) -> Unit raise TypeError {
  ensure_not_reserved_wasm_type_name(name, span)
  if env.get_enum_def(name) is Some(_) || env.get_type_alias(name) is Some(_) {
    raise TypeError::BadTypeDef(message="duplicate type: " + name, span~)
  }
  if ctors.is_empty() {
    raise TypeError::BadTypeDef(message="empty type: " + name, span~)
  }
  ensure_unique_params(params, span)
  env.set_enum_def(name, EnumDef::{ name, params, ctors })
  let ctor_map : Map[String, @core.Type] = {}
  for ctor in ctors {
    if ctor_map.contains(ctor.name) {
      raise TypeError::BadTypeDef(
        message="duplicate ctor: " + ctor.name,
        span=ctor.span,
      )
    }
    let payload = ctor_payload_type(env, ctor)
    ctor_map[ctor.name] = payload
  }
  for ctor_name, payload in ctor_map {
    if env.get_ctor(ctor_name) is Some(_) {
      raise TypeError::BadTypeDef(
        message="ctor already defined: " + ctor_name,
        span~,
      )
    }
    env.set_ctor(ctor_name, CtorInfo::{ type_name: name, params, payload })
  }
}

///|
fn register_type_alias(
  env : TypeEnv,
  name : String,
  params : Array[String],
  target : @core.Type,
  span : @core.Span,
) -> Unit raise TypeError {
  ensure_not_reserved_wasm_type_name(name, span)
  if env.get_enum_def(name) is Some(_) || env.get_type_alias(name) is Some(_) {
    raise TypeError::BadTypeDef(message="duplicate type: " + name, span~)
  }
  ensure_unique_params(params, span)
  let normalized = normalize_type(env, target)
  env.set_type_alias(name, TypeAlias::{ name, params, target: normalized })
}

///|
fn register_struct_def(
  env : TypeEnv,
  name : String,
  params : Array[String],
  fields : Array[@core.StructField],
  span : @core.Span,
) -> Unit raise TypeError {
  ensure_not_reserved_wasm_type_name(name, span)
  if env.get_enum_def(name) is Some(_) ||
    env.get_type_alias(name) is Some(_) ||
    env.get_struct(name) is Some(_) {
    raise TypeError::BadTypeDef(message="duplicate type: " + name, span~)
  }
  ensure_unique_params(params, span)
  // Check for duplicate field names
  let seen : Map[String, Bool] = {}
  for field in fields {
    if seen.contains(field.name) {
      raise TypeError::BadTypeDef(
        message="duplicate field: " + field.name,
        span=field.span,
      )
    }
    seen[field.name] = true
  }
  // Convert fields
  let field_defs : Array[StructFieldDef] = []
  for field in fields {
    let normalized = normalize_type(env, field.ty)
    field_defs.push(StructFieldDef::{ name: field.name, ty: normalized })
  }
  env.set_struct(name, StructDef::{ name, params, fields: field_defs })
}

///|
/// Build a provisional TypeScheme for a forward-declarable function.
/// Used in the pre-scan phase to register function signatures before
/// type-checking bodies, enabling mutual recursion.
fn build_forward_fn_scheme(
  env : TypeEnv,
  type_params : Array[String],
  type_bounds : Map[String, Array[String]],
  params : Array[@core.FuncParam],
  ret : @core.Type,
  effects : Array[@core.EffectAtom],
  fn_span : @core.Span,
) -> TypeScheme raise TypeError {
  let type_param_vars : Map[String, @core.Type] = {}
  for tp in type_params {
    type_param_vars[tp] = fresh_type_var(env)
    match type_bounds.get(tp) {
      Some(bounds) => {
        let deduped = dedup_trait_bounds(bounds)
        ensure_traits_defined(env, deduped, fn_span)
        match type_param_vars.get(tp) {
          Some(@core.Type::Var(id)) => add_var_trait_bounds(env, id, deduped)
          _ => ()
        }
      }
      None => ()
    }
  }
  let mut uses_num = false
  for param in params {
    if has_num_type(param.ty) {
      uses_num = true
      break
    }
  }
  if not(uses_num) {
    uses_num = has_num_type(ret)
  }
  let num_var = if uses_num { Some(fresh_num_var(env)) } else { None }
  let resolved_params : Array[@core.FuncParam] = []
  for param in params {
    let param_ty_with_num = match num_var {
      Some(n) => replace_num_type(param.ty, n)
      None => param.ty
    }
    let param_ty = substitute_type_params(param_ty_with_num, type_param_vars)
    let resolved = normalize_type(env, param_ty)
    ensure_no_scoped_ref_param_decl(env, resolved, fn_span)
    // Note: bounds are NOT checked here; the main loop's type_let_expr(rec=true)
    // will perform full bound checking when the function body is type-checked.
    resolved_params.push(@core.FuncParam::{
      name: param.name,
      label: param.label,
      ty: resolved,
      bounds: param.bounds,
    })
  }
  let ret_ty_with_num = match num_var {
    Some(n) => replace_num_type(ret, n)
    None => ret
  }
  let ret_ty = substitute_type_params(ret_ty_with_num, type_param_vars)
  let resolved_ret = normalize_type(env, ret_ty)
  let normalized_effects = normalize_effects(effects, fn_span)
  let provisional_fn_ty = @core.Type::Func(
    params=resolved_params,
    ret=resolved_ret,
    effects=normalized_effects,
  )
  generalize(env, provisional_fn_ty)
}
