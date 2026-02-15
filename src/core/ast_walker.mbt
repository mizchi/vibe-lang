///|
/// Generic AST reference walker.
/// Collects free variable references from expressions and blocks
/// with a pluggable `on_name` callback for filtering.

///|
/// Scope-chain for efficient scope management in AST walkers.
/// Creating a child scope is O(1) instead of O(N) map copying.
pub struct WalkerScope {
  bindings : Map[String, Bool]
  parent : WalkerScope?
}

///|
pub fn WalkerScope::new() -> WalkerScope {
  { bindings: {}, parent: None }
}

///|
pub fn WalkerScope::child(self : WalkerScope) -> WalkerScope {
  { bindings: {}, parent: Some(self) }
}

///|
pub fn WalkerScope::contains(self : WalkerScope, name : String) -> Bool {
  if self.bindings.contains(name) {
    true
  } else {
    match self.parent {
      Some(p) => p.contains(name)
      None => false
    }
  }
}

///|
/// Clone a `Map[String, Bool]` (shallow copy).
pub fn clone_bool_map(m : Map[String, Bool]) -> Map[String, Bool] {
  let out : Map[String, Bool] = {}
  for k, v in m {
    out[k] = v
  }
  out
}

///|
/// Bind all variable names introduced by a pattern into the `bound` map.
pub fn bind_pattern_names_walker(bound : Map[String, Bool], pat : Pat) -> Unit {
  match pat {
    Pat::Wildcard(..) => ()
    Pat::Bind(name~, span~) => {
      let _ = span
      bound[name] = true
    }
    Pat::Ctor(name~, args~, span~) => {
      let _ = name
      let _ = span
      for arg in args {
        bind_pattern_names_walker(bound, arg)
      }
    }
    Pat::Tuple(items~, span~) => {
      let _ = span
      for item in items {
        bind_pattern_names_walker(bound, item)
      }
    }
    Pat::Record(fields~, span~) => {
      let _ = span
      for field in fields {
        bind_pattern_names_walker(bound, field.pat)
      }
    }
    Pat::Struct(name~, fields~, span~) => {
      let _ = name
      let _ = span
      for field in fields {
        bind_pattern_names_walker(bound, field.pat)
      }
    }
    Pat::Int(..)
    | Pat::Float(..)
    | Pat::Double(..)
    | Pat::Bool(..)
    | Pat::Char(..)
    | Pat::String(..) => ()
    Pat::Or(pats~, span~) => {
      let _ = span
      for p in pats {
        bind_pattern_names_walker(bound, p)
      }
    }
  }
}

///|
/// Bind all variable names introduced by a pattern into a WalkerScope.
pub fn bind_pattern_names_scope(scope : WalkerScope, pat : Pat) -> Unit {
  bind_pattern_names_walker(scope.bindings, pat)
}

///|
/// Walk an expression, collecting free variable references via `on_name`.
pub fn walk_expr_refs(
  expr : Expr,
  bound : WalkerScope,
  refs : Map[String, Bool],
  on_name : (String, WalkerScope, Map[String, Bool]) -> Unit,
) -> Unit {
  match expr {
    Expr::Int(..)
    | Expr::Float(..)
    | Expr::Double(..)
    | Expr::Bool(..)
    | Expr::Char(..)
    | Expr::String(..)
    | Expr::Placeholder(..) => ()
    Expr::Ident(name~, span~) => {
      let _ = span
      on_name(name, bound, refs)
    }
    Expr::Call(name~, args~, span~, ..) => {
      let _ = span
      on_name(name, bound, refs)
      for arg in args {
        walk_expr_refs(arg.expr, bound, refs, on_name)
      }
    }
    Expr::Tuple(items~, span~) => {
      let _ = span
      for item in items {
        walk_expr_refs(item, bound, refs, on_name)
      }
    }
    Expr::TupleIndex(expr~, ..) => walk_expr_refs(expr, bound, refs, on_name)
    Expr::Record(fields~, span~) => {
      let _ = span
      for field in fields {
        walk_expr_refs(field.expr, bound, refs, on_name)
      }
    }
    Expr::StructLit(name~, type_args~, fields~, span~) => {
      let _ = span
      let _ = type_args
      on_name(name, bound, refs)
      for field in fields {
        walk_expr_refs(field.expr, bound, refs, on_name)
      }
    }
    Expr::Array(items~, span~) => {
      let _ = span
      for item in items {
        walk_expr_refs(item, bound, refs, on_name)
      }
    }
    Expr::Map(fields~, span~) => {
      let _ = span
      for field in fields {
        walk_expr_refs(field.expr, bound, refs, on_name)
      }
    }
    Expr::If(cond~, then_body~, else_body~, span~) => {
      let _ = span
      walk_expr_refs(cond, bound, refs, on_name)
      walk_block_refs(then_body, bound, refs, on_name)
      walk_block_refs(else_body, bound, refs, on_name)
    }
    Expr::Block(body~, span~) => {
      let _ = span
      walk_block_refs(body, bound, refs, on_name)
    }
    Expr::Do(body~, span~) => {
      let _ = span
      walk_block_refs(body, bound, refs, on_name)
    }
    Expr::Try(try_body~, catch_body~, span~) => {
      let _ = span
      walk_block_refs(try_body, bound, refs, on_name)
      walk_block_refs(catch_body, bound, refs, on_name)
    }
    Expr::Match(scrutinee~, arms~, span~) => {
      let _ = span
      walk_expr_refs(scrutinee, bound, refs, on_name)
      for arm in arms {
        let arm_bound = bound.child()
        bind_pattern_names_scope(arm_bound, arm.pat)
        match arm.cond {
          Some(cond) => walk_expr_refs(cond, arm_bound, refs, on_name)
          None => ()
        }
        walk_expr_refs(arm.expr, arm_bound, refs, on_name)
      }
    }
    Expr::Fn(params~, ret~, effects=_, body~, span~, ..) => {
      let _ = span
      let _ = ret
      let fn_bound = bound.child()
      for param in params {
        fn_bound.bindings[param.name] = true
      }
      walk_block_refs(body, fn_bound, refs, on_name)
    }
    Expr::While(cond~, body~, span~) => {
      let _ = span
      walk_expr_refs(cond, bound, refs, on_name)
      walk_block_refs(body, bound, refs, on_name)
    }
    Expr::Loop(params~, body~, span~) => {
      let _ = span
      let loop_bound = bound.child()
      for param in params {
        walk_expr_refs(param.init, bound, refs, on_name)
        loop_bound.bindings[param.name] = true
      }
      walk_block_refs(body, loop_bound, refs, on_name)
    }
    Expr::Break(value~, span~) => {
      let _ = span
      match value {
        Some(e) => walk_expr_refs(e, bound, refs, on_name)
        None => ()
      }
    }
    Expr::Continue(args~, span~) => {
      let _ = span
      for arg in args {
        walk_expr_refs(arg, bound, refs, on_name)
      }
    }
    Expr::Raise(value~, span~) => {
      let _ = span
      walk_expr_refs(value, bound, refs, on_name)
    }
    Expr::Await(expr~, span~) => {
      let _ = span
      walk_expr_refs(expr, bound, refs, on_name)
    }
    Expr::Yield(expr~, span~) => {
      let _ = span
      walk_expr_refs(expr, bound, refs, on_name)
    }
  }
}

///|
/// Walk a block (Module), collecting free variable references via `on_name`.
/// Type-level references (EnumDef, StructDef, TypeAlias fields) are NOT walked
/// here -- callers that need type refs should handle them separately.
pub fn walk_block_refs(
  body : Module,
  bound : WalkerScope,
  refs : Map[String, Bool],
  on_name : (String, WalkerScope, Map[String, Bool]) -> Unit,
) -> Unit {
  let scope = bound.child()
  for stmt in body.stmts {
    walk_stmt_refs(stmt, scope, refs, on_name)
  }
}

///|
/// Walk a single statement, mutating `scope` to add bound names and collecting
/// free variable references via `on_name`.
pub fn walk_stmt_refs(
  stmt : Stmt,
  scope : WalkerScope,
  refs : Map[String, Bool],
  on_name : (String, WalkerScope, Map[String, Bool]) -> Unit,
) -> Unit {
  match stmt {
    Stmt::Let(rec~, name~, expr~, span~)
    | Stmt::ExportLet(rec~, name~, expr~, span~) => {
      let _ = span
      if rec {
        scope.bindings[name] = true
      }
      walk_expr_refs(expr, scope, refs, on_name)
      if not(rec) {
        scope.bindings[name] = true
      }
    }
    Stmt::LetMut(name~, expr~, span~) => {
      let _ = span
      walk_expr_refs(expr, scope, refs, on_name)
      scope.bindings[name] = true
    }
    Stmt::Assign(name~, expr~, span~) => {
      let _ = span
      on_name(name, scope, refs)
      walk_expr_refs(expr, scope, refs, on_name)
    }
    Stmt::IndexAssign(target~, index~, value~, span~) => {
      let _ = span
      walk_expr_refs(target, scope, refs, on_name)
      walk_expr_refs(index, scope, refs, on_name)
      walk_expr_refs(value, scope, refs, on_name)
    }
    Stmt::LetPat(pat~, expr~, span~) => {
      let _ = span
      walk_expr_refs(expr, scope, refs, on_name)
      bind_pattern_names_scope(scope, pat)
    }
    Stmt::LetPatElse(pat~, expr~, else_body~, span~) => {
      let _ = span
      walk_expr_refs(expr, scope, refs, on_name)
      walk_block_refs(else_body, scope, refs, on_name)
      bind_pattern_names_scope(scope, pat)
    }
    Stmt::Expr(expr~, span~) => {
      let _ = span
      walk_expr_refs(expr, scope, refs, on_name)
    }
    Stmt::Test(body~, ..) | Stmt::Bench(body~, ..) =>
      walk_block_refs(body, scope, refs, on_name)
    Stmt::EnumDef(name~, ..)
    | Stmt::ExportEnumDef(name~, ..)
    | Stmt::TypeAlias(name~, ..)
    | Stmt::ExportTypeAlias(name~, ..)
    | Stmt::StructDef(name~, ..)
    | Stmt::ExportStructDef(name~, ..) => scope.bindings[name] = true
    Stmt::Import(..)
    | Stmt::TraitDef(..)
    | Stmt::TraitImpl(..)
    | Stmt::Export(..)
    | Stmt::ReExport(..) => ()
  }
}
