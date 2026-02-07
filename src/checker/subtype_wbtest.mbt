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
fn fn_param_with_bounds(
  name : String,
  ty : @core.Type,
  bounds : Array[String],
) -> @core.FuncParam {
  @core.FuncParam::{
    name,
    label: @core.ParamLabel::Positional,
    ty,
    bounds: bounds.copy(),
  }
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
test "trait subtype supertrait relation" {
  let script =
    #|trait Eq
    #|trait Ord: Eq
    #|impl Ord for Int
  let env = parse_and_check(script)
  let eq_ty = @core.Type::Named(name="Eq", args=[])
  let ord_ty = @core.Type::Named(name="Ord", args=[])
  assert_true(is_type_subtype(env, @core.Type::Int, ord_ty))
  assert_true(is_type_subtype(env, @core.Type::Int, eq_ty))
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
test "api version bump is major when parameter bound is tightened" {
  let old_ty = @core.Type::Func(
    params=[fn_param_with_bounds("x", @core.Type::Int, ["Eq"])],
    ret=@core.Type::Int,
    effects=[],
  )
  let new_ty = @core.Type::Func(
    params=[fn_param_with_bounds("x", @core.Type::Int, ["Eq", "Show"])],
    ret=@core.Type::Int,
    effects=[],
  )
  let env = TypeEnv::new()
  assert_eq(
    classify_function_api_change(env, old_ty, new_ty),
    ApiVersionBump::Major,
  )
}

///|
test "api version bump is minor when parameter bound is loosened" {
  let old_ty = @core.Type::Func(
    params=[fn_param_with_bounds("x", @core.Type::Int, ["Eq", "Show"])],
    ret=@core.Type::Int,
    effects=[],
  )
  let new_ty = @core.Type::Func(
    params=[fn_param_with_bounds("x", @core.Type::Int, ["Eq"])],
    ret=@core.Type::Int,
    effects=[],
  )
  let env = TypeEnv::new()
  assert_eq(
    classify_function_api_change(env, old_ty, new_ty),
    ApiVersionBump::Minor,
  )
}

///|
test "api version bump treats supertrait bound as looser" {
  let script =
    #|trait Eq
    #|trait Ord: Eq
  let env = parse_and_check(script)
  let old_ty = @core.Type::Func(
    params=[fn_param_with_bounds("x", @core.Type::Int, ["Ord"])],
    ret=@core.Type::Int,
    effects=[],
  )
  let new_ty = @core.Type::Func(
    params=[fn_param_with_bounds("x", @core.Type::Int, ["Eq"])],
    ret=@core.Type::Int,
    effects=[],
  )
  assert_eq(
    classify_function_api_change(env, old_ty, new_ty),
    ApiVersionBump::Minor,
  )
}

///|
test "fn metadata version reflects generic parameter bound changes" {
  let env = TypeEnv::new()
  let base_script =
    #|trait Eq
    #|trait Show
    #|impl Eq for Int
    #|impl Show for Int
    #|export let f = [T: Eq](x: T) -> Bool { x == x }
  let base_ast = parse_module(base_script)
  let env1 = type_check_with_env(env, base_ast, {})
  assert_eq(
    env1.get_fn_version("f"),
    Some(ApiSemver::{ major: 1, minor: 0, patch: 0 }),
  )
  let tighten_ast = parse_module(
    "export let f = [T: Eq + Show](x: T) -> Bool { x == x }",
  )
  let env2 = type_check_with_env(env1, tighten_ast, {})
  assert_eq(
    env2.get_fn_version("f"),
    Some(ApiSemver::{ major: 2, minor: 0, patch: 0 }),
  )
  let loosen_ast = parse_module(
    "export let f = [T: Eq](x: T) -> Bool { x == x }",
  )
  let env3 = type_check_with_env(env2, loosen_ast, {})
  assert_eq(
    env3.get_fn_version("f"),
    Some(ApiSemver::{ major: 2, minor: 1, patch: 0 }),
  )
}

///|
test "fn metadata version auto bump" {
  let env = TypeEnv::new()
  let base_script =
    #|export let f = (x: Int) -> Int { x }
  let base_ast = parse_module(base_script)
  let env1 = type_check_with_env(env, base_ast, {})
  assert_eq(
    env1.get_fn_version("f"),
    Some(ApiSemver::{ major: 1, minor: 0, patch: 0 }),
  )
  let patch_ast = parse_module("export let f = (x: Int) -> Int { x }")
  let env2 = type_check_with_env(env1, patch_ast, {})
  assert_eq(
    env2.get_fn_version("f"),
    Some(ApiSemver::{ major: 1, minor: 0, patch: 1 }),
  )
  let major_ast = parse_module("export let f = (x: Int) -> String { \"x\" }")
  let env3 = type_check_with_env(env2, major_ast, {})
  assert_eq(
    env3.get_fn_version("f"),
    Some(ApiSemver::{ major: 2, minor: 0, patch: 0 }),
  )
}

///|
test "fn metadata version is not tracked for non-exported function" {
  let env = TypeEnv::new()
  let base_ast = parse_module("let f = (x: Int) -> Int { x }")
  let env1 = type_check_with_env(env, base_ast, {})
  assert_eq(env1.get_fn_version("f"), None)
  let next_ast = parse_module("let f = (x: Int) -> String { \"x\" }")
  let env2 = type_check_with_env(env1, next_ast, {})
  assert_eq(env2.get_fn_version("f"), None)
}
