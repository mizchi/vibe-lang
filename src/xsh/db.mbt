///|
/// Incremental xsh database using ripple
pub struct ImportSpec {
  path : String
  alias_name : String
  hash : String?
  module_ref : String?
} derive(Show, Eq)

///|
pub struct XshDb {
  db : @ripple.Database
  rt : @ripple.Runtime
  sources : @ripple.Input[String, String]
  cst_query : @ripple.Query[String, @cst.SyntaxNode]
  ast_query : @ripple.Query[String, HashedModule] // Uses structural hash for Eq
  type_query : @ripple.Query[String, @checker.TypeEnv]
  import_query : @ripple.Query[String, Array[ImportSpec]]
  diags : @ripple.Accumulator[@core.Diagnostic]
}

///|
pub fn XshDb::new() -> XshDb {
  let db = @ripple.Database::new()
  let rt = db.runtime()
  let sources : @ripple.Input[String, String] = db.input()
  sources.register(rt)
  let diags : @ripple.Accumulator[@core.Diagnostic] = db.accumulator()
  let cst_query : @ripple.Query[String, @cst.SyntaxNode] = db.query(fn(
    rt,
    path,
  ) {
    match sources.get(rt, path) {
      Some(content) => @parser.parse_cst(content)
      None => @parser.parse_cst("")
    }
  })
  cst_query.register(rt)
  // AST query wrapped in HashedModule for structural equality comparison
  // This enables backdate when only whitespace changes (same structural hash)
  let ast_query : @ripple.Query[String, HashedModule] = db.query(fn(rt, path) {
    match sources.get(rt, path) {
      Some(content) => {
        let parsed = @parser.parse_ast(content) catch {
          e => {
            diags.push(rt, e.diagnostic())
            { stmts: [] }
          }
        }
        HashedModule::new(parsed)
      }
      None => HashedModule::new({ stmts: [] })
    }
  })
  ast_query.register(rt)
  let import_query : @ripple.Query[String, Array[ImportSpec]] = db.query(fn(
    rt,
    file_path,
  ) {
    let ast = ast_query.fetch(rt, file_path).unwrap()
    let base_dir = @path.Path(file_path).dirname().to_string()
    let out : Array[ImportSpec] = []
    for stmt in ast.stmts {
      match stmt {
        @core.Stmt::Import(source~, span~, ..) => {
          let import_path = match source {
            @core.ModuleRef::Path(path~) => path
            @core.ModuleRef::Hash(hash~) => hash // Use hash as path for now
          }
          // Resolve relative path to absolute
          let resolved_path = if import_path.has_prefix("/") {
            import_path
          } else {
            @path.Path(base_dir)
            .join(@path.Path(import_path))
            .normalize()
            .to_string()
          }
          let alias_name = @core.import_alias_name(import_path)
          // Try resolved path first, then fall back to original import path (for tests)
          let (final_path, content_opt) = match sources.get(rt, resolved_path) {
            Some(c) => (resolved_path, Some(c))
            None =>
              match sources.get(rt, import_path) {
                Some(c) => (import_path, Some(c))
                None => (resolved_path, None)
              }
          }
          match content_opt {
            Some(content) => {
              let hash = @core.git_blob_hash_string(content)
              out.push(ImportSpec::{
                path: final_path,
                alias_name,
                hash: Some(hash),
                module_ref: Some(@core.module_ref_from_hash(hash)),
              })
            }
            None => {
              diags.push(rt, @core.Diagnostic::{
                stage: "import",
                message: "missing: " + resolved_path,
                span: Some(span),
                hint: None,
                note: None,
              })
              out.push(ImportSpec::{
                path: final_path,
                alias_name,
                hash: None,
                module_ref: None,
              })
            }
          }
        }
        _ => ()
      }
    }
    out
  })
  import_query.register(rt)
  // First, create a simple type query that only type checks a single module
  let simple_type_query : @ripple.Query[String, @checker.TypeEnv] = db.query(fn(
    rt,
    path,
  ) {
    let ast = ast_query.fetch(rt, path).unwrap()
    let imports = import_query.fetch(rt, path)
    let aliases = build_alias_map_from_ast(ast, imports)
    let desugared = desugar_method_calls(ast, aliases)
    @checker.type_check_with_aliases(desugared, aliases) catch {
      e => {
        diags.push(rt, e.diagnostic())
        @checker.TypeEnv::new()
      }
    }
  })
  simple_type_query.register(rt)
  // Now create the main type query that handles imports
  let type_query : @ripple.Query[String, @checker.TypeEnv] = db.query(fn(
    rt,
    file_path,
  ) {
    let ast = ast_query.fetch(rt, file_path).unwrap()
    let imports = import_query.fetch(rt, file_path)
    let aliases = build_alias_map_from_ast(ast, imports)
    let desugared = desugar_method_calls(ast, aliases)
    let base_dir = @path.Path(file_path).dirname().to_string()
    // Create base environment with prelude
    let env = @checker.TypeEnv::new()
    let _ = try! @checker.ensure_prelude_option(env)
    let _ = try! @checker.ensure_prelude_functions(env, aliases)
    // Import types from imported modules
    for imp in imports {
      match sources.get(rt, imp.path) {
        None => ()
        Some(_) => {
          // Use simple_type_query to get the imported module's type environment
          let imported_env = simple_type_query.fetch(rt, imp.path)
          // Get the AST of the imported module to find exports
          let imported_ast = ast_query.fetch(rt, imp.path).unwrap()
          let exported_names = collect_exported_names(imported_ast)
          // Now look up the import items in the main AST's Import statement
          for stmt in ast.stmts {
            match stmt {
              @core.Stmt::Import(spec~, source~, ..) => {
                let raw_import_path = match source {
                  @core.ModuleRef::Path(path~) => path
                  @core.ModuleRef::Hash(hash~) => hash
                }
                // Resolve the import path the same way as import_query
                let resolved_import_path = if raw_import_path.has_prefix("/") {
                  raw_import_path
                } else {
                  @path.Path(base_dir)
                  .join(@path.Path(raw_import_path))
                  .normalize()
                  .to_string()
                }
                // Match with resolved path or original path (for tests)
                if resolved_import_path == imp.path ||
                  raw_import_path == imp.path {
                  // For each imported item, copy its type to current env
                  for item in spec.items {
                    let name = item.name
                    let local_name = match item.rename {
                      Some(n) => n
                      None => name
                    }
                    // Only import if the symbol is exported
                    if exported_names.contains(name) {
                      match imported_env.get_scheme(name) {
                        Some(scheme) => env.set_scheme(local_name, scheme)
                        None => ()
                      }
                      // If it's an enum, also import the enum definition and all constructors
                      match imported_env.get_enum_def(name) {
                        Some(enum_def) => {
                          env.set_enum_def(local_name, enum_def)
                          // Import all constructors of this enum
                          for ctor in enum_def.ctors {
                            match imported_env.get_ctor(ctor.name) {
                              Some(ctor_info) =>
                                env.set_ctor(ctor.name, ctor_info)
                              None => ()
                            }
                            // Also import the constructor's scheme
                            match imported_env.get_scheme(ctor.name) {
                              Some(scheme) => env.set_scheme(ctor.name, scheme)
                              None => ()
                            }
                          }
                        }
                        None => ()
                      }
                    }
                  }
                }
              }
              _ => ()
            }
          }
        }
      }
    }
    // Type check with the enriched environment
    @checker.type_check_with_env(env, desugared, aliases) catch {
      e => {
        diags.push(rt, e.diagnostic())
        @checker.TypeEnv::new()
      }
    }
  })
  type_query.register(rt)
  { db, rt, sources, cst_query, ast_query, type_query, import_query, diags }
}

///|
fn collect_exported_names(ast : @core.Module) -> Map[String, Bool] {
  let exports : Map[String, Bool] = {}
  let defined : Map[String, Bool] = {}
  // First pass: collect all definitions
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::Let(name~, ..) | @core.Stmt::LetMut(name~, ..) =>
        defined[name] = true
      @core.Stmt::EnumDef(name~, ..) => defined[name] = true
      @core.Stmt::TypeAlias(name~, ..) => defined[name] = true
      @core.Stmt::ExportLet(name~, ..) => {
        defined[name] = true
        exports[name] = true
      }
      @core.Stmt::ExportEnumDef(name~, ctors~, ..) => {
        defined[name] = true
        exports[name] = true
        // Also export all constructor names
        for ctor in ctors {
          defined[ctor.name] = true
          exports[ctor.name] = true
        }
      }
      @core.Stmt::ExportTypeAlias(name~, ..) => {
        defined[name] = true
        exports[name] = true
      }
      _ => ()
    }
  }
  // Second pass: handle export and re-export statements
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::Export(names~, ..) =>
        for name in names {
          if defined.contains(name) {
            exports[name] = true
          }
        }
      // Re-export: mark names as exported (actual definitions come from source module)
      @core.Stmt::ReExport(names~, ..) =>
        for name in names {
          exports[name] = true
        }
      _ => ()
    }
  }
  exports
}

///|
fn build_alias_map_from_ast(
  ast : @core.Module,
  imports : Array[ImportSpec],
) -> Map[String, @core.Ref] {
  let _ = ast
  let aliases : Map[String, @core.Ref] = {}
  for imp in imports {
    match imp.module_ref {
      Some(m) =>
        aliases[imp.alias_name] = @core.Ref::{ name: m, hash_prefix: None }
      None => ()
    }
  }
  aliases
}

///|
pub fn XshDb::set_source(self : XshDb, path : String, content : String) -> Unit {
  let _ = self.sources.set(self.rt, path, content)

}

///|
pub fn XshDb::cst(self : XshDb, path : String) -> @cst.SyntaxNode {
  self.cst_query.fetch(self.rt, path)
}

///|
pub fn XshDb::ast(self : XshDb, path : String) -> @core.Module {
  self.ast_query.fetch(self.rt, path).unwrap()
}

///|
pub fn XshDb::types(self : XshDb, path : String) -> @checker.TypeEnv {
  self.type_query.fetch(self.rt, path)
}

///|
pub fn XshDb::imports(self : XshDb, path : String) -> Array[ImportSpec] {
  self.import_query.fetch(self.rt, path)
}

///|
pub fn XshDb::get_source(self : XshDb, path : String) -> String? {
  self.sources.get(self.rt, path)
}

///|
/// Build alias map from imports (alias -> module ref)
pub fn XshDb::import_aliases(
  self : XshDb,
  path : String,
) -> Map[String, @core.Ref] {
  let imports = self.import_query.fetch(self.rt, path)
  let aliases : Map[String, @core.Ref] = {}
  for imp in imports {
    match imp.module_ref {
      Some(m) =>
        aliases[imp.alias_name] = @core.Ref::{ name: m, hash_prefix: None }
      None => ()
    }
  }
  aliases
}

///|
/// Collect diagnostics from parse/type stages
pub fn XshDb::diagnostics(
  self : XshDb,
  path : String,
) -> Array[@core.Diagnostic] {
  let parse_diags = self.diags.get_for_query(self.ast_query, path)
  let type_diags = self.diags.get_for_query(self.type_query, path)
  let import_diags = self.diags.get_for_query(self.import_query, path)
  let out : Array[@core.Diagnostic] = []
  for d in parse_diags {
    out.push(d)
  }
  for d in type_diags {
    out.push(d)
  }
  for d in import_diags {
    out.push(d)
  }
  out
}
