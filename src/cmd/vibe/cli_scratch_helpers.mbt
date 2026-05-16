///|
fn load_scratch_db_source(path : String) -> Result[String, String] {
  if !@os_fs.path_exists(path) {
    return Ok("")
  }
  let is_file = @os_fs.is_file(path) catch { _ => false }
  if !is_file {
    return Err("scratch-db path is not a file: " + path)
  }
  let source = @os_fs.read_file_to_string(path) catch {
    e =>
      return Err("failed to read scratch-db `" + path + "`: " + e.to_string())
  }
  Ok(source)
}

///|
struct ScratchScopeSymbol {
  name : String
  kind : String
  signature : String
  path : String
  def_id : String
} derive(Debug, Eq)

///|
fn scratch_scope_symbol_id_from_entry(entry : @frontend.SymbolEntry) -> String {
  let key = entry.path +
    "|" +
    entry.span.start.to_string() +
    "|" +
    entry.span.end.to_string() +
    "|" +
    entry.name +
    "|" +
    @frontend.symbol_kind_name(entry.kind) +
    "|" +
    entry.signature
  @vibe_core.git_blob_hash_string(key)
}

///|
fn collect_scratch_scope_symbols(
  path : String,
  source : String,
) -> Array[ScratchScopeSymbol] {
  if source.trim().to_owned().length() == 0 {
    return []
  }
  let db = @runtime.VibeDb::new()
  db.set_source(path, source)
  let index = @runtime_compile.build_symbol_index(db, [path])
  let out : Array[ScratchScopeSymbol] = []
  for entry in index.entries {
    if entry.path != path {
      continue
    }
    out.push({
      name: entry.name,
      kind: @frontend.symbol_kind_name(entry.kind),
      signature: entry.signature,
      path: entry.path,
      def_id: scratch_scope_symbol_id_from_entry(entry),
    })
  }
  out
}

///|
fn clone_json_map(src : Map[String, Json]) -> Map[String, Json] {
  let out : Map[String, Json] = {}
  for key, value in src {
    out[key] = value
  }
  out
}

///|
fn default_scratch_ns_name() -> String {
  "scratch"
}

///|
fn workspace_probe_entry_path() -> String {
  @vibe_fs.normalize_path(@io.current_dir_or_root() + "/__scratch__.vibe")
}

///|
fn current_workspace_index_root() -> String {
  @codebase.resolve_index_root(workspace_probe_entry_path())
}

///|
fn default_ns_db_rel_path(ns_name : String) -> String {
  ".vibe/namespaces/" + ns_name + ".db"
}

///|
fn vibe_cache_json_path(index_root : String) -> String {
  let vibe_dir = find_vibe_dir(index_root + "/index.vibe")
  vibe_dir + "/cache.json"
}

///|
fn load_vibe_cache_object(index_root : String) -> Map[String, Json] {
  let path = vibe_cache_json_path(index_root)
  let obj : Map[String, Json] = {}
  if !@os_fs.path_exists(path) {
    return obj
  }
  let source = @os_fs.read_file_to_string(path) catch { _ => return obj }
  let parsed : Json = @json.parse(source) catch { _ => return obj }
  match parsed {
    Json::Object(current) => {
      for key, value in current {
        obj[key] = value
      }
      obj
    }
    _ => obj
  }
}

///|
fn write_vibe_cache_object(
  index_root : String,
  obj : Map[String, Json],
) -> Result[Unit, String] {
  let path = vibe_cache_json_path(index_root)
  let dir = @vibe_fs.parent_path(path)
  if !@os_fs.path_exists(dir) {
    @os_fs.create_dir(dir) catch {
      e => return Err("mkdir .vibe: " + e.to_string())
    }
  }
  @os_fs.write_string_to_file(path, Json::object(obj).stringify() + "\n") catch {
    e => return Err("write .vibe/cache.json: " + e.to_string())
  }
  Ok(())
}

///|
fn resolve_active_ns_name_from_cache(cache : Map[String, Json]) -> String {
  match cache.get("active_namespace") {
    Some(Json::String(name)) =>
      if name.trim().to_owned().length() > 0 {
        name.trim().to_owned()
      } else {
        default_scratch_ns_name()
      }
    _ => default_scratch_ns_name()
  }
}

///|
fn resolve_ns_db_rel_path_from_cache(
  cache : Map[String, Json],
  ns_name : String,
) -> String {
  match cache.get("namespaces") {
    Some(Json::Object(namespaces)) =>
      match namespaces.get(ns_name) {
        Some(Json::Object(ns_obj)) =>
          match ns_obj.get("db_path") {
            Some(Json::String(path)) =>
              if path.trim().to_owned().length() > 0 {
                path.trim().to_owned()
              } else {
                default_ns_db_rel_path(ns_name)
              }
            _ => default_ns_db_rel_path(ns_name)
          }
        _ => default_ns_db_rel_path(ns_name)
      }
    _ => default_ns_db_rel_path(ns_name)
  }
}

///|
fn to_absolute_db_path(index_root : String, db_path : String) -> String {
  if db_path.has_prefix("/") {
    @vibe_fs.normalize_path(db_path)
  } else {
    @vibe_fs.normalize_path(index_root + "/" + db_path)
  }
}

///|
fn resolve_scratch_db_path_for_index_root(
  index_root : String,
) -> Result[(String, String), String] {
  match @sys.get_env_var("VIBE_SCRATCH_DB_PATH") {
    Some(path) =>
      if path.trim().to_owned().length() == 0 {
        Err("VIBE_SCRATCH_DB_PATH must not be empty")
      } else {
        Ok((default_scratch_ns_name(), @loader.resolve_entry_path(path)))
      }
    None => {
      let vibe_dir = find_vibe_dir(index_root + "/index.vibe")
      let cache = load_vibe_cache_object(index_root)
      let ns_name = resolve_active_ns_name_from_cache(cache)
      let db_rel = resolve_ns_db_rel_path_from_cache(cache, ns_name)
      let db_path = to_absolute_db_path(index_root, db_rel)
      let next_cache = clone_json_map(cache)
      next_cache["active_namespace"] = Json::string(ns_name)
      let namespaces = match cache.get("namespaces") {
        Some(Json::Object(current)) => clone_json_map(current)
        _ => {}
      }
      let ns_obj = match namespaces.get(ns_name) {
        Some(Json::Object(current)) => clone_json_map(current)
        _ => {}
      }
      let db_path_in_cache = if db_path.has_prefix(vibe_dir) {
        default_ns_db_rel_path(ns_name)
      } else {
        db_path
      }
      ns_obj["db_path"] = Json::string(db_path_in_cache)
      ns_obj["updated_at"] = Json::string(@env.now().to_string())
      namespaces[ns_name] = Json::object(ns_obj)
      next_cache["namespaces"] = Json::object(namespaces)
      match write_vibe_cache_object(index_root, next_cache) {
        Ok(_) => ()
        Err(err) => return Err(err)
      }
      Ok((ns_name, db_path))
    }
  }
}

///|
fn scratch_source_is_import_stmt(source : String) -> Bool {
  source.trim().to_owned().has_prefix("import ")
}

///|
fn scratch_source_is_import_prefix_line(line : String) -> Bool {
  let trimmed = line.trim().to_owned()
  trimmed.length() == 0 ||
  trimmed.has_prefix("//") ||
  trimmed.has_prefix("/*") ||
  trimmed.has_prefix("*") ||
  trimmed.has_prefix("import ")
}

///|
fn scratch_source_contains_import_stmt(
  base_source : String,
  import_stmt : String,
) -> Bool {
  let target = try @parser.parse_ast(import_stmt) catch {
    _ => None
  } noraise {
    ast =>
      match ast.stmts {
        [@vibe_core.Stmt::Import(spec~, source~, ..)] => Some((spec, source))
        _ => None
      }
  }
  match target {
    Some((target_spec, target_source)) => {
      let base_ast = try @parser.parse_ast(base_source) catch {
        _ => None
      } noraise {
        ast => Some(ast)
      }
      match base_ast {
        Some(ast) =>
          for stmt in ast.stmts {
            match stmt {
              @vibe_core.Stmt::Import(spec~, source~, ..) =>
                if spec == target_spec && source == target_source {
                  return true
                }
              _ => ()
            }
          }
        None => ()
      }
    }
    None => ()
  }
  let target = import_stmt.trim().to_owned()
  for line_view in base_source.split("\n") {
    if line_view.to_owned().trim().to_owned() == target {
      return true
    }
  }
  false
}

///|
fn scratch_source_import_block_delta(line : String) -> Int {
  let mut delta = 0
  for ch in line {
    if ch == '{' {
      delta += 1
    } else if ch == '}' {
      delta -= 1
    }
  }
  delta
}

///|
fn append_scratch_db_source_hoist_import(
  base_source : String,
  import_stmt : String,
) -> String {
  if scratch_source_contains_import_stmt(base_source, import_stmt) {
    return base_source
  }
  let head = StringBuilder::new()
  let tail = StringBuilder::new()
  let mut in_prefix = true
  let mut inserted = false
  let mut import_block_depth = 0
  for line_view in base_source.split("\n") {
    let line = line_view.to_owned()
    if import_block_depth > 0 {
      head.write_string(line)
      head.write_char('\n')
      import_block_depth += scratch_source_import_block_delta(line)
      if import_block_depth < 0 {
        import_block_depth = 0
      }
      continue
    }
    if in_prefix && scratch_source_is_import_prefix_line(line) {
      head.write_string(line)
      head.write_char('\n')
      if line.trim().to_owned().has_prefix("import ") {
        import_block_depth = scratch_source_import_block_delta(line)
        if import_block_depth < 0 {
          import_block_depth = 0
        }
      }
      continue
    }
    if in_prefix {
      head.write_string(import_stmt)
      head.write_char('\n')
      inserted = true
      in_prefix = false
    }
    tail.write_string(line)
    tail.write_char('\n')
  }
  if !inserted {
    head.write_string(import_stmt)
    head.write_char('\n')
  }
  head.write_string(tail.to_string())
  head.to_string()
}

///|
fn append_scratch_db_source(base_source : String, expr : String) -> String {
  let trimmed = expr.trim().to_owned()
  if trimmed.length() == 0 {
    return base_source
  }
  let next_source = if scratch_source_is_import_stmt(trimmed) {
    if base_source.length() == 0 {
      trimmed + "\n"
    } else {
      append_scratch_db_source_hoist_import(base_source, trimmed)
    }
  } else {
    let out = StringBuilder::new()
    if base_source.length() > 0 {
      out.write_string(base_source)
      if !base_source.has_suffix("\n") {
        out.write_char('\n')
      }
    }
    out.write_string(trimmed)
    if !trimmed.has_suffix("\n") {
      out.write_char('\n')
    }
    out.to_string()
  }
  let parsed_ok = @parser.parse_ast(next_source) catch {
    _ => return next_source
  }
  let _ = parsed_ok
  let formatted = @parser.format_script(next_source)
  if formatted.has_suffix("\n") {
    formatted
  } else {
    formatted + "\n"
  }
}

///|
fn write_scratch_db_source(
  path : String,
  source : String,
) -> Result[Unit, String] {
  match ensure_parent_dir_for_file(path, "scratch-db") {
    Ok(_) => ()
    Err(err) => return Err(err)
  }
  @os_fs.write_string_to_file(path, source) catch {
    e => return Err("failed to write db `" + path + "`: " + e.to_string())
  }
  Ok(())
}

///|
fn write_output_source(path : String, source : String) -> Result[Unit, String] {
  match ensure_parent_dir_for_file(path, "output") {
    Ok(_) => ()
    Err(err) => return Err(err)
  }
  @os_fs.write_string_to_file(path, source) catch {
    e => return Err("failed to write export `" + path + "`: " + e.to_string())
  }
  Ok(())
}
