///|
let zero_span_for_export_norm_test : Span = Span::{ start: 0, end: 0 }

///|
fn int_expr_for_export_norm_test(value : Int) -> Expr {
  Expr::Int(value~, span=zero_span_for_export_norm_test)
}

///|
test "normalize_module canonicalizes export list into explicit exports" {
  let mod_ast = Module::{
    stmts: [
      Stmt::Let(
        rec=false,
        name="foo",
        expr=int_expr_for_export_norm_test(1),
        span=zero_span_for_export_norm_test,
      ),
      Stmt::TypeAlias(
        name="Age",
        params=[],
        target=Type::Int,
        span=zero_span_for_export_norm_test,
      ),
      Stmt::TraitDef(
        name="Showable",
        supertraits=[],
        open_impl=false,
        exported=false,
        span=zero_span_for_export_norm_test,
      ),
      Stmt::StructDef(
        name="User",
        params=[],
        fields=[
          StructField::{
            name: "id",
            ty: Type::Int,
            span: zero_span_for_export_norm_test,
          },
        ],
        span=zero_span_for_export_norm_test,
      ),
      Stmt::EnumDef(
        name="State",
        params=[],
        ctors=[
          TypeCtor::{
            name: "Ready",
            args: [],
            span: zero_span_for_export_norm_test,
          },
        ],
        span=zero_span_for_export_norm_test,
      ),
      Stmt::Export(
        names=["foo", "Age", "Showable", "User", "State"],
        span=zero_span_for_export_norm_test,
      ),
    ],
  }
  let normalized = normalize_module(mod_ast)
  assert_eq(normalized.stmts.length(), 5)
  assert_true(
    match normalized.stmts[0] {
      Stmt::ExportLet(name="$0", ..) => true
      _ => false
    },
  )
  assert_true(
    match normalized.stmts[1] {
      Stmt::ExportTypeAlias(name="Age", ..) => true
      _ => false
    },
  )
  assert_true(
    match normalized.stmts[2] {
      Stmt::TraitDef(name="Showable", exported=true, ..) => true
      _ => false
    },
  )
  assert_true(
    match normalized.stmts[3] {
      Stmt::ExportStructDef(name="User", ..) => true
      _ => false
    },
  )
  assert_true(
    match normalized.stmts[4] {
      Stmt::ExportEnumDef(name="State", ..) => true
      _ => false
    },
  )
}

///|
test "normalize_module keeps unresolved names in export list" {
  let mod_ast = Module::{
    stmts: [
      Stmt::Let(
        rec=false,
        name="foo",
        expr=int_expr_for_export_norm_test(1),
        span=zero_span_for_export_norm_test,
      ),
      Stmt::Export(
        names=["foo", "missing"],
        span=zero_span_for_export_norm_test,
      ),
    ],
  }
  let normalized = normalize_module(mod_ast)
  assert_eq(normalized.stmts.length(), 2)
  assert_true(
    match normalized.stmts[0] {
      Stmt::ExportLet(name="$0", ..) => true
      _ => false
    },
  )
  assert_true(
    match normalized.stmts[1] {
      Stmt::Export(names=["missing"], ..) => true
      _ => false
    },
  )
}

///|
test "normalize_module canonicalizes forward export list" {
  let mod_ast = Module::{
    stmts: [
      Stmt::Export(names=["foo"], span=zero_span_for_export_norm_test),
      Stmt::Let(
        rec=false,
        name="foo",
        expr=int_expr_for_export_norm_test(1),
        span=zero_span_for_export_norm_test,
      ),
    ],
  }
  let normalized = normalize_module(mod_ast)
  assert_eq(normalized.stmts.length(), 1)
  assert_true(
    match normalized.stmts[0] {
      Stmt::ExportLet(name="$0", ..) => true
      _ => false
    },
  )
}

///|
test "hash_module treats export list and export let equally" {
  let list_export_ast = Module::{
    stmts: [
      Stmt::Let(
        rec=false,
        name="foo",
        expr=int_expr_for_export_norm_test(1),
        span=zero_span_for_export_norm_test,
      ),
      Stmt::Export(names=["foo"], span=zero_span_for_export_norm_test),
    ],
  }
  let explicit_export_ast = Module::{
    stmts: [
      Stmt::ExportLet(
        rec=false,
        name="foo",
        expr=int_expr_for_export_norm_test(1),
        span=zero_span_for_export_norm_test,
      ),
    ],
  }
  assert_eq(hash_module(list_export_ast), hash_module(explicit_export_ast))
}
