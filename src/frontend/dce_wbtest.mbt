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
fn collect_stmt_names(stmts : Array[@core.Stmt]) -> Map[String, Bool] {
  let names : Map[String, Bool] = {}
  for stmt in stmts {
    match stmt_name(stmt) {
      Some(name) => names[name] = true
      None => ()
    }
  }
  names
}

///|
fn has_enum_stmt(stmts : Array[@core.Stmt], target : String) -> Bool {
  for stmt in stmts {
    match stmt {
      @core.Stmt::EnumDef(name~, ..)
      | @core.Stmt::ExportEnumDef(name~, ..)
      | @core.Stmt::InternalExportEnumDef(name~, ..) =>
        if name == target {
          return true
        }
      _ => ()
    }
  }
  false
}

///|
fn dce_test_ctor(name : String) -> @core.TypeCtor {
  @core.TypeCtor::{ name, args: [], span: dce_test_span() }
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

///|
test "dce keeps iterable helper defs referenced from for-in benches" {
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
      @core.Stmt::Bench(
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
test "dce drops iterable helper defs referenced only from for-in benches by default" {
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
      @core.Stmt::Bench(
        name=Some("for-in"),
        body=@core.Module::{
          stmts: [@core.Stmt::Expr(expr=for_in, span=dce_test_span())],
        },
        span=dce_test_span(),
      ),
    ],
  }
  let filtered = dce_module(mod)
  let names : Map[String, Bool] = {}
  for stmt in filtered.stmts {
    match stmt_name(stmt) {
      Some(name) => names[name] = true
      None => ()
    }
  }
  assert_false(names.contains("list_of3"))
  assert_false(names.contains("iter_require"))
  assert_false(names.contains("iter_length"))
  assert_false(names.contains("iter_get"))
}

///|
test "dce keeps extra entry names for export surface" {
  let mod = @core.Module::{
    stmts: [
      @core.Stmt::Let(
        rec=false,
        name="keep",
        expr=dce_test_int(1L),
        span=dce_test_span(),
      ),
      @core.Stmt::Let(
        rec=false,
        name="drop",
        expr=dce_test_int(2L),
        span=dce_test_span(),
      ),
      @core.Stmt::Export(names=["keep"], span=dce_test_span()),
    ],
  }
  let filtered = dce_module_with_entry_names(mod, ["keep"])
  let names = collect_stmt_names(filtered.stmts)
  assert_true(names.contains("keep"))
  assert_false(names.contains("drop"))
  assert_eq(filtered.stmts.length(), 2)
}

///|
test "dce keeps enum when constructor name is explicit entry" {
  let mod = @core.Module::{
    stmts: [
      @core.Stmt::Let(
        rec=false,
        name="drop",
        expr=dce_test_int(1L),
        span=dce_test_span(),
      ),
      @core.Stmt::EnumDef(
        name="Color",
        params=[],
        ctors=[dce_test_ctor("Red"), dce_test_ctor("Blue")],
        span=dce_test_span(),
      ),
      @core.Stmt::Expr(expr=dce_test_int(0L), span=dce_test_span()),
    ],
  }
  let filtered = dce_module_with_entry_names(mod, ["Red"])
  let names = collect_stmt_names(filtered.stmts)
  assert_true(has_enum_stmt(filtered.stmts, "Color"))
  assert_false(names.contains("drop"))
}

///|
test "dce keeps enum when qualified constructor name is explicit entry" {
  let mod = @core.Module::{
    stmts: [
      @core.Stmt::Let(
        rec=false,
        name="drop",
        expr=dce_test_int(1L),
        span=dce_test_span(),
      ),
      @core.Stmt::EnumDef(
        name="Color",
        params=[],
        ctors=[dce_test_ctor("Red"), dce_test_ctor("Blue")],
        span=dce_test_span(),
      ),
      @core.Stmt::Expr(expr=dce_test_int(0L), span=dce_test_span()),
    ],
  }
  let filtered = dce_module_with_entry_names(mod, ["Color::Blue"])
  let names = collect_stmt_names(filtered.stmts)
  assert_true(has_enum_stmt(filtered.stmts, "Color"))
  assert_false(names.contains("drop"))
}

///|
fn has_type_alias_stmt(stmts : Array[@core.Stmt], target : String) -> Bool {
  for stmt in stmts {
    match stmt {
      @core.Stmt::TypeAlias(name~, ..)
      | @core.Stmt::ExportTypeAlias(name~, ..)
      | @core.Stmt::InternalExportTypeAlias(name~, ..) =>
        if name == target {
          return true
        }
      _ => ()
    }
  }
  false
}

///|
test "dce drops TypeAlias when not referenced" {
  let mod = @core.Module::{
    stmts: [
      @core.Stmt::TypeAlias(
        name="UnusedAlias",
        params=[],
        target=@core.Type::Int,
        span=dce_test_span(),
      ),
      @core.Stmt::Let(
        rec=false,
        name="x",
        expr=dce_test_int(1L),
        span=dce_test_span(),
      ),
    ],
  }
  let filtered = dce_module(mod)
  assert_false(has_type_alias_stmt(filtered.stmts, "UnusedAlias"))
}

///|
test "dce keeps ExportTypeAlias as always-kept entry" {
  // drop_me is not last so it is not promoted to an entry; PublicAlias is
  // always an entry because it's an ExportTypeAlias.
  let mod = @core.Module::{
    stmts: [
      @core.Stmt::Let(
        rec=false,
        name="drop_me",
        expr=dce_test_int(1L),
        span=dce_test_span(),
      ),
      @core.Stmt::ExportTypeAlias(
        name="PublicAlias",
        params=[],
        target=@core.Type::Int,
        span=dce_test_span(),
      ),
    ],
  }
  let filtered = dce_module(mod)
  assert_true(has_type_alias_stmt(filtered.stmts, "PublicAlias"))
  let names = collect_stmt_names(filtered.stmts)
  assert_false(names.contains("drop_me"))
}

///|
test "dce keeps TypeAlias when referenced from reachable StructDef field" {
  let mod = @core.Module::{
    stmts: [
      @core.Stmt::TypeAlias(
        name="UserId",
        params=[],
        target=@core.Type::Int,
        span=dce_test_span(),
      ),
      @core.Stmt::ExportStructDef(
        name="Profile",
        params=[],
        fields=[
          @core.StructField::{
            name: "id",
            ty: @core.Type::Named(name="UserId", args=[]),
            span: dce_test_span(),
          },
        ],
        span=dce_test_span(),
      ),
    ],
  }
  let filtered = dce_module(mod)
  assert_true(has_type_alias_stmt(filtered.stmts, "UserId"))
}
