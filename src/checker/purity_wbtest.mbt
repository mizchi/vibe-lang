///|
fn parse_for_purity(script : String) -> @core.Module raise {
  let parsed : Result[@core.Module, @parser.ParseError] = try? @parser.parse_ast(
    script,
  )
  match parsed {
    Ok(m) => m
    Err(err) => fail("parse error: \{err.to_string()}")
  }
}

///|
test "check_toplevel_purity: pure let passes" {
  let ast = parse_for_purity("let x = 1\nlet y = x + 2")
  let env = type_check(ast) catch {
    err => fail("type error: \{err.to_string()}")
  }
  check_toplevel_purity(env, ast.stmts) catch {
    err => fail("should pass: \{err.to_string()}")
  }
}

///|
test "check_toplevel_purity: pure fn passes" {
  let ast = parse_for_purity("let f = (x: Int) -> Int { x + 1 }")
  let env = type_check(ast) catch {
    err => fail("type error: \{err.to_string()}")
  }
  check_toplevel_purity(env, ast.stmts) catch {
    err => fail("should pass: \{err.to_string()}")
  }
}

///|
test "check_toplevel_purity: let mut rejected" {
  let ast = parse_for_purity("let mut x = 0")
  let env = type_check(ast) catch {
    err => fail("type error: \{err.to_string()}")
  }
  let result : Result[Unit, TypeError] = try? check_toplevel_purity(
    env,
    ast.stmts,
  )
  match result {
    Ok(_) => fail("should have failed")
    Err(TypeError::TopLevelImpure(name~, tier~, ..)) => {
      assert_eq(name, "x")
      assert_eq(tier, TopLevelPurityTier::StateLocal)
    }
    Err(other) => fail("wrong error: \{other.to_string()}")
  }
}

///|
test "check_toplevel_purity: test block allowed" {
  let script =
    #|test "t" {
    #|  let mut x = 0
    #|  x = x + 1
    #|}
  let ast = parse_for_purity(script)
  let env = type_check(ast) catch {
    err => fail("type error: \{err.to_string()}")
  }
  check_toplevel_purity(env, ast.stmts) catch {
    err => fail("should pass: \{err.to_string()}")
  }
}

///|
test "check_toplevel_purity: bench block allowed" {
  let script =
    #|bench "b" {
    #|  let mut x = 0
    #|  x = x + 1
    #|}
  let ast = parse_for_purity(script)
  let env = type_check(ast) catch {
    err => fail("type error: \{err.to_string()}")
  }
  check_toplevel_purity(env, ast.stmts) catch {
    err => fail("should pass: \{err.to_string()}")
  }
}

///|
test "check_toplevel_purity: enum def passes" {
  let ast = parse_for_purity("enum Color { Red; Green; Blue }")
  let env = type_check(ast) catch {
    err => fail("type error: \{err.to_string()}")
  }
  check_toplevel_purity(env, ast.stmts) catch {
    err => fail("should pass: \{err.to_string()}")
  }
}

///|
test "check_toplevel_purity: escape-free builder in fn should be pure" {
  // A function that uses array_builder internally but freezes the result
  // should be considered pure — the builder doesn't escape.
  let script =
    #|let make_arr = () -> Array[Int] {
    #|  do {
    #|    let b = array_builder()
    #|    array_builder_push(b, 1)
    #|    array_builder_push(b, 2)
    #|    array_builder_freeze(b)
    #|  }
    #|}
    #|let xs = make_arr()
  let ast = parse_for_purity(script)
  let env = type_check(ast) catch {
    err => fail("type error: \{err.to_string()}")
  }
  // Currently fails with TopLevelImpure — we want this to pass
  check_toplevel_purity(env, ast.stmts) catch {
    err => fail("should pass for escape-free builder: \{err.to_string()}")
  }
}

///|
test "check_toplevel_purity: for-in at top-level is pure" {
  let script =
    #|let xs = for x in [1, 2, 3] { x + 1 }
  let ast = parse_for_purity(script)
  let env = type_check(ast) catch {
    err => fail("type error: \{err.to_string()}")
  }
  check_toplevel_purity(env, ast.stmts) catch {
    err => fail("should pass: \{err.to_string()}")
  }
}

///|
test "check_toplevel_purity: chained pure call propagation" {
  let script =
    #|let f = () -> Int { 1 }
    #|let g = () -> Int { f() }
    #|let x = g()
  let ast = parse_for_purity(script)
  let env = type_check(ast) catch {
    err => fail("type error: \{err.to_string()}")
  }
  check_toplevel_purity(env, ast.stmts) catch {
    err => fail("should pass: \{err.to_string()}")
  }
}

///|
test "check_toplevel_purity: call chain keeps state_local tier" {
  let script =
    #|let next = () -> Int {
    #|  let mut x = 0
    #|  x = x + 1
    #|  x
    #|}
    #|let y = next()
  let ast = parse_for_purity(script)
  let env = type_check(ast) catch {
    err => fail("type error: \{err.to_string()}")
  }
  let result : Result[Unit, TypeError] = try? check_toplevel_purity(
    env,
    ast.stmts,
  )
  match result {
    Ok(_) => fail("should have failed")
    Err(TypeError::TopLevelImpure(name~, tier~, ..)) => {
      assert_eq(name, "y")
      assert_eq(tier, TopLevelPurityTier::StateLocal)
    }
    Err(other) => fail("wrong error: \{other.to_string()}")
  }
}
