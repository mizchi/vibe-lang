///|
fn type_call_builtin_handler_runtime_memory(
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
    "__assert" => {
      let pos_args = extract_positional_args(args, "__assert", call_span)
      if pos_args.length() != 1 {
        raise TypeError::BadCall(message="__assert", span=call_span)
      }
      let a = type_expr_eff(env, pos_args[0], aliases, effects, allow_effect)
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
      let pos_args = extract_positional_args(args, "record_set", call_span)
      if pos_args.length() != 3 {
        raise TypeError::BadCall(message="record_set", span=call_span)
      }
      let record_ty = normalize_type(
        env,
        type_expr_eff(env, pos_args[0], aliases, effects, allow_effect),
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
                None => raise TypeError::BadCall(message="record_set", span~)
              }
            _ => ()
          }
        _ => raise TypeError::BadCall(message="record_set", span=call_span)
      }
      record_ty
    }
    "Map::keys" => {
      let pos_args = extract_positional_args(args, "Map::keys", call_span)
      if pos_args.length() != 1 {
        raise TypeError::BadCall(message="Map::keys", span=call_span)
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
        @core.Type::Map(key_ty, _) => @core.Type::Array(key_ty)
        _ => raise TypeError::BadCall(message="Map::keys", span=call_span)
      }
    }
    "Map::values" => {
      let pos_args = extract_positional_args(args, "Map::values", call_span)
      if pos_args.length() != 1 {
        raise TypeError::BadCall(message="Map::values", span=call_span)
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
        @core.Type::Map(_key, elem_ty) => @core.Type::Array(elem_ty)
        _ => raise TypeError::BadCall(message="Map::values", span=call_span)
      }
    }
    "Map::has_key" => {
      let pos_args = extract_positional_args(args, "Map::has_key", call_span)
      if pos_args.length() != 2 {
        raise TypeError::BadCall(message="Map::has_key", span=call_span)
      }
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
      let resolved = normalize_type(env, map_ty)
      match resolved {
        @core.Type::Map(key_ty, _) => {
          ensure_type(env, key_arg_ty, key_ty, pos_args[1].span(), "argument")
          ensure_map_key_hashable(env, key_arg_ty, pos_args[1].span())
        }
        _ => raise TypeError::BadCall(message="Map::has_key", span=call_span)
      }
      @core.Type::Bool
    }
    "Array::slice" => {
      let pos_args = extract_positional_args(args, "Array::slice", call_span)
      if pos_args.length() != 3 {
        raise TypeError::BadCall(message="Array::slice", span=call_span)
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
        _ => raise TypeError::BadCall(message="Array::slice", span=call_span)
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
    "Int::to_float" | "f32_convert_i32_s" =>
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
    "Int::to_double" | "f64_convert_i32_s" =>
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
    "Float::to_int" | "i32_trunc_f32_s" =>
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
    "Float::to_double" | "f64_promote_f32" =>
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
    "Double::to_int" | "i32_trunc_f64_s" =>
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
    "Double::to_i64_bits" =>
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
    "Double::from_i64_bits" =>
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
    "Double::to_float" | "f32_demote_f64" =>
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
    "f32_neg"
    | "f32_abs"
    | "f32_ceil"
    | "f32_floor"
    | "f32_trunc"
    | "f32_nearest"
    | "f32_sqrt" =>
      type_check_unary_convert(
        env,
        args,
        call_span,
        aliases,
        effects,
        allow_effect,
        name,
        @core.Type::Float,
        @core.Type::Float,
      )
    "f64_neg"
    | "f64_abs"
    | "f64_ceil"
    | "f64_floor"
    | "f64_trunc"
    | "f64_nearest"
    | "f64_sqrt" =>
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
    _ =>
      type_call_builtin_handler_json_and_fallback(
        env, name, args, aliases, effects, allow_effect, call_span,
      )
  }
}
