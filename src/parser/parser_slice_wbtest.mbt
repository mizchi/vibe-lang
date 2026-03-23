///|
test "parse string slice s[i:j] desugars to __slice" {
  let module_ = parse_ast("let x = s[1:3]")
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
test "parse string slice s[:j] desugars to __slice with 0 start" {
  let module_ = parse_ast("let x = s[:3]")
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
test "parse string slice s[i:] desugars to block with __len" {
  let module_ = parse_ast("let x = s[1:]")
  match module_.stmts[0] {
    @core.Stmt::Let(name="x", expr=@core.Expr::Block(body~, ..), ..) => {
      let temp_name = match body.stmts[0] {
        @core.Stmt::Let(name~, ..) => name
        _ => fail("expected temp let in s[i:] block")
      }
      match body.stmts[1] {
        @core.Stmt::Expr(expr=@core.Expr::Call(name="__slice", args~, ..), ..) =>
          match args[2].expr {
            @core.Expr::Call(name="__len", args=len_args, ..) => {
              assert_eq(len_args.length(), 1)
              match len_args[0].expr {
                @core.Expr::Ident(name~, ..) => assert_eq(name, temp_name)
                _ => fail("expected __len temp ident")
              }
            }
            _ => fail("expected __len call")
          }
        _ => fail("expected __slice expr in s[i:] block")
      }
    }
    _ => fail("expected let with block expr for s[i:]")
  }
}

///|
test "parse string slice s[:] desugars to full copy via __len" {
  let module_ = parse_ast("let x = s[:]")
  match module_.stmts[0] {
    @core.Stmt::Let(name="x", expr=@core.Expr::Block(body~, ..), ..) => {
      let temp_name = match body.stmts[0] {
        @core.Stmt::Let(name~, ..) => name
        _ => fail("expected temp let in s[:] block")
      }
      match body.stmts[1] {
        @core.Stmt::Expr(expr=@core.Expr::Call(name="__slice", args~, ..), ..) =>
          match args[2].expr {
            @core.Expr::Call(name="__len", args=len_args, ..) => {
              assert_eq(len_args.length(), 1)
              match len_args[0].expr {
                @core.Expr::Ident(name~, ..) => assert_eq(name, temp_name)
                _ => fail("expected __len temp ident")
              }
            }
            _ => fail("expected __len call")
          }
        _ => fail("expected __slice expr in s[:] block")
      }
    }
    _ => fail("expected let with block expr for s[:]")
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
