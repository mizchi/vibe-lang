///|
priv struct WarningBinding {
  name : String
  span : @core.Span
  suppress : Bool
  exported : Bool
}

///|
priv struct WarningScope {
  bindings : Array[WarningBinding]
  name_index : Map[String, Array[Int]]
  used_ids : Map[Int, Bool]
}

///|
priv struct PatternBinding {
  name : String
  span : @core.Span
}

///|
fn warning_scope_new() -> WarningScope {
  { bindings: [], name_index: {}, used_ids: {} }
}

///|
fn warning_scope_declare(
  scopes : Array[WarningScope],
  name : String,
  span : @core.Span,
  exported : Bool,
) -> Unit {
  if scopes.length() == 0 {
    return
  }
  let idx = scopes.length() - 1
  let scope = scopes[idx]
  let binding_id = scope.bindings.length()
  scope.bindings.push({
    name,
    span,
    suppress: name.has_prefix("_"),
    exported,
  })
  match scope.name_index.get(name) {
    Some(ids) => {
      ids.push(binding_id)
      scope.name_index[name] = ids
    }
    None => scope.name_index[name] = [binding_id]
  }
  scopes[idx] = scope
}

///|
fn warning_scope_mark_use(scopes : Array[WarningScope], name : String) -> Unit {
  let mut i = scopes.length()
  while i > 0 {
    i -= 1
    let scope = scopes[i]
    match scope.name_index.get(name) {
      Some(ids) =>
        if ids.length() > 0 {
          let binding_id = ids[ids.length() - 1]
          scope.used_ids[binding_id] = true
          scopes[i] = scope
          return
        }
      None => ()
    }
  }
}

///|
fn warning_scope_pop(
  scopes : Array[WarningScope],
  out : Array[@core.Diagnostic],
) -> Unit {
  if scopes.length() == 0 {
    return
  }
  let scope = match scopes.pop() {
    Some(value) => value
    None => return
  }
  for i in 0..<scope.bindings.length() {
    if scope.used_ids.contains(i) {
      continue
    }
    let binding = scope.bindings[i]
    if binding.suppress || binding.exported {
      continue
    }
    out.push(@core.Diagnostic::{
      stage: "warning",
      message: "unused variable: " + binding.name,
      span: Some(binding.span),
      hint: Some("prefix with `_` if intentionally unused"),
      note: None,
    })
  }
}

///|
fn warning_collect_pattern_bindings(
  pat : @core.Pat,
  seen : Map[String, Bool],
  out : Array[PatternBinding],
) -> Unit {
  match pat {
    @core.Pat::Bind(name~, span~) =>
      if !seen.contains(name) {
        seen[name] = true
        out.push({ name, span })
      }
    @core.Pat::Ctor(args~, ..) =>
      for arg in args {
        warning_collect_pattern_bindings(arg, seen, out)
      }
    @core.Pat::Tuple(items~, ..) =>
      for item in items {
        warning_collect_pattern_bindings(item, seen, out)
      }
    @core.Pat::Record(fields~, ..) | @core.Pat::Struct(fields~, ..) =>
      for field in fields {
        warning_collect_pattern_bindings(field.pat, seen, out)
      }
    @core.Pat::Or(pats~, ..) =>
      for item in pats {
        warning_collect_pattern_bindings(item, seen, out)
      }
    @core.Pat::Wildcard(..)
    | @core.Pat::Int(..)
    | @core.Pat::Float(..)
    | @core.Pat::Double(..)
    | @core.Pat::Bool(..)
    | @core.Pat::String(..) => ()
  }
}

///|
fn declare_pattern_bindings(
  scopes : Array[WarningScope],
  pat : @core.Pat,
) -> Unit {
  let seen : Map[String, Bool] = {}
  let bindings : Array[PatternBinding] = []
  warning_collect_pattern_bindings(pat, seen, bindings)
  for binding in bindings {
    warning_scope_declare(scopes, binding.name, binding.span, false)
  }
}

///|
fn walk_module(
  module_ast : @core.Module,
  scopes : Array[WarningScope],
  out : Array[@core.Diagnostic],
) -> Unit {
  for stmt in module_ast.stmts {
    walk_stmt(stmt, scopes, out)
  }
}

///|
fn walk_stmt(
  stmt : @core.Stmt,
  scopes : Array[WarningScope],
  out : Array[@core.Diagnostic],
) -> Unit {
  match stmt {
    @core.Stmt::Let(rec~, name~, expr~, span~) => {
      if rec {
        warning_scope_declare(scopes, name, span, false)
      }
      walk_expr(expr, scopes, out)
      if !rec {
        warning_scope_declare(scopes, name, span, false)
      }
    }
    @core.Stmt::ExportLet(rec~, name~, expr~, span~) => {
      if rec {
        warning_scope_declare(scopes, name, span, true)
      }
      walk_expr(expr, scopes, out)
      if !rec {
        warning_scope_declare(scopes, name, span, true)
      }
    }
    @core.Stmt::LetMut(name~, expr~, span~) => {
      walk_expr(expr, scopes, out)
      warning_scope_declare(scopes, name, span, false)
    }
    @core.Stmt::Assign(name~, expr~, ..) => {
      walk_expr(expr, scopes, out)
      warning_scope_mark_use(scopes, name)
    }
    @core.Stmt::IndexAssign(target~, index~, value~, ..) => {
      walk_expr(target, scopes, out)
      walk_expr(index, scopes, out)
      walk_expr(value, scopes, out)
    }
    @core.Stmt::LetPat(pat~, expr~, ..) => {
      walk_expr(expr, scopes, out)
      declare_pattern_bindings(scopes, pat)
    }
    @core.Stmt::Expr(expr~, ..) => walk_expr(expr, scopes, out)
    @core.Stmt::Export(names~, ..) =>
      for name in names {
        warning_scope_mark_use(scopes, name)
      }
    @core.Stmt::Test(body~, ..) => {
      scopes.push(warning_scope_new())
      walk_module(body, scopes, out)
      warning_scope_pop(scopes, out)
    }
    @core.Stmt::Import(..)
    | @core.Stmt::EnumDef(..)
    | @core.Stmt::TypeAlias(..)
    | @core.Stmt::TraitDef(..)
    | @core.Stmt::TraitImpl(..)
    | @core.Stmt::ExportEnumDef(..)
    | @core.Stmt::ExportTypeAlias(..)
    | @core.Stmt::ReExport(..)
    | @core.Stmt::StructDef(..)
    | @core.Stmt::ExportStructDef(..) => ()
  }
}

///|
fn walk_expr(
  expr : @core.Expr,
  scopes : Array[WarningScope],
  out : Array[@core.Diagnostic],
) -> Unit {
  match expr {
    @core.Expr::Ident(name~, ..) => warning_scope_mark_use(scopes, name)
    @core.Expr::Call(name~, args~, ..) => {
      warning_scope_mark_use(scopes, name)
      for arg in args {
        walk_expr(arg.expr, scopes, out)
      }
    }
    @core.Expr::Tuple(items~, ..) =>
      for item in items {
        walk_expr(item, scopes, out)
      }
    @core.Expr::TupleIndex(expr~, ..) => walk_expr(expr, scopes, out)
    @core.Expr::Record(fields~, ..) =>
      for field in fields {
        walk_expr(field.expr, scopes, out)
      }
    @core.Expr::Array(items~, ..) =>
      for item in items {
        walk_expr(item, scopes, out)
      }
    @core.Expr::Map(fields~, ..) =>
      for field in fields {
        walk_expr(field.expr, scopes, out)
      }
    @core.Expr::If(cond~, then_body~, else_body~, ..) => {
      walk_expr(cond, scopes, out)
      scopes.push(warning_scope_new())
      walk_module(then_body, scopes, out)
      warning_scope_pop(scopes, out)
      scopes.push(warning_scope_new())
      walk_module(else_body, scopes, out)
      warning_scope_pop(scopes, out)
    }
    @core.Expr::Block(body~, ..) | @core.Expr::Do(body~, ..) => {
      scopes.push(warning_scope_new())
      walk_module(body, scopes, out)
      warning_scope_pop(scopes, out)
    }
    @core.Expr::Try(try_body~, catch_body~, ..) => {
      scopes.push(warning_scope_new())
      walk_module(try_body, scopes, out)
      warning_scope_pop(scopes, out)
      scopes.push(warning_scope_new())
      walk_module(catch_body, scopes, out)
      warning_scope_pop(scopes, out)
    }
    @core.Expr::Match(scrutinee~, arms~, ..) => {
      walk_expr(scrutinee, scopes, out)
      for arm in arms {
        scopes.push(warning_scope_new())
        declare_pattern_bindings(scopes, arm.pat)
        match arm.cond {
          Some(cond) => walk_expr(cond, scopes, out)
          None => ()
        }
        walk_expr(arm.expr, scopes, out)
        warning_scope_pop(scopes, out)
      }
    }
    @core.Expr::Fn(params~, body~, span~, ..) => {
      scopes.push(warning_scope_new())
      for param in params {
        warning_scope_declare(scopes, param.name, span, false)
      }
      walk_module(body, scopes, out)
      warning_scope_pop(scopes, out)
    }
    @core.Expr::While(cond~, body~, ..) => {
      walk_expr(cond, scopes, out)
      scopes.push(warning_scope_new())
      walk_module(body, scopes, out)
      warning_scope_pop(scopes, out)
    }
    @core.Expr::Raise(value~, ..)
    | @core.Expr::Await(expr=value, ..)
    | @core.Expr::Yield(expr=value, ..) => walk_expr(value, scopes, out)
    @core.Expr::StructLit(fields~, ..) =>
      for field in fields {
        walk_expr(field.expr, scopes, out)
      }
    @core.Expr::Int(..)
    | @core.Expr::Float(..)
    | @core.Expr::Double(..)
    | @core.Expr::Bool(..)
    | @core.Expr::String(..)
    | @core.Expr::Placeholder(..)
    | @core.Expr::Break(..)
    | @core.Expr::Continue(..) => ()
  }
}

///|
pub fn collect_warnings(ast : @core.Module) -> Array[@core.Diagnostic] {
  let scopes : Array[WarningScope] = [warning_scope_new()]
  let out : Array[@core.Diagnostic] = []
  walk_module(ast, scopes, out)
  warning_scope_pop(scopes, out)
  out
}
