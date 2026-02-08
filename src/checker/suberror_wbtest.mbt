///|
fn parse_module_suberror(script : String) -> @core.Module raise {
  let parsed : Result[@core.Module, @parser.ParseError] = try? @parser.parse_ast(
    script,
  )
  match parsed {
    Ok(m) => m
    Err(err) => fail("parse error: \{err.to_string()}")
  }
}

///|
test "suberror registers Error impl" {
  let script =
    #|suberror AppError {
    #|  Io(String);
    #|}
  let ast = parse_module_suberror(script)
  let serialized = @core.serialize_module(ast)
  assert_true(
    match ast.stmts[0] {
      @core.Stmt::EnumDef(..) => true
      _ => false
    },
  )
  assert_true(serialized.contains("\"TraitImpl\":"))
  let env = type_check(ast) catch {
    err => fail("type error: \{err.to_string()}")
  }
  assert_true(
    type_implements_trait(
      env,
      @core.Type::Named(name="AppError", args=[]),
      "Error",
    ),
  )
}
