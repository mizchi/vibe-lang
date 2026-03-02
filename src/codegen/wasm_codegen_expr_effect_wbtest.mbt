///|
fn effect_test_span() -> @core.Span {
  @core.Span::empty(0)
}

///|
fn effect_test_expr_stmt(expr : @core.Expr) -> @core.Stmt {
  @core.Stmt::Expr(expr~, span=effect_test_span())
}

///|
test "compile_expr_handle encodes error-tag catch and typed catch block" {
  let span = effect_test_span()
  let ctx = CodegenCtx::new(false)
  let buf = ByteBuf::new()
  let body = @core.Module::{
    stmts: [effect_test_expr_stmt(@core.Expr::Int(value=1L, span~))],
  }
  let arm = @core.MatchArm::{
    pat: @core.Pat::Bind(name="err", span~),
    cond: None,
    expr: @core.Expr::Int(value=2L, span~),
    span,
  }
  compile_expr_handle(ctx, buf, body, [arm], span) catch {
    err => fail(err.to_string())
  }
  let arr = buf.to_bytes().to_array()
  assert_true(arr.length() >= 10)
  assert_eq(arr[0].to_int(), 2)
  assert_eq(arr[1].to_int(), valtype_byte(ValueKind::I64).to_int())
  assert_eq(arr[2].to_int(), 2)
  assert_eq(arr[3].to_int(), valtype_byte(ValueKind::I64).to_int())
  assert_eq(arr[4].to_int(), 31)
  assert_eq(arr[5].to_int(), valtype_byte(ValueKind::I64).to_int())
  assert_eq(arr[6].to_int(), 1)
  assert_eq(arr[7].to_int(), 0)
  assert_eq(arr[8].to_int(), 0)
  assert_eq(arr[9].to_int(), 0)
}

///|
test "compile_expr_multivalue handle encodes error-tag catch" {
  let span = effect_test_span()
  let ctx = CodegenCtx::new(false)
  let buf = ByteBuf::new()
  let body = @core.Module::{
    stmts: [effect_test_expr_stmt(@core.Expr::Int(value=1L, span~))],
  }
  let arm = @core.MatchArm::{
    pat: @core.Pat::Bind(name="err", span~),
    cond: None,
    expr: @core.Expr::Int(value=2L, span~),
    span,
  }
  let expr = @core.Expr::Handle(body~, arms=[arm], span~)
  compile_expr_multivalue(ctx, buf, expr, [ValueKind::I64]) catch {
    err => fail(err.to_string())
  }
  let arr = buf.to_bytes().to_array()
  assert_true(arr.length() >= 10)
  assert_eq(arr[0].to_int(), 2)
  assert_eq(arr[2].to_int(), 2)
  assert_eq(arr[3].to_int(), valtype_byte(ValueKind::I64).to_int())
  assert_eq(arr[4].to_int(), 31)
  assert_eq(arr[6].to_int(), 1)
  assert_eq(arr[7].to_int(), 0)
}
