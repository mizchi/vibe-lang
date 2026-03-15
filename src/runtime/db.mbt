///|
/// Incremental vibe database using ripple
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
pub struct VibeDbInputs {
  sources : @ripple.Input[String, String]
  binary_sources : @ripple.Input[String, Bytes]
  preparsed_ast_hashes : @ripple.Input[String, String]
  preparsed_asts : @ripple.Input[String, HashedModule]
  preparsed_import_hashes : @ripple.Input[String, String]
  preparsed_imports : @ripple.Input[String, Array[ImportSpec]]
}

///|
pub struct VibeDbQueries {
  cst_query : @ripple.Query[String, @cst.SyntaxNode]
  ast_query : @ripple.Query[String, HashedModule] // Uses structural hash for Eq
  type_query : @ripple.Query[String, @checker.TypeEnv]
  simple_type_query : @ripple.Query[String, @checker.TypeEnv]
  import_query : @ripple.Query[String, Array[ImportSpec]]
}

///|
pub struct VibeDbDiagnosticStore {
  diags : @ripple.Accumulator[@core.Diagnostic]
}

///|
pub struct VibeDb {
  db : @ripple.Database
  rt : @ripple.Runtime
  inputs : VibeDbInputs
  queries : VibeDbQueries
  diagnostics : VibeDbDiagnosticStore
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
    @core.ImportKind::Module => "module namespace"
  }
}

///|
fn supports_module_namespace_import(path : String) -> Bool {
  path.has_suffix(".xm")
}

///|
fn collect_pat_bind_names(
  pat : @core.Pat,
  out : Map[String, @core.Span],
) -> Unit {
  match pat {
    @core.Pat::Bind(name~, span~) =>
      if name != "_" && not(out.contains(name)) {
        out[name] = span
      }
    @core.Pat::Ctor(args~, ..) =>
      for arg in args {
        collect_pat_bind_names(arg, out)
      }
    @core.Pat::Tuple(items~, ..) =>
      for item in items {
        collect_pat_bind_names(item, out)
      }
    @core.Pat::Record(fields~, ..) =>
      for field in fields {
        collect_pat_bind_names(field.pat, out)
      }
    @core.Pat::Struct(fields~, ..) =>
      for field in fields {
        collect_pat_bind_names(field.pat, out)
      }
    @core.Pat::Or(pats~, ..) =>
      for p in pats {
        collect_pat_bind_names(p, out)
      }
    _ => ()
  }
}

///|
fn collect_local_value_decl_spans(
  ast : @core.Module,
) -> Map[String, @core.Span] {
  let out : Map[String, @core.Span] = {}
  let collect_name = fn(name : String, span : @core.Span) {
    if name != "_" && not(out.contains(name)) {
      out[name] = span
    }
  }
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::Let(rec~, name~, expr~, span~) => {
        let _ = rec
        let _ = expr
        collect_name(name, span)
      }
      @core.Stmt::ExportLet(rec~, name~, expr~, span~) => {
        let _ = rec
        let _ = expr
        collect_name(name, span)
      }
      @core.Stmt::LetMut(name~, expr~, span~) => {
        let _ = expr
        collect_name(name, span)
      }
      @core.Stmt::LetPat(pat~, expr~, span~) => {
        let _ = expr
        let _ = span
        collect_pat_bind_names(pat, out)
      }
      @core.Stmt::LetPatElse(pat~, expr~, else_body~, span~) => {
        let _ = expr
        let _ = else_body
        let _ = span
        collect_pat_bind_names(pat, out)
      }
      _ => ()
    }
  }
  out
}

///|
pub fn VibeDb::set_source(
  self : VibeDb,
  path : String,
  content : String,
) -> Unit {
  let _ = self.inputs.sources.set(self.rt, path, content)
  let hash = @core.content_address_hash_string(content)
  let _ = self.inputs.sources.set(self.rt, hash_source_key(hash), content)
}

///|
pub fn VibeDb::set_preparsed_ast(
  self : VibeDb,
  path : String,
  content : String,
  ast : @core.Module,
) -> Unit {
  let hash = @core.content_address_hash_string(content)
  let _ = self.inputs.preparsed_ast_hashes.set(self.rt, path, hash)
  let _ = self.inputs.preparsed_asts.set(self.rt, path, HashedModule::new(ast))
}

///|
pub fn VibeDb::set_preparsed_imports(
  self : VibeDb,
  path : String,
  content : String,
  imports : Array[ImportSpec],
) -> Unit {
  let hash = @core.content_address_hash_string(content)
  let _ = self.inputs.preparsed_import_hashes.set(self.rt, path, hash)
  let _ = self.inputs.preparsed_imports.set(self.rt, path, imports)
}

///|
pub fn make_import_spec(
  path : String,
  alias_name : String,
  hash : String?,
  module_ref : String?,
  source_hash : String?,
  source_version : String?,
  source_symbol : String?,
) -> ImportSpec {
  ImportSpec::{
    path,
    alias_name,
    hash,
    module_ref,
    path_obj: None,
    source_hash,
    source_version,
    source_symbol,
  }
}

///|
pub fn VibeDb::set_binary_source(
  self : VibeDb,
  path : String,
  content : Bytes,
) -> Unit {
  let _ = self.inputs.binary_sources.set(self.rt, path, content)
  let hash = @core.git_blob_hash_bytes(content)
  let _ = self.inputs.binary_sources.set(
    self.rt,
    hash_source_key(hash),
    content,
  )
}

///|
pub fn VibeDb::set_version_ref(
  self : VibeDb,
  name : String,
  hash : String,
) -> Unit {
  let _ = self.inputs.sources.set(
    self.rt,
    version_ref_key(name),
    normalize_hash(hash),
  )
}

///|
pub fn VibeDb::set_path_ref(
  self : VibeDb,
  path : String,
  hash : String,
) -> Unit {
  let normalized = normalize_lock_path(path)
  let _ = self.inputs.sources.set(
    self.rt,
    path_ref_key(normalized),
    normalize_hash(hash),
  )
}

///|
pub fn VibeDb::require_path_lock(self : VibeDb, required : Bool) -> Unit {
  let value = if required { "1" } else { "0" }
  let _ = self.inputs.sources.set(
    self.rt,
    require_path_lock_config_key(),
    value,
  )
}

///|
pub fn VibeDb::set_symbol_ref(
  self : VibeDb,
  name : String,
  hash : String,
) -> Unit {
  let _ = self.inputs.sources.set(
    self.rt,
    symbol_ref_key(name),
    normalize_hash(hash),
  )
}

///|
fn VibeDb::cst(self : VibeDb, path : String) -> @cst.SyntaxNode {
  self.queries.cst_query.fetch(self.rt, path)
}

///|
pub fn VibeDb::ast(self : VibeDb, path : String) -> @core.Module {
  self.queries.ast_query.fetch(self.rt, path).unwrap()
}

///|
pub fn VibeDb::ast_with_hash_imports(
  self : VibeDb,
  path : String,
) -> @core.Module {
  rewrite_import_sources(
    self.ast(path),
    self.queries.import_query.fetch(self.rt, path),
  )
}

///|
pub fn VibeDb::rewrite_imports_to_hash(
  self : VibeDb,
  path : String,
  ast : @core.Module,
) -> @core.Module {
  rewrite_import_sources(ast, self.queries.import_query.fetch(self.rt, path))
}

///|
pub fn VibeDb::types(self : VibeDb, path : String) -> @checker.TypeEnv {
  self.queries.type_query.fetch(self.rt, path)
}

///|
pub fn VibeDb::imports(self : VibeDb, path : String) -> Array[ImportSpec] {
  self.queries.import_query.fetch(self.rt, path)
}

///|
pub fn VibeDb::get_source(self : VibeDb, path : String) -> String? {
  self.inputs.sources.get(self.rt, path)
}

///|
/// Collect diagnostics from parse/type stages
pub fn VibeDb::diagnostics(
  self : VibeDb,
  path : String,
) -> Array[@core.Diagnostic] {
  let parse_diags = self.diagnostics.diags.get_for_query(
    self.queries.ast_query,
    path,
  )
  let type_diags = self.diagnostics.diags.get_for_query(
    self.queries.type_query,
    path,
  )
  let simple_type_diags = self.diagnostics.diags.get_for_query(
    self.queries.simple_type_query,
    path,
  )
  let import_diags = self.diagnostics.diags.get_for_query(
    self.queries.import_query,
    path,
  )
  let out : Array[@core.Diagnostic] = []
  for d in parse_diags {
    out.push(d)
  }
  for d in type_diags {
    out.push(d)
  }
  for d in simple_type_diags {
    out.push(d)
  }
  for d in import_diags {
    out.push(d)
  }
  out
}

///|
/// Collect diagnostics from import stage only (does not trigger type_query).
pub fn VibeDb::import_diagnostics(
  self : VibeDb,
  path : String,
) -> Array[@core.Diagnostic] {
  self.diagnostics.diags.get_for_query(self.queries.import_query, path)
}

///|
/// Collect non-fatal diagnostics such as warnings.
pub fn VibeDb::warnings(
  self : VibeDb,
  path : String,
) -> Array[@core.Diagnostic] {
  let ast = self.queries.ast_query.fetch(self.rt, path).unwrap()
  @checker.collect_warnings(ast)
}
