///|
fn is_threads_builtin_name(name : String) -> Bool {
  name.has_prefix("Threads::")
}

///|
fn module_uses_threads_builtins(ast : @vibe_core.Module) -> Bool {
  let hits : Map[String, Bool] = {}
  @vibe_core.walk_block_refs(ast, @vibe_core.WalkerScope::new(), hits, fn(
    name : String,
    _scope : @vibe_core.WalkerScope,
    out : Map[String, Bool],
  ) {
    if is_threads_builtin_name(name) {
      out[name] = true
    }
  })
  hits.length() > 0
}

///|
fn db_entry_uses_threads_builtins(db : @runtime.VibeDb, entry : String) -> Bool {
  let seen : Map[String, Bool] = {}
  let stack : Array[String] = [entry]
  while stack.length() > 0 {
    let path = stack.remove(stack.length() - 1)
    if seen.contains(path) {
      continue
    }
    seen[path] = true
    if db_module_uses_threads_builtins(db, path) {
      return true
    }
    for imp in db.imports(path) {
      if !seen.contains(imp.path) {
        stack.push(imp.path)
      }
    }
  }
  false
}

///|
fn db_module_uses_threads_builtins(db : @runtime.VibeDb, path : String) -> Bool {
  if module_uses_threads_builtins(db.ast(path)) {
    return true
  }
  match db.get_source(path) {
    Some(source) => {
      let raw_ast = @parser.parse_ast(source) catch { _ => return false }
      module_uses_threads_builtins(raw_ast)
    }
    None => false
  }
}

///|
fn cached_source_hash_paths(text : String) -> Array[String] {
  let out : Array[String] = []
  for line_view in text.split("\n") {
    let line = line_view.to_owned().trim().to_owned()
    if line.length() == 0 {
      continue
    }
    let mut tab_at = -1
    for i, c in line {
      if c == '\t' {
        tab_at = i
        break
      }
    }
    if tab_at > 0 {
      out.push(line.unsafe_substring(start=0, end=tab_at))
    }
  }
  out
}

///|
fn cached_source_hashes_use_threads_builtins(
  hash_cache_path : String,
) -> Result[Bool, Unit] {
  if !@os_fs.path_exists(hash_cache_path) {
    return Err(())
  }
  let hash_text = @os_fs.read_file_to_string(hash_cache_path) catch {
    _ => return Err(())
  }
  let paths = cached_source_hash_paths(hash_text)
  if paths.length() == 0 {
    return Err(())
  }
  for path in paths {
    let source = @os_fs.read_file_to_string(path) catch { _ => return Err(()) }
    let raw_ast = @parser.parse_ast(source) catch { _ => return Err(()) }
    if module_uses_threads_builtins(raw_ast) {
      return Ok(true)
    }
  }
  Ok(false)
}

///|
fn require_unstable_threads_for_cached_sources(
  cmd_name : String,
  features : @runtime.RuntimeFeatureFlags,
  hash_cache_path : String,
) -> Result[Unit, String] {
  if features.is_unstable_threads_enabled() {
    return Ok(())
  }
  match cached_source_hashes_use_threads_builtins(hash_cache_path) {
    Ok(true) => Err(thread_feature_gate_error(cmd_name))
    Ok(false) => Ok(())
    Err(_) =>
      Err(cmd_name + ": unable to inspect cached source hashes for Threads::*")
  }
}

///|
fn thread_feature_gate_error(cmd_name : String) -> String {
  cmd_name + ": Threads::* requires --unstable-threads"
}

///|
fn require_unstable_threads_for_module(
  cmd_name : String,
  features : @runtime.RuntimeFeatureFlags,
  ast : @vibe_core.Module,
) -> Result[Unit, String] {
  if features.is_unstable_threads_enabled() {
    Ok(())
  } else if module_uses_threads_builtins(ast) {
    Err(thread_feature_gate_error(cmd_name))
  } else {
    Ok(())
  }
}

///|
fn require_unstable_threads_for_entry(
  cmd_name : String,
  features : @runtime.RuntimeFeatureFlags,
  db : @runtime.VibeDb,
  entry : String,
) -> Result[Unit, String] {
  if features.is_unstable_threads_enabled() {
    Ok(())
  } else if db_entry_uses_threads_builtins(db, entry) {
    Err(thread_feature_gate_error(cmd_name))
  } else {
    Ok(())
  }
}
