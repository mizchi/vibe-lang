///|
/// Dead Code Elimination for vibe WASM bundling
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
  // Collect user-defined names so we can detect when they shadow builtins.
  // Builtin names that are redefined by the user must NOT be filtered
  // during reference collection, otherwise DCE incorrectly removes them.
  let user_defs : Map[String, Bool] = {}
  for stmt in mod.stmts {
    match stmt {
      @core.Stmt::Let(name~, ..)
      | @core.Stmt::ExportLet(name~, ..)
      | @core.Stmt::LetMut(name~, ..) => user_defs[name] = true
      _ => ()
    }
  }
  let on_name = fn(
    name : String,
    bound : @core.WalkerScope,
    refs : Map[String, Bool],
  ) {
    if bound.contains(name) {
      return
    }
    if @core.has_qualified_name(name) {
      return
    }
    // Only filter builtin names that are NOT shadowed by user definitions
    if @core.is_builtin_name(name) && not(user_defs.contains(name)) {
      return
    }
    refs[name] = true
  }
  let graph = build_dep_graph(mod.stmts, on_name)
  let entries = collect_entry_points(mod.stmts, include_tests~, on_name)
  for name in extra_entries {
    entries[name] = true
  }
  let reachable = compute_reachable(entries, graph)
  let filtered = filter_reachable_stmts(mod.stmts, reachable)
  @core.Module::{ stmts: filtered }
}

///|
/// Build dependency graph: definition name -> set of referenced names
fn build_dep_graph(
  stmts : Array[@core.Stmt],
  on_name : (String, @core.WalkerScope, Map[String, Bool]) -> Unit,
) -> Map[String, Map[String, Bool]] {
  let graph : Map[String, Map[String, Bool]] = {}
  for stmt in stmts {
    let (name, refs) = collect_stmt_info(stmt, on_name)
    match name {
      Some(n) =>
        match graph.get(n) {
          Some(existing) => {
            let merged = @core.clone_bool_map(existing)
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
fn collect_stmt_info(
  stmt : @core.Stmt,
  on_name : (String, @core.WalkerScope, Map[String, Bool]) -> Unit,
) -> (String?, Map[String, Bool]) {
  let refs : Map[String, Bool] = {}
  let bound = @core.WalkerScope::new()
  match stmt {
    @core.Stmt::Let(rec~, name~, expr~, span~) => {
      let _ = span
      if rec {
        bound.bindings[name] = true
      }
      collect_refs_expr(expr, bound, refs, on_name)
      (Some(name), refs)
    }
    @core.Stmt::ExportLet(rec~, name~, expr~, span~) => {
      let _ = span
      if rec {
        bound.bindings[name] = true
      }
      collect_refs_expr(expr, bound, refs, on_name)
      (Some(name), refs)
    }
    @core.Stmt::InternalExportLet(rec~, name~, expr~, span~) => {
      let _ = span
      if rec {
        bound.bindings[name] = true
      }
      collect_refs_expr(expr, bound, refs, on_name)
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
    @core.Stmt::InternalExportEnumDef(name~, params~, ctors~, span~) => {
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
    @core.Stmt::InternalExportTypeAlias(name~, params~, target~, span~) => {
      let _ = params
      let _ = span
      collect_refs_type(target, refs)
      (Some(name), refs)
    }
    @core.Stmt::LetMut(name~, expr~, span~) => {
      let _ = span
      collect_refs_expr(expr, bound, refs, on_name)
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
    @core.Stmt::InternalExportStructDef(name~, params~, fields~, span~) => {
      let _ = params
      let _ = span
      for field in fields {
        collect_refs_type(field.ty, refs)
      }
      (Some(name), refs)
    }
    @core.Stmt::ExternLet(name~, ty~, span~) => {
      let _ = span
      collect_refs_type(ty, refs)
      (Some(name), refs)
    }
    // Non-definition statements
    @core.Stmt::Expr(..)
    | @core.Stmt::Import(..)
    | @core.Stmt::Test(..)
    | @core.Stmt::Bench(..)
    | @core.Stmt::TraitDef(..)
    | @core.Stmt::InternalTraitDef(..)
    | @core.Stmt::TraitImpl(..)
    | @core.Stmt::Assign(..)
    | @core.Stmt::IndexAssign(..)
    | @core.Stmt::LetPat(..)
    | @core.Stmt::LetPatElse(..)
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
  on_name : (String, @core.WalkerScope, Map[String, Bool]) -> Unit,
) -> Map[String, Bool] {
  let entries : Map[String, Bool] = {}
  let empty_bound = @core.WalkerScope::new()
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
        collect_refs_expr(expr, empty_bound, entries, on_name)
      }
      // Assignments are entry points (side effects)
      @core.Stmt::Assign(name~, expr~, span~) => {
        let _ = span
        entries[name] = true
        collect_refs_expr(expr, empty_bound, entries, on_name)
      }
      @core.Stmt::IndexAssign(target~, index~, value~, span~) => {
        let _ = span
        collect_refs_expr(target, empty_bound, entries, on_name)
        collect_refs_expr(index, empty_bound, entries, on_name)
        collect_refs_expr(value, empty_bound, entries, on_name)
      }
      // Let patterns with side effects - collect refs from expr
      @core.Stmt::LetPat(pat~, expr~, span~) => {
        let _ = pat
        let _ = span
        collect_refs_expr(expr, empty_bound, entries, on_name)
      }
      @core.Stmt::LetPatElse(pat~, expr~, else_body~, span~) => {
        let _ = pat
        let _ = span
        collect_refs_expr(expr, empty_bound, entries, on_name)
        collect_refs_block(else_body, empty_bound, entries, on_name)
      }
      // Last let binding is an entry point (its value is returned by 'run')
      @core.Stmt::Let(name~, ..) => if is_last { entries[name] = true }
      @core.Stmt::LetMut(name~, ..) => if is_last { entries[name] = true }
      @core.Stmt::Test(name~, body~, span~) => {
        let _ = name
        let _ = span
        if include_tests {
          collect_refs_block(body, empty_bound, entries, on_name)
        }
      }
      @core.Stmt::Bench(name~, body~, span~) => {
        let _ = name
        let _ = span
        if include_tests {
          collect_refs_block(body, empty_bound, entries, on_name)
        }
      }
      @core.Stmt::EnumDef(..)
      | @core.Stmt::InternalExportEnumDef(..)
      | @core.Stmt::TypeAlias(..)
      | @core.Stmt::InternalExportTypeAlias(..)
      | @core.Stmt::StructDef(..)
      | @core.Stmt::InternalExportStructDef(..)
      | @core.Stmt::ExternLet(..)
      | @core.Stmt::Import(..)
      | @core.Stmt::TraitDef(..)
      | @core.Stmt::InternalTraitDef(..)
      | @core.Stmt::TraitImpl(..)
      | @core.Stmt::InternalExportLet(..)
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
      @core.Stmt::InternalExportLet(name~, ..) =>
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
      @core.Stmt::InternalExportEnumDef(name~, params~, ctors~, span~) => {
        let _ = params
        let _ = span
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
      @core.Stmt::InternalExportTypeAlias(name~, ..) =>
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
      @core.Stmt::InternalExportStructDef(name~, ..) =>
        if reachable.contains(name) {
          out.push(stmt)
        }
      @core.Stmt::ExternLet(name~, ..) =>
        if reachable.contains(name) {
          out.push(stmt)
        }
      // Non-definition statements are always kept
      @core.Stmt::Expr(..)
      | @core.Stmt::Import(..)
      | @core.Stmt::Test(..)
      | @core.Stmt::Bench(..)
      | @core.Stmt::TraitDef(..)
      | @core.Stmt::InternalTraitDef(..)
      | @core.Stmt::TraitImpl(..)
      | @core.Stmt::Assign(..)
      | @core.Stmt::IndexAssign(..)
      | @core.Stmt::LetPat(..)
      | @core.Stmt::LetPatElse(..)
      | @core.Stmt::Export(..)
      | @core.Stmt::ReExport(..) => out.push(stmt)
    }
  }
  out
}

///|
/// Collect references from an expression using the generic walker with DCE filtering.
fn collect_refs_expr(
  expr : @core.Expr,
  bound : @core.WalkerScope,
  refs : Map[String, Bool],
  on_name : (String, @core.WalkerScope, Map[String, Bool]) -> Unit,
) -> Unit {
  @core.walk_expr_refs(expr, bound, refs, on_name)
}

///|
/// Collect references from a block using the generic walker with DCE filtering.
/// Additionally walks type-level refs (EnumDef, StructDef, TypeAlias)
/// which is DCE-specific.
fn collect_refs_block(
  body : @core.Module,
  bound : @core.WalkerScope,
  refs : Map[String, Bool],
  on_name : (String, @core.WalkerScope, Map[String, Bool]) -> Unit,
) -> Unit {
  @core.walk_block_refs(body, bound, refs, on_name)
  // DCE also needs type-level refs from type definitions in blocks
  for stmt in body.stmts {
    match stmt {
      @core.Stmt::EnumDef(ctors~, ..)
      | @core.Stmt::ExportEnumDef(ctors~, ..)
      | @core.Stmt::InternalExportEnumDef(ctors~, ..) =>
        for ctor in ctors {
          for arg in ctor.args {
            collect_refs_type(arg, refs)
          }
        }
      @core.Stmt::TypeAlias(target~, ..)
      | @core.Stmt::ExportTypeAlias(target~, ..)
      | @core.Stmt::InternalExportTypeAlias(target~, ..) =>
        collect_refs_type(target, refs)
      @core.Stmt::StructDef(fields~, ..)
      | @core.Stmt::ExportStructDef(fields~, ..)
      | @core.Stmt::InternalExportStructDef(fields~, ..) =>
        for field in fields {
          collect_refs_type(field.ty, refs)
        }
      _ => ()
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
    | @core.Type::Char
    | @core.Type::String
    | @core.Type::Path
    | @core.Type::PromptText
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
    @core.Type::StringBuilder => ()
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
