///|
fn type_check_for_string_rewrite_test(
  ast : @core.Module,
) -> @checker.TypeEnv raise {
  let typed : Result[@checker.TypeEnv, @checker.TypeError] = try? @checker.type_check(
    ast,
  )
  match typed {
    Ok(env) => env
    Err(err) => fail("type error: \{err.to_string()}")
  }
}

///|
fn rewrite_test_span(id : Int) -> @core.Span {
  { start: id * 10, end: id * 10 + 1 }
}

///|
fn rewrite_test_arg(expr : @core.Expr, id : Int) -> @core.CallArg {
  @core.CallArg::{ label: None, expr, span: rewrite_test_span(id) }
}

///|
test "rewrite_string_add rewrites string add call with expr type contract" {
  let lhs = @core.Expr::String(value="ab", span=rewrite_test_span(1))
  let rhs = @core.Expr::String(value="cd", span=rewrite_test_span(2))
  let add_expr = @core.Expr::Call(
    name="__add",
    type_args=[],
    args=[rewrite_test_arg(lhs, 3), rewrite_test_arg(rhs, 4)],
    span=rewrite_test_span(5),
  )
  let ast : @core.Module = {
    stmts: [@core.Stmt::Expr(expr=add_expr, span=rewrite_test_span(6))],
  }
  let env = type_check_for_string_rewrite_test(ast)
  let rewritten = rewrite_string_add(ast, env.expr_type_index())
  match rewritten.stmts[0] {
    @core.Stmt::Expr(expr~, ..) =>
      match expr {
        @core.Expr::Call(name~, ..) => assert_eq(name, "String::concat")
        _ => fail("expected rewritten call")
      }
    _ => fail("expected expr stmt")
  }
}
