// Roundtrip tests for the binary AST ABI v1. The "smoke module"
// exercises every tagged variant at least once — both this MoonBit
// implementation and the selfhost one
// (vibe/compiler/ast_binary_test.vibe) must produce byte-identical
// output when serializing it.

///|
fn span0() -> Span {
  Span::{ start: 0, end: 0 }
}

///|
/// Construct a small Module that touches every Expr / Stmt / Type /
/// Pat tag. Keep this in sync with the selfhost smoke fixture.
fn smoke_module() -> Module {
  let s = span0()
  let int_expr : Expr = Expr::Int(value=42L, span=s)
  let unit_ty : Type = Type::Unit
  let mod_body : Module = Module::{ stmts: [Stmt::Expr(expr=int_expr, span=s)] }
  Module::{
    stmts: [
      Stmt::Let(rec=false, name="x", expr=int_expr, span=s),
      Stmt::Let(rec=true, name="y", expr=Expr::Float(value=1.5, span=s), span=s),
      Stmt::Let(
        rec=false,
        name="d",
        expr=Expr::Double(value=3.14, span=s),
        span=s,
      ),
      Stmt::Let(
        rec=false,
        name="b",
        expr=Expr::Bool(value=true, span=s),
        span=s,
      ),
      Stmt::Let(
        rec=false,
        name="c",
        expr=Expr::Char(value='a', span=s),
        span=s,
      ),
      Stmt::Let(
        rec=false,
        name="strv",
        expr=Expr::String(value="hi", span=s),
        span=s,
      ),
      Stmt::Let(
        rec=false,
        name="interp",
        expr=Expr::StringInterp(
          parts=[
            StringInterpPart::Lit("a="),
            StringInterpPart::Expr(Expr::Ident(name="x", span=s)),
          ],
          span=s,
        ),
        span=s,
      ),
      Stmt::Let(
        rec=false,
        name="ph",
        expr=Expr::Placeholder(index=0, span=s),
        span=s,
      ),
      Stmt::Let(
        rec=false,
        name="call",
        expr=Expr::Call(
          name="f",
          type_args=[Type::Int],
          args=[CallArg::{ label: None, expr: int_expr, span: s }],
          span=s,
        ),
        span=s,
      ),
      Stmt::Let(
        rec=false,
        name="tup",
        expr=Expr::Tuple(items=[int_expr], span=s),
        span=s,
      ),
      Stmt::Let(
        rec=false,
        name="tix",
        expr=Expr::TupleIndex(expr=int_expr, index=0, span=s),
        span=s,
      ),
      Stmt::Let(
        rec=false,
        name="rec",
        expr=Expr::Record(
          fields=[RecordFieldExpr::{ name: "k", expr: int_expr, span: s }],
          span=s,
        ),
        span=s,
      ),
      Stmt::Let(
        rec=false,
        name="arr",
        expr=Expr::Array(items=[int_expr], span=s),
        span=s,
      ),
      Stmt::Let(
        rec=false,
        name="m",
        expr=Expr::Map(
          fields=[MapFieldExpr::{ key: "k", expr: int_expr, span: s }],
          span=s,
        ),
        span=s,
      ),
      Stmt::Let(
        rec=false,
        name="iff",
        expr=Expr::If(
          cond=Expr::Bool(value=true, span=s),
          then_body=mod_body,
          else_body=mod_body,
          span=s,
        ),
        span=s,
      ),
      Stmt::Let(
        rec=false,
        name="blk",
        expr=Expr::Block(body=mod_body, span=s),
        span=s,
      ),
      Stmt::Let(
        rec=false,
        name="mch",
        expr=Expr::Match(
          scrutinee=int_expr,
          arms=[
            MatchArm::{
              pat: Pat::Wildcard(span=s),
              cond: None,
              expr: int_expr,
              span: s,
            },
          ],
          span=s,
        ),
        span=s,
      ),
      Stmt::Let(
        rec=false,
        name="fin",
        expr=Expr::ForIn(
          value_name="v",
          index_name=Some("i"),
          iterable=Expr::Array(items=[int_expr], span=s),
          body=mod_body,
          span=s,
        ),
        span=s,
      ),
      Stmt::Let(
        rec=false,
        name="fn1",
        expr=Expr::Fn(
          type_params=["T"],
          type_bounds={ "T": ["Show"] },
          params=[
            FuncParam::{
              name: "x",
              label: ParamLabel::Positional,
              ty: Type::Param("T"),
              bounds: [],
            },
          ],
          ret=Some(Type::Param("T")),
          effects=[EffectAtom::Const("IO")],
          body=mod_body,
          span=s,
        ),
        span=s,
      ),
      Stmt::Let(
        rec=false,
        name="wh",
        expr=Expr::While(
          cond=Expr::Bool(value=true, span=s),
          body=mod_body,
          span=s,
        ),
        span=s,
      ),
      Stmt::Let(
        rec=false,
        name="lp",
        expr=Expr::Loop(
          params=[LoopParam::{ name: "i", init: int_expr, span: s }],
          body=mod_body,
          span=s,
        ),
        span=s,
      ),
      Stmt::Let(
        rec=false,
        name="br",
        expr=Expr::Break(value=Some(int_expr), span=s),
        span=s,
      ),
      Stmt::Let(
        rec=false,
        name="ct",
        expr=Expr::Continue(args=[int_expr], span=s),
        span=s,
      ),
      Stmt::Let(
        rec=false,
        name="rt",
        expr=Expr::Return(value=None, span=s),
        span=s,
      ),
      Stmt::Let(
        rec=false,
        name="yi",
        expr=Expr::Yield(expr=int_expr, span=s),
        span=s,
      ),
      Stmt::Let(
        rec=false,
        name="hn",
        expr=Expr::Handle(
          body=mod_body,
          arms=[
            MatchArm::{
              pat: Pat::Wildcard(span=s),
              cond: Some(Expr::Bool(value=true, span=s)),
              expr: int_expr,
              span: s,
            },
          ],
          span=s,
        ),
        span=s,
      ),
      Stmt::Let(
        rec=false,
        name="sl",
        expr=Expr::StructLit(
          name="Foo",
          type_args=[],
          fields=[RecordFieldExpr::{ name: "f", expr: int_expr, span: s }],
          span=s,
        ),
        span=s,
      ),
      Stmt::Let(
        rec=false,
        name="sp",
        expr=Expr::Spread(expr=int_expr, span=s),
        span=s,
      ),
      Stmt::Let(
        rec=false,
        name="pf",
        expr=Expr::Perform(
          effect_name="E",
          op_name="Op",
          args=[],
          span=s,
        ),
        span=s,
      ),
      Stmt::EnumDef(
        name="E",
        params=["T"],
        ctors=[TypeCtor::{ name: "A", args: [Type::Int], span: s }],
        span=s,
      ),
      Stmt::TypeAlias(name="Alias", params=[], target=Type::Int, span=s),
      Stmt::TraitDef(
        name="Tr",
        supertraits=["Show"],
        methods=[
          TraitMethodSig::{ name: "m", params: [], ret: Type::Unit, span: s },
        ],
        open_impl=false,
        exported=true,
        span=s,
      ),
      Stmt::TraitImpl(
        type_params=[],
        type_bounds={},
        trait_name="Tr",
        target=Type::Int,
        methods=[
          ImplMethodDef::{ name: "m", expr: int_expr, span: s },
        ],
        span=s,
      ),
      Stmt::Expr(expr=int_expr, span=s),
      Stmt::Import(
        spec=ImportSpec::{
          items: [
            ImportItem::{
              kind: ImportKind::Value,
              name: "foo",
              rename: Some("bar"),
            },
            ImportItem::{ kind: ImportKind::Type, name: "T", rename: None },
            ImportItem::{ kind: ImportKind::Struct, name: "S", rename: None },
            ImportItem::{ kind: ImportKind::Trait, name: "Tr", rename: None },
            ImportItem::{ kind: ImportKind::Effect, name: "E", rename: None },
            ImportItem::{ kind: ImportKind::Suberror, name: "Er", rename: None },
            ImportItem::{ kind: ImportKind::Module, name: "M", rename: None },
          ],
        },
        source=ModuleRef::Path(path="./x.vibe"),
        span=s,
      ),
      Stmt::Test(name=Some("t1"), body=mod_body, span=s),
      Stmt::Bench(name=None, body=mod_body, span=s),
      Stmt::LetMut(name="mu", expr=int_expr, span=s),
      Stmt::ExternLet(name="ex", ty=Type::Int, span=s),
      Stmt::Assign(name="x", expr=int_expr, span=s),
      Stmt::IndexAssign(
        target=Expr::Ident(name="a", span=s),
        index=int_expr,
        value=int_expr,
        span=s,
      ),
      Stmt::LetPat(pat=Pat::Wildcard(span=s), expr=int_expr, span=s),
      Stmt::LetPatElse(
        pat=Pat::Bind(name="x", span=s),
        expr=int_expr,
        else_body=mod_body,
        span=s,
      ),
      Stmt::ExportLet(rec=false, name="e1", expr=int_expr, span=s),
      Stmt::InternalExportLet(rec=false, name="e2", expr=int_expr, span=s),
      Stmt::ExportEnumDef(name="E2", params=[], ctors=[], span=s),
      Stmt::InternalExportEnumDef(name="E3", params=[], ctors=[], span=s),
      Stmt::ExportTypeAlias(name="A2", params=[], target=unit_ty, span=s),
      Stmt::InternalExportTypeAlias(name="A3", params=[], target=unit_ty, span=s),
      Stmt::InternalTraitDef(
        name="T2",
        supertraits=[],
        methods=[],
        open_impl=true,
        span=s,
      ),
      Stmt::Export(names=["x", "y"], span=s),
      Stmt::ReExport(
        spec=ImportSpec::{ items: [] },
        source=ModuleRef::Hash(hash="abc"),
        span=s,
      ),
      Stmt::AliasDecl(
        alias_name="ali",
        source=ModuleRef::Version(name="v"),
        span=s,
      ),
      Stmt::StructDef(
        name="S",
        params=[],
        fields=[
          StructField::{
            name: "f",
            ty: Type::Int,
            is_mut: false,
            span: s,
          },
        ],
        span=s,
      ),
      Stmt::ExportStructDef(name="S2", params=[], fields=[], span=s),
      Stmt::InternalExportStructDef(name="S3", params=[], fields=[], span=s),
      Stmt::EffectDef(
        name="Eff",
        params=[],
        ops=[
          EffectOp::{
            name: "op",
            params: [Type::Int],
            ret: Type::Unit,
            span: s,
          },
        ],
        import_path=Some("./eff.vibe"),
        span=s,
      ),
      Stmt::ExportEffectDef(name="Eff2", params=[], ops=[], import_path=None, span=s),
      // Touch remaining type variants
      Stmt::ExternLet(name="t_tuple", ty=Type::Tuple([Type::Int, Type::Bool]), span=s),
      Stmt::ExternLet(name="t_rec", ty=Type::Record({ "k": Type::Int }), span=s),
      Stmt::ExternLet(name="t_arr", ty=Type::Array(Type::Int), span=s),
      Stmt::ExternLet(name="t_map", ty=Type::Map(Type::String, Type::Int), span=s),
      Stmt::ExternLet(name="t_set", ty=Type::Set(Type::Int), span=s),
      Stmt::ExternLet(name="t_ab", ty=Type::ArrayBuilder(Type::Int), span=s),
      Stmt::ExternLet(name="t_mb", ty=Type::MapBuilder(Type::String, Type::Int), span=s),
      Stmt::ExternLet(name="t_sb", ty=Type::StringBuilder, span=s),
      Stmt::ExternLet(name="t_by", ty=Type::Bytes, span=s),
      Stmt::ExternLet(name="t_v128", ty=Type::V128, span=s),
      Stmt::ExternLet(name="t_var", ty=Type::Variant({ "X": Type::Unit }), span=s),
      Stmt::ExternLet(
        name="t_named",
        ty=Type::Named(name="Box", args=[Type::Int]),
        span=s,
      ),
      Stmt::ExternLet(name="t_param", ty=Type::Param("T"), span=s),
      Stmt::ExternLet(name="t_tvar", ty=Type::Var(7), span=s),
      Stmt::ExternLet(
        name="t_fn",
        ty=Type::Func(
          params=[
            FuncParam::{
              name: "x",
              label: ParamLabel::Required,
              ty: Type::Int,
              bounds: ["Show"],
            },
          ],
          ret=Type::Int,
          effects=[EffectAtom::Var("e")],
        ),
        span=s,
      ),
      Stmt::ExternLet(name="t_never", ty=Type::Never, span=s),
      // Touch remaining Pat variants via a Match with many arms
      Stmt::Let(
        rec=false,
        name="pat_smoke",
        expr=Expr::Match(
          scrutinee=int_expr,
          arms=[
            MatchArm::{
              pat: Pat::Ctor(name="A", args=[Pat::Bind(name="x", span=s)], span=s),
              cond: None,
              expr: int_expr,
              span: s,
            },
            MatchArm::{
              pat: Pat::Tuple(items=[Pat::Wildcard(span=s)], span=s),
              cond: None,
              expr: int_expr,
              span: s,
            },
            MatchArm::{
              pat: Pat::Record(
                fields=[
                  RecordFieldPat::{
                    name: "k",
                    pat: Pat::Wildcard(span=s),
                    span: s,
                  },
                ],
                span=s,
              ),
              cond: None,
              expr: int_expr,
              span: s,
            },
            MatchArm::{
              pat: Pat::Struct(name="S", fields=[], span=s),
              cond: None,
              expr: int_expr,
              span: s,
            },
            MatchArm::{
              pat: Pat::Int(value=1L, span=s),
              cond: None,
              expr: int_expr,
              span: s,
            },
            MatchArm::{
              pat: Pat::Float(value=1.0, span=s),
              cond: None,
              expr: int_expr,
              span: s,
            },
            MatchArm::{
              pat: Pat::Double(value=2.0, span=s),
              cond: None,
              expr: int_expr,
              span: s,
            },
            MatchArm::{
              pat: Pat::Bool(value=false, span=s),
              cond: None,
              expr: int_expr,
              span: s,
            },
            MatchArm::{
              pat: Pat::Char(value='z', span=s),
              cond: None,
              expr: int_expr,
              span: s,
            },
            MatchArm::{
              pat: Pat::String(value="s", span=s),
              cond: None,
              expr: int_expr,
              span: s,
            },
            MatchArm::{
              pat: Pat::Or(
                pats=[Pat::Wildcard(span=s), Pat::Wildcard(span=s)],
                span=s,
              ),
              cond: None,
              expr: int_expr,
              span: s,
            },
          ],
          span=s,
        ),
        span=s,
      ),
      // ModuleRef tags we haven't hit yet (Symbol, Alias, PinnedPath)
      Stmt::AliasDecl(
        alias_name="sym",
        source=ModuleRef::Symbol(name="@std/math"),
        span=s,
      ),
      Stmt::AliasDecl(
        alias_name="aname",
        source=ModuleRef::Alias(name="types"),
        span=s,
      ),
      Stmt::AliasDecl(
        alias_name="pin",
        source=ModuleRef::PinnedPath(path="./p.vibe", hash="deadbeef"),
        span=s,
      ),
      // ParamLabel Optional & Variadic — only Required/Positional covered above
      Stmt::ExternLet(
        name="t_fn_opt",
        ty=Type::Func(
          params=[
            FuncParam::{
              name: "x",
              label: ParamLabel::Optional,
              ty: Type::Int,
              bounds: [],
            },
            FuncParam::{
              name: "rest",
              label: ParamLabel::Variadic,
              ty: Type::Int,
              bounds: [],
            },
          ],
          ret=Type::Unit,
          effects=[],
        ),
        span=s,
      ),
    ],
  }
}

///|
test "binary ABI: smoke module roundtrips" {
  let m = smoke_module()
  let bytes = serialize_module_binary(m)
  let m2 = try? deserialize_module_binary(bytes)
  let m2 = match m2 {
    Ok(v) => v
    Err(e) => {
      println("deserialize failed: " + Debug::to_repr(e).to_string())
      assert_true(false)
      return
    }
  }
  assert_eq(m, m2)
}

///|
test "binary ABI: empty module" {
  let m = Module::{ stmts: [] }
  let bytes = serialize_module_binary(m)
  let m2 = deserialize_module_binary(bytes) catch {
    e => {
      println("err: " + Debug::to_repr(e).to_string())
      assert_true(false)
      return
    }
  }
  assert_eq(m, m2)
}

///|
test "binary ABI: bad magic rejected" {
  let bad : Bytes = b"\x00\x00\x00\x00\x01"
  let r = try? deserialize_module_binary(bad)
  assert_true(r is Err(BadMagic))
}

///|
test "binary ABI: unsupported version rejected" {
  // Magic + version=99 (single-byte varint)
  let bad : Bytes = b"vAST\x63"
  let r = try? deserialize_module_binary(bad)
  match r {
    Err(UnsupportedVersion(99)) => ()
    _ => assert_true(false)
  }
}

///|
/// Cross-implementation parity fixture: an empty module MUST encode
/// to exactly these 6 bytes — `'v','A','S','T', version=1, count=0`.
/// The matching assertion lives in
/// `vibe/compiler/ast_binary_test.vibe` ("ast_binary: empty-module
/// canonical bytes") so any drift between the two implementations
/// shows up as a test failure on one side or the other.
test "binary ABI: empty module canonical bytes (cross-impl fixture)" {
  let bytes = serialize_module_binary(Module::{ stmts: [] })
  assert_eq(bytes.length(), 6)
  assert_eq(bytes[0], b'v')
  assert_eq(bytes[1], b'A')
  assert_eq(bytes[2], b'S')
  assert_eq(bytes[3], b'T')
  assert_eq(bytes[4], b'\x01') // version=1, single-byte varint
  assert_eq(bytes[5], b'\x00') // stmt-array length=0, single-byte varint
}

///|
/// Cross-impl parity for the svarint corner cases the selfhost test
/// also checks. Encoded byte sequences must match byte-for-byte.
test "binary ABI: svarint canonical bytes (cross-impl fixture)" {
  let cases : Array[(Int64, Array[Byte])] = [
    (-1L, [b'\x7F']),
    (0L, [b'\x00']),
    (63L, [b'\x3F']),
    (64L, [b'\xC0', b'\x00']),
    (-64L, [b'\x40']),
  ]
  for case in cases {
    let (value, expected_bytes) = case
    let buf = @buffer.Buffer(size_hint=8)
    write_svarint(buf, value)
    let got = buf.to_bytes()
    assert_eq(got.length(), expected_bytes.length())
    let mut i = 0
    while i < expected_bytes.length() {
      assert_eq(got[i], expected_bytes[i])
      i = i + 1
    }
  }
}

///|
/// Cross-impl parity for varint corner cases.
test "binary ABI: varint canonical bytes (cross-impl fixture)" {
  let cases : Array[(Int64, Array[Byte])] = [
    (0L, [b'\x00']),
    (127L, [b'\x7F']),
    (128L, [b'\x80', b'\x01']),
    (16384L, [b'\x80', b'\x80', b'\x01']),
  ]
  for case in cases {
    let (value, expected_bytes) = case
    let buf = @buffer.Buffer(size_hint=8)
    write_varint(buf, value)
    let got = buf.to_bytes()
    assert_eq(got.length(), expected_bytes.length())
    let mut i = 0
    while i < expected_bytes.length() {
      assert_eq(got[i], expected_bytes[i])
      i = i + 1
    }
  }
}
