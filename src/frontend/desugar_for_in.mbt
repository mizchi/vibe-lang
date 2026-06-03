///|
/// Desugar `ForIn` nodes into their `Block`/`While` form *before* Perceus RC
/// analysis, so the analysis and the codegen observe the same lowered shape.
///
/// The linear codegen normally desugars `for-in` lazily at emit time
/// (`compile_expr`'s `ForIn` case). On the RC path that is too late: Perceus
/// runs on the original `ForIn` AST and emits drop sites under
/// `...for_in.body...`, but codegen compiles the desugared `while`/`Block`,
/// so the two site spaces never line up and the loop body's per-iteration
/// drops are lost (the same class of leak fixed for plain `while` in A-1).
///
/// Running this pass up front makes `for-in` indistinguishable from a
/// hand-written `while` for both passes, so the A-1 while-body drop wiring
/// covers `for-in` too. This mirrors `desugar_string_interp`, which runs
/// before Perceus for the same reason.
///
/// The String-vs-generic dispatch uses the same `is_string_for_in` registry
/// the codegen consults, so the lowered form matches byte-for-byte.
pub fn desugar_for_in_module(ast : @core.Module) -> @core.Module {
  dfi_rewrite_module(ast)
}

///|
fn dfi_rewrite_module(m : @core.Module) -> @core.Module {
  let next : Array[@core.Stmt] = []
  for stmt in m.stmts {
    next.push(dfi_rewrite_stmt(stmt))
  }
  @core.Module::{ stmts: next }
}

///|
fn dfi_rewrite_stmt(stmt : @core.Stmt) -> @core.Stmt {
  match stmt {
    @core.Stmt::Let(rec~, name~, expr~, span~) =>
      @core.Stmt::Let(rec~, name~, expr=dfi_rewrite_expr(expr), span~)
    @core.Stmt::ExportLet(rec~, name~, expr~, span~) =>
      @core.Stmt::ExportLet(rec~, name~, expr=dfi_rewrite_expr(expr), span~)
    @core.Stmt::InternalExportLet(rec~, name~, expr~, span~) =>
      @core.Stmt::InternalExportLet(
        rec~,
        name~,
        expr=dfi_rewrite_expr(expr),
        span~,
      )
    @core.Stmt::LetMut(name~, expr~, span~) =>
      @core.Stmt::LetMut(name~, expr=dfi_rewrite_expr(expr), span~)
    @core.Stmt::Assign(name~, expr~, span~) =>
      @core.Stmt::Assign(name~, expr=dfi_rewrite_expr(expr), span~)
    @core.Stmt::Expr(expr~, span~) =>
      @core.Stmt::Expr(expr=dfi_rewrite_expr(expr), span~)
    @core.Stmt::Test(name~, body~, span~) =>
      @core.Stmt::Test(name~, body=dfi_rewrite_module(body), span~)
    @core.Stmt::Bench(name~, body~, span~) =>
      @core.Stmt::Bench(name~, body=dfi_rewrite_module(body), span~)
    _ => stmt
  }
}

///|
fn dfi_rewrite_expr(expr : @core.Expr) -> @core.Expr {
  match expr {
    @core.Expr::ForIn(value_name~, index_name~, iterable~, body~, span~) => {
      // Rewrite nested for-ins (and other constructs) inside the iterable and
      // body first, then lower this for-in. The lowered body is a Module; we
      // wrap it in a Block expression so it slots in as a single expr.
      let iterable = dfi_rewrite_expr(iterable)
      let body = dfi_rewrite_module(body)
      let lowered = if @core.is_string_for_in(span.start) {
        @core.desugar_for_in_string(
          value_name, index_name, iterable, body, span,
        )
      } else {
        @core.desugar_for_in(value_name, index_name, iterable, body, span)
      }
      @core.Expr::Block(body=lowered, span~)
    }
    @core.Expr::Call(name~, type_args~, args~, span~) => {
      let next_args : Array[@core.CallArg] = []
      for arg in args {
        next_args.push(@core.CallArg::{
          label: arg.label,
          expr: dfi_rewrite_expr(arg.expr),
          span: arg.span,
        })
      }
      @core.Expr::Call(name~, type_args~, args=next_args, span~)
    }
    @core.Expr::If(cond~, then_body~, else_body~, span~) =>
      @core.Expr::If(
        cond=dfi_rewrite_expr(cond),
        then_body=dfi_rewrite_module(then_body),
        else_body=dfi_rewrite_module(else_body),
        span~,
      )
    @core.Expr::Match(scrutinee~, arms~, span~) => {
      let next_arms : Array[@core.MatchArm] = []
      for arm in arms {
        next_arms.push(@core.MatchArm::{
          pat: arm.pat,
          cond: match arm.cond {
            Some(g) => Some(dfi_rewrite_expr(g))
            None => None
          },
          expr: dfi_rewrite_expr(arm.expr),
          span: arm.span,
        })
      }
      @core.Expr::Match(
        scrutinee=dfi_rewrite_expr(scrutinee),
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
          expr: dfi_rewrite_expr(arm.expr),
          span: arm.span,
        })
      }
      @core.Expr::Handle(body=dfi_rewrite_module(body), arms=next_arms, span~)
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
        body=dfi_rewrite_module(body),
        span~,
      )
    @core.Expr::Block(body~, span~) =>
      @core.Expr::Block(body=dfi_rewrite_module(body), span~)
    @core.Expr::While(cond~, body~, span~) =>
      @core.Expr::While(
        cond=dfi_rewrite_expr(cond),
        body=dfi_rewrite_module(body),
        span~,
      )
    @core.Expr::Tuple(items~, span~) => {
      let next : Array[@core.Expr] = []
      for e in items {
        next.push(dfi_rewrite_expr(e))
      }
      @core.Expr::Tuple(items=next, span~)
    }
    @core.Expr::Array(items~, span~) => {
      let next : Array[@core.Expr] = []
      for e in items {
        next.push(dfi_rewrite_expr(e))
      }
      @core.Expr::Array(items=next, span~)
    }
    _ => expr
  }
}
