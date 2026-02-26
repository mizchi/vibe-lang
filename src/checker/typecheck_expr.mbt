///|
/// Bind handle arm pattern variables into the arm environment.
/// For known constructors, bind with the ctor payload type.
/// Fallback to String binding for unknown constructors (`Error(...)` etc).
fn bind_handle_arm_pat(
  arm_env : TypeEnv,
  env : TypeEnv,
  pat : @core.Pat,
) -> Unit raise TypeError {
  match pat {
    @core.Pat::Ctor(name~, args~, ..) =>
      match env.get_ctor(name) {
        Some(info) => {
          let inst = instantiate_ctor(arm_env, info)
          let effect_row : Map[String, @core.Type] = {}
          effect_row[name] = inst.payload
          let bindings = collect_pattern_bindings(
            arm_env,
            pat,
            @core.Type::Variant(effect_row),
          )
          for bind_name, bind_ty in bindings {
            arm_env.set(bind_name, bind_ty)
          }
        }
        None =>
          for arg in args {
            if arg is @core.Pat::Bind(name~, ..) {
              arm_env.set(name, @core.Type::String)
            }
          }
      }
    _ => {
      let bindings = collect_pattern_bindings(env, pat, @core.Type::String)
      for name, ty in bindings {
        arm_env.set(name, ty)
      }
    }
  }
}

///|
fn ensure_no_scoped_ref_capture_in_fn(
  env : TypeEnv,
  params : Array[@core.FuncParam],
  body : @core.Module,
  span : @core.Span,
) -> Unit raise TypeError {
  if not(env.scoped_ref_checks_enabled) {
    return
  }
  let profile_start = if env.scoped_ref_profile_enabled {
    env.scoped_ref_capture_checks += 1
    Some(@bench.monotonic_clock_start())
  } else {
    None
  }
  let finish = fn() {
    match profile_start {
      Some(ts) =>
        env.scoped_ref_capture_time_us += @bench.monotonic_clock_end(ts)
      None => ()
    }
  }
  if not(env.has_scoped_ref_binding_for_capture()) {
    finish()
    return
  }
  let bound = @core.WalkerScope::new()
  for param in params {
    bound.bindings[param.name] = true
  }
  let refs : Map[String, Bool] = {}
  @core.walk_block_refs(body, bound, refs, fn(name, scope, out) {
    if scope.contains(name) {
      return
    }
    if @core.is_builtin_name(name) ||
      @core.is_logic_builtin_name(name) ||
      @core.has_qualified_name(name) {
      return
    }
    out[name] = true
  })
  for name, _ in refs {
    match env.get_scheme(name) {
      Some(scheme) =>
        if type_contains_scoped_ref(env, scheme.ty) {
          finish()
          raise TypeError::ScopedRefEscape(context="closure capture", span~)
        }
      None => ()
    }
  }
  finish()
}

///|
fn ensure_no_scoped_ref_param_decl(
  env : TypeEnv,
  param_ty : @core.Type,
  span : @core.Span,
) -> Unit raise TypeError {
  if not(env.scoped_ref_checks_enabled) {
    return
  }
  if type_contains_scoped_ref(env, param_ty) {
    raise TypeError::ScopedRefEscape(context="function parameter", span~)
  }
}

///|
fn type_struct_lit(
  env : TypeEnv,
  name : String,
  type_args : Array[@core.Type],
  fields : Array[@core.RecordFieldExpr],
  span : @core.Span,
  aliases : Map[String, @core.Ref],
  effects : EffectScope,
  allow_effect : Bool,
) -> @core.Type raise TypeError {
  match env.get_struct(name) {
    Some(struct_def) => {
      // Build type argument mapping
      let type_map : Map[String, @core.Type] = {}
      if type_args.length() > 0 {
        // Explicit type arguments
        if type_args.length() != struct_def.params.length() {
          raise TypeError::BadTypeDef(
            message="wrong number of type arguments for struct " + name,
            span~,
          )
        }
        for i, param in struct_def.params {
          type_map[param] = type_args[i]
        }
      }
      // Check each field
      let provided : Map[String, Bool] = {}
      for field in fields {
        if provided.contains(field.name) {
          raise TypeError::BadTypeDef(
            message="duplicate field: " + field.name,
            span=field.span,
          )
        }
        provided[field.name] = true
        match struct_def.get_field(field.name) {
          Some(field_def) => {
            let field_ty = type_expr_eff(
              env,
              field.expr,
              aliases,
              effects,
              allow_effect,
            )
            // Infer type params from field types first (before type check)
            if type_args.is_empty() {
              infer_type_params_from_field(
                env,
                field_def.ty,
                field_ty,
                type_map,
              )
            }
            // Now substitute and check
            let expected = substitute_type_params_by_name(
              field_def.ty,
              type_map,
            )
            if not(type_equal(env, expected, field_ty)) {
              raise TypeError::Mismatch(
                expected~,
                actual=field_ty,
                span=field.span,
                context=Some("struct field " + field.name),
              )
            }
          }
          None =>
            raise TypeError::BadTypeDef(
              message="struct " + name + " has no field: " + field.name,
              span=field.span,
            )
        }
      }
      // Check all required fields are provided
      for field_def in struct_def.fields {
        if not(provided.contains(field_def.name)) {
          raise TypeError::BadTypeDef(
            message="missing field: " + field_def.name,
            span~,
          )
        }
      }
      // Build result type
      let result_args : Array[@core.Type] = []
      for param in struct_def.params {
        match type_map.get(param) {
          Some(ty) => result_args.push(ty)
          None => result_args.push(fresh_type_var(env))
        }
      }
      @core.Type::Named(name~, args=result_args)
    }
    None => raise TypeError::UnknownName(name~, span~, suggestion=None)
  }
}

///|
fn infer_type_params_from_field(
  env : TypeEnv,
  expected : @core.Type,
  actual : @core.Type,
  type_map : Map[String, @core.Type],
) -> Unit {
  match expected {
    @core.Type::Param(param_name) =>
      if not(type_map.contains(param_name)) {
        type_map[param_name] = actual
      }
    @core.Type::Array(inner) =>
      match actual {
        @core.Type::Array(actual_inner) =>
          infer_type_params_from_field(env, inner, actual_inner, type_map)
        _ => ()
      }
    @core.Type::Tuple(items) =>
      match actual {
        @core.Type::Tuple(actual_items) =>
          for i, item in items {
            if i < actual_items.length() {
              infer_type_params_from_field(env, item, actual_items[i], type_map)
            }
          }
        _ => ()
      }
    @core.Type::Named(args~, ..) =>
      match actual {
        @core.Type::Named(args=actual_args, ..) =>
          for i, arg in args {
            if i < actual_args.length() {
              infer_type_params_from_field(env, arg, actual_args[i], type_map)
            }
          }
        _ => ()
      }
    _ => ()
  }
}

///|
fn substitute_type_params_by_name(
  ty : @core.Type,
  type_map : Map[String, @core.Type],
) -> @core.Type {
  match ty {
    @core.Type::Param(name) =>
      match type_map.get(name) {
        Some(t) => t
        None => ty
      }
    @core.Type::Array(inner) =>
      @core.Type::Array(substitute_type_params_by_name(inner, type_map))
    @core.Type::Tuple(items) => {
      let new_items : Array[@core.Type] = []
      for item in items {
        new_items.push(substitute_type_params_by_name(item, type_map))
      }
      @core.Type::Tuple(new_items)
    }
    @core.Type::Named(name~, args~) => {
      let new_args : Array[@core.Type] = []
      for arg in args {
        new_args.push(substitute_type_params_by_name(arg, type_map))
      }
      @core.Type::Named(name~, args=new_args)
    }
    @core.Type::Record(fields) => {
      let new_fields : Map[String, @core.Type] = {}
      for name, field_ty in fields {
        new_fields[name] = substitute_type_params_by_name(field_ty, type_map)
      }
      @core.Type::Record(new_fields)
    }
    @core.Type::Func(params~, ret~, effects~) => {
      let new_params : Array[@core.FuncParam] = []
      for param in params {
        new_params.push(@core.FuncParam::{
          name: param.name,
          label: param.label,
          ty: substitute_type_params_by_name(param.ty, type_map),
          bounds: param.bounds,
        })
      }
      @core.Type::Func(
        params=new_params,
        ret=substitute_type_params_by_name(ret, type_map),
        effects~,
      )
    }
    _ => ty
  }
}

///|
fn ctor_payload_type(
  env : TypeEnv,
  ctor : @core.TypeCtor,
) -> @core.Type raise TypeError {
  if ctor.args.length() == 0 {
    @core.Type::Unit
  } else if ctor.args.length() == 1 {
    normalize_type_preserve_enum(env, ctor.args[0])
  } else {
    let items : Array[@core.Type] = []
    for arg in ctor.args {
      items.push(normalize_type_preserve_enum(env, arg))
    }
    @core.Type::Tuple(items)
  }
}

///|
fn infer_perform_effect_name(env : TypeEnv, value_expr : @core.Expr) -> String {
  match value_expr {
    @core.Expr::Call(name~, ..) | @core.Expr::Ident(name~, ..) =>
      match env.get_ctor(name) {
        Some(_) => name
        None => "Error"
      }
    _ => "Error"
  }
}

///|
fn infer_handle_arm_effect_name(pat : @core.Pat) -> String? {
  match pat {
    @core.Pat::Ctor(name~, ..) => Some(name)
    @core.Pat::Wildcard(..) | @core.Pat::Bind(..) => Some("Error")
    _ => None
  }
}

///|
fn type_perform_expr(
  env : TypeEnv,
  args : Array[@core.CallArg],
  aliases : Map[String, @core.Ref],
  effects : EffectScope,
  allow_effect : Bool,
  span : @core.Span,
) -> @core.Type raise TypeError {
  let pos_args = extract_positional_args(args, "perform", span)
  if pos_args.length() != 1 {
    raise TypeError::BadCall(message="perform", span~)
  }
  let value_expr = pos_args[0]
  let value_ty = type_expr_eff(env, value_expr, aliases, effects, allow_effect)
  let effect_name = infer_perform_effect_name(env, value_expr)
  if effect_name == "Error" {
    let _ = ensure_type_satisfies_bounds(
      env,
      value_ty,
      ["Error"],
      span,
      "perform",
    )
  }
  require_effects(
    env,
    effects,
    [@core.EffectAtom::Const(effect_name)],
    "perform",
    span,
  )
  let ret_ty = fresh_type_var(env)
  if env.handle_resume_types_active {
    match env.handle_resume_types.get(effect_name) {
      Some(expected_ty) =>
        if not(type_equal(env, expected_ty, ret_ty)) {
          raise TypeError::Mismatch(
            expected=expected_ty,
            actual=ret_ty,
            span~,
            context=Some("perform resume type"),
          )
        }
      None => env.handle_resume_types[effect_name] = ret_ty
    }
  }
  ret_ty
}

///|
fn type_resume_expr(
  env : TypeEnv,
  args : Array[@core.CallArg],
  aliases : Map[String, @core.Ref],
  effects : EffectScope,
  allow_effect : Bool,
  span : @core.Span,
) -> @core.Type raise TypeError {
  let pos_args = extract_positional_args(args, "resume", span)
  if pos_args.length() != 1 {
    raise TypeError::BadCall(message="resume", span~)
  }
  if env.handle_arm_depth <= 0 {
    raise TypeError::BadCall(message="resume used outside handle arm", span~)
  }
  let arg_ty = type_expr_eff(env, pos_args[0], aliases, effects, allow_effect)
  if not(env.handle_resume_types_active) {
    raise TypeError::BadCall(
      message="resume used outside resumable handle",
      span~,
    )
  }
  let effect_name = match env.handle_arm_effect_name {
    Some(name) => name
    None =>
      raise TypeError::BadCall(message="resume used outside effect arm", span~)
  }
  match env.handle_arm_resume_expected {
    Some(expected_ty) =>
      if not(type_equal(env, expected_ty, arg_ty)) {
        raise TypeError::Mismatch(
          expected=expected_ty,
          actual=arg_ty,
          span=pos_args[0].span(),
          context=Some("resume value"),
        )
      }
    None => ()
  }
  match env.handle_resume_types.get(effect_name) {
    Some(expected_ty) =>
      if not(type_equal(env, expected_ty, arg_ty)) {
        raise TypeError::Mismatch(
          expected=expected_ty,
          actual=arg_ty,
          span=pos_args[0].span(),
          context=Some("resume value"),
        )
      }
    None =>
      raise TypeError::BadCall(
        message="resume has no matching perform for effect: " + effect_name,
        span~,
      )
  }
  fresh_type_var(env)
}

///|
fn type_handle_arm_expr(
  env : TypeEnv,
  arm : @core.MatchArm,
  aliases : Map[String, @core.Ref],
  effects : EffectScope,
  allow_effect : Bool,
) -> @core.Type raise TypeError {
  if arm.cond is Some(c) {
    let g_ty = type_expr_eff(env, c, aliases, effects, allow_effect)
    if not(type_equal(env, g_ty, @core.Type::Bool)) {
      raise TypeError::Mismatch(
        expected=@core.Type::Bool,
        actual=g_ty,
        span=c.span(),
        context=Some("handle guard"),
      )
    }
  }
  type_expr_eff(env, arm.expr, aliases, effects, allow_effect)
}

///|
fn type_expr_eff(
  env : TypeEnv,
  expr : @core.Expr,
  aliases : Map[String, @core.Ref],
  effects : EffectScope,
  allow_effect : Bool,
) -> @core.Type raise TypeError {
  let ty = match expr {
    @core.Expr::Int(value~, span~) => {
      let _ = value
      let _ = span
      @core.Type::Int
    }
    @core.Expr::Float(value~, span~) => {
      let _ = value
      let _ = span
      @core.Type::Float
    }
    @core.Expr::Double(value~, span~) => {
      let _ = value
      let _ = span
      @core.Type::Double
    }
    @core.Expr::Bool(value~, span~) => {
      let _ = value
      let _ = span
      @core.Type::Bool
    }
    @core.Expr::Char(value~, span~) => {
      let _ = value
      let _ = span
      @core.Type::Char
    }
    @core.Expr::String(value~, span~) => {
      let _ = value
      let _ = span
      @core.Type::String
    }
    @core.Expr::Ident(name~, span~) =>
      match env.get(name) {
        Some(ty) => ty
        None =>
          if has_alias_prefix(name, aliases) {
            @core.Type::Unit
          } else {
            match env.get_ctor(name) {
              Some(info) => {
                let inst = instantiate_ctor(env, info)
                inst.ret
              }
              None =>
                if @core.is_ctor_name(name) {
                  let map : Map[String, @core.Type] = {}
                  map[name] = @core.Type::Unit
                  @core.Type::Variant(map)
                } else {
                  raise TypeError::UnknownName(
                    name~,
                    span~,
                    suggestion=find_name_suggestion(env, aliases, name),
                  )
                }
            }
          }
      }
    @core.Expr::Placeholder(span~, ..) =>
      // Placeholder should have been desugared to lambda; error if it reaches here
      raise TypeError::BadCall(
        message="placeholder _ can only be used in function arguments",
        span~,
      )
    @core.Expr::Call(name~, args~, span~, ..) =>
      if has_alias_prefix(name, aliases) {
        @core.Type::Unit
      } else if name == "__perform" {
        type_perform_expr(env, args, aliases, effects, allow_effect, span)
      } else if name == "__resume" {
        type_resume_expr(env, args, aliases, effects, allow_effect, span)
      } else {
        type_call(env, name, args, aliases, effects, allow_effect, span)
      }
    @core.Expr::Tuple(items~, span~) => {
      let _ = span
      let tys : Array[@core.Type] = []
      for item in items {
        tys.push(type_expr_eff(env, item, aliases, effects, allow_effect))
      }
      @core.Type::Tuple(tys)
    }
    @core.Expr::TupleIndex(expr~, index~, span~) => {
      let tuple_ty = type_expr_eff(env, expr, aliases, effects, allow_effect)
      let resolved = resolve_type(env, tuple_ty)
      match resolved {
        @core.Type::Tuple(items) =>
          if index < 0 || index >= items.length() {
            raise TypeError::BadCall(
              message="tuple index \{index} out of bounds (length \{items.length()})",
              span~,
            )
          } else {
            items[index]
          }
        _ =>
          raise TypeError::Mismatch(
            expected=@core.Type::Tuple([]),
            actual=resolved,
            span~,
            context=Some("tuple index"),
          )
      }
    }
    @core.Expr::Record(fields~, span~) => {
      let _ = span
      let map : Map[String, @core.Type] = {}
      for field in fields {
        let ty = type_expr_eff(env, field.expr, aliases, effects, allow_effect)
        map[field.name] = ty
      }
      @core.Type::Record(map)
    }
    @core.Expr::StructLit(name~, type_args~, fields~, span~) =>
      type_struct_lit(
        env, name, type_args, fields, span, aliases, effects, allow_effect,
      )
    @core.Expr::Array(items~, span~) => {
      let _ = span
      if items.is_empty() {
        @core.Type::Array(@core.Type::Unit)
      } else {
        let first = type_expr_eff(env, items[0], aliases, effects, allow_effect)
        let elem_ty = normalize_type(env, first)
        for i in 1..<items.length() {
          let item_ty = type_expr_eff(
            env,
            items[i],
            aliases,
            effects,
            allow_effect,
          )
          if not(type_equal(env, elem_ty, item_ty)) {
            raise TypeError::Mismatch(
              expected=elem_ty,
              actual=item_ty,
              span=items[i].span(),
              context=Some("array item"),
            )
          }
        }
        @core.Type::Array(elem_ty)
      }
    }
    @core.Expr::Map(fields~, span~) => {
      let _ = span
      if fields.is_empty() {
        @core.Type::Map(@core.Type::Unit)
      } else {
        let first = type_expr_eff(
          env,
          fields[0].expr,
          aliases,
          effects,
          allow_effect,
        )
        let val_ty = normalize_type(env, first)
        for i in 1..<fields.length() {
          let item_ty = type_expr_eff(
            env,
            fields[i].expr,
            aliases,
            effects,
            allow_effect,
          )
          if not(type_equal(env, val_ty, item_ty)) {
            raise TypeError::Mismatch(
              expected=val_ty,
              actual=item_ty,
              span=fields[i].span,
              context=Some("map value"),
            )
          }
        }
        @core.Type::Map(val_ty)
      }
    }
    @core.Expr::If(cond~, then_body~, else_body~, span~) => {
      let cond_ty = type_expr_eff(env, cond, aliases, effects, allow_effect)
      if not(type_equal(env, cond_ty, @core.Type::Bool)) {
        raise TypeError::Mismatch(
          expected=@core.Type::Bool,
          actual=cond_ty,
          span=cond.span(),
          context=Some("if condition"),
        )
      }
      let then_ty = type_block(env, then_body, aliases, effects, allow_effect)
      let else_ty = type_block(env, else_body, aliases, effects, allow_effect)
      if not(type_equal(env, then_ty, else_ty)) {
        raise TypeError::Mismatch(
          expected=then_ty,
          actual=else_ty,
          span~,
          context=Some("if branches"),
        )
      }
      then_ty
    }
    @core.Expr::Block(body~, span~) => {
      let _ = span
      type_block(env, body, aliases, effects, allow_effect)
    }
    @core.Expr::Handle(body~, arms~, span~) => {
      let handle_effects : Array[@core.EffectAtom] = []
      for arm in arms {
        match arm.pat {
          @core.Pat::Ctor(name~, ..) =>
            handle_effects.push(@core.EffectAtom::Const(name))
          @core.Pat::Wildcard(..) | @core.Pat::Bind(..) =>
            handle_effects.push(@core.EffectAtom::Const("Error"))
          _ => ()
        }
      }
      let body_scope = effect_scope_extend(effects, handle_effects)
      let body_env = clone_env(env)
      body_env.handle_resume_types = {}
      body_env.handle_resume_types_active = true
      body_env.handle_arm_effect_name = None
      body_env.handle_arm_resume_expected = None
      let body_ty = type_block(
        body_env, body, aliases, body_scope, allow_effect,
      )
      let inferred_resume_types = body_env.handle_resume_types.copy()
      for arm in arms {
        let arm_env = clone_env(env)
        arm_env.handle_arm_depth += 1
        arm_env.handle_resume_types = inferred_resume_types.copy()
        arm_env.handle_resume_types_active = true
        let arm_effect_name = infer_handle_arm_effect_name(arm.pat)
        arm_env.handle_arm_effect_name = arm_effect_name
        arm_env.handle_arm_resume_expected = match arm_effect_name {
          Some(effect_name) => inferred_resume_types.get(effect_name)
          None => None
        }
        bind_handle_arm_pat(arm_env, body_env, arm.pat)
        let arm_ty_result : Result[@core.Type, TypeError] = try? type_handle_arm_expr(
          arm_env, arm, aliases, effects, allow_effect,
        )
        arm_env.handle_arm_depth -= 1
        let arm_ty = match arm_ty_result {
          Ok(ty) => ty
          Err(err) => raise err
        }
        if not(type_equal(arm_env, body_ty, arm_ty)) {
          raise TypeError::Mismatch(
            expected=body_ty,
            actual=arm_ty,
            span~,
            context=Some("handle branches"),
          )
        }
      }
      body_ty
    }
    @core.Expr::Match(scrutinee~, arms~, span~) => {
      if arms.is_empty() {
        raise TypeError::BadMatch(message="empty match", span~)
      }
      let scrutinee_ty = normalize_type(
        env,
        type_expr_eff(env, scrutinee, aliases, effects, allow_effect),
      )
      let mut result : @core.Type? = None
      let mut has_wildcard = false
      let mut has_ctor = false
      let covered : Map[String, Bool] = {}
      let mut has_bool_pat = false
      let mut covered_true = false
      let mut covered_false = false
      for arm in arms {
        if is_top_wildcard(arm.pat) {
          has_wildcard = true
        }
        match arm.pat {
          @core.Pat::Ctor(name~, ..) => {
            has_ctor = true
            covered[name] = true
          }
          @core.Pat::Or(pats~, ..) =>
            for p in pats {
              match p {
                @core.Pat::Ctor(name~, ..) => {
                  has_ctor = true
                  covered[name] = true
                }
                @core.Pat::Bool(value~, ..) => {
                  has_bool_pat = true
                  if value {
                    covered_true = true
                  } else {
                    covered_false = true
                  }
                }
                _ => ()
              }
            }
          @core.Pat::Bool(value~, ..) => {
            has_bool_pat = true
            if value {
              covered_true = true
            } else {
              covered_false = true
            }
          }
          _ => ()
        }
        let arm_env = clone_env(env)
        let bindings = collect_pattern_bindings(env, arm.pat, scrutinee_ty)
        for name, ty in bindings {
          arm_env.set(name, ty)
        }
        match arm.cond {
          Some(c) => {
            let g_ty = type_expr_eff(arm_env, c, aliases, effects, allow_effect)
            if not(type_equal(env, g_ty, @core.Type::Bool)) {
              raise TypeError::Mismatch(
                expected=@core.Type::Bool,
                actual=g_ty,
                span=c.span(),
                context=Some("match guard"),
              )
            }
          }
          None => ()
        }
        let arm_ty = type_expr_eff(
          arm_env,
          arm.expr,
          aliases,
          effects,
          allow_effect,
        )
        match result {
          Some(t) =>
            if not(type_equal(env, t, arm_ty)) {
              raise TypeError::Mismatch(
                expected=t,
                actual=arm_ty,
                span=arm.expr.span(),
                context=Some("match arm"),
              )
            }
          None => result = Some(arm_ty)
        }
      }
      if not(has_wildcard) {
        match scrutinee_ty {
          @core.Type::Variant(types) => {
            let mut missing = false
            for name, _ in types {
              if not(covered.contains(name)) {
                missing = true
                break
              }
            }
            if missing {
              raise TypeError::NonExhaustiveMatch(span~)
            }
          }
          @core.Type::Bool =>
            if not(has_bool_pat && covered_true && covered_false) {
              raise TypeError::NonExhaustiveMatch(span~)
            }
          _ => if not(has_ctor) { raise TypeError::NonExhaustiveMatch(span~) }
        }
      }
      match result {
        Some(t) => t
        None => @core.Type::Unit
      }
    }
    @core.Expr::ForIn(value_name~, index_name~, iterable~, body~, span~) => {
      let desugared = @core.desugar_for_in(
        value_name, index_name, iterable, body, span,
      )
      type_block(env, desugared, aliases, effects, true)
    }
    @core.Expr::Fn(
      type_params~,
      type_bounds~,
      params~,
      ret~,
      effects=fn_effects,
      body~,
      span~
    ) => {
      ensure_no_scoped_ref_capture_in_fn(env, params, body, span)
      // Create fresh type variables for each type parameter
      let type_param_vars : Map[String, @core.Type] = {}
      for tp in type_params {
        type_param_vars[tp] = fresh_type_var(env)
        match type_bounds.get(tp) {
          Some(bounds) => {
            let deduped = dedup_trait_bounds(bounds)
            ensure_traits_defined(env, deduped, span)
            match type_param_vars.get(tp) {
              Some(@core.Type::Var(id)) =>
                add_var_trait_bounds(env, id, deduped)
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
        match ret {
          Some(r) => uses_num = has_num_type(r)
          None => ()
        }
      }
      let num_var = if uses_num { Some(fresh_num_var(env)) } else { None }
      let scope_env = clone_env(env)
      // Add type parameters as type aliases so inner functions can access them
      for tp in type_params {
        match type_param_vars.get(tp) {
          Some(ty) =>
            scope_env.set_type_alias(tp, TypeAlias::{
              name: tp,
              params: [],
              target: ty,
            })
          None => ()
        }
      }
      let resolved_params : Array[@core.FuncParam] = []
      for param in params {
        let param_ty_with_num = match num_var {
          Some(n) => replace_num_type(param.ty, n)
          None => param.ty
        }
        // Replace type parameters with their type variables
        let param_ty = substitute_type_params(
          param_ty_with_num, type_param_vars,
        )
        let resolved = normalize_type(env, param_ty)
        ensure_no_scoped_ref_param_decl(env, resolved, span)
        let _ = ensure_type_satisfies_bounds(
          env,
          resolved,
          param.bounds,
          span,
          "fn param " + param.name,
        )
        let binding_ty = if param.label == @core.ParamLabel::Optional {
          @core.Type::Named(name="Option", args=[resolved])
        } else {
          resolved
        }
        scope_env.set(param.name, binding_ty)
        resolved_params.push(@core.FuncParam::{
          name: param.name,
          label: param.label,
          ty: resolved,
          bounds: declared_param_bounds(env, resolved, param.bounds),
        })
      }
      let normalized_effects = normalize_effects(fn_effects, span)
      let fn_scope = effect_scope_from_list(normalized_effects)
      // Allow effects in function body if function declares effects
      let fn_allow_effect = allow_effect || normalized_effects.length() > 0
      let body_ty = type_block(
        scope_env, body, aliases, fn_scope, fn_allow_effect,
      )
      let resolved_effects = effect_set_to_atoms(
        effect_set_from_atoms(scope_env, normalized_effects),
      )
      let final_ret = match ret {
        Some(r) => {
          let ret_ty_with_num = match num_var {
            Some(n) => replace_num_type(r, n)
            None => r
          }
          // Replace type parameters with their type variables
          let ret_ty = substitute_type_params(ret_ty_with_num, type_param_vars)
          let resolved = normalize_type(env, ret_ty)
          if not(type_equal(env, resolved, body_ty)) {
            raise TypeError::Mismatch(
              expected=resolved,
              actual=body_ty,
              span~,
              context=Some("fn return"),
            )
          }
          resolved
        }
        None => body_ty
      }
      ensure_no_scoped_ref_return_escape(env, final_ret, span)
      @core.Type::Func(
        params=resolved_params,
        ret=final_ret,
        effects=resolved_effects,
      )
    }
    @core.Expr::While(cond~, body~, span~) => {
      let _ = span
      let cond_ty = type_expr_eff(env, cond, aliases, effects, allow_effect)
      if not(type_equal(env, cond_ty, @core.Type::Bool)) {
        raise TypeError::Mismatch(
          expected=@core.Type::Bool,
          actual=cond_ty,
          span=cond.span(),
          context=Some("while condition"),
        )
      }
      env.loop_depth += 1
      let body_ty_result : Result[@core.Type, TypeError] = try? type_block(
        env, body, aliases, effects, allow_effect,
      )
      env.loop_depth -= 1
      match body_ty_result {
        Ok(_) => ()
        Err(err) => raise err
      }
      @core.Type::Unit
    }
    @core.Expr::Loop(params~, body~, span~) => {
      let _ = span
      // Type-check param init expressions and bind params in scope
      for param in params {
        let param_ty = type_expr_eff(
          env,
          param.init,
          aliases,
          effects,
          allow_effect,
        )
        let scheme = TypeScheme::{
          vars: [],
          num_vars: [],
          effect_vars: [],
          trait_bounds: {},
          ty: param_ty,
        }
        env.set_scheme(param.name, scheme)
        env.set_purity_tier(param.name, TopLevelPurityTier::StateLocal)
      }
      env.loop_depth += 1
      let body_ty_result : Result[@core.Type, TypeError] = try? type_block(
        env, body, aliases, effects, allow_effect,
      )
      env.loop_depth -= 1
      match body_ty_result {
        Ok(_) => ()
        Err(err) => raise err
      }
      @core.Type::Unit
    }
    @core.Expr::Break(value~, span~) => {
      if env.loop_depth <= 0 {
        raise TypeError::BadCall(message="break used outside loop", span~)
      }
      match value {
        Some(expr) =>
          type_expr_eff(env, expr, aliases, effects, allow_effect) |> ignore
        None => ()
      }
      @core.Type::Unit
    }
    @core.Expr::Continue(args~, span~) => {
      if env.loop_depth <= 0 {
        raise TypeError::BadCall(message="continue used outside loop", span~)
      }
      for arg in args {
        type_expr_eff(env, arg, aliases, effects, allow_effect) |> ignore
      }
      @core.Type::Unit
    }
    @core.Expr::Raise(value~, span~) => {
      let val_ty = type_expr_eff(env, value, aliases, effects, allow_effect)
      let _ = ensure_type_satisfies_bounds(
        env,
        val_ty,
        ["Error"],
        span,
        "throw",
      )
      require_effects(
        env,
        effects,
        [@core.EffectAtom::Const("Error")],
        "throw",
        span,
      )
      @core.Type::Never
    }
    @core.Expr::Yield(expr~, span~) => {
      let _ = type_expr_eff(env, expr, aliases, effects, allow_effect)
      require_effects(
        env,
        effects,
        [@core.EffectAtom::Const("Async")],
        "yield",
        span,
      )
      @core.Type::Unit
    }
  }
  record_expr_type(env, expr.span(), ty)
  ty
}

///|
fn type_block(
  env : TypeEnv,
  body : @core.Module,
  aliases : Map[String, @core.Ref],
  effects : EffectScope,
  allow_effect : Bool,
) -> @core.Type raise TypeError {
  let scope_env = clone_env(env)
  let mut last = @core.Type::Unit
  for stmt in body.stmts {
    match stmt {
      @core.Stmt::Let(rec~, name~, expr~, span~) => {
        let _ = span
        let scheme = type_let_expr(
          scope_env, rec, name, expr, span, aliases, effects, allow_effect,
        )
        scope_env.set_scheme(name, scheme)
        last = scheme.ty
      }
      @core.Stmt::EnumDef(name~, params~, ctors~, span~) => {
        register_enum_def(scope_env, name, params, ctors, span)
        last = @core.Type::Unit
      }
      @core.Stmt::TypeAlias(name~, params~, target~, span~) => {
        register_type_alias(scope_env, name, params, target, span)
        last = @core.Type::Unit
      }
      @core.Stmt::TraitDef(name~, supertraits~, open_impl~, exported~, span~) => {
        register_trait_def(
          scope_env, name, supertraits, open_impl, exported, span,
        )
        last = @core.Type::Unit
      }
      @core.Stmt::InternalTraitDef(name~, supertraits~, open_impl~, span~) => {
        register_trait_def(scope_env, name, supertraits, open_impl, false, span)
        last = @core.Type::Unit
      }
      @core.Stmt::TraitImpl(
        type_params~,
        type_bounds~,
        trait_name~,
        target~,
        span~
      ) => {
        register_trait_impl(
          scope_env, type_params, type_bounds, trait_name, target, span,
        )
        last = @core.Type::Unit
      }
      @core.Stmt::Expr(expr~, span~) => {
        let _ = span
        last = type_expr_eff(scope_env, expr, aliases, effects, allow_effect)
      }
      @core.Stmt::Import(spec~, source~, span~) => {
        let _ = spec
        let _ = source
        let _ = span
        last = @core.Type::Unit
      }
      @core.Stmt::ExternLet(name~, ty~, span~) => {
        let _ = span
        let scheme = TypeScheme::{
          vars: [],
          num_vars: [],
          effect_vars: [],
          trait_bounds: {},
          ty,
        }
        scope_env.set_scheme(name, scheme)
        scope_env.set_purity_tier(name, TopLevelPurityTier::Pure)
        last = @core.Type::Unit
      }
      @core.Stmt::ExportLet(rec~, name~, expr~, span~) => {
        let scheme = type_let_expr(
          scope_env, rec, name, expr, span, aliases, effects, allow_effect,
        )
        scope_env.set_scheme(name, scheme)
        last = scheme.ty
      }
      @core.Stmt::InternalExportLet(rec~, name~, expr~, span~) => {
        let scheme = type_let_expr(
          scope_env, rec, name, expr, span, aliases, effects, allow_effect,
        )
        scope_env.set_scheme(name, scheme)
        last = scheme.ty
      }
      @core.Stmt::ExportEnumDef(name~, params~, ctors~, span~) => {
        register_enum_def(scope_env, name, params, ctors, span)
        last = @core.Type::Unit
      }
      @core.Stmt::InternalExportEnumDef(name~, params~, ctors~, span~) => {
        register_enum_def(scope_env, name, params, ctors, span)
        last = @core.Type::Unit
      }
      @core.Stmt::ExportTypeAlias(name~, params~, target~, span~) => {
        register_type_alias(scope_env, name, params, target, span)
        last = @core.Type::Unit
      }
      @core.Stmt::InternalExportTypeAlias(name~, params~, target~, span~) => {
        register_type_alias(scope_env, name, params, target, span)
        last = @core.Type::Unit
      }
      @core.Stmt::Export(..) | @core.Stmt::ReExport(..) =>
        last = @core.Type::Unit
      @core.Stmt::Test(name~, body~, span~) => {
        let _ = span
        let _ = name
        let _ = type_block(scope_env, body, aliases, effects, allow_effect)
        last = @core.Type::Unit
      }
      @core.Stmt::Bench(name~, body~, span~) => {
        let _ = span
        let _ = name
        let _ = type_block(scope_env, body, aliases, effects, allow_effect)
        last = @core.Type::Unit
      }
      @core.Stmt::LetMut(name~, expr~, span~) => {
        let _ = span
        let ty = type_expr_eff(scope_env, expr, aliases, effects, allow_effect)
        let scheme = TypeScheme::{
          vars: [],
          num_vars: [],
          effect_vars: [],
          trait_bounds: {},
          ty,
        }
        scope_env.set_scheme(name, scheme)
        scope_env.set_purity_tier(name, TopLevelPurityTier::StateLocal)
        last = @core.Type::Unit
      }
      @core.Stmt::LetPat(pat~, expr~, span~) => {
        let _ = span
        let ty = type_expr_eff(scope_env, expr, aliases, effects, allow_effect)
        let bindings = collect_pattern_bindings(scope_env, pat, ty)
        for name, bound_ty in bindings {
          let scheme = TypeScheme::{
            vars: [],
            num_vars: [],
            effect_vars: [],
            trait_bounds: {},
            ty: bound_ty,
          }
          scope_env.set_scheme(name, scheme)
          scope_env.set_purity_tier(name, TopLevelPurityTier::Pure)
        }
        last = ty
      }
      @core.Stmt::LetPatElse(pat~, expr~, else_body~, span~) => {
        let _ = span
        let ty = type_expr_eff(scope_env, expr, aliases, effects, allow_effect)
        let bindings = collect_pattern_bindings(scope_env, pat, ty)
        for name, bound_ty in bindings {
          let scheme = TypeScheme::{
            vars: [],
            num_vars: [],
            effect_vars: [],
            trait_bounds: {},
            ty: bound_ty,
          }
          scope_env.set_scheme(name, scheme)
          scope_env.set_purity_tier(name, TopLevelPurityTier::Impure)
        }
        type_block(scope_env, else_body, aliases, effects, allow_effect)
        |> ignore
        last = ty
      }
      @core.Stmt::Assign(name~, expr~, span~) => {
        let ty = type_expr_eff(scope_env, expr, aliases, effects, allow_effect)
        match scope_env.get_scheme(name) {
          Some(scheme) => {
            let expected = instantiate_scheme(scope_env, scheme)
            if not(type_equal(scope_env, expected, ty)) {
              raise TypeError::Mismatch(
                expected~,
                actual=ty,
                span~,
                context=Some("assignment"),
              )
            }
            scope_env.set_purity_tier(name, TopLevelPurityTier::StateLocal)
          }
          None =>
            raise TypeError::UnknownName(
              name~,
              span~,
              suggestion=find_name_suggestion(scope_env, aliases, name),
            )
        }
        last = @core.Type::Unit
      }
      @core.Stmt::IndexAssign(target~, index~, value~, span~) => {
        // Type check target[index] = value
        let _ = type_expr_eff(scope_env, target, aliases, effects, allow_effect)
        let _ = type_expr_eff(scope_env, index, aliases, effects, allow_effect)
        let _ = type_expr_eff(scope_env, value, aliases, effects, allow_effect)
        let _ = span
        last = @core.Type::Unit
      }
      @core.Stmt::StructDef(name~, params~, fields~, span~) => {
        register_struct_def(scope_env, name, params, fields, span)
        last = @core.Type::Unit
      }
      @core.Stmt::ExportStructDef(name~, params~, fields~, span~) => {
        register_struct_def(scope_env, name, params, fields, span)
        last = @core.Type::Unit
      }
      @core.Stmt::InternalExportStructDef(name~, params~, fields~, span~) => {
        register_struct_def(scope_env, name, params, fields, span)
        last = @core.Type::Unit
      }
    }
  }
  if env.handle_resume_types_active {
    let inferred_resume_types : Map[String, @core.Type] = {}
    for effect_name, resume_ty in scope_env.handle_resume_types {
      inferred_resume_types[effect_name] = normalize_type(scope_env, resume_ty)
    }
    env.handle_resume_types = inferred_resume_types
    env.next_var = scope_env.next_var
  }
  last
}

///|
fn ensure_num_operand(
  env : TypeEnv,
  ty : @core.Type,
  span : @core.Span,
) -> Unit raise TypeError {
  let resolved = resolve_type(env, ty)
  match resolved {
    @core.Type::Int | @core.Type::Float | @core.Type::Double => ()
    @core.Type::Var(id) => mark_num_var(env, id)
    _ =>
      raise TypeError::Mismatch(
        expected=@core.Type::Int,
        actual=resolved,
        span~,
        context=Some("argument"),
      )
  }
}

///|
fn ensure_eq_operand(
  env : TypeEnv,
  ty : @core.Type,
  span : @core.Span,
) -> Unit raise TypeError {
  let resolved = resolve_type(env, ty)
  match resolved {
    @core.Type::Int
    | @core.Type::Float
    | @core.Type::Double
    | @core.Type::Bool
    | @core.Type::Char
    | @core.Type::String => ()
    @core.Type::Var(id) =>
      if is_num_var(env, id) {
        ()
      } else {
        match env.var_trait_bounds.get(id) {
          Some(bounds) =>
            if not(trait_bound_satisfied(env, bounds, "Eq")) {
              raise TypeError::Mismatch(
                expected=@core.Type::Named(name="Eq", args=[]),
                actual=resolved,
                span~,
                context=Some("argument"),
              )
            }
          None =>
            raise TypeError::Mismatch(
              expected=@core.Type::Named(name="Eq", args=[]),
              actual=resolved,
              span~,
              context=Some("argument"),
            )
        }
      }
    _ =>
      raise TypeError::Mismatch(
        expected=@core.Type::Int,
        actual=resolved,
        span~,
        context=Some("argument"),
      )
  }
}

///|
fn ensure_ord_operand(
  env : TypeEnv,
  ty : @core.Type,
  span : @core.Span,
) -> Unit raise TypeError {
  let resolved = resolve_type(env, ty)
  match resolved {
    @core.Type::Int
    | @core.Type::Float
    | @core.Type::Double
    | @core.Type::Char
    | @core.Type::String => ()
    @core.Type::Var(id) =>
      if is_num_var(env, id) {
        ()
      } else {
        match env.var_trait_bounds.get(id) {
          Some(bounds) =>
            if not(trait_bound_satisfied(env, bounds, "Ord")) {
              raise TypeError::Mismatch(
                expected=@core.Type::Named(name="Ord", args=[]),
                actual=resolved,
                span~,
                context=Some("argument"),
              )
            }
          None =>
            raise TypeError::Mismatch(
              expected=@core.Type::Named(name="Ord", args=[]),
              actual=resolved,
              span~,
              context=Some("argument"),
            )
        }
      }
    _ =>
      raise TypeError::Mismatch(
        expected=@core.Type::Int,
        actual=resolved,
        span~,
        context=Some("argument"),
      )
  }
}

///|
fn int_char_comparable_pair(
  env : TypeEnv,
  left : @core.Type,
  right : @core.Type,
) -> Bool {
  let l = resolve_type(env, left)
  let r = resolve_type(env, right)
  (l == @core.Type::Int && r == @core.Type::Char) ||
  (l == @core.Type::Char && r == @core.Type::Int)
}

///|
fn parse_type_member_decl(name : String) -> (String, String)? {
  if not(name.contains("::")) {
    return None
  }
  let parts : Array[String] = []
  for part_view in name.split("::") {
    parts.push(part_view.to_string())
  }
  if parts.length() != 2 {
    return None
  }
  let type_name = parts[0]
  let member_name = parts[1]
  if type_name == "" || member_name == "" {
    None
  } else {
    Some((type_name, member_name))
  }
}

///|
fn should_enforce_type_member_decl_contract(
  env : TypeEnv,
  type_name : String,
) -> Bool {
  match type_name {
    "Int" | "Float" | "Double" | "Bool" | "String" | "Path" => true
    _ =>
      env.get_enum_def(type_name) is Some(_) ||
      env.get_struct(type_name) is Some(_) ||
      env.get_type_alias(type_name) is Some(_)
  }
}

///|
fn ensure_type_member_decl_receiver_contract(
  env : TypeEnv,
  name : String,
  ty : @core.Type,
  span : @core.Span,
) -> Unit raise TypeError {
  match parse_type_member_decl(name) {
    None => ()
    Some((type_name, member_name)) => {
      let _ = member_name
      if not(should_enforce_type_member_decl_contract(env, type_name)) {
        return
      }
      let resolved = normalize_type(env, ty)
      match resolved {
        @core.Type::Func(params~, ..) => {
          if params.is_empty() {
            raise TypeError::BadCall(
              message="type member `" +
                name +
                "` must have first parameter of type `" +
                type_name +
                "`",
              span~,
            )
          }
          let recv_ty = params[0].ty
          match namespace_root_from_type(env, recv_ty) {
            Some(actual_type_name) =>
              if actual_type_name != type_name {
                raise TypeError::BadCall(
                  message="type member `" +
                    name +
                    "` first parameter must be `" +
                    type_name +
                    "`, but got `" +
                    actual_type_name +
                    "`",
                  span~,
                )
              }
            None =>
              raise TypeError::BadCall(
                message="type member `" +
                  name +
                  "` first parameter must be `" +
                  type_name +
                  "`",
                span~,
              )
          }
        }
        _ =>
          raise TypeError::BadCall(
            message="type member `" +
              name +
              "` must be a function with first parameter `" +
              type_name +
              "`",
            span~,
          )
      }
    }
  }
}

///|
fn type_check_unary_convert(
  env : TypeEnv,
  args : Array[@core.CallArg],
  call_span : @core.Span,
  aliases : Map[String, @core.Ref],
  effects : EffectScope,
  allow_effect : Bool,
  name : String,
  from_ty : @core.Type,
  to_ty : @core.Type,
) -> @core.Type raise TypeError {
  let pos_args = extract_positional_args(args, name, call_span)
  if pos_args.length() != 1 {
    raise TypeError::BadCall(message=name, span=call_span)
  }
  let arg_ty = type_expr_eff(env, pos_args[0], aliases, effects, allow_effect)
  if not(type_equal(env, arg_ty, from_ty)) {
    raise TypeError::Mismatch(
      expected=from_ty,
      actual=arg_ty,
      span=pos_args[0].span(),
      context=Some("argument"),
    )
  }
  to_ty
}

///|
fn type_check_binary_exact(
  env : TypeEnv,
  args : Array[@core.CallArg],
  call_span : @core.Span,
  aliases : Map[String, @core.Ref],
  effects : EffectScope,
  allow_effect : Bool,
  name : String,
  left_expect : @core.Type,
  right_expect : @core.Type,
  ret_ty : @core.Type,
) -> @core.Type raise TypeError {
  let pos_args = extract_positional_args(args, name, call_span)
  if pos_args.length() != 2 {
    raise TypeError::BadCall(message=name, span=call_span)
  }
  let left_ty = type_expr_eff(env, pos_args[0], aliases, effects, allow_effect)
  if not(type_equal(env, left_ty, left_expect)) {
    raise TypeError::Mismatch(
      expected=left_expect,
      actual=left_ty,
      span=pos_args[0].span(),
      context=Some("argument"),
    )
  }
  let right_ty = type_expr_eff(env, pos_args[1], aliases, effects, allow_effect)
  if not(type_equal(env, right_ty, right_expect)) {
    raise TypeError::Mismatch(
      expected=right_expect,
      actual=right_ty,
      span=pos_args[1].span(),
      context=Some("argument"),
    )
  }
  ret_ty
}

///|
fn is_non_expansive_expr(
  env : TypeEnv,
  expr : @core.Expr,
  aliases : Map[String, @core.Ref],
) -> Bool {
  match expr {
    @core.Expr::Int(..) => true
    @core.Expr::Float(..) => true
    @core.Expr::Double(..) => true
    @core.Expr::Bool(..) => true
    @core.Expr::Char(..) => true
    @core.Expr::String(..) => true
    @core.Expr::Ident(name~, span~) => {
      let _ = span
      not(has_alias_prefix(name, aliases))
    }
    @core.Expr::Tuple(items~, span~) => {
      let _ = span
      let mut ok = true
      for item in items {
        if not(is_non_expansive_expr(env, item, aliases)) {
          ok = false
          break
        }
      }
      ok
    }
    @core.Expr::TupleIndex(expr~, ..) =>
      is_non_expansive_expr(env, expr, aliases)
    @core.Expr::Record(fields~, span~) => {
      let _ = span
      let mut ok = true
      for field in fields {
        if not(is_non_expansive_expr(env, field.expr, aliases)) {
          ok = false
          break
        }
      }
      ok
    }
    @core.Expr::Array(items~, span~) => {
      let _ = span
      let mut ok = true
      for item in items {
        if not(is_non_expansive_expr(env, item, aliases)) {
          ok = false
          break
        }
      }
      ok
    }
    @core.Expr::Map(fields~, span~) => {
      let _ = span
      let mut ok = true
      for field in fields {
        if not(is_non_expansive_expr(env, field.expr, aliases)) {
          ok = false
          break
        }
      }
      ok
    }
    @core.Expr::Fn(..) => true
    @core.Expr::Call(name~, args~, span~, ..) => {
      let _ = span
      if has_alias_prefix(name, aliases) {
        false
      } else if @core.is_ctor_name(name) {
        let mut ok = true
        for arg in args {
          if not(is_non_expansive_expr(env, arg.expr, aliases)) {
            ok = false
            break
          }
        }
        ok
      } else {
        false
      }
    }
    _ => false
  }
}

///|
fn type_let_expr(
  env : TypeEnv,
  rec : Bool,
  name : String,
  expr : @core.Expr,
  span : @core.Span,
  aliases : Map[String, @core.Ref],
  effects : EffectScope,
  allow_effect : Bool,
) -> TypeScheme raise TypeError {
  if rec && name == "_" {
    raise TypeError::BadRec(
      message="wildcard binding cannot be recursive",
      span~,
    )
  }
  if rec {
    match expr {
      @core.Expr::Fn(
        type_params~,
        type_bounds~,
        params~,
        ret~,
        effects=fn_effects,
        body~,
        span=fn_span
      ) =>
        match ret {
          None => raise TypeError::BadRec(message="missing return type", span~)
          Some(r) => {
            ensure_no_scoped_ref_capture_in_fn(env, params, body, fn_span)
            let type_param_vars : Map[String, @core.Type] = {}
            for tp in type_params {
              type_param_vars[tp] = fresh_type_var(env)
              match type_bounds.get(tp) {
                Some(bounds) => {
                  let deduped = dedup_trait_bounds(bounds)
                  ensure_traits_defined(env, deduped, fn_span)
                  match type_param_vars.get(tp) {
                    Some(@core.Type::Var(id)) =>
                      add_var_trait_bounds(env, id, deduped)
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
              uses_num = has_num_type(r)
            }
            let num_var = if uses_num { Some(fresh_num_var(env)) } else { None }
            let scope_env = clone_env(env)
            for tp in type_params {
              match type_param_vars.get(tp) {
                Some(ty) =>
                  scope_env.set_type_alias(tp, TypeAlias::{
                    name: tp,
                    params: [],
                    target: ty,
                  })
                None => ()
              }
            }
            let resolved_params : Array[@core.FuncParam] = []
            for param in params {
              let param_ty_with_num = match num_var {
                Some(n) => replace_num_type(param.ty, n)
                None => param.ty
              }
              let param_ty = substitute_type_params(
                param_ty_with_num, type_param_vars,
              )
              let resolved = normalize_type(env, param_ty)
              ensure_no_scoped_ref_param_decl(env, resolved, span)
              let _ = ensure_type_satisfies_bounds(
                env,
                resolved,
                param.bounds,
                fn_span,
                "fn param " + param.name,
              )
              let binding_ty = if param.label == @core.ParamLabel::Optional {
                @core.Type::Named(name="Option", args=[resolved])
              } else {
                resolved
              }
              scope_env.set(param.name, binding_ty)
              resolved_params.push(@core.FuncParam::{
                name: param.name,
                label: param.label,
                ty: resolved,
                bounds: declared_param_bounds(env, resolved, param.bounds),
              })
            }
            let ret_ty_with_num = match num_var {
              Some(n) => replace_num_type(r, n)
              None => r
            }
            let ret_ty = substitute_type_params(
              ret_ty_with_num, type_param_vars,
            )
            let resolved_ret = normalize_type(env, ret_ty)
            ensure_no_scoped_ref_return_escape(env, resolved_ret, fn_span)
            let normalized_effects = normalize_effects(fn_effects, fn_span)
            let provisional_fn_ty = @core.Type::Func(
              params=resolved_params,
              ret=resolved_ret,
              effects=normalized_effects,
            )
            scope_env.set(name, provisional_fn_ty)
            scope_env.active_rec_fn = Some(name)
            scope_env.active_rec_fn_has_type_params = type_params.length() > 0
            let fn_scope = effect_scope_from_list(normalized_effects)
            let fn_allow_effect = allow_effect ||
              normalized_effects.length() > 0
            let body_ty = type_block(
              scope_env, body, aliases, fn_scope, fn_allow_effect,
            )
            if not(type_equal(scope_env, resolved_ret, body_ty)) {
              raise TypeError::Mismatch(
                expected=resolved_ret,
                actual=body_ty,
                span=fn_span,
                context=Some("fn return"),
              )
            }
            let resolved_effects = effect_set_to_atoms(
              effect_set_from_atoms(scope_env, normalized_effects),
            )
            let final_params : Array[@core.FuncParam] = []
            for param in resolved_params {
              final_params.push(@core.FuncParam::{
                name: param.name,
                label: param.label,
                ty: resolve_type(scope_env, param.ty),
                bounds: param.bounds,
              })
            }
            let final_ty = @core.Type::Func(
              params=final_params,
              ret=resolve_type(scope_env, resolved_ret),
              effects=resolved_effects,
            )
            generalize(env, final_ty)
          }
        }
      _ => raise TypeError::BadRec(message="expected fn", span~)
    }
  } else {
    let ty = type_expr_eff(env, expr, aliases, effects, allow_effect)
    if allow_effect {
      if is_non_expansive_expr(env, expr, aliases) {
        generalize(env, ty)
      } else {
        let resolved = resolve_type(env, ty)
        let normalized = normalize_type(env, resolved)
        TypeScheme::{
          vars: [],
          num_vars: [],
          effect_vars: [],
          trait_bounds: {},
          ty: normalized,
        }
      }
    } else {
      generalize(env, ty)
    }
  }
}

///|
priv struct ArgType {
  label : String?
  ty : @core.Type
  span : @core.Span
}

///|
fn extract_positional_args(
  args : Array[@core.CallArg],
  name : String,
  call_span : @core.Span,
) -> Array[@core.Expr] raise TypeError {
  let _ = call_span
  let out : Array[@core.Expr] = []
  for arg in args {
    match arg.label {
      Some(_) => raise TypeError::BadCall(message=name, span=arg.span)
      None => out.push(arg.expr)
    }
  }
  out
}

///|
/// Check if a lambda expression has placeholder types that need inference
fn has_infer_placeholder(params : Array[@core.FuncParam]) -> Bool {
  for param in params {
    if param.ty.is_infer_placeholder() {
      return true
    }
  }
  false
}

///|
/// Type an argument expression with optional expected type context
fn type_arg_with_context(
  env : TypeEnv,
  expr : @core.Expr,
  expected : @core.Type?,
  aliases : Map[String, @core.Ref],
  effects : EffectScope,
  allow_effect : Bool,
) -> @core.Type raise TypeError {
  match expr {
    @core.Expr::Fn(params=fn_params, ..) =>
      match expected {
        Some(exp_ty) if has_infer_placeholder(fn_params) =>
          type_lambda_with_context(
            env, expr, exp_ty, aliases, effects, allow_effect,
          )
        _ => type_expr_eff(env, expr, aliases, effects, allow_effect)
      }
    _ => type_expr_eff(env, expr, aliases, effects, allow_effect)
  }
}

///|
/// Type a lambda with contextual type information from the expected parameter type
fn type_lambda_with_context(
  env : TypeEnv,
  expr : @core.Expr,
  expected : @core.Type,
  aliases : Map[String, @core.Ref],
  effects : EffectScope,
  allow_effect : Bool,
) -> @core.Type raise TypeError {
  match expr {
    @core.Expr::Fn(params~, ret~, effects=fn_effects, body~, span~, ..) => {
      // Resolve the expected type first
      let resolved_expected = resolve_type(env, expected)
      match resolved_expected {
        @core.Type::Func(params=expected_params, ret=expected_ret, ..) => {
          let scope_env = clone_env(env)
          let resolved_params : Array[@core.FuncParam] = []
          for i in 0..<params.length() {
            let param = params[i]
            // Use expected type if param type is placeholder
            let param_ty = if param.ty.is_infer_placeholder() &&
              i < expected_params.length() {
              // Resolve the expected param type (might still be Var, that's ok)
              resolve_type(env, expected_params[i].ty)
            } else {
              normalize_type(env, param.ty)
            }
            let _ = ensure_type_satisfies_bounds(
              env,
              param_ty,
              param.bounds,
              span,
              "lambda param " + param.name,
            )
            ensure_no_scoped_ref_param_decl(env, param_ty, span)
            let binding_ty = if param.label == @core.ParamLabel::Optional {
              @core.Type::Named(name="Option", args=[param_ty])
            } else {
              param_ty
            }
            scope_env.set(param.name, binding_ty)
            resolved_params.push(@core.FuncParam::{
              name: param.name,
              label: param.label,
              ty: param_ty,
              bounds: declared_param_bounds(env, param_ty, param.bounds),
            })
          }
          let normalized_effects = normalize_effects(fn_effects, span)
          let fn_scope = effect_scope_from_list(normalized_effects)
          let body_ty = type_block(
            scope_env, body, aliases, fn_scope, allow_effect,
          )
          let resolved_effects = effect_set_to_atoms(
            effect_set_from_atoms(scope_env, normalized_effects),
          )
          // Verify or infer return type
          let final_ret = match ret {
            Some(r) => {
              let resolved = normalize_type(env, r)
              if not(type_equal(env, resolved, body_ty)) {
                raise TypeError::Mismatch(
                  expected=resolved,
                  actual=body_ty,
                  span~,
                  context=Some("lambda return"),
                )
              }
              resolved
            }
            None => body_ty
          }
          // Unify return type with expected (this binds type vars)
          let _ = unify_types(env, expected_ret, final_ret)
          // After body type checking, params might have been unified with concrete types
          // Re-resolve params to get final types
          let final_params : Array[@core.FuncParam] = []
          for p in resolved_params {
            let final_ty = resolve_type(env, p.ty)
            final_params.push(@core.FuncParam::{
              name: p.name,
              label: p.label,
              ty: final_ty,
              bounds: p.bounds,
            })
          }
          @core.Type::Func(
            params=final_params,
            ret=final_ret,
            effects=resolved_effects,
          )
        }
        @core.Type::Var(id) => {
          // Expected type is itself a type variable
          // Type the lambda normally and unify
          let lambda_ty = type_expr_eff(
            env, expr, aliases, effects, allow_effect,
          )
          let _ = bind_var(env, id, lambda_ty)
          lambda_ty
        }
        _ =>
          // Expected type is not a function, fall back to normal typing
          type_expr_eff(env, expr, aliases, effects, allow_effect)
      }
    }
    _ => type_expr_eff(env, expr, aliases, effects, allow_effect)
  }
}

///|
fn is_active_polymorphic_recursive_call(
  env : TypeEnv,
  callee_name : String,
) -> Bool {
  match env.active_rec_fn {
    Some(active) => active == callee_name && env.active_rec_fn_has_type_params
    None => false
  }
}

///|
fn variadic_param_element_type(param : @core.FuncParam) -> @core.Type {
  match param.ty {
    @core.Type::Array(inner) => inner
    _ => param.ty
  }
}

///|
fn ensure_no_scoped_ref_call_argument(
  env : TypeEnv,
  arg_ty : @core.Type,
  span : @core.Span,
) -> Unit raise TypeError {
  if not(env.scoped_ref_checks_enabled) {
    return
  }
  let profile_start = if env.scoped_ref_profile_enabled {
    env.scoped_ref_call_arg_checks += 1
    Some(@bench.monotonic_clock_start())
  } else {
    None
  }
  let finish = fn() {
    match profile_start {
      Some(ts) =>
        env.scoped_ref_call_arg_time_us += @bench.monotonic_clock_end(ts)
      None => ()
    }
  }
  if type_contains_scoped_ref(env, arg_ty) {
    finish()
    raise TypeError::ScopedRefEscape(context="function argument", span~)
  }
  finish()
}

///|
fn check_call_args(
  env : TypeEnv,
  callee_name : String,
  params : Array[@core.FuncParam],
  args : Array[@core.CallArg],
  aliases : Map[String, @core.Ref],
  effects : EffectScope,
  allow_effect : Bool,
  call_span : @core.Span,
) -> Unit raise TypeError {
  // Build positional prefix + variadic tail first for bidirectional inference.
  let positional : Array[@core.FuncParam] = []
  let mut variadic_param : @core.FuncParam? = None
  for param in params {
    if not(@core.ParamLabel::is_positional(param.label)) {
      continue
    }
    match param.label {
      @core.ParamLabel::Variadic =>
        match variadic_param {
          Some(_) =>
            raise TypeError::BadCall(
              message="duplicate variadic params",
              span=call_span,
            )
          None =>
            match param.ty {
              @core.Type::Array(_) => variadic_param = Some(param)
              _ =>
                raise TypeError::BadCall(
                  message="variadic param must be array type",
                  span=call_span,
                )
            }
        }
      _ =>
        if variadic_param is Some(_) {
          raise TypeError::BadCall(
            message="positional param after variadic is unsupported",
            span=call_span,
          )
        } else {
          positional.push(param)
        }
    }
  }
  let variadic_expected_ty = variadic_param.map(fn(param) {
    variadic_param_element_type(param)
  })
  // Type arguments with contextual information for lambdas
  let arg_types : Array[ArgType] = []
  let mut pos_idx = 0
  for arg in args {
    let ty = match arg.label {
      None => {
        // Positional argument - check if it's a lambda needing inference
        let expected_ty : @core.Type? = if pos_idx < positional.length() {
          let expected = positional[pos_idx].ty
          pos_idx += 1
          Some(expected)
        } else {
          variadic_expected_ty
        }
        type_arg_with_context(
          env,
          arg.expr,
          expected_ty,
          aliases,
          effects,
          allow_effect,
        )
      }
      Some(label) => {
        // Labeled argument - find expected type
        let mut expected_ty : @core.Type? = None
        for param in params {
          if not(@core.ParamLabel::is_positional(param.label)) &&
            param.name == label {
            expected_ty = Some(param.ty)
            break
          }
        }
        type_arg_with_context(
          env,
          arg.expr,
          expected_ty,
          aliases,
          effects,
          allow_effect,
        )
      }
    }
    ensure_no_scoped_ref_call_argument(env, ty, arg.span)
    arg_types.push(ArgType::{ label: arg.label, ty, span: arg.span })
  }
  // Now check types match
  let mut pos_index = 0
  let used_labels : Map[String, Bool] = {}
  for arg in arg_types {
    match arg.label {
      None => {
        let expected_ty = if pos_index < positional.length() {
          let param = positional[pos_index]
          pos_index += 1
          Some(param.ty)
        } else {
          variadic_expected_ty
        }
        match expected_ty {
          Some(param_ty) =>
            if not(type_equal(env, param_ty, arg.ty)) {
              if is_active_polymorphic_recursive_call(env, callee_name) {
                raise TypeError::BadRec(
                  message="polymorphic recursion is unsupported",
                  span=arg.span,
                )
              }
              raise TypeError::Mismatch(
                expected=argument_mismatch_expected_type(env, param_ty, arg.ty),
                actual=resolve_type(env, arg.ty),
                span=arg.span,
                context=Some("argument"),
              )
            }
          None =>
            raise TypeError::BadCall(
              message="too many positional args",
              span=arg.span,
            )
        }
      }
      Some(label) => {
        if used_labels.contains(label) {
          raise TypeError::BadCall(
            message="duplicate label: " + label,
            span=arg.span,
          )
        }
        let mut found : @core.FuncParam? = None
        for param in params {
          if not(@core.ParamLabel::is_positional(param.label)) &&
            param.name == label {
            found = Some(param)
            break
          }
        }
        match found {
          Some(param) => {
            used_labels[label] = true
            if not(type_equal(env, param.ty, arg.ty)) {
              if is_active_polymorphic_recursive_call(env, callee_name) {
                raise TypeError::BadRec(
                  message="polymorphic recursion is unsupported",
                  span=arg.span,
                )
              }
              raise TypeError::Mismatch(
                expected=argument_mismatch_expected_type(env, param.ty, arg.ty),
                actual=resolve_type(env, arg.ty),
                span=arg.span,
                context=Some("argument"),
              )
            }
          }
          None =>
            raise TypeError::BadCall(
              message="unknown label: " + label,
              span=arg.span,
            )
        }
      }
    }
  }
  if pos_index != positional.length() {
    raise TypeError::BadCall(message="missing positional args", span=call_span)
  }
  for param in params {
    if param.label == @core.ParamLabel::Required &&
      not(used_labels.contains(param.name)) {
      raise TypeError::BadCall(
        message="missing label: " + param.name,
        span=call_span,
      )
    }
  }
}

///|
fn argument_mismatch_expected_type(
  env : TypeEnv,
  expected : @core.Type,
  actual : @core.Type,
) -> @core.Type {
  let resolved_expected = resolve_type(env, expected)
  let resolved_actual = resolve_type(env, actual)
  match resolved_expected {
    @core.Type::Var(id) =>
      match env.var_trait_bounds.get(id) {
        Some(bounds) => {
          let deduped = dedup_trait_bounds(bounds)
          for bound in deduped {
            if not(type_implements_trait(env, resolved_actual, bound)) {
              return @core.Type::Named(name=bound, args=[])
            }
          }
          resolved_expected
        }
        None => resolved_expected
      }
    _ => resolved_expected
  }
}
