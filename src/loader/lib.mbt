///|
fn apply_lock_to_db(
  db : @xsh_lib.XshDb,
  entry : String,
) -> Result[Unit, String] {
  db.require_path_lock(true)
  let lock_path = @codebase.lock_file_path(entry)
  let lock = match @codebase.load_lock_data(lock_path) {
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
  db : @xsh_lib.XshDb,
  path : String,
  visited : Map[String, Bool],
) -> Result[Unit, String] {
  let stack : Array[String] = []
  load_sources_recursive_impl(db, path, visited, stack)
}

///|
fn load_sources_recursive_impl(
  db : @xsh_lib.XshDb,
  path : String,
  visited : Map[String, Bool],
  stack : Array[String],
) -> Result[Unit, String] {
  let norm = @xsh_fs.normalize_path(path)
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
  let source = match @io.read_string(norm) {
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
  let base = @xsh_fs.parent_path(norm)
  for stmt in ast.stmts {
    match stmt {
      @xsh_core.Stmt::Import(source~, ..) =>
        match source {
          @xsh_core.ModuleRef::Path(path~) => {
            let resolved = resolve_import_path(base, path)
            if resolved.has_suffix(".wasm") {
              if not(visited.contains(resolved)) {
                visited.set(resolved, true)
                let wasm_bytes = match @io.read_bytes(resolved) {
                  Ok(v) => v
                  Err(err) => {
                    let _ = stack.pop()
                    return Err("io: " + err)
                  }
                }
                db.set_binary_source(resolved, wasm_bytes)
              }
            } else {
              match load_sources_recursive_impl(db, resolved, visited, stack) {
                Ok(_) => ()
                Err(err) => {
                  let _ = stack.pop()
                  return Err(err)
                }
              }
            }
          }
          @xsh_core.ModuleRef::Hash(..)
          | @xsh_core.ModuleRef::Version(..)
          | @xsh_core.ModuleRef::Symbol(..) => ()
        }
      _ => ()
    }
  }
  let _ = stack.pop()
  Ok(())
}

///|
pub fn resolve_entry_path(path : String) -> String {
  if path.has_prefix("/") {
    @xsh_fs.normalize_path(path)
  } else {
    let cwd = @io.current_dir_or_root()
    @xsh_fs.normalize_path(cwd + "/" + path)
  }
}

///|
pub fn resolve_import_path(base : String, import_path : String) -> String {
  if import_path.has_prefix("/") {
    @xsh_fs.normalize_path(import_path)
  } else {
    @xsh_fs.normalize_path(base + "/" + import_path)
  }
}

///|
pub fn load_db(entry_path : String) -> Result[(@xsh_lib.XshDb, String), String] {
  match load_db_with_paths(entry_path) {
    Ok((db, entry, _)) => Ok((db, entry))
    Err(err) => Err(err)
  }
}

///|
pub fn load_db_with_paths(
  entry_path : String,
) -> Result[(@xsh_lib.XshDb, String, Array[String]), String] {
  let db = @xsh_lib.XshDb::new()
  let entry = resolve_entry_path(entry_path)
  match apply_lock_to_db(db, entry) {
    Ok(_) => ()
    Err(err) => return Err(err)
  }
  let visited : Map[String, Bool] = {}
  match load_sources_recursive(db, entry, visited) {
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
