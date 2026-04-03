///|
let resolve_member_depth : Ref[Int] = Ref::new(0)

///|
/// Map a resolved type to its builtin namespace root for UFCS dispatch.
/// This is separate from TypeEnv::namespace_root to avoid affecting existing
/// user-defined function resolution (resolve_type_member_call_name).
fn builtin_ufcs_namespace(ty : @core.Type) -> String? {
  match ty {
    @core.Type::Int => Some("Int")
    @core.Type::Float => Some("Float")
    @core.Type::Double => Some("Double")
    @core.Type::Bool => Some("Bool")
    @core.Type::Char => Some("Char")
    @core.Type::String => Some("String")
    @core.Type::Path => Some("Path")
    @core.Type::Array(_) => Some("Array")
    @core.Type::Map(_, _) => Some("Map")
    @core.Type::Set(_) => Some("Set")
    @core.Type::ArrayBuilder(_) => Some("ArrayBuilder")
    @core.Type::MapBuilder(_, _) => Some("MapBuilder")
    @core.Type::Bytes => Some("Bytes")
    @core.Type::PromptText => Some("PromptText")
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
  // Guard against infinite recursion: type_expr_eff → type_call → resolve_type_member_call_name
  if resolve_member_depth.val >= 4 {
    return None
  }
  let _ = call_span
  match @core.first_positional_expr(args) {
    None => None
    Some(expr) => {
      resolve_member_depth.val += 1
      let recv_ty = resolve_type(
        env,
        type_expr_eff(env, expr, aliases, effects, allow_effect),
      ) catch {
        _ => {
          // UFCS receiver typing failed — e.g. lambda with untyped params.
          // Fall through to normal call dispatch where bidirectional inference
          // can propagate expected types from the callee signature.
          resolve_member_depth.val -= 1
          return None
        }
      }
      resolve_member_depth.val -= 1
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
  if @core.lower_wasm_intrinsic_name(lookup_name) == "__to_string" {
    return type_call_builtin(
      env,
      lookup_name,
      args,
      aliases,
      effects,
      allow_effect,
      call_span,
    )
  }
  match env.get(lookup_name) {
    Some(ty) =>
      match ty {
        @core.Type::Func(params~, ret~, effects=fn_effects) => {
          check_call_args(
            env, lookup_name, params, args, aliases, effects, allow_effect, call_span,
          )
          require_effects(env, effects, fn_effects, lookup_name, call_span)
          ret
        }
        _ => raise TypeError::BadCall(message=lookup_name, span=call_span)
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
