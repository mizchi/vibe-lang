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
  // Resolve aliases / type vars but do NOT expand `Named` enums into
  // `Variant`. Pre-expanding broke e.g. `let (a, b) = (Some(1), None)`:
  // `a` got bound to `Variant({Some: Int, None: Unit})` while `Some(42)`
  // continues to be typed as `Named("Option", [Int])`, so a later
  // `a == Some(42)` failed to unify. Pat::Ctor still needs the Variant
  // shape, so it expands locally.
  let normalized = normalize_type(env, scrutinee_ty)
  collect_pattern_bindings_inner(env, out, pat, normalized)
  out
}

///|
/// Like collect_pattern_bindings but skips normalize_type on the scrutinee,
/// assuming the caller has already normalized it.
fn collect_pattern_bindings_prenormalized(
  env : TypeEnv,
  pat : @core.Pat,
  scrutinee_ty : @core.Type,
) -> Map[String, @core.Type] raise TypeError {
  let out : Map[String, @core.Type] = {}
  collect_pattern_bindings_inner(env, out, pat, scrutinee_ty)
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
    @core.Pat::Ctor(name~, args~, span~) => {
      // Strip qualified prefix for variant lookup: Color::Red → Red
      let ctor_key = @core.strip_ctor_qualifier(name)
      // Pat::Ctor needs the expanded Variant view; the public entry no
      // longer pre-expands so we do it here on demand.
      let expanded = normalize_type_expand_enum(env, scrutinee_ty)
      match expanded {
        @core.Type::Variant(types) =>
          match types.get(ctor_key) {
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
    }
    @core.Pat::Int(value~, span~) => {
      let _ = value
      if !type_equal(env, scrutinee_ty, @core.Type::Int) {
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
      if !type_equal(env, scrutinee_ty, @core.Type::Float) {
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
      if !type_equal(env, scrutinee_ty, @core.Type::Double) {
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
      if !type_equal(env, scrutinee_ty, @core.Type::Bool) {
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
      if !type_equal(env, scrutinee_ty, @core.Type::Char) {
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
      if !type_equal(env, scrutinee_ty, @core.Type::String) {
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
