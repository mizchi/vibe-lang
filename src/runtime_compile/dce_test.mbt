///|
/// Tests for Dead Code Elimination
test "dce: keeps used definitions" {
  let stmts : Array[@core.Stmt] = [
    @core.Stmt::Let(
      rec=false,
      name="x",
      expr=@core.Expr::Int(value=1L, span=@core.Span::empty(0)),
      span=@core.Span::empty(0),
    ),
    @core.Stmt::Expr(
      expr=@core.Expr::Ident(name="x", span=@core.Span::empty(0)),
      span=@core.Span::empty(0),
    ),
  ]
  let input = @core.Module::{ stmts, }
  let result = @pipeline.dce_module(input)
  // Both statements should be kept: x is used
  inspect(result.stmts.length(), content="2")
}

///|
test "dce: removes unused definitions" {
  let stmts : Array[@core.Stmt] = [
    @core.Stmt::Let(
      rec=false,
      name="unused",
      expr=@core.Expr::Int(value=1L, span=@core.Span::empty(0)),
      span=@core.Span::empty(0),
    ),
    @core.Stmt::Let(
      rec=false,
      name="used",
      expr=@core.Expr::Int(value=2L, span=@core.Span::empty(0)),
      span=@core.Span::empty(0),
    ),
    @core.Stmt::Expr(
      expr=@core.Expr::Ident(name="used", span=@core.Span::empty(0)),
      span=@core.Span::empty(0),
    ),
  ]
  let input = @core.Module::{ stmts, }
  let result = @pipeline.dce_module(input)
  // Only 'used' definition and expression should remain
  inspect(result.stmts.length(), content="2")
  match result.stmts[0] {
    @core.Stmt::Let(name~, ..) => inspect(name, content="used")
    _ => fail("expected Let")
  }
}

///|
test "dce: keeps transitive dependencies" {
  // let a = 1; let b = a; b
  let stmts : Array[@core.Stmt] = [
    @core.Stmt::Let(
      rec=false,
      name="a",
      expr=@core.Expr::Int(value=1L, span=@core.Span::empty(0)),
      span=@core.Span::empty(0),
    ),
    @core.Stmt::Let(
      rec=false,
      name="b",
      expr=@core.Expr::Ident(name="a", span=@core.Span::empty(0)),
      span=@core.Span::empty(0),
    ),
    @core.Stmt::Expr(
      expr=@core.Expr::Ident(name="b", span=@core.Span::empty(0)),
      span=@core.Span::empty(0),
    ),
  ]
  let input = @core.Module::{ stmts, }
  let result = @pipeline.dce_module(input)
  // All statements should be kept: a -> b -> expr
  inspect(result.stmts.length(), content="3")
}

///|
test "dce: keeps last let statement" {
  // let x = 1 (as last statement, its value is returned)
  let stmts : Array[@core.Stmt] = [
    @core.Stmt::Let(
      rec=false,
      name="x",
      expr=@core.Expr::Int(value=1L, span=@core.Span::empty(0)),
      span=@core.Span::empty(0),
    ),
  ]
  let input = @core.Module::{ stmts, }
  let result = @pipeline.dce_module(input)
  // Should keep the let statement since it's the last one
  inspect(result.stmts.length(), content="1")
}

///|
test "dce: keeps exports" {
  let stmts : Array[@core.Stmt] = [
    @core.Stmt::Let(
      rec=false,
      name="unused",
      expr=@core.Expr::Int(value=1L, span=@core.Span::empty(0)),
      span=@core.Span::empty(0),
    ),
    @core.Stmt::ExportLet(
      rec=false,
      name="exported",
      expr=@core.Expr::Int(value=2L, span=@core.Span::empty(0)),
      span=@core.Span::empty(0),
    ),
  ]
  let input = @core.Module::{ stmts, }
  let result = @pipeline.dce_module(input)
  // Only exported should remain
  inspect(result.stmts.length(), content="1")
  match result.stmts[0] {
    @core.Stmt::ExportLet(name~, ..) => inspect(name, content="exported")
    _ => fail("expected ExportLet")
  }
}

///|
test "dce: removes multiple unused" {
  let stmts : Array[@core.Stmt] = [
    @core.Stmt::Let(
      rec=false,
      name="unused1",
      expr=@core.Expr::Int(value=1L, span=@core.Span::empty(0)),
      span=@core.Span::empty(0),
    ),
    @core.Stmt::Let(
      rec=false,
      name="unused2",
      expr=@core.Expr::Int(value=2L, span=@core.Span::empty(0)),
      span=@core.Span::empty(0),
    ),
    @core.Stmt::Let(
      rec=false,
      name="unused3",
      expr=@core.Expr::Int(value=3L, span=@core.Span::empty(0)),
      span=@core.Span::empty(0),
    ),
    @core.Stmt::ExportLet(
      rec=false,
      name="used",
      expr=@core.Expr::Int(value=4L, span=@core.Span::empty(0)),
      span=@core.Span::empty(0),
    ),
  ]
  let input = @core.Module::{ stmts, }
  let result = @pipeline.dce_module(input)
  // Only exported 'used' should remain
  inspect(result.stmts.length(), content="1")
}

///|
test "dce: keeps function dependencies" {
  // let helper = (x) -> x; let main = (y) -> helper(y); main(1)
  let helper_body = @core.Module::{
    stmts: [
      @core.Stmt::Expr(
        expr=@core.Expr::Ident(name="x", span=@core.Span::empty(0)),
        span=@core.Span::empty(0),
      ),
    ],
  }
  let main_body = @core.Module::{
    stmts: [
      @core.Stmt::Expr(
        expr=@core.Expr::Call(
          name="helper",
          type_args=[],
          args=[
            @core.CallArg::{
              label: None,
              expr: @core.Expr::Ident(name="y", span=@core.Span::empty(0)),
              span: @core.Span::empty(0),
            },
          ],
          span=@core.Span::empty(0),
        ),
        span=@core.Span::empty(0),
      ),
    ],
  }
  let stmts : Array[@core.Stmt] = [
    @core.Stmt::Let(
      rec=false,
      name="helper",
      expr=@core.Expr::Fn(
        type_params=[],
        type_bounds={},
        params=[
          @core.FuncParam::{
            name: "x",
            label: @core.ParamLabel::Positional,
            ty: @core.Type::Int,
            bounds: [],
          },
        ],
        ret=Some(@core.Type::Int),
        effects=[],
        body=helper_body,
        span=@core.Span::empty(0),
      ),
      span=@core.Span::empty(0),
    ),
    @core.Stmt::Let(
      rec=false,
      name="main",
      expr=@core.Expr::Fn(
        type_params=[],
        type_bounds={},
        params=[
          @core.FuncParam::{
            name: "y",
            label: @core.ParamLabel::Positional,
            ty: @core.Type::Int,
            bounds: [],
          },
        ],
        ret=Some(@core.Type::Int),
        effects=[],
        body=main_body,
        span=@core.Span::empty(0),
      ),
      span=@core.Span::empty(0),
    ),
    @core.Stmt::Expr(
      expr=@core.Expr::Call(
        name="main",
        type_args=[],
        args=[
          @core.CallArg::{
            label: None,
            expr: @core.Expr::Int(value=1L, span=@core.Span::empty(0)),
            span: @core.Span::empty(0),
          },
        ],
        span=@core.Span::empty(0),
      ),
      span=@core.Span::empty(0),
    ),
  ]
  let input = @core.Module::{ stmts, }
  let result = @pipeline.dce_module(input)
  // All 3 should be kept: helper <- main <- expr
  inspect(result.stmts.length(), content="3")
}

///|
test "dce: merges dependencies for duplicate definition names" {
  let inner_body = @core.Module::{
    stmts: [
      @core.Stmt::Expr(
        expr=@core.Expr::Ident(name="v", span=@core.Span::empty(0)),
        span=@core.Span::empty(0),
      ),
    ],
  }
  let shared_impl_body = @core.Module::{
    stmts: [
      @core.Stmt::Expr(
        expr=@core.Expr::Call(
          name="inner",
          type_args=[],
          args=[
            @core.CallArg::{
              label: None,
              expr: @core.Expr::Ident(name="v", span=@core.Span::empty(0)),
              span: @core.Span::empty(0),
            },
          ],
          span=@core.Span::empty(0),
        ),
        span=@core.Span::empty(0),
      ),
    ],
  }
  let outer_body = @core.Module::{
    stmts: [
      @core.Stmt::Expr(
        expr=@core.Expr::Call(
          name="shared",
          type_args=[],
          args=[
            @core.CallArg::{
              label: None,
              expr: @core.Expr::Ident(name="v", span=@core.Span::empty(0)),
              span: @core.Span::empty(0),
            },
          ],
          span=@core.Span::empty(0),
        ),
        span=@core.Span::empty(0),
      ),
    ],
  }
  let param = @core.FuncParam::{
    name: "v",
    label: @core.ParamLabel::Positional,
    ty: @core.Type::Int,
    bounds: [],
  }
  let stmts : Array[@core.Stmt] = [
    @core.Stmt::Let(
      rec=false,
      name="inner",
      expr=@core.Expr::Fn(
        type_params=[],
        type_bounds={},
        params=[param],
        ret=Some(@core.Type::Int),
        effects=[],
        body=inner_body,
        span=@core.Span::empty(0),
      ),
      span=@core.Span::empty(0),
    ),
    @core.Stmt::Let(
      rec=false,
      name="shared",
      expr=@core.Expr::Fn(
        type_params=[],
        type_bounds={},
        params=[param],
        ret=Some(@core.Type::Int),
        effects=[],
        body=shared_impl_body,
        span=@core.Span::empty(0),
      ),
      span=@core.Span::empty(0),
    ),
    @core.Stmt::Let(
      rec=false,
      name="outer",
      expr=@core.Expr::Fn(
        type_params=[],
        type_bounds={},
        params=[param],
        ret=Some(@core.Type::Int),
        effects=[],
        body=outer_body,
        span=@core.Span::empty(0),
      ),
      span=@core.Span::empty(0),
    ),
    @core.Stmt::Let(
      rec=false,
      name="shared",
      expr=@core.Expr::Ident(name="outer", span=@core.Span::empty(0)),
      span=@core.Span::empty(0),
    ),
    @core.Stmt::Expr(
      expr=@core.Expr::Call(
        name="shared",
        type_args=[],
        args=[
          @core.CallArg::{
            label: None,
            expr: @core.Expr::Int(value=1L, span=@core.Span::empty(0)),
            span: @core.Span::empty(0),
          },
        ],
        span=@core.Span::empty(0),
      ),
      span=@core.Span::empty(0),
    ),
  ]
  let input = @core.Module::{ stmts, }
  let result = @pipeline.dce_module(input)
  let mut has_inner = false
  for stmt in result.stmts {
    match stmt {
      @core.Stmt::Let(name~, ..) => if name == "inner" { has_inner = true }
      _ => ()
    }
  }
  inspect(has_inner, content="true")
}

///|
test "dce: keeps user-defined builtin names (mul shadow)" {
  // let mul = (x) -> x * 2; mul(5)
  // "mul" is in is_builtin_name, but user redefines it — DCE must keep it.
  let mul_body = @core.Module::{
    stmts: [
      @core.Stmt::Expr(
        expr=@core.Expr::Ident(name="x", span=@core.Span::empty(0)),
        span=@core.Span::empty(0),
      ),
    ],
  }
  let stmts : Array[@core.Stmt] = [
    @core.Stmt::Let(
      rec=false,
      name="mul",
      expr=@core.Expr::Fn(
        type_params=[],
        type_bounds={},
        params=[
          @core.FuncParam::{
            name: "x",
            label: @core.ParamLabel::Positional,
            ty: @core.Type::Int,
            bounds: [],
          },
        ],
        ret=Some(@core.Type::Int),
        effects=[],
        body=mul_body,
        span=@core.Span::empty(0),
      ),
      span=@core.Span::empty(0),
    ),
    @core.Stmt::Expr(
      expr=@core.Expr::Call(
        name="mul",
        type_args=[],
        args=[
          @core.CallArg::{
            label: None,
            expr: @core.Expr::Int(value=5L, span=@core.Span::empty(0)),
            span: @core.Span::empty(0),
          },
        ],
        span=@core.Span::empty(0),
      ),
      span=@core.Span::empty(0),
    ),
  ]
  let input = @core.Module::{ stmts, }
  let result = @pipeline.dce_module(input)
  let mut has_mul = false
  for stmt in result.stmts {
    match stmt {
      @core.Stmt::Let(name~, ..) => if name == "mul" { has_mul = true }
      _ => ()
    }
  }
  // Must keep user-defined "mul" even though it shadows a builtin
  inspect(has_mul, content="true")
  inspect(result.stmts.length(), content="2")
}

///|
test "dce: keeps user-defined and/or names" {
  let and_body = @core.Module::{
    stmts: [
      @core.Stmt::Expr(
        expr=@core.Expr::Ident(name="a", span=@core.Span::empty(0)),
        span=@core.Span::empty(0),
      ),
    ],
  }
  let use_body = @core.Module::{
    stmts: [
      @core.Stmt::Expr(
        expr=@core.Expr::Call(
          name="and",
          type_args=[],
          args=[
            @core.CallArg::{
              label: None,
              expr: @core.Expr::Ident(name="x", span=@core.Span::empty(0)),
              span: @core.Span::empty(0),
            },
            @core.CallArg::{
              label: None,
              expr: @core.Expr::Ident(name="x", span=@core.Span::empty(0)),
              span: @core.Span::empty(0),
            },
          ],
          span=@core.Span::empty(0),
        ),
        span=@core.Span::empty(0),
      ),
    ],
  }
  let stmts : Array[@core.Stmt] = [
    @core.Stmt::Let(
      rec=false,
      name="and",
      expr=@core.Expr::Fn(
        type_params=[],
        type_bounds={},
        params=[
          @core.FuncParam::{
            name: "a",
            label: @core.ParamLabel::Positional,
            ty: @core.Type::Int,
            bounds: [],
          },
          @core.FuncParam::{
            name: "b",
            label: @core.ParamLabel::Positional,
            ty: @core.Type::Int,
            bounds: [],
          },
        ],
        ret=Some(@core.Type::Int),
        effects=[],
        body=and_body,
        span=@core.Span::empty(0),
      ),
      span=@core.Span::empty(0),
    ),
    @core.Stmt::Let(
      rec=false,
      name="use",
      expr=@core.Expr::Fn(
        type_params=[],
        type_bounds={},
        params=[
          @core.FuncParam::{
            name: "x",
            label: @core.ParamLabel::Positional,
            ty: @core.Type::Int,
            bounds: [],
          },
        ],
        ret=Some(@core.Type::Int),
        effects=[],
        body=use_body,
        span=@core.Span::empty(0),
      ),
      span=@core.Span::empty(0),
    ),
    @core.Stmt::Expr(
      expr=@core.Expr::Call(
        name="use",
        type_args=[],
        args=[
          @core.CallArg::{
            label: None,
            expr: @core.Expr::Int(value=1L, span=@core.Span::empty(0)),
            span: @core.Span::empty(0),
          },
        ],
        span=@core.Span::empty(0),
      ),
      span=@core.Span::empty(0),
    ),
  ]
  let input = @core.Module::{ stmts, }
  let result = @pipeline.dce_module(input)
  let mut has_and = false
  for stmt in result.stmts {
    match stmt {
      @core.Stmt::Let(name~, ..) => if name == "and" { has_and = true }
      _ => ()
    }
  }
  inspect(has_and, content="true")
}

///|
test "dce: keeps enum definitions referenced only by match patterns" {
  let span = @core.Span::empty(0)
  let stmts : Array[@core.Stmt] = [
    @core.Stmt::EnumDef(
      name="Pat",
      params=[],
      ctors=[@core.TypeCtor::{ name: "PWild", args: [], span }],
      span~,
    ),
    @core.Stmt::ExportLet(
      rec=false,
      name="is_wild",
      expr=@core.Expr::Fn(
        type_params=[],
        type_bounds={},
        params=[
          @core.FuncParam::{
            name: "p",
            label: @core.ParamLabel::Positional,
            ty: @core.Type::Named(name="Pat", args=[]),
            bounds: [],
          },
        ],
        ret=Some(@core.Type::Bool),
        effects=[],
        body=@core.Module::{
          stmts: [
            @core.Stmt::Expr(
              expr=@core.Expr::Match(
                scrutinee=@core.Expr::Ident(name="p", span~),
                arms=[
                  @core.MatchArm::{
                    pat: @core.Pat::Ctor(name="PWild", args=[], span~),
                    cond: None,
                    expr: @core.Expr::Bool(value=true, span~),
                    span,
                  },
                ],
                span~,
              ),
              span~,
            ),
          ],
        },
        span~,
      ),
      span~,
    ),
  ]
  let input = @core.Module::{ stmts, }
  let result = @pipeline.dce_module(input)
  let mut has_pat_enum = false
  for stmt in result.stmts {
    match stmt {
      @core.Stmt::EnumDef(name~, ..) => if name == "Pat" { has_pat_enum = true }
      _ => ()
    }
  }
  inspect(has_pat_enum, content="true")
}
