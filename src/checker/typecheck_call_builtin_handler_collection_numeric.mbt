///|
fn type_call_builtin_handler_collection_numeric(
  env : TypeEnv,
  name : String,
  builtin_name : String,
  args : Array[@core.CallArg],
  aliases : Map[String, @core.Ref],
  effects : EffectScope,
  allow_effect : Bool,
  call_span : @core.Span,
) -> @core.Type raise TypeError {
  match builtin_name {
    "string_from_char_code" =>
      check_builtin_simple(
        env,
        "string_from_char_code",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Int],
        @core.Type::String,
        false,
      )
    "char_to_int" =>
      check_builtin_simple(
        env,
        "char_to_int",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Char],
        @core.Type::Int,
        false,
      )
    "char_from_int" =>
      check_builtin_simple(
        env,
        "char_from_int",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Int],
        @core.Type::Char,
        false,
      )
    "string_builder" =>
      check_builtin_simple(
        env,
        "string_builder",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [],
        @core.Type::StringBuilder,
        true,
      )
    "string_builder_push" =>
      check_builtin_simple(
        env,
        "string_builder_push",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::StringBuilder, @core.Type::String],
        @core.Type::Unit,
        true,
      )
    "string_builder_freeze" =>
      check_builtin_simple(
        env,
        "string_builder_freeze",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::StringBuilder],
        @core.Type::String,
        true,
      )
    "bytes_new" =>
      check_builtin_simple(
        env,
        "bytes_new",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [],
        @core.Type::Bytes,
        true,
      )
    "bytes_length" =>
      check_builtin_simple(
        env,
        "bytes_length",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Bytes],
        @core.Type::Int,
        false,
      )
    "bytes_get" =>
      check_builtin_simple(
        env,
        "bytes_get",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Bytes, @core.Type::Int],
        @core.Type::Int,
        false,
      )
    "bytes_set" =>
      check_builtin_simple(
        env,
        "bytes_set",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Bytes, @core.Type::Int, @core.Type::Int],
        @core.Type::Unit,
        true,
      )
    "bytes_push" =>
      check_builtin_simple(
        env,
        "bytes_push",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Bytes, @core.Type::Int],
        @core.Type::Unit,
        true,
      )
    "bytes_concat" =>
      check_builtin_simple(
        env,
        "bytes_concat",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Bytes, @core.Type::Bytes],
        @core.Type::Bytes,
        false,
      )
    "bytes_slice" =>
      check_builtin_simple(
        env,
        "bytes_slice",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Bytes, @core.Type::Int, @core.Type::Int],
        @core.Type::Bytes,
        false,
      )
    "bytes_from_array" =>
      check_builtin_simple(
        env,
        "bytes_from_array",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Array(@core.Type::Int)],
        @core.Type::Bytes,
        false,
      )
    "bytes_to_array" =>
      check_builtin_simple(
        env,
        "bytes_to_array",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Bytes],
        @core.Type::Array(@core.Type::Int),
        false,
      )
    "bytes_from_string" =>
      check_builtin_simple(
        env,
        "bytes_from_string",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String],
        @core.Type::Bytes,
        false,
      )
    "bytes_to_string" =>
      check_builtin_simple(
        env,
        "bytes_to_string",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Bytes],
        @core.Type::String,
        false,
      )
    "array_builder" =>
      check_builtin_simple(
        env,
        "array_builder",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [],
        @core.Type::ArrayBuilder(fresh_type_var(env)),
        true,
      )
    "array_builder_push" => {
      let pos_args = prepare_builtin_pos_args(
        env, "array_builder_push", args, 2, effects, allow_effect, call_span, true,
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
      let elem_ty = expect_array_builder_elem_type(
        env,
        builder_ty,
        pos_args[0].span(),
      )
      ensure_type(env, value_ty, elem_ty, pos_args[1].span(), "argument")
      @core.Type::Unit
    }
    "array_builder_freeze" => {
      let pos_args = prepare_builtin_pos_args(
        env, "array_builder_freeze", args, 1, effects, allow_effect, call_span, true,
      )
      let builder_ty = type_expr_eff(
        env,
        pos_args[0],
        aliases,
        effects,
        allow_effect,
      )
      let elem_ty = expect_array_builder_elem_type(
        env,
        builder_ty,
        pos_args[0].span(),
      )
      @core.Type::Array(elem_ty)
    }
    "map_builder" =>
      check_builtin_simple(
        env,
        "map_builder",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [],
        @core.Type::MapBuilder(fresh_type_var(env)),
        true,
      )
    "map_builder_set" => {
      let pos_args = prepare_builtin_pos_args(
        env, "map_builder_set", args, 3, effects, allow_effect, call_span, true,
      )
      let builder_ty = type_expr_eff(
        env,
        pos_args[0],
        aliases,
        effects,
        allow_effect,
      )
      let _ = check_arg_type(
        env,
        pos_args[1],
        @core.Type::String,
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
      let elem_ty = expect_map_builder_elem_type(
        env,
        builder_ty,
        pos_args[0].span(),
      )
      ensure_type(env, value_ty, elem_ty, pos_args[2].span(), "argument")
      @core.Type::Unit
    }
    "map_builder_freeze" => {
      let pos_args = prepare_builtin_pos_args(
        env, "map_builder_freeze", args, 1, effects, allow_effect, call_span, true,
      )
      let builder_ty = type_expr_eff(
        env,
        pos_args[0],
        aliases,
        effects,
        allow_effect,
      )
      let elem_ty = expect_map_builder_elem_type(
        env,
        builder_ty,
        pos_args[0].span(),
      )
      @core.Type::Map(elem_ty)
    }
    "array_length" => {
      let pos_args = check_positional_arity(args, "array_length", 1, call_span)
      let array_ty = type_expr_eff(
        env,
        pos_args[0],
        aliases,
        effects,
        allow_effect,
      )
      let _ = expect_array_elem_type(env, array_ty, pos_args[0].span())
      @core.Type::Int
    }
    "array_get" => {
      let pos_args = check_positional_arity(args, "array_get", 2, call_span)
      let array_ty = type_expr_eff(
        env,
        pos_args[0],
        aliases,
        effects,
        allow_effect,
      )
      let _ = check_arg_type(
        env,
        pos_args[1],
        @core.Type::Int,
        aliases,
        effects,
        allow_effect,
      )
      let elem_ty = expect_array_elem_type(env, array_ty, pos_args[0].span())
      elem_ty
    }
    "array_push" => {
      let pos_args = check_positional_arity(args, "array_push", 2, call_span)
      let array_ty = type_expr_eff(
        env,
        pos_args[0],
        aliases,
        effects,
        allow_effect,
      )
      let elem_ty = expect_array_elem_type(env, array_ty, pos_args[0].span())
      let _ = check_arg_type(
        env,
        pos_args[1],
        elem_ty,
        aliases,
        effects,
        allow_effect,
      )
      @core.Type::Unit
    }
    "array_set" => {
      let pos_args = check_positional_arity(args, "array_set", 3, call_span)
      let array_ty = type_expr_eff(
        env,
        pos_args[0],
        aliases,
        effects,
        allow_effect,
      )
      let _ = check_arg_type(
        env,
        pos_args[1],
        @core.Type::Int,
        aliases,
        effects,
        allow_effect,
      )
      let elem_ty = expect_array_elem_type(env, array_ty, pos_args[0].span())
      let _ = check_arg_type(
        env,
        pos_args[2],
        elem_ty,
        aliases,
        effects,
        allow_effect,
      )
      @core.Type::Unit
    }
    "array_truncate" => {
      let pos_args = check_positional_arity(
        args, "array_truncate", 2, call_span,
      )
      let _ = type_expr_eff(
        env, pos_args[0], aliases, effects, allow_effect,
      )
      let _ = check_arg_type(
        env, pos_args[1], @core.Type::Int, aliases, effects, allow_effect,
      )
      @core.Type::Unit
    }
    "array_slice" => {
      let pos_args = check_positional_arity(args, "array_slice", 3, call_span)
      let array_ty = type_expr_eff(
        env,
        pos_args[0],
        aliases,
        effects,
        allow_effect,
      )
      let _ = check_arg_type(
        env,
        pos_args[1],
        @core.Type::Int,
        aliases,
        effects,
        allow_effect,
      )
      let _ = check_arg_type(
        env,
        pos_args[2],
        @core.Type::Int,
        aliases,
        effects,
        allow_effect,
      )
      array_ty
    }
    "map_get" => {
      let pos_args = check_positional_arity(args, "map_get", 2, call_span)
      let map_ty = type_expr_eff(
        env,
        pos_args[0],
        aliases,
        effects,
        allow_effect,
      )
      let _ = check_arg_type(
        env,
        pos_args[1],
        @core.Type::String,
        aliases,
        effects,
        allow_effect,
      )
      let elem_ty = expect_map_elem_type(env, map_ty, pos_args[0].span())
      elem_ty
    }
    "string_length"
    | "string_utf8_length"
    | "string_utf16_length"
    | "string_unicode_length" =>
      check_builtin_simple(
        env,
        name,
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String],
        @core.Type::Int,
        false,
      )
    "parse_int" =>
      check_builtin_simple(
        env,
        "parse_int",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String],
        @core.Type::Int,
        false,
      )
    "parse_double" =>
      check_builtin_simple(
        env,
        "parse_double",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String],
        @core.Type::Double,
        false,
      )
    "string_char_code_at" =>
      check_builtin_simple(
        env,
        "string_char_code_at",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String, @core.Type::Int],
        @core.Type::Int,
        false,
      )
    "string_substring" =>
      check_builtin_simple(
        env,
        "string_substring",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String, @core.Type::Int, @core.Type::Int],
        @core.Type::String,
        false,
      )
    "string_concat" =>
      check_builtin_simple(
        env,
        "string_concat",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String, @core.Type::String],
        @core.Type::String,
        false,
      )
    "string_equals" =>
      check_builtin_simple(
        env,
        "string_equals",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String, @core.Type::String],
        @core.Type::Bool,
        false,
      )
    "string_split" =>
      check_builtin_simple(
        env,
        "string_split",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String, @core.Type::String],
        @core.Type::Array(@core.Type::String),
        false,
      )
    "string_index_of" | "string_last_index_of" | "string_count" =>
      check_builtin_simple(
        env,
        name,
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String, @core.Type::String],
        @core.Type::Int,
        false,
      )
    "string_contains" | "string_starts_with" | "string_ends_with" =>
      check_builtin_simple(
        env,
        name,
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String, @core.Type::String],
        @core.Type::Bool,
        false,
      )
    "string_trim" | "string_trim_start" | "string_trim_end" =>
      check_builtin_simple(
        env,
        name,
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String],
        @core.Type::String,
        false,
      )
    "string_replace" | "string_replace_all" =>
      check_builtin_simple(
        env,
        name,
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String, @core.Type::String, @core.Type::String],
        @core.Type::String,
        false,
      )
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
    "int_max" | "int_min" =>
      check_builtin_simple(
        env,
        name,
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Int, @core.Type::Int],
        @core.Type::Int,
        false,
      )
    "int_clamp" =>
      check_builtin_simple(
        env,
        "int_clamp",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Int, @core.Type::Int, @core.Type::Int],
        @core.Type::Int,
        false,
      )
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
    "double_max" | "double_min" =>
      check_builtin_simple(
        env,
        name,
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Double, @core.Type::Double],
        @core.Type::Double,
        false,
      )
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
    "string_to_upper" | "string_to_lower" =>
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
    "__add" => {
      let pos_args = extract_positional_args(args, "__add", call_span)
      if pos_args.length() != 2 {
        raise TypeError::BadCall(message="__add", span=call_span)
      }
      let a = type_expr_eff(env, pos_args[0], aliases, effects, allow_effect)
      let b = type_expr_eff(env, pos_args[1], aliases, effects, allow_effect)
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
      let a = type_expr_eff(env, pos_args[0], aliases, effects, allow_effect)
      let b = type_expr_eff(env, pos_args[1], aliases, effects, allow_effect)
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
      let a = type_expr_eff(env, pos_args[0], aliases, effects, allow_effect)
      let b = type_expr_eff(env, pos_args[1], aliases, effects, allow_effect)
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
      let a = type_expr_eff(env, pos_args[0], aliases, effects, allow_effect)
      let b = type_expr_eff(env, pos_args[1], aliases, effects, allow_effect)
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
    "__lshift" | "__rshift" | "__bit_and" | "__bit_or" | "__bit_xor" => {
      let pos_args = extract_positional_args(args, name, call_span)
      if pos_args.length() != 2 {
        raise TypeError::BadCall(message=name, span=call_span)
      }
      let a = type_expr_eff(env, pos_args[0], aliases, effects, allow_effect)
      let b = type_expr_eff(env, pos_args[1], aliases, effects, allow_effect)
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
    "i32_eq" | "i32_ne" | "i32_lt_s" | "i32_le_s" | "i32_gt_s" | "i32_ge_s" =>
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
      let ref_name = match @core.wasm_gc_ref_eq_type_name(builtin_name) {
        Some(t) => t
        None => raise TypeError::BadCall(message=builtin_name, span=call_span)
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
      let pos_args = extract_positional_args(args, "__index", call_span)
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
      let resolved_container = resolve_type(env, container_ty)
      match resolved_container {
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
              type_equal(env, resolved_container, @core.Type::Array(elem_ty)),
            ) {
            raise TypeError::Mismatch(
              expected=@core.Type::Array(elem_ty),
              actual=resolved_container,
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
          if not(type_equal(env, resolved_container, @core.Type::Map(elem_ty))) {
            raise TypeError::Mismatch(
              expected=@core.Type::Map(elem_ty),
              actual=resolved_container,
              span=pos_args[0].span(),
              context=Some("argument"),
            )
          }
          elem_ty
        }
        @core.Type::Record(fields) => {
          if not(type_equal(env, index_ty, @core.Type::String)) {
            raise TypeError::Mismatch(
              expected=@core.Type::String,
              actual=index_ty,
              span=pos_args[1].span(),
              context=Some("index"),
            )
          }
          match pos_args[1] {
            @core.Expr::String(value=key, ..) =>
              match fields.get(key) {
                Some(field_ty) => field_ty
                None =>
                  raise TypeError::BadCall(
                    message="__index: unknown record field: " + key,
                    span=call_span,
                  )
              }
            _ =>
              raise TypeError::BadCall(
                message="__index: record field index must be string literal",
                span=call_span,
              )
          }
        }
        @core.Type::Named(name~, args=type_args) =>
          match env.get_struct(name) {
            Some(struct_def) => {
              if not(type_equal(env, index_ty, @core.Type::String)) {
                raise TypeError::Mismatch(
                  expected=@core.Type::String,
                  actual=index_ty,
                  span=pos_args[1].span(),
                  context=Some("index"),
                )
              }
              match pos_args[1] {
                @core.Expr::String(value=key, ..) =>
                  match struct_def.get_field(key) {
                    Some(field_def) => {
                      let type_map : Map[String, @core.Type] = {}
                      for i, param in struct_def.params {
                        if i < type_args.length() {
                          type_map[param] = resolve_type(env, type_args[i])
                        }
                      }
                      substitute_type_params_by_name(field_def.ty, type_map)
                    }
                    None =>
                      raise TypeError::BadCall(
                        message="__index: unknown struct field: " + key,
                        span=call_span,
                      )
                  }
                _ =>
                  raise TypeError::BadCall(
                    message="__index: struct field index must be string literal",
                    span=call_span,
                  )
              }
            }
            None =>
              raise TypeError::BadCall(
                message="__index: not indexable",
                span=call_span,
              )
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
      let a = type_expr_eff(env, pos_args[0], aliases, effects, allow_effect)
      let b = type_expr_eff(env, pos_args[1], aliases, effects, allow_effect)
      ensure_eq_operand(env, a, pos_args[0].span())
      ensure_eq_operand(env, b, pos_args[1].span())
      if not(type_equal(env, b, a)) && not(int_char_comparable_pair(env, a, b)) {
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
      let a = type_expr_eff(env, pos_args[0], aliases, effects, allow_effect)
      let b = type_expr_eff(env, pos_args[1], aliases, effects, allow_effect)
      ensure_ord_operand(env, a, pos_args[0].span())
      ensure_ord_operand(env, b, pos_args[1].span())
      if not(type_equal(env, b, a)) && not(int_char_comparable_pair(env, a, b)) {
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
      let a = type_expr_eff(env, pos_args[0], aliases, effects, allow_effect)
      ensure_num_operand(env, a, pos_args[0].span())
      a
    }
    _ =>
      type_call_builtin_handler_runtime_memory(
        env, name, builtin_name, args, aliases, effects, allow_effect, call_span,
      )
  }
}
