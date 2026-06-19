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
    @core.Stmt::Assign(name~, expr~, span~) =>
      @core.Stmt::Assign(name~, expr=rsa_rewrite_expr(expr, expr_types), span~)
    @core.Stmt::IndexAssign(target~, index~, value~, span~) =>
      @core.Stmt::IndexAssign(
        target=rsa_rewrite_expr(target, expr_types),
        index=rsa_rewrite_expr(index, expr_types),
        value=rsa_rewrite_expr(value, expr_types),
        span~,
      )
    @core.Stmt::LetPat(pat~, expr~, span~) =>
      @core.Stmt::LetPat(pat~, expr=rsa_rewrite_expr(expr, expr_types), span~)
    @core.Stmt::LetPatElse(pat~, expr~, else_body~, span~) =>
      @core.Stmt::LetPatElse(
        pat~,
        expr=rsa_rewrite_expr(expr, expr_types),
        else_body=rsa_rewrite_module(else_body, expr_types),
        span~,
      )
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

///|
/// Whether `expr` is a 0-arg pull closure returning `Option[_]` (the iterable of
/// a lazy `for await x in pull { .. }`). Marked so codegen drains it via the
/// pull desugar instead of indexing.
fn rsa_is_pull_valued(
  expr : @core.Expr,
  expr_types : @core.ExprTypeIndex,
) -> Bool {
  match expr_types.get_expr_type(expr.span()) {
    Some(@core.Type::Func(params~, ret~, ..)) =>
      params.length() == 0 &&
      (match ret {
        @core.Type::Named(name="Option", ..) => true
        _ => false
      })
    _ => false
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
      if rsa_is_pull_valued(iterable, expr_types) {
        @core.mark_pull_for_in(span.start)
      } else if rsa_is_string_valued(iterable, expr_types) {
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
    @core.Expr::Loop(params~, body~, span~) => {
      let next_params : Array[@core.LoopParam] = []
      for p in params {
        next_params.push(@core.LoopParam::{
          name: p.name,
          init: rsa_rewrite_expr(p.init, expr_types),
          span: p.span,
        })
      }
      @core.Expr::Loop(
        params=next_params,
        body=rsa_rewrite_module(body, expr_types),
        span~,
      )
    }
    @core.Expr::Break(value~, span~) =>
      @core.Expr::Break(
        value=match value {
          Some(v) => Some(rsa_rewrite_expr(v, expr_types))
          None => None
        },
        span~,
      )
    @core.Expr::Continue(args~, span~) => {
      let next_args : Array[@core.Expr] = []
      for a in args {
        next_args.push(rsa_rewrite_expr(a, expr_types))
      }
      @core.Expr::Continue(args=next_args, span~)
    }
    @core.Expr::Return(value~, span~) =>
      @core.Expr::Return(
        value=match value {
          Some(v) => Some(rsa_rewrite_expr(v, expr_types))
          None => None
        },
        span~,
      )
    @core.Expr::Yield(expr~, span~) =>
      @core.Expr::Yield(expr=rsa_rewrite_expr(expr, expr_types), span~)
    @core.Expr::Tuple(items~, span~) => {
      let next_items : Array[@core.Expr] = []
      for it in items {
        next_items.push(rsa_rewrite_expr(it, expr_types))
      }
      @core.Expr::Tuple(items=next_items, span~)
    }
    @core.Expr::TupleIndex(expr~, index~, span~) =>
      @core.Expr::TupleIndex(
        expr=rsa_rewrite_expr(expr, expr_types),
        index~,
        span~,
      )
    @core.Expr::Array(items~, span~) => {
      let next_items : Array[@core.Expr] = []
      for it in items {
        next_items.push(rsa_rewrite_expr(it, expr_types))
      }
      @core.Expr::Array(items=next_items, span~)
    }
    @core.Expr::Record(fields~, span~) => {
      let next_fields : Array[@core.RecordFieldExpr] = []
      for f in fields {
        next_fields.push(@core.RecordFieldExpr::{
          name: f.name,
          expr: rsa_rewrite_expr(f.expr, expr_types),
          span: f.span,
        })
      }
      @core.Expr::Record(fields=next_fields, span~)
    }
    @core.Expr::Map(fields~, span~) => {
      let next_fields : Array[@core.MapFieldExpr] = []
      for f in fields {
        next_fields.push(@core.MapFieldExpr::{
          key: f.key,
          expr: rsa_rewrite_expr(f.expr, expr_types),
          span: f.span,
        })
      }
      @core.Expr::Map(fields=next_fields, span~)
    }
    @core.Expr::StructLit(name~, type_args~, fields~, span~) => {
      let next_fields : Array[@core.RecordFieldExpr] = []
      for f in fields {
        next_fields.push(@core.RecordFieldExpr::{
          name: f.name,
          expr: rsa_rewrite_expr(f.expr, expr_types),
          span: f.span,
        })
      }
      @core.Expr::StructLit(name~, type_args~, fields=next_fields, span~)
    }
    @core.Expr::Spread(expr~, span~) =>
      @core.Expr::Spread(expr=rsa_rewrite_expr(expr, expr_types), span~)
    @core.Expr::StringInterp(parts~, span~) => {
      let next_parts : Array[@core.StringInterpPart] = []
      for p in parts {
        match p {
          @core.StringInterpPart::Lit(_) => next_parts.push(p)
          @core.StringInterpPart::Expr(e) =>
            next_parts.push(
              @core.StringInterpPart::Expr(rsa_rewrite_expr(e, expr_types)),
            )
        }
      }
      @core.Expr::StringInterp(parts=next_parts, span~)
    }
    @core.Expr::Perform(effect_name~, op_name~, args~, span~) => {
      let next_args : Array[@core.CallArg] = []
      for a in args {
        next_args.push(@core.CallArg::{
          label: a.label,
          expr: rsa_rewrite_expr(a.expr, expr_types),
          span: a.span,
        })
      }
      @core.Expr::Perform(effect_name~, op_name~, args=next_args, span~)
    }
    _ => expr
  }
}
