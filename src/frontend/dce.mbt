///|
/// Dead Code Elimination for xsh WASM bundling
/// Uses backward reachability analysis from entry points

///|
/// Apply DCE to a bundled module, keeping only reachable definitions.
pub fn dce_module(mod : @core.Module) -> @core.Module {
  dce_module_with_entry_names_impl(mod, [], include_tests=false)
}

///|
/// Apply DCE with additional entry names (e.g. names from `export { ... }`).
pub fn dce_module_with_entry_names(
  mod : @core.Module,
  extra_entries : Array[String],
) -> @core.Module {
  dce_module_with_entry_names_impl(mod, extra_entries, include_tests=false)
}

///|
/// Apply DCE including references from top-level `test {}` blocks.
pub fn dce_module_for_tests(mod : @core.Module) -> @core.Module {
  dce_module_with_entry_names_impl(mod, [], include_tests=true)
}

///|
fn dce_module_with_entry_names_impl(
  mod : @core.Module,
  extra_entries : Array[String],
  include_tests~ : Bool,
) -> @core.Module {
  let graph = build_dep_graph(mod.stmts)
  let entries = collect_entry_points(mod.stmts, include_tests~)
  for name in extra_entries {
    entries[name] = true
  }
  let reachable = compute_reachable(entries, graph)
  let filtered = filter_reachable_stmts(mod.stmts, reachable)
  @core.Module::{ stmts: filtered }
}

///|
/// Build dependency graph: definition name -> set of referenced names
fn build_dep_graph(stmts : Array[@core.Stmt]) -> Map[String, Map[String, Bool]] {
  let graph : Map[String, Map[String, Bool]] = {}
  for stmt in stmts {
    let (name, refs) = collect_stmt_info(stmt)
    match name {
      Some(n) =>
        match graph.get(n) {
          Some(existing) => {
            let merged = clone_bool_map(existing)
            for ref_name, _ in refs {
              merged[ref_name] = true
            }
            graph[n] = merged
          }
          None => graph[n] = refs
        }
      None => ()
    }
  }
  graph
}

///|
/// Extract definition name and its references from a statement
fn collect_stmt_info(stmt : @core.Stmt) -> (String?, Map[String, Bool]) {
  let refs : Map[String, Bool] = {}
  let bound : Map[String, Bool] = {}
  match stmt {
    @core.Stmt::Let(rec~, name~, expr~, span~) => {
      let _ = span
      if rec {
        bound[name] = true
      }
      collect_refs_expr(expr, bound, refs)
      (Some(name), refs)
    }
    @core.Stmt::ExportLet(rec~, name~, expr~, span~) => {
      let _ = span
      if rec {
        bound[name] = true
      }
      collect_refs_expr(expr, bound, refs)
      (Some(name), refs)
    }
    @core.Stmt::EnumDef(name~, params~, ctors~, span~) => {
      let _ = params
      let _ = span
      // Enum constructors reference the enum type
      for ctor in ctors {
        for arg in ctor.args {
          collect_refs_type(arg, refs)
        }
      }
      (Some(name), refs)
    }
    @core.Stmt::ExportEnumDef(name~, params~, ctors~, span~) => {
      let _ = params
      let _ = span
      for ctor in ctors {
        for arg in ctor.args {
          collect_refs_type(arg, refs)
        }
      }
      (Some(name), refs)
    }
    @core.Stmt::TypeAlias(name~, params~, target~, span~) => {
      let _ = params
      let _ = span
      collect_refs_type(target, refs)
      (Some(name), refs)
    }
    @core.Stmt::ExportTypeAlias(name~, params~, target~, span~) => {
      let _ = params
      let _ = span
      collect_refs_type(target, refs)
      (Some(name), refs)
    }
    @core.Stmt::LetMut(name~, expr~, span~) => {
      let _ = span
      collect_refs_expr(expr, bound, refs)
      (Some(name), refs)
    }
    @core.Stmt::StructDef(name~, params~, fields~, span~) => {
      let _ = params
      let _ = span
      for field in fields {
        collect_refs_type(field.ty, refs)
      }
      (Some(name), refs)
    }
    @core.Stmt::ExportStructDef(name~, params~, fields~, span~) => {
      let _ = params
      let _ = span
      for field in fields {
        collect_refs_type(field.ty, refs)
      }
      (Some(name), refs)
    }
    // Non-definition statements
    @core.Stmt::Expr(..)
    | @core.Stmt::Import(..)
    | @core.Stmt::Test(..)
    | @core.Stmt::TraitDef(..)
    | @core.Stmt::TraitImpl(..)
    | @core.Stmt::Assign(..)
    | @core.Stmt::IndexAssign(..)
    | @core.Stmt::LetPat(..)
    | @core.Stmt::Export(..)
    | @core.Stmt::ReExport(..) => (None, refs)
  }
}

///|
/// Collect entry points: exports + references from top-level expressions + last stmt
/// Note: We don't track bound names here because we want ALL references
/// from top-level expressions to be considered entry points.
fn collect_entry_points(
  stmts : Array[@core.Stmt],
  include_tests~ : Bool,
) -> Map[String, Bool] {
  let entries : Map[String, Bool] = {}
  let empty_bound : Map[String, Bool] = {}
  let len = stmts.length()
  for i, stmt in stmts {
    let is_last = i == len - 1
    match stmt {
      // Exported definitions are entry points
      @core.Stmt::ExportLet(name~, ..) => entries[name] = true
      @core.Stmt::ExportEnumDef(name~, ..) => entries[name] = true
      @core.Stmt::ExportTypeAlias(name~, ..) => entries[name] = true
      // Top-level expressions are entry points (side effects)
      // Collect ALL references - they will be resolved via dependency graph
      @core.Stmt::Expr(expr~, span~) => {
        let _ = span
        collect_refs_expr(expr, empty_bound, entries)
      }
      // Assignments are entry points (side effects)
      @core.Stmt::Assign(name~, expr~, span~) => {
        let _ = span
        entries[name] = true
        collect_refs_expr(expr, empty_bound, entries)
      }
      @core.Stmt::IndexAssign(target~, index~, value~, span~) => {
        let _ = span
        collect_refs_expr(target, empty_bound, entries)
        collect_refs_expr(index, empty_bound, entries)
        collect_refs_expr(value, empty_bound, entries)
      }
      // Let patterns with side effects - collect refs from expr
      @core.Stmt::LetPat(pat~, expr~, span~) => {
        let _ = pat
        let _ = span
        collect_refs_expr(expr, empty_bound, entries)
      }
      // Last let binding is an entry point (its value is returned by 'run')
      @core.Stmt::Let(name~, ..) => if is_last { entries[name] = true }
      @core.Stmt::LetMut(name~, ..) => if is_last { entries[name] = true }
      @core.Stmt::Test(name~, body~, span~) => {
        let _ = name
        let _ = span
        if include_tests {
          collect_refs_block(body, empty_bound, entries)
        }
      }
      @core.Stmt::EnumDef(..)
      | @core.Stmt::TypeAlias(..)
      | @core.Stmt::StructDef(..)
      | @core.Stmt::Import(..)
      | @core.Stmt::TraitDef(..)
      | @core.Stmt::TraitImpl(..)
      | @core.Stmt::Export(..)
      | @core.Stmt::ReExport(..) => ()
      @core.Stmt::ExportStructDef(name~, ..) => entries[name] = true
    }
  }
  entries
}

///|
/// BFS to compute all reachable definitions from entry points
fn compute_reachable(
  entries : Map[String, Bool],
  graph : Map[String, Map[String, Bool]],
) -> Map[String, Bool] {
  let reachable : Map[String, Bool] = {}
  let queue : Array[String] = []
  // Initialize with entry points
  for name, _ in entries {
    if not(reachable.contains(name)) {
      reachable[name] = true
      queue.push(name)
    }
  }
  // BFS traversal
  while queue.length() > 0 {
    let current = queue.pop()
    match current {
      Some(name) =>
        match graph.get(name) {
          Some(deps) =>
            for dep, _ in deps {
              if not(reachable.contains(dep)) {
                reachable[dep] = true
                queue.push(dep)
              }
            }
          None => ()
        }
      None => ()
    }
  }
  reachable
}

///|
/// Filter statements to keep only reachable definitions
fn filter_reachable_stmts(
  stmts : Array[@core.Stmt],
  reachable : Map[String, Bool],
) -> Array[@core.Stmt] {
  let out : Array[@core.Stmt] = []
  for stmt in stmts {
    match stmt {
      @core.Stmt::Let(name~, ..) =>
        if reachable.contains(name) {
          out.push(stmt)
        }
      @core.Stmt::ExportLet(name~, ..) =>
        if reachable.contains(name) {
          out.push(stmt)
        }
      @core.Stmt::EnumDef(name~, params~, ctors~, span~) => {
        let _ = params
        let _ = span
        // Keep if type name is reachable OR any constructor is reachable
        let mut keep = reachable.contains(name)
        if not(keep) {
          for ctor in ctors {
            if reachable.contains(ctor.name) {
              keep = true
              break
            }
          }
        }
        if keep {
          out.push(stmt)
        }
      }
      @core.Stmt::ExportEnumDef(name~, params~, ctors~, span~) => {
        let _ = params
        let _ = span
        // Keep if type name is reachable OR any constructor is reachable
        let mut keep = reachable.contains(name)
        if not(keep) {
          for ctor in ctors {
            if reachable.contains(ctor.name) {
              keep = true
              break
            }
          }
        }
        if keep {
          out.push(stmt)
        }
      }
      @core.Stmt::TypeAlias(name~, ..) =>
        if reachable.contains(name) {
          out.push(stmt)
        }
      @core.Stmt::ExportTypeAlias(name~, ..) =>
        if reachable.contains(name) {
          out.push(stmt)
        }
      @core.Stmt::LetMut(name~, ..) =>
        if reachable.contains(name) {
          out.push(stmt)
        }
      @core.Stmt::StructDef(name~, ..) =>
        if reachable.contains(name) {
          out.push(stmt)
        }
      @core.Stmt::ExportStructDef(name~, ..) =>
        if reachable.contains(name) {
          out.push(stmt)
        }
      // Non-definition statements are always kept
      @core.Stmt::Expr(..)
      | @core.Stmt::Import(..)
      | @core.Stmt::Test(..)
      | @core.Stmt::TraitDef(..)
      | @core.Stmt::TraitImpl(..)
      | @core.Stmt::Assign(..)
      | @core.Stmt::IndexAssign(..)
      | @core.Stmt::LetPat(..)
      | @core.Stmt::Export(..)
      | @core.Stmt::ReExport(..) => out.push(stmt)
    }
  }
  out
}

///|
/// Collect references from an expression (adapted from test_runner.mbt)
fn collect_refs_expr(
  expr : @core.Expr,
  bound : Map[String, Bool],
  refs : Map[String, Bool],
) -> Unit {
  match expr {
    @core.Expr::Int(..)
    | @core.Expr::Float(..)
    | @core.Expr::Double(..)
    | @core.Expr::Bool(..)
    | @core.Expr::String(..)
    | @core.Expr::Placeholder(..) => ()
    @core.Expr::Ident(name~, span~) => {
      let _ = span
      add_ref_name(name, bound, refs)
    }
    @core.Expr::Call(name~, args~, span~, ..) => {
      let _ = span
      add_ref_name(name, bound, refs)
      for arg in args {
        collect_refs_expr(arg.expr, bound, refs)
      }
    }
    @core.Expr::Tuple(items~, span~) => {
      let _ = span
      for item in items {
        collect_refs_expr(item, bound, refs)
      }
    }
    @core.Expr::TupleIndex(expr~, ..) => collect_refs_expr(expr, bound, refs)
    @core.Expr::Record(fields~, span~) => {
      let _ = span
      for field in fields {
        collect_refs_expr(field.expr, bound, refs)
      }
    }
    @core.Expr::StructLit(name~, type_args~, fields~, span~) => {
      let _ = span
      let _ = type_args
      add_ref_name(name, bound, refs)
      for field in fields {
        collect_refs_expr(field.expr, bound, refs)
      }
    }
    @core.Expr::Array(items~, span~) => {
      let _ = span
      for item in items {
        collect_refs_expr(item, bound, refs)
      }
    }
    @core.Expr::Map(fields~, span~) => {
      let _ = span
      for field in fields {
        collect_refs_expr(field.expr, bound, refs)
      }
    }
    @core.Expr::If(cond~, then_body~, else_body~, span~) => {
      let _ = span
      collect_refs_expr(cond, bound, refs)
      collect_refs_block(then_body, bound, refs)
      collect_refs_block(else_body, bound, refs)
    }
    @core.Expr::Block(body~, span~) => {
      let _ = span
      collect_refs_block(body, bound, refs)
    }
    @core.Expr::Do(body~, span~) => {
      let _ = span
      collect_refs_block(body, bound, refs)
    }
    @core.Expr::Try(try_body~, catch_body~, span~) => {
      let _ = span
      collect_refs_block(try_body, bound, refs)
      collect_refs_block(catch_body, bound, refs)
    }
    @core.Expr::Match(scrutinee~, arms~, span~) => {
      let _ = span
      collect_refs_expr(scrutinee, bound, refs)
      for arm in arms {
        let arm_bound = clone_bool_map(bound)
        bind_pattern_names(arm_bound, arm.pat)
        match arm.cond {
          Some(cond) => collect_refs_expr(cond, arm_bound, refs)
          None => ()
        }
        collect_refs_expr(arm.expr, arm_bound, refs)
      }
    }
    @core.Expr::Fn(params~, ret~, effects=_, body~, span~, ..) => {
      let _ = span
      let _ = ret
      let fn_bound = clone_bool_map(bound)
      for param in params {
        fn_bound[param.name] = true
      }
      collect_refs_block(body, fn_bound, refs)
    }
    @core.Expr::While(cond~, body~, span~) => {
      let _ = span
      collect_refs_expr(cond, bound, refs)
      collect_refs_block(body, bound, refs)
    }
    @core.Expr::Break(span~) => {
      let _ = span
    }
    @core.Expr::Continue(span~) => {
      let _ = span
    }
    @core.Expr::Raise(value~, span~) => {
      let _ = span
      collect_refs_expr(value, bound, refs)
    }
    @core.Expr::Await(expr~, span~) => {
      let _ = span
      collect_refs_expr(expr, bound, refs)
    }
    @core.Expr::Yield(expr~, span~) => {
      let _ = span
      collect_refs_expr(expr, bound, refs)
    }
  }
}

///|
/// Collect references from a block
fn collect_refs_block(
  body : @core.Module,
  bound : Map[String, Bool],
  refs : Map[String, Bool],
) -> Unit {
  let scope = clone_bool_map(bound)
  for stmt in body.stmts {
    match stmt {
      @core.Stmt::Let(rec~, name~, expr~, span~) => {
        let _ = span
        if rec {
          scope[name] = true
        }
        collect_refs_expr(expr, scope, refs)
        if not(rec) {
          scope[name] = true
        }
      }
      @core.Stmt::ExportLet(rec~, name~, expr~, span~) => {
        let _ = span
        if rec {
          scope[name] = true
        }
        collect_refs_expr(expr, scope, refs)
        if not(rec) {
          scope[name] = true
        }
      }
      @core.Stmt::LetMut(name~, expr~, span~) => {
        let _ = span
        collect_refs_expr(expr, scope, refs)
        scope[name] = true
      }
      @core.Stmt::Assign(name~, expr~, span~) => {
        let _ = span
        add_ref_name(name, scope, refs)
        collect_refs_expr(expr, scope, refs)
      }
      @core.Stmt::IndexAssign(target~, index~, value~, span~) => {
        let _ = span
        collect_refs_expr(target, scope, refs)
        collect_refs_expr(index, scope, refs)
        collect_refs_expr(value, scope, refs)
      }
      @core.Stmt::LetPat(pat~, expr~, span~) => {
        let _ = span
        collect_refs_expr(expr, scope, refs)
        bind_pattern_names(scope, pat)
      }
      @core.Stmt::Expr(expr~, span~) => {
        let _ = span
        collect_refs_expr(expr, scope, refs)
      }
      @core.Stmt::EnumDef(name~, params~, ctors~, span~) => {
        let _ = params
        let _ = span
        scope[name] = true
        for ctor in ctors {
          for arg in ctor.args {
            collect_refs_type(arg, refs)
          }
        }
      }
      @core.Stmt::ExportEnumDef(name~, params~, ctors~, span~) => {
        let _ = params
        let _ = span
        scope[name] = true
        for ctor in ctors {
          for arg in ctor.args {
            collect_refs_type(arg, refs)
          }
        }
      }
      @core.Stmt::TypeAlias(name~, params~, target~, span~) => {
        let _ = params
        let _ = span
        scope[name] = true
        collect_refs_type(target, refs)
      }
      @core.Stmt::ExportTypeAlias(name~, params~, target~, span~) => {
        let _ = params
        let _ = span
        scope[name] = true
        collect_refs_type(target, refs)
      }
      @core.Stmt::StructDef(name~, params~, fields~, span~) => {
        let _ = params
        let _ = span
        scope[name] = true
        for field in fields {
          collect_refs_type(field.ty, refs)
        }
      }
      @core.Stmt::ExportStructDef(name~, params~, fields~, span~) => {
        let _ = params
        let _ = span
        scope[name] = true
        for field in fields {
          collect_refs_type(field.ty, refs)
        }
      }
      @core.Stmt::Test(..)
      | @core.Stmt::Import(..)
      | @core.Stmt::TraitDef(..)
      | @core.Stmt::TraitImpl(..)
      | @core.Stmt::Export(..)
      | @core.Stmt::ReExport(..) => ()
    }
  }
}

///|
/// Collect type references from a type annotation
fn collect_refs_type(ty : @core.Type, refs : Map[String, Bool]) -> Unit {
  match ty {
    @core.Type::Int
    | @core.Type::Float
    | @core.Type::Double
    | @core.Type::Bool
    | @core.Type::String
    | @core.Type::Path
    | @core.Type::Unit
    | @core.Type::Never
    | @core.Type::Param(_)
    | @core.Type::Var(_) => ()
    @core.Type::Named(name~, args~) => {
      refs[name] = true
      for arg in args {
        collect_refs_type(arg, refs)
      }
    }
    @core.Type::Tuple(items) =>
      for item in items {
        collect_refs_type(item, refs)
      }
    @core.Type::Record(fields) =>
      for _, field_ty in fields {
        collect_refs_type(field_ty, refs)
      }
    @core.Type::Array(inner)
    | @core.Type::Map(inner)
    | @core.Type::ArrayBuilder(inner)
    | @core.Type::MapBuilder(inner) => collect_refs_type(inner, refs)
    @core.Type::Variant(fields) =>
      for _, field_ty in fields {
        collect_refs_type(field_ty, refs)
      }
    @core.Type::Func(params~, ret~, effects~) => {
      let _ = effects
      for param in params {
        collect_refs_type(param.ty, refs)
      }
      collect_refs_type(ret, refs)
    }
  }
}

///|
/// Add a reference if not bound locally and not a builtin
fn add_ref_name(
  name : String,
  bound : Map[String, Bool],
  refs : Map[String, Bool],
) -> Unit {
  if bound.contains(name) {
    return
  }
  // Note: enum constructors (is_ctor_name) ARE added as refs
  // so that DCE keeps the enum definition when a constructor is used
  if dce_is_builtin_name(name) || dce_has_qualified_name(name) {
    return
  }
  refs[name] = true
}

///|
fn dce_has_qualified_name(name : String) -> Bool {
  for c in name {
    if c == '.' {
      return true
    }
  }
  false
}

///|
fn dce_is_builtin_name(name : String) -> Bool {
  name == "path" ||
  name == "addr" ||
  name == "sh" ||
  name == "add" ||
  name == "sub" ||
  name == "mul" ||
  name == "div" ||
  name == "eq" ||
  name == "lt" ||
  name == "stdout_write_char" ||
  name == "stdout_write_stream" ||
  name == "stdin_read_char" ||
  name == "stdin_read_stream" ||
  name == "array_builder" ||
  name == "array_builder_push" ||
  name == "array_builder_freeze" ||
  name == "map_builder" ||
  name == "map_builder_set" ||
  name == "map_builder_freeze"
}

///|
fn clone_bool_map(m : Map[String, Bool]) -> Map[String, Bool] {
  let out : Map[String, Bool] = {}
  for k, v in m {
    out[k] = v
  }
  out
}

///|
fn bind_pattern_names(bound : Map[String, Bool], pat : @core.Pat) -> Unit {
  match pat {
    @core.Pat::Wildcard(..) => ()
    @core.Pat::Bind(name~, span~) => {
      let _ = span
      bound[name] = true
    }
    @core.Pat::Ctor(name~, args~, span~) => {
      let _ = name
      let _ = span
      for arg in args {
        bind_pattern_names(bound, arg)
      }
    }
    @core.Pat::Tuple(items~, span~) => {
      let _ = span
      for item in items {
        bind_pattern_names(bound, item)
      }
    }
    @core.Pat::Record(fields~, span~) => {
      let _ = span
      for field in fields {
        bind_pattern_names(bound, field.pat)
      }
    }
    @core.Pat::Struct(name~, fields~, span~) => {
      let _ = name
      let _ = span
      for field in fields {
        bind_pattern_names(bound, field.pat)
      }
    }
    @core.Pat::Int(..)
    | @core.Pat::Float(..)
    | @core.Pat::Double(..)
    | @core.Pat::Bool(..)
    | @core.Pat::String(..) => ()
    @core.Pat::Or(pats~, span~) => {
      let _ = span
      for p in pats {
        bind_pattern_names(bound, p)
      }
    }
  }
}
