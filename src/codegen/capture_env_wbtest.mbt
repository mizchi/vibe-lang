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
fn wb_fn_infer(
  params : Array[@core.FuncParam],
  body_stmts : Array[@core.Stmt],
) -> @core.Expr {
  @core.Expr::Fn(
    type_params=[],
    type_bounds={},
    params~,
    ret=None,
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
test "closure captures const int: env slot allocated unconditionally" {
  // Regression: `let n = 5; let f = () -> Int { n }` must store n in env.
  // Previously, const_i64_values skipped env allocation in compile_expr_fn,
  // but compile_function (inner) ran earlier without const knowledge, causing
  // env index mismatch and reading uninitialized memory.
  let inner = wb_fn([], [wb_expr(wb_ident("n"))])
  let ast = @core.Module::{
    stmts: [wb_let("n", wb_int(5)), wb_let("f", inner)],
  }
  let funcs = collect_func_defs(ast)
  // f captures n even though n is an int literal (const)
  let f_idx = find_func_idx(funcs, "f")
  assert_true(f_idx >= 0)
  assert_true(contains_name(funcs[f_idx].captures, "n"))
}

///|
test "closure captures multiple consts: all env slots present" {
  // `let a = 2; let b = 3; let f = (x: Int) -> Int { x * a + b }`
  let body = wb_call("__add", [
    wb_call("__mul", [wb_ident("x"), wb_ident("a")]),
    wb_ident("b"),
  ])
  let inner = wb_fn([wb_param("x")], [wb_expr(body)])
  let ast = @core.Module::{
    stmts: [
      wb_let("a", wb_int(2)),
      wb_let("b", wb_int(3)),
      wb_let("f", inner),
      wb_expr(wb_call("f", [wb_int(5)])),
    ],
  }
  let funcs = collect_func_defs(ast)
  let f_idx = find_func_idx(funcs, "f")
  assert_true(f_idx >= 0)
  assert_true(contains_name(funcs[f_idx].captures, "a"))
  assert_true(contains_name(funcs[f_idx].captures, "b"))
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

///|
test "nested lambda without return annotation keeps boxed int wasm result" {
  let double_fn = wb_fn_infer([wb_param("x")], [
    wb_expr(wb_call("__mul", [wb_ident("x"), wb_int(2)])),
  ])
  let run_fn = wb_fn([], [wb_let("double", double_fn), wb_expr(wb_int(0))])
  let ast = @core.Module::{ stmts: [wb_let("run", run_fn)] }
  let wat = wasm_to_wat(emit_module_wasm(ast))
  assert_true(wat.contains("(param i64 i32) (result i64)"))
  assert_true(not(wat.contains("(param i64 i32) (result i32)")))
}
