///|
test "parse string slice s[i..j] desugars to __slice" {
  let module_ = parse_ast("let x = s[1..3]")
  match module_.stmts[0] {
    @core.Stmt::Let(
      name="x",
      expr=@core.Expr::Call(name="__slice", args~, ..),
      ..
    ) => assert_eq(args.length(), 3)
    _ => fail("expected let with __slice call")
  }
}

///|
test "parse string slice s[..j] desugars to __slice with 0 start" {
  let module_ = parse_ast("let x = s[..3]")
  match module_.stmts[0] {
    @core.Stmt::Let(
      name="x",
      expr=@core.Expr::Call(name="__slice", args~, ..),
      ..
    ) => {
      assert_eq(args.length(), 3)
      match args[1].expr {
        @core.Expr::Int(value=0L, ..) => ()
        _ => fail("expected start=0")
      }
    }
    _ => fail("expected let with __slice call")
  }
}

///|
test "parse string slice s[i..] desugars to block with String::length" {
  let module_ = parse_ast("let x = s[1..]")
  match module_.stmts[0] {
    @core.Stmt::Let(name="x", expr=@core.Expr::Block(..), ..) => ()
    _ => fail("expected let with block expr for s[i..]")
  }
}

///|
test "parse regular index s[i] stays as __index" {
  let module_ = parse_ast("let x = s[1]")
  match module_.stmts[0] {
    @core.Stmt::Let(
      name="x",
      expr=@core.Expr::Call(name="__index", args~, ..),
      ..
    ) => assert_eq(args.length(), 2)
    _ => fail("expected let with __index call")
  }
}

///|
test "lex dotdot token" {
  let lexer = Lexer::new("1..2")
  let t1 = lexer.next_token()
  assert_eq(t1.kind, int_lit())
  let t2 = lexer.next_token()
  assert_eq(t2.kind, dotdot())
  let t3 = lexer.next_token()
  assert_eq(t3.kind, int_lit())
}

///|
test "lex raw string r\"hello\\nworld\" has no escapes" {
  let lexer = Lexer::new("r\"hello\\nworld\"")
  let t = lexer.next_token()
  assert_eq(t.kind, string_lit())
  assert_eq(t.text(), "hello\\nworld")
}

///|
test "lex raw string with backslash" {
  let lexer = Lexer::new("r\"a\\\\b\"")
  let t = lexer.next_token()
  assert_eq(t.kind, string_lit())
  assert_eq(t.text(), "a\\\\b")
}
