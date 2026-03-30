///|
/// Rewrite String operator calls to explicit builtin calls:
/// - `__add(a, b)` to `String::concat(a, b)` when operands are String typed.
/// - `__eq(a, b)` to `String::equals(a, b)` when operands are String typed.
pub fn rewrite_string_add(
  ast : @core.Module,
  expr_types : @core.ExprTypeIndex,
) -> @core.Module {
  rsa_rewrite_module(ast, expr_types)
}

///|
fn rsa_rewrite_module(
  m : @core.Module,
  expr_types : @core.ExprTypeIndex,
) -> @core.Module {
  let next : Array[@core.Stmt] = []
  for stmt in m.stmts {
    next.push(rsa_rewrite_stmt(stmt, expr_types))
  }
  @core.Module::{ stmts: next }
}

///|
fn rsa_rewrite_stmt(
  stmt : @core.Stmt,
  expr_types : @core.ExprTypeIndex,
) -> @core.Stmt {
  match stmt {
    @core.Stmt::Let(rec~, name~, expr~, span~) =>
      @core.Stmt::Let(
        rec~,
        name~,
        expr=rsa_rewrite_expr(expr, expr_types),
        span~,
      )
    @core.Stmt::ExportLet(rec~, name~, expr~, span~) =>
      @core.Stmt::ExportLet(
        rec~,
        name~,
        expr=rsa_rewrite_expr(expr, expr_types),
        span~,
      )
    @core.Stmt::InternalExportLet(rec~, name~, expr~, span~) =>
      @core.Stmt::InternalExportLet(
        rec~,
        name~,
        expr=rsa_rewrite_expr(expr, expr_types),
        span~,
      )
    @core.Stmt::LetMut(name~, expr~, span~) =>
      @core.Stmt::LetMut(name~, expr=rsa_rewrite_expr(expr, expr_types), span~)
    @core.Stmt::Expr(expr~, span~) =>
      @core.Stmt::Expr(expr=rsa_rewrite_expr(expr, expr_types), span~)
    @core.Stmt::Test(name~, body~, span~) =>
      @core.Stmt::Test(name~, body=rsa_rewrite_module(body, expr_types), span~)
    @core.Stmt::Bench(name~, body~, span~) =>
      @core.Stmt::Bench(name~, body=rsa_rewrite_module(body, expr_types), span~)
    _ => stmt
  }
}

///|
fn rsa_is_string_valued(
  expr : @core.Expr,
  expr_types : @core.ExprTypeIndex,
) -> Bool {
  match expr {
    @core.Expr::String(..) => true
    @core.Expr::Ident(..) =>
      match expr_types.get_expr_type(expr.span()) {
        Some(@core.Type::String) => true
        _ => false
      }
    @core.Expr::Call(name~, ..) =>
      match name {
        "String::concat"
        | "String::substring"
        | "String::trim"
        | "String::replace"
        | "String::replace_all"
        | "String::join"
        | "String::to_upper"
        | "String::to_lower"
        | "to_string"
        | "__to_string" => true
        _ =>
          match expr_types.get_expr_type(expr.span()) {
            Some(@core.Type::String) => true
            _ => false
          }
      }
    _ =>
      match expr_types.get_expr_type(expr.span()) {
        Some(@core.Type::String) => true
        _ => false
      }
  }
}

///|
fn rsa_rewrite_expr(
  expr : @core.Expr,
  expr_types : @core.ExprTypeIndex,
) -> @core.Expr {
  match expr {
    @core.Expr::Call(name~, type_args~, args~, span~) => {
      let next_args : Array[@core.CallArg] = []
      for arg in args {
        next_args.push(@core.CallArg::{
          label: arg.label,
          expr: rsa_rewrite_expr(arg.expr, expr_types),
          span: arg.span,
        })
      }
      let effective_name = if name == "__add" && next_args.length() == 2 {
        if rsa_is_string_valued(next_args[0].expr, expr_types) {
          "String::concat"
        } else {
          name
        }
      } else if name == "__eq" && next_args.length() == 2 {
        if rsa_is_string_valued(next_args[0].expr, expr_types) ||
          rsa_is_string_valued(next_args[1].expr, expr_types) {
          "String::equals"
        } else {
          name
        }
      } else {
        name
      }
      @core.Expr::Call(name=effective_name, type_args~, args=next_args, span~)
    }
    @core.Expr::If(cond~, then_body~, else_body~, span~) =>
      @core.Expr::If(
        cond=rsa_rewrite_expr(cond, expr_types),
        then_body=rsa_rewrite_module(then_body, expr_types),
        else_body=rsa_rewrite_module(else_body, expr_types),
        span~,
      )
    @core.Expr::Match(scrutinee~, arms~, span~) => {
      let next_arms : Array[@core.MatchArm] = []
      for arm in arms {
        next_arms.push(@core.MatchArm::{
          pat: arm.pat,
          cond: match arm.cond {
            Some(g) => Some(rsa_rewrite_expr(g, expr_types))
            None => None
          },
          expr: rsa_rewrite_expr(arm.expr, expr_types),
          span: arm.span,
        })
      }
      @core.Expr::Match(
        scrutinee=rsa_rewrite_expr(scrutinee, expr_types),
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
          expr: rsa_rewrite_expr(arm.expr, expr_types),
          span: arm.span,
        })
      }
      @core.Expr::Handle(
        body=rsa_rewrite_module(body, expr_types),
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
        body=rsa_rewrite_module(body, expr_types),
        span~,
      )
    @core.Expr::Block(body~, span~) =>
      @core.Expr::Block(body=rsa_rewrite_module(body, expr_types), span~)
    @core.Expr::While(cond~, body~, span~) =>
      @core.Expr::While(
        cond=rsa_rewrite_expr(cond, expr_types),
        body=rsa_rewrite_module(body, expr_types),
        span~,
      )
    @core.Expr::ForIn(value_name~, index_name~, iterable~, body~, span~) => {
      if rsa_is_string_valued(iterable, expr_types) {
        @core.mark_string_for_in(span.start)
      }
      @core.Expr::ForIn(
        value_name~,
        index_name~,
        iterable=rsa_rewrite_expr(iterable, expr_types),
        body=rsa_rewrite_module(body, expr_types),
        span~,
      )
    }
    _ => expr
  }
}
