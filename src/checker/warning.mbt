///|
priv enum WarningBindingKind {
  Variable
  Import
  MutableVariable
}

///|
priv struct WarningBinding {
  name : String
  span : @core.Span
  kind : WarningBindingKind
  suppress : Bool
  exported : Bool
}

///|
priv struct WarningScope {
  bindings : Array[WarningBinding]
  name_index : Map[String, Array[Int]]
  used_ids : Map[Int, Bool]
  assigned_ids : Map[Int, Bool]
}

///|
priv struct PatternBinding {
  name : String
  span : @core.Span
}

///|
fn warning_scope_new() -> WarningScope {
  { bindings: [], name_index: {}, used_ids: {}, assigned_ids: {} }
}

///|
// context keywords (for, in, is, map, loop, derive) are now reserved keywords
// and rejected by the parser, so no checker warning is needed.
fn warn_context_keyword_binding(
  _name : String,
  _span : @core.Span,
  _out : Array[@core.Diagnostic],
) -> Unit {
  // no-op: reserved keywords cannot appear as bindings
}

///|
fn warning_scope_declare(
  scopes : Array[WarningScope],
  name : String,
  span : @core.Span,
  exported : Bool,
  kind : WarningBindingKind,
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
    kind,
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
fn warning_scope_mark_assign(
  scopes : Array[WarningScope],
  name : String,
) -> Unit {
  let mut i = scopes.length()
  while i > 0 {
    i -= 1
    let scope = scopes[i]
    match scope.name_index.get(name) {
      Some(ids) =>
        if ids.length() > 0 {
          let binding_id = ids[ids.length() - 1]
          scope.assigned_ids[binding_id] = true
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
    let binding = scope.bindings[i]
    if binding.suppress || binding.exported {
      continue
    }
    if !scope.used_ids.contains(i) {
      let (message, hint) = match binding.kind {
        WarningBindingKind::Import =>
          (
            "unused import: " + binding.name,
            Some("remove import or use it in expression"),
          )
        _ =>
          (
            "unused variable: " + binding.name,
            Some("prefix with `_` if intentionally unused"),
          )
      }
      out.push(@core.Diagnostic::{
        stage: "warning",
        message,
        span: Some(binding.span),
        hint,
        note: None,
      })
      continue
    }
    match binding.kind {
      WarningBindingKind::MutableVariable =>
        if !scope.assigned_ids.contains(i) {
          out.push(@core.Diagnostic::{
            stage: "warning",
            message: "unnecessary `mut` binding: " + binding.name,
            span: Some(binding.span),
            hint: Some("use `let` instead of `let mut`"),
            note: None,
          })
        }
      _ => ()
    }
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
    | @core.Pat::Char(..)
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
    warning_scope_declare(
      scopes,
      binding.name,
      binding.span,
      false,
      WarningBindingKind::Variable,
    )
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
      warn_context_keyword_binding(name, span, out)
      if rec {
        warning_scope_declare(
          scopes,
          name,
          span,
          false,
          WarningBindingKind::Variable,
        )
      }
      walk_expr(expr, scopes, out)
      if !rec {
        warning_scope_declare(
          scopes,
          name,
          span,
          false,
          WarningBindingKind::Variable,
        )
      }
    }
    @core.Stmt::ExportLet(rec~, name~, expr~, span~) => {
      warn_context_keyword_binding(name, span, out)
      if rec {
        warning_scope_declare(
          scopes,
          name,
          span,
          true,
          WarningBindingKind::Variable,
        )
      }
      walk_expr(expr, scopes, out)
      if !rec {
        warning_scope_declare(
          scopes,
          name,
          span,
          true,
          WarningBindingKind::Variable,
        )
      }
    }
    @core.Stmt::InternalExportLet(rec~, name~, expr~, span~) => {
      warn_context_keyword_binding(name, span, out)
      if rec {
        warning_scope_declare(
          scopes,
          name,
          span,
          true,
          WarningBindingKind::Variable,
        )
      }
      walk_expr(expr, scopes, out)
      if !rec {
        warning_scope_declare(
          scopes,
          name,
          span,
          true,
          WarningBindingKind::Variable,
        )
      }
    }
    @core.Stmt::LetMut(name~, expr~, span~) => {
      warn_context_keyword_binding(name, span, out)
      walk_expr(expr, scopes, out)
      warning_scope_declare(
        scopes,
        name,
        span,
        false,
        WarningBindingKind::MutableVariable,
      )
    }
    @core.Stmt::Assign(name~, expr~, ..) => {
      walk_expr(expr, scopes, out)
      warning_scope_mark_assign(scopes, name)
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
    @core.Stmt::LetPatElse(pat~, expr~, else_body~, ..) => {
      walk_expr(expr, scopes, out)
      declare_pattern_bindings(scopes, pat)
      scopes.push(warning_scope_new())
      walk_module(else_body, scopes, out)
      warning_scope_pop(scopes, out)
    }
    @core.Stmt::Expr(expr~, ..) => walk_expr(expr, scopes, out)
    @core.Stmt::Import(spec~, span~, ..) =>
      for item in spec.items {
        let local_name = match item.rename {
          Some(rename) => rename
          None => item.name
        }
        warning_scope_declare(
          scopes,
          local_name,
          span,
          false,
          WarningBindingKind::Import,
        )
        if item.kind != @core.ImportKind::Value {
          // Type/trait imports are consumed in type space; avoid false positives.
          warning_scope_mark_use(scopes, local_name)
        }
      }
    @core.Stmt::ExternLet(name~, ty~, span~) => {
      let _ = ty
      warning_scope_declare(
        scopes,
        name,
        span,
        false,
        WarningBindingKind::Import,
      )
    }
    @core.Stmt::Export(names~, ..) =>
      for name in names {
        warning_scope_mark_use(scopes, name)
      }
    @core.Stmt::Test(body~, ..) => {
      scopes.push(warning_scope_new())
      walk_module(body, scopes, out)
      warning_scope_pop(scopes, out)
    }
    @core.Stmt::Bench(body~, ..) => {
      scopes.push(warning_scope_new())
      walk_module(body, scopes, out)
      warning_scope_pop(scopes, out)
    }
    @core.Stmt::EnumDef(..)
    | @core.Stmt::TypeAlias(..)
    | @core.Stmt::TraitDef(..)
    | @core.Stmt::InternalTraitDef(..)
    | @core.Stmt::TraitImpl(..)
    | @core.Stmt::ExportEnumDef(..)
    | @core.Stmt::InternalExportEnumDef(..)
    | @core.Stmt::ExportTypeAlias(..)
    | @core.Stmt::InternalExportTypeAlias(..)
    | @core.Stmt::ReExport(..)
    | @core.Stmt::AliasDecl(..)
    | @core.Stmt::StructDef(..)
    | @core.Stmt::ExportStructDef(..)
    | @core.Stmt::InternalExportStructDef(..)
    | @core.Stmt::EffectDef(..)
    | @core.Stmt::ExportEffectDef(..) => ()
  }
}

///|
fn is_eq_on_ident(cond : @core.Expr) -> String? {
  match cond {
    @core.Expr::Call(name~, args~, ..) => {
      let fn_name = name
      if (fn_name == "__eq" || fn_name == "eq") && args.length() == 2 {
        match args[0].expr {
          @core.Expr::Ident(name~, ..) => Some(name)
          _ =>
            match args[1].expr {
              @core.Expr::Ident(name~, ..) => Some(name)
              _ => None
            }
        }
      } else {
        None
      }
    }
    _ => None
  }
}

///|
fn get_chain_next(else_body : @core.Module, target : String) -> @core.Expr? {
  if else_body.stmts.length() == 1 {
    match else_body.stmts[0] {
      @core.Stmt::Expr(expr~, ..) =>
        match expr {
          @core.Expr::If(cond~, ..) =>
            match is_eq_on_ident(cond) {
              Some(name) => if name == target { Some(expr) } else { None }
              None => None
            }
          _ => None
        }
      _ => None
    }
  } else {
    None
  }
}

///|
fn count_eq_chain(expr : @core.Expr, target : String) -> Int {
  match expr {
    @core.Expr::If(cond~, else_body~, ..) =>
      match is_eq_on_ident(cond) {
        Some(name) =>
          if name == target {
            match get_chain_next(else_body, target) {
              Some(next_if) => 1 + count_eq_chain(next_if, target)
              None => 1
            }
          } else {
            0
          }
        None => 0
      }
    _ => 0
  }
}

///|
fn walk_eq_chain(
  expr : @core.Expr,
  target : String,
  scopes : Array[WarningScope],
  out : Array[@core.Diagnostic],
) -> Unit {
  match expr {
    @core.Expr::If(cond~, then_body~, else_body~, ..) => {
      walk_expr(cond, scopes, out)
      scopes.push(warning_scope_new())
      walk_module(then_body, scopes, out)
      warning_scope_pop(scopes, out)
      match get_chain_next(else_body, target) {
        Some(next_if) => walk_eq_chain(next_if, target, scopes, out)
        None => {
          scopes.push(warning_scope_new())
          walk_module(else_body, scopes, out)
          warning_scope_pop(scopes, out)
        }
      }
    }
    _ => walk_expr(expr, scopes, out)
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
    @core.Expr::If(cond~, then_body~, else_body~, span~) => {
      let chain_handled : Bool = match is_eq_on_ident(cond) {
        Some(target) => {
          let depth = count_eq_chain(expr, target)
          if depth >= 3 {
            out.push(@core.Diagnostic::{
              stage: "warning",
              message: "if-else chain on `" +
              target +
              "` with " +
              depth.to_string() +
              " branches can be rewritten as match",
              span: Some(span),
              hint: Some(
                "use `match " +
                target +
                " { ... }` instead of chained `==` comparisons",
              ),
              note: None,
            })
            walk_eq_chain(expr, target, scopes, out)
            true
          } else {
            false
          }
        }
        None => false
      }
      if !chain_handled {
        walk_expr(cond, scopes, out)
        scopes.push(warning_scope_new())
        walk_module(then_body, scopes, out)
        warning_scope_pop(scopes, out)
        scopes.push(warning_scope_new())
        walk_module(else_body, scopes, out)
        warning_scope_pop(scopes, out)
      }
    }
    @core.Expr::ForIn(value_name~, index_name~, iterable~, body~, span~) => {
      let desugared = if @core.is_string_for_in(span.start) {
        @core.desugar_for_in_string(
          value_name, index_name, iterable, body, span,
        )
      } else {
        @core.desugar_for_in(value_name, index_name, iterable, body, span)
      }
      scopes.push(warning_scope_new())
      walk_module(desugared, scopes, out)
      warning_scope_pop(scopes, out)
    }
    @core.Expr::Block(body~, ..) => {
      scopes.push(warning_scope_new())
      walk_module(body, scopes, out)
      warning_scope_pop(scopes, out)
    }
    @core.Expr::Handle(body~, arms~, ..) => {
      scopes.push(warning_scope_new())
      walk_module(body, scopes, out)
      warning_scope_pop(scopes, out)
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
    @core.Expr::Match(scrutinee~, arms~, ..) => {
      walk_expr(scrutinee, scopes, out)
      let mut catchall_seen = false
      for arm in arms {
        if catchall_seen {
          out.push(@core.Diagnostic::{
            stage: "warning",
            message: "unreachable match arm",
            span: Some(arm.pat.span()),
            hint: Some(
              "this arm will never be matched because a previous arm catches all patterns",
            ),
            note: None,
          })
        }
        scopes.push(warning_scope_new())
        declare_pattern_bindings(scopes, arm.pat)
        match arm.cond {
          Some(cond) => walk_expr(cond, scopes, out)
          None => ()
        }
        walk_expr(arm.expr, scopes, out)
        warning_scope_pop(scopes, out)
        if not(catchall_seen) && arm.cond is None {
          match arm.pat {
            @core.Pat::Wildcard(..) | @core.Pat::Bind(..) =>
              catchall_seen = true
            _ => ()
          }
        }
      }
    }
    @core.Expr::Fn(params~, body~, span~, ..) => {
      scopes.push(warning_scope_new())
      for param in params {
        warning_scope_declare(
          scopes,
          param.name,
          span,
          false,
          WarningBindingKind::Variable,
        )
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
    @core.Expr::Loop(params~, body~, ..) => {
      for param in params {
        walk_expr(param.init, scopes, out)
      }
      scopes.push(warning_scope_new())
      walk_module(body, scopes, out)
      warning_scope_pop(scopes, out)
    }
    @core.Expr::Yield(expr=value, ..) => walk_expr(value, scopes, out)
    @core.Expr::StructLit(fields~, ..) =>
      for field in fields {
        walk_expr(field.expr, scopes, out)
      }
    @core.Expr::Break(value~, ..) =>
      match value {
        Some(expr) => walk_expr(expr, scopes, out)
        None => ()
      }
    @core.Expr::Continue(args~, ..) =>
      for arg in args {
        walk_expr(arg, scopes, out)
      }
    @core.Expr::Spread(expr~, ..) => walk_expr(expr, scopes, out)
    @core.Expr::Perform(args~, ..) =>
      for arg in args {
        walk_expr(arg.expr, scopes, out)
      }
    @core.Expr::Int(..)
    | @core.Expr::Float(..)
    | @core.Expr::Double(..)
    | @core.Expr::Bool(..)
    | @core.Expr::Char(..)
    | @core.Expr::String(..)
    | @core.Expr::Placeholder(..) => ()
    // StringInterp is lowered in desugar; should never reach here
    @core.Expr::StringInterp(parts~, ..) =>
      for part in parts {
        match part {
          @core.StringInterpPart::Expr(e) => walk_expr(e, scopes, out)
          @core.StringInterpPart::Lit(_) => ()
        }
      }
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
