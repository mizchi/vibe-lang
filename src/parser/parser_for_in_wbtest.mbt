///|
fn for_in_len_call_name(stmt : @core.Stmt) -> String? {
  match stmt {
    @core.Stmt::Expr(expr=@core.Expr::Do(body~, ..), ..) =>
      if body.stmts.length() < 6 {
        None
      } else {
        match body.stmts[2] {
          @core.Stmt::Let(expr=@core.Expr::Call(name~, ..), ..) => Some(name)
          _ => None
        }
      }
    _ => None
  }
}

///|
fn for_in_require_call_name(stmt : @core.Stmt) -> String? {
  match stmt {
    @core.Stmt::Expr(expr=@core.Expr::Do(body~, ..), ..) =>
      if body.stmts.length() < 6 {
        None
      } else {
        match body.stmts[1] {
          @core.Stmt::Let(expr=@core.Expr::Call(name~, ..), ..) => Some(name)
          _ => None
        }
      }
    _ => None
  }
}

///|
fn for_in_item_call_name(stmt : @core.Stmt) -> String? {
  match stmt {
    @core.Stmt::Expr(expr=@core.Expr::Do(body~, ..), ..) =>
      if body.stmts.length() < 6 {
        None
      } else {
        match body.stmts[5] {
          @core.Stmt::Expr(expr=@core.Expr::While(body=while_body, ..), ..) =>
            if while_body.stmts.length() == 0 {
              None
            } else {
              match while_body.stmts[0] {
                @core.Stmt::Let(expr=@core.Expr::Call(name~, ..), ..) =>
                  Some(name)
                _ => None
              }
            }
          _ => None
        }
      }
    _ => None
  }
}

///|
test "for-in desugar uses iter_length and iter_get helpers" {
  let ast = parse_ast("for x in [1, 2, 3] { x * 2 }") catch {
    err => abort("parse failed: " + err.diagnostic().message)
  }
  assert_eq(ast.stmts.length(), 1)
  assert_eq(for_in_require_call_name(ast.stmts[0]), Some("iter_require"))
  assert_eq(for_in_len_call_name(ast.stmts[0]), Some("iter_length"))
  assert_eq(for_in_item_call_name(ast.stmts[0]), Some("iter_get"))
}

///|
test "for-in with index binding also uses iter_get helper" {
  let ast = parse_ast("for i, x in [10, 20, 30] { i + x }") catch {
    err => abort("parse failed: " + err.diagnostic().message)
  }
  assert_eq(ast.stmts.length(), 1)
  assert_eq(for_in_require_call_name(ast.stmts[0]), Some("iter_require"))
  assert_eq(for_in_len_call_name(ast.stmts[0]), Some("iter_length"))
  assert_eq(for_in_item_call_name(ast.stmts[0]), Some("iter_get"))
}
