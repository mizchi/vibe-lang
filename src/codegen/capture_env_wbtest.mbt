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
fn wb_let_rec(name : String, expr : @core.Expr) -> @core.Stmt {
  @core.Stmt::Let(rec=true, name~, expr~, span=wb_span())
}

///|
fn wb_export_let(name : String, expr : @core.Expr) -> @core.Stmt {
  @core.Stmt::ExportLet(rec=false, name~, expr~, span=wb_span())
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
test "exported env-backed top-level function can be captured" {
  let helper_fn = wb_fn([wb_param("n")], [
    wb_expr(wb_call("__add", [wb_ident("n"), wb_ident("seed")])),
  ])
  let call_helper_fn = wb_fn([], [wb_expr(wb_call("helper", [wb_int(1)]))])
  let run_fn = wb_fn([], [
    wb_let("call_helper", call_helper_fn),
    wb_expr(wb_call("call_helper", [])),
  ])
  let ast = @core.Module::{
    stmts: [
      wb_let("seed", wb_int(41)),
      wb_export_let("helper", helper_fn),
      wb_let("run", run_fn),
    ],
  }
  let bytes = emit_module_wasm(ast)
  assert_true(bytes.length() >= 8)
}

///|
test "non-exported env-backed top-level function can be captured" {
  let helper_fn = wb_fn([wb_param("n")], [
    wb_expr(wb_call("__add", [wb_ident("n"), wb_ident("seed")])),
  ])
  let call_helper_fn = wb_fn([], [wb_expr(wb_call("helper", [wb_int(1)]))])
  let run_fn = wb_fn([], [
    wb_let("call_helper", call_helper_fn),
    wb_expr(wb_call("call_helper", [])),
  ])
  let ast = @core.Module::{
    stmts: [
      wb_let("seed", wb_int(41)),
      wb_let("helper", helper_fn),
      wb_let("run", run_fn),
    ],
  }
  let bytes = emit_module_wasm(ast)
  assert_true(bytes.length() >= 8)
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
  assert_true(!wat.contains("(param i64 i32) (result i32)"))
}

///|
test "compile_function_with_scoped_names restores named function metadata after body compile" {
  let ctx = CodegenCtx::new(false)
  ctx.fn_indices["go"] = 7
  ctx.fn_params["go"] = [ValueKind::I64]
  ctx.fn_param_names["go"] = ["x"]
  ctx.fn_returns["go"] = ValueKind::I64
  ctx.forward_fn_keys["go"] = "outer-go-key"

  let local_go_params = [wb_param("acc"), wb_param("rest")]
  let local_go_key = span_key_named(Some("go"), wb_span(), local_go_params)
  ctx.fn_closure_indices[local_go_key] = 42
  ctx.fn_closure_captures[local_go_key] = []
  ctx.fn_needs_env[42] = false

  let outer_params = [wb_param("n")]
  let outer_func = FuncDef::{
    name: Some("outer"),
    params: outer_params,
    ret: Some(@core.Type::Int),
    body: @core.Module::{
      stmts: [
        wb_let_rec("go", wb_fn(local_go_params, [wb_expr(wb_int(0))])),
        wb_expr(wb_call("go", [wb_int(0), wb_int(0)])),
      ],
    },
    span_key: span_key_named(Some("outer"), wb_span(), outer_params),
    captures: [],
  }
  let _ = try
    compile_function_with_scoped_names(
      ctx,
      outer_func,
      1,
      [ValueKind::I64],
      ValueKind::I64,
      false,
      [],
      [],
      false,
    )
  catch {
    e => fail("compile error: " + e.to_string())
  } noraise {
    func => func
  }

  let go_idx = match ctx.fn_indices.get("go") {
    Some(idx) => idx
    None => -1
  }
  assert_eq(go_idx, 7)
  let go_param_count = match ctx.fn_params.get("go") {
    Some(kinds) => kinds.length()
    None => 0
  }
  assert_eq(go_param_count, 1)
  let go_param_name = match ctx.fn_param_names.get("go") {
    Some(names) => if names.length() > 0 { names[0] } else { "" }
    None => ""
  }
  assert_eq(go_param_name, "x")
  let go_return = match ctx.fn_returns.get("go") {
    Some(kind) => kind
    None => ValueKind::I32
  }
  assert_eq(go_return, ValueKind::I64)
  let go_forward_key = match ctx.forward_fn_keys.get("go") {
    Some(key) => key
    None => ""
  }
  assert_eq(go_forward_key, "outer-go-key")
  assert_false(ctx.fn_indices.contains("outer"))
  assert_false(ctx.fn_params.contains("outer"))
  assert_false(ctx.fn_param_names.contains("outer"))
  assert_false(ctx.fn_returns.contains("outer"))
}
