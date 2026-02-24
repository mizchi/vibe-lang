///|
fn parse_first_expr_for_typecheck(script : String) -> @core.Expr raise {
  let ast = @parser.parse_ast(script)
  match ast.stmts {
    [@core.Stmt::Expr(expr~, ..)] => expr
    _ => fail("expected a single expression statement")
  }
}

///|
test "type_expr_eff: loop param purity tier is state_local" {
  let expr = parse_first_expr_for_typecheck("loop (i = 0) { break i }") catch {
    err => fail("parse error: \{err.to_string()}")
  }
  let env = TypeEnv::new()
  let aliases : Map[String, @core.Ref] = {}
  let _ = type_expr_eff(env, expr, aliases, effect_scope_all(), true) catch {
    err => fail(err.to_string())
  }
  match env.get_purity_tier("i") {
    Some(tier) => assert_eq(tier, TopLevelPurityTier::StateLocal)
    None => fail("expected loop param purity tier")
  }
}

///|
test "type_check: handle resume value must match continuation destination type" {
  let script = "let run = () -> Int with { Error } {\n" +
    "  handle {\n" +
    "    let resumed: Int = perform(\"boom\")\n" +
    "    resumed\n" +
    "  } {\n" +
    "    Error(_) => resume(\"oops\")\n" +
    "  }\n" +
    "}"
  let ast = @parser.parse_ast(script) catch {
    err => fail("parse error: \{err.to_string()}")
  }
  let result : Result[TypeEnv, TypeError] = try? type_check(ast)
  match result {
    Ok(_) => fail("expected resume value mismatch")
    Err(TypeError::Mismatch(expected~, actual~, context~, ..)) => {
      assert_eq(expected, @core.Type::Int)
      assert_eq(actual, @core.Type::String)
      assert_eq(context, Some("resume value"))
    }
    Err(err) => fail("unexpected type error: " + err.to_string())
  }
}
