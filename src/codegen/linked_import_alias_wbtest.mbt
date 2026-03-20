///|
fn linked_alias_span() -> @core.Span {
  @core.Span::empty(0)
}

///|
fn linked_alias_arg(expr : @core.Expr) -> @core.CallArg {
  { label: None, expr, span: linked_alias_span() }
}

///|
test "top-level linked import alias compiles" {
  let span = linked_alias_span()
  let ast = @core.Module::{
    stmts: [
      @core.Stmt::Let(
        rec=false,
        name="alias",
        expr=@core.Expr::Ident(name="add", span~),
        span~,
      ),
      @core.Stmt::Let(
        rec=false,
        name="run",
        expr=@core.Expr::Fn(
          type_params=[],
          type_bounds={},
          params=[],
          ret=Some(@core.Type::Int),
          effects=[],
          body=@core.Module::{
            stmts: [
              @core.Stmt::Expr(
                expr=@core.Expr::Call(
                  name="alias",
                  type_args=[],
                  args=[
                    linked_alias_arg(@core.Expr::Int(value=1L, span~)),
                    linked_alias_arg(@core.Expr::Int(value=2L, span~)),
                  ],
                  span~,
                ),
                span~,
              ),
            ],
          },
          span~,
        ),
        span~,
      ),
    ],
  }
  let wasm = try
    emit_module_wasm_with_options(
      ast,
      wasm_emit_options(linked_imports=[("lib", "add", 2, 1)]),
    )
  catch {
    err => fail(err.to_string())
  } noraise {
    bytes => bytes
  }
  assert_true(wasm.length() > 8)
  assert_eq(wasm[0], (0).to_byte())
  assert_eq(wasm[1], (97).to_byte())
  assert_eq(wasm[2], (115).to_byte())
  assert_eq(wasm[3], (109).to_byte())
}
