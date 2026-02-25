///|
test "type_check: plain call does not fallback to record field access" {
  let script =
    #|let r = record { a: 1 }
    #|a(r)
  let ast = @parser.parse_ast(script) catch {
    err => fail("parse error: \{err.to_string()}")
  }
  let result : Result[TypeEnv, TypeError] = try? type_check(ast)
  match result {
    Ok(_) => fail("expected call-style field fallback to be rejected")
    Err(TypeError::UnknownName(..)) => ()
    Err(TypeError::BadCall(..)) => ()
    Err(err) => fail("unexpected error: \{err.to_string()}")
  }
}

///|
test "type_check: dot property access on record stays valid" {
  let script =
    #|let r = record { a: 1 }
    #|r.a
  let ast = @parser.parse_ast(script) catch {
    err => fail("parse error: \{err.to_string()}")
  }
  let result : Result[TypeEnv, TypeError] = try? type_check(ast)
  match result {
    Ok(_) => ()
    Err(err) => fail("expected record property access to type-check: \{err.to_string()}")
  }
}

///|
test "type_check: dot property access on struct stays valid" {
  let script =
    #|struct User { name : String; age : Int; }
    #|let u = User::{ name: "alice"; age: 20 }
    #|u.age
  let ast = @parser.parse_ast(script) catch {
    err => fail("parse error: \{err.to_string()}")
  }
  let result : Result[TypeEnv, TypeError] = try? type_check(ast)
  match result {
    Ok(_) => ()
    Err(err) => fail("expected struct property access to type-check: \{err.to_string()}")
  }
}
