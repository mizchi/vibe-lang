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
fn strip_module_ext(path : String) -> String {
  if path.has_suffix(".vibe") && path.length() > 5 {
    try { path[0:path.length() - 5].to_string() } catch { _ => path }
  } else if path.has_suffix(".xm") && path.length() > 3 {
    try { path[0:path.length() - 3].to_string() } catch { _ => path }
  } else {
    path
  }
}

///|
fn normalize_module_entry_path(path : String) -> String {
  if path.has_suffix(".vibe") ||
    path.has_suffix(".xm") ||
    path.has_suffix(".wasm") ||
    path.has_suffix(".db") ||
    path.has_suffix(".lock") ||
    path.has_suffix(".vbundle") {
    path
  } else {
    @path.Path(path).join(@path.Path("index.vibe")).normalize().to_string()
  }
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
fn split_registry_like_path(path : String) -> (String, String)? {
  for i, c in path {
    if c == '/' {
      if i <= 0 || i + 1 >= path.length() {
        return None
      }
      let ns = path.unsafe_substring(start=0, end=i)
      let rest = path.unsafe_substring(start=i + 1, end=path.length())
      return Some((ns, rest))
    }
  }
  None
}

///|
fn fallback_import_root_from_vibe_segment(base_dir : String) -> String? {
  let mut dir = @path.Path(base_dir).normalize().to_string()
  for _ in 0..<64 {
    let parent = @path.Path(dir).dirname().normalize().to_string()
    if parent == dir {
      break
    }
    let name = @path.Path(dir).basename().to_string()
    if name == "vibe" {
      return Some(parent)
    }
    dir = parent
  }
  None
}

///|
fn resolve_import_root_dir(base_dir : String) -> String {
  let mut dir = @path.Path(base_dir).normalize().to_string()
  for _ in 0..<64 {
    let index_path = @path.Path(dir)
      .join(@path.Path("index.vibe"))
      .normalize()
      .to_string()
    if @io.path_exists(index_path) {
      return dir
    }
    let parent = @path.Path(dir).dirname().normalize().to_string()
    if parent == dir {
      break
    }
    dir = parent
  }
  match fallback_import_root_from_vibe_segment(base_dir) {
    Some(v) => v
    None => @path.Path(base_dir).normalize().to_string()
  }
}

///|
fn resolve_default_registry_path(
  base_dir : String,
  raw_path : String,
) -> String? {
  if raw_path.has_prefix("/") ||
    raw_path.has_prefix("./") ||
    raw_path.has_prefix("../") {
    return None
  }
  match split_registry_like_path(raw_path) {
    Some((ns, rest)) =>
      if ns == "prelude" ||
        ns == "std" ||
        ns == "json" ||
        ns == "base64" ||
        ns == "sha1" ||
        ns == "path" {
        let root = resolve_import_root_dir(base_dir)
        let dir = if ns == "std" { "prelude" } else { ns }
        let resolved = "vibe/" + dir + "/" + rest
        Some(
          @path.Path(root).join(@path.Path(resolved)).normalize().to_string(),
        )
      } else {
        None
      }
    None => None
  }
}

///|
fn normalize_path_obj(base_dir : String, raw_path : String) -> PathObj {
  let normalized_raw = if raw_path.has_prefix("/") {
    @path.Path(raw_path).normalize().to_string()
  } else if raw_path.has_prefix("./") || raw_path.has_prefix("../") {
    @path.Path(base_dir).join(@path.Path(raw_path)).normalize().to_string()
  } else {
    match resolve_default_registry_path(base_dir, raw_path) {
      Some(v) => v
      None =>
        @path.Path(base_dir).join(@path.Path(raw_path)).normalize().to_string()
    }
  }
  let normalized = normalize_module_entry_path(normalized_raw)
  PathObj::{ raw: raw_path, base: base_dir, normalized }
}

///|
fn resolve_hash_import(
  rt : @ripple.Runtime,
  sources : @ripple.Input[String, String],
  binary_sources : @ripple.Input[String, Bytes],
  diags : @ripple.Accumulator[@core.Diagnostic],
  hash_text : String,
  span : @core.Span,
) -> (String, String?) {
  let hash = normalize_hash(hash_text)
  let snapshot_key = hash_source_key(hash)
  match sources.get(rt, snapshot_key) {
    Some(content) => {
      let actual_hash = @core.content_address_hash_string(content)
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
    None =>
      match binary_sources.get(rt, snapshot_key) {
        Some(content) => {
          let actual_hash = @core.git_blob_hash_bytes(content)
          if actual_hash == hash {
            (snapshot_key, Some(hash))
          } else {
            diags.push(rt, @core.Diagnostic::{
              stage: "import",
              message: "hash mismatch: expected " +
              hash +
              ", got " +
              actual_hash,
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
      let source_norm = path_obj.normalized
      let source_base = strip_module_ext(source_norm)
      let imp_base = strip_module_ext(imp.path)
      if source_norm == imp.path || path == imp.path || source_base == imp_base {
        true
      } else {
        match imp.path_obj {
          Some(obj) =>
            obj.normalized == source_norm ||
            obj.raw == path ||
            strip_module_ext(obj.normalized) == source_base ||
            strip_module_ext(obj.raw) == strip_module_ext(path)
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
fn rewrite_import_sources(
  ast : @core.Module,
  imports : Array[ImportSpec],
) -> @core.Module {
  let stmts : Array[@core.Stmt] = []
  let mut import_idx = 0
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::Import(spec~, source~, span~) => {
        if spec.items.length() == 0 {
          stmts.push(stmt)
          continue
        }
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
      @core.Stmt::ReExport(spec~, source~, span~) => {
        let _ = source
        let next_stmt = if import_idx < imports.length() {
          let resolved = imports[import_idx]
          import_idx += 1
          match resolved.hash {
            Some(hash) =>
              @core.Stmt::ReExport(
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
