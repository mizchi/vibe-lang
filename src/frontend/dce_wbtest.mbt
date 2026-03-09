///|
fn dce_test_span() -> @core.Span {
  { start: 0, end: 0 }
}

///|
fn dce_test_arg(expr : @core.Expr) -> @core.CallArg {
  @core.CallArg::{ label: None, expr, span: dce_test_span() }
}

///|
fn dce_test_int(value : Int64) -> @core.Expr {
  @core.Expr::Int(value~, span=dce_test_span())
}

///|
fn dce_test_ident(name : String) -> @core.Expr {
  @core.Expr::Ident(name~, span=dce_test_span())
}

///|
fn dce_test_call(name : String, args : Array[@core.Expr]) -> @core.Expr {
  let call_args : Array[@core.CallArg] = []
  for arg in args {
    call_args.push(dce_test_arg(arg))
  }
  @core.Expr::Call(name~, type_args=[], args=call_args, span=dce_test_span())
}

///|
fn stmt_name(stmt : @core.Stmt) -> String? {
  match stmt {
    @core.Stmt::Let(name~, ..)
    | @core.Stmt::ExportLet(name~, ..)
    | @core.Stmt::LetMut(name~, ..) => Some(name)
    _ => None
  }
}

///|
test "dce keeps iterable helper defs referenced from for-in tests" {
  let body = @core.Module::{
    stmts: [@core.Stmt::Expr(expr=dce_test_ident("x"), span=dce_test_span())],
  }
  let for_in = @core.Expr::ForIn(
    value_name="x",
    index_name=None,
    iterable=dce_test_call("list_of3", [
      dce_test_int(1L),
      dce_test_int(2L),
      dce_test_int(3L),
    ]),
    body~,
    span=dce_test_span(),
  )
  let mod = @core.Module::{
    stmts: [
      @core.Stmt::Let(
        rec=false,
        name="iter_require",
        expr=dce_test_int(1L),
        span=dce_test_span(),
      ),
      @core.Stmt::Let(
        rec=false,
        name="iter_length",
        expr=dce_test_int(1L),
        span=dce_test_span(),
      ),
      @core.Stmt::Let(
        rec=false,
        name="iter_get",
        expr=dce_test_int(1L),
        span=dce_test_span(),
      ),
      @core.Stmt::Let(
        rec=false,
        name="list_of3",
        expr=dce_test_int(1L),
        span=dce_test_span(),
      ),
      @core.Stmt::Test(
        name=Some("for-in"),
        body=@core.Module::{
          stmts: [@core.Stmt::Expr(expr=for_in, span=dce_test_span())],
        },
        span=dce_test_span(),
      ),
    ],
  }
  let filtered = dce_module_for_tests(mod)
  let names : Map[String, Bool] = {}
  for stmt in filtered.stmts {
    match stmt_name(stmt) {
      Some(name) => names[name] = true
      None => ()
    }
  }
  assert_true(names.contains("list_of3"))
  assert_true(names.contains("iter_require"))
  assert_true(names.contains("iter_length"))
  assert_true(names.contains("iter_get"))
}

///|
test "dce gc drops iterable helper defs referenced only from for-in" {
  let body = @core.Module::{
    stmts: [@core.Stmt::Expr(expr=dce_test_ident("x"), span=dce_test_span())],
  }
  let for_in = @core.Expr::ForIn(
    value_name="x",
    index_name=None,
    iterable=dce_test_call("list_of3", [
      dce_test_int(1L),
      dce_test_int(2L),
      dce_test_int(3L),
    ]),
    body~,
    span=dce_test_span(),
  )
  let mod = @core.Module::{
    stmts: [
      @core.Stmt::Let(
        rec=false,
        name="iter_require",
        expr=dce_test_int(1L),
        span=dce_test_span(),
      ),
      @core.Stmt::Let(
        rec=false,
        name="iter_length",
        expr=dce_test_int(1L),
        span=dce_test_span(),
      ),
      @core.Stmt::Let(
        rec=false,
        name="iter_get",
        expr=dce_test_int(1L),
        span=dce_test_span(),
      ),
      @core.Stmt::Let(
        rec=false,
        name="list_of3",
        expr=dce_test_int(1L),
        span=dce_test_span(),
      ),
      @core.Stmt::Expr(expr=for_in, span=dce_test_span()),
    ],
  }
  let filtered = dce_module_gc(mod)
  let names : Map[String, Bool] = {}
  for stmt in filtered.stmts {
    match stmt_name(stmt) {
      Some(name) => names[name] = true
      None => ()
    }
  }
  assert_true(names.contains("list_of3"))
  assert_false(names.contains("iter_require"))
  assert_false(names.contains("iter_length"))
  assert_false(names.contains("iter_get"))
}
