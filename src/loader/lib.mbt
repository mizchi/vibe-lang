///|
fn apply_lock_to_db_with_fs(
  db : @runtime.VibeDb,
  entry : String,
  fs : &@io.FileSystemAdapter,
) -> Result[Unit, String] {
  db.require_path_lock(true)
  let lock_path = @codebase.lock_file_path_with_fs(entry, fs)
  let lock_root = @vibe_fs.parent_path(lock_path)
  let legacy_lock_path = lock_root + "/xsh.lock"
  let index_vdb_path = lock_root + "/index.vdb"
  let has_lock_source = @io.path_exists_with(fs, lock_path) ||
    @io.path_exists_with(fs, legacy_lock_path) ||
    @io.path_exists_with(fs, index_vdb_path)
  if has_lock_source {
    match @codebase.update_lock_path_refs_with_fs(entry, fs) {
      Ok(_) => ()
      Err(err) => return Err(err)
    }
  }
  let lock = match @codebase.load_lock_data_with_fs(lock_path, fs) {
    Ok(data) => data
    Err(err) => return Err(err)
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
  let source = match @io.read_string_with(fs, norm) {
    Ok(v) => v
    Err(err) => {
      let _ = stack.pop()
      return Err("io: " + err)
    }
  }
  db.set_source(norm, source)
  let ast = @parser.parse_ast(source) catch {
    e => {
      let _ = stack.pop()
      return Err("parse: " + e.to_string())
    }
  }
  let base = @vibe_fs.parent_path(norm)
  for stmt in ast.stmts {
    match stmt {
      @vibe_core.Stmt::Import(source~, ..) =>
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
              if not(visited.contains(resolved)) {
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
          @vibe_core.ModuleRef::Hash(..)
          | @vibe_core.ModuleRef::Version(..)
          | @vibe_core.ModuleRef::Symbol(..) => ()
        }
      _ => ()
    }
  }
  let _ = stack.pop()
  Ok(())
}

///|
pub fn resolve_entry_path_with_fs(
  path : String,
  fs : &@io.FileSystemAdapter,
) -> String {
  if path.has_prefix("/") {
    @vibe_fs.normalize_path(path)
  } else {
    let cwd = @io.current_dir_or_root_with(fs)
    @vibe_fs.normalize_path(cwd + "/" + path)
  }
}

///|
pub fn resolve_entry_path(path : String) -> String {
  resolve_entry_path_with_fs(path, @io.default_fs_adapter())
}

///|
pub fn resolve_import_path(base : String, import_path : String) -> String {
  if import_path.has_prefix("/") {
    @vibe_fs.normalize_path(import_path)
  } else {
    @vibe_fs.normalize_path(base + "/" + import_path)
  }
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
  match load_db_with_paths_with_fs(entry_path, fs) {
    Ok((db, entry, _)) => Ok((db, entry))
    Err(err) => Err(err)
  }
}

///|
pub fn load_db_with_paths(
  entry_path : String,
) -> Result[(@runtime.VibeDb, String, Array[String]), String] {
  load_db_with_paths_with_fs(entry_path, @io.default_fs_adapter())
}

///|
pub fn load_db_with_paths_with_fs(
  entry_path : String,
  fs : &@io.FileSystemAdapter,
) -> Result[(@runtime.VibeDb, String, Array[String]), String] {
  let db = @runtime.VibeDb::new()
  let entry = resolve_entry_path_with_fs(entry_path, fs)
  let root = @codebase.resolve_index_root_with_fs(entry, fs)
  let registry_modules = match
    @codebase.load_registry_modules_with_fs(root, fs) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  match apply_lock_to_db_with_fs(db, entry, fs) {
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
