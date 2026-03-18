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
    "String::from_char_code" =>
      check_builtin_simple(
        env,
        "String::from_char_code",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Int],
        @core.Type::String,
        false,
      )
    "Char::to_int" =>
      check_builtin_simple(
        env,
        "Char::to_int",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Char],
        @core.Type::Int,
        false,
      )
    "Char::from_int" =>
      check_builtin_simple(
        env,
        "Char::from_int",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Int],
        @core.Type::Char,
        false,
      )
    "StringBuilder::new" =>
      check_builtin_simple(
        env,
        "StringBuilder::new",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [],
        @core.Type::StringBuilder,
        true,
      )
    "StringBuilder::push" =>
      check_builtin_simple(
        env,
        "StringBuilder::push",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::StringBuilder, @core.Type::String],
        @core.Type::Unit,
        true,
      )
    "StringBuilder::freeze" =>
      check_builtin_simple(
        env,
        "StringBuilder::freeze",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::StringBuilder],
        @core.Type::String,
        true,
      )
    "Bytes::new" =>
      check_builtin_simple(
        env,
        "Bytes::new",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [],
        @core.Type::Bytes,
        true,
      )
    "Bytes::length" =>
      check_builtin_simple(
        env,
        "Bytes::length",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Bytes],
        @core.Type::Int,
        false,
      )
    "Bytes::get" =>
      check_builtin_simple(
        env,
        "Bytes::get",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Bytes, @core.Type::Int],
        @core.Type::Int,
        false,
      )
    "Bytes::set" =>
      check_builtin_simple(
        env,
        "Bytes::set",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Bytes, @core.Type::Int, @core.Type::Int],
        @core.Type::Unit,
        true,
      )
    "Bytes::push" =>
      check_builtin_simple(
        env,
        "Bytes::push",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Bytes, @core.Type::Int],
        @core.Type::Unit,
        true,
      )
    "Bytes::concat" =>
      check_builtin_simple(
        env,
        "Bytes::concat",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Bytes, @core.Type::Bytes],
        @core.Type::Bytes,
        false,
      )
    "Bytes::slice" =>
      check_builtin_simple(
        env,
        "Bytes::slice",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Bytes, @core.Type::Int, @core.Type::Int],
        @core.Type::Bytes,
        false,
      )
    "Bytes::from_array" =>
      check_builtin_simple(
        env,
        "Bytes::from_array",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Array(@core.Type::Int)],
        @core.Type::Bytes,
        false,
      )
    "Bytes::to_array" =>
      check_builtin_simple(
        env,
        "Bytes::to_array",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Bytes],
        @core.Type::Array(@core.Type::Int),
        false,
      )
    "Bytes::from_string" =>
      check_builtin_simple(
        env,
        "Bytes::from_string",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String],
        @core.Type::Bytes,
        false,
      )
    "Bytes::to_string" =>
      check_builtin_simple(
        env,
        "Bytes::to_string",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Bytes],
        @core.Type::String,
        false,
      )
    "ArrayBuilder::new" =>
      check_builtin_simple(
        env,
        "ArrayBuilder::new",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [],
        @core.Type::ArrayBuilder(fresh_type_var(env)),
        true,
      )
    "ArrayBuilder::push" => {
      let pos_args = prepare_builtin_pos_args(
        env, "ArrayBuilder::push", args, 2, effects, allow_effect, call_span, true,
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
    "ArrayBuilder::freeze" => {
      let pos_args = prepare_builtin_pos_args(
        env, "ArrayBuilder::freeze", args, 1, effects, allow_effect, call_span, true,
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
    "MapBuilder::new" =>
      check_builtin_simple(
        env,
        "MapBuilder::new",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [],
        @core.Type::MapBuilder(fresh_type_var(env), fresh_type_var(env)),
        true,
      )
    "MapBuilder::set" => {
      let pos_args = prepare_builtin_pos_args(
        env, "MapBuilder::set", args, 3, effects, allow_effect, call_span, true,
      )
      let builder_ty = type_expr_eff(
        env,
        pos_args[0],
        aliases,
        effects,
        allow_effect,
      )
      let key_arg_ty = type_expr_eff(
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
      let (key_ty, elem_ty) = expect_map_builder_elem_type(
        env,
        builder_ty,
        pos_args[0].span(),
      )
      ensure_type(env, key_arg_ty, key_ty, pos_args[1].span(), "argument")
      ensure_map_key_hashable(env, key_arg_ty, pos_args[1].span())
      ensure_type(env, value_ty, elem_ty, pos_args[2].span(), "argument")
      @core.Type::Unit
    }
    "MapBuilder::freeze" => {
      let pos_args = prepare_builtin_pos_args(
        env, "MapBuilder::freeze", args, 1, effects, allow_effect, call_span, true,
      )
      let builder_ty = type_expr_eff(
        env,
        pos_args[0],
        aliases,
        effects,
        allow_effect,
      )
      let (key_ty, elem_ty) = expect_map_builder_elem_type(
        env,
        builder_ty,
        pos_args[0].span(),
      )
      @core.Type::Map(key_ty, elem_ty)
    }
    "array_new" => {
      let _ = check_positional_arity(args, "array_new", 0, call_span)
      @core.Type::Array(fresh_type_var(env))
    }
    "Array::length" | "FixedArray::length" => {
      let pos_args = check_positional_arity(args, "Array::length", 1, call_span)
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
    "Array::get" | "FixedArray::get" => {
      let pos_args = check_positional_arity(args, "Array::get", 2, call_span)
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
    "FixedArray::make" => {
      let pos_args = check_positional_arity(
        args, "FixedArray::make", 2, call_span,
      )
      let _ = check_arg_type(
        env,
        pos_args[0],
        @core.Type::Int,
        aliases,
        effects,
        allow_effect,
      )
      let elem_ty = type_expr_eff(
        env,
        pos_args[1],
        aliases,
        effects,
        allow_effect,
      )
      @core.Type::Array(elem_ty)
    }
    "Array::push" => {
      let pos_args = check_positional_arity(args, "Array::push", 2, call_span)
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
    "Array::push_all" => {
      let pos_args = check_positional_arity(
        args, "Array::push_all", 2, call_span,
      )
      let dst_ty = type_expr_eff(
        env,
        pos_args[0],
        aliases,
        effects,
        allow_effect,
      )
      let _ = check_arg_type(
        env,
        pos_args[1],
        dst_ty,
        aliases,
        effects,
        allow_effect,
      )
      @core.Type::Unit
    }
    "Array::set" | "FixedArray::set" | "FixedArray::unsafe_set" => {
      let pos_args = check_positional_arity(args, "Array::set", 3, call_span)
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
    "FixedArray::blit" => {
      let pos_args = check_positional_arity(
        args, "FixedArray::blit", 5, call_span,
      )
      let dst_ty = type_expr_eff(
        env,
        pos_args[0],
        aliases,
        effects,
        allow_effect,
      )
      let _ = expect_array_elem_type(env, dst_ty, pos_args[0].span())
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
        dst_ty,
        aliases,
        effects,
        allow_effect,
      )
      let _ = check_arg_type(
        env,
        pos_args[3],
        @core.Type::Int,
        aliases,
        effects,
        allow_effect,
      )
      let _ = check_arg_type(
        env,
        pos_args[4],
        @core.Type::Int,
        aliases,
        effects,
        allow_effect,
      )
      @core.Type::Unit
    }
    "Array::truncate" => {
      let pos_args = check_positional_arity(
        args, "Array::truncate", 2, call_span,
      )
      let _ = type_expr_eff(env, pos_args[0], aliases, effects, allow_effect)
      let _ = check_arg_type(
        env,
        pos_args[1],
        @core.Type::Int,
        aliases,
        effects,
        allow_effect,
      )
      @core.Type::Unit
    }
    "Array::slice" => {
      let pos_args = check_positional_arity(args, "Array::slice", 3, call_span)
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
    "Map::get" => {
      let pos_args = check_positional_arity(args, "Map::get", 2, call_span)
      let map_ty = type_expr_eff(
        env,
        pos_args[0],
        aliases,
        effects,
        allow_effect,
      )
      let key_arg_ty = type_expr_eff(
        env,
        pos_args[1],
        aliases,
        effects,
        allow_effect,
      )
      let (key_ty, elem_ty) = expect_map_elem_type(
        env,
        map_ty,
        pos_args[0].span(),
      )
      ensure_type(env, key_arg_ty, key_ty, pos_args[1].span(), "argument")
      ensure_map_key_hashable(env, key_arg_ty, pos_args[1].span())
      elem_ty
    }
    "Map::set" => {
      let pos_args = check_positional_arity(args, "Map::set", 3, call_span)
      let map_ty = type_expr_eff(
        env,
        pos_args[0],
        aliases,
        effects,
        allow_effect,
      )
      let key_arg_ty = type_expr_eff(
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
      let (key_ty, elem_ty) = expect_map_elem_type(
        env,
        map_ty,
        pos_args[0].span(),
      )
      ensure_type(env, key_arg_ty, key_ty, pos_args[1].span(), "argument")
      ensure_map_key_hashable(env, key_arg_ty, pos_args[1].span())
      ensure_type(env, value_ty, elem_ty, pos_args[2].span(), "argument")
      map_ty
    }
    "String::length"
    | "String::utf8_length"
    | "String::utf16_length"
    | "String::unicode_length" =>
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
    "Int::parse" =>
      check_builtin_simple(
        env,
        "Int::parse",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String],
        @core.Type::Int,
        false,
      )
    "Double::parse" =>
      check_builtin_simple(
        env,
        "Double::parse",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String],
        @core.Type::Double,
        false,
      )
    "String::char_code_at" =>
      check_builtin_simple(
        env,
        "String::char_code_at",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String, @core.Type::Int],
        @core.Type::Int,
        false,
      )
    "String::substring" =>
      check_builtin_simple(
        env,
        "String::substring",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String, @core.Type::Int, @core.Type::Int],
        @core.Type::String,
        false,
      )
    "String::concat" =>
      check_builtin_simple(
        env,
        "String::concat",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String, @core.Type::String],
        @core.Type::String,
        false,
      )
    "String::equals" =>
      check_builtin_simple(
        env,
        "String::equals",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String, @core.Type::String],
        @core.Type::Bool,
        false,
      )
    "String::split" =>
      check_builtin_simple(
        env,
        "String::split",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::String, @core.Type::String],
        @core.Type::Array(@core.Type::String),
        false,
      )
    "String::index_of" | "String::last_index_of" | "String::count" =>
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
    "String::contains" | "String::starts_with" | "String::ends_with" =>
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
    "String::trim" | "String::trim_start" | "String::trim_end" =>
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
    "String::replace" | "String::replace_all" =>
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
    "Int::abs" | "Int::signum" =>
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
    "Int::is_even" | "Int::is_odd" =>
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
    "Int::max" | "Int::min" =>
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
    "Int::clamp" =>
      check_builtin_simple(
        env,
        "Int::clamp",
        args,
        aliases,
        effects,
        allow_effect,
        call_span,
        [@core.Type::Int, @core.Type::Int, @core.Type::Int],
        @core.Type::Int,
        false,
      )
    "Double::abs" =>
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
    "Double::max" | "Double::min" =>
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
    "Double::floor" | "Double::ceil" =>
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
    "String::to_upper" | "String::to_lower" =>
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
      let resolved_a = resolve_type(env, a)
      if not(resolved_a == @core.Type::String) {
        ensure_num_operand(env, a, pos_args[0].span())
      }
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
        @core.Type::Map(key_ty, _) => {
          ensure_type(env, index_ty, key_ty, pos_args[1].span(), "index")
          ensure_map_key_hashable(env, index_ty, pos_args[1].span())
          if not(
              type_equal(
                env,
                resolved_container,
                @core.Type::Map(key_ty, elem_ty),
              ),
            ) {
            raise TypeError::Mismatch(
              expected=@core.Type::Map(key_ty, elem_ty),
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
        @core.Type::String => {
          if not(type_equal(env, index_ty, @core.Type::Int)) {
            raise TypeError::Mismatch(
              expected=@core.Type::Int,
              actual=index_ty,
              span=pos_args[1].span(),
              context=Some("string index"),
            )
          }
          @core.Type::String
        }
        @core.Type::Bytes => {
          if not(type_equal(env, index_ty, @core.Type::Int)) {
            raise TypeError::Mismatch(
              expected=@core.Type::Int,
              actual=index_ty,
              span=pos_args[1].span(),
              context=Some("bytes index"),
            )
          }
          @core.Type::Int
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
    "__slice" => {
      let pos_args = extract_positional_args(args, "__slice", call_span)
      if pos_args.length() != 3 {
        raise TypeError::BadCall(message="__slice", span=call_span)
      }
      let container_ty = type_expr_eff(
        env,
        pos_args[0],
        aliases,
        effects,
        allow_effect,
      )
      let _start_ty = type_expr_eff(
        env,
        pos_args[1],
        aliases,
        effects,
        allow_effect,
      )
      let _end_ty = type_expr_eff(
        env,
        pos_args[2],
        aliases,
        effects,
        allow_effect,
      )
      let resolved_container = resolve_type(env, container_ty)
      match resolved_container {
        @core.Type::String => @core.Type::String
        @core.Type::Array(elem_ty) => @core.Type::Array(elem_ty)
        @core.Type::Bytes => @core.Type::Bytes
        _ =>
          raise TypeError::BadCall(
            message="__slice: not sliceable",
            span=call_span,
          )
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
