///|
fn prelude_value_name_map(stmts : Array[@core.Stmt]) -> Map[String, Bool] {
  let names : Map[String, Bool] = {}
  for stmt in stmts {
    match prelude_stmt_value_name(stmt) {
      Some(name) => names[name] = true
      None => ()
    }
  }
  names
}

///|
test "prelude partition keeps logic and option helpers core-eligible" {
  let (core_stmts, builtin_stmts) = _prelude_partition_value_stmts(
    prelude_ast(),
  )
  let core_names = prelude_value_name_map(core_stmts)
  let builtin_names = prelude_value_name_map(builtin_stmts)
  assert_true(core_names.contains("not"))
  assert_true(core_names.contains("and"))
  assert_true(core_names.contains("or"))
  assert_true(core_names.contains("iter_require"))
  assert_true(core_names.contains("option_map"))
  assert_true(core_names.contains("option_flat_map"))
  assert_true(core_names.contains("option_or_else"))
  assert_true(core_names.contains("option_is_some"))
  assert_true(core_names.contains("option_is_none"))
  assert_false(builtin_names.contains("option_map"))
  assert_false(builtin_names.contains("option_is_none"))
}

///|
test "prelude partition keeps builtin-dependent helpers out of core set" {
  let (core_stmts, builtin_stmts) = _prelude_partition_value_stmts(
    prelude_ast(),
  )
  let core_names = prelude_value_name_map(core_stmts)
  let builtin_names = prelude_value_name_map(builtin_stmts)
  assert_true(builtin_names.contains("add"))
  assert_true(builtin_names.contains("sub"))
  assert_true(builtin_names.contains("assert"))
  assert_true(builtin_names.contains("assert_eq"))
  assert_true(builtin_names.contains("to_string"))
  assert_true(builtin_names.contains("iter_length"))
  assert_true(builtin_names.contains("iter_get"))
  assert_true(builtin_names.contains("Array::map"))
  assert_true(builtin_names.contains("Array::join"))
  assert_true(builtin_names.contains("string_concat_all"))
  assert_true(builtin_names.contains("Map::get_or"))
  assert_false(core_names.contains("add"))
  assert_false(core_names.contains("assert_eq"))
  assert_false(core_names.contains("Array::map"))
}

///|
test "prelude partition covers every value statement exactly once" {
  let ast = prelude_ast()
  let (core_stmts, builtin_stmts) = _prelude_partition_value_stmts(ast)
  let all_names : Map[String, Bool] = {}
  let core_names = prelude_value_name_map(core_stmts)
  let builtin_names = prelude_value_name_map(builtin_stmts)
  let mut total_value_stmts = 0
  for stmt in ast.stmts {
    match prelude_stmt_value_name(stmt) {
      Some(name) => {
        all_names[name] = true
        total_value_stmts += 1
      }
      None => ()
    }
  }
  assert_eq(core_stmts.length() + builtin_stmts.length(), total_value_stmts)
  for name, _ in all_names {
    assert_true(core_names.contains(name) || builtin_names.contains(name))
    assert_false(core_names.contains(name) && builtin_names.contains(name))
  }
}

///|
test "prelude reachable values keep transitive deps and respect shadowing" {
  let roots : Map[String, Bool] = { "Array::sort": true }
  let shadowed : Map[String, Bool] = { "div": true }
  let names = prelude_value_name_map(
    prelude_reachable_value_stmts(roots, shadowed),
  )
  assert_true(names.contains("Array::sort"))
  assert_true(names.contains("lt"))
  assert_false(names.contains("div"))
  assert_false(names.contains("Array::map"))
}
