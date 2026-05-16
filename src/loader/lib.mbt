///|
/// Extract ```vibe code blocks from markdown and join them.
fn extract_vibe_from_markdown(markdown : String) -> String {
  let lines : Array[String] = markdown
    .split("\n")
    .map(StringView::to_string)
    .collect()
  let blocks : Array[String] = []
  let buf : Array[String] = []
  let mut in_vibe_block = false
  let mut in_other_block = false
  for i = 0; i < lines.length(); i = i + 1 {
    let line = lines[i]
    if !in_vibe_block && !in_other_block {
      if line.has_prefix("```vibe") {
        in_vibe_block = true
      } else if line.has_prefix("```") {
        in_other_block = true
      }
    } else if in_vibe_block {
      if line.trim().to_owned() == "```" {
        let sb = StringBuilder::new()
        for j, s in buf {
          if j > 0 {
            sb.write_string("\n")
          }
          sb.write_string(s)
        }
        blocks.push(sb.to_string())
        let _ = buf.drain(0, buf.length())
        in_vibe_block = false
      } else {
        buf.push(line)
      }
    } else if in_other_block {
      if line.trim().to_owned() == "```" {
        in_other_block = false
      }
    }
  }
  let result = StringBuilder::new()
  for i, block in blocks {
    if i > 0 {
      result.write_string("\n\n")
    }
    result.write_string(block)
  }
  result.to_string()
}

///|
fn apply_lock_to_db_with_fs(
  db : @runtime.VibeDb,
  entry : String,
  fs : &@io.FileSystemAdapter,
  persist_lock_updates : Bool,
) -> Result[Unit, String] {
  db.require_path_lock(true)
  let lock_path = @codebase.lock_file_path_with_fs(entry, fs)
  let lock_root = @vibe_fs.parent_path(lock_path)
  let legacy_lock_path = lock_root + "/vibe.lock"
  let has_lock_source = @io.path_exists_with(fs, lock_path) ||
    @io.path_exists_with(fs, legacy_lock_path)
  let lock = if has_lock_source {
    if persist_lock_updates {
      match @codebase.update_lock_path_refs_with_fs(entry, fs) {
        Ok(updated) => updated
        Err(err) => return Err(err)
      }
    } else {
      match @codebase.refresh_lock_path_refs_with_fs(entry, fs) {
        Ok(updated) => updated
        Err(err) => return Err(err)
      }
    }
  } else {
    match @codebase.load_lock_data_with_fs(lock_path, fs) {
      Ok(data) => data
      Err(err) => return Err(err)
    }
  }
  for path, hash in lock.path_refs {
    db.set_path_ref(path, hash)
  }
  for name, hash in lock.version_refs {
    db.set_version_ref(name, hash)
  }
  for name, hash in lock.symbol_refs {
    db.set_symbol_ref(name, hash)
  }
  Ok(())
}

///|
fn load_sources_recursive(
  db : @runtime.VibeDb,
  path : String,
  visited : Map[String, Bool],
  fs : &@io.FileSystemAdapter,
  root : String,
  registry_modules : Map[String, String],
) -> Result[Unit, String] {
  let stack : Array[String] = []
  load_sources_recursive_impl(
    db, path, visited, stack, fs, root, registry_modules,
  )
}

///|
/// Resolve an alias name to its source ModuleRef by reading index.vibe in the given directory.
fn resolve_alias_to_source(
  dir : String,
  alias_name : String,
  fs : &@io.FileSystemAdapter,
) -> Result[@vibe_core.ModuleRef, String] {
  let index_path = dir + "/index.vibe"
  if !@io.path_exists_with(fs, index_path) {
    return Err("alias @" + alias_name + ": no index.vibe found in " + dir)
  }
  let source = match @io.read_string_with(fs, index_path) {
    Ok(v) => v
    Err(err) => return Err("alias @" + alias_name + ": " + err)
  }
  let ast = @parser.parse_ast(source) catch {
    e =>
      return Err(
        "alias @" + alias_name + ": parse error in index.vibe: " + e.to_string(),
      )
  }
  for stmt in ast.stmts {
    match stmt {
      @vibe_core.Stmt::AliasDecl(alias_name=decl_name, source~, ..) =>
        if decl_name == alias_name {
          return Ok(source)
        }
      _ => ()
    }
  }
  Err(
    "alias @" +
    alias_name +
    " not found in " +
    index_path +
    " (add `import <path> @" +
    alias_name +
    "` to index.vibe)",
  )
}

///|
fn load_sources_recursive_impl(
  db : @runtime.VibeDb,
  path : String,
  visited : Map[String, Bool],
  stack : Array[String],
  fs : &@io.FileSystemAdapter,
  root : String,
  registry_modules : Map[String, String],
) -> Result[Unit, String] {
  let norm = @vibe_fs.normalize_path(path)
  for i, p in stack {
    if p == norm {
      let cycle_path = StringBuilder::new()
      for j = i; j < stack.length(); j = j + 1 {
        cycle_path.write_string(stack[j])
        cycle_path.write_string(" -> ")
      }
      cycle_path.write_string(norm)
      return Err("import cycle detected: " + cycle_path.to_string())
    }
  }
  if visited.contains(norm) {
    return Ok(())
  }
  stack.push(norm)
  visited.set(norm, true)
  let raw_source = match @io.read_string_with(fs, norm) {
    Ok(v) => v
    Err(err) => {
      let _ = stack.pop()
      return Err("io: " + err)
    }
  }
  let source = if norm.has_suffix(".md") {
    extract_vibe_from_markdown(raw_source)
  } else {
    raw_source
  }
  db.set_source(norm, source)
  let ast = @parser.parse_ast(source) catch {
    e => {
      let _ = stack.pop()
      return Err("parse: " + e.to_string())
    }
  }
  db.set_preparsed_ast(norm, source, ast)
  let base = @vibe_fs.parent_path(norm)
  for stmt in ast.stmts {
    match stmt {
      @vibe_core.Stmt::Import(spec~, source~, ..) => {
        if spec.items.length() == 0 {
          continue
        }
        match source {
          @vibe_core.ModuleRef::Path(path~) => {
            let resolved = match
              @codebase.resolve_import_path_with_registry(
                base, path, root, registry_modules,
              ) {
              Ok(v) => v
              Err(err) => {
                let _ = stack.pop()
                return Err(err)
              }
            }
            if resolved.has_suffix(".wasm") {
              if !visited.contains(resolved) {
                visited.set(resolved, true)
                let wasm_bytes = match @io.read_bytes_with(fs, resolved) {
                  Ok(v) => v
                  Err(err) => {
                    let _ = stack.pop()
                    return Err("io: " + err)
                  }
                }
                db.set_binary_source(resolved, wasm_bytes)
              }
            } else {
              match
                load_sources_recursive_impl(
                  db, resolved, visited, stack, fs, root, registry_modules,
                ) {
                Ok(_) => ()
                Err(err) => {
                  let _ = stack.pop()
                  return Err(err)
                }
              }
            }
          }
          @vibe_core.ModuleRef::Alias(name~) => {
            // Ensure index.vibe is loaded into db for alias resolution in db_query
            let index_path = @vibe_fs.normalize_path(base + "/index.vibe")
            if !visited.contains(index_path) {
              match @io.read_string_with(fs, index_path) {
                Ok(index_src) => db.set_source(index_path, index_src)
                Err(_) => ()
              }
            }
            let alias_source = match resolve_alias_to_source(base, name, fs) {
              Ok(resolved_source) => resolved_source
              Err(err) => {
                let _ = stack.pop()
                return Err(err)
              }
            }
            match alias_source {
              @vibe_core.ModuleRef::Path(path~) => {
                let resolved = match
                  @codebase.resolve_import_path_with_registry(
                    base, path, root, registry_modules,
                  ) {
                  Ok(v) => v
                  Err(err) => {
                    let _ = stack.pop()
                    return Err(err)
                  }
                }
                match
                  load_sources_recursive_impl(
                    db, resolved, visited, stack, fs, root, registry_modules,
                  ) {
                  Ok(_) => ()
                  Err(err) => {
                    let _ = stack.pop()
                    return Err(err)
                  }
                }
              }
              _ => ()
            }
          }
          @vibe_core.ModuleRef::Hash(..)
          | @vibe_core.ModuleRef::Version(..)
          | @vibe_core.ModuleRef::Symbol(..)
          | @vibe_core.ModuleRef::PinnedPath(..) => ()
        }
      }
      @vibe_core.Stmt::ReExport(spec~, source~, ..) => {
        let _ = spec
        match source {
          @vibe_core.ModuleRef::Path(path~) => {
            let resolved = match
              @codebase.resolve_import_path_with_registry(
                base, path, root, registry_modules,
              ) {
              Ok(v) => v
              Err(err) => {
                let _ = stack.pop()
                return Err(err)
              }
            }
            if resolved.has_suffix(".wasm") {
              if !visited.contains(resolved) {
                visited.set(resolved, true)
                let wasm_bytes = match @io.read_bytes_with(fs, resolved) {
                  Ok(v) => v
                  Err(err) => {
                    let _ = stack.pop()
                    return Err("io: " + err)
                  }
                }
                db.set_binary_source(resolved, wasm_bytes)
              }
            } else {
              match
                load_sources_recursive_impl(
                  db, resolved, visited, stack, fs, root, registry_modules,
                ) {
                Ok(_) => ()
                Err(err) => {
                  let _ = stack.pop()
                  return Err(err)
                }
              }
            }
          }
          @vibe_core.ModuleRef::Alias(name~) => {
            let index_path = @vibe_fs.normalize_path(base + "/index.vibe")
            if !visited.contains(index_path) {
              match @io.read_string_with(fs, index_path) {
                Ok(index_src) => db.set_source(index_path, index_src)
                Err(_) => ()
              }
            }
            let alias_source = match resolve_alias_to_source(base, name, fs) {
              Ok(resolved_source) => resolved_source
              Err(err) => {
                let _ = stack.pop()
                return Err(err)
              }
            }
            match alias_source {
              @vibe_core.ModuleRef::Path(path~) => {
                let resolved = match
                  @codebase.resolve_import_path_with_registry(
                    base, path, root, registry_modules,
                  ) {
                  Ok(v) => v
                  Err(err) => {
                    let _ = stack.pop()
                    return Err(err)
                  }
                }
                if resolved.has_suffix(".wasm") {
                  if !visited.contains(resolved) {
                    visited.set(resolved, true)
                    let wasm_bytes = match @io.read_bytes_with(fs, resolved) {
                      Ok(v) => v
                      Err(err) => {
                        let _ = stack.pop()
                        return Err("io: " + err)
                      }
                    }
                    db.set_binary_source(resolved, wasm_bytes)
                  }
                } else {
                  match
                    load_sources_recursive_impl(
                      db, resolved, visited, stack, fs, root, registry_modules,
                    ) {
                    Ok(_) => ()
                    Err(err) => {
                      let _ = stack.pop()
                      return Err(err)
                    }
                  }
                }
              }
              _ => ()
            }
          }
          @vibe_core.ModuleRef::Hash(..)
          | @vibe_core.ModuleRef::Version(..)
          | @vibe_core.ModuleRef::Symbol(..)
          | @vibe_core.ModuleRef::PinnedPath(..) => ()
        }
      }
      _ => ()
    }
  }
  match
    build_preparsed_path_import_specs(db, norm, ast, root, registry_modules) {
    Some(preparsed_imports) =>
      db.set_preparsed_imports(norm, source, preparsed_imports)
    None => ()
  }
  let _ = stack.pop()
  Ok(())
}

///|
fn preparsed_source_hash_and_module_ref(
  db : @runtime.VibeDb,
  resolved : String,
) -> (String?, String?) {
  let source_hash = if resolved.has_suffix(".wasm") {
    match @ripple.Input::get(db.inputs.binary_sources, db.rt, resolved) {
      Some(content) => Some(@vibe_core.git_blob_hash_bytes(content))
      None => None
    }
  } else {
    match db.get_source(resolved) {
      Some(content) => Some(@vibe_core.content_address_hash_string(content))
      None => None
    }
  }
  let module_ref = match source_hash {
    Some(hash) => Some(@vibe_core.module_ref_from_hash(hash))
    None => None
  }
  (source_hash, module_ref)
}

///|
fn build_preparsed_path_import_specs(
  db : @runtime.VibeDb,
  path : String,
  ast : @vibe_core.Module,
  root : String,
  registry_modules : Map[String, String],
) -> Array[@runtime.ImportSpec]? {
  let base = @vibe_fs.parent_path(path)
  let out : Array[@runtime.ImportSpec] = []
  for stmt in ast.stmts {
    match stmt {
      @vibe_core.Stmt::Import(spec~, source~, ..) => {
        if spec.items.length() == 0 {
          continue
        }
        match source {
          @vibe_core.ModuleRef::Path(path~) => {
            let raw_path = path
            let resolved = match
              @codebase.resolve_import_path_with_registry(
                base, raw_path, root, registry_modules,
              ) {
              Ok(v) => v
              Err(_) => return None
            }
            let (source_hash, module_ref) = preparsed_source_hash_and_module_ref(
              db, resolved,
            )
            out.push(
              @runtime.make_import_spec(
                resolved,
                @vibe_core.import_alias_name(raw_path),
                source_hash,
                module_ref,
                source_hash,
                None,
                None,
              ),
            )
          }
          _ => return None
        }
      }
      @vibe_core.Stmt::ReExport(spec~, source~, ..) => {
        let _ = spec
        match source {
          @vibe_core.ModuleRef::Path(path~) => {
            let raw_path = path
            let resolved = match
              @codebase.resolve_import_path_with_registry(
                base, raw_path, root, registry_modules,
              ) {
              Ok(v) => v
              Err(_) => return None
            }
            let (source_hash, module_ref) = preparsed_source_hash_and_module_ref(
              db, resolved,
            )
            out.push(
              @runtime.make_import_spec(
                resolved,
                @vibe_core.import_alias_name(raw_path),
                source_hash,
                module_ref,
                source_hash,
                None,
                None,
              ),
            )
          }
          _ => return None
        }
      }
      _ => ()
    }
  }
  Some(out)
}

///|
pub fn resolve_entry_path_with_fs(
  path : String,
  fs : &@io.FileSystemAdapter,
) -> String {
  let resolved = if path.has_prefix("/") {
    @vibe_fs.normalize_path(path)
  } else {
    let cwd = @io.current_dir_or_root_with(fs)
    @vibe_fs.normalize_path(cwd + "/" + path)
  }
  if resolved.has_suffix(".vibe") ||
    resolved.has_suffix(".xm") ||
    resolved.has_suffix(".wasm") ||
    resolved.has_suffix(".db") ||
    resolved.has_suffix(".lock") ||
    resolved.has_suffix(".md") {
    return resolved
  }
  let index_entry = @vibe_fs.normalize_path(resolved + "/index.vibe")
  if @io.path_exists_with(fs, index_entry) {
    return index_entry
  }
  match @io.read_dir_with(fs, resolved) {
    Ok(_) => index_entry
    Err(_) => resolved
  }
}

///|
pub fn resolve_entry_path(path : String) -> String {
  resolve_entry_path_with_fs(path, @io.default_fs_adapter())
}

///|
fn graph_head_from_cache_json(source : String) -> String? {
  let parsed : Json = @json.parse(source) catch { _ => return None }
  match parsed {
    Json::Object(obj) =>
      match obj.get("graph_head") {
        Some(Json::String(hash)) => Some(hash)
        _ => None
      }
    _ => None
  }
}

///|
pub fn resolve_entry_graph_head_with_fs(
  entry_path : String,
  fs : &@io.FileSystemAdapter,
) -> String? {
  let resolved = resolve_entry_path_with_fs(entry_path, fs)
  let vibe_dir = @codebase.vibe_dir_path_with_fs(resolved, fs)
  let cache_path = vibe_dir + "/cache.json"
  let source = match @io.read_string_with(fs, cache_path) {
    Ok(v) => v
    Err(_) => return None
  }
  graph_head_from_cache_json(source)
}

///|
pub fn resolve_entry_graph_head(entry_path : String) -> String? {
  resolve_entry_graph_head_with_fs(entry_path, @io.default_fs_adapter())
}

///|
fn resolve_import_module_entry(path : String) -> String {
  let normalized = @vibe_fs.normalize_path(path)
  if normalized.has_suffix(".vibe") ||
    normalized.has_suffix(".xm") ||
    normalized.has_suffix(".wasm") ||
    normalized.has_suffix(".db") ||
    normalized.has_suffix(".lock") {
    normalized
  } else {
    @vibe_fs.normalize_path(normalized + "/index.vibe")
  }
}

///|
pub fn resolve_import_path(base : String, import_path : String) -> String {
  let resolved = if import_path.has_prefix("/") {
    @vibe_fs.normalize_path(import_path)
  } else {
    @vibe_fs.normalize_path(base + "/" + import_path)
  }
  resolve_import_module_entry(resolved)
}

///|
pub fn load_db(
  entry_path : String,
) -> Result[(@runtime.VibeDb, String), String] {
  match load_db_with_fs(entry_path, @io.default_fs_adapter()) {
    Ok((db, entry)) => Ok((db, entry))
    Err(err) => Err(err)
  }
}

///|
pub fn load_db_with_fs(
  entry_path : String,
  fs : &@io.FileSystemAdapter,
) -> Result[(@runtime.VibeDb, String), String] {
  match load_db_with_paths_with_fs_impl(entry_path, fs, true) {
    Ok((db, entry, _)) => Ok((db, entry))
    Err(err) => Err(err)
  }
}

///|
pub fn load_db_into(
  db : @runtime.VibeDb,
  entry_path : String,
) -> Result[(@runtime.VibeDb, String), String] {
  match load_db_with_fs_into(db, entry_path, @io.default_fs_adapter()) {
    Ok((next_db, entry)) => Ok((next_db, entry))
    Err(err) => Err(err)
  }
}

///|
pub fn load_db_with_fs_into(
  db : @runtime.VibeDb,
  entry_path : String,
  fs : &@io.FileSystemAdapter,
) -> Result[(@runtime.VibeDb, String), String] {
  match load_db_with_paths_with_fs_into_impl(db, entry_path, fs, true) {
    Ok((next_db, entry, _)) => Ok((next_db, entry))
    Err(err) => Err(err)
  }
}

///|
pub fn load_db_with_paths(
  entry_path : String,
) -> Result[(@runtime.VibeDb, String, Array[String]), String] {
  load_db_with_paths_with_fs_impl(entry_path, @io.default_fs_adapter(), true)
}

///|
pub fn load_db_with_paths_into(
  db : @runtime.VibeDb,
  entry_path : String,
) -> Result[(@runtime.VibeDb, String, Array[String]), String] {
  load_db_with_paths_with_fs_into_impl(
    db,
    entry_path,
    @io.default_fs_adapter(),
    true,
  )
}

///|
pub fn load_db_with_paths_with_fs(
  entry_path : String,
  fs : &@io.FileSystemAdapter,
) -> Result[(@runtime.VibeDb, String, Array[String]), String] {
  load_db_with_paths_with_fs_impl(entry_path, fs, true)
}

///|
pub fn load_db_with_paths_with_fs_into(
  db : @runtime.VibeDb,
  entry_path : String,
  fs : &@io.FileSystemAdapter,
) -> Result[(@runtime.VibeDb, String, Array[String]), String] {
  load_db_with_paths_with_fs_into_impl(db, entry_path, fs, true)
}

///|
fn load_db_with_paths_with_fs_impl(
  entry_path : String,
  fs : &@io.FileSystemAdapter,
  persist_lock_updates : Bool,
) -> Result[(@runtime.VibeDb, String, Array[String]), String] {
  let db = @runtime.VibeDb::new()
  load_db_with_paths_with_fs_into_impl(db, entry_path, fs, persist_lock_updates)
}

///|
fn load_db_with_paths_with_fs_into_impl(
  db : @runtime.VibeDb,
  entry_path : String,
  fs : &@io.FileSystemAdapter,
  persist_lock_updates : Bool,
) -> Result[(@runtime.VibeDb, String, Array[String]), String] {
  let entry = resolve_entry_path_with_fs(entry_path, fs)
  let root = @codebase.resolve_index_root_with_fs(entry, fs)
  let registry_modules = match
    @codebase.load_registry_modules_with_fs(root, fs) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  match apply_lock_to_db_with_fs(db, entry, fs, persist_lock_updates) {
    Ok(_) => ()
    Err(err) => return Err(err)
  }
  let visited : Map[String, Bool] = {}
  match load_sources_recursive(db, entry, visited, fs, root, registry_modules) {
    Ok(_) => {
      let paths : Array[String] = []
      for path, _ in visited {
        paths.push(path)
      }
      paths.sort()
      Ok((db, entry, paths))
    }
    Err(err) => Err(err)
  }
}

///|
pub fn load_db_for_test(
  entry_path : String,
) -> Result[(@runtime.VibeDb, String), String] {
  match
    load_db_with_paths_with_fs_impl(entry_path, @io.default_fs_adapter(), false) {
    Ok((db, entry, _)) => Ok((db, entry))
    Err(err) => Err(err)
  }
}

///|
pub fn load_db_for_test_into(
  db : @runtime.VibeDb,
  entry_path : String,
) -> Result[(@runtime.VibeDb, String), String] {
  match
    load_db_with_paths_with_fs_into_impl(
      db,
      entry_path,
      @io.default_fs_adapter(),
      false,
    ) {
    Ok((next_db, entry, _)) => Ok((next_db, entry))
    Err(err) => Err(err)
  }
}
