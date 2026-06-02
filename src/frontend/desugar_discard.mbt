///|
/// Bind discarded statement-expression values to synthetic `let` bindings so
/// Perceus RC can reclaim owned heap temporaries that are never named.
///
/// A non-final `Stmt::Expr(e)` in a block evaluates `e` and discards its
/// value. When `e` produces a freshly owned heap object (e.g. a function call
/// returning a tuple, or a for-in used as a statement whose result array is
/// thrown away), nothing decrements its reference count and it leaks.
///
/// Rewriting `e` to `let __discardN = e` hands the value to a binding with
/// zero uses, so Perceus's existing scope-end drop reclaims it. Delegating to
/// Perceus's use counting keeps this correct for the borrow case too: a bare
/// `Stmt::Expr(x)` becomes `let __discardN = x`, which Perceus accounts for as
/// a move/borrow of `x` rather than a spurious extra drop.
///
/// Only the *non-final* statement of each block is rewritten; the final
/// statement is the block's value and must stay an expression. Runs on the RC
/// path only, before Perceus analysis (alongside the for-in / string-interp
/// desugars).
pub fn desugar_discarded_stmts(ast : @core.Module) -> @core.Module {
  let counter : Ref[Int] = Ref(0)
  dds_rewrite_module(ast, counter)
}

///|
fn dds_rewrite_module(m : @core.Module, counter : Ref[Int]) -> @core.Module {
  let n = m.stmts.length()
  let next : Array[@core.Stmt] = []
  for i = 0; i < n; i = i + 1 {
    let rewritten = dds_rewrite_stmt(m.stmts[i], counter)
    let is_last = i == n - 1
    if !is_last {
      match rewritten {
        // Divergent expressions never produce a reclaimable value and must
        // not be wrapped in a binding (it would put a `local.set` after the
        // control-transfer / be semantically wrong).
        @core.Stmt::Expr(expr=@core.Expr::Break(..), ..)
        | @core.Stmt::Expr(expr=@core.Expr::Continue(..), ..)
        | @core.Stmt::Expr(expr=@core.Expr::Return(..), ..)
        | @core.Stmt::Expr(expr=@core.Expr::Perform(..), ..) =>
          next.push(rewritten)
        @core.Stmt::Expr(expr~, span~) => {
          let name = "__discard" + counter.val.to_string()
          counter.val = counter.val + 1
          next.push(@core.Stmt::Let(rec=false, name~, expr~, span~))
        }
        _ => next.push(rewritten)
      }
    } else {
      next.push(rewritten)
    }
  }
  @core.Module::{ stmts: next }
}

///|
fn dds_rewrite_stmt(stmt : @core.Stmt, counter : Ref[Int]) -> @core.Stmt {
  match stmt {
    @core.Stmt::Let(rec~, name~, expr~, span~) =>
      @core.Stmt::Let(rec~, name~, expr=dds_rewrite_expr(expr, counter), span~)
    @core.Stmt::ExportLet(rec~, name~, expr~, span~) =>
      @core.Stmt::ExportLet(
        rec~,
        name~,
        expr=dds_rewrite_expr(expr, counter),
        span~,
      )
    @core.Stmt::InternalExportLet(rec~, name~, expr~, span~) =>
      @core.Stmt::InternalExportLet(
        rec~,
        name~,
        expr=dds_rewrite_expr(expr, counter),
        span~,
      )
    @core.Stmt::LetMut(name~, expr~, span~) =>
      @core.Stmt::LetMut(name~, expr=dds_rewrite_expr(expr, counter), span~)
    @core.Stmt::Assign(name~, expr~, span~) =>
      @core.Stmt::Assign(name~, expr=dds_rewrite_expr(expr, counter), span~)
    @core.Stmt::Expr(expr~, span~) =>
      @core.Stmt::Expr(expr=dds_rewrite_expr(expr, counter), span~)
    @core.Stmt::Test(name~, body~, span~) =>
      @core.Stmt::Test(name~, body=dds_rewrite_module(body, counter), span~)
    @core.Stmt::Bench(name~, body~, span~) =>
      @core.Stmt::Bench(name~, body=dds_rewrite_module(body, counter), span~)
    _ => stmt
  }
}

///|
fn dds_rewrite_expr(expr : @core.Expr, counter : Ref[Int]) -> @core.Expr {
  match expr {
    @core.Expr::Call(name~, type_args~, args~, span~) => {
      let next_args : Array[@core.CallArg] = []
      for arg in args {
        next_args.push(@core.CallArg::{
          label: arg.label,
          expr: dds_rewrite_expr(arg.expr, counter),
          span: arg.span,
        })
      }
      @core.Expr::Call(name~, type_args~, args=next_args, span~)
    }
    @core.Expr::If(cond~, then_body~, else_body~, span~) =>
      @core.Expr::If(
        cond=dds_rewrite_expr(cond, counter),
        then_body=dds_rewrite_module(then_body, counter),
        else_body=dds_rewrite_module(else_body, counter),
        span~,
      )
    @core.Expr::Match(scrutinee~, arms~, span~) => {
      let next_arms : Array[@core.MatchArm] = []
      for arm in arms {
        next_arms.push(@core.MatchArm::{
          pat: arm.pat,
          cond: match arm.cond {
            Some(g) => Some(dds_rewrite_expr(g, counter))
            None => None
          },
          expr: dds_rewrite_expr(arm.expr, counter),
          span: arm.span,
        })
      }
      @core.Expr::Match(
        scrutinee=dds_rewrite_expr(scrutinee, counter),
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
          expr: dds_rewrite_expr(arm.expr, counter),
          span: arm.span,
        })
      }
      @core.Expr::Handle(
        body=dds_rewrite_module(body, counter),
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
        body=dds_rewrite_module(body, counter),
        span~,
      )
    @core.Expr::Block(body~, span~) =>
      @core.Expr::Block(body=dds_rewrite_module(body, counter), span~)
    @core.Expr::While(cond~, body~, span~) =>
      @core.Expr::While(
        cond=dds_rewrite_expr(cond, counter),
        body=dds_rewrite_module(body, counter),
        span~,
      )
    @core.Expr::Tuple(items~, span~) => {
      let next : Array[@core.Expr] = []
      for e in items {
        next.push(dds_rewrite_expr(e, counter))
      }
      @core.Expr::Tuple(items=next, span~)
    }
    @core.Expr::Array(items~, span~) => {
      let next : Array[@core.Expr] = []
      for e in items {
        next.push(dds_rewrite_expr(e, counter))
      }
      @core.Expr::Array(items=next, span~)
    }
    _ => expr
  }
}
