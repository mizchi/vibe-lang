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
  match @core.first_positional_expr(args) {
    None => None
    Some(expr) => {
      let recv_ty = resolve_type(
        env,
        type_expr_eff(env, expr, aliases, effects, allow_effect),
      )
      match env.build_type_member_candidate(recv_ty, name) {
        Some(candidate) =>
          match env.get(candidate) {
            Some(_) => Some(candidate)
            None => None
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
    TypeError::TopLevelImpure(name~, ..) =>
      "top-level binding must be pure: " + name
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
            type_call_builtin(
              env, name, args, aliases, effects, allow_effect, call_span,
            )
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
