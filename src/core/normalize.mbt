///| AST Normalization for content-addressable modules

///|

///| Alpha-normalization: rename variables to positional indices ($0, $1, ...)

///| Span stripping: remove source location info

///|
/// Normalized variable name prefix
let var_prefix : String = "$"

///|
/// Scope for alpha-normalization
priv struct NormScope {
  bindings : Map[String, String] // original name -> normalized name
  mut counter : Int
  parent : NormScope?
}

///|
fn NormScope::new() -> NormScope {
  NormScope::{ bindings: {}, counter: 0, parent: None }
}

///|
fn NormScope::child(self : NormScope) -> NormScope {
  // Function scopes reset counter, block scopes inherit
  NormScope::{ bindings: {}, counter: 0, parent: Some(self) }
}

///|
fn NormScope::child_block(self : NormScope) -> NormScope {
  // Block scopes inherit counter from parent
  NormScope::{ bindings: {}, counter: self.counter, parent: Some(self) }
}

///|
fn NormScope::bind(self : NormScope, name : String) -> String {
  let normalized = var_prefix + self.counter.to_string()
  self.counter += 1
  self.bindings[name] = normalized
  normalized
}

///|
fn NormScope::lookup(self : NormScope, name : String) -> String {
  match self.bindings.get(name) {
    Some(n) => n
    None =>
      match self.parent {
        Some(p) => p.lookup(name)
        None => name // Keep original if not bound (global/builtin)
      }
  }
}

///|
/// Normalize a module AST
pub fn normalize_module(m : Module) -> Module {
  let scope = NormScope::new()
  Module::{ stmts: normalize_stmts(m.stmts, scope) }
}

///|
fn normalize_stmts(stmts : Array[Stmt], scope : NormScope) -> Array[Stmt] {
  let out : Array[Stmt] = []
  for stmt in stmts {
    out.push(normalize_stmt(stmt, scope))
  }
  out
}

///|
fn normalize_stmt(stmt : Stmt, scope : NormScope) -> Stmt {
  let zero_span = Span::{ start: 0, end: 0 }
  match stmt {
    Stmt::Let(rec~, name~, expr~, ..) => {
      // For recursive, bind name first so it's visible in expr
      let norm_name = if rec { scope.bind(name) } else { name }
      let norm_expr = normalize_expr(expr, scope)
      // For non-recursive, bind after normalizing expr
      let final_name = if rec { norm_name } else { scope.bind(name) }
      Stmt::Let(rec~, name=final_name, expr=norm_expr, span=zero_span)
    }
    Stmt::LetMut(name~, expr~, ..) => {
      let norm_expr = normalize_expr(expr, scope)
      let norm_name = scope.bind(name)
      Stmt::LetMut(name=norm_name, expr=norm_expr, span=zero_span)
    }
    Stmt::LetPat(pat~, expr~, ..) => {
      let norm_expr = normalize_expr(expr, scope)
      let norm_pat = normalize_pat(pat, scope)
      Stmt::LetPat(pat=norm_pat, expr=norm_expr, span=zero_span)
    }
    Stmt::Assign(name~, expr~, ..) => {
      let norm_name = scope.lookup(name)
      let norm_expr = normalize_expr(expr, scope)
      Stmt::Assign(name=norm_name, expr=norm_expr, span=zero_span)
    }
    Stmt::Expr(expr~, ..) =>
      Stmt::Expr(expr=normalize_expr(expr, scope), span=zero_span)
    Stmt::Test(name~, body~, ..) => {
      let child = scope.child()
      Stmt::Test(name~, body=normalize_block(body, child), span=zero_span)
    }
    Stmt::EnumDef(name~, params~, ctors~, ..) =>
      Stmt::EnumDef(
        name~,
        params~,
        ctors=normalize_ctors(ctors),
        span=zero_span,
      )
    Stmt::TypeAlias(name~, params~, target~, ..) =>
      Stmt::TypeAlias(name~, params~, target~, span=zero_span)
    Stmt::Flake(raw~, ..) => Stmt::Flake(raw~, span=zero_span)
    Stmt::Alias(name~, target~, ..) =>
      Stmt::Alias(name~, target~, span=zero_span)
    Stmt::Import(spec~, source~, ..) =>
      Stmt::Import(spec~, source~, span=zero_span)
    Stmt::ExportLet(rec~, name~, expr~, ..) => {
      let norm_name = if rec { scope.bind(name) } else { name }
      let norm_expr = normalize_expr(expr, scope)
      let final_name = if rec { norm_name } else { scope.bind(name) }
      Stmt::ExportLet(rec~, name=final_name, expr=norm_expr, span=zero_span)
    }
    Stmt::ExportEnumDef(name~, params~, ctors~, ..) =>
      Stmt::ExportEnumDef(
        name~,
        params~,
        ctors=normalize_ctors(ctors),
        span=zero_span,
      )
    Stmt::ExportTypeAlias(name~, params~, target~, ..) =>
      Stmt::ExportTypeAlias(name~, params~, target~, span=zero_span)
    Stmt::Export(names~, ..) => Stmt::Export(names~, span=zero_span)
    Stmt::ReExport(names~, source~, ..) =>
      Stmt::ReExport(names~, source~, span=zero_span)
  }
}

///|
fn normalize_block(m : Module, scope : NormScope) -> Module {
  Module::{ stmts: normalize_stmts(m.stmts, scope) }
}

///|
fn normalize_ctors(ctors : Array[TypeCtor]) -> Array[TypeCtor] {
  let out : Array[TypeCtor] = []
  let zero_span = Span::{ start: 0, end: 0 }
  for ctor in ctors {
    out.push(TypeCtor::{ name: ctor.name, args: ctor.args, span: zero_span })
  }
  out
}

///|
fn normalize_expr(expr : Expr, scope : NormScope) -> Expr {
  let zero_span = Span::{ start: 0, end: 0 }
  match expr {
    Expr::Int(value~, ..) => Expr::Int(value~, span=zero_span)
    Expr::Float(value~, ..) => Expr::Float(value~, span=zero_span)
    Expr::Double(value~, ..) => Expr::Double(value~, span=zero_span)
    Expr::Bool(value~, ..) => Expr::Bool(value~, span=zero_span)
    Expr::String(value~, ..) => Expr::String(value~, span=zero_span)
    Expr::Ident(name~, ..) =>
      Expr::Ident(name=scope.lookup(name), span=zero_span)
    Expr::Placeholder(index~, ..) =>
      // Placeholder should be desugared before normalization
      Expr::Placeholder(index~, span=zero_span)
    Expr::Call(name~, type_args~, args~, ..) =>
      Expr::Call(
        name=scope.lookup(name),
        type_args~,
        args=normalize_call_args(args, scope),
        span=zero_span,
      )
    Expr::Fn(type_params~, params~, ret~, effects~, body~, ..) => {
      let child = scope.child()
      let norm_params = normalize_params(params, child)
      Expr::Fn(
        type_params~,
        params=norm_params,
        ret~,
        effects~,
        body=normalize_block(body, child),
        span=zero_span,
      )
    }
    Expr::If(cond~, then_body~, else_body~, ..) =>
      Expr::If(
        cond=normalize_expr(cond, scope),
        then_body=normalize_block(then_body, scope.child_block()),
        else_body=normalize_block(else_body, scope.child_block()),
        span=zero_span,
      )
    Expr::Match(scrutinee~, arms~, ..) =>
      Expr::Match(
        scrutinee=normalize_expr(scrutinee, scope),
        arms=normalize_arms(arms, scope),
        span=zero_span,
      )
    Expr::Block(body~, ..) =>
      Expr::Block(
        body=normalize_block(body, scope.child_block()),
        span=zero_span,
      )
    Expr::Tuple(items~, ..) =>
      Expr::Tuple(items=normalize_exprs(items, scope), span=zero_span)
    Expr::TupleIndex(expr~, index~, ..) =>
      Expr::TupleIndex(expr=normalize_expr(expr, scope), index~, span=zero_span)
    Expr::Array(items~, ..) =>
      Expr::Array(items=normalize_exprs(items, scope), span=zero_span)
    Expr::Record(fields~, ..) =>
      Expr::Record(
        fields=normalize_record_fields(fields, scope),
        span=zero_span,
      )
    Expr::Map(fields~, ..) =>
      Expr::Map(fields=normalize_map_fields(fields, scope), span=zero_span)
    Expr::Do(body~, ..) =>
      Expr::Do(body=normalize_block(body, scope.child_block()), span=zero_span)
    Expr::While(cond~, body~, ..) =>
      Expr::While(
        cond=normalize_expr(cond, scope),
        body=normalize_block(body, scope.child_block()),
        span=zero_span,
      )
    Expr::Try(try_body~, catch_body~, ..) =>
      Expr::Try(
        try_body=normalize_block(try_body, scope.child_block()),
        catch_body=normalize_block(catch_body, scope.child_block()),
        span=zero_span,
      )
    Expr::Raise(value~, ..) =>
      Expr::Raise(value=normalize_expr(value, scope), span=zero_span)
    Expr::Await(expr~, ..) =>
      Expr::Await(expr=normalize_expr(expr, scope), span=zero_span)
    Expr::Yield(expr~, ..) =>
      Expr::Yield(expr=normalize_expr(expr, scope), span=zero_span)
  }
}

///|
fn normalize_exprs(exprs : Array[Expr], scope : NormScope) -> Array[Expr] {
  let out : Array[Expr] = []
  for e in exprs {
    out.push(normalize_expr(e, scope))
  }
  out
}

///|
fn normalize_call_args(
  args : Array[CallArg],
  scope : NormScope,
) -> Array[CallArg] {
  let out : Array[CallArg] = []
  let zero_span = Span::{ start: 0, end: 0 }
  for arg in args {
    out.push(CallArg::{
      label: arg.label,
      expr: normalize_expr(arg.expr, scope),
      span: zero_span,
    })
  }
  out
}

///|
fn normalize_params(
  params : Array[FuncParam],
  scope : NormScope,
) -> Array[FuncParam] {
  let out : Array[FuncParam] = []
  for p in params {
    let norm_name = scope.bind(p.name)
    out.push(FuncParam::{ name: norm_name, label: p.label, ty: p.ty })
  }
  out
}

///|
fn normalize_arms(arms : Array[MatchArm], scope : NormScope) -> Array[MatchArm] {
  let out : Array[MatchArm] = []
  let zero_span = Span::{ start: 0, end: 0 }
  for arm in arms {
    let arm_scope = scope.child_block()
    let norm_pat = normalize_pat(arm.pat, arm_scope)
    let norm_cond = match arm.cond {
      Some(c) => Some(normalize_expr(c, arm_scope))
      None => None
    }
    out.push(MatchArm::{
      pat: norm_pat,
      cond: norm_cond,
      expr: normalize_expr(arm.expr, arm_scope),
      span: zero_span,
    })
  }
  out
}

///|
fn normalize_pat(pat : Pat, scope : NormScope) -> Pat {
  let zero_span = Span::{ start: 0, end: 0 }
  match pat {
    Pat::Wildcard(..) => Pat::Wildcard(span=zero_span)
    Pat::Bind(name~, ..) => Pat::Bind(name=scope.bind(name), span=zero_span)
    Pat::Ctor(name~, args~, ..) =>
      Pat::Ctor(name~, args=normalize_pats(args, scope), span=zero_span)
    Pat::Tuple(items~, ..) =>
      Pat::Tuple(items=normalize_pats(items, scope), span=zero_span)
    Pat::Record(fields~, ..) =>
      Pat::Record(
        fields=normalize_record_field_pats(fields, scope),
        span=zero_span,
      )
    Pat::Int(value~, ..) => Pat::Int(value~, span=zero_span)
    Pat::Float(value~, ..) => Pat::Float(value~, span=zero_span)
    Pat::Double(value~, ..) => Pat::Double(value~, span=zero_span)
    Pat::Bool(value~, ..) => Pat::Bool(value~, span=zero_span)
    Pat::String(value~, ..) => Pat::String(value~, span=zero_span)
    Pat::Or(pats~, ..) =>
      Pat::Or(pats=normalize_pats(pats, scope), span=zero_span)
  }
}

///|
fn normalize_pats(pats : Array[Pat], scope : NormScope) -> Array[Pat] {
  let out : Array[Pat] = []
  for p in pats {
    out.push(normalize_pat(p, scope))
  }
  out
}

///|
fn normalize_record_fields(
  fields : Array[RecordFieldExpr],
  scope : NormScope,
) -> Array[RecordFieldExpr] {
  let out : Array[RecordFieldExpr] = []
  let zero_span = Span::{ start: 0, end: 0 }
  for f in fields {
    out.push(RecordFieldExpr::{
      name: f.name,
      expr: normalize_expr(f.expr, scope),
      span: zero_span,
    })
  }
  out
}

///|
fn normalize_map_fields(
  fields : Array[MapFieldExpr],
  scope : NormScope,
) -> Array[MapFieldExpr] {
  let out : Array[MapFieldExpr] = []
  let zero_span = Span::{ start: 0, end: 0 }
  for f in fields {
    out.push(MapFieldExpr::{
      key: f.key,
      expr: normalize_expr(f.expr, scope),
      span: zero_span,
    })
  }
  out
}

///|
fn normalize_record_field_pats(
  fields : Array[RecordFieldPat],
  scope : NormScope,
) -> Array[RecordFieldPat] {
  let out : Array[RecordFieldPat] = []
  let zero_span = Span::{ start: 0, end: 0 }
  for f in fields {
    out.push(RecordFieldPat::{
      name: f.name,
      pat: normalize_pat(f.pat, scope),
      span: zero_span,
    })
  }
  out
}

///|
/// Result of normalizing a module with its imports
pub struct NormalizedBundle {
  main_hash : String
  modules : Map[String, Module] // hash -> normalized module
}

///|
/// Normalize a module with all imports resolved to hashes.
/// resolve_import: takes a path and returns the parsed AST.
/// Returns a bundle containing the main module and all dependencies.
pub fn normalize_with_imports(
  m : Module,
  resolve_import : (String) -> Module?,
) -> NormalizedBundle {
  let modules : Map[String, Module] = {}
  let path_to_hash : Map[String, String] = {}
  // First pass: collect and normalize all dependencies
  collect_and_normalize_imports(m, resolve_import, modules, path_to_hash)
  // Second pass: convert main module's imports to hash-based
  let converted = convert_imports_in_module(m, path_to_hash)
  let normalized = normalize_module(converted)
  let main_hash = hash_module(normalized)
  modules[main_hash] = normalized
  NormalizedBundle::{ main_hash, modules }
}

///|
/// Recursively collect and normalize all imported modules
fn collect_and_normalize_imports(
  m : Module,
  resolve_import : (String) -> Module?,
  modules : Map[String, Module],
  path_to_hash : Map[String, String],
) -> Unit {
  for stmt in m.stmts {
    match stmt {
      Stmt::Import(source~, ..) =>
        match source {
          ModuleRef::Path(path~) =>
            if not(path_to_hash.contains(path)) {
              match resolve_import(path) {
                Some(imported_ast) => {
                  // Recursively process imports of the imported module
                  collect_and_normalize_imports(
                    imported_ast, resolve_import, modules, path_to_hash,
                  )
                  // Convert imports in imported module and normalize
                  let converted = convert_imports_in_module(
                    imported_ast, path_to_hash,
                  )
                  let normalized = normalize_module(converted)
                  let hash = hash_module(normalized)
                  path_to_hash[path] = hash
                  modules[hash] = normalized
                }
                None => ()
              }
            }
          ModuleRef::Hash(_) => ()
        }
      _ => ()
    }
  }
}

///|
/// Convert path-based imports to hash-based imports in a module
fn convert_imports_in_module(
  m : Module,
  path_to_hash : Map[String, String],
) -> Module {
  convert_imports_to_hash(m, fn(path) { path_to_hash.get(path) })
}

///|
/// Extract import hashes from a module
pub fn collect_import_hashes(m : Module) -> Array[String] {
  let hashes : Array[String] = []
  for stmt in m.stmts {
    match stmt {
      Stmt::Import(source~, ..) =>
        match source {
          ModuleRef::Hash(hash~) => hashes.push(hash)
          ModuleRef::Path(_) => ()
        }
      _ => ()
    }
  }
  hashes
}

///|
/// Result of expanding a module with its dependencies
pub struct ExpandedBundle {
  main_hash : String
  modules : Map[String, Module] // hash -> module
  order : Array[String] // topological order (dependencies first)
}

///|
/// Expand a module from storage, loading dependencies up to specified depth.
/// load_module: takes a hash and returns the module if available.
/// depth: None for unlimited, Some(n) for maximum depth.
pub fn expand_module(
  main_hash : String,
  load_module : (String) -> Module?,
  depth : Int?,
) -> ExpandedBundle {
  let modules : Map[String, Module] = {}
  let order : Array[String] = []
  let visited : Map[String, Bool] = {}
  expand_recursive(main_hash, load_module, depth, 0, modules, order, visited)
  ExpandedBundle::{ main_hash, modules, order }
}

///|
fn expand_recursive(
  hash : String,
  load_module : (String) -> Module?,
  max_depth : Int?,
  current_depth : Int,
  modules : Map[String, Module],
  order : Array[String],
  visited : Map[String, Bool],
) -> Unit {
  // Check if already visited
  if visited.contains(hash) {
    return
  }
  visited[hash] = true
  // Check depth limit
  let within_depth = match max_depth {
    None => true
    Some(d) => current_depth < d
  }
  // Load the module
  let result = load_module(hash)
  match result {
    None => ()
    Some(m) => {
      modules[hash] = m
      // Recursively load dependencies (if within depth)
      if within_depth {
        let import_hashes = collect_import_hashes(m)
        for dep_hash in import_hashes {
          expand_recursive(
            dep_hash,
            load_module,
            max_depth,
            current_depth + 1,
            modules,
            order,
            visited,
          )
        }
      }
      // Add to order after dependencies (topological sort)
      order.push(hash)
    }
  }
}
