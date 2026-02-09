///|
/// Incremental xsh database using ripple
pub struct PathObj {
  raw : String
  base : String
  normalized : String
} derive(Show, Eq)

///|
/// Resolved import metadata used by compile/type phases.
pub struct ImportSpec {
  path : String
  alias_name : String
  hash : String?
  module_ref : String?
  path_obj : PathObj?
  source_hash : String?
  source_version : String?
  source_symbol : String?
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
fn array_has_string(xs : Array[String], needle : String) -> Bool {
  for x in xs {
    if x == needle {
      return true
    }
  }
  false
}

///|
fn collect_import_trait_aliases(
  spec : @core.ImportSpec,
  imported_env : @checker.TypeEnv,
) -> Map[String, String] {
  let out : Map[String, String] = {}
  for item in spec.items {
    if import_item_accepts_trait(item) && imported_env.has_trait(item.name) {
      let local_name = match item.rename {
        Some(rename) => rename
        None => item.name
      }
      out[item.name] = local_name
    }
  }
  out
}

///|
fn import_item_accepts_value(item : @core.ImportItem, name : String) -> Bool {
  item.kind == @core.ImportKind::Value ||
  (item.kind == @core.ImportKind::Type && name.contains("::"))
}

///|
fn import_item_accepts_type(item : @core.ImportItem) -> Bool {
  item.kind == @core.ImportKind::Value || item.kind == @core.ImportKind::Type
}

///|
fn import_item_accepts_trait(item : @core.ImportItem) -> Bool {
  item.kind == @core.ImportKind::Value || item.kind == @core.ImportKind::Trait
}

///|
fn import_kind_expected_label(kind : @core.ImportKind) -> String {
  match kind {
    @core.ImportKind::Value => "value"
    @core.ImportKind::Type => "type"
    @core.ImportKind::Trait => "trait"
  }
}

///|
fn resolve_imported_trait_supertraits(
  source_name : String,
  local_name : String,
  source_supertraits : Array[String],
  trait_aliases : Map[String, String],
) -> Array[String] {
  let out : Array[String] = []
  for supertrait in source_supertraits {
    let local_super = match trait_aliases.get(supertrait) {
      Some(alias_name) => alias_name
      None => supertrait
    }
    if not(array_has_string(out, local_super)) {
      out.push(local_super)
    }
  }
  if local_name != source_name && not(array_has_string(out, source_name)) {
    // Preserve canonical source relation so renamed traits still satisfy
    // built-in canonical bounds like Eq/Ord.
    out.push(source_name)
  }
  out
}

///|
fn maybe_add_trait_impl(
  env : @checker.TypeEnv,
  trait_name : String,
  impl_def : @checker.TraitImplDef,
) -> Unit {
  for existing in env.trait_impls_for(trait_name) {
    if existing == impl_def {
      return
    }
  }
  env.add_trait_impl(trait_name, impl_def)
}

///|
fn impl_target_root_name(ty : @core.Type) -> String? {
  match ty {
    @core.Type::Named(name~, ..) => Some(name)
    _ => None
  }
}

///|
fn import_trait_impls_for_type(
  env : @checker.TypeEnv,
  imported_env : @checker.TypeEnv,
  source_type_name : String,
  trait_aliases : Map[String, String],
) -> Unit {
  for source_trait_name in imported_env.trait_names() {
    let local_trait_name = match trait_aliases.get(source_trait_name) {
      Some(alias_name) => alias_name
      None => source_trait_name
    }
    if env.has_trait(local_trait_name) {
      for impl_def in imported_env.trait_impls_for(source_trait_name) {
        match impl_target_root_name(impl_def.target) {
          Some(root_name) =>
            if root_name == source_type_name {
              maybe_add_trait_impl(env, local_trait_name, impl_def)
            }
          None => ()
        }
      }
    }
  }
}

///|
fn hash_source_key(hash : String) -> String {
  "__hash__/" + hash
}

///|
fn version_ref_key(name : String) -> String {
  "__ref__/version/" + name
}

///|
fn symbol_ref_key(name : String) -> String {
  "__ref__/symbol/" + name
}

///|
fn path_ref_key(path : String) -> String {
  "__ref__/path/" + path
}

///|
fn require_path_lock_config_key() -> String {
  "__config__/require_path_lock"
}

///|
fn normalize_lock_path(path : String) -> String {
  @path.Path(path).normalize().to_string()
}

///|
fn path_lock_required(
  rt : @ripple.Runtime,
  sources : @ripple.Input[String, String],
) -> Bool {
  match sources.get(rt, require_path_lock_config_key()) {
    Some(flag) => flag == "1"
    None => false
  }
}

///|
fn normalize_hash(hash : String) -> String {
  if hash.has_prefix("#") && hash.length() > 1 {
    hash.unsafe_substring(start=1, end=hash.length())
  } else {
    hash
  }
}

///|
fn sanitize_alias(name : String) -> String {
  let buf = StringBuilder::new()
  for c in name {
    let ok = (c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') ||
      (c >= '0' && c <= '9') ||
      c == '_'
    if ok {
      buf.write_char(c)
    } else {
      buf.write_char('_')
    }
  }
  let out = buf.to_string()
  if out.length() == 0 {
    "ref"
  } else {
    out
  }
}

///|
fn hash_alias_name(hash : String) -> String {
  let short = if hash.length() > 8 {
    hash.unsafe_substring(start=0, end=8)
  } else {
    hash
  }
  "hash_" + short
}

///|
fn version_alias_name(name : String) -> String {
  "version_" + sanitize_alias(name)
}

///|
fn symbol_alias_name(name : String) -> String {
  "symbol_" + sanitize_alias(name)
}

///|
fn normalize_path_obj(base_dir : String, raw_path : String) -> PathObj {
  let normalized = if raw_path.has_prefix("/") {
    @path.Path(raw_path).normalize().to_string()
  } else {
    @path.Path(base_dir).join(@path.Path(raw_path)).normalize().to_string()
  }
  PathObj::{ raw: raw_path, base: base_dir, normalized }
}

///|
fn resolve_hash_import(
  rt : @ripple.Runtime,
  sources : @ripple.Input[String, String],
  diags : @ripple.Accumulator[@core.Diagnostic],
  hash_text : String,
  span : @core.Span,
) -> (String, String?) {
  let hash = normalize_hash(hash_text)
  let snapshot_key = hash_source_key(hash)
  match sources.get(rt, snapshot_key) {
    Some(content) => {
      let actual_hash = @core.git_blob_hash_string(content)
      if actual_hash == hash {
        (snapshot_key, Some(hash))
      } else {
        diags.push(rt, @core.Diagnostic::{
          stage: "import",
          message: "hash mismatch: expected " + hash + ", got " + actual_hash,
          span: Some(span),
          hint: None,
          note: None,
        })
        (snapshot_key, None)
      }
    }
    None => {
      diags.push(rt, @core.Diagnostic::{
        stage: "import",
        message: "missing hash import: " + hash,
        span: Some(span),
        hint: None,
        note: None,
      })
      (snapshot_key, None)
    }
  }
}

///|
fn import_stmt_matches_spec(
  base_dir : String,
  source : @core.ModuleRef,
  imp : ImportSpec,
) -> Bool {
  match source {
    @core.ModuleRef::Path(path~) => {
      let path_obj = normalize_path_obj(base_dir, path)
      if path_obj.normalized == imp.path || path == imp.path {
        true
      } else {
        match imp.path_obj {
          Some(obj) => obj.normalized == path_obj.normalized || obj.raw == path
          None => false
        }
      }
    }
    @core.ModuleRef::Hash(hash~) =>
      match imp.source_hash {
        Some(source_hash) => source_hash == hash
        None => false
      }
    @core.ModuleRef::Version(name~) =>
      match imp.source_version {
        Some(source_version) => source_version == name
        None => false
      }
    @core.ModuleRef::Symbol(name~) =>
      match imp.source_symbol {
        Some(source_symbol) => source_symbol == name
        None => false
      }
  }
}

///|
fn stack_index_of_path(stack : Array[String], path : String) -> Int? {
  for i, p in stack {
    if p == path {
      return Some(i)
    }
  }
  None
}

///|
fn cycle_path_from_stack(
  stack : Array[String],
  start_idx : Int,
) -> Array[String] {
  let out : Array[String] = []
  for i in start_idx..<stack.length() {
    out.push(stack[i])
  }
  if start_idx >= 0 && start_idx < stack.length() {
    out.push(stack[start_idx])
  }
  out
}

///|
fn render_import_cycle(cycle : Array[String]) -> String {
  let mut out = ""
  for i, p in cycle {
    if i > 0 {
      out += " -> "
    }
    out += p
  }
  out
}

///|
fn detect_import_cycle_from(
  rt : @ripple.Runtime,
  sources : @ripple.Input[String, String],
  ast_query : @ripple.Query[String, HashedModule],
  path : String,
  stack : Array[String],
  done : Map[String, Bool],
) -> Array[String]? {
  match stack_index_of_path(stack, path) {
    Some(idx) => return Some(cycle_path_from_stack(stack, idx))
    None => ()
  }
  if done.contains(path) {
    return None
  }
  stack.push(path)
  let ast = ast_query.fetch(rt, path).unwrap()
  let base_dir = @path.Path(path).dirname().to_string()
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::Import(source~, ..) =>
        match source {
          @core.ModuleRef::Path(path=raw_path) => {
            let path_obj = normalize_path_obj(base_dir, raw_path)
            let next_path = match sources.get(rt, path_obj.normalized) {
              Some(_) => Some(path_obj.normalized)
              None =>
                match sources.get(rt, raw_path) {
                  Some(_) => Some(raw_path)
                  None => None
                }
            }
            match next_path {
              Some(next) =>
                match
                  detect_import_cycle_from(
                    rt, sources, ast_query, next, stack, done,
                  ) {
                  Some(cycle) => return Some(cycle)
                  None => ()
                }
              None => ()
            }
          }
          _ => ()
        }
      _ => ()
    }
  }
  let _ = stack.pop()
  done[path] = true
  None
}

///|
fn detect_import_cycle(
  rt : @ripple.Runtime,
  sources : @ripple.Input[String, String],
  ast_query : @ripple.Query[String, HashedModule],
  root_path : String,
) -> Array[String]? {
  let stack : Array[String] = []
  let done : Map[String, Bool] = {}
  detect_import_cycle_from(rt, sources, ast_query, root_path, stack, done)
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
    let mut has_imports = false
    for stmt in ast.stmts {
      match stmt {
        @core.Stmt::Import(source~, span~, ..) => {
          has_imports = true
          match source {
            @core.ModuleRef::Path(path~) => {
              let path_obj = normalize_path_obj(base_dir, path)
              let alias_name = @core.import_alias_name(path)
              // Try normalized path first, then fall back to raw import path (for tests).
              let (final_path, content_opt) = match
                sources.get(rt, path_obj.normalized) {
                Some(c) => (path_obj.normalized, Some(c))
                None =>
                  match sources.get(rt, path) {
                    Some(c) => (path, Some(c))
                    None => (path_obj.normalized, None)
                  }
              }
              match content_opt {
                Some(content) => {
                  let hash = @core.git_blob_hash_string(content)
                  let mut resolved_hash : String? = Some(hash)
                  let mut module_ref : String? = Some(
                    @core.module_ref_from_hash(hash),
                  )
                  if path_lock_required(rt, sources) {
                    match sources.get(rt, path_ref_key(path_obj.normalized)) {
                      Some(expected_hash_text) => {
                        let expected_hash = normalize_hash(expected_hash_text)
                        if expected_hash != hash {
                          diags.push(rt, @core.Diagnostic::{
                            stage: "import",
                            message: "lock mismatch for path: " +
                            path_obj.normalized +
                            " (expected " +
                            expected_hash +
                            ", got " +
                            hash +
                            ")",
                            span: Some(span),
                            hint: Some(
                              "run `xsh fetch <entry>` to refresh xsh.lock",
                            ),
                            note: None,
                          })
                          resolved_hash = None
                          module_ref = None
                        }
                      }
                      None => {
                        diags.push(rt, @core.Diagnostic::{
                          stage: "import",
                          message: "missing lock entry for path: " +
                          path_obj.normalized,
                          span: Some(span),
                          hint: Some(
                            "run `xsh fetch <entry>` to create xsh.lock",
                          ),
                          note: None,
                        })
                        resolved_hash = None
                        module_ref = None
                      }
                    }
                  }
                  out.push(ImportSpec::{
                    path: final_path,
                    alias_name,
                    hash: resolved_hash,
                    module_ref,
                    path_obj: Some(path_obj),
                    source_hash: None,
                    source_version: None,
                    source_symbol: None,
                  })
                }
                None => {
                  diags.push(rt, @core.Diagnostic::{
                    stage: "import",
                    message: "missing: " + path_obj.normalized,
                    span: Some(span),
                    hint: None,
                    note: None,
                  })
                  out.push(ImportSpec::{
                    path: final_path,
                    alias_name,
                    hash: None,
                    module_ref: None,
                    path_obj: Some(path_obj),
                    source_hash: None,
                    source_version: None,
                    source_symbol: None,
                  })
                }
              }
            }
            @core.ModuleRef::Hash(hash~) => {
              let alias_name = hash_alias_name(hash)
              let (snapshot_key, resolved_hash) = resolve_hash_import(
                rt, sources, diags, hash, span,
              )
              out.push(ImportSpec::{
                path: snapshot_key,
                alias_name,
                hash: resolved_hash,
                module_ref: match resolved_hash {
                  Some(h) => Some(@core.module_ref_from_hash(h))
                  None => None
                },
                path_obj: None,
                source_hash: Some(normalize_hash(hash)),
                source_version: None,
                source_symbol: None,
              })
            }
            @core.ModuleRef::Version(name~) => {
              let alias_name = version_alias_name(name)
              match sources.get(rt, version_ref_key(name)) {
                Some(hash_text) => {
                  let (snapshot_key, resolved_hash) = resolve_hash_import(
                    rt, sources, diags, hash_text, span,
                  )
                  out.push(ImportSpec::{
                    path: snapshot_key,
                    alias_name,
                    hash: resolved_hash,
                    module_ref: match resolved_hash {
                      Some(h) => Some(@core.module_ref_from_hash(h))
                      None => None
                    },
                    path_obj: None,
                    source_hash: None,
                    source_version: Some(name),
                    source_symbol: None,
                  })
                }
                None => {
                  diags.push(rt, @core.Diagnostic::{
                    stage: "import",
                    message: "missing version ref: " + name,
                    span: Some(span),
                    hint: None,
                    note: None,
                  })
                  out.push(ImportSpec::{
                    path: version_ref_key(name),
                    alias_name,
                    hash: None,
                    module_ref: None,
                    path_obj: None,
                    source_hash: None,
                    source_version: Some(name),
                    source_symbol: None,
                  })
                }
              }
            }
            @core.ModuleRef::Symbol(name~) => {
              let alias_name = symbol_alias_name(name)
              match sources.get(rt, symbol_ref_key(name)) {
                Some(hash_text) => {
                  let (snapshot_key, resolved_hash) = resolve_hash_import(
                    rt, sources, diags, hash_text, span,
                  )
                  out.push(ImportSpec::{
                    path: snapshot_key,
                    alias_name,
                    hash: resolved_hash,
                    module_ref: match resolved_hash {
                      Some(h) => Some(@core.module_ref_from_hash(h))
                      None => None
                    },
                    path_obj: None,
                    source_hash: None,
                    source_version: None,
                    source_symbol: Some(name),
                  })
                }
                None => {
                  diags.push(rt, @core.Diagnostic::{
                    stage: "import",
                    message: "missing symbol ref: " + name,
                    span: Some(span),
                    hint: None,
                    note: None,
                  })
                  out.push(ImportSpec::{
                    path: symbol_ref_key(name),
                    alias_name,
                    hash: None,
                    module_ref: None,
                    path_obj: None,
                    source_hash: None,
                    source_version: None,
                    source_symbol: Some(name),
                  })
                }
              }
            }
          }
        }
        _ => ()
      }
    }
    if has_imports {
      match detect_import_cycle(rt, sources, ast_query, file_path) {
        Some(cycle) =>
          diags.push(rt, @core.Diagnostic::{
            stage: "import",
            message: "import cycle: " + render_import_cycle(cycle),
            span: None,
            hint: Some("break the cycle by extracting shared definitions"),
            note: None,
          })
        None => ()
      }
    }
    out
  })
  import_query.register(rt)
  let no_import_type_query : @ripple.Query[String, @checker.TypeEnv?] = db.query(fn(
      rt,
      hash,
    ) {
      match sources.get(rt, hash_source_key(hash)) {
        None => None
        Some(content) => {
          let ast_opt = try @parser.parse_ast(content) catch {
            _ => None
          } noraise {
            ast => Some(ast)
          }
          match ast_opt {
            None => None
            Some(ast) => {
              let mut has_import = false
              for stmt in ast.stmts {
                match stmt {
                  @core.Stmt::Import(..) => has_import = true
                  _ => ()
                }
              }
              if has_import {
                None
              } else {
                let desugared = desugar_method_calls(ast, {})
                let env = try
                  @checker.type_check_with_aliases(desugared, {})
                catch {
                  _ => None
                } noraise {
                  typed => Some(typed)
                }
                env
              }
            }
          }
        }
      }
    },
  )
  no_import_type_query.register(rt)
  // First, create a simple type query that only type checks a single module
  let simple_type_query : @ripple.Query[String, @checker.TypeEnv] = db.query(fn(
    rt,
    path,
  ) {
    match sources.get(rt, path) {
      None => @checker.TypeEnv::new()
      Some(content) =>
        if not(content.contains("import")) {
          let hash = @core.git_blob_hash_string(content)
          match no_import_type_query.fetch(rt, hash) {
            Some(env) => env
            None => {
              let imports = import_query.fetch(rt, path)
              let ast = ast_query.fetch(rt, path).unwrap()
              let aliases = build_alias_map_from_ast(ast, imports)
              let desugared = desugar_method_calls(ast, aliases)
              let env = try! @checker.get_cached_prelude_env_for_module()
              @checker.type_check_with_env(env, desugared, aliases) catch {
                e => {
                  diags.push(rt, e.diagnostic())
                  @checker.TypeEnv::new()
                }
              }
            }
          }
        } else {
          let imports = import_query.fetch(rt, path)
          let ast = ast_query.fetch(rt, path).unwrap()
          let aliases = build_alias_map_from_ast(ast, imports)
          let desugared = desugar_method_calls(ast, aliases)
          let env = try! @checker.get_cached_prelude_env_for_module()
          @checker.type_check_with_env(env, desugared, aliases) catch {
            e => {
              diags.push(rt, e.diagnostic())
              @checker.TypeEnv::new()
            }
          }
        }
    }
  })
  simple_type_query.register(rt)
  // Now create the main type query that handles imports
  let type_query : @ripple.Query[String, @checker.TypeEnv] = db.query(fn(
    rt,
    file_path,
  ) {
    match sources.get(rt, file_path) {
      Some(content) =>
        if not(content.contains("import")) {
          return simple_type_query.fetch(rt, file_path)
        }
      None => ()
    }
    let imports = import_query.fetch(rt, file_path)
    if imports.length() == 0 {
      return simple_type_query.fetch(rt, file_path)
    }
    let ast = ast_query.fetch(rt, file_path).unwrap()
    let aliases = build_alias_map_from_ast(ast, imports)
    let desugared = desugar_method_calls(ast, aliases)
    let base_dir = @path.Path(file_path).dirname().to_string()
    let env = try! @checker.get_cached_prelude_env_for_module()
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
              @core.Stmt::Import(spec~, source~, span~) =>
                if import_stmt_matches_spec(base_dir, source, imp) {
                  let trait_aliases = collect_import_trait_aliases(
                    spec, imported_env,
                  )
                  let import_symbol = fn(
                    item : @core.ImportItem,
                    source_name : String,
                    target_name : String,
                  ) -> Bool {
                    let mut imported_any = false
                    if import_item_accepts_trait(item) &&
                      imported_env.has_trait(source_name) {
                      let local_supertraits = resolve_imported_trait_supertraits(
                        source_name,
                        target_name,
                        imported_env.trait_supertraits(source_name),
                        trait_aliases,
                      )
                      env.import_trait(
                        target_name,
                        imported_env.trait_is_open(source_name),
                        local_supertraits,
                      )
                      let impls = imported_env.trait_impls_for(source_name)
                      for impl_def in impls {
                        env.add_trait_impl(target_name, impl_def)
                      }
                      imported_any = true
                    }
                    if import_item_accepts_value(item, source_name) {
                      match imported_env.get_scheme(source_name) {
                        Some(scheme) => {
                          env.set_scheme(target_name, scheme)
                          imported_any = true
                        }
                        None => ()
                      }
                    }
                    if import_item_accepts_type(item) {
                      match imported_env.get_type_alias(source_name) {
                        Some(type_alias) => {
                          env.set_type_alias(target_name, type_alias)
                          imported_any = true
                        }
                        None => ()
                      }
                    }
                    // If it's an enum, also import the enum definition and all constructors.
                    // Constructors always keep canonical names.
                    if import_item_accepts_type(item) {
                      match imported_env.get_enum_def(source_name) {
                        Some(enum_def) => {
                          env.set_enum_def(target_name, enum_def)
                          imported_any = true
                          import_trait_impls_for_type(
                            env, imported_env, source_name, trait_aliases,
                          )
                          for ctor in enum_def.ctors {
                            match imported_env.get_ctor(ctor.name) {
                              Some(ctor_info) =>
                                env.set_ctor(ctor.name, ctor_info)
                              None => ()
                            }
                            match imported_env.get_scheme(ctor.name) {
                              Some(scheme) => env.set_scheme(ctor.name, scheme)
                              None => ()
                            }
                          }
                        }
                        None => ()
                      }
                    }
                    imported_any
                  }
                  let report_kind_mismatch = fn(
                    item : @core.ImportItem,
                    name : String,
                  ) {
                    if item.kind == @core.ImportKind::Value {
                      return
                    }
                    diags.push(rt, @core.Diagnostic::{
                      stage: "import",
                      message: "expected " +
                      import_kind_expected_label(item.kind) +
                      " export: " +
                      name,
                      span: Some(span),
                      hint: None,
                      note: None,
                    })
                  }
                  // For each imported item, copy symbols by declared kind.
                  for item in spec.items {
                    let name = item.name
                    let local_name = match item.rename {
                      Some(n) => n
                      None => name
                    }
                    if exported_names.contains(name) {
                      if not(import_symbol(item, name, local_name)) {
                        report_kind_mismatch(item, name)
                      }
                    } else if item.rename is None {
                      // Namespace import: `import { Int }` or `import { type Int }`
                      // brings all `Int::...` exports.
                      let prefix = name + "::"
                      let mut imported_any = false
                      for exported_name, _ in exported_names {
                        if exported_name.has_prefix(prefix) {
                          imported_any = true
                          if not(import_symbol(item, exported_name, exported_name)) {
                            report_kind_mismatch(item, exported_name)
                          }
                        }
                      }
                      if item.kind != @core.ImportKind::Value && not(imported_any) {
                        report_kind_mismatch(item, name)
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
  let mut has_late_exports = false
  // First pass: collect all definitions
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::Let(name~, ..) | @core.Stmt::LetMut(name~, ..) =>
        defined[name] = true
      @core.Stmt::EnumDef(name~, ..) => defined[name] = true
      @core.Stmt::TypeAlias(name~, ..) => defined[name] = true
      @core.Stmt::TraitDef(name~, exported~, ..) => {
        defined[name] = true
        if exported {
          exports[name] = true
        }
      }
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
      @core.Stmt::Export(..) | @core.Stmt::ReExport(..) =>
        has_late_exports = true
      _ => ()
    }
  }
  if not(has_late_exports) {
    return exports
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
fn rewrite_import_sources(
  ast : @core.Module,
  imports : Array[ImportSpec],
) -> @core.Module {
  let stmts : Array[@core.Stmt] = []
  let mut import_idx = 0
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::Import(spec~, source~, span~) => {
        let _ = source
        let next_stmt = if import_idx < imports.length() {
          let resolved = imports[import_idx]
          import_idx += 1
          match resolved.hash {
            Some(hash) =>
              @core.Stmt::Import(
                spec~,
                source=@core.ModuleRef::Hash(hash~),
                span~,
              )
            None => stmt
          }
        } else {
          stmt
        }
        stmts.push(next_stmt)
      }
      _ => stmts.push(stmt)
    }
  }
  @core.Module::{ stmts, }
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
  let hash = @core.git_blob_hash_string(content)
  let _ = self.sources.set(self.rt, hash_source_key(hash), content)

}

///|
pub fn XshDb::set_version_ref(
  self : XshDb,
  name : String,
  hash : String,
) -> Unit {
  let _ = self.sources.set(self.rt, version_ref_key(name), normalize_hash(hash))

}

///|
pub fn XshDb::set_path_ref(self : XshDb, path : String, hash : String) -> Unit {
  let normalized = normalize_lock_path(path)
  let _ = self.sources.set(
    self.rt,
    path_ref_key(normalized),
    normalize_hash(hash),
  )

}

///|
pub fn XshDb::require_path_lock(self : XshDb, required : Bool) -> Unit {
  let value = if required { "1" } else { "0" }
  let _ = self.sources.set(self.rt, require_path_lock_config_key(), value)

}

///|
pub fn XshDb::set_symbol_ref(
  self : XshDb,
  name : String,
  hash : String,
) -> Unit {
  let _ = self.sources.set(self.rt, symbol_ref_key(name), normalize_hash(hash))

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
pub fn XshDb::ast_with_hash_imports(
  self : XshDb,
  path : String,
) -> @core.Module {
  rewrite_import_sources(self.ast(path), self.import_query.fetch(self.rt, path))
}

///|
pub fn XshDb::rewrite_imports_to_hash(
  self : XshDb,
  path : String,
  ast : @core.Module,
) -> @core.Module {
  rewrite_import_sources(ast, self.import_query.fetch(self.rt, path))
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

///|
/// Collect non-fatal diagnostics such as warnings.
pub fn XshDb::warnings(self : XshDb, path : String) -> Array[@core.Diagnostic] {
  let ast = self.ast_query.fetch(self.rt, path).unwrap()
  @checker.collect_warnings(ast)
}
