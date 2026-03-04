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
  bundle_for_wasm_impl(db, path, ast, apply_dce=true, include_test_entries=true)
}

///|
fn bundle_for_wasm_impl(
  db : VibeDb,
  path : String,
  ast : @core.Module,
  apply_dce~ : Bool,
  include_test_entries~ : Bool,
) -> @core.Module {
  let bundled_stmts : Array[@core.Stmt] = []
  let visited : Map[String, Bool] = {}
  // Collect all dependency definitions in topological order
  collect_dependency_defs(db, path, bundled_stmts, visited)
  // Include prelude function definitions so that higher-order functions
  // like array_map, array_filter, array_fold etc. are available in WASM.
  // These are defined as user-level .vibe code using primitive builtins
  // (array_builder, array_builder_push, etc.) that the WASM backend handles.
  // DCE will remove any prelude definitions that aren't actually used.
  let prelude = @checker.prelude_ast()
  for stmt in prelude.stmts {
    match stmt {
      // Include function definitions from prelude
      @core.Stmt::Let(..) => bundled_stmts.push(stmt)
      // Skip trait definitions and impls (not needed for codegen)
      _ => ()
    }
  }
  // Add main module statements (excluding imports and expanding re-exports)
  let base_dir = @path.Path(path).dirname().to_string()
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::Import(..) => () // Skip imports
      @core.Stmt::ReExport(spec~, source~, span=_) =>
        // Expand re-exports in main module
        collect_reexport_defs(
          db, base_dir, spec, source, bundled_stmts, visited,
        )
      _ => bundled_stmts.push(stmt)
    }
  }
  let bundled = @core.Module::{ stmts: bundled_stmts }
  let after_dce = if apply_dce {
    if include_test_entries {
      @pipeline.dce_module_for_tests(bundled)
    } else {
      @pipeline.dce_module(bundled)
    }
  } else {
    bundled
  }
  demote_unused_let_mut(after_dce)
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
    let base_dir = @path.Path(path).dirname().to_string()
    for stmt in dep_ast.stmts {
      match stmt {
        // Convert exports to regular definitions
        @core.Stmt::ExportLet(rec~, name~, expr~, span~) =>
          out.push(@core.Stmt::Let(rec~, name~, expr~, span~))
        @core.Stmt::ExportEnumDef(name~, params~, ctors~, span~) =>
          out.push(@core.Stmt::EnumDef(name~, params~, ctors~, span~))
        @core.Stmt::ExportTypeAlias(name~, params~, target~, span~) =>
          out.push(@core.Stmt::TypeAlias(name~, params~, target~, span~))
        // Also include non-exported definitions that exported ones might depend on
        @core.Stmt::Let(..)
        | @core.Stmt::EnumDef(..)
        | @core.Stmt::TypeAlias(..) => out.push(stmt)
        // Handle re-exports: fetch definitions from source module
        @core.Stmt::ReExport(spec~, source~, span=_) =>
          collect_reexport_defs(db, base_dir, spec, source, out, visited)
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
/// Collect definitions for re-export statement.
fn collect_reexport_defs(
  db : VibeDb,
  base_dir : String,
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
  // Resolve source module path
  let source_path = match source {
    @core.ModuleRef::Path(path~) =>
      if path.has_prefix("/") {
        path
      } else {
        @path.Path(base_dir).join(@path.Path(path)).normalize().to_string()
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
  // Extract matching definitions from source module
  for stmt in source_ast.stmts {
    match stmt {
      @core.Stmt::ExportLet(rec~, name~, expr~, span~) =>
        if requested_items.contains(name) {
          out.push(@core.Stmt::Let(rec~, name~, expr~, span~))
          append_value_aliases(name, span)
        }
      @core.Stmt::ExportEnumDef(name~, params~, ctors~, span~) =>
        if requested_items.contains(name) {
          out.push(@core.Stmt::EnumDef(name~, params~, ctors~, span~))
        }
      @core.Stmt::ExportTypeAlias(name~, params~, target~, span~) =>
        if requested_items.contains(name) {
          out.push(@core.Stmt::TypeAlias(name~, params~, target~, span~))
        }
      @core.Stmt::Let(rec~, name~, expr~, span~) =>
        if requested_items.contains(name) {
          out.push(@core.Stmt::Let(rec~, name~, expr~, span~))
          append_value_aliases(name, span)
        }
      @core.Stmt::EnumDef(name~, params~, ctors~, span~) =>
        if requested_items.contains(name) {
          out.push(@core.Stmt::EnumDef(name~, params~, ctors~, span~))
        }
      @core.Stmt::TypeAlias(name~, params~, target~, span~) =>
        if requested_items.contains(name) {
          out.push(@core.Stmt::TypeAlias(name~, params~, target~, span~))
        }
      @core.Stmt::ExportStructDef(name~, params~, fields~, span~) =>
        if requested_items.contains(name) {
          out.push(@core.Stmt::StructDef(name~, params~, fields~, span~))
        }
      @core.Stmt::StructDef(name~, params~, fields~, span~) =>
        if requested_items.contains(name) {
          out.push(@core.Stmt::StructDef(name~, params~, fields~, span~))
        }
      @core.Stmt::TraitDef(name~, supertraits~, open_impl~, exported~, span~) =>
        if requested_items.contains(name) {
          out.push(
            @core.Stmt::TraitDef(
              name~,
              supertraits~,
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
    @core.Expr::Raise(value~, ..) => collect_all_assign_targets_expr(value, out)
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
