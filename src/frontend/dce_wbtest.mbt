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

///|
fn has_extern_let_stmt(stmts : Array[@core.Stmt], target : String) -> Bool {
  for stmt in stmts {
    match stmt {
      @core.Stmt::ExternLet(name~, ..) => if name == target { return true }
      _ => ()
    }
  }
  false
}

///|
test "dce keeps LetMut as last-statement entry" {
  let mod = @core.Module::{
    stmts: [
      @core.Stmt::Let(
        rec=false,
        name="unused",
        expr=dce_test_int(1L),
        span=dce_test_span(),
      ),
      @core.Stmt::LetMut(
        name="counter",
        expr=dce_test_int(0L),
        span=dce_test_span(),
      ),
    ],
  }
  let filtered = dce_module(mod)
  let names = collect_stmt_names(filtered.stmts)
  assert_true(names.contains("counter"))
  assert_false(names.contains("unused"))
}

///|
test "dce keeps TypeAlias referenced via reachable ExternLet" {
  // export let reader = fd  -> fd (ExternLet) -> Handle (TypeAlias)
  let mod = @core.Module::{
    stmts: [
      @core.Stmt::TypeAlias(
        name="Handle",
        params=[],
        target=@core.Type::Int,
        span=dce_test_span(),
      ),
      @core.Stmt::ExternLet(
        name="fd",
        ty=@core.Type::Named(name="Handle", args=[]),
        span=dce_test_span(),
      ),
      @core.Stmt::ExportLet(
        rec=false,
        name="reader",
        expr=dce_test_ident("fd"),
        span=dce_test_span(),
      ),
    ],
  }
  let filtered = dce_module(mod)
  assert_true(has_type_alias_stmt(filtered.stmts, "Handle"))
  assert_true(has_extern_let_stmt(filtered.stmts, "fd"))
  let names = collect_stmt_names(filtered.stmts)
  assert_true(names.contains("reader"))
}

///|
test "dce drops ExternLet + its TypeAlias when nothing references them" {
  let mod = @core.Module::{
    stmts: [
      @core.Stmt::TypeAlias(
        name="Handle",
        params=[],
        target=@core.Type::Int,
        span=dce_test_span(),
      ),
      @core.Stmt::ExternLet(
        name="fd",
        ty=@core.Type::Named(name="Handle", args=[]),
        span=dce_test_span(),
      ),
      @core.Stmt::ExportLet(
        rec=false,
        name="reader",
        expr=dce_test_int(0L),
        span=dce_test_span(),
      ),
    ],
  }
  let filtered = dce_module(mod)
  assert_false(has_type_alias_stmt(filtered.stmts, "Handle"))
  assert_false(has_extern_let_stmt(filtered.stmts, "fd"))
}

///|
test "dce keeps InternalExportLet when reachable from a regular export" {
  // InternalExportLet is filtered by `filter_reachable_stmts` only when it
  // appears in the reachable set. Verify the path: reachable export calls
  // the internal-export, so the internal-export must survive DCE.
  let mod = @core.Module::{
    stmts: [
      @core.Stmt::InternalExportLet(
        rec=false,
        name="helper_internal",
        expr=dce_test_int(1L),
        span=dce_test_span(),
      ),
      @core.Stmt::InternalExportLet(
        rec=false,
        name="helper_unreachable",
        expr=dce_test_int(99L),
        span=dce_test_span(),
      ),
      @core.Stmt::ExportLet(
        rec=false,
        name="api",
        expr=dce_test_call("helper_internal", []),
        span=dce_test_span(),
      ),
    ],
  }
  let filtered = dce_module(mod)
  let names = collect_stmt_names(filtered.stmts)
  assert_true(names.contains("api"))
  // Reachable internal export survives.
  let mut kept_internal = false
  let mut kept_unreachable = false
  for stmt in filtered.stmts {
    match stmt {
      @core.Stmt::InternalExportLet(name="helper_internal", ..) =>
        kept_internal = true
      @core.Stmt::InternalExportLet(name="helper_unreachable", ..) =>
        kept_unreachable = true
      _ => ()
    }
  }
  assert_true(kept_internal)
  assert_false(kept_unreachable)
}

///|
test "dce keeps InternalExportEnumDef when its constructor is referenced" {
  // filter_reachable_stmts has a dedicated branch for InternalExportEnumDef
  // that preserves the enum if any constructor (qualified or unqualified)
  // is in the reachable set. Exercise it.
  let ctor_a = dce_test_ctor("Active")
  let ctor_b = dce_test_ctor("Idle")
  let mod = @core.Module::{
    stmts: [
      @core.Stmt::InternalExportEnumDef(
        name="State",
        params=[],
        ctors=[ctor_a, ctor_b],
        span=dce_test_span(),
      ),
      @core.Stmt::ExportLet(
        rec=false,
        name="start",
        expr=dce_test_call("Active", []),
        span=dce_test_span(),
      ),
    ],
  }
  let filtered = dce_module(mod)
  // The enum stays because Active is reachable.
  assert_true(has_enum_stmt(filtered.stmts, "State"))
}

///|
test "dce drops InternalExportEnumDef when no constructor is reached" {
  let ctor = dce_test_ctor("Unused")
  let mod = @core.Module::{
    stmts: [
      @core.Stmt::InternalExportEnumDef(
        name="Dead",
        params=[],
        ctors=[ctor],
        span=dce_test_span(),
      ),
      @core.Stmt::ExportLet(
        rec=false,
        name="api",
        expr=dce_test_int(0L),
        span=dce_test_span(),
      ),
    ],
  }
  let filtered = dce_module(mod)
  assert_false(has_enum_stmt(filtered.stmts, "Dead"))
}

///|
test "dce_module_with_entry_names handles missing entries gracefully" {
  // Unknown entry names must not affect the kept-set; reachable analysis
  // proceeds as if the unknown names contribute nothing.
  let mod = @core.Module::{
    stmts: [
      @core.Stmt::ExportLet(
        rec=false,
        name="real_export",
        expr=dce_test_int(1L),
        span=dce_test_span(),
      ),
    ],
  }
  let filtered = dce_module_with_entry_names(mod, [
    "does_not_exist", "another_phantom",
  ])
  let names = collect_stmt_names(filtered.stmts)
  assert_true(names.contains("real_export"))
  // Phantom entries don't show up because they were never defined.
  assert_false(names.contains("does_not_exist"))
}

///|
test "dce_module_with_entry_names accepts an empty entry list" {
  // Smoke: empty extra_entries should not panic; ExportLet roots still
  // anchor the reachable set so the export survives.
  let mod = @core.Module::{
    stmts: [
      @core.Stmt::ExportLet(
        rec=false,
        name="kept",
        expr=dce_test_int(1L),
        span=dce_test_span(),
      ),
    ],
  }
  let filtered = dce_module_with_entry_names(mod, [])
  let names = collect_stmt_names(filtered.stmts)
  assert_true(names.contains("kept"))
}
