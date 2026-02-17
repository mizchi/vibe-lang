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
    Err(TypeError::TopLevelImpure(name~, ..)) => assert_eq(name, "x")
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
