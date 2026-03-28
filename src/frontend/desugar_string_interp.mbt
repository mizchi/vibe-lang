///|
/// Desugar StringInterp nodes into Block expressions with let-bindings
/// so that Perceus can track intermediate String::concat results.
///
/// Example: "\{a} and \{b}"
/// → { let __si_0 = __to_string(a)
///     let __si_1 = String::concat(__si_0, " and ")
///     let __si_2 = String::concat(__si_1, __to_string(b))
///     __si_2 }
pub fn desugar_string_interp(ast : @core.Module) -> @core.Module {
  let counter : Ref[Int] = Ref::new(0)
  dsi_rewrite_module(ast, counter)
}

///|
fn dsi_rewrite_module(m : @core.Module, counter : Ref[Int]) -> @core.Module {
  let next : Array[@core.Stmt] = []
  for stmt in m.stmts {
    next.push(dsi_rewrite_stmt(stmt, counter))
  }
  @core.Module::{ stmts: next }
}

///|
fn dsi_rewrite_stmt(stmt : @core.Stmt, counter : Ref[Int]) -> @core.Stmt {
  match stmt {
    @core.Stmt::Let(rec~, name~, expr~, span~) =>
      @core.Stmt::Let(rec~, name~, expr=dsi_rewrite_expr(expr, counter), span~)
    @core.Stmt::ExportLet(rec~, name~, expr~, span~) =>
      @core.Stmt::ExportLet(
        rec~,
        name~,
        expr=dsi_rewrite_expr(expr, counter),
        span~,
      )
    @core.Stmt::InternalExportLet(rec~, name~, expr~, span~) =>
      @core.Stmt::InternalExportLet(
        rec~,
        name~,
        expr=dsi_rewrite_expr(expr, counter),
        span~,
      )
    @core.Stmt::LetMut(name~, expr~, span~) =>
      @core.Stmt::LetMut(name~, expr=dsi_rewrite_expr(expr, counter), span~)
    @core.Stmt::Expr(expr~, span~) =>
      @core.Stmt::Expr(expr=dsi_rewrite_expr(expr, counter), span~)
    @core.Stmt::Test(name~, body~, span~) =>
      @core.Stmt::Test(name~, body=dsi_rewrite_module(body, counter), span~)
    @core.Stmt::Bench(name~, body~, span~) =>
      @core.Stmt::Bench(name~, body=dsi_rewrite_module(body, counter), span~)
    _ => stmt
  }
}

///|
fn dsi_rewrite_expr(expr : @core.Expr, counter : Ref[Int]) -> @core.Expr {
  match expr {
    @core.Expr::StringInterp(parts~, span~) =>
      dsi_lower_interp(parts, span, counter)
    @core.Expr::Call(name~, type_args~, args~, span~) => {
      let next_args : Array[@core.CallArg] = []
      for arg in args {
        next_args.push(@core.CallArg::{
          label: arg.label,
          expr: dsi_rewrite_expr(arg.expr, counter),
          span: arg.span,
        })
      }
      @core.Expr::Call(name~, type_args~, args=next_args, span~)
    }
    @core.Expr::If(cond~, then_body~, else_body~, span~) =>
      @core.Expr::If(
        cond=dsi_rewrite_expr(cond, counter),
        then_body=dsi_rewrite_module(then_body, counter),
        else_body=dsi_rewrite_module(else_body, counter),
        span~,
      )
    @core.Expr::Match(scrutinee~, arms~, span~) => {
      let next_arms : Array[@core.MatchArm] = []
      for arm in arms {
        next_arms.push(@core.MatchArm::{
          pat: arm.pat,
          cond: match arm.cond {
            Some(g) => Some(dsi_rewrite_expr(g, counter))
            None => None
          },
          expr: dsi_rewrite_expr(arm.expr, counter),
          span: arm.span,
        })
      }
      @core.Expr::Match(
        scrutinee=dsi_rewrite_expr(scrutinee, counter),
        arms=next_arms,
        span~,
      )
    }
    @core.Expr::Handle(body~, arms~, span~) => {
      let next_arms : Array[@core.MatchArm] = []
      for arm in arms {
        next_arms.push(@core.MatchArm::{
          pat: arm.pat,
          cond: arm.cond,
          expr: dsi_rewrite_expr(arm.expr, counter),
          span: arm.span,
        })
      }
      @core.Expr::Handle(
        body=dsi_rewrite_module(body, counter),
        arms=next_arms,
        span~,
      )
    }
    @core.Expr::Fn(
      type_params~,
      type_bounds~,
      params~,
      ret~,
      effects~,
      body~,
      span~
    ) =>
      @core.Expr::Fn(
        type_params~,
        type_bounds~,
        params~,
        ret~,
        effects~,
        body=dsi_rewrite_module(body, counter),
        span~,
      )
    @core.Expr::Block(body~, span~) =>
      @core.Expr::Block(body=dsi_rewrite_module(body, counter), span~)
    @core.Expr::While(cond~, body~, span~) =>
      @core.Expr::While(
        cond=dsi_rewrite_expr(cond, counter),
        body=dsi_rewrite_module(body, counter),
        span~,
      )
    @core.Expr::ForIn(value_name~, index_name~, iterable~, body~, span~) =>
      @core.Expr::ForIn(
        value_name~,
        index_name~,
        iterable=dsi_rewrite_expr(iterable, counter),
        body=dsi_rewrite_module(body, counter),
        span~,
      )
    @core.Expr::Tuple(items~, span~) => {
      let next : Array[@core.Expr] = []
      for e in items {
        next.push(dsi_rewrite_expr(e, counter))
      }
      @core.Expr::Tuple(items=next, span~)
    }
    @core.Expr::Array(items~, span~) => {
      let next : Array[@core.Expr] = []
      for e in items {
        next.push(dsi_rewrite_expr(e, counter))
      }
      @core.Expr::Array(items=next, span~)
    }
    _ => expr
  }
}

///|
/// Lower a StringInterp into a Block with let-bindings for intermediate concats.
fn dsi_lower_interp(
  parts : Array[@core.StringInterpPart],
  span : @core.Span,
  counter : Ref[Int],
) -> @core.Expr {
  // Build the list of sub-expressions (Lit → String literal, Expr → __to_string(e))
  let exprs : Array[@core.Expr] = []
  for part in parts {
    match part {
      @core.StringInterpPart::Lit(s) =>
        exprs.push(@core.Expr::String(value=s, span~))
      @core.StringInterpPart::Expr(e) =>
        exprs.push(
          @core.Expr::Call(
            name="__to_string",
            type_args=[],
            args=[
              @core.CallArg::{
                label: None,
                expr: dsi_rewrite_expr(e, counter),
                span,
              },
            ],
            span~,
          ),
        )
    }
  }
  if exprs.length() == 0 {
    return @core.Expr::String(value="", span~)
  }
  if exprs.length() == 1 {
    return exprs[0]
  }
  // Build Block with let-bindings for each intermediate
  let stmts : Array[@core.Stmt] = []
  let first_name = "__si_" + counter.val.to_string()
  counter.val = counter.val + 1
  stmts.push(@core.Stmt::Let(rec=false, name=first_name, expr=exprs[0], span~))
  let mut prev_name = first_name
  for j in 1..<exprs.length() {
    let next_name = "__si_" + counter.val.to_string()
    counter.val = counter.val + 1
    let concat_expr = @core.Expr::Call(
      name="String::concat",
      type_args=[],
      args=[
        @core.CallArg::{
          label: None,
          expr: @core.Expr::Ident(name=prev_name, span~),
          span,
        },
        @core.CallArg::{ label: None, expr: exprs[j], span },
      ],
      span~,
    )
    stmts.push(
      @core.Stmt::Let(rec=false, name=next_name, expr=concat_expr, span~),
    )
    prev_name = next_name
  }
  // Final expression: reference to the last temp
  stmts.push(
    @core.Stmt::Expr(expr=@core.Expr::Ident(name=prev_name, span~), span~),
  )
  @core.Expr::Block(body=@core.Module::{ stmts, }, span~)
}
