///|
test "scoped ref profile: module without ref usage disables checks" {
  let script =
    #|let add = (x: Int) -> Int { x + 1 }
    #|add(1)
  let ast = @parser.parse_ast(script)
  let env = get_cached_prelude_env_for_module()
  env.set_scoped_ref_profile_enabled(true)
  let aliases : Map[String, @core.Ref] = {}
  let typed = type_check_with_env(env, ast, aliases)
  let profile = typed.get_scoped_ref_profile()
  assert_false(typed.is_scoped_ref_checks_enabled())
  assert_eq(profile.contains_calls, 0)
  assert_eq(profile.capture_checks, 0)
  assert_eq(profile.call_arg_checks, 0)
  assert_eq(profile.return_checks, 0)
  assert_eq(profile.toplevel_checks, 0)
}

///|
test "scoped ref profile: explicit Ref enables checks" {
  let script =
    #|let keep = (r: Ref[Int]) -> Int { 1 }
  let ast = @parser.parse_ast(script)
  let env = get_cached_prelude_env_for_module()
  env.set_scoped_ref_profile_enabled(true)
  let aliases : Map[String, @core.Ref] = {}
  let result : Result[TypeEnv, TypeError] = try? type_check_with_env(
    env, ast, aliases,
  )
  match result {
    Ok(_) => fail("expected scoped ref function parameter error")
    Err(TypeError::ScopedRefEscape(context~, ..)) =>
      assert_eq(context, "function parameter")
    Err(err) => fail("unexpected error: \{err.to_string()}")
  }
  let profile = env.get_scoped_ref_profile()
  assert_true(env.is_scoped_ref_checks_enabled())
  assert_true(profile.contains_calls > 0)
  assert_eq(profile.toplevel_checks, 0)
}

///|
test "scoped ref profile: repeated checks hit cache" {
  let script =
    #|let keep1 = (x: Json) -> Json { x }
    #|let keep2 = (x: Json) -> Json { x }
    #|let keep3 = (x: Json) -> Json { x }
  let ast = @parser.parse_ast(script)
  let env = get_cached_prelude_env_for_module()
  env.set_scoped_ref_profile_enabled(true)
  let aliases : Map[String, @core.Ref] = {}
  let typed = type_check_with_env(env, ast, aliases)
  let profile = typed.get_scoped_ref_profile()
  let _ = typed
  assert_true(profile.contains_cache_misses > 0)
  assert_true(profile.contains_cache_hits > 0)
}

///|
test "scoped ref cache: cache growth is bounded" {
  let env = TypeEnv::new()
  env.set_scoped_ref_checks_enabled(true)
  for i in 0..<10000 {
    let ty = @core.Type::Named(name="NoRef\{i.to_string()}", args=[])
    ignore(type_contains_scoped_ref(env, ty))
  }
  assert_true(env.scoped_ref_contains_cache.length() <= 4096)
}
