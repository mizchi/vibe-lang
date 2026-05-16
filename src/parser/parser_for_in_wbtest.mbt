///|
test "for-in parses to ForIn AST node" {
  let ast = parse_ast("for x in [1, 2, 3] { x * 2 }") catch {
    err => abort("parse failed: " + err.diagnostic().message)
  }
  assert_eq(ast.stmts.length(), 1)
  match ast.stmts[0] {
    @core.Stmt::Expr(
      expr=@core.Expr::ForIn(value_name~, index_name~, iterable~, body~, ..),
      ..
    ) => {
      assert_eq(value_name, "x")
      @debug.assert_eq(index_name, None)
      // iterable is [1, 2, 3]
      match iterable {
        @core.Expr::Array(items~, ..) => assert_eq(items.length(), 3)
        _ => abort("expected Array iterable")
      }
      // body has one expr stmt: x * 2
      assert_eq(body.stmts.length(), 1)
    }
    _ => abort("expected ForIn expression")
  }
}

///|
test "for-in with index binding parses correctly" {
  let ast = parse_ast("for i, x in [10, 20, 30] { i + x }") catch {
    err => abort("parse failed: " + err.diagnostic().message)
  }
  assert_eq(ast.stmts.length(), 1)
  match ast.stmts[0] {
    @core.Stmt::Expr(expr=@core.Expr::ForIn(value_name~, index_name~, ..), ..) => {
      assert_eq(value_name, "x")
      @debug.assert_eq(index_name, Some("i"))
    }
    _ => abort("expected ForIn expression with index")
  }
}
