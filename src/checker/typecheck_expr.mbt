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
    normalize_type(env, ctor.args[0])
  } else {
    let items : Array[@core.Type] = []
    for arg in ctor.args {
      items.push(normalize_type(env, arg))
    }
    @core.Type::Tuple(items)
  }
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
    @core.Expr::Try(try_body~, catch_body~, span~) => {
      let try_scope = effect_scope_extend(effects, [
        @core.EffectAtom::Const("Error"),
      ])
      let try_ty = type_block(env, try_body, aliases, try_scope, allow_effect)
      let catch_ty = type_block(env, catch_body, aliases, effects, allow_effect)
      if not(type_equal(env, try_ty, catch_ty)) {
        raise TypeError::Mismatch(
          expected=try_ty,
          actual=catch_ty,
          span~,
          context=Some("try/catch branches"),
        )
      }
      try_ty
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
    @core.Expr::Do(body~, span~) => {
      let _ = span
      type_block(env, body, aliases, effects, true)
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
        env.set_purity(param.name, false)
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
        "raise",
      )
      require_effects(
        env,
        effects,
        [@core.EffectAtom::Const("Error")],
        "raise",
        span,
      )
      @core.Type::Never
    }
    @core.Expr::Await(expr~, span~) => {
      let inner_ty = type_expr_eff(env, expr, aliases, effects, allow_effect)
      require_effects(
        env,
        effects,
        [@core.EffectAtom::Const("Async")],
        "await",
        span,
      )
      inner_ty
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
fn is_top_wildcard(pat : @core.Pat) -> Bool {
  match pat {
    @core.Pat::Wildcard(..) => true
    @core.Pat::Bind(..) => true
    _ => false
  }
}

///|
fn collect_pattern_bindings(
  env : TypeEnv,
  pat : @core.Pat,
  scrutinee_ty : @core.Type,
) -> Map[String, @core.Type] raise TypeError {
  let out : Map[String, @core.Type] = {}
  let normalized = normalize_type(env, scrutinee_ty)
  collect_pattern_bindings_inner(env, out, pat, normalized)
  out
}

///|
fn collect_pattern_bindings_inner(
  env : TypeEnv,
  out : Map[String, @core.Type],
  pat : @core.Pat,
  scrutinee_ty : @core.Type,
) -> Unit raise TypeError {
  match pat {
    @core.Pat::Wildcard(span~) => {
      let _ = span
    }
    @core.Pat::Bind(name~, span~) => {
      if out.contains(name) {
        raise TypeError::BadMatch(message="duplicate bind: " + name, span~)
      }
      out[name] = scrutinee_ty
    }
    @core.Pat::Ctor(name~, args~, span~) =>
      match scrutinee_ty {
        @core.Type::Variant(types) =>
          match types.get(name) {
            Some(field_ty) =>
              if args.length() == 0 {
                ()
              } else if args.length() == 1 {
                collect_pattern_bindings_inner(env, out, args[0], field_ty)
              } else {
                match field_ty {
                  @core.Type::Tuple(items) =>
                    if items.length() != args.length() {
                      raise TypeError::BadMatch(message="ctor arity", span~)
                    } else {
                      for i in 0..<args.length() {
                        collect_pattern_bindings_inner(
                          env,
                          out,
                          args[i],
                          items[i],
                        )
                      }
                    }
                  _ =>
                    raise TypeError::BadMatch(
                      message="ctor expects tuple",
                      span~,
                    )
                }
              }
            None => {
              let mut closed = true
              for ctor_name, _ in types {
                if env.get_ctor(ctor_name) is None {
                  closed = false
                  break
                }
              }
              if closed {
                raise TypeError::BadMatch(
                  message="unknown ctor: " + name,
                  span~,
                )
              } else {
                for arg in args {
                  collect_pattern_bindings_loose(out, arg)
                }
              }
            }
          }
        @core.Type::Record(types) =>
          match types.get(name) {
            Some(field_ty) =>
              if args.length() == 0 {
                ()
              } else if args.length() == 1 {
                collect_pattern_bindings_inner(env, out, args[0], field_ty)
              } else {
                match field_ty {
                  @core.Type::Tuple(items) =>
                    if items.length() != args.length() {
                      raise TypeError::BadMatch(message="ctor arity", span~)
                    } else {
                      for i in 0..<args.length() {
                        collect_pattern_bindings_inner(
                          env,
                          out,
                          args[i],
                          items[i],
                        )
                      }
                    }
                  _ =>
                    raise TypeError::BadMatch(
                      message="ctor expects tuple",
                      span~,
                    )
                }
              }
            None =>
              for arg in args {
                collect_pattern_bindings_loose(out, arg)
              }
          }
        _ => raise TypeError::BadMatch(message="expected ctor variant", span~)
      }
    @core.Pat::Int(value~, span~) => {
      let _ = value
      if not(type_equal(env, scrutinee_ty, @core.Type::Int)) {
        raise TypeError::Mismatch(
          expected=@core.Type::Int,
          actual=scrutinee_ty,
          span~,
          context=Some("pattern"),
        )
      }
    }
    @core.Pat::Float(value~, span~) => {
      let _ = value
      if not(type_equal(env, scrutinee_ty, @core.Type::Float)) {
        raise TypeError::Mismatch(
          expected=@core.Type::Float,
          actual=scrutinee_ty,
          span~,
          context=Some("pattern"),
        )
      }
    }
    @core.Pat::Double(value~, span~) => {
      let _ = value
      if not(type_equal(env, scrutinee_ty, @core.Type::Double)) {
        raise TypeError::Mismatch(
          expected=@core.Type::Double,
          actual=scrutinee_ty,
          span~,
          context=Some("pattern"),
        )
      }
    }
    @core.Pat::Bool(value~, span~) => {
      let _ = value
      if not(type_equal(env, scrutinee_ty, @core.Type::Bool)) {
        raise TypeError::Mismatch(
          expected=@core.Type::Bool,
          actual=scrutinee_ty,
          span~,
          context=Some("pattern"),
        )
      }
    }
    @core.Pat::Char(value~, span~) => {
      let _ = value
      if not(type_equal(env, scrutinee_ty, @core.Type::Char)) {
        raise TypeError::Mismatch(
          expected=@core.Type::Char,
          actual=scrutinee_ty,
          span~,
          context=Some("pattern"),
        )
      }
    }
    @core.Pat::String(value~, span~) => {
      let _ = value
      if not(type_equal(env, scrutinee_ty, @core.Type::String)) {
        raise TypeError::Mismatch(
          expected=@core.Type::String,
          actual=scrutinee_ty,
          span~,
          context=Some("pattern"),
        )
      }
    }
    @core.Pat::Tuple(items~, span~) =>
      match scrutinee_ty {
        @core.Type::Tuple(types) => {
          if items.length() != types.length() {
            raise TypeError::BadMatch(message="tuple arity", span~)
          }
          for i in 0..<items.length() {
            collect_pattern_bindings_inner(env, out, items[i], types[i])
          }
        }
        _ => raise TypeError::BadMatch(message="expected tuple", span~)
      }
    @core.Pat::Record(fields~, span~) =>
      match scrutinee_ty {
        @core.Type::Record(types) =>
          for field in fields {
            match types.get(field.name) {
              Some(field_ty) =>
                collect_pattern_bindings_inner(env, out, field.pat, field_ty)
              None =>
                raise TypeError::BadMatch(
                  message="missing field: " + field.name,
                  span=field.span,
                )
            }
          }
        _ => raise TypeError::BadMatch(message="expected record", span~)
      }
    @core.Pat::Struct(name=struct_name, fields~, span~) =>
      match env.get_struct(struct_name) {
        Some(struct_def) => {
          // Create type argument mapping from scrutinee type
          let type_map : Map[String, @core.Type] = {}
          match scrutinee_ty {
            @core.Type::Named(args~, ..) =>
              for i, param in struct_def.params {
                if i < args.length() {
                  type_map[param] = args[i]
                }
              }
            _ => ()
          }
          for field in fields {
            match struct_def.get_field(field.name) {
              Some(field_def) => {
                let field_ty = substitute_type_params_by_name(
                  field_def.ty,
                  type_map,
                )
                collect_pattern_bindings_inner(env, out, field.pat, field_ty)
              }
              None =>
                raise TypeError::BadMatch(
                  message="struct " +
                    struct_name +
                    " has no field: " +
                    field.name,
                  span=field.span,
                )
            }
          }
        }
        None =>
          raise TypeError::BadMatch(
            message="unknown struct: " + struct_name,
            span~,
          )
      }
    @core.Pat::Or(pats~, span~) => {
      let _ = span
      for p in pats {
        collect_pattern_bindings_inner(env, out, p, scrutinee_ty)
      }
    }
  }
}

///|
fn collect_pattern_bindings_loose(
  out : Map[String, @core.Type],
  pat : @core.Pat,
) -> Unit raise TypeError {
  match pat {
    @core.Pat::Wildcard(span~) => {
      let _ = span
    }
    @core.Pat::Bind(name~, span~) => {
      if out.contains(name) {
        raise TypeError::BadMatch(message="duplicate bind: " + name, span~)
      }
      out[name] = @core.Type::Unit
    }
    @core.Pat::Ctor(name~, args~, span~) => {
      let _ = name
      let _ = span
      for arg in args {
        collect_pattern_bindings_loose(out, arg)
      }
    }
    @core.Pat::Tuple(items~, span~) => {
      let _ = span
      for item in items {
        collect_pattern_bindings_loose(out, item)
      }
    }
    @core.Pat::Record(fields~, span~) => {
      let _ = span
      for field in fields {
        collect_pattern_bindings_loose(out, field.pat)
      }
    }
    @core.Pat::Struct(name~, fields~, span~) => {
      let _ = name
      let _ = span
      for field in fields {
        collect_pattern_bindings_loose(out, field.pat)
      }
    }
    @core.Pat::Int(value~, span~) => {
      let _ = value
      let _ = span
    }
    @core.Pat::Float(value~, span~) => {
      let _ = value
      let _ = span
    }
    @core.Pat::Double(value~, span~) => {
      let _ = value
      let _ = span
    }
    @core.Pat::Bool(value~, span~) => {
      let _ = value
      let _ = span
    }
    @core.Pat::Char(value~, span~) => {
      let _ = value
      let _ = span
    }
    @core.Pat::String(value~, span~) => {
      let _ = value
      let _ = span
    }
    @core.Pat::Or(pats~, span~) => {
      let _ = span
      for p in pats {
        collect_pattern_bindings_loose(out, p)
      }
    }
  }
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
      @core.Stmt::ExportLet(rec~, name~, expr~, span~) => {
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
      @core.Stmt::ExportTypeAlias(name~, params~, target~, span~) => {
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
        scope_env.set_purity(name, false)
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
          scope_env.set_purity(name, true)
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
          scope_env.set_purity(name, false)
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
    }
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
fn variant_namespace_root_from_type(
  env : TypeEnv,
  fields : Map[String, @core.Type],
) -> String? {
  let mut found : String? = None
  for enum_name in env.enum_names() {
    match env.get_enum_def(enum_name) {
      Some(enum_def) => {
        if enum_def.ctors.length() != fields.length() {
          continue
        }
        let mut all_match = true
        for ctor in enum_def.ctors {
          if not(fields.contains(ctor.name)) {
            all_match = false
            break
          }
        }
        if all_match {
          match found {
            None => found = Some(enum_name)
            Some(_) => return None
          }
        }
      }
      None => ()
    }
  }
  found
}

///|
fn namespace_root_from_type(env : TypeEnv, ty : @core.Type) -> String? {
  match resolve_type(env, ty) {
    @core.Type::Int => Some("Int")
    @core.Type::Float => Some("Float")
    @core.Type::Double => Some("Double")
    @core.Type::Bool => Some("Bool")
    @core.Type::Char => Some("Char")
    @core.Type::String => Some("String")
    @core.Type::Path => Some("Path")
    @core.Type::Named(name~, ..) => Some(name)
    @core.Type::Variant(fields) => variant_namespace_root_from_type(env, fields)
    _ => None
  }
}

///|
fn resolve_type_member_call_name(
  env : TypeEnv,
  name : String,
  args : Array[@core.CallArg],
  aliases : Map[String, @core.Ref],
  effects : EffectScope,
  allow_effect : Bool,
  call_span : @core.Span,
) -> String? raise TypeError {
  if name.contains("::") || name.contains(".") {
    return None
  }
  let _ = call_span
  let mut recv_expr : @core.Expr? = None
  for arg in args {
    match arg.label {
      Some(_) => ()
      None => if recv_expr is None { recv_expr = Some(arg.expr) }
    }
  }
  match recv_expr {
    None => return None
    Some(expr) => {
      let recv_ty = type_expr_eff(env, expr, aliases, effects, allow_effect)
      match namespace_root_from_type(env, recv_ty) {
        Some(root) => {
          let candidate = root + "::" + name
          match env.get(candidate) {
            Some(_) => Some(candidate)
            None => None
          }
        }
        None => None
      }
    }
  }
}

///|
fn is_postfix_property_call_shape(
  args : Array[@core.CallArg],
  name : String,
  call_span : @core.Span,
) -> Bool {
  let pos_args = extract_positional_args(args, name, call_span) catch {
    _ => return false
  }
  if pos_args.length() != 1 {
    return false
  }
  let recv_span = pos_args[0].span()
  recv_span.start == call_span.start && recv_span.end < call_span.end
}

///|
fn summarize_type_error_for_candidate(err : TypeError) -> String {
  match err {
    TypeError::UnknownName(name~, ..) => "unknown name: " + name
    TypeError::UnknownType(name~, ..) => "unknown type: " + name
    TypeError::DuplicateDecl(name~, ..) => "duplicate declaration: " + name
    TypeError::Mismatch(expected~, actual~, context~, ..) =>
      match context {
        Some(ctx) =>
          "type mismatch (" +
          ctx +
          "): expected " +
          expected.to_string() +
          ", actual " +
          actual.to_string()
        None =>
          "type mismatch: expected " +
          expected.to_string() +
          ", actual " +
          actual.to_string()
      }
    TypeError::BadCall(message~, ..) => format_bad_call(message)
    TypeError::PropertyAccessAmbiguous(function_error~, ..) => function_error
    TypeError::BadRec(message~, ..) => format_bad_rec(message)
    TypeError::BadMatch(message~, ..) => format_bad_match(message)
    TypeError::NonExhaustiveMatch(..) => "non-exhaustive match"
    TypeError::BadTypeDef(message~, ..) => "type definition: " + message
    TypeError::TraitSealed(trait_name~, ..) =>
      "[TROP001] trait is sealed: " + trait_name
    TypeError::TraitImplOverlap(trait_name~, ..) =>
      "[TROP003] overlapping impl: " + trait_name
    TypeError::EffectGuardNotSatisfied(
      operation~,
      missing_effect~,
      missing_do_boundary~,
      ..
    ) => {
      let mut detail = "effect requirements not satisfied: `" + operation + "`"
      match missing_effect {
        Some(effect_name) =>
          detail = detail + " (missing effect `" + effect_name + "`)"
        None => ()
      }
      if missing_do_boundary {
        detail = detail + " (missing do boundary)"
      }
      detail
    }
  }
}

///|
fn maybe_raise_property_access_ambiguity(
  env : TypeEnv,
  property_name : String,
  function_name : String,
  args : Array[@core.CallArg],
  aliases : Map[String, @core.Ref],
  effects : EffectScope,
  allow_effect : Bool,
  call_span : @core.Span,
  cause : TypeError,
) -> Unit raise TypeError {
  if is_postfix_property_call_shape(args, property_name, call_span) {
    let field_candidate = try_field_access(
      env, property_name, args, aliases, effects, allow_effect, call_span,
    ) catch {
      _ => None
    }
    match field_candidate {
      Some(field_ty) =>
        raise TypeError::PropertyAccessAmbiguous(
          property_name~,
          function_name~,
          function_error=summarize_type_error_for_candidate(cause),
          field_type=field_ty,
          span=call_span,
        )
      None => ()
    }
  }
  raise cause
}

///|
fn type_call(
  env : TypeEnv,
  name : String,
  args : Array[@core.CallArg],
  aliases : Map[String, @core.Ref],
  effects : EffectScope,
  allow_effect : Bool,
  call_span : @core.Span,
) -> @core.Type raise TypeError {
  let lookup_name = match
    resolve_type_member_call_name(
      env, name, args, aliases, effects, allow_effect, call_span,
    ) {
    Some(candidate) => candidate
    None => name
  }
  match env.get(lookup_name) {
    Some(ty) =>
      match ty {
        @core.Type::Func(params~, ret~, effects=fn_effects) => {
          check_call_args(
            env, lookup_name, params, args, aliases, effects, allow_effect, call_span,
          ) catch {
            err =>
              maybe_raise_property_access_ambiguity(
                env, name, lookup_name, args, aliases, effects, allow_effect, call_span,
                err,
              )
          }
          require_effects(env, effects, fn_effects, lookup_name, call_span) catch {
            err =>
              maybe_raise_property_access_ambiguity(
                env, name, lookup_name, args, aliases, effects, allow_effect, call_span,
                err,
              )
          }
          ret
        }
        _ =>
          // Name exists but isn't a function - try field access first
          match
            try_field_access(
              env, lookup_name, args, aliases, effects, allow_effect, call_span,
            ) {
            Some(field_ty) => field_ty
            None =>
              raise TypeError::BadCall(message=lookup_name, span=call_span)
          }
      }
    None =>
      match env.get_ctor(name) {
        Some(info) => {
          let pos_args = extract_positional_args(args, name, call_span)
          let inst = instantiate_ctor(env, info)
          match inst.payload {
            @core.Type::Unit =>
              if pos_args.length() != 0 {
                raise TypeError::BadCall(message=name, span=call_span)
              }
            @core.Type::Tuple(items) =>
              if pos_args.length() != items.length() {
                raise TypeError::BadCall(message=name, span=call_span)
              } else {
                for i in 0..<items.length() {
                  let arg_ty = type_expr_eff(
                    env,
                    pos_args[i],
                    aliases,
                    effects,
                    allow_effect,
                  )
                  if not(type_equal(env, arg_ty, items[i])) {
                    raise TypeError::Mismatch(
                      expected=items[i],
                      actual=arg_ty,
                      span=pos_args[i].span(),
                      context=Some("ctor argument"),
                    )
                  }
                }
              }
            _ =>
              if pos_args.length() != 1 {
                raise TypeError::BadCall(message=name, span=call_span)
              } else {
                let arg_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, arg_ty, inst.payload)) {
                  raise TypeError::Mismatch(
                    expected=inst.payload,
                    actual=arg_ty,
                    span=pos_args[0].span(),
                    context=Some("ctor argument"),
                  )
                }
              }
          }
          inst.ret
        }
        None =>
          if @core.is_ctor_name(name) {
            let pos_args = extract_positional_args(args, name, call_span)
            let field_ty = if pos_args.length() == 0 {
              @core.Type::Unit
            } else if pos_args.length() == 1 {
              type_expr_eff(env, pos_args[0], aliases, effects, allow_effect)
            } else {
              let tys : Array[@core.Type] = []
              for arg in pos_args {
                tys.push(
                  type_expr_eff(env, arg, aliases, effects, allow_effect),
                )
              }
              @core.Type::Tuple(tys)
            }
            let map : Map[String, @core.Type] = {}
            map[name] = field_ty
            @core.Type::Variant(map)
          } else {
            let builtin_name = @core.lower_wasm_intrinsic_name(name)
            match builtin_name {
              "path" | "path_ref" => {
                let builtin_name = name
                let pos_args = extract_positional_args(
                  args, builtin_name, call_span,
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(message=builtin_name, span=call_span)
                }
                let arg_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, arg_ty, @core.Type::String)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::String,
                    actual=arg_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Path
              }
              "path_to_string" => {
                let pos_args = extract_positional_args(
                  args, "path_to_string", call_span,
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(
                    message="path_to_string",
                    span=call_span,
                  )
                }
                let arg_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, arg_ty, @core.Type::Path)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Path,
                    actual=arg_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::String
              }
              "path_is_absolute" => {
                let pos_args = extract_positional_args(
                  args, "path_is_absolute", call_span,
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(
                    message="path_is_absolute",
                    span=call_span,
                  )
                }
                let arg_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, arg_ty, @core.Type::Path)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Path,
                    actual=arg_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Bool
              }
              "dynamic_path_resolve" => {
                let pos_args = extract_positional_args(
                  args, "dynamic_path_resolve", call_span,
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(
                    message="dynamic_path_resolve",
                    span=call_span,
                  )
                }
                require_effect_guard(
                  env,
                  effects,
                  allow_effect,
                  "dynamic_path_resolve",
                  builtin_effects("dynamic_path_resolve"),
                  call_span,
                )
                let arg_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, arg_ty, @core.Type::String)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::String,
                    actual=arg_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Path
              }
              "addr" => {
                let pos_args = extract_positional_args(args, "addr", call_span)
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(message="addr", span=call_span)
                }
                match pos_args[0] {
                  @core.Expr::String(value=s, span~) =>
                    match env.get_addr_type(s) {
                      Some(ty) => ty
                      None =>
                        raise TypeError::UnknownName(
                          name="addr:" + s,
                          span~,
                          suggestion=None,
                        )
                    }
                  _ => raise TypeError::BadCall(message="addr", span=call_span)
                }
              }
              "sh" => {
                let pos_args = extract_positional_args(args, "sh", call_span)
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(message="sh", span=call_span)
                }
                require_effect_guard(
                  env,
                  effects,
                  allow_effect,
                  "sh",
                  builtin_effects("sh"),
                  call_span,
                )
                let arg_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, arg_ty, @core.Type::String)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::String,
                    actual=arg_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Unit
              }
              "sh_lines" => {
                let pos_args = extract_positional_args(
                  args, "sh_lines", call_span,
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(message="sh_lines", span=call_span)
                }
                require_effect_guard(
                  env,
                  effects,
                  allow_effect,
                  "sh_lines",
                  builtin_effects("sh_lines"),
                  call_span,
                )
                let arg_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, arg_ty, @core.Type::String)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::String,
                    actual=arg_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Array(@core.Type::String)
              }
              "sleep" => {
                let pos_args = extract_positional_args(args, "sleep", call_span)
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(message="sleep", span=call_span)
                }
                require_effect_guard(
                  env,
                  effects,
                  allow_effect,
                  "sleep",
                  builtin_effects("sleep"),
                  call_span,
                )
                let arg_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, arg_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=arg_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Unit
              }
              "threads_probe_wat" => {
                let pos_args = extract_positional_args(
                  args, "threads_probe_wat", call_span,
                )
                if pos_args.length() != 0 {
                  raise TypeError::BadCall(
                    message="threads_probe_wat",
                    span=call_span,
                  )
                }
                @core.Type::String
              }
              "threads_runtime_hints" => {
                let pos_args = extract_positional_args(
                  args, "threads_runtime_hints", call_span,
                )
                if pos_args.length() != 0 {
                  raise TypeError::BadCall(
                    message="threads_runtime_hints",
                    span=call_span,
                  )
                }
                let fields : Map[String, @core.Type] = {}
                fields["wasm_flags"] = @core.Type::Array(@core.Type::String)
                fields["wasi_flags"] = @core.Type::Array(@core.Type::String)
                fields["wasm_env"] = @core.Type::String
                fields["wasi_env"] = @core.Type::String
                @core.Type::Record(fields)
              }
              "threads_channel_new" => {
                let pos_args = extract_positional_args(
                  args, "threads_channel_new", call_span,
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(
                    message="threads_channel_new",
                    span=call_span,
                  )
                }
                let cap_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, cap_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=cap_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Int
              }
              "threads_send" => {
                let pos_args = extract_positional_args(
                  args, "threads_send", call_span,
                )
                if pos_args.length() != 2 {
                  raise TypeError::BadCall(
                    message="threads_send",
                    span=call_span,
                  )
                }
                let channel_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, channel_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=channel_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                let message_ty = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, message_ty, @core.Type::String)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::String,
                    actual=message_ty,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Bool
              }
              "threads_recv" => {
                let pos_args = extract_positional_args(
                  args, "threads_recv", call_span,
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(
                    message="threads_recv",
                    span=call_span,
                  )
                }
                let channel_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, channel_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=channel_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::String
              }
              "threads_spawn" => {
                let pos_args = extract_positional_args(
                  args, "threads_spawn", call_span,
                )
                if pos_args.length() != 2 {
                  raise TypeError::BadCall(
                    message="threads_spawn",
                    span=call_span,
                  )
                }
                let name_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, name_ty, @core.Type::String)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::String,
                    actual=name_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                let mailbox_ty = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, mailbox_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=mailbox_ty,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Int
              }
              "threads_wait" => {
                let pos_args = extract_positional_args(
                  args, "threads_wait", call_span,
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(
                    message="threads_wait",
                    span=call_span,
                  )
                }
                let task_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, task_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=task_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Int
              }
              "stdout_write_char" => {
                let pos_args = extract_positional_args(
                  args, "stdout_write_char", call_span,
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(
                    message="stdout_write_char",
                    span=call_span,
                  )
                }
                require_effect_guard(
                  env,
                  effects,
                  allow_effect,
                  "stdout_write_char",
                  builtin_effects("stdout_write_char"),
                  call_span,
                )
                let arg_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, arg_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=arg_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Unit
              }
              "stdin_read_char" => {
                let pos_args = extract_positional_args(
                  args, "stdin_read_char", call_span,
                )
                if pos_args.length() != 0 {
                  raise TypeError::BadCall(
                    message="stdin_read_char",
                    span=call_span,
                  )
                }
                require_effect_guard(
                  env,
                  effects,
                  allow_effect,
                  "stdin_read_char",
                  builtin_effects("stdin_read_char"),
                  call_span,
                )
                @core.Type::Int
              }
              "stdout_write_stream" => {
                let pos_args = extract_positional_args(
                  args, "stdout_write_stream", call_span,
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(
                    message="stdout_write_stream",
                    span=call_span,
                  )
                }
                require_effect_guard(
                  env,
                  effects,
                  allow_effect,
                  "stdout_write_stream",
                  builtin_effects("stdout_write_stream"),
                  call_span,
                )
                let arg_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, arg_ty, @core.Type::String)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::String,
                    actual=arg_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Unit
              }
              "stdin_read_stream" => {
                let pos_args = extract_positional_args(
                  args, "stdin_read_stream", call_span,
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(
                    message="stdin_read_stream",
                    span=call_span,
                  )
                }
                require_effect_guard(
                  env,
                  effects,
                  allow_effect,
                  "stdin_read_stream",
                  builtin_effects("stdin_read_stream"),
                  call_span,
                )
                let arg_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, arg_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=arg_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::String
              }
              "string_from_char_code" => {
                let pos_args = extract_positional_args(
                  args, "string_from_char_code", call_span,
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(
                    message="string_from_char_code",
                    span=call_span,
                  )
                }
                let arg_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, arg_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=arg_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::String
              }
              "char_to_int" => {
                let pos_args = extract_positional_args(
                  args, "char_to_int", call_span,
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(
                    message="char_to_int",
                    span=call_span,
                  )
                }
                let arg_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, arg_ty, @core.Type::Char)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Char,
                    actual=arg_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Int
              }
              "char_from_int" => {
                let pos_args = extract_positional_args(
                  args, "char_from_int", call_span,
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(
                    message="char_from_int",
                    span=call_span,
                  )
                }
                let arg_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, arg_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=arg_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Char
              }
              "string_builder" => {
                let pos_args = extract_positional_args(
                  args, "string_builder", call_span,
                )
                if pos_args.length() != 0 {
                  raise TypeError::BadCall(
                    message="string_builder",
                    span=call_span,
                  )
                }
                require_effect_guard(
                  env,
                  effects,
                  allow_effect,
                  "string_builder",
                  [],
                  call_span,
                )
                @core.Type::StringBuilder
              }
              "string_builder_push" => {
                let pos_args = extract_positional_args(
                  args, "string_builder_push", call_span,
                )
                if pos_args.length() != 2 {
                  raise TypeError::BadCall(
                    message="string_builder_push",
                    span=call_span,
                  )
                }
                require_effect_guard(
                  env,
                  effects,
                  allow_effect,
                  "string_builder_push",
                  [],
                  call_span,
                )
                let builder_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                let value_ty = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, builder_ty, @core.Type::StringBuilder)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::StringBuilder,
                    actual=builder_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                if not(type_equal(env, value_ty, @core.Type::String)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::String,
                    actual=value_ty,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Unit
              }
              "string_builder_freeze" => {
                let pos_args = extract_positional_args(
                  args, "string_builder_freeze", call_span,
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(
                    message="string_builder_freeze",
                    span=call_span,
                  )
                }
                require_effect_guard(
                  env,
                  effects,
                  allow_effect,
                  "string_builder_freeze",
                  [],
                  call_span,
                )
                let builder_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, builder_ty, @core.Type::StringBuilder)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::StringBuilder,
                    actual=builder_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::String
              }
              "array_builder" => {
                let pos_args = extract_positional_args(
                  args, "array_builder", call_span,
                )
                if pos_args.length() != 0 {
                  raise TypeError::BadCall(
                    message="array_builder",
                    span=call_span,
                  )
                }
                require_effect_guard(
                  env,
                  effects,
                  allow_effect,
                  "array_builder",
                  [],
                  call_span,
                )
                let elem = fresh_type_var(env)
                @core.Type::ArrayBuilder(elem)
              }
              "array_builder_push" => {
                let pos_args = extract_positional_args(
                  args, "array_builder_push", call_span,
                )
                if pos_args.length() != 2 {
                  raise TypeError::BadCall(
                    message="array_builder_push",
                    span=call_span,
                  )
                }
                require_effect_guard(
                  env,
                  effects,
                  allow_effect,
                  "array_builder_push",
                  [],
                  call_span,
                )
                let builder_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                let value_ty = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                let elem_ty = fresh_type_var(env)
                if not(
                    type_equal(
                      env,
                      builder_ty,
                      @core.Type::ArrayBuilder(elem_ty),
                    ),
                  ) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::ArrayBuilder(elem_ty),
                    actual=builder_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                if not(type_equal(env, value_ty, elem_ty)) {
                  raise TypeError::Mismatch(
                    expected=elem_ty,
                    actual=value_ty,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Unit
              }
              "array_builder_freeze" => {
                let pos_args = extract_positional_args(
                  args, "array_builder_freeze", call_span,
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(
                    message="array_builder_freeze",
                    span=call_span,
                  )
                }
                require_effect_guard(
                  env,
                  effects,
                  allow_effect,
                  "array_builder_freeze",
                  [],
                  call_span,
                )
                let builder_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                let elem_ty = fresh_type_var(env)
                if not(
                    type_equal(
                      env,
                      builder_ty,
                      @core.Type::ArrayBuilder(elem_ty),
                    ),
                  ) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::ArrayBuilder(elem_ty),
                    actual=builder_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Array(elem_ty)
              }
              "map_builder" => {
                let pos_args = extract_positional_args(
                  args, "map_builder", call_span,
                )
                if pos_args.length() != 0 {
                  raise TypeError::BadCall(
                    message="map_builder",
                    span=call_span,
                  )
                }
                require_effect_guard(
                  env,
                  effects,
                  allow_effect,
                  "map_builder",
                  [],
                  call_span,
                )
                let value = fresh_type_var(env)
                @core.Type::MapBuilder(value)
              }
              "map_builder_set" => {
                let pos_args = extract_positional_args(
                  args, "map_builder_set", call_span,
                )
                if pos_args.length() != 3 {
                  raise TypeError::BadCall(
                    message="map_builder_set",
                    span=call_span,
                  )
                }
                require_effect_guard(
                  env,
                  effects,
                  allow_effect,
                  "map_builder_set",
                  [],
                  call_span,
                )
                let builder_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                let key_ty = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                let value_ty = type_expr_eff(
                  env,
                  pos_args[2],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, key_ty, @core.Type::String)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::String,
                    actual=key_ty,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                let elem_ty = fresh_type_var(env)
                if not(
                    type_equal(env, builder_ty, @core.Type::MapBuilder(elem_ty)),
                  ) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::MapBuilder(elem_ty),
                    actual=builder_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                if not(type_equal(env, value_ty, elem_ty)) {
                  raise TypeError::Mismatch(
                    expected=elem_ty,
                    actual=value_ty,
                    span=pos_args[2].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Unit
              }
              "map_builder_freeze" => {
                let pos_args = extract_positional_args(
                  args, "map_builder_freeze", call_span,
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(
                    message="map_builder_freeze",
                    span=call_span,
                  )
                }
                require_effect_guard(
                  env,
                  effects,
                  allow_effect,
                  "map_builder_freeze",
                  [],
                  call_span,
                )
                let builder_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                let elem_ty = fresh_type_var(env)
                if not(
                    type_equal(env, builder_ty, @core.Type::MapBuilder(elem_ty)),
                  ) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::MapBuilder(elem_ty),
                    actual=builder_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Map(elem_ty)
              }
              "array_length" => {
                let pos_args = extract_positional_args(
                  args, "array_length", call_span,
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(
                    message="array_length",
                    span=call_span,
                  )
                }
                let array_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                let elem_ty = fresh_type_var(env)
                if not(type_equal(env, array_ty, @core.Type::Array(elem_ty))) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Array(elem_ty),
                    actual=array_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Int
              }
              "array_get" => {
                let pos_args = extract_positional_args(
                  args, "array_get", call_span,
                )
                if pos_args.length() != 2 {
                  raise TypeError::BadCall(message="array_get", span=call_span)
                }
                let array_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                let index_ty = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, index_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=index_ty,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                let elem_ty = fresh_type_var(env)
                if not(type_equal(env, array_ty, @core.Type::Array(elem_ty))) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Array(elem_ty),
                    actual=array_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                elem_ty
              }
              "map_get" => {
                let pos_args = extract_positional_args(
                  args, "map_get", call_span,
                )
                if pos_args.length() != 2 {
                  raise TypeError::BadCall(message="map_get", span=call_span)
                }
                let map_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                let key_ty = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, key_ty, @core.Type::String)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::String,
                    actual=key_ty,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                let elem_ty = fresh_type_var(env)
                if not(type_equal(env, map_ty, @core.Type::Map(elem_ty))) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Map(elem_ty),
                    actual=map_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                elem_ty
              }
              "string_length" => {
                let pos_args = extract_positional_args(
                  args, "string_length", call_span,
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(
                    message="string_length",
                    span=call_span,
                  )
                }
                let arg_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, arg_ty, @core.Type::String)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::String,
                    actual=arg_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Int
              }
              "string_utf8_length" => {
                let pos_args = extract_positional_args(
                  args, "string_utf8_length", call_span,
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(
                    message="string_utf8_length",
                    span=call_span,
                  )
                }
                let arg_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, arg_ty, @core.Type::String)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::String,
                    actual=arg_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Int
              }
              "string_utf16_length" => {
                let pos_args = extract_positional_args(
                  args, "string_utf16_length", call_span,
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(
                    message="string_utf16_length",
                    span=call_span,
                  )
                }
                let arg_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, arg_ty, @core.Type::String)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::String,
                    actual=arg_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Int
              }
              "string_unicode_length" => {
                let pos_args = extract_positional_args(
                  args, "string_unicode_length", call_span,
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(
                    message="string_unicode_length",
                    span=call_span,
                  )
                }
                let arg_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, arg_ty, @core.Type::String)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::String,
                    actual=arg_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Int
              }
              "string_char_code_at" => {
                let pos_args = extract_positional_args(
                  args, "string_char_code_at", call_span,
                )
                if pos_args.length() != 2 {
                  raise TypeError::BadCall(
                    message="string_char_code_at",
                    span=call_span,
                  )
                }
                let str_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                let index_ty = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, str_ty, @core.Type::String)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::String,
                    actual=str_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                if not(type_equal(env, index_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=index_ty,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Int
              }
              "string_substring" => {
                let pos_args = extract_positional_args(
                  args, "string_substring", call_span,
                )
                if pos_args.length() != 3 {
                  raise TypeError::BadCall(
                    message="string_substring",
                    span=call_span,
                  )
                }
                let str_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                let start_ty = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                let end_ty = type_expr_eff(
                  env,
                  pos_args[2],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, str_ty, @core.Type::String)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::String,
                    actual=str_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                if not(type_equal(env, start_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=start_ty,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                if not(type_equal(env, end_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=end_ty,
                    span=pos_args[2].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::String
              }
              "string_concat" => {
                let pos_args = extract_positional_args(
                  args, "string_concat", call_span,
                )
                if pos_args.length() != 2 {
                  raise TypeError::BadCall(
                    message="string_concat",
                    span=call_span,
                  )
                }
                let left_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                let right_ty = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, left_ty, @core.Type::String)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::String,
                    actual=left_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                if not(type_equal(env, right_ty, @core.Type::String)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::String,
                    actual=right_ty,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::String
              }
              "string_equals" => {
                let pos_args = extract_positional_args(
                  args, "string_equals", call_span,
                )
                if pos_args.length() != 2 {
                  raise TypeError::BadCall(
                    message="string_equals",
                    span=call_span,
                  )
                }
                let left_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                let right_ty = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, left_ty, @core.Type::String)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::String,
                    actual=left_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                if not(type_equal(env, right_ty, @core.Type::String)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::String,
                    actual=right_ty,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Bool
              }
              "string_split" => {
                let pos_args = extract_positional_args(
                  args, "string_split", call_span,
                )
                if pos_args.length() != 2 {
                  raise TypeError::BadCall(
                    message="string_split",
                    span=call_span,
                  )
                }
                let str_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                let sep_ty = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, str_ty, @core.Type::String)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::String,
                    actual=str_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                if not(type_equal(env, sep_ty, @core.Type::String)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::String,
                    actual=sep_ty,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Array(@core.Type::String)
              }
              "string_index_of" => {
                let pos_args = extract_positional_args(
                  args, "string_index_of", call_span,
                )
                if pos_args.length() != 2 {
                  raise TypeError::BadCall(
                    message="string_index_of",
                    span=call_span,
                  )
                }
                let str_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                let sub_ty = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, str_ty, @core.Type::String)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::String,
                    actual=str_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                if not(type_equal(env, sub_ty, @core.Type::String)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::String,
                    actual=sub_ty,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Int
              }
              "string_contains" => {
                let pos_args = extract_positional_args(
                  args, "string_contains", call_span,
                )
                if pos_args.length() != 2 {
                  raise TypeError::BadCall(
                    message="string_contains",
                    span=call_span,
                  )
                }
                let str_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                let sub_ty = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, str_ty, @core.Type::String)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::String,
                    actual=str_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                if not(type_equal(env, sub_ty, @core.Type::String)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::String,
                    actual=sub_ty,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Bool
              }
              "string_trim" => {
                let pos_args = extract_positional_args(
                  args, "string_trim", call_span,
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(
                    message="string_trim",
                    span=call_span,
                  )
                }
                let arg_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, arg_ty, @core.Type::String)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::String,
                    actual=arg_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::String
              }
              "__add" => {
                let pos_args = extract_positional_args(args, "__add", call_span)
                if pos_args.length() != 2 {
                  raise TypeError::BadCall(message="__add", span=call_span)
                }
                let a = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                let b = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                ensure_num_operand(env, a, pos_args[0].span())
                if not(type_equal(env, b, a)) {
                  raise TypeError::Mismatch(
                    expected=a,
                    actual=b,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                a
              }
              "__sub" => {
                let pos_args = extract_positional_args(args, "__sub", call_span)
                if pos_args.length() != 2 {
                  raise TypeError::BadCall(message="__sub", span=call_span)
                }
                let a = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                let b = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                ensure_num_operand(env, a, pos_args[0].span())
                if not(type_equal(env, b, a)) {
                  raise TypeError::Mismatch(
                    expected=a,
                    actual=b,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                a
              }
              "__mul" => {
                let pos_args = extract_positional_args(args, "__mul", call_span)
                if pos_args.length() != 2 {
                  raise TypeError::BadCall(message="__mul", span=call_span)
                }
                let a = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                let b = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                ensure_num_operand(env, a, pos_args[0].span())
                if not(type_equal(env, b, a)) {
                  raise TypeError::Mismatch(
                    expected=a,
                    actual=b,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                a
              }
              "__div" | "__mod" => {
                let pos_args = extract_positional_args(args, name, call_span)
                if pos_args.length() != 2 {
                  raise TypeError::BadCall(message=name, span=call_span)
                }
                let a = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                let b = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                ensure_num_operand(env, a, pos_args[0].span())
                if not(type_equal(env, b, a)) {
                  raise TypeError::Mismatch(
                    expected=a,
                    actual=b,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                a
              }
              "__lshift"
              | "__rshift"
              | "__bit_and"
              | "__bit_or"
              | "__bit_xor" => {
                let pos_args = extract_positional_args(args, name, call_span)
                if pos_args.length() != 2 {
                  raise TypeError::BadCall(message=name, span=call_span)
                }
                let a = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                let b = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, a, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=a,
                    span=pos_args[0].span(),
                    context=Some("bit operation"),
                  )
                }
                if not(type_equal(env, b, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=b,
                    span=pos_args[1].span(),
                    context=Some("bit operation"),
                  )
                }
                @core.Type::Int
              }
              "i32_eqz" =>
                type_check_unary_convert(
                  env,
                  args,
                  call_span,
                  aliases,
                  effects,
                  allow_effect,
                  "i32_eqz",
                  @core.Type::Int,
                  @core.Type::Int,
                )
              "i32_eq"
              | "i32_ne"
              | "i32_lt_s"
              | "i32_le_s"
              | "i32_gt_s"
              | "i32_ge_s" =>
                type_check_binary_exact(
                  env,
                  args,
                  call_span,
                  aliases,
                  effects,
                  allow_effect,
                  builtin_name,
                  @core.Type::Int,
                  @core.Type::Int,
                  @core.Type::Int,
                )
              "f32_eq" | "f32_ne" | "f32_lt" | "f32_le" | "f32_gt" | "f32_ge" =>
                type_check_binary_exact(
                  env,
                  args,
                  call_span,
                  aliases,
                  effects,
                  allow_effect,
                  builtin_name,
                  @core.Type::Float,
                  @core.Type::Float,
                  @core.Type::Int,
                )
              "f64_eq" | "f64_ne" | "f64_lt" | "f64_le" | "f64_gt" | "f64_ge" =>
                type_check_binary_exact(
                  env,
                  args,
                  call_span,
                  aliases,
                  effects,
                  allow_effect,
                  builtin_name,
                  @core.Type::Double,
                  @core.Type::Double,
                  @core.Type::Int,
                )
              "anyref_eq"
              | "eqref_eq"
              | "i31ref_eq"
              | "structref_eq"
              | "arrayref_eq"
              | "funcref_eq"
              | "externref_eq" => {
                let ref_name = match
                  @core.wasm_gc_ref_eq_type_name(builtin_name) {
                  Some(t) => t
                  None =>
                    raise TypeError::BadCall(
                      message=builtin_name,
                      span=call_span,
                    )
                }
                type_check_binary_exact(
                  env,
                  args,
                  call_span,
                  aliases,
                  effects,
                  allow_effect,
                  builtin_name,
                  @core.Type::Named(name=ref_name, args=[]),
                  @core.Type::Named(name=ref_name, args=[]),
                  @core.Type::Int,
                )
              }
              "__index" => {
                let pos_args = extract_positional_args(
                  args, "__index", call_span,
                )
                if pos_args.length() != 2 {
                  raise TypeError::BadCall(message="__index", span=call_span)
                }
                let container_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                let index_ty = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                let elem_ty = fresh_type_var(env)
                match container_ty {
                  @core.Type::Array(_) => {
                    if not(type_equal(env, index_ty, @core.Type::Int)) {
                      raise TypeError::Mismatch(
                        expected=@core.Type::Int,
                        actual=index_ty,
                        span=pos_args[1].span(),
                        context=Some("index"),
                      )
                    }
                    if not(
                        type_equal(
                          env,
                          container_ty,
                          @core.Type::Array(elem_ty),
                        ),
                      ) {
                      raise TypeError::Mismatch(
                        expected=@core.Type::Array(elem_ty),
                        actual=container_ty,
                        span=pos_args[0].span(),
                        context=Some("argument"),
                      )
                    }
                    elem_ty
                  }
                  @core.Type::Map(_) => {
                    if not(type_equal(env, index_ty, @core.Type::String)) {
                      raise TypeError::Mismatch(
                        expected=@core.Type::String,
                        actual=index_ty,
                        span=pos_args[1].span(),
                        context=Some("index"),
                      )
                    }
                    if not(
                        type_equal(env, container_ty, @core.Type::Map(elem_ty)),
                      ) {
                      raise TypeError::Mismatch(
                        expected=@core.Type::Map(elem_ty),
                        actual=container_ty,
                        span=pos_args[0].span(),
                        context=Some("argument"),
                      )
                    }
                    elem_ty
                  }
                  _ => {
                    let _ = index_ty
                    let _ = elem_ty
                    raise TypeError::BadCall(
                      message="__index: not indexable",
                      span=call_span,
                    )
                  }
                }
              }
              "__eq" => {
                let pos_args = extract_positional_args(args, "__eq", call_span)
                if pos_args.length() != 2 {
                  raise TypeError::BadCall(message="__eq", span=call_span)
                }
                let a = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                let b = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                ensure_eq_operand(env, a, pos_args[0].span())
                ensure_eq_operand(env, b, pos_args[1].span())
                if not(type_equal(env, b, a)) &&
                  not(int_char_comparable_pair(env, a, b)) {
                  raise TypeError::Mismatch(
                    expected=a,
                    actual=b,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Bool
              }
              "__lt" => {
                let pos_args = extract_positional_args(args, "__lt", call_span)
                if pos_args.length() != 2 {
                  raise TypeError::BadCall(message="__lt", span=call_span)
                }
                let a = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                let b = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                ensure_ord_operand(env, a, pos_args[0].span())
                ensure_ord_operand(env, b, pos_args[1].span())
                if not(type_equal(env, b, a)) &&
                  not(int_char_comparable_pair(env, a, b)) {
                  raise TypeError::Mismatch(
                    expected=a,
                    actual=b,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Bool
              }
              "__neg" => {
                let pos_args = extract_positional_args(args, "__neg", call_span)
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(message="__neg", span=call_span)
                }
                let a = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                ensure_num_operand(env, a, pos_args[0].span())
                a
              }
              "__assert" => {
                let pos_args = extract_positional_args(
                  args, "__assert", call_span,
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(message="__assert", span=call_span)
                }
                let a = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, a, @core.Type::Bool)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Bool,
                    actual=a,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Unit
              }
              "record_set" => {
                let pos_args = extract_positional_args(
                  args, "record_set", call_span,
                )
                if pos_args.length() != 3 {
                  raise TypeError::BadCall(message="record_set", span=call_span)
                }
                let record_ty = normalize_type(
                  env,
                  type_expr_eff(
                    env,
                    pos_args[0],
                    aliases,
                    effects,
                    allow_effect,
                  ),
                )
                let field_ty = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, field_ty, @core.Type::String)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::String,
                    actual=field_ty,
                    span=pos_args[1].span(),
                    context=Some("record field name"),
                  )
                }
                let value_ty = type_expr_eff(
                  env,
                  pos_args[2],
                  aliases,
                  effects,
                  allow_effect,
                )
                match record_ty {
                  @core.Type::Record(fields) =>
                    match pos_args[1] {
                      @core.Expr::String(value=name, span~) =>
                        match fields.get(name) {
                          Some(expect) =>
                            if not(type_equal(env, expect, value_ty)) {
                              raise TypeError::Mismatch(
                                expected=expect,
                                actual=value_ty,
                                span=pos_args[2].span(),
                                context=Some("record field value"),
                              )
                            }
                          None =>
                            raise TypeError::BadCall(
                              message="record_set",
                              span~,
                            )
                        }
                      _ => ()
                    }
                  _ =>
                    raise TypeError::BadCall(
                      message="record_set",
                      span=call_span,
                    )
                }
                record_ty
              }
              "map_keys" => {
                let pos_args = extract_positional_args(
                  args, "map_keys", call_span,
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(message="map_keys", span=call_span)
                }
                let map_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                let resolved = normalize_type(env, map_ty)
                match resolved {
                  @core.Type::Map(_) => @core.Type::Array(@core.Type::String)
                  _ =>
                    raise TypeError::BadCall(message="map_keys", span=call_span)
                }
              }
              "map_values" => {
                let pos_args = extract_positional_args(
                  args, "map_values", call_span,
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(message="map_values", span=call_span)
                }
                let map_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                let resolved = normalize_type(env, map_ty)
                match resolved {
                  @core.Type::Map(elem_ty) => @core.Type::Array(elem_ty)
                  _ =>
                    raise TypeError::BadCall(
                      message="map_values",
                      span=call_span,
                    )
                }
              }
              "map_has_key" => {
                let pos_args = extract_positional_args(
                  args, "map_has_key", call_span,
                )
                if pos_args.length() != 2 {
                  raise TypeError::BadCall(
                    message="map_has_key",
                    span=call_span,
                  )
                }
                let map_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                let resolved = normalize_type(env, map_ty)
                match resolved {
                  @core.Type::Map(_) => ()
                  _ =>
                    raise TypeError::BadCall(
                      message="map_has_key",
                      span=call_span,
                    )
                }
                let key_ty = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, key_ty, @core.Type::String)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::String,
                    actual=key_ty,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Bool
              }
              "array_slice" => {
                let pos_args = extract_positional_args(
                  args, "array_slice", call_span,
                )
                if pos_args.length() != 3 {
                  raise TypeError::BadCall(
                    message="array_slice",
                    span=call_span,
                  )
                }
                let array_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                let resolved = normalize_type(env, array_ty)
                let elem_ty = match resolved {
                  @core.Type::Array(elem_ty) => elem_ty
                  _ =>
                    raise TypeError::BadCall(
                      message="array_slice",
                      span=call_span,
                    )
                }
                let start_ty = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, start_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=start_ty,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                let end_ty = type_expr_eff(
                  env,
                  pos_args[2],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, end_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=end_ty,
                    span=pos_args[2].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Array(elem_ty)
              }
              "int_to_float" | "f32_convert_i32_s" =>
                type_check_unary_convert(
                  env,
                  args,
                  call_span,
                  aliases,
                  effects,
                  allow_effect,
                  name,
                  @core.Type::Int,
                  @core.Type::Float,
                )
              "int_to_double" | "f64_convert_i32_s" =>
                type_check_unary_convert(
                  env,
                  args,
                  call_span,
                  aliases,
                  effects,
                  allow_effect,
                  name,
                  @core.Type::Int,
                  @core.Type::Double,
                )
              "float_to_int" | "i32_trunc_f32_s" =>
                type_check_unary_convert(
                  env,
                  args,
                  call_span,
                  aliases,
                  effects,
                  allow_effect,
                  name,
                  @core.Type::Float,
                  @core.Type::Int,
                )
              "float_to_double" | "f64_promote_f32" =>
                type_check_unary_convert(
                  env,
                  args,
                  call_span,
                  aliases,
                  effects,
                  allow_effect,
                  name,
                  @core.Type::Float,
                  @core.Type::Double,
                )
              "double_to_int" | "i32_trunc_f64_s" =>
                type_check_unary_convert(
                  env,
                  args,
                  call_span,
                  aliases,
                  effects,
                  allow_effect,
                  name,
                  @core.Type::Double,
                  @core.Type::Int,
                )
              "double_to_float" | "f32_demote_f64" =>
                type_check_unary_convert(
                  env,
                  args,
                  call_span,
                  aliases,
                  effects,
                  allow_effect,
                  name,
                  @core.Type::Double,
                  @core.Type::Float,
                )
              "i32_shr_u" => {
                let pos_args = extract_positional_args(args, name, call_span)
                if pos_args.length() != 2 {
                  raise TypeError::BadCall(message=name, span=call_span)
                }
                let a = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                let b = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, a, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=a,
                    span=pos_args[0].span(),
                    context=Some("bit operation"),
                  )
                }
                if not(type_equal(env, b, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=b,
                    span=pos_args[1].span(),
                    context=Some("bit operation"),
                  )
                }
                @core.Type::Int
              }
              "f32_neg" =>
                type_check_unary_convert(
                  env,
                  args,
                  call_span,
                  aliases,
                  effects,
                  allow_effect,
                  "f32_neg",
                  @core.Type::Float,
                  @core.Type::Float,
                )
              "f64_neg" =>
                type_check_unary_convert(
                  env,
                  args,
                  call_span,
                  aliases,
                  effects,
                  allow_effect,
                  "f64_neg",
                  @core.Type::Double,
                  @core.Type::Double,
                )
              "i32_load" | "i32_load8_u" => {
                let pos_args = extract_positional_args(args, name, call_span)
                if pos_args.length() != 2 {
                  raise TypeError::BadCall(message=name, span=call_span)
                }
                let base_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, base_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=base_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                let offset_ty = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, offset_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=offset_ty,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Int
              }
              "i32_store" | "i32_store8" => {
                let pos_args = extract_positional_args(args, name, call_span)
                if pos_args.length() != 3 {
                  raise TypeError::BadCall(message=name, span=call_span)
                }
                let base_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, base_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=base_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                let offset_ty = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, offset_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=offset_ty,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                let value_ty = type_expr_eff(
                  env,
                  pos_args[2],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, value_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=value_ty,
                    span=pos_args[2].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Unit
              }
              "f32_load" => {
                let pos_args = extract_positional_args(args, name, call_span)
                if pos_args.length() != 2 {
                  raise TypeError::BadCall(message=name, span=call_span)
                }
                let base_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, base_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=base_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                let offset_ty = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, offset_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=offset_ty,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Float
              }
              "f64_load" => {
                let pos_args = extract_positional_args(args, name, call_span)
                if pos_args.length() != 2 {
                  raise TypeError::BadCall(message=name, span=call_span)
                }
                let base_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, base_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=base_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                let offset_ty = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, offset_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=offset_ty,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Double
              }
              "f32_store" => {
                let pos_args = extract_positional_args(args, name, call_span)
                if pos_args.length() != 3 {
                  raise TypeError::BadCall(message=name, span=call_span)
                }
                let base_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, base_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=base_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                let offset_ty = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, offset_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=offset_ty,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                let value_ty = type_expr_eff(
                  env,
                  pos_args[2],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, value_ty, @core.Type::Float)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Float,
                    actual=value_ty,
                    span=pos_args[2].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Unit
              }
              "f64_store" => {
                let pos_args = extract_positional_args(args, name, call_span)
                if pos_args.length() != 3 {
                  raise TypeError::BadCall(message=name, span=call_span)
                }
                let base_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, base_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=base_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                let offset_ty = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, offset_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=offset_ty,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                let value_ty = type_expr_eff(
                  env,
                  pos_args[2],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, value_ty, @core.Type::Double)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Double,
                    actual=value_ty,
                    span=pos_args[2].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Unit
              }
              "__to_string" => {
                let pos_args = extract_positional_args(
                  args, "__to_string", call_span,
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(
                    message="__to_string",
                    span=call_span,
                  )
                }
                let _ = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                @core.Type::String
              }
              _ =>
                // Try to interpret as field access: x(p) where p is a record/struct
                // and x is a field name
                match
                  try_field_access(
                    env, name, args, aliases, effects, allow_effect, call_span,
                  ) {
                  Some(ty) => ty
                  None => raise TypeError::BadCall(message=name, span=call_span)
                }
            }
          }
      }
  }
}

///|
fn try_field_access(
  env : TypeEnv,
  field_name : String,
  args : Array[@core.CallArg],
  aliases : Map[String, @core.Ref],
  effects : EffectScope,
  allow_effect : Bool,
  call_span : @core.Span,
) -> @core.Type? raise TypeError {
  // Field access is desugared from p.field to field(p)
  // So we expect exactly one positional argument
  let pos_args = extract_positional_args(args, field_name, call_span)
  if pos_args.length() != 1 {
    return None
  }
  let arg_ty = type_expr_eff(env, pos_args[0], aliases, effects, allow_effect)
  let resolved = resolve_type(env, arg_ty)
  // Try Record field access
  match resolved {
    @core.Type::Record(fields) =>
      match fields.get(field_name) {
        Some(field_ty) => return Some(field_ty)
        None => return None
      }
    @core.Type::Named(name~, args=type_args) =>
      // Try Struct field access
      match env.get_struct(name) {
        Some(struct_def) =>
          match struct_def.get_field(field_name) {
            Some(field_def) => {
              // Substitute type parameters (resolve type args first)
              let type_map : Map[String, @core.Type] = {}
              for i, param in struct_def.params {
                if i < type_args.length() {
                  type_map[param] = resolve_type(env, type_args[i])
                }
              }
              let result_ty = substitute_type_params_by_name(
                field_def.ty,
                type_map,
              )
              return Some(result_ty)
            }
            None => return None
          }
        None => return None
      }
    _ => return None
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
  // Build positional params list first for bidirectional inference
  let positional : Array[@core.FuncParam] = []
  for param in params {
    if param.label == @core.ParamLabel::Positional {
      positional.push(param)
    }
  }
  // Type arguments with contextual information for lambdas
  let arg_types : Array[ArgType] = []
  let mut pos_idx = 0
  for arg in args {
    let ty = match arg.label {
      None => {
        // Positional argument - check if it's a lambda needing inference
        let expected_ty : @core.Type? = if pos_idx < positional.length() {
          Some(positional[pos_idx].ty)
        } else {
          None
        }
        pos_idx += 1
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
          if param.label != @core.ParamLabel::Positional && param.name == label {
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
    arg_types.push(ArgType::{ label: arg.label, ty, span: arg.span })
  }
  // Now check types match
  let mut pos_index = 0
  let used_labels : Map[String, Bool] = {}
  for arg in arg_types {
    match arg.label {
      None => {
        if pos_index >= positional.length() {
          raise TypeError::BadCall(
            message="too many positional args",
            span=arg.span,
          )
        }
        let param = positional[pos_index]
        pos_index += 1
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
      Some(label) => {
        if used_labels.contains(label) {
          raise TypeError::BadCall(
            message="duplicate label: " + label,
            span=arg.span,
          )
        }
        let mut found : @core.FuncParam? = None
        for param in params {
          if param.label != @core.ParamLabel::Positional && param.name == label {
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
