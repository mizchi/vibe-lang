///|
/// Bundle a module with all its dependencies for WASM compilation.
/// This inlines all exported definitions from dependencies and removes imports.
/// Applies DCE to eliminate unused definitions.
pub fn bundle_for_wasm(
  db : VibeDb,
  path : String,
  ast : @core.Module,
) -> @core.Module {
  bundle_for_wasm_impl(
    db,
    path,
    ast,
    apply_dce=true,
    include_test_entries=false,
    keep_for_in_helpers=true,
  )
}

///|
pub fn bundle_for_wasm_gc(
  db : VibeDb,
  path : String,
  ast : @core.Module,
) -> @core.Module {
  bundle_for_wasm_impl(
    db,
    path,
    ast,
    apply_dce=true,
    include_test_entries=false,
    keep_for_in_helpers=false,
  )
}

///|
/// Bundle without DCE (for benchmarking comparison).
pub fn bundle_for_wasm_no_dce(
  db : VibeDb,
  path : String,
  ast : @core.Module,
) -> @core.Module {
  bundle_for_wasm_impl(
    db,
    path,
    ast,
    apply_dce=false,
    include_test_entries=false,
    keep_for_in_helpers=true,
  )
}

///|
/// Bundle for coverage mode that executes top-level tests.
/// Keeps definitions referenced from test bodies when applying DCE.
pub fn bundle_for_wasm_test_coverage(
  db : VibeDb,
  path : String,
  ast : @core.Module,
) -> @core.Module {
  bundle_for_wasm_impl(
    db,
    path,
    ast,
    apply_dce=true,
    include_test_entries=true,
    keep_for_in_helpers=true,
  )
}

///|
/// Linked import info for debug linked builds.
pub(all) struct LinkedImport {
  /// wasm module name (used in wasmtime --preload)
  module_name : String
  /// function name (wasm export name in library module)
  func_name : String
  /// number of i64 params (excluding i32 env)
  param_count : Int
  /// number of i64 return values (1 for scalar, 2+ for tuple)
  return_count : Int
} derive(Show, Eq)

///|
pub fn prelude_core_module_name() -> String {
  "prelude_core"
}

///|
fn prelude_core_linked_import(stmt : @core.Stmt) -> LinkedImport? {
  match stmt {
    @core.Stmt::Let(name~, expr~, ..)
    | @core.Stmt::ExportLet(name~, expr~, ..)
    | @core.Stmt::InternalExportLet(name~, expr~, ..) =>
      match expr {
        @core.Expr::Fn(params~, ret~, ..) =>
          if linked_fn_has_func_param(params) {
            None
          } else {
            Some(LinkedImport::{
              module_name: prelude_core_module_name(),
              func_name: name,
              param_count: params.length(),
              return_count: fn_return_count(ret),
            })
          }
        _ => None
      }
    _ => None
  }
}

///|
fn prelude_core_library_stmts() -> Array[@core.Stmt] {
  let stmts : Array[@core.Stmt] = []
  for stmt in @checker.prelude_core_value_stmts() {
    match prelude_core_linked_import(stmt) {
      Some(_) => stmts.push(stmt)
      None => ()
    }
  }
  stmts
}

///|
fn prelude_linked_build_inline_stmts() -> Array[@core.Stmt] {
  let stmts : Array[@core.Stmt] = []
  for stmt in @checker.prelude_core_value_stmts() {
    match prelude_core_linked_import(stmt) {
      Some(_) => ()
      None => stmts.push(stmt)
    }
  }
  for stmt in @checker.prelude_builtin_value_stmts() {
    stmts.push(stmt)
  }
  stmts
}

///|
fn append_prelude_core_linked_imports(
  linked_imports : Array[LinkedImport],
  existing_value_names : Map[String, Bool],
) -> Unit {
  for stmt in prelude_core_library_stmts() {
    match prelude_core_linked_import(stmt) {
      Some(li) =>
        if not(existing_value_names.contains(li.func_name)) {
          existing_value_names[li.func_name] = true
          linked_imports.push(li)
        }
      None => ()
    }
  }
}

///|
fn append_prelude_inline_stmts_for_linked_build(
  bundled_stmts : Array[@core.Stmt],
  existing_value_names : Map[String, Bool],
) -> Unit {
  for stmt in prelude_linked_build_inline_stmts() {
    match bundle_stmt_value_name(stmt) {
      Some(name) =>
        if not(existing_value_names.contains(name)) {
          bundled_stmts.push(stmt)
          existing_value_names[name] = true
        }
      None => ()
    }
  }
}

///|
pub fn prelude_core_library_module() -> @core.Module {
  @core.Module::{ stmts: prelude_core_library_stmts() }
}

///|
priv struct SelectedReExport {
  spec : @core.ImportSpec
  source : @core.ModuleRef
}

///|
fn push_linked_import(
  linked_imports : Array[LinkedImport],
  existing_value_names : Map[String, Bool],
  li : LinkedImport,
) -> Unit {
  if not(existing_value_names.contains(li.func_name)) {
    existing_value_names[li.func_name] = true
    linked_imports.push(li)
  }
}

///|
fn linked_import_from_resolved_fn(
  module_name : String,
  local_name : String,
  resolved : ResolvedReExportFn,
) -> LinkedImport {
  LinkedImport::{
    module_name,
    func_name: local_name,
    param_count: resolved.params.length(),
    return_count: resolved.return_count,
  }
}

///|
fn collect_dependency_defs_selected(
  db : VibeDb,
  path : String,
  out : Array[@core.Stmt],
  visited : Map[String, Bool],
  selected_export_names : Map[String, Bool],
  selected_reexports : Array[SelectedReExport],
) -> Unit {
  if visited.contains(path) {
    return
  }
  let emitted_types : Map[String, Bool] = {}
  for stmt in out {
    match bundle_stmt_type_name(stmt) {
      Some(name) => emitted_types[name] = true
      None => ()
    }
  }
  let is_entry = visited.length() == 0
  visited[path] = true
  let imports = db.imports(path)
  for imp in imports {
    collect_dependency_defs(db, imp.path, out, visited)
  }
  if not(is_entry) {
    let dep_ast = db.ast_with_hash_imports(path)
    for stmt in dep_ast.stmts {
      match stmt {
        @core.Stmt::ExportLet(rec~, name~, expr~, span~) =>
          if selected_export_names.contains(name) {
            out.push(@core.Stmt::Let(rec~, name~, expr~, span~))
          }
        @core.Stmt::ExportEnumDef(name~, params~, ctors~, span~) =>
          if not(emitted_types.contains(name)) {
            out.push(@core.Stmt::EnumDef(name~, params~, ctors~, span~))
            emitted_types[name] = true
          }
        @core.Stmt::ExportTypeAlias(name~, params~, target~, span~) =>
          if not(emitted_types.contains(name)) {
            out.push(@core.Stmt::TypeAlias(name~, params~, target~, span~))
            emitted_types[name] = true
          }
        @core.Stmt::Let(..) => out.push(stmt)
        @core.Stmt::EnumDef(name~, ..) =>
          if not(emitted_types.contains(name)) {
            out.push(stmt)
            emitted_types[name] = true
          }
        @core.Stmt::TypeAlias(name~, ..) =>
          if not(emitted_types.contains(name)) {
            out.push(stmt)
            emitted_types[name] = true
          }
        @core.Stmt::ReExport(..) => ()
        @core.Stmt::Import(..) | @core.Stmt::Export(..) => ()
        @core.Stmt::Test(..) | @core.Stmt::Bench(..) => ()
        @core.Stmt::TraitDef(..)
        | @core.Stmt::TraitImpl(..)
        | @core.Stmt::InternalTraitDef(..) => ()
        @core.Stmt::LetMut(..) => out.push(stmt)
        _ => out.push(stmt)
      }
    }
    for selected in selected_reexports {
      collect_reexport_defs(
        db,
        path,
        selected.spec,
        selected.source,
        out,
        visited,
      )
    }
  }
}

///|
/// Bundle for linked mode: don't inline import dependencies, instead return
/// their exported function names as linked imports. These become wasm imports
/// that are resolved at runtime via `wasmtime --preload`.
pub fn bundle_for_wasm_linked(
  db : VibeDb,
  path : String,
  ast : @core.Module,
) -> (@core.Module, Array[LinkedImport]) {
  let bundled_stmts : Array[@core.Stmt] = []
  let linked_imports : Array[LinkedImport] = []
  let existing_value_names : Map[String, Bool] = {}
  // Collect linked imports from dependency modules.
  // If all exported functions have scalar params → linked import (static wasm call).
  // If any export has Func params (HOF) → inline the entire module (monolithic).
  let imports = db.imports(path)
  let visited : Map[String, Bool] = {}
  // Mark user module as visited so collect_dependency_defs treats
  // import modules as non-entry (their ExportLet defs will be included).
  visited[path] = true
  for imp in imports {
    let dep_ast = db.ast_with_hash_imports(imp.path)
    let module_name = linked_module_name(imp.path)
    let host_imports_visited : Map[String, Bool] = {}
    let needs_host_import_inline = module_requires_preload_host_imports(
      db,
      imp.path,
      host_imports_visited,
    )
    if needs_host_import_inline {
      // Inline deps that need host imports because wasmtime --preload cannot
      // instantiate library modules that carry their own host/WASI imports.
      collect_dependency_defs(db, imp.path, bundled_stmts, visited)
    } else {
      let selected_export_names : Map[String, Bool] = {}
      let selected_reexports : Array[SelectedReExport] = []
      for stmt in dep_ast.stmts {
        match stmt {
          @core.Stmt::ExportLet(name~, expr=_, ..) =>
            match resolve_bound_fn_at_path(db, imp.path, name, {}) {
              Some(resolved) =>
                if linked_fn_has_func_param(resolved.params) {
                  selected_export_names[name] = true
                } else {
                  push_linked_import(
                    linked_imports,
                    existing_value_names,
                    linked_import_from_resolved_fn(module_name, name, resolved),
                  )
                }
              _ => ()
            }
          @core.Stmt::ReExport(spec~, source~, ..) => {
            let resolved = resolve_reexport_all(db, imp.path, spec, source)
            let resolved_fn_map : Map[String, ResolvedReExportFn] = {}
            for r in resolved.functions {
              resolved_fn_map[r.name] = r
            }
            let hof_items : Array[@core.ImportItem] = []
            for item in spec.items {
              let local_name = import_local_name(item)
              match resolved_fn_map.get(local_name) {
                Some(resolved_fn) =>
                  if linked_fn_has_func_param(resolved_fn.params) {
                    hof_items.push(item)
                  } else {
                    push_linked_import(
                      linked_imports,
                      existing_value_names,
                      linked_import_from_resolved_fn(
                        module_name, local_name, resolved_fn,
                      ),
                    )
                  }
                None => ()
              }
            }
            if hof_items.length() > 0 {
              selected_reexports.push(SelectedReExport::{
                spec: { items: hof_items },
                source,
              })
            }
            for t in resolved.type_stmts {
              bundled_stmts.push(t)
            }
          }
          @core.Stmt::ExportEnumDef(name~, params~, ctors~, span~) =>
            bundled_stmts.push(
              @core.Stmt::EnumDef(name~, params~, ctors~, span~),
            )
          @core.Stmt::ExportTypeAlias(name~, params~, target~, span~) =>
            bundled_stmts.push(
              @core.Stmt::TypeAlias(name~, params~, target~, span~),
            )
          _ => ()
        }
      }
      if selected_export_names.length() > 0 || selected_reexports.length() > 0 {
        collect_dependency_defs_selected(
          db,
          imp.path,
          bundled_stmts,
          visited,
          selected_export_names,
          selected_reexports,
        )
      }
    }
  }
  append_prelude_core_linked_imports(linked_imports, existing_value_names)
  append_prelude_inline_stmts_for_linked_build(
    bundled_stmts, existing_value_names,
  )
  // Add main module statements (excluding imports; resolve re-exports for types)
  let raw_entry_ast = db.ast(path)
  let non_prelude_names : Array[String] = []
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::Import(..) => ()
      @core.Stmt::ReExport(..) => ()
      _ => {
        match bundle_stmt_value_name(stmt) {
          Some(name) => non_prelude_names.push(name)
          None => ()
        }
        bundled_stmts.push(stmt)
      }
    }
  }
  // Resolve type definitions from entry module's own ReExport stmts
  for stmt in raw_entry_ast.stmts {
    match stmt {
      @core.Stmt::ReExport(spec~, source~, ..) => {
        let resolved = resolve_reexport_all(db, path, spec, source)
        for t in resolved.type_stmts {
          bundled_stmts.push(t)
        }
      }
      _ => ()
    }
  }
  let bundled = @core.Module::{
    stmts: dedupe_bundle_structural_defs(bundled_stmts),
  }
  let after_dce = @pipeline.dce_module_with_entry_names(
    bundled, non_prelude_names,
  )
  (demote_unused_let_mut(after_dce), linked_imports)
}

///|

///|
/// Bundle for linked mode with pre-computed imports list (fast path).
/// No VibeDb needed — just prelude + user AST.
/// `extra_type_stmts` provides type definitions resolved from ReExport chains
/// (since db is not available to resolve them at bundle time).
pub fn bundle_for_wasm_linked_with_imports(
  ast : @core.Module,
  linked_imports : Array[LinkedImport],
  extra_type_stmts? : Array[@core.Stmt] = [],
) -> (@core.Module, Array[LinkedImport]) {
  let bundled_stmts : Array[@core.Stmt] = []
  let existing_value_names : Map[String, Bool] = {}
  for li in linked_imports {
    existing_value_names[li.func_name] = true
  }
  append_prelude_inline_stmts_for_linked_build(
    bundled_stmts, existing_value_names,
  )
  // Add extra type definitions from resolved ReExports
  for stmt in extra_type_stmts {
    bundled_stmts.push(stmt)
  }
  // Add user code (skip imports and re-exports)
  let non_prelude_names : Array[String] = []
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::Import(..) | @core.Stmt::ReExport(..) => ()
      _ => {
        match bundle_stmt_value_name(stmt) {
          Some(name) => non_prelude_names.push(name)
          None => ()
        }
        bundled_stmts.push(stmt)
      }
    }
  }
  let bundled = @core.Module::{
    stmts: dedupe_bundle_structural_defs(bundled_stmts),
  }
  let after_dce = @pipeline.dce_module_with_entry_names(
    bundled, non_prelude_names,
  )
  (demote_unused_let_mut(after_dce), linked_imports)
}

///|

///|
/// Check if any function parameter has a Func type (higher-order function).
/// HOF functions need funcref table sharing, so they must be inlined.
fn linked_fn_has_func_param(params : Array[@core.FuncParam]) -> Bool {
  for param in params {
    if linked_type_is_func(param.ty) {
      return true
    }
  }
  false
}

///|
fn linked_type_is_func(ty : @core.Type) -> Bool {
  match ty {
    @core.Type::Func(..) => true
    _ => false
  }
}

///|
fn module_requires_preload_host_imports(
  db : VibeDb,
  path : String,
  visited : Map[String, Bool],
) -> Bool {
  if visited.contains(path) {
    return false
  }
  visited[path] = true
  let ast = db.ast(path)
  if module_stmt_list_requires_preload_host_imports(ast.stmts) {
    return true
  }
  let dep_imports = db.imports(path)
  for imp in dep_imports {
    if module_requires_preload_host_imports(db, imp.path, visited) {
      return true
    }
  }
  let base_dir = @path.Path(path).dirname().to_string()
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::ReExport(source~, ..) =>
        match resolve_module_ref_path(base_dir, source, dep_imports~) {
          Some(source_path) =>
            if module_requires_preload_host_imports(db, source_path, visited) {
              return true
            }
          None => ()
        }
      _ => ()
    }
  }
  false
}

///|
fn module_stmt_list_requires_preload_host_imports(
  stmts : Array[@core.Stmt],
) -> Bool {
  for stmt in stmts {
    if module_stmt_requires_preload_host_imports(stmt) {
      return true
    }
  }
  false
}

///|
fn module_stmt_requires_preload_host_imports(stmt : @core.Stmt) -> Bool {
  match stmt {
    @core.Stmt::Let(expr~, ..)
    | @core.Stmt::ExportLet(expr~, ..)
    | @core.Stmt::InternalExportLet(expr~, ..)
    | @core.Stmt::LetMut(expr~, ..)
    | @core.Stmt::Expr(expr~, ..)
    | @core.Stmt::LetPat(expr~, ..) =>
      module_expr_requires_preload_host_imports(expr)
    @core.Stmt::LetPatElse(expr~, else_body~, ..) =>
      module_expr_requires_preload_host_imports(expr) ||
      module_stmt_list_requires_preload_host_imports(else_body.stmts)
    @core.Stmt::Assign(expr~, ..) =>
      module_expr_requires_preload_host_imports(expr)
    @core.Stmt::IndexAssign(target~, index~, value~, ..) =>
      module_expr_requires_preload_host_imports(target) ||
      module_expr_requires_preload_host_imports(index) ||
      module_expr_requires_preload_host_imports(value)
    @core.Stmt::Test(..) | @core.Stmt::Bench(..) => false
    _ => false
  }
}

///|
fn module_expr_requires_preload_host_imports(expr : @core.Expr) -> Bool {
  match expr {
    @core.Expr::Call(name~, args~, ..) => {
      if is_preload_unsafe_builtin_name(name) {
        return true
      }
      for arg in args {
        if module_expr_requires_preload_host_imports(arg.expr) {
          return true
        }
      }
      false
    }
    @core.Expr::Perform(effect_name~, args~, ..) => {
      if is_preload_unsafe_effect_name(effect_name) {
        return true
      }
      for arg in args {
        if module_expr_requires_preload_host_imports(arg.expr) {
          return true
        }
      }
      false
    }
    @core.Expr::Tuple(items~, ..) | @core.Expr::Array(items~, ..) => {
      for item in items {
        if module_expr_requires_preload_host_imports(item) {
          return true
        }
      }
      false
    }
    @core.Expr::TupleIndex(expr~, ..)
    | @core.Expr::Spread(expr~, ..)
    | @core.Expr::Yield(expr~, ..) =>
      module_expr_requires_preload_host_imports(expr)
    @core.Expr::Record(fields~, ..) | @core.Expr::StructLit(fields~, ..) => {
      for field in fields {
        if module_expr_requires_preload_host_imports(field.expr) {
          return true
        }
      }
      false
    }
    @core.Expr::Map(fields~, ..) => {
      for field in fields {
        if module_expr_requires_preload_host_imports(field.expr) {
          return true
        }
      }
      false
    }
    @core.Expr::If(cond~, then_body~, else_body~, ..) =>
      module_expr_requires_preload_host_imports(cond) ||
      module_stmt_list_requires_preload_host_imports(then_body.stmts) ||
      module_stmt_list_requires_preload_host_imports(else_body.stmts)
    @core.Expr::Block(body~, ..) | @core.Expr::Fn(body~, ..) =>
      module_stmt_list_requires_preload_host_imports(body.stmts)
    @core.Expr::Match(scrutinee~, arms~, ..) => {
      if module_expr_requires_preload_host_imports(scrutinee) {
        return true
      }
      for arm in arms {
        if module_expr_requires_preload_host_imports(arm.expr) {
          return true
        }
        match arm.cond {
          Some(cond) =>
            if module_expr_requires_preload_host_imports(cond) {
              return true
            }
          None => ()
        }
      }
      false
    }
    @core.Expr::Handle(body~, arms~, ..) => {
      if module_stmt_list_requires_preload_host_imports(body.stmts) {
        return true
      }
      for arm in arms {
        if module_expr_requires_preload_host_imports(arm.expr) {
          return true
        }
        match arm.cond {
          Some(cond) =>
            if module_expr_requires_preload_host_imports(cond) {
              return true
            }
          None => ()
        }
      }
      false
    }
    @core.Expr::ForIn(iterable~, body~, ..) =>
      module_expr_requires_preload_host_imports(iterable) ||
      module_stmt_list_requires_preload_host_imports(body.stmts)
    @core.Expr::While(cond~, body~, ..) =>
      module_expr_requires_preload_host_imports(cond) ||
      module_stmt_list_requires_preload_host_imports(body.stmts)
    @core.Expr::Loop(params~, body~, ..) => {
      for param in params {
        if module_expr_requires_preload_host_imports(param.init) {
          return true
        }
      }
      module_stmt_list_requires_preload_host_imports(body.stmts)
    }
    @core.Expr::Break(value~, ..) =>
      match value {
        Some(inner) => module_expr_requires_preload_host_imports(inner)
        None => false
      }
    @core.Expr::Continue(args~, ..) => {
      for arg in args {
        if module_expr_requires_preload_host_imports(arg) {
          return true
        }
      }
      false
    }
    @core.Expr::Int(..)
    | @core.Expr::Float(..)
    | @core.Expr::Double(..)
    | @core.Expr::Bool(..)
    | @core.Expr::Char(..)
    | @core.Expr::String(..)
    | @core.Expr::Ident(..)
    | @core.Expr::Placeholder(..) => false
    // StringInterp is lowered in desugar; should never reach here
    @core.Expr::StringInterp(..) => false
  }
}

///|
fn is_preload_unsafe_builtin_name(name : String) -> Bool {
  name == "sh" ||
  name == "path" ||
  name == "Path::resolve" ||
  name == "sleep" ||
  name == "Env::get" ||
  name == "Env::args_len" ||
  name == "Env::args_get" ||
  name == "Stdout::write_char" ||
  name == "Stdout::write_stream" ||
  name == "Stdin::read_char" ||
  name == "Stdin::read_stream" ||
  name == "Fs::read_file" ||
  name == "Fs::write_file" ||
  name == "Fs::write_bytes" ||
  name == "Fs::exists" ||
  name == "Fs::stat_token" ||
  name == "Socket::tcp_connect" ||
  name == "Socket::tcp_read" ||
  name == "Socket::tcp_write" ||
  name == "Socket::tcp_close" ||
  name == "Http::request" ||
  name == "Http::response_status" ||
  name == "Http::response_header" ||
  name == "Http::response_body" ||
  name == "Http::close" ||
  name == "Http::listen" ||
  name == "Http::accept" ||
  name == "Http::request_method" ||
  name == "Http::request_url" ||
  name == "Http::request_header" ||
  name == "Http::request_body" ||
  name == "Http::respond"
}

///|
fn is_preload_unsafe_effect_name(effect_name : String) -> Bool {
  effect_name == "Fs" ||
  effect_name == "Env" ||
  effect_name == "Stdout" ||
  effect_name == "Stdin" ||
  effect_name == "Socket" ||
  effect_name == "Http" ||
  effect_name == "Process"
}

///|
/// Resolved function info from a ReExport chain.
priv struct ResolvedReExportFn {
  name : String
  params : Array[@core.FuncParam]
  return_count : Int
}

///|
/// Result of resolving all items in a ReExport statement.
priv struct ResolvedReExport {
  functions : Array[ResolvedReExportFn]
  type_stmts : Array[@core.Stmt]
}

///|
fn fn_return_count(ret : @core.Type?) -> Int {
  match ret {
    Some(@core.Type::Tuple(items)) => items.length()
    _ => 1
  }
}

///|
fn import_local_name(item : @core.ImportItem) -> String {
  match item.rename {
    Some(alias_name) => alias_name
    None => item.name
  }
}

///|
fn resolve_bound_fn_via_imports(
  db : VibeDb,
  source_path : String,
  source_ast : @core.Module,
  name : String,
  visited : Map[String, Bool],
) -> ResolvedReExportFn? {
  let dep_imports = db.imports(source_path)
  let base_dir = @path.Path(source_path).dirname().to_string()
  for stmt in source_ast.stmts {
    match stmt {
      @core.Stmt::Import(spec~, source~, ..) =>
        for item in spec.items {
          if import_local_name(item) == name {
            match resolve_module_ref_path(base_dir, source, dep_imports~) {
              Some(import_path) =>
                match
                  resolve_bound_fn_at_path(db, import_path, item.name, visited) {
                  Some(resolved) =>
                    return Some(ResolvedReExportFn::{ ..resolved, name, })
                  None => ()
                }
              None => ()
            }
          }
        }
      _ => ()
    }
  }
  None
}

///|
fn resolve_bound_fn_at_path(
  db : VibeDb,
  source_path : String,
  name : String,
  visited : Map[String, Bool],
) -> ResolvedReExportFn? {
  let visit_key = source_path + "#" + name
  if visited.contains(visit_key) {
    return None
  }
  visited[visit_key] = true
  let source_ast = db.ast_with_hash_imports(source_path)
  for stmt in source_ast.stmts {
    match stmt {
      @core.Stmt::Let(name=bound_name, expr~, ..)
      | @core.Stmt::ExportLet(name=bound_name, expr~, ..)
      | @core.Stmt::InternalExportLet(name=bound_name, expr~, ..) =>
        if bound_name == name {
          match expr {
            @core.Expr::Fn(params~, ret~, ..) =>
              return Some(ResolvedReExportFn::{
                name,
                params,
                return_count: fn_return_count(ret),
              })
            @core.Expr::Ident(name=target_name, ..) =>
              match
                resolve_bound_fn_via_imports(
                  db, source_path, source_ast, target_name, visited,
                ) {
                Some(resolved) =>
                  return Some(ResolvedReExportFn::{ ..resolved, name, })
                None => return None
              }
            _ => return None
          }
        }
      _ => ()
    }
  }
  resolve_bound_fn_via_imports(db, source_path, source_ast, name, visited)
}

///|
/// Resolve the file path that a ModuleRef points to, given the directory of the
/// referencing module and the import specs for the referrer.
fn resolve_module_ref_path(
  base_dir : String,
  source : @core.ModuleRef,
  dep_imports? : Array[ImportSpec] = [],
) -> String? {
  match source {
    @core.ModuleRef::Path(path~) =>
      Some(normalize_path_obj(base_dir, path).normalized)
    @core.ModuleRef::PinnedPath(path~, ..) =>
      Some(normalize_path_obj(base_dir, path).normalized)
    @core.ModuleRef::Hash(hash~) => {
      // Resolve hash to path using pre-resolved import specs
      for imp in dep_imports {
        match imp.hash {
          Some(h) => if h == hash { return Some(imp.path) }
          None => ()
        }
      }
      None
    }
    _ => None
  }
}

///|
/// Resolve all items in a ReExport: functions become LinkedImports, types become
/// inlined definitions. Uses raw ASTs so ModuleRef::Path is preserved.
/// All item names are treated as potential matches regardless of ImportKind,
/// because vibe import syntax uses Value kind by default for all names.
fn resolve_reexport_all(
  db : VibeDb,
  dep_path : String,
  spec : @core.ImportSpec,
  source : @core.ModuleRef,
) -> ResolvedReExport {
  let result = ResolvedReExport::{ functions: [], type_stmts: [] }
  let wanted : Map[String, String] = {}
  for item in spec.items {
    let export_name = match item.rename {
      Some(alias_name) => alias_name
      None => item.name
    }
    wanted[item.name] = export_name
  }
  if wanted.length() == 0 {
    return result
  }
  let dep_imports = db.imports(dep_path)
  let base_dir = @path.Path(dep_path).dirname().to_string()
  let source_path = match
    resolve_module_ref_path(base_dir, source, dep_imports~) {
    Some(p) => p
    None => return result
  }
  resolve_reexport_at_path(db, source_path, wanted, result)
  result
}

///|
/// Resolve ReExport items at a known source path.
fn resolve_reexport_at_path(
  db : VibeDb,
  source_path : String,
  wanted : Map[String, String],
  result : ResolvedReExport,
) -> Unit {
  let source_ast = db.ast_with_hash_imports(source_path)
  for stmt in source_ast.stmts {
    match stmt {
      @core.Stmt::ExportLet(name~, expr=_, ..) =>
        match wanted.get(name) {
          Some(export_name) =>
            match resolve_bound_fn_at_path(db, source_path, name, {}) {
              Some(resolved) =>
                result.functions.push(ResolvedReExportFn::{
                  ..resolved,
                  name: export_name,
                })
              _ => ()
            }
          None => ()
        }
      @core.Stmt::ExportEnumDef(name~, params~, ctors~, span~) =>
        match wanted.get(name) {
          Some(_export_name) =>
            result.type_stmts.push(
              @core.Stmt::EnumDef(name~, params~, ctors~, span~),
            )
          None => ()
        }
      @core.Stmt::ExportTypeAlias(name~, params~, target~, span~) =>
        match wanted.get(name) {
          Some(_export_name) =>
            result.type_stmts.push(
              @core.Stmt::TypeAlias(name~, params~, target~, span~),
            )
          None => ()
        }
      @core.Stmt::ExportStructDef(name~, params~, fields~, span~) =>
        match wanted.get(name) {
          Some(_export_name) =>
            result.type_stmts.push(
              @core.Stmt::StructDef(name~, params~, fields~, span~),
            )
          None => ()
        }
      @core.Stmt::ReExport(spec=inner_spec, source=inner_source, ..) => {
        // Recurse into nested ReExport chains
        let inner = resolve_reexport_all(
          db, source_path, inner_spec, inner_source,
        )
        for r in inner.functions {
          match wanted.get(r.name) {
            Some(export_name) =>
              result.functions.push(ResolvedReExportFn::{
                ..r,
                name: export_name,
              })
            None => ()
          }
        }
        for t in inner.type_stmts {
          let type_name = match t {
            @core.Stmt::EnumDef(name~, ..) => Some(name)
            @core.Stmt::TypeAlias(name~, ..) => Some(name)
            @core.Stmt::StructDef(name~, ..) => Some(name)
            _ => None
          }
          match type_name {
            Some(n) => if wanted.contains(n) { result.type_stmts.push(t) }
            None => ()
          }
        }
      }
      _ => ()
    }
  }
}

///|
pub fn linked_module_name(path : String) -> String {
  // Convert path to a valid wasm module name
  // e.g. "./wasm_runtime.vibe" -> "wasm_runtime"
  let mut name = path
  // Strip directory prefix
  let mut last_slash = -1
  for i, c in name {
    if c == '/' {
      last_slash = i
    }
  }
  if last_slash >= 0 {
    name = name.unsafe_substring(start=last_slash + 1, end=name.length())
  }
  // Strip .vibe extension
  if name.has_suffix(".vibe") {
    name = name.unsafe_substring(start=0, end=name.length() - 5)
  }
  name
}

///|
fn bundle_for_wasm_impl(
  db : VibeDb,
  path : String,
  ast : @core.Module,
  apply_dce~ : Bool,
  include_test_entries~ : Bool,
  keep_for_in_helpers~ : Bool,
) -> @core.Module {
  let bundled_stmts : Array[@core.Stmt] = []
  let visited : Map[String, Bool] = {}
  // Collect all dependency definitions in topological order
  collect_dependency_defs(db, path, bundled_stmts, visited)
  let existing_value_names : Map[String, Bool] = {}
  for stmt in bundled_stmts {
    match bundle_stmt_value_name(stmt) {
      Some(name) => existing_value_names[name] = true
      None => ()
    }
  }
  // Include prelude function definitions so that higher-order functions
  // like array_map, array_filter, array_fold etc. are available in WASM.
  // These are defined as user-level .vibe code using primitive builtins
  // (array_builder, array_builder_push, etc.) that the WASM backend handles.
  // DCE will remove any prelude definitions that aren't actually used.
  // Snapshot non-prelude names before adding prelude stmts.
  // Used for surgical prelude DCE in --no-dce mode.
  let non_prelude_names : Array[String] = []
  for stmt in bundled_stmts {
    match bundle_stmt_value_name(stmt) {
      Some(name) => non_prelude_names.push(name)
      None => ()
    }
  }
  for
    prelude_stmts in [
      @checker.prelude_core_value_stmts(),
      @checker.prelude_builtin_value_stmts(),
    ] {
    for stmt in prelude_stmts {
      match bundle_stmt_value_name(stmt) {
        Some(name) =>
          if not(existing_value_names.contains(name)) {
            bundled_stmts.push(stmt)
            existing_value_names[name] = true
          }
        None => ()
      }
    }
  }
  // Add main module statements (excluding imports and expanding re-exports)
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::Import(..) => () // Skip imports
      @core.Stmt::ReExport(spec~, source~, span=_) =>
        // Expand re-exports in main module
        collect_reexport_defs(db, path, spec, source, bundled_stmts, visited)
      _ => {
        match bundle_stmt_value_name(stmt) {
          Some(name) => non_prelude_names.push(name)
          None => ()
        }
        bundled_stmts.push(stmt)
      }
    }
  }
  let bundled = @core.Module::{
    stmts: dedupe_bundle_structural_defs(bundled_stmts),
  }
  let after_dce = if apply_dce {
    if include_test_entries {
      @pipeline.dce_module_for_tests(bundled)
    } else if keep_for_in_helpers {
      @pipeline.dce_module(bundled)
    } else {
      @pipeline.dce_module_gc(bundled)
    }
  } else {
    // Without full DCE, still remove unused prelude functions to avoid
    // compiling ~30+ unused standard library functions per module.
    // All user/dependency names are kept as roots so only prelude is affected.
    @pipeline.dce_module_with_entry_names(bundled, non_prelude_names)
  }
  demote_unused_let_mut(after_dce)
}

///|
fn bundle_stmt_value_name(stmt : @core.Stmt) -> String? {
  match stmt {
    @core.Stmt::Let(name~, ..)
    | @core.Stmt::ExportLet(name~, ..)
    | @core.Stmt::InternalExportLet(name~, ..)
    | @core.Stmt::LetMut(name~, ..) => Some(name)
    _ => None
  }
}

///|
/// Recursively collect definitions from dependencies.
fn collect_dependency_defs(
  db : VibeDb,
  path : String,
  out : Array[@core.Stmt],
  visited : Map[String, Bool],
) -> Unit {
  if visited.contains(path) {
    return
  }
  // Track emitted type names to avoid duplicate EnumDef/StructDef/TypeAlias
  let emitted_types : Map[String, Bool] = {}
  for stmt in out {
    match bundle_stmt_type_name(stmt) {
      Some(name) => emitted_types[name] = true
      None => ()
    }
  }
  let is_entry = visited.length() == 0
  visited[path] = true
  let imports = db.imports(path)
  // First, recursively process dependencies
  for imp in imports {
    collect_dependency_defs(db, imp.path, out, visited)
  }
  // Then add definitions from this module (if it's an imported module)
  // Skip the entry module itself (it will be added separately)
  if not(is_entry) {
    let dep_ast = db.ast_with_hash_imports(path)
    for stmt in dep_ast.stmts {
      match stmt {
        // Convert exports to regular definitions
        @core.Stmt::ExportLet(rec~, name~, expr~, span~) =>
          out.push(@core.Stmt::Let(rec~, name~, expr~, span~))
        @core.Stmt::ExportEnumDef(name~, params~, ctors~, span~) =>
          if not(emitted_types.contains(name)) {
            out.push(@core.Stmt::EnumDef(name~, params~, ctors~, span~))
            emitted_types[name] = true
          }
        @core.Stmt::ExportTypeAlias(name~, params~, target~, span~) =>
          if not(emitted_types.contains(name)) {
            out.push(@core.Stmt::TypeAlias(name~, params~, target~, span~))
            emitted_types[name] = true
          }
        // Also include non-exported definitions that exported ones might depend on
        @core.Stmt::Let(..) => out.push(stmt)
        @core.Stmt::EnumDef(name~, ..) =>
          if not(emitted_types.contains(name)) {
            out.push(stmt)
            emitted_types[name] = true
          }
        @core.Stmt::TypeAlias(name~, ..) =>
          if not(emitted_types.contains(name)) {
            out.push(stmt)
            emitted_types[name] = true
          }
        // Handle re-exports: fetch definitions from source module
        @core.Stmt::ReExport(spec~, source~, span=_) =>
          collect_reexport_defs(db, path, spec, source, out, visited)
        // Skip imports and exports in dependencies
        @core.Stmt::Import(..) | @core.Stmt::Export(..) => ()
        // Skip tests from dependencies
        @core.Stmt::Test(..) | @core.Stmt::Bench(..) => ()
        // Skip trait definitions (no-op in codegen)
        @core.Stmt::TraitDef(..)
        | @core.Stmt::TraitImpl(..)
        | @core.Stmt::InternalTraitDef(..) => ()
        // Include mutable variable definitions
        @core.Stmt::LetMut(..) => out.push(stmt)
        // Other statements are passed through
        _ => out.push(stmt)
      }
    }
  }
}

///|
fn bundle_stmt_type_name(stmt : @core.Stmt) -> String? {
  match stmt {
    @core.Stmt::EnumDef(name~, ..)
    | @core.Stmt::ExportEnumDef(name~, ..)
    | @core.Stmt::TypeAlias(name~, ..)
    | @core.Stmt::ExportTypeAlias(name~, ..)
    | @core.Stmt::StructDef(name~, ..)
    | @core.Stmt::ExportStructDef(name~, ..) => Some(name)
    _ => None
  }
}

///|
fn dedupe_bundle_structural_defs(
  stmts : Array[@core.Stmt],
) -> Array[@core.Stmt] {
  let out : Array[@core.Stmt] = []
  let seen_type_names : Map[String, Bool] = {}
  for stmt in stmts {
    match bundle_stmt_type_name(stmt) {
      Some(name) =>
        if not(seen_type_names.contains(name)) {
          out.push(stmt)
          seen_type_names[name] = true
        }
      None => out.push(stmt)
    }
  }
  out
}

///|
/// Collect definitions for re-export statement.
fn collect_reexport_defs(
  db : VibeDb,
  owner_path : String,
  spec : @core.ImportSpec,
  source : @core.ModuleRef,
  out : Array[@core.Stmt],
  visited : Map[String, Bool],
) -> Unit {
  let normalize_hash_ref = fn(hash : String) {
    if hash.has_prefix("#") && hash.length() > 1 {
      hash.unsafe_substring(start=1, end=hash.length())
    } else {
      hash
    }
  }
  let base_dir = @path.Path(owner_path).dirname().to_string()
  let resolved_from_imports = fn() -> String? {
    for imp in db.imports(owner_path) {
      if import_stmt_matches_spec(base_dir, source, imp) {
        return Some(imp.path)
      }
    }
    None
  }
  // Resolve source module path
  let source_path = match source {
    @core.ModuleRef::Path(path~) =>
      match resolved_from_imports() {
        Some(resolved) => resolved
        None =>
          if path.has_prefix("/") {
            path
          } else {
            @path.Path(base_dir).join(@path.Path(path)).normalize().to_string()
          }
      }
    @core.ModuleRef::Hash(hash~) => "__hash__/" + normalize_hash_ref(hash)
    @core.ModuleRef::Version(name~) =>
      match db.get_source("__ref__/version/" + name) {
        Some(hash_text) => "__hash__/" + normalize_hash_ref(hash_text)
        None => "__missing__/version/" + name
      }
    @core.ModuleRef::Symbol(name~) =>
      match db.get_source("__ref__/symbol/" + name) {
        Some(hash_text) => "__hash__/" + normalize_hash_ref(hash_text)
        None => "__missing__/symbol/" + name
      }
    @core.ModuleRef::Alias(name~) => "__alias__/" + name
    @core.ModuleRef::PinnedPath(path=_, hash~) =>
      "__hash__/" + normalize_hash_ref(hash)
  }
  // Recursively process the source module's dependencies first
  collect_dependency_defs(db, source_path, out, visited)
  // Get the source module AST
  let source_ast = db.ast_with_hash_imports(source_path)
  let requested_items : Map[String, Array[@core.ImportItem]] = {}
  for item in spec.items {
    match requested_items.get(item.name) {
      Some(items) => items.push(item)
      None => requested_items[item.name] = [item]
    }
  }
  let append_value_aliases = fn(source_name : String, span : @core.Span) {
    match requested_items.get(source_name) {
      Some(items) =>
        for item in items {
          let export_name = @core.import_item_local_name(item)
          if item.kind == @core.ImportKind::Value && export_name != source_name {
            out.push(
              @core.Stmt::Let(
                rec=false,
                name=export_name,
                expr=@core.Expr::Ident(name=source_name, span~),
                span~,
              ),
            )
          }
        }
      None => ()
    }
  }
  // Track already-emitted types to avoid duplicates
  let emitted_types : Map[String, Bool] = {}
  for stmt in out {
    match bundle_stmt_type_name(stmt) {
      Some(name) => emitted_types[name] = true
      None => ()
    }
  }
  // Extract matching definitions from source module
  for stmt in source_ast.stmts {
    match stmt {
      @core.Stmt::ExportLet(rec~, name~, expr~, span~) =>
        if requested_items.contains(name) {
          out.push(@core.Stmt::Let(rec~, name~, expr~, span~))
          append_value_aliases(name, span)
        }
      @core.Stmt::ExportEnumDef(name~, params~, ctors~, span~) =>
        if requested_items.contains(name) && not(emitted_types.contains(name)) {
          out.push(@core.Stmt::EnumDef(name~, params~, ctors~, span~))
          emitted_types[name] = true
        }
      @core.Stmt::ExportTypeAlias(name~, params~, target~, span~) =>
        if requested_items.contains(name) && not(emitted_types.contains(name)) {
          out.push(@core.Stmt::TypeAlias(name~, params~, target~, span~))
          emitted_types[name] = true
        }
      @core.Stmt::Let(rec~, name~, expr~, span~) =>
        if requested_items.contains(name) {
          out.push(@core.Stmt::Let(rec~, name~, expr~, span~))
          append_value_aliases(name, span)
        }
      @core.Stmt::EnumDef(name~, params~, ctors~, span~) =>
        if requested_items.contains(name) && not(emitted_types.contains(name)) {
          out.push(@core.Stmt::EnumDef(name~, params~, ctors~, span~))
          emitted_types[name] = true
        }
      @core.Stmt::TypeAlias(name~, params~, target~, span~) =>
        if requested_items.contains(name) && not(emitted_types.contains(name)) {
          out.push(@core.Stmt::TypeAlias(name~, params~, target~, span~))
          emitted_types[name] = true
        }
      @core.Stmt::ExportStructDef(name~, params~, fields~, span~) =>
        if requested_items.contains(name) && not(emitted_types.contains(name)) {
          out.push(@core.Stmt::StructDef(name~, params~, fields~, span~))
          emitted_types[name] = true
        }
      @core.Stmt::StructDef(name~, params~, fields~, span~) =>
        if requested_items.contains(name) && not(emitted_types.contains(name)) {
          out.push(@core.Stmt::StructDef(name~, params~, fields~, span~))
          emitted_types[name] = true
        }
      @core.Stmt::TraitDef(
        name~,
        supertraits~,
        methods~,
        open_impl~,
        exported~,
        span~
      ) =>
        if requested_items.contains(name) {
          out.push(
            @core.Stmt::TraitDef(
              name~,
              supertraits~,
              methods~,
              open_impl~,
              exported~,
              span~,
            ),
          )
        }
      _ => ()
    }
  }
}

///|
/// Demote `let mut` bindings that are never assigned to into plain `let`.
/// This prevents unnecessary ref cell allocation when captured by closures.
fn demote_unused_let_mut(mod_ : @core.Module) -> @core.Module {
  let assigned : Map[String, Bool] = {}
  collect_all_assign_targets_block(mod_, assigned)
  let mut changed = false
  let new_stmts : Array[@core.Stmt] = []
  for stmt in mod_.stmts {
    match stmt {
      @core.Stmt::LetMut(name~, expr~, span~) =>
        if not(assigned.contains(name)) {
          new_stmts.push(@core.Stmt::Let(rec=false, name~, expr~, span~))
          changed = true
        } else {
          new_stmts.push(stmt)
        }
      _ => new_stmts.push(stmt)
    }
  }
  if changed {
    @core.Module::{ stmts: new_stmts }
  } else {
    mod_
  }
}

///|
fn collect_all_assign_targets_block(
  body : @core.Module,
  out : Map[String, Bool],
) -> Unit {
  for stmt in body.stmts {
    collect_all_assign_targets_stmt(stmt, out)
  }
}

///|
fn collect_all_assign_targets_stmt(
  stmt : @core.Stmt,
  out : Map[String, Bool],
) -> Unit {
  match stmt {
    @core.Stmt::Assign(name~, expr~, ..) => {
      out[name] = true
      collect_all_assign_targets_expr(expr, out)
    }
    @core.Stmt::Let(expr~, ..)
    | @core.Stmt::ExportLet(expr~, ..)
    | @core.Stmt::InternalExportLet(expr~, ..)
    | @core.Stmt::LetMut(expr~, ..) =>
      collect_all_assign_targets_expr(expr, out)
    @core.Stmt::Expr(expr~, ..) => collect_all_assign_targets_expr(expr, out)
    @core.Stmt::LetPat(expr~, ..) => collect_all_assign_targets_expr(expr, out)
    @core.Stmt::LetPatElse(expr~, else_body~, ..) => {
      collect_all_assign_targets_expr(expr, out)
      collect_all_assign_targets_block(else_body, out)
    }
    @core.Stmt::IndexAssign(target~, index~, value~, ..) => {
      collect_all_assign_targets_expr(target, out)
      collect_all_assign_targets_expr(index, out)
      collect_all_assign_targets_expr(value, out)
    }
    @core.Stmt::Test(body~, ..) | @core.Stmt::Bench(body~, ..) =>
      collect_all_assign_targets_block(body, out)
    _ => ()
  }
}

///|
fn collect_all_assign_targets_expr(
  expr : @core.Expr,
  out : Map[String, Bool],
) -> Unit {
  match expr {
    @core.Expr::Call(args~, ..) =>
      for arg in args {
        collect_all_assign_targets_expr(arg.expr, out)
      }
    @core.Expr::Tuple(items~, ..) =>
      for item in items {
        collect_all_assign_targets_expr(item, out)
      }
    @core.Expr::TupleIndex(expr~, ..) =>
      collect_all_assign_targets_expr(expr, out)
    @core.Expr::Record(fields~, ..) =>
      for f in fields {
        collect_all_assign_targets_expr(f.expr, out)
      }
    @core.Expr::StructLit(fields~, ..) =>
      for f in fields {
        collect_all_assign_targets_expr(f.expr, out)
      }
    @core.Expr::Array(items~, ..) =>
      for item in items {
        collect_all_assign_targets_expr(item, out)
      }
    @core.Expr::Map(fields~, ..) =>
      for f in fields {
        collect_all_assign_targets_expr(f.expr, out)
      }
    @core.Expr::If(cond~, then_body~, else_body~, ..) => {
      collect_all_assign_targets_expr(cond, out)
      collect_all_assign_targets_block(then_body, out)
      collect_all_assign_targets_block(else_body, out)
    }
    @core.Expr::Block(body~, ..) => collect_all_assign_targets_block(body, out)
    @core.Expr::Match(scrutinee~, arms~, ..) => {
      collect_all_assign_targets_expr(scrutinee, out)
      for arm in arms {
        collect_all_assign_targets_expr(arm.expr, out)
        match arm.cond {
          Some(c) => collect_all_assign_targets_expr(c, out)
          None => ()
        }
      }
    }
    @core.Expr::Handle(body~, arms~, ..) => {
      collect_all_assign_targets_block(body, out)
      for arm in arms {
        collect_all_assign_targets_expr(arm.expr, out)
        match arm.cond {
          Some(c) => collect_all_assign_targets_expr(c, out)
          None => ()
        }
      }
    }
    @core.Expr::Fn(body~, ..) => collect_all_assign_targets_block(body, out)
    @core.Expr::While(cond~, body~, ..) => {
      collect_all_assign_targets_expr(cond, out)
      collect_all_assign_targets_block(body, out)
    }
    @core.Expr::Loop(params~, body~, ..) => {
      for p in params {
        collect_all_assign_targets_expr(p.init, out)
      }
      collect_all_assign_targets_block(body, out)
    }
    @core.Expr::Yield(expr~, ..) => collect_all_assign_targets_expr(expr, out)
    @core.Expr::ForIn(value_name~, index_name~, iterable~, body~, span~) => {
      let desugared = @core.desugar_for_in(
        value_name, index_name, iterable, body, span,
      )
      collect_all_assign_targets_block(desugared, out)
    }
    _ => ()
  }
}
