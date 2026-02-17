///|
pub fn type_check(ast : @core.Module) -> TypeEnv raise TypeError {
  type_check_with_aliases(ast, {})
}

///|
/// @core.Type check with import aliases (qualified names treated as external).
pub fn type_check_with_aliases(
  ast : @core.Module,
  aliases : Map[String, @core.Ref],
) -> TypeEnv raise TypeError {
  let env = get_cached_prelude_env_for_module()
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
pub fn get_cached_prelude_env_for_module() -> TypeEnv raise TypeError {
  match default_typecheck_session.cached_prelude_env.val {
    Some(seed) => seed.clone_for_module()
    None => {
      let seed = TypeEnv::new()
      ensure_prelude_option(seed)
      ensure_prelude_functions(seed, {})
      default_typecheck_session.cached_prelude_env.val = Some(seed)
      seed.clone_for_module()
    }
  }
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
  for stmt in stmts {
    match stmt {
      @core.Stmt::Let(rec~, name~, expr~, span~) => {
        ensure_fresh_value_binding(name, span)
        let scheme = type_let_expr(
          env, rec, name, expr, span, aliases, effects, allow_effect,
        )
        ensure_type_member_decl_receiver_contract(env, name, scheme.ty, span)
        if name != "_" {
          if has_exports && exported_names.contains(name) {
            env.set_exported_scheme(name, scheme)
          } else {
            env.set_scheme(name, scheme)
          }
          let info = purity_for_let(env, rec, name, expr)
          env.set_purity(name, info.value)
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
        let scheme = type_let_expr(
          env, rec, name, expr, span, aliases, effects, allow_effect,
        )
        ensure_type_member_decl_receiver_contract(env, name, scheme.ty, span)
        if name != "_" {
          env.set_exported_scheme(name, scheme)
          let info = purity_for_let(env, rec, name, expr)
          env.set_purity(name, info.value)
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
          env.set_purity(name, false)
          record_value_binding(name)
        }
      }
      @core.Stmt::LetPat(pat~, expr~, span~) => {
        let _ = span
        let ty = type_expr_eff(env, expr, aliases, effects, allow_effect)
        let bindings = collect_pattern_bindings(env, pat, ty)
        for name, bound_ty in bindings {
          ensure_fresh_value_binding(name, span)
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
          env.set_purity(name, true)
          record_value_binding(name)
        }
      }
      @core.Stmt::LetPatElse(pat~, expr~, else_body~, span~) => {
        let _ = span
        let ty = type_expr_eff(env, expr, aliases, effects, allow_effect)
        let bindings = collect_pattern_bindings(env, pat, ty)
        for name, bound_ty in bindings {
          ensure_fresh_value_binding(name, span)
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
        _ => false
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
fn trait_impls_overlap(
  env : TypeEnv,
  left : TraitImplDef,
  right : TraitImplDef,
) -> Bool {
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
