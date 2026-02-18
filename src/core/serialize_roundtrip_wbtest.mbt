///| Round-trip serialization tests: deserialize(serialize(x)) == x

///| All AST nodes use zero-span since deserialization drops span info.

///|
fn zero_span() -> Span {
  Span::{ start: 0, end: 0 }
}

///|
fn roundtrip_module(m : Module) -> Module raise DeserializeError {
  let json = serialize_module(m)
  deserialize_module(json)
}

///|
test "roundtrip: let binding (non-recursive)" {
  let m = Module::{
    stmts: [
      Stmt::Let(
        rec=false,
        name="x",
        expr=Expr::Int(value=42L, span=zero_span()),
        span=zero_span(),
      ),
    ],
  }
  let result = roundtrip_module(m)
  assert_eq(result, m)
}

///|
test "roundtrip: let binding (recursive)" {
  let m = Module::{
    stmts: [
      Stmt::Let(
        rec=true,
        name="fact",
        expr=Expr::Fn(
          type_params=[],
          type_bounds={},
          params=[
            FuncParam::{
              name: "n",
              label: ParamLabel::Positional,
              ty: Type::Int,
              bounds: [],
            },
          ],
          ret=Some(Type::Int),
          effects=[],
          body=Module::{
            stmts: [
              Stmt::Expr(
                expr=Expr::Ident(name="n", span=zero_span()),
                span=zero_span(),
              ),
            ],
          },
          span=zero_span(),
        ),
        span=zero_span(),
      ),
    ],
  }
  let result = roundtrip_module(m)
  assert_eq(result, m)
}

///|
test "roundtrip: let-mut and assign" {
  let m = Module::{
    stmts: [
      Stmt::LetMut(
        name="counter",
        expr=Expr::Int(value=0L, span=zero_span()),
        span=zero_span(),
      ),
      Stmt::Assign(
        name="counter",
        expr=Expr::Int(value=1L, span=zero_span()),
        span=zero_span(),
      ),
    ],
  }
  let result = roundtrip_module(m)
  assert_eq(result, m)
}

///|
test "roundtrip: expr literals (int, float, double, bool, char, string)" {
  let m = Module::{
    stmts: [
      Stmt::Expr(expr=Expr::Int(value=99L, span=zero_span()), span=zero_span()),
      Stmt::Expr(
        expr=Expr::Float(value=Float::from_double(3.14), span=zero_span()),
        span=zero_span(),
      ),
      Stmt::Expr(
        expr=Expr::Double(value=2.718, span=zero_span()),
        span=zero_span(),
      ),
      Stmt::Expr(
        expr=Expr::Bool(value=true, span=zero_span()),
        span=zero_span(),
      ),
      Stmt::Expr(expr=Expr::Char(value='A', span=zero_span()), span=zero_span()),
      Stmt::Expr(
        expr=Expr::String(value="hello", span=zero_span()),
        span=zero_span(),
      ),
    ],
  }
  let result = roundtrip_module(m)
  assert_eq(result, m)
}

///|
test "roundtrip: call expression with labeled args" {
  let m = Module::{
    stmts: [
      Stmt::Expr(
        expr=Expr::Call(
          name="add",
          type_args=[],
          args=[
            CallArg::{
              label: None,
              expr: Expr::Int(value=1L, span=zero_span()),
              span: zero_span(),
            },
            CallArg::{
              label: Some("y"),
              expr: Expr::Int(value=2L, span=zero_span()),
              span: zero_span(),
            },
          ],
          span=zero_span(),
        ),
        span=zero_span(),
      ),
    ],
  }
  let result = roundtrip_module(m)
  assert_eq(result, m)
}

///|
test "roundtrip: if-else expression" {
  let m = Module::{
    stmts: [
      Stmt::Expr(
        expr=Expr::If(
          cond=Expr::Bool(value=true, span=zero_span()),
          then_body=Module::{
            stmts: [
              Stmt::Expr(
                expr=Expr::Int(value=1L, span=zero_span()),
                span=zero_span(),
              ),
            ],
          },
          else_body=Module::{
            stmts: [
              Stmt::Expr(
                expr=Expr::Int(value=2L, span=zero_span()),
                span=zero_span(),
              ),
            ],
          },
          span=zero_span(),
        ),
        span=zero_span(),
      ),
    ],
  }
  let result = roundtrip_module(m)
  assert_eq(result, m)
}

///|
test "roundtrip: match expression with patterns" {
  let m = Module::{
    stmts: [
      Stmt::Expr(
        expr=Expr::Match(
          scrutinee=Expr::Ident(name="x", span=zero_span()),
          arms=[
            MatchArm::{
              pat: Pat::Int(value=0L, span=zero_span()),
              cond: None,
              expr: Expr::String(value="zero", span=zero_span()),
              span: zero_span(),
            },
            MatchArm::{
              pat: Pat::Bind(name="n", span=zero_span()),
              cond: Some(
                Expr::Call(
                  name=">",
                  type_args=[],
                  args=[
                    CallArg::{
                      label: None,
                      expr: Expr::Ident(name="n", span=zero_span()),
                      span: zero_span(),
                    },
                    CallArg::{
                      label: None,
                      expr: Expr::Int(value=0L, span=zero_span()),
                      span: zero_span(),
                    },
                  ],
                  span=zero_span(),
                ),
              ),
              expr: Expr::String(value="positive", span=zero_span()),
              span: zero_span(),
            },
            MatchArm::{
              pat: Pat::Wildcard(span=zero_span()),
              cond: None,
              expr: Expr::String(value="negative", span=zero_span()),
              span: zero_span(),
            },
          ],
          span=zero_span(),
        ),
        span=zero_span(),
      ),
    ],
  }
  let result = roundtrip_module(m)
  assert_eq(result, m)
}

///|
test "roundtrip: fn expression with params and effects" {
  let m = Module::{
    stmts: [
      Stmt::Let(
        rec=false,
        name="greet",
        expr=Expr::Fn(
          type_params=["T"],
          type_bounds={ "T": ["Show"] },
          params=[
            FuncParam::{
              name: "name",
              label: ParamLabel::Required,
              ty: Type::String,
              bounds: [],
            },
            FuncParam::{
              name: "loud",
              label: ParamLabel::Optional,
              ty: Type::Bool,
              bounds: [],
            },
          ],
          ret=Some(Type::String),
          effects=[EffectAtom::Const("IO")],
          body=Module::{
            stmts: [
              Stmt::Expr(
                expr=Expr::Ident(name="name", span=zero_span()),
                span=zero_span(),
              ),
            ],
          },
          span=zero_span(),
        ),
        span=zero_span(),
      ),
    ],
  }
  let result = roundtrip_module(m)
  assert_eq(result, m)
}

///|
test "roundtrip: enum def" {
  let m = Module::{
    stmts: [
      Stmt::EnumDef(
        name="Option",
        params=["T"],
        ctors=[
          TypeCtor::{
            name: "Some",
            args: [Type::Param("T")],
            span: zero_span(),
          },
          TypeCtor::{ name: "None", args: [], span: zero_span() },
        ],
        span=zero_span(),
      ),
    ],
  }
  let result = roundtrip_module(m)
  assert_eq(result, m)
}

///|
test "roundtrip: type alias" {
  let m = Module::{
    stmts: [
      Stmt::TypeAlias(
        name="IntList",
        params=[],
        target=Type::Array(Type::Int),
        span=zero_span(),
      ),
    ],
  }
  let result = roundtrip_module(m)
  assert_eq(result, m)
}

///|
test "roundtrip: trait def and trait impl" {
  let m = Module::{
    stmts: [
      Stmt::TraitDef(
        name="Printable",
        supertraits=["Show"],
        open_impl=true,
        exported=false,
        span=zero_span(),
      ),
      Stmt::TraitImpl(
        type_params=["T"],
        type_bounds={ "T": ["Show"] },
        trait_name="Printable",
        target=Type::Named(name="MyType", args=[Type::Param("T")]),
        span=zero_span(),
      ),
    ],
  }
  let result = roundtrip_module(m)
  assert_eq(result, m)
}

///|
test "roundtrip: import statement" {
  let m = Module::{
    stmts: [
      Stmt::Import(
        spec=ImportSpec::{
          items: [
            ImportItem::{ kind: ImportKind::Value, name: "foo", rename: None },
            ImportItem::{
              kind: ImportKind::Type,
              name: "Bar",
              rename: Some("Baz"),
            },
            ImportItem::{ kind: ImportKind::Trait, name: "Eq", rename: None },
            ImportItem::{
              kind: ImportKind::Module,
              name: "utils",
              rename: None,
            },
          ],
        },
        source=ModuleRef::Path(path="./math.vibe"),
        span=zero_span(),
      ),
    ],
  }
  let result = roundtrip_module(m)
  assert_eq(result, m)
}

///|
test "roundtrip: array and tuple expressions" {
  let m = Module::{
    stmts: [
      Stmt::Expr(
        expr=Expr::Array(
          items=[
            Expr::Int(value=1L, span=zero_span()),
            Expr::Int(value=2L, span=zero_span()),
            Expr::Int(value=3L, span=zero_span()),
          ],
          span=zero_span(),
        ),
        span=zero_span(),
      ),
      Stmt::Expr(
        expr=Expr::Tuple(
          items=[
            Expr::String(value="a", span=zero_span()),
            Expr::Int(value=1L, span=zero_span()),
          ],
          span=zero_span(),
        ),
        span=zero_span(),
      ),
      Stmt::Expr(
        expr=Expr::TupleIndex(
          expr=Expr::Ident(name="t", span=zero_span()),
          index=0,
          span=zero_span(),
        ),
        span=zero_span(),
      ),
    ],
  }
  let result = roundtrip_module(m)
  assert_eq(result, m)
}

///|
test "roundtrip: record and map expressions" {
  let m = Module::{
    stmts: [
      Stmt::Expr(
        expr=Expr::Record(
          fields=[
            RecordFieldExpr::{
              name: "x",
              expr: Expr::Int(value=1L, span=zero_span()),
              span: zero_span(),
            },
            RecordFieldExpr::{
              name: "y",
              expr: Expr::Int(value=2L, span=zero_span()),
              span: zero_span(),
            },
          ],
          span=zero_span(),
        ),
        span=zero_span(),
      ),
      Stmt::Expr(
        expr=Expr::Map(
          fields=[
            MapFieldExpr::{
              key: "name",
              expr: Expr::String(value="Alice", span=zero_span()),
              span: zero_span(),
            },
          ],
          span=zero_span(),
        ),
        span=zero_span(),
      ),
    ],
  }
  let result = roundtrip_module(m)
  assert_eq(result, m)
}

///|
test "roundtrip: while loop and block" {
  let m = Module::{
    stmts: [
      Stmt::Expr(
        expr=Expr::While(
          cond=Expr::Bool(value=true, span=zero_span()),
          body=Module::{
            stmts: [
              Stmt::Expr(
                expr=Expr::Break(value=None, span=zero_span()),
                span=zero_span(),
              ),
            ],
          },
          span=zero_span(),
        ),
        span=zero_span(),
      ),
      Stmt::Expr(
        expr=Expr::Block(
          body=Module::{
            stmts: [
              Stmt::Expr(
                expr=Expr::Int(value=42L, span=zero_span()),
                span=zero_span(),
              ),
            ],
          },
          span=zero_span(),
        ),
        span=zero_span(),
      ),
    ],
  }
  let result = roundtrip_module(m)
  assert_eq(result, m)
}

///|
test "roundtrip: pattern variants (ctor, tuple, record, or)" {
  let m = Module::{
    stmts: [
      Stmt::Expr(
        expr=Expr::Match(
          scrutinee=Expr::Ident(name="v", span=zero_span()),
          arms=[
            MatchArm::{
              pat: Pat::Ctor(
                name="Some",
                args=[Pat::Bind(name="x", span=zero_span())],
                span=zero_span(),
              ),
              cond: None,
              expr: Expr::Ident(name="x", span=zero_span()),
              span: zero_span(),
            },
            MatchArm::{
              pat: Pat::Tuple(
                items=[
                  Pat::Int(value=1L, span=zero_span()),
                  Pat::String(value="hi", span=zero_span()),
                ],
                span=zero_span(),
              ),
              cond: None,
              expr: Expr::Int(value=0L, span=zero_span()),
              span: zero_span(),
            },
            MatchArm::{
              pat: Pat::Record(
                fields=[
                  RecordFieldPat::{
                    name: "x",
                    pat: Pat::Bind(name="a", span=zero_span()),
                    span: zero_span(),
                  },
                ],
                span=zero_span(),
              ),
              cond: None,
              expr: Expr::Ident(name="a", span=zero_span()),
              span: zero_span(),
            },
            MatchArm::{
              pat: Pat::Or(
                pats=[
                  Pat::Bool(value=true, span=zero_span()),
                  Pat::Bool(value=false, span=zero_span()),
                ],
                span=zero_span(),
              ),
              cond: None,
              expr: Expr::String(value="bool", span=zero_span()),
              span: zero_span(),
            },
          ],
          span=zero_span(),
        ),
        span=zero_span(),
      ),
    ],
  }
  let result = roundtrip_module(m)
  assert_eq(result, m)
}

///|
test "roundtrip: type variants (func, named, tuple, record, variant)" {
  let func_type = Type::Func(
    params=[
      FuncParam::{
        name: "a",
        label: ParamLabel::Positional,
        ty: Type::Int,
        bounds: [],
      },
      FuncParam::{
        name: "b",
        label: ParamLabel::Required,
        ty: Type::String,
        bounds: ["Show"],
      },
    ],
    ret=Type::Bool,
    effects=[EffectAtom::Var("E")],
  )
  let m = Module::{
    stmts: [
      Stmt::TypeAlias(
        name="MyFunc",
        params=[],
        target=func_type,
        span=zero_span(),
      ),
      Stmt::TypeAlias(
        name="Pair",
        params=["A", "B"],
        target=Type::Tuple([Type::Param("A"), Type::Param("B")]),
        span=zero_span(),
      ),
      Stmt::TypeAlias(
        name="Point",
        params=[],
        target=Type::Record({ "x": Type::Int, "y": Type::Int }),
        span=zero_span(),
      ),
      Stmt::TypeAlias(
        name="Container",
        params=[],
        target=Type::Named(name="List", args=[Type::Int]),
        span=zero_span(),
      ),
    ],
  }
  let result = roundtrip_module(m)
  assert_eq(result, m)
}

///|
test "roundtrip: export statements" {
  let m = Module::{
    stmts: [
      Stmt::ExportLet(
        rec=false,
        name="pi",
        expr=Expr::Double(value=3.14159, span=zero_span()),
        span=zero_span(),
      ),
      Stmt::ExportEnumDef(
        name="Color",
        params=[],
        ctors=[
          TypeCtor::{ name: "Red", args: [], span: zero_span() },
          TypeCtor::{ name: "Green", args: [], span: zero_span() },
          TypeCtor::{ name: "Blue", args: [], span: zero_span() },
        ],
        span=zero_span(),
      ),
      Stmt::ExportTypeAlias(
        name="Num",
        params=[],
        target=Type::Int,
        span=zero_span(),
      ),
      Stmt::Export(names=["foo", "bar"], span=zero_span()),
      Stmt::ReExport(
        names=["baz"],
        source=ModuleRef::Hash(hash="abc123"),
        span=zero_span(),
      ),
    ],
  }
  let result = roundtrip_module(m)
  assert_eq(result, m)
}

///|
test "roundtrip: let-pat and let-pat-else" {
  let m = Module::{
    stmts: [
      Stmt::LetPat(
        pat=Pat::Tuple(
          items=[
            Pat::Bind(name="a", span=zero_span()),
            Pat::Bind(name="b", span=zero_span()),
          ],
          span=zero_span(),
        ),
        expr=Expr::Tuple(
          items=[
            Expr::Int(value=1L, span=zero_span()),
            Expr::Int(value=2L, span=zero_span()),
          ],
          span=zero_span(),
        ),
        span=zero_span(),
      ),
      Stmt::LetPatElse(
        pat=Pat::Ctor(
          name="Some",
          args=[Pat::Bind(name="x", span=zero_span())],
          span=zero_span(),
        ),
        expr=Expr::Ident(name="opt", span=zero_span()),
        else_body=Module::{
          stmts: [
            Stmt::Expr(
              expr=Expr::Raise(
                value=Expr::String(value="none", span=zero_span()),
                span=zero_span(),
              ),
              span=zero_span(),
            ),
          ],
        },
        span=zero_span(),
      ),
    ],
  }
  let result = roundtrip_module(m)
  assert_eq(result, m)
}

///|
test "roundtrip: loop with params and continue" {
  let m = Module::{
    stmts: [
      Stmt::Expr(
        expr=Expr::Loop(
          params=[
            LoopParam::{
              name: "i",
              init: Expr::Int(value=0L, span=zero_span()),
              span: zero_span(),
            },
          ],
          body=Module::{
            stmts: [
              Stmt::Expr(
                expr=Expr::Continue(args=[], span=zero_span()),
                span=zero_span(),
              ),
            ],
          },
          span=zero_span(),
        ),
        span=zero_span(),
      ),
    ],
  }
  let result = roundtrip_module(m)
  assert_eq(result, m)
}

///|
test "roundtrip: yield" {
  let m = Module::{
    stmts: [
      Stmt::Expr(
        expr=Expr::Yield(
          expr=Expr::Int(value=1L, span=zero_span()),
          span=zero_span(),
        ),
        span=zero_span(),
      ),
    ],
  }
  let result = roundtrip_module(m)
  assert_eq(result, m)
}

///|
test "roundtrip: test and bench stmts" {
  let m = Module::{
    stmts: [
      Stmt::Test(
        name=Some("my test"),
        body=Module::{
          stmts: [
            Stmt::Expr(
              expr=Expr::Bool(value=true, span=zero_span()),
              span=zero_span(),
            ),
          ],
        },
        span=zero_span(),
      ),
      Stmt::Bench(
        name=None,
        body=Module::{
          stmts: [
            Stmt::Expr(
              expr=Expr::Int(value=0L, span=zero_span()),
              span=zero_span(),
            ),
          ],
        },
        span=zero_span(),
      ),
    ],
  }
  let result = roundtrip_module(m)
  assert_eq(result, m)
}

///|
test "roundtrip: module ref variants" {
  let m = Module::{
    stmts: [
      Stmt::Import(
        spec=ImportSpec::{
          items: [
            ImportItem::{ kind: ImportKind::Value, name: "a", rename: None },
          ],
        },
        source=ModuleRef::Path(path="./mod.vibe"),
        span=zero_span(),
      ),
      Stmt::Import(
        spec=ImportSpec::{
          items: [
            ImportItem::{ kind: ImportKind::Value, name: "b", rename: None },
          ],
        },
        source=ModuleRef::Hash(hash="deadbeef"),
        span=zero_span(),
      ),
      Stmt::Import(
        spec=ImportSpec::{
          items: [
            ImportItem::{ kind: ImportKind::Value, name: "c", rename: None },
          ],
        },
        source=ModuleRef::Version(name="v1.0"),
        span=zero_span(),
      ),
      Stmt::Import(
        spec=ImportSpec::{
          items: [
            ImportItem::{ kind: ImportKind::Value, name: "d", rename: None },
          ],
        },
        source=ModuleRef::Symbol(name="std/io"),
        span=zero_span(),
      ),
    ],
  }
  let result = roundtrip_module(m)
  assert_eq(result, m)
}

///|
test "roundtrip: do expression" {
  let m = Module::{
    stmts: [
      Stmt::Expr(
        expr=Expr::Do(
          body=Module::{
            stmts: [
              Stmt::Expr(
                expr=Expr::String(value="side effect", span=zero_span()),
                span=zero_span(),
              ),
            ],
          },
          span=zero_span(),
        ),
        span=zero_span(),
      ),
    ],
  }
  let result = roundtrip_module(m)
  assert_eq(result, m)
}

///|
test "roundtrip: complex nested program" {
  let m = Module::{
    stmts: [
      Stmt::EnumDef(
        name="Tree",
        params=["T"],
        ctors=[
          TypeCtor::{
            name: "Leaf",
            args: [Type::Param("T")],
            span: zero_span(),
          },
          TypeCtor::{
            name: "Node",
            args: [
              Type::Named(name="Tree", args=[Type::Param("T")]),
              Type::Named(name="Tree", args=[Type::Param("T")]),
            ],
            span: zero_span(),
          },
        ],
        span=zero_span(),
      ),
      Stmt::Let(
        rec=true,
        name="sum_tree",
        expr=Expr::Fn(
          type_params=[],
          type_bounds={},
          params=[
            FuncParam::{
              name: "tree",
              label: ParamLabel::Positional,
              ty: Type::Named(name="Tree", args=[Type::Int]),
              bounds: [],
            },
          ],
          ret=Some(Type::Int),
          effects=[],
          body=Module::{
            stmts: [
              Stmt::Expr(
                expr=Expr::Match(
                  scrutinee=Expr::Ident(name="tree", span=zero_span()),
                  arms=[
                    MatchArm::{
                      pat: Pat::Ctor(
                        name="Leaf",
                        args=[Pat::Bind(name="v", span=zero_span())],
                        span=zero_span(),
                      ),
                      cond: None,
                      expr: Expr::Ident(name="v", span=zero_span()),
                      span: zero_span(),
                    },
                    MatchArm::{
                      pat: Pat::Ctor(
                        name="Node",
                        args=[
                          Pat::Bind(name="l", span=zero_span()),
                          Pat::Bind(name="r", span=zero_span()),
                        ],
                        span=zero_span(),
                      ),
                      cond: None,
                      expr: Expr::Call(
                        name="+",
                        type_args=[],
                        args=[
                          CallArg::{
                            label: None,
                            expr: Expr::Call(
                              name="sum_tree",
                              type_args=[],
                              args=[
                                CallArg::{
                                  label: None,
                                  expr: Expr::Ident(name="l", span=zero_span()),
                                  span: zero_span(),
                                },
                              ],
                              span=zero_span(),
                            ),
                            span: zero_span(),
                          },
                          CallArg::{
                            label: None,
                            expr: Expr::Call(
                              name="sum_tree",
                              type_args=[],
                              args=[
                                CallArg::{
                                  label: None,
                                  expr: Expr::Ident(name="r", span=zero_span()),
                                  span: zero_span(),
                                },
                              ],
                              span=zero_span(),
                            ),
                            span: zero_span(),
                          },
                        ],
                        span=zero_span(),
                      ),
                      span: zero_span(),
                    },
                  ],
                  span=zero_span(),
                ),
                span=zero_span(),
              ),
            ],
          },
          span=zero_span(),
        ),
        span=zero_span(),
      ),
    ],
  }
  let result = roundtrip_module(m)
  assert_eq(result, m)
}

///|
test "roundtrip: string with special characters" {
  let m = Module::{
    stmts: [
      Stmt::Expr(
        expr=Expr::String(
          value="hello\nworld\t\"quoted\"\\backslash",
          span=zero_span(),
        ),
        span=zero_span(),
      ),
    ],
  }
  let result = roundtrip_module(m)
  assert_eq(result, m)
}

///|
test "roundtrip: empty module" {
  let m = Module::{ stmts: [] }
  let result = roundtrip_module(m)
  assert_eq(result, m)
}
