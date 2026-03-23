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

///|
test "collect pat binding kinds uses ctor arg kinds" {
  let ctx = CodegenCtx::new(false)
  ctx.enum_ctor_arg_kinds["VFloat"] = [ValueKind::BoxedF64]
  let pat = @core.Pat::Ctor(
    name="VFloat",
    args=[@core.Pat::Bind(name="x", span=@core.Span::empty(0))],
    span=@core.Span::empty(0),
  )
  let out : Map[String, ValueKind] = {}
  collect_pat_binding_kinds_codegen(ctx, pat, ValueKind::I64, out)
  assert_eq(out["x"], ValueKind::BoxedF64)
}

///|
test "infer match arm kind uses ctor-bound double locals" {
  let ctx = CodegenCtx::new(false)
  ctx.enum_ctor_arg_kinds["VFloat"] = [ValueKind::BoxedF64]
  ctx.local_kinds["v"] = ValueKind::I64
  let span = @core.Span::empty(0)
  let expr = @core.Expr::Match(
    scrutinee=@core.Expr::Ident(name="v", span~),
    arms=[
      {
        pat: @core.Pat::Ctor(
          name="VFloat",
          args=[@core.Pat::Bind(name="x", span~)],
          span~,
        ),
        cond: None,
        expr: @core.Expr::Call(
          name="__mul",
          type_args=[],
          args=[
            { label: None, expr: @core.Expr::Ident(name="x", span~), span },
            { label: None, expr: @core.Expr::Double(value=2.0, span~), span },
          ],
          span~,
        ),
        span,
      },
    ],
    span~,
  )
  assert_eq(infer_expr_kind(ctx, expr), ValueKind::BoxedF64)
}
