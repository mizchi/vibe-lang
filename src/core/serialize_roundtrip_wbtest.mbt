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
        methods=[],
        open_impl=true,
        exported=false,
        span=zero_span(),
      ),
      Stmt::TraitImpl(
        type_params=["T"],
        type_bounds={ "T": ["Show"] },
        trait_name="Printable",
        target=Type::Named(name="MyType", args=[Type::Param("T")]),
        methods=[],
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
      FuncParam::{
        name: "rest",
        label: ParamLabel::Variadic,
        ty: Type::Array(Type::Int),
        bounds: [],
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
        spec=ImportSpec::{
          items: [
            ImportItem::{ kind: ImportKind::Value, name: "baz", rename: None },
            ImportItem::{
              kind: ImportKind::Value,
              name: "qux",
              rename: Some("quux"),
            },
          ],
        },
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
              expr=Expr::Perform(
                effect_name="Error",
                op_name="Throw",
                args=[
                  CallArg::{
                    label: None,
                    expr: Expr::String(value="none", span=zero_span()),
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
test "roundtrip: block expression" {
  let m = Module::{
    stmts: [
      Stmt::Expr(
        expr=Expr::Block(
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

///|
test "roundtrip: index assign" {
  let m = Module::{
    stmts: [
      Stmt::IndexAssign(
        target=Expr::Ident(name="arr", span=zero_span()),
        index=Expr::Int(value=0L, span=zero_span()),
        value=Expr::Int(value=42L, span=zero_span()),
        span=zero_span(),
      ),
    ],
  }
  let result = roundtrip_module(m)
  assert_eq(result, m)
}

///|
test "roundtrip: struct def" {
  let m = Module::{
    stmts: [
      Stmt::StructDef(
        name="Point",
        params=["T"],
        fields=[
          StructField::{
            name: "x",
            ty: Type::Param("T"),
            is_mut: false,
            span: zero_span(),
          },
          StructField::{
            name: "y",
            ty: Type::Param("T"),
            is_mut: false,
            span: zero_span(),
          },
        ],
        span=zero_span(),
      ),
    ],
  }
  let result = roundtrip_module(m)
  assert_eq(result, m)
}

///|
test "roundtrip: export struct def" {
  let m = Module::{
    stmts: [
      Stmt::ExportStructDef(
        name="Color",
        params=[],
        fields=[
          StructField::{
            name: "r",
            ty: Type::Int,
            is_mut: false,
            span: zero_span(),
          },
          StructField::{
            name: "g",
            ty: Type::Int,
            is_mut: false,
            span: zero_span(),
          },
          StructField::{
            name: "b",
            ty: Type::Int,
            is_mut: false,
            span: zero_span(),
          },
        ],
        span=zero_span(),
      ),
    ],
  }
  let result = roundtrip_module(m)
  assert_eq(result, m)
}

///|
test "roundtrip: placeholder expr" {
  let m = Module::{
    stmts: [
      Stmt::Expr(
        expr=Expr::Placeholder(index=0, span=zero_span()),
        span=zero_span(),
      ),
    ],
  }
  let result = roundtrip_module(m)
  assert_eq(result, m)
}

///|
test "roundtrip: struct lit expr" {
  let m = Module::{
    stmts: [
      Stmt::Expr(
        expr=Expr::StructLit(
          name="Point",
          type_args=[Type::Int],
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
    ],
  }
  let result = roundtrip_module(m)
  assert_eq(result, m)
}

///|
test "roundtrip: struct pattern" {
  let m = Module::{
    stmts: [
      Stmt::Expr(
        expr=Expr::Match(
          scrutinee=Expr::Ident(name="p", span=zero_span()),
          arms=[
            MatchArm::{
              pat: Pat::Struct(
                name="Point",
                fields=[
                  RecordFieldPat::{
                    name: "x",
                    pat: Pat::Bind(name="a", span=zero_span()),
                    span: zero_span(),
                  },
                  RecordFieldPat::{
                    name: "y",
                    pat: Pat::Bind(name="b", span=zero_span()),
                    span: zero_span(),
                  },
                ],
                span=zero_span(),
              ),
              cond: None,
              expr: Expr::Ident(name="a", span=zero_span()),
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
test "roundtrip: handle expression" {
  let m = Module::{
    stmts: [
      Stmt::Expr(
        expr=Expr::Handle(
          body=Module::{
            stmts: [
              Stmt::Expr(
                expr=Expr::Call(
                  name="read_line",
                  type_args=[],
                  args=[],
                  span=zero_span(),
                ),
                span=zero_span(),
              ),
            ],
          },
          arms=[
            MatchArm::{
              pat: Pat::Ctor(
                name="Err",
                args=[Pat::Bind(name="e", span=zero_span())],
                span=zero_span(),
              ),
              cond: None,
              expr: Expr::String(value="error", span=zero_span()),
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
test "roundtrip: raise expression standalone (desugared to Perform)" {
  let m = Module::{
    stmts: [
      Stmt::Expr(
        expr=Expr::Perform(
          effect_name="Error",
          op_name="Throw",
          args=[
            CallArg::{
              label: None,
              expr: Expr::String(value="fail", span=zero_span()),
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
test "roundtrip: pattern literals (float, double, char)" {
  let m = Module::{
    stmts: [
      Stmt::Expr(
        expr=Expr::Match(
          scrutinee=Expr::Ident(name="v", span=zero_span()),
          arms=[
            MatchArm::{
              pat: Pat::Float(value=Float::from_double(1.5), span=zero_span()),
              cond: None,
              expr: Expr::String(value="float", span=zero_span()),
              span: zero_span(),
            },
            MatchArm::{
              pat: Pat::Double(value=2.5, span=zero_span()),
              cond: None,
              expr: Expr::String(value="double", span=zero_span()),
              span: zero_span(),
            },
            MatchArm::{
              pat: Pat::Char(value='Z', span=zero_span()),
              cond: None,
              expr: Expr::String(value="char", span=zero_span()),
              span: zero_span(),
            },
            MatchArm::{
              pat: Pat::Wildcard(span=zero_span()),
              cond: None,
              expr: Expr::String(value="other", span=zero_span()),
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
test "roundtrip: type variants (never, path, prompttext, unit, var)" {
  let m = Module::{
    stmts: [
      Stmt::TypeAlias(name="A", params=[], target=Type::Never, span=zero_span()),
      Stmt::TypeAlias(name="B", params=[], target=Type::Path, span=zero_span()),
      Stmt::TypeAlias(
        name="C",
        params=[],
        target=Type::PromptText,
        span=zero_span(),
      ),
      Stmt::TypeAlias(name="D", params=[], target=Type::Unit, span=zero_span()),
      Stmt::TypeAlias(
        name="E",
        params=[],
        target=Type::Var(42),
        span=zero_span(),
      ),
    ],
  }
  let result = roundtrip_module(m)
  assert_eq(result, m)
}

///|
test "roundtrip: type variants (arraybuilder, mapbuilder, stringbuilder, variant)" {
  let m = Module::{
    stmts: [
      Stmt::TypeAlias(
        name="AB",
        params=[],
        target=Type::ArrayBuilder(Type::Int),
        span=zero_span(),
      ),
      Stmt::TypeAlias(
        name="MB",
        params=[],
        target=Type::MapBuilder(Type::String, Type::String),
        span=zero_span(),
      ),
      Stmt::TypeAlias(
        name="SB",
        params=[],
        target=Type::StringBuilder,
        span=zero_span(),
      ),
      Stmt::TypeAlias(
        name="V",
        params=[],
        target=Type::Variant({ "Ok": Type::Int, "Err": Type::String }),
        span=zero_span(),
      ),
    ],
  }
  let result = roundtrip_module(m)
  assert_eq(result, m)
}

///|
test "roundtrip: type map" {
  let m = Module::{
    stmts: [
      Stmt::TypeAlias(
        name="M",
        params=[],
        target=Type::Map(Type::String, Type::Int),
        span=zero_span(),
      ),
    ],
  }
  let result = roundtrip_module(m)
  assert_eq(result, m)
}

///|
test "roundtrip: int boundary values" {
  let m = Module::{
    stmts: [
      Stmt::Expr(expr=Expr::Int(value=0L, span=zero_span()), span=zero_span()),
      Stmt::Expr(expr=Expr::Int(value=-1L, span=zero_span()), span=zero_span()),
      Stmt::Expr(
        expr=Expr::Int(value=1000000L, span=zero_span()),
        span=zero_span(),
      ),
      Stmt::Expr(
        expr=Expr::Int(value=-1000000L, span=zero_span()),
        span=zero_span(),
      ),
      Stmt::Expr(
        expr=Expr::Int(value=4294967296L, span=zero_span()),
        span=zero_span(),
      ),
    ],
  }
  let result = roundtrip_module(m)
  assert_eq(result, m)
}

///|
test "roundtrip: empty collections" {
  let m = Module::{
    stmts: [
      Stmt::Expr(expr=Expr::Array(items=[], span=zero_span()), span=zero_span()),
      Stmt::Expr(expr=Expr::Map(fields=[], span=zero_span()), span=zero_span()),
      Stmt::Expr(
        expr=Expr::Record(fields=[], span=zero_span()),
        span=zero_span(),
      ),
      Stmt::Expr(expr=Expr::Tuple(items=[], span=zero_span()), span=zero_span()),
    ],
  }
  let result = roundtrip_module(m)
  assert_eq(result, m)
}

///|
test "roundtrip: unicode strings" {
  let m = Module::{
    stmts: [
      Stmt::Expr(
        expr=Expr::String(value="こんにちは世界", span=zero_span()),
        span=zero_span(),
      ),
      Stmt::Expr(
        expr=Expr::String(value="mixed: abc日本語def", span=zero_span()),
        span=zero_span(),
      ),
    ],
  }
  let result = roundtrip_module(m)
  assert_eq(result, m)
}

///|
test "roundtrip: call type_args are erased" {
  // type_args are intentionally dropped during serialization (monomorphized)
  let m = Module::{
    stmts: [
      Stmt::Expr(
        expr=Expr::Call(
          name="identity",
          type_args=[Type::Int, Type::String],
          args=[
            CallArg::{
              label: None,
              expr: Expr::Int(value=1L, span=zero_span()),
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
  let expected = Module::{
    stmts: [
      Stmt::Expr(
        expr=Expr::Call(
          name="identity",
          type_args=[],
          args=[
            CallArg::{
              label: None,
              expr: Expr::Int(value=1L, span=zero_span()),
              span: zero_span(),
            },
          ],
          span=zero_span(),
        ),
        span=zero_span(),
      ),
    ],
  }
  assert_eq(result, expected)
}

///|
test "roundtrip: fn with no return type" {
  let m = Module::{
    stmts: [
      Stmt::Let(
        rec=false,
        name="f",
        expr=Expr::Fn(
          type_params=[],
          type_bounds={},
          params=[],
          ret=None,
          effects=[],
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
        span=zero_span(),
      ),
    ],
  }
  let result = roundtrip_module(m)
  assert_eq(result, m)
}

///|
test "roundtrip: fn with multiple effects" {
  let m = Module::{
    stmts: [
      Stmt::Let(
        rec=false,
        name="g",
        expr=Expr::Fn(
          type_params=["E"],
          type_bounds={},
          params=[],
          ret=Some(Type::Unit),
          effects=[
            EffectAtom::Const("IO"),
            EffectAtom::Const("Fs"),
            EffectAtom::Var("E"),
          ],
          body=Module::{ stmts: [] },
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
test "roundtrip: trait def with exported=true" {
  let m = Module::{
    stmts: [
      Stmt::TraitDef(
        name="Serializable",
        supertraits=[],
        methods=[],
        open_impl=false,
        exported=true,
        span=zero_span(),
      ),
    ],
  }
  let result = roundtrip_module(m)
  assert_eq(result, m)
}

///|
test "roundtrip: deep nesting" {
  let inner = Expr::Int(value=1L, span=zero_span())
  let nested = Expr::If(
    cond=Expr::Bool(value=true, span=zero_span()),
    then_body=Module::{
      stmts: [
        Stmt::Expr(
          expr=Expr::Block(
            body=Module::{
              stmts: [
                Stmt::Expr(
                  expr=Expr::Block(
                    body=Module::{
                      stmts: [
                        Stmt::Expr(
                          expr=Expr::Match(
                            scrutinee=inner,
                            arms=[
                              MatchArm::{
                                pat: Pat::Wildcard(span=zero_span()),
                                cond: None,
                                expr: Expr::Array(
                                  items=[
                                    Expr::Tuple(
                                      items=[
                                        Expr::String(
                                          value="deep",
                                          span=zero_span(),
                                        ),
                                        Expr::Int(value=42L, span=zero_span()),
                                      ],
                                      span=zero_span(),
                                    ),
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
            },
            span=zero_span(),
          ),
          span=zero_span(),
        ),
      ],
    },
    else_body=Module::{ stmts: [] },
    span=zero_span(),
  )
  let m = Module::{ stmts: [Stmt::Expr(expr=nested, span=zero_span())] }
  let result = roundtrip_module(m)
  assert_eq(result, m)
}
