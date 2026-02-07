///|
fn parse_and_check(script : String) -> TypeEnv raise {
  let ast = parse_module(script)
  let typed : Result[TypeEnv, TypeError] = try? type_check(ast)
  match typed {
    Ok(env) => env
    Err(err) => fail("type error: \{err.to_string()}")
  }
}

///|
fn parse_module(script : String) -> @core.Module raise {
  let parsed : Result[@core.Module, @parser.ParseError] = try? @parser.parse_ast(
    script,
  )
  match parsed {
    Ok(m) => m
    Err(err) => fail("parse error: \{err.to_string()}")
  }
}

///|
fn fn_param(name : String, ty : @core.Type) -> @core.FuncParam {
  @core.FuncParam::{ name, label: @core.ParamLabel::Positional, ty, bounds: [] }
}

///|
test "trait subtype basic" {
  let script =
    #|trait Eq
    #|impl Eq for Int
  let env = parse_and_check(script)
  let trait_ty = @core.Type::Named(name="Eq", args=[])
  assert_true(is_type_subtype(env, @core.Type::Int, trait_ty))
  assert_false(is_type_subtype(env, @core.Type::String, trait_ty))
}

///|
test "trait subtype generic impl" {
  let script =
    #|trait Eq
    #|impl Eq for Int
    #|impl[T: Eq] Eq for Array[T]
  let env = parse_and_check(script)
  let trait_ty = @core.Type::Named(name="Eq", args=[])
  assert_true(
    is_type_subtype(env, @core.Type::Array(@core.Type::Int), trait_ty),
  )
  assert_false(
    is_type_subtype(env, @core.Type::Array(@core.Type::String), trait_ty),
  )
}

///|
test "api version bump uses subtype relation" {
  let script =
    #|trait Eq
    #|impl Eq for Int
  let env = parse_and_check(script)
  let old_ty = @core.Type::Func(
    params=[fn_param("x", @core.Type::Int)],
    ret=@core.Type::Named(name="Eq", args=[]),
    effects=[],
  )
  let same_ty = @core.Type::Func(
    params=[fn_param("x", @core.Type::Int)],
    ret=@core.Type::Named(name="Eq", args=[]),
    effects=[],
  )
  let narrower_ty = @core.Type::Func(
    params=[fn_param("x", @core.Type::Int)],
    ret=@core.Type::Int,
    effects=[],
  )
  let breaking_ty = @core.Type::Func(
    params=[fn_param("x", @core.Type::Int)],
    ret=@core.Type::String,
    effects=[],
  )
  assert_eq(
    classify_function_api_change(env, old_ty, same_ty),
    ApiVersionBump::Patch,
  )
  assert_eq(
    classify_function_api_change(env, old_ty, narrower_ty),
    ApiVersionBump::Minor,
  )
  assert_eq(
    classify_function_api_change(env, old_ty, breaking_ty),
    ApiVersionBump::Major,
  )
}

///|
test "fn metadata version auto bump" {
  let env = TypeEnv::new()
  let base_script =
    #|let f = (x: Int) -> Int { x }
  let base_ast = parse_module(base_script)
  let env1 = type_check_with_env(env, base_ast, {})
  assert_eq(
    env1.get_fn_version("f"),
    Some(ApiSemver::{ major: 1, minor: 0, patch: 0 }),
  )
  let patch_ast = parse_module("let f = (x: Int) -> Int { x }")
  let env2 = type_check_with_env(env1, patch_ast, {})
  assert_eq(
    env2.get_fn_version("f"),
    Some(ApiSemver::{ major: 1, minor: 0, patch: 1 }),
  )
  let major_ast = parse_module("let f = (x: Int) -> String { \"x\" }")
  let env3 = type_check_with_env(env2, major_ast, {})
  assert_eq(
    env3.get_fn_version("f"),
    Some(ApiSemver::{ major: 2, minor: 0, patch: 0 }),
  )
}
