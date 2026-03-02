///|
test "builtin type count includes fs signatures" {
  let ctx = CodegenCtx::new(false)
  ctx.need_fs = true
  assert_eq(builtin_type_count(ctx), 5)
}

///|
test "builtin type count includes socket signatures" {
  let ctx = CodegenCtx::new(false)
  ctx.need_socket = true
  assert_eq(builtin_type_count(ctx), 10)
}

///|
test "builtin type count includes fs and socket together" {
  let ctx = CodegenCtx::new(false)
  ctx.need_fs = true
  ctx.need_socket = true
  assert_eq(builtin_type_count(ctx), 15)
}

///|
test "infer kind treats mut-captured locals as boxed values" {
  let ctx = CodegenCtx::new(false)
  ctx.local_kinds["x"] = ValueKind::I32
  ctx.mut_captured_vars["x"] = true
  let expr = @core.Expr::Ident(name="x", span=@core.Span::empty(0))
  assert_eq(infer_expr_kind(ctx, expr), ValueKind::I64)
}
