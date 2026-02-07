///|
/// Tests for Dead Code Elimination
test "dce: keeps used definitions" {
  let stmts : Array[@core.Stmt] = [
    @core.Stmt::Let(
      rec=false,
      name="x",
      expr=@core.Expr::Int(value=1, span=@core.Span::empty(0)),
      span=@core.Span::empty(0),
    ),
    @core.Stmt::Expr(
      expr=@core.Expr::Ident(name="x", span=@core.Span::empty(0)),
      span=@core.Span::empty(0),
    ),
  ]
  let input = @core.Module::{ stmts, }
  let result = dce_module(input)
  // Both statements should be kept: x is used
  inspect(result.stmts.length(), content="2")
}

///|
test "dce: removes unused definitions" {
  let stmts : Array[@core.Stmt] = [
    @core.Stmt::Let(
      rec=false,
      name="unused",
      expr=@core.Expr::Int(value=1, span=@core.Span::empty(0)),
      span=@core.Span::empty(0),
    ),
    @core.Stmt::Let(
      rec=false,
      name="used",
      expr=@core.Expr::Int(value=2, span=@core.Span::empty(0)),
      span=@core.Span::empty(0),
    ),
    @core.Stmt::Expr(
      expr=@core.Expr::Ident(name="used", span=@core.Span::empty(0)),
      span=@core.Span::empty(0),
    ),
  ]
  let input = @core.Module::{ stmts, }
  let result = dce_module(input)
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
      expr=@core.Expr::Int(value=1, span=@core.Span::empty(0)),
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
  let result = dce_module(input)
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
      expr=@core.Expr::Int(value=1, span=@core.Span::empty(0)),
      span=@core.Span::empty(0),
    ),
  ]
  let input = @core.Module::{ stmts, }
  let result = dce_module(input)
  // Should keep the let statement since it's the last one
  inspect(result.stmts.length(), content="1")
}

///|
test "dce: keeps exports" {
  let stmts : Array[@core.Stmt] = [
    @core.Stmt::Let(
      rec=false,
      name="unused",
      expr=@core.Expr::Int(value=1, span=@core.Span::empty(0)),
      span=@core.Span::empty(0),
    ),
    @core.Stmt::ExportLet(
      rec=false,
      name="exported",
      expr=@core.Expr::Int(value=2, span=@core.Span::empty(0)),
      span=@core.Span::empty(0),
    ),
  ]
  let input = @core.Module::{ stmts, }
  let result = dce_module(input)
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
      expr=@core.Expr::Int(value=1, span=@core.Span::empty(0)),
      span=@core.Span::empty(0),
    ),
    @core.Stmt::Let(
      rec=false,
      name="unused2",
      expr=@core.Expr::Int(value=2, span=@core.Span::empty(0)),
      span=@core.Span::empty(0),
    ),
    @core.Stmt::Let(
      rec=false,
      name="unused3",
      expr=@core.Expr::Int(value=3, span=@core.Span::empty(0)),
      span=@core.Span::empty(0),
    ),
    @core.Stmt::ExportLet(
      rec=false,
      name="used",
      expr=@core.Expr::Int(value=4, span=@core.Span::empty(0)),
      span=@core.Span::empty(0),
    ),
  ]
  let input = @core.Module::{ stmts, }
  let result = dce_module(input)
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
            expr: @core.Expr::Int(value=1, span=@core.Span::empty(0)),
            span: @core.Span::empty(0),
          },
        ],
        span=@core.Span::empty(0),
      ),
      span=@core.Span::empty(0),
    ),
  ]
  let input = @core.Module::{ stmts, }
  let result = dce_module(input)
  // All 3 should be kept: helper <- main <- expr
  inspect(result.stmts.length(), content="3")
}
