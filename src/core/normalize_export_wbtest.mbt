///|
let zero_span_for_export_norm_test : Span = Span::{ start: 0, end: 0 }

///|
fn int_expr_for_export_norm_test(value : Int64) -> Expr {
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
        methods=[],
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
            is_mut: false,
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

///|
test "normalize_module canonicalizes EffectDef export list into ExportEffectDef" {
  let mod_ast = Module::{
    stmts: [
      Stmt::EffectDef(
        name="Net",
        params=[],
        ops=[
          EffectOp::{
            name: "Get",
            params: [Type::String],
            ret: Type::String,
            span: zero_span_for_export_norm_test,
          },
        ],
        import_path=None,
        span=zero_span_for_export_norm_test,
      ),
      Stmt::Export(names=["Net"], span=zero_span_for_export_norm_test),
    ],
  }
  let normalized = normalize_module(mod_ast)
  assert_eq(normalized.stmts.length(), 1)
  assert_true(
    match normalized.stmts[0] {
      Stmt::ExportEffectDef(name="Net", ..) => true
      _ => false
    },
  )
}

///|
test "normalize_expr unwraps single-Stmt::Expr Block to the inner expression" {
  // `let x = { 42 }` should collapse the one-expr Block to `let x = 42`.
  let inner = Expr::Block(
    body=Module::{
      stmts: [
        Stmt::Expr(
          expr=int_expr_for_export_norm_test(42),
          span=zero_span_for_export_norm_test,
        ),
      ],
    },
    span=zero_span_for_export_norm_test,
  )
  let mod_ast = Module::{
    stmts: [
      Stmt::Let(
        rec=false,
        name="x",
        expr=inner,
        span=zero_span_for_export_norm_test,
      ),
    ],
  }
  let normalized = normalize_module(mod_ast)
  assert_eq(normalized.stmts.length(), 1)
  assert_true(
    match normalized.stmts[0] {
      Stmt::Let(expr=Expr::Int(value=42L, ..), ..) => true
      _ => false
    },
  )
}

///|
test "normalize_expr keeps Block wrapper when it contains multiple stmts" {
  // `let x = { let y = 1; y }` should remain a Block (two stmts).
  let inner = Expr::Block(
    body=Module::{
      stmts: [
        Stmt::Let(
          rec=false,
          name="y",
          expr=int_expr_for_export_norm_test(1),
          span=zero_span_for_export_norm_test,
        ),
        Stmt::Expr(
          expr=Expr::Ident(name="y", span=zero_span_for_export_norm_test),
          span=zero_span_for_export_norm_test,
        ),
      ],
    },
    span=zero_span_for_export_norm_test,
  )
  let mod_ast = Module::{
    stmts: [
      Stmt::Let(
        rec=false,
        name="x",
        expr=inner,
        span=zero_span_for_export_norm_test,
      ),
    ],
  }
  let normalized = normalize_module(mod_ast)
  assert_eq(normalized.stmts.length(), 1)
  assert_true(
    match normalized.stmts[0] {
      Stmt::Let(expr=Expr::Block(..), ..) => true
      _ => false
    },
  )
}

///|
test "normalize_with_imports returns only the main module when resolver always fails" {
  let main_mod = Module::{
    stmts: [
      Stmt::Import(
        spec=ImportSpec::{
          items: [
            ImportItem::{
              kind: ImportKind::Value,
              name: "missing",
              rename: None,
            },
          ],
        },
        source=ModuleRef::Path(path="./not_found.vibe"),
        span=zero_span_for_export_norm_test,
      ),
      Stmt::Let(
        rec=false,
        name="v",
        expr=int_expr_for_export_norm_test(1),
        span=zero_span_for_export_norm_test,
      ),
    ],
  }
  let bundle = normalize_with_imports(main_mod, fn(_path) { None })
  assert_eq(bundle.modules.length(), 1)
  assert_true(bundle.modules.contains(bundle.main_hash))
}

///|
test "normalize_module renames LetMut binding" {
  // `let mut x = 1; x` → `let mut $0 = 1; $0`
  let mod_ast = Module::{
    stmts: [
      Stmt::LetMut(
        name="x",
        expr=int_expr_for_export_norm_test(1),
        span=zero_span_for_export_norm_test,
      ),
      Stmt::Expr(
        expr=Expr::Ident(name="x", span=zero_span_for_export_norm_test),
        span=zero_span_for_export_norm_test,
      ),
    ],
  }
  let normalized = normalize_module(mod_ast)
  assert_eq(normalized.stmts.length(), 2)
  assert_true(
    match normalized.stmts[0] {
      Stmt::LetMut(name="$0", ..) => true
      _ => false
    },
  )
  assert_true(
    match normalized.stmts[1] {
      Stmt::Expr(expr=Expr::Ident(name="$0", ..), ..) => true
      _ => false
    },
  )
}

///|
test "normalize_module renames LetPat tuple bindings" {
  // `let (a, b) = (1, 2); a` → `let ($0, $1) = (1, 2); $0`
  let pat_a = Pat::Bind(name="a", span=zero_span_for_export_norm_test)
  let pat_b = Pat::Bind(name="b", span=zero_span_for_export_norm_test)
  let pat = Pat::Tuple(
    items=[pat_a, pat_b],
    span=zero_span_for_export_norm_test,
  )
  let tup = Expr::Tuple(
    items=[int_expr_for_export_norm_test(1), int_expr_for_export_norm_test(2)],
    span=zero_span_for_export_norm_test,
  )
  let mod_ast = Module::{
    stmts: [
      Stmt::LetPat(pat~, expr=tup, span=zero_span_for_export_norm_test),
      Stmt::Expr(
        expr=Expr::Ident(name="a", span=zero_span_for_export_norm_test),
        span=zero_span_for_export_norm_test,
      ),
    ],
  }
  let normalized = normalize_module(mod_ast)
  assert_eq(normalized.stmts.length(), 2)
  assert_true(
    match normalized.stmts[0] {
      Stmt::LetPat(
        pat=Pat::Tuple(
          items=[Pat::Bind(name="$0", ..), Pat::Bind(name="$1", ..)],
          ..
        ),
        ..
      ) => true
      _ => false
    },
  )
  assert_true(
    match normalized.stmts[1] {
      Stmt::Expr(expr=Expr::Ident(name="$0", ..), ..) => true
      _ => false
    },
  )
}

///|
test "normalize_module LetPatElse else_body uses child scope so pat names don't leak" {
  // `let Some(x) = e else { 0 }; x` — `x` from pat should NOT bind in
  // outer scope, so the trailing `x` reference stays as the global ident
  // rather than being renamed.
  // Actually verify: pat in the let-pat-else IS visible after the let
  // (the else-branch is the not-matched fallback). What matters is the
  // ELSE body running in a child scope (its own bindings don't leak).
  let pat = Pat::Ctor(
    name="Some",
    args=[Pat::Bind(name="x", span=zero_span_for_export_norm_test)],
    span=zero_span_for_export_norm_test,
  )
  let else_body = Module::{
    stmts: [
      Stmt::Let(
        rec=false,
        name="fallback",
        expr=int_expr_for_export_norm_test(0),
        span=zero_span_for_export_norm_test,
      ),
      Stmt::Expr(
        expr=Expr::Ident(name="fallback", span=zero_span_for_export_norm_test),
        span=zero_span_for_export_norm_test,
      ),
    ],
  }
  let mod_ast = Module::{
    stmts: [
      Stmt::LetPatElse(
        pat~,
        expr=Expr::Ident(name="e", span=zero_span_for_export_norm_test),
        else_body~,
        span=zero_span_for_export_norm_test,
      ),
    ],
  }
  let normalized = normalize_module(mod_ast)
  // Verify the else-body's `fallback` got a fresh $0 in its child scope.
  assert_true(
    match normalized.stmts[0] {
      Stmt::LetPatElse(
        pat=Pat::Ctor(name="Some", args=[Pat::Bind(name="$0", ..)], ..),
        else_body~,
        ..
      ) =>
        match else_body.stmts[0] {
          // Block-child scope inherits counter from outer. The pat's $0
          // is in the outer scope; else-body is its own child block, so
          // `fallback` gets the next number ($1).
          Stmt::Let(name="$1", ..) => true
          _ => false
        }
      _ => false
    },
  )
}

///|
test "normalize_module Match scrutinee + arm patterns are renamed" {
  // `let v = 1; match v { x => x }` →
  // `let $0 = 1; match $0 { $1 => $1 }`
  let arm = MatchArm::{
    pat: Pat::Bind(name="x", span=zero_span_for_export_norm_test),
    cond: None,
    expr: Expr::Ident(name="x", span=zero_span_for_export_norm_test),
    span: zero_span_for_export_norm_test,
  }
  let match_expr = Expr::Match(
    scrutinee=Expr::Ident(name="v", span=zero_span_for_export_norm_test),
    arms=[arm],
    span=zero_span_for_export_norm_test,
  )
  let mod_ast = Module::{
    stmts: [
      Stmt::Let(
        rec=false,
        name="v",
        expr=int_expr_for_export_norm_test(1),
        span=zero_span_for_export_norm_test,
      ),
      Stmt::Expr(expr=match_expr, span=zero_span_for_export_norm_test),
    ],
  }
  let normalized = normalize_module(mod_ast)
  let ok = match normalized.stmts[1] {
    Stmt::Expr(
      expr=Expr::Match(scrutinee=Expr::Ident(name="$0", ..), arms~, ..),
      ..
    ) =>
      if arms.length() == 1 {
        let arm = arms[0]
        let pat_ok = match arm.pat {
          Pat::Bind(name="$1", ..) => true
          _ => false
        }
        let expr_ok = match arm.expr {
          Expr::Ident(name="$1", ..) => true
          _ => false
        }
        pat_ok && expr_ok
      } else {
        false
      }
    _ => false
  }
  assert_true(ok)
}

///|
test "normalize_module While renames cond and body identifiers" {
  // `let mut i = 0; while i > 0 { i = i - 1 }` →
  // `let mut $0 = 0; while $0 > 0 { $0 = $0 - 1 }`
  let cond = Expr::Call(
    name=">",
    type_args=[],
    args=[
      CallArg::{
        label: None,
        expr: Expr::Ident(name="i", span=zero_span_for_export_norm_test),
        span: zero_span_for_export_norm_test,
      },
      CallArg::{
        label: None,
        expr: int_expr_for_export_norm_test(0),
        span: zero_span_for_export_norm_test,
      },
    ],
    span=zero_span_for_export_norm_test,
  )
  let body = Module::{
    stmts: [
      Stmt::Assign(
        name="i",
        expr=int_expr_for_export_norm_test(99),
        span=zero_span_for_export_norm_test,
      ),
    ],
  }
  let mod_ast = Module::{
    stmts: [
      Stmt::LetMut(
        name="i",
        expr=int_expr_for_export_norm_test(0),
        span=zero_span_for_export_norm_test,
      ),
      Stmt::Expr(
        expr=Expr::While(cond~, body~, span=zero_span_for_export_norm_test),
        span=zero_span_for_export_norm_test,
      ),
    ],
  }
  let normalized = normalize_module(mod_ast)
  assert_true(
    match normalized.stmts[1] {
      Stmt::Expr(
        expr=Expr::While(cond=Expr::Call(name=">", args~, ..), body~, ..),
        ..
      ) =>
        args.length() == 2 &&
        (match args[0].expr {
          Expr::Ident(name="$0", ..) => true
          _ => false
        }) &&
        (match body.stmts[0] {
          Stmt::Assign(name="$0", ..) => true
          _ => false
        })
      _ => false
    },
  )
}
