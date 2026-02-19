///|
fn type_check_for_monoify_test(ast : @core.Module) -> @checker.TypeEnv raise {
  let typed : Result[@checker.TypeEnv, @checker.TypeError] = try? @checker.type_check(
    ast,
  )
  match typed {
    Ok(env) => env
    Err(err) => fail("type error: \{err.to_string()}")
  }
}

///|
fn monoify_test_span(id : Int) -> @core.Span {
  { start: id * 10, end: id * 10 + 1 }
}

///|
fn monoify_test_num_type() -> @core.Type {
  @core.Type::Named(name="Num", args=[])
}

///|
fn monoify_test_num_param(name : String) -> @core.FuncParam {
  @core.FuncParam::{
    name,
    label: @core.ParamLabel::Positional,
    ty: monoify_test_num_type(),
    bounds: [],
  }
}

///|
fn monoify_test_arg(expr : @core.Expr, id : Int) -> @core.CallArg {
  @core.CallArg::{ label: None, expr, span: monoify_test_span(id) }
}

///|
test "monoify_module rewrites local Num add call to specialized symbol" {
  let x_ident = @core.Expr::Ident(name="x", span=monoify_test_span(1))
  let y_ident = @core.Expr::Ident(name="y", span=monoify_test_span(2))
  let add_body_call = @core.Expr::Call(
    name="__add",
    type_args=[],
    args=[monoify_test_arg(x_ident, 3), monoify_test_arg(y_ident, 4)],
    span=monoify_test_span(5),
  )
  let add_fn_expr = @core.Expr::Fn(
    type_params=[],
    type_bounds={},
    params=[monoify_test_num_param("x"), monoify_test_num_param("y")],
    ret=Some(monoify_test_num_type()),
    effects=[],
    body={
      stmts: [@core.Stmt::Expr(expr=add_body_call, span=monoify_test_span(6))],
    },
    span=monoify_test_span(7),
  )
  let value_expr = @core.Expr::Call(
    name="add",
    type_args=[],
    args=[
      monoify_test_arg(@core.Expr::Int(value=1L, span=monoify_test_span(8)), 9),
      monoify_test_arg(
        @core.Expr::Int(value=2L, span=monoify_test_span(10)),
        11,
      ),
    ],
    span=monoify_test_span(12),
  )
  let ast : @core.Module = {
    stmts: [
      @core.Stmt::Let(
        rec=false,
        name="add",
        expr=add_fn_expr,
        span=monoify_test_span(13),
      ),
      @core.Stmt::Let(
        rec=false,
        name="value",
        expr=value_expr,
        span=monoify_test_span(14),
      ),
    ],
  }
  let env = type_check_for_monoify_test(ast)
  let result = monoify_module(ast, env)
  assert_true(result.instantiations.contains("add:i32"))
  let mut has_specialized_def = false
  let mut value_calls_specialized = false
  for stmt in result.ast.stmts {
    match stmt {
      @core.Stmt::Let(name~, expr~, ..) => {
        if name == "add$i32" {
          has_specialized_def = true
        }
        if name == "value" {
          match expr {
            @core.Expr::Call(name=call_name, ..) =>
              if call_name == "add$i32" {
                value_calls_specialized = true
              }
            _ => ()
          }
        }
      }
      _ => ()
    }
  }
  assert_true(has_specialized_def)
  assert_true(value_calls_specialized)
}
