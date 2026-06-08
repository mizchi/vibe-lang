///|
test "record type parses in let annotation" {
  let ast = parse_ast(
    "let msg: record { value: Int, label: String } = record { value: 1, label: \"ok\" }",
  ) catch {
    err => abort("parse failed: " + err.diagnostic().message)
  }
  match ast.stmts[0] {
    @core.Stmt::Let(expr=@core.Expr::Block(body~, ..), ..) =>
      match body.stmts[0] {
        @core.Stmt::Let(expr=@core.Expr::Fn(params~, ..), ..) =>
          match params[0].ty {
            @core.Type::Record(fields) => {
              assert_eq(fields.length(), 2)
              assert_eq(fields["value"], @core.Type::Named(name="Int", args=[]))
              assert_eq(
                fields["label"],
                @core.Type::Named(name="String", args=[]),
              )
            }
            other => fail("expected record type annotation, got \{other}")
          }
        _ => fail("expected annotation helper function")
      }
    _ => fail("expected annotated let wrapper")
  }
}

///|
test "record type parses as generic type argument" {
  let ast = parse_ast(
    "let ch: ThreadChannel[record { value: Int }] = Threads::channel_new(1)",
  ) catch {
    err => abort("parse failed: " + err.diagnostic().message)
  }
  match ast.stmts[0] {
    @core.Stmt::Let(expr=@core.Expr::Block(body~, ..), ..) =>
      match body.stmts[0] {
        @core.Stmt::Let(expr=@core.Expr::Fn(params~, ..), ..) =>
          match params[0].ty {
            @core.Type::Named(
              name="ThreadChannel",
              args=[@core.Type::Record(fields)]
            ) => {
              assert_eq(fields.length(), 1)
              assert_eq(fields["value"], @core.Type::Named(name="Int", args=[]))
            }
            other => fail("expected ThreadChannel[record], got \{other}")
          }
        _ => fail("expected annotation helper function")
      }
    _ => fail("expected annotated let wrapper")
  }
}
