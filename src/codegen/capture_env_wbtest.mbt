///|
fn wb_span() -> @core.Span {
  @core.Span::empty(0)
}

///|
fn wb_param(name : String) -> @core.FuncParam {
  @core.FuncParam::{
    name,
    label: @core.ParamLabel::Positional,
    ty: @core.Type::Int,
    bounds: [],
  }
}

///|
fn wb_call(name : String, args : Array[@core.Expr]) -> @core.Expr {
  let span = wb_span()
  let call_args : Array[@core.CallArg] = []
  for arg in args {
    call_args.push(@core.CallArg::{ label: None, expr: arg, span })
  }
  @core.Expr::Call(name~, type_args=[], args=call_args, span~)
}

///|
fn wb_fn(
  params : Array[@core.FuncParam],
  body_stmts : Array[@core.Stmt],
) -> @core.Expr {
  @core.Expr::Fn(
    type_params=[],
    type_bounds={},
    params~,
    ret=Some(@core.Type::Int),
    effects=[],
    body=@core.Module::{ stmts: body_stmts },
    span=wb_span(),
  )
}

///|
fn wb_ident(name : String) -> @core.Expr {
  @core.Expr::Ident(name~, span=wb_span())
}

///|
fn wb_int(value : Int64) -> @core.Expr {
  @core.Expr::Int(value~, span=wb_span())
}

///|
fn wb_let(name : String, expr : @core.Expr) -> @core.Stmt {
  @core.Stmt::Let(rec=false, name~, expr~, span=wb_span())
}

///|
fn wb_expr(expr : @core.Expr) -> @core.Stmt {
  @core.Stmt::Expr(expr~, span=wb_span())
}

///|
fn contains_name(xs : Array[String], target : String) -> Bool {
  for x in xs {
    if x == target {
      return true
    }
  }
  false
}

///|
fn find_func_idx(funcs : Array[FuncDef], name : String) -> Int {
  for i in 0..<funcs.length() {
    match funcs[i].name {
      Some(n) if n == name => return i
      _ => ()
    }
  }
  -1
}

///|
test "capture propagation: nested closure pulls outer value into parent captures" {
  let inner_fn = wb_fn([], [
    wb_expr(wb_call("__add", [wb_ident("y"), wb_ident("z")])),
  ])
  let mid_fn = wb_fn([wb_param("z")], [
    wb_let("inner", inner_fn),
    wb_expr(wb_call("inner", [])),
  ])
  let run_fn = wb_fn([wb_param("x")], [
    wb_let("y", wb_call("__add", [wb_ident("x"), wb_int(1)])),
    wb_let("mid", mid_fn),
    wb_expr(wb_call("mid", [wb_int(2)])),
  ])
  let ast = @core.Module::{ stmts: [wb_let("run", run_fn)] }
  let funcs = collect_func_defs(ast)
  let mid_idx = find_func_idx(funcs, "mid")
  assert_true(mid_idx >= 0)
  assert_true(contains_name(funcs[mid_idx].captures, "y"))
}

///|
test "env requirement: function-only capture still needs closure env" {
  let helper_fn = wb_fn([wb_param("n")], [
    wb_expr(wb_call("__add", [wb_ident("n"), wb_int(1)])),
  ])
  let call_helper_fn = wb_fn([], [wb_expr(wb_call("helper", [wb_int(1)]))])
  let run_fn = wb_fn([], [
    wb_let("call_helper", call_helper_fn),
    wb_expr(wb_call("call_helper", [])),
  ])
  let ast = @core.Module::{
    stmts: [wb_let("helper", helper_fn), wb_let("run", run_fn)],
  }
  let funcs = collect_func_defs(ast)
  let needs = compute_fn_env_requirements(funcs)
  let idx = find_func_idx(funcs, "call_helper")
  assert_true(idx >= 0)
  assert_true(contains_name(funcs[idx].captures, "helper"))
  assert_true(needs[idx])
}
