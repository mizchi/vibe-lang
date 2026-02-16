///|
pub fn TypeEnv::variant_namespace_root(
  self : TypeEnv,
  fields : Map[String, @core.Type],
) -> String? {
  let mut found : String? = None
  for enum_name in self.enum_names() {
    match self.get_enum_def(enum_name) {
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
/// Resolve namespace root from an already-resolved type (no type variable substitution).
/// Used by both checker and runtime for type member dispatch.
pub fn TypeEnv::namespace_root(self : TypeEnv, ty : @core.Type) -> String? {
  match ty {
    @core.Type::Int => Some("Int")
    @core.Type::Float => Some("Float")
    @core.Type::Double => Some("Double")
    @core.Type::Bool => Some("Bool")
    @core.Type::Char => Some("Char")
    @core.Type::String => Some("String")
    @core.Type::Path => Some("Path")
    @core.Type::Named(name~, ..) => Some(name)
    @core.Type::Variant(fields) => self.variant_namespace_root(fields)
    _ => None
  }
}

///|
fn namespace_root_from_type(env : TypeEnv, ty : @core.Type) -> String? {
  env.namespace_root(resolve_type(env, ty))
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
              "fs_read_file" => {
                let pos_args = extract_positional_args(
                  args, "fs_read_file", call_span,
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(
                    message="fs_read_file",
                    span=call_span,
                  )
                }
                require_effect_guard(
                  env,
                  effects,
                  allow_effect,
                  "fs_read_file",
                  builtin_effects("fs_read_file"),
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
                @core.Type::String
              }
              "fs_write_file" => {
                let pos_args = extract_positional_args(
                  args, "fs_write_file", call_span,
                )
                if pos_args.length() != 2 {
                  raise TypeError::BadCall(
                    message="fs_write_file",
                    span=call_span,
                  )
                }
                require_effect_guard(
                  env,
                  effects,
                  allow_effect,
                  "fs_write_file",
                  builtin_effects("fs_write_file"),
                  call_span,
                )
                let path_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, path_ty, @core.Type::String)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::String,
                    actual=path_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                let content_ty = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, content_ty, @core.Type::String)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::String,
                    actual=content_ty,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Unit
              }
              "fs_exists" => {
                let pos_args = extract_positional_args(
                  args, "fs_exists", call_span,
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(
                    message="fs_exists",
                    span=call_span,
                  )
                }
                require_effect_guard(
                  env,
                  effects,
                  allow_effect,
                  "fs_exists",
                  builtin_effects("fs_exists"),
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
                @core.Type::Bool
              }
              "socket_tcp_connect" => {
                let pos_args = extract_positional_args(
                  args, "socket_tcp_connect", call_span,
                )
                if pos_args.length() != 2 {
                  raise TypeError::BadCall(
                    message="socket_tcp_connect",
                    span=call_span,
                  )
                }
                require_effect_guard(
                  env,
                  effects,
                  allow_effect,
                  "socket_tcp_connect",
                  builtin_effects("socket_tcp_connect"),
                  call_span,
                )
                let host_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, host_ty, @core.Type::String)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::String,
                    actual=host_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                let port_ty = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, port_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=port_ty,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Int
              }
              "socket_tcp_read" => {
                let pos_args = extract_positional_args(
                  args, "socket_tcp_read", call_span,
                )
                if pos_args.length() != 2 {
                  raise TypeError::BadCall(
                    message="socket_tcp_read",
                    span=call_span,
                  )
                }
                require_effect_guard(
                  env,
                  effects,
                  allow_effect,
                  "socket_tcp_read",
                  builtin_effects("socket_tcp_read"),
                  call_span,
                )
                let handle_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, handle_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=handle_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                let max_bytes_ty = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, max_bytes_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=max_bytes_ty,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::String
              }
              "socket_tcp_write" => {
                let pos_args = extract_positional_args(
                  args, "socket_tcp_write", call_span,
                )
                if pos_args.length() != 2 {
                  raise TypeError::BadCall(
                    message="socket_tcp_write",
                    span=call_span,
                  )
                }
                require_effect_guard(
                  env,
                  effects,
                  allow_effect,
                  "socket_tcp_write",
                  builtin_effects("socket_tcp_write"),
                  call_span,
                )
                let handle_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, handle_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=handle_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                let data_ty = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, data_ty, @core.Type::String)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::String,
                    actual=data_ty,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Unit
              }
              "socket_tcp_close" => {
                let pos_args = extract_positional_args(
                  args, "socket_tcp_close", call_span,
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(
                    message="socket_tcp_close",
                    span=call_span,
                  )
                }
                require_effect_guard(
                  env,
                  effects,
                  allow_effect,
                  "socket_tcp_close",
                  builtin_effects("socket_tcp_close"),
                  call_span,
                )
                let handle_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, handle_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=handle_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Unit
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
              "string_starts_with" | "string_ends_with" => {
                let pos_args = extract_positional_args(args, name, call_span)
                if pos_args.length() != 2 {
                  raise TypeError::BadCall(message=name, span=call_span)
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
              "string_replace" | "string_replace_all" => {
                let pos_args = extract_positional_args(args, name, call_span)
                if pos_args.length() != 3 {
                  raise TypeError::BadCall(message=name, span=call_span)
                }
                let str_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                let pat_ty = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                let rep_ty = type_expr_eff(
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
                if not(type_equal(env, pat_ty, @core.Type::String)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::String,
                    actual=pat_ty,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                if not(type_equal(env, rep_ty, @core.Type::String)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::String,
                    actual=rep_ty,
                    span=pos_args[2].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::String
              }
              "string_trim_start" | "string_trim_end" =>
                type_check_unary_convert(
                  env,
                  args,
                  call_span,
                  aliases,
                  effects,
                  allow_effect,
                  name,
                  @core.Type::String,
                  @core.Type::String,
                )
              "string_last_index_of" | "string_count" => {
                let pos_args = extract_positional_args(args, name, call_span)
                if pos_args.length() != 2 {
                  raise TypeError::BadCall(message=name, span=call_span)
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
              "int_abs" | "int_signum" =>
                type_check_unary_convert(
                  env,
                  args,
                  call_span,
                  aliases,
                  effects,
                  allow_effect,
                  name,
                  @core.Type::Int,
                  @core.Type::Int,
                )
              "int_is_even" | "int_is_odd" =>
                type_check_unary_convert(
                  env,
                  args,
                  call_span,
                  aliases,
                  effects,
                  allow_effect,
                  name,
                  @core.Type::Int,
                  @core.Type::Bool,
                )
              "int_max" | "int_min" => {
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
                    context=Some("argument"),
                  )
                }
                if not(type_equal(env, b, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=b,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Int
              }
              "int_clamp" => {
                let pos_args = extract_positional_args(
                  args, "int_clamp", call_span,
                )
                if pos_args.length() != 3 {
                  raise TypeError::BadCall(message="int_clamp", span=call_span)
                }
                let x_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                let lo_ty = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                let hi_ty = type_expr_eff(
                  env,
                  pos_args[2],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(type_equal(env, x_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=x_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                if not(type_equal(env, lo_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=lo_ty,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                if not(type_equal(env, hi_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=hi_ty,
                    span=pos_args[2].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Int
              }
              "double_abs" =>
                type_check_unary_convert(
                  env,
                  args,
                  call_span,
                  aliases,
                  effects,
                  allow_effect,
                  name,
                  @core.Type::Double,
                  @core.Type::Double,
                )
              "double_max" | "double_min" => {
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
                if not(type_equal(env, a, @core.Type::Double)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Double,
                    actual=a,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                if not(type_equal(env, b, @core.Type::Double)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Double,
                    actual=b,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Double
              }
              "double_floor" | "double_ceil" =>
                type_check_unary_convert(
                  env,
                  args,
                  call_span,
                  aliases,
                  effects,
                  allow_effect,
                  name,
                  @core.Type::Double,
                  @core.Type::Double,
                )
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
              "string_join" => {
                let pos_args = extract_positional_args(
                  args, "string_join", call_span,
                )
                if pos_args.length() != 2 {
                  raise TypeError::BadCall(
                    message="string_join",
                    span=call_span,
                  )
                }
                let arr_ty = type_expr_eff(
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
                if not(
                    type_equal(
                      env,
                      arr_ty,
                      @core.Type::Array(@core.Type::String),
                    ),
                  ) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Array(@core.Type::String),
                    actual=arr_ty,
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
                @core.Type::String
              }
              "from_lines" => {
                let pos_args = extract_positional_args(
                  args, "from_lines", call_span,
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(message="from_lines", span=call_span)
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
                @core.Type::Array(@core.Type::String)
              }
              "to_lines" => {
                let pos_args = extract_positional_args(
                  args, "to_lines", call_span,
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(message="to_lines", span=call_span)
                }
                let arg_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                if not(
                    type_equal(
                      env,
                      arg_ty,
                      @core.Type::Array(@core.Type::String),
                    ),
                  ) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Array(@core.Type::String),
                    actual=arg_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::String
              }
              "to_json" => {
                let pos_args = extract_positional_args(
                  args, "to_json", call_span,
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(message="to_json", span=call_span)
                }
                let arg_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                let json_type = @core.Type::Named(name="Json", args=[])
                if not(type_equal(env, arg_ty, json_type)) {
                  raise TypeError::Mismatch(
                    expected=json_type,
                    actual=arg_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::String
              }
              "from_json" => {
                let pos_args = extract_positional_args(
                  args, "from_json", call_span,
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(message="from_json", span=call_span)
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
                @core.Type::Named(name="Json", args=[])
              }
              "to_jsonl" => {
                let pos_args = extract_positional_args(
                  args, "to_jsonl", call_span,
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(message="to_jsonl", span=call_span)
                }
                let arg_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                let json_array_type = @core.Type::Array(
                  @core.Type::Named(name="Json", args=[]),
                )
                if not(type_equal(env, arg_ty, json_array_type)) {
                  raise TypeError::Mismatch(
                    expected=json_array_type,
                    actual=arg_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::String
              }
              "from_jsonl" => {
                let pos_args = extract_positional_args(
                  args, "from_jsonl", call_span,
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(message="from_jsonl", span=call_span)
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
                @core.Type::Array(@core.Type::Named(name="Json", args=[]))
              }
              "json_type" => {
                let pos_args = extract_positional_args(
                  args, "json_type", call_span,
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(message="json_type", span=call_span)
                }
                let arg_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                let json_type = @core.Type::Named(name="Json", args=[])
                if not(type_equal(env, arg_ty, json_type)) {
                  raise TypeError::Mismatch(
                    expected=json_type,
                    actual=arg_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::String
              }
              "json_get" => {
                let pos_args = extract_positional_args(
                  args, "json_get", call_span,
                )
                if pos_args.length() != 2 {
                  raise TypeError::BadCall(message="json_get", span=call_span)
                }
                let obj_ty = type_expr_eff(
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
                let json_type = @core.Type::Named(name="Json", args=[])
                if not(type_equal(env, obj_ty, json_type)) {
                  raise TypeError::Mismatch(
                    expected=json_type,
                    actual=obj_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                if not(type_equal(env, key_ty, @core.Type::String)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::String,
                    actual=key_ty,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                json_type
              }
              "json_index" => {
                let pos_args = extract_positional_args(
                  args, "json_index", call_span,
                )
                if pos_args.length() != 2 {
                  raise TypeError::BadCall(message="json_index", span=call_span)
                }
                let arr_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                let idx_ty = type_expr_eff(
                  env,
                  pos_args[1],
                  aliases,
                  effects,
                  allow_effect,
                )
                let json_type = @core.Type::Named(name="Json", args=[])
                if not(type_equal(env, arr_ty, json_type)) {
                  raise TypeError::Mismatch(
                    expected=json_type,
                    actual=arr_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                if not(type_equal(env, idx_ty, @core.Type::Int)) {
                  raise TypeError::Mismatch(
                    expected=@core.Type::Int,
                    actual=idx_ty,
                    span=pos_args[1].span(),
                    context=Some("argument"),
                  )
                }
                json_type
              }
              "json_string" => {
                let pos_args = extract_positional_args(
                  args, "json_string", call_span,
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(
                    message="json_string",
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
                let json_type = @core.Type::Named(name="Json", args=[])
                if not(type_equal(env, arg_ty, json_type)) {
                  raise TypeError::Mismatch(
                    expected=json_type,
                    actual=arg_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::String
              }
              "json_number" => {
                let pos_args = extract_positional_args(
                  args, "json_number", call_span,
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(
                    message="json_number",
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
                let json_type = @core.Type::Named(name="Json", args=[])
                if not(type_equal(env, arg_ty, json_type)) {
                  raise TypeError::Mismatch(
                    expected=json_type,
                    actual=arg_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Double
              }
              "json_bool" => {
                let pos_args = extract_positional_args(
                  args, "json_bool", call_span,
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(message="json_bool", span=call_span)
                }
                let arg_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                let json_type = @core.Type::Named(name="Json", args=[])
                if not(type_equal(env, arg_ty, json_type)) {
                  raise TypeError::Mismatch(
                    expected=json_type,
                    actual=arg_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Bool
              }
              "json_is_null" => {
                let pos_args = extract_positional_args(
                  args, "json_is_null", call_span,
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(
                    message="json_is_null",
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
                let json_type = @core.Type::Named(name="Json", args=[])
                if not(type_equal(env, arg_ty, json_type)) {
                  raise TypeError::Mismatch(
                    expected=json_type,
                    actual=arg_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Bool
              }
              "json_length" => {
                let pos_args = extract_positional_args(
                  args, "json_length", call_span,
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(
                    message="json_length",
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
                let json_type = @core.Type::Named(name="Json", args=[])
                if not(type_equal(env, arg_ty, json_type)) {
                  raise TypeError::Mismatch(
                    expected=json_type,
                    actual=arg_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Int
              }
              "json_keys" => {
                let pos_args = extract_positional_args(
                  args, "json_keys", call_span,
                )
                if pos_args.length() != 1 {
                  raise TypeError::BadCall(message="json_keys", span=call_span)
                }
                let arg_ty = type_expr_eff(
                  env,
                  pos_args[0],
                  aliases,
                  effects,
                  allow_effect,
                )
                let json_type = @core.Type::Named(name="Json", args=[])
                if not(type_equal(env, arg_ty, json_type)) {
                  raise TypeError::Mismatch(
                    expected=json_type,
                    actual=arg_ty,
                    span=pos_args[0].span(),
                    context=Some("argument"),
                  )
                }
                @core.Type::Array(@core.Type::String)
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
