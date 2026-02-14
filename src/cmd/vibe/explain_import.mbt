///|
priv struct ExplainImportItem {
  module_path : String
  line : Int
  source : String
  ref_kind : String
  normalized : String?
  lock_lookup_key : String?
  lock_lookup_status : String
  lock_hash : String?
  actual_hash : String?
  resolved_hash : String?
  module_ref : String?
  reason : String?
}

///|
priv struct ExplainImportReport {
  entry_path : String
  index_root : String
  lock_path : String
  lock_root : String
  vibe_dir : String
  imports : Array[ExplainImportItem]
}

///|
fn explain_import_normalize_hash(hash : String) -> String {
  if hash.has_prefix("#") && hash.length() > 1 {
    hash.unsafe_substring(start=1, end=hash.length())
  } else {
    hash
  }
}

///|
fn explain_import_hash_object_exists(
  codebase : @codebase.Codebase,
  hash : String,
) -> Bool {
  @io.path_exists(codebase.object_path(hash))
}

///|
fn explain_import_compute_file_hash(
  path : String,
) -> Result[(String, String), String] {
  if path.has_suffix(".wasm") {
    let bytes = match @io.read_bytes(path) {
      Ok(v) => v
      Err(err) => return Err("read binary import: " + err)
    }
    Ok(("binary", @vibe_core.git_blob_hash_bytes(bytes)))
  } else {
    let source = match @io.read_string(path) {
      Ok(v) => v
      Err(err) => return Err("read source import: " + err)
    }
    Ok(("text", @vibe_core.content_address_hash_string(source)))
  }
}

///|
fn explain_import_path_item(
  source_path : String,
  line : Int,
  raw_path : String,
  root : String,
  registry_modules : Map[String, String],
  lock : @codebase.LockData,
) -> ExplainImportItem {
  let base = @vibe_fs.parent_path(source_path)
  match
    @codebase.resolve_import_path_with_registry(
      base, raw_path, root, registry_modules,
    ) {
    Err(err) =>
      {
        module_path: source_path,
        line,
        source: raw_path,
        ref_kind: "PathRef",
        normalized: None,
        lock_lookup_key: None,
        lock_lookup_status: "error",
        lock_hash: None,
        actual_hash: None,
        resolved_hash: None,
        module_ref: None,
        reason: Some(err),
      }
    Ok(resolved) => {
      let lock_hash_opt = lock.path_refs.get(resolved)
      let lock_hash = match lock_hash_opt {
        Some(h) => Some(explain_import_normalize_hash(h))
        None => None
      }
      if not(@io.path_exists(resolved)) {
        {
          module_path: source_path,
          line,
          source: raw_path,
          ref_kind: "PathRef",
          normalized: Some(resolved),
          lock_lookup_key: Some(resolved),
          lock_lookup_status: "error",
          lock_hash,
          actual_hash: None,
          resolved_hash: None,
          module_ref: None,
          reason: Some("resolved path not found"),
        }
      } else {
        match explain_import_compute_file_hash(resolved) {
          Err(err) =>
            {
              module_path: source_path,
              line,
              source: raw_path,
              ref_kind: "PathRef",
              normalized: Some(resolved),
              lock_lookup_key: Some(resolved),
              lock_lookup_status: "error",
              lock_hash,
              actual_hash: None,
              resolved_hash: None,
              module_ref: None,
              reason: Some(err),
            }
          Ok((_content_kind, actual_hash)) =>
            match lock_hash {
              None =>
                {
                  module_path: source_path,
                  line,
                  source: raw_path,
                  ref_kind: "PathRef",
                  normalized: Some(resolved),
                  lock_lookup_key: Some(resolved),
                  lock_lookup_status: "miss",
                  lock_hash: None,
                  actual_hash: Some(actual_hash),
                  resolved_hash: None,
                  module_ref: None,
                  reason: Some("missing path ref in index.lock"),
                }
              Some(expected_hash) =>
                if expected_hash == actual_hash {
                  {
                    module_path: source_path,
                    line,
                    source: raw_path,
                    ref_kind: "PathRef",
                    normalized: Some(resolved),
                    lock_lookup_key: Some(resolved),
                    lock_lookup_status: "hit",
                    lock_hash: Some(expected_hash),
                    actual_hash: Some(actual_hash),
                    resolved_hash: Some(actual_hash),
                    module_ref: Some(
                      @vibe_core.module_ref_from_hash(actual_hash),
                    ),
                    reason: None,
                  }
                } else {
                  {
                    module_path: source_path,
                    line,
                    source: raw_path,
                    ref_kind: "PathRef",
                    normalized: Some(resolved),
                    lock_lookup_key: Some(resolved),
                    lock_lookup_status: "mismatch",
                    lock_hash: Some(expected_hash),
                    actual_hash: Some(actual_hash),
                    resolved_hash: None,
                    module_ref: None,
                    reason: Some("lock hash differs from current source hash"),
                  }
                }
            }
        }
      }
    }
  }
}

///|
fn explain_import_hash_item(
  source_path : String,
  line : Int,
  hash_text : String,
  codebase : @codebase.Codebase,
) -> ExplainImportItem {
  let hash = explain_import_normalize_hash(hash_text)
  if explain_import_hash_object_exists(codebase, hash) {
    {
      module_path: source_path,
      line,
      source: "#" + hash_text,
      ref_kind: "HashRef",
      normalized: Some(hash),
      lock_lookup_key: None,
      lock_lookup_status: "n/a",
      lock_hash: None,
      actual_hash: None,
      resolved_hash: Some(hash),
      module_ref: Some(@vibe_core.module_ref_from_hash(hash)),
      reason: None,
    }
  } else {
    {
      module_path: source_path,
      line,
      source: "#" + hash_text,
      ref_kind: "HashRef",
      normalized: Some(hash),
      lock_lookup_key: None,
      lock_lookup_status: "n/a",
      lock_hash: None,
      actual_hash: None,
      resolved_hash: None,
      module_ref: None,
      reason: Some("hash object not found in .vibe/objects"),
    }
  }
}

///|
fn explain_import_version_item(
  source_path : String,
  line : Int,
  name : String,
  lock : @codebase.LockData,
  codebase : @codebase.Codebase,
) -> ExplainImportItem {
  match lock.version_refs.get(name) {
    None =>
      {
        module_path: source_path,
        line,
        source: "version@" + name,
        ref_kind: "VersionRef",
        normalized: Some(name),
        lock_lookup_key: Some(name),
        lock_lookup_status: "miss",
        lock_hash: None,
        actual_hash: None,
        resolved_hash: None,
        module_ref: None,
        reason: Some("missing version ref in index.lock"),
      }
    Some(hash_text) => {
      let hash = explain_import_normalize_hash(hash_text)
      if explain_import_hash_object_exists(codebase, hash) {
        {
          module_path: source_path,
          line,
          source: "version@" + name,
          ref_kind: "VersionRef",
          normalized: Some(name),
          lock_lookup_key: Some(name),
          lock_lookup_status: "hit",
          lock_hash: Some(hash),
          actual_hash: None,
          resolved_hash: Some(hash),
          module_ref: Some(@vibe_core.module_ref_from_hash(hash)),
          reason: None,
        }
      } else {
        {
          module_path: source_path,
          line,
          source: "version@" + name,
          ref_kind: "VersionRef",
          normalized: Some(name),
          lock_lookup_key: Some(name),
          lock_lookup_status: "hit",
          lock_hash: Some(hash),
          actual_hash: None,
          resolved_hash: None,
          module_ref: None,
          reason: Some("version ref resolved to missing hash object"),
        }
      }
    }
  }
}

///|
fn explain_import_symbol_item(
  source_path : String,
  line : Int,
  name : String,
  lock : @codebase.LockData,
  codebase : @codebase.Codebase,
) -> ExplainImportItem {
  match lock.symbol_refs.get(name) {
    None =>
      {
        module_path: source_path,
        line,
        source: "symbol@" + name,
        ref_kind: "SymbolRef",
        normalized: Some(name),
        lock_lookup_key: Some(name),
        lock_lookup_status: "miss",
        lock_hash: None,
        actual_hash: None,
        resolved_hash: None,
        module_ref: None,
        reason: Some("missing symbol ref in index.lock"),
      }
    Some(hash_text) => {
      let hash = explain_import_normalize_hash(hash_text)
      if explain_import_hash_object_exists(codebase, hash) {
        {
          module_path: source_path,
          line,
          source: "symbol@" + name,
          ref_kind: "SymbolRef",
          normalized: Some(name),
          lock_lookup_key: Some(name),
          lock_lookup_status: "hit",
          lock_hash: Some(hash),
          actual_hash: None,
          resolved_hash: Some(hash),
          module_ref: Some(@vibe_core.module_ref_from_hash(hash)),
          reason: None,
        }
      } else {
        {
          module_path: source_path,
          line,
          source: "symbol@" + name,
          ref_kind: "SymbolRef",
          normalized: Some(name),
          lock_lookup_key: Some(name),
          lock_lookup_status: "hit",
          lock_hash: Some(hash),
          actual_hash: None,
          resolved_hash: None,
          module_ref: None,
          reason: Some("symbol ref resolved to missing hash object"),
        }
      }
    }
  }
}

///|
fn explain_import_collect_module(
  path : String,
  root : String,
  registry_modules : Map[String, String],
  lock : @codebase.LockData,
  codebase : @codebase.Codebase,
  visited : Map[String, Bool],
  out : Array[ExplainImportItem],
) -> Result[Unit, String] {
  let norm = @vibe_fs.normalize_path(path)
  if visited.contains(norm) {
    return Ok(())
  }
  visited[norm] = true
  let source = match @io.read_string(norm) {
    Ok(v) => v
    Err(err) => return Err("read: " + norm + ": " + err)
  }
  let ast = @parser.parse_ast(source) catch {
    e => return Err("parse: " + norm + ": " + e.to_string())
  }
  for stmt in ast.stmts {
    match stmt {
      @vibe_core.Stmt::Import(source=import_source, span~, ..)
      | @vibe_core.Stmt::ReExport(source=import_source, span~, ..) => {
        let line = @vibe_core.line_info(source, span.start).0.line
        let item = match import_source {
          @vibe_core.ModuleRef::Path(path=raw_path) =>
            explain_import_path_item(
              norm, line, raw_path, root, registry_modules, lock,
            )
          @vibe_core.ModuleRef::Hash(hash~) =>
            explain_import_hash_item(norm, line, hash, codebase)
          @vibe_core.ModuleRef::Version(name~) =>
            explain_import_version_item(norm, line, name, lock, codebase)
          @vibe_core.ModuleRef::Symbol(name~) =>
            explain_import_symbol_item(norm, line, name, lock, codebase)
        }
        out.push(item)
      }
      _ => ()
    }
  }
  let base = @vibe_fs.parent_path(norm)
  for stmt in ast.stmts {
    match stmt {
      @vibe_core.Stmt::Import(source=import_source, ..)
      | @vibe_core.Stmt::ReExport(source=import_source, ..) =>
        match import_source {
          @vibe_core.ModuleRef::Path(path=raw_path) =>
            match
              @codebase.resolve_import_path_with_registry(
                base, raw_path, root, registry_modules,
              ) {
              Ok(next) =>
                if @io.path_exists(next) && not(next.has_suffix(".wasm")) {
                  match
                    explain_import_collect_module(
                      next, root, registry_modules, lock, codebase, visited, out,
                    ) {
                    Ok(_) => ()
                    Err(err) => return Err(err)
                  }
                }
              Err(_) => ()
            }
          _ => ()
        }
      _ => ()
    }
  }
  Ok(())
}

///|
fn explain_import_report(
  entry_path : String,
) -> Result[ExplainImportReport, String] {
  let resolved_entry = @loader.resolve_entry_path(entry_path)
  let index_root = @codebase.resolve_index_root(resolved_entry)
  let lock_path = @codebase.lock_file_path(resolved_entry)
  let lock_root = @vibe_fs.parent_path(lock_path)
  let vibe_dir = @codebase.vibe_dir_path(resolved_entry)
  let registry_modules = match @codebase.load_registry_modules(index_root) {
    Ok(v) => v
    Err(err) => return Err("load registry: " + err)
  }
  let lock = match @codebase.load_lock_data(lock_path) {
    Ok(v) => v
    Err(err) => return Err("load lock: " + err)
  }
  let codebase = @codebase.Codebase::new(vibe_dir)
  let visited : Map[String, Bool] = {}
  let items : Array[ExplainImportItem] = []
  match
    explain_import_collect_module(
      resolved_entry, index_root, registry_modules, lock, codebase, visited, items,
    ) {
    Ok(_) => ()
    Err(err) => return Err(err)
  }
  Ok({
    entry_path: resolved_entry,
    index_root,
    lock_path,
    lock_root,
    vibe_dir,
    imports: items,
  })
}

///|
fn explain_import_render_opt(value : String?) -> String {
  match value {
    Some(v) => v
    None => "<none>"
  }
}

///|
fn render_explain_import_report(report : ExplainImportReport) -> String {
  let out = StringBuilder::new()
  out.write_string("entry: " + report.entry_path + "\n")
  out.write_string("index_root: " + report.index_root + "\n")
  out.write_string("lock_path: " + report.lock_path + "\n")
  out.write_string("lock_root: " + report.lock_root + "\n")
  out.write_string("vibe_dir: " + report.vibe_dir + "\n")
  out.write_string("imports: " + report.imports.length().to_string())
  for i, item in report.imports {
    out.write_string("\n\n")
    out.write_string("[" + (i + 1).to_string() + "] ")
    out.write_string(item.module_path + ":" + item.line.to_string())
    out.write_string(" " + item.source)
    out.write_string("\n  kind: " + item.ref_kind)
    out.write_string(
      "\n  normalized: " + explain_import_render_opt(item.normalized),
    )
    out.write_string(
      "\n  lock_lookup_key: " + explain_import_render_opt(item.lock_lookup_key),
    )
    out.write_string("\n  lock_lookup_status: " + item.lock_lookup_status)
    out.write_string(
      "\n  lock_hash: " + explain_import_render_opt(item.lock_hash),
    )
    out.write_string(
      "\n  actual_hash: " + explain_import_render_opt(item.actual_hash),
    )
    out.write_string(
      "\n  resolved_hash: " + explain_import_render_opt(item.resolved_hash),
    )
    out.write_string(
      "\n  module_ref: " + explain_import_render_opt(item.module_ref),
    )
    out.write_string("\n  reason: " + explain_import_render_opt(item.reason))
  }
  out.to_string()
}

///|
pub fn explain_import_cmd(args : Array[String]) -> Unit {
  if args.length() != 1 {
    abort("explain-import: expected <entry-file>")
  }
  let report = match explain_import_report(args[0]) {
    Ok(v) => v
    Err(err) => abort("explain-import: " + err)
  }
  println(render_explain_import_report(report))
}
