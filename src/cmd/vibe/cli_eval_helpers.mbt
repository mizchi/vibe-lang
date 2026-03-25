///|
fn print_eval_result(result : @runtime.EvalResult) -> Unit {
  match result.last {
    Some(value) => println("last: " + value.to_string())
    None => ()
  }
  for effect in result.effects {
    match effect {
      @runtime.Effect::PosixDesugar(message) => println("note: " + message)
      _ => println("effect: " + effect.to_string())
    }
  }
}

///|
fn load_eval_db_source(path : String) -> Result[String, String] {
  if not(@os_fs.path_exists(path)) {
    return Ok("")
  }
  let is_file = @os_fs.is_file(path) catch { _ => false }
  if not(is_file) {
    return Err("db path is not a file: " + path)
  }
  let source = @os_fs.read_file_to_string(path) catch {
    e => return Err("failed to read db `" + path + "`: " + e.to_string())
  }
  Ok(source)
}

///|
struct EvalScopeSymbol {
  name : String
  kind : String
  signature : String
  path : String
  def_id : String
} derive(Show, Eq)

///|
enum EvalRestoreSeverity {
  Fatal
  NonFatal
} derive(Show, Eq)

///|
struct EvalRestoreDiagnosis {
  severity : EvalRestoreSeverity
  category : String
  hint : String
} derive(Show, Eq)

///|
fn eval_restore_diagnose(err_text : String) -> EvalRestoreDiagnosis {
  if err_text.contains("DuplicateDecl") {
    return {
      severity: EvalRestoreSeverity::NonFatal,
      category: "duplicate_decl",
      hint: "run `vibe history reset` to clear duplicate declarations in scratch db",
    }
  }
  if err_text.contains("Parse(") || err_text.contains("ParseError") {
    return {
      severity: EvalRestoreSeverity::NonFatal,
      category: "parse",
      hint: "db source may be stale or syntax mode changed; run `vibe history reset` and re-evaluate needed defs",
    }
  }
  if err_text.contains("UnknownName(") ||
    err_text.contains("UnknownType(") ||
    err_text.contains("UnknownModule(") {
    return {
      severity: EvalRestoreSeverity::NonFatal,
      category: "unresolved_name",
      hint: "required defs/imports are missing; re-run with `--include` or reset scratch db",
    }
  }
  {
    severity: EvalRestoreSeverity::Fatal,
    category: "runtime",
    hint: "inspect db source and runtime error; if needed run `vibe history reset` to recover",
  }
}

///|
fn eval_restore_message(
  db_path : String,
  err_text : String,
  diagnosis : EvalRestoreDiagnosis,
) -> String {
  "failed to restore db `" +
  db_path +
  "` (" +
  diagnosis.category +
  "): " +
  err_text +
  " hint: " +
  diagnosis.hint
}

///|
fn eval_scope_symbol_id_from_entry(entry : @frontend.SymbolEntry) -> String {
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
fn collect_eval_scope_symbols(
  path : String,
  source : String,
) -> Array[EvalScopeSymbol] {
  if source.trim().to_string().length() == 0 {
    return []
  }
  let db = @runtime.VibeDb::new()
  db.set_source(path, source)
  let index = @runtime.build_symbol_index(db, [path])
  let out : Array[EvalScopeSymbol] = []
  for entry in index.entries {
    if entry.path != path {
      continue
    }
    out.push({
      name: entry.name,
      kind: @frontend.symbol_kind_name(entry.kind),
      signature: entry.signature,
      path: entry.path,
      def_id: eval_scope_symbol_id_from_entry(entry),
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
  if not(@os_fs.path_exists(path)) {
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
  if not(@os_fs.path_exists(dir)) {
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
      if name.trim().to_string().length() > 0 {
        name.trim().to_string()
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
              if path.trim().to_string().length() > 0 {
                path.trim().to_string()
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
      if path.trim().to_string().length() == 0 {
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
fn path_last_segment(path : String) -> String {
  let parts : Array[String] = []
  for part in path.split("/") {
    let text = part.to_string()
    if text.length() > 0 {
      parts.push(text)
    }
  }
  if parts.length() == 0 {
    ""
  } else {
    parts[parts.length() - 1]
  }
}

///|
fn load_git_blob_source_from_objects_dir(
  objects_dir : String,
  hash : String,
) -> Result[String, String] {
  if not(@os_fs.path_exists(objects_dir)) {
    return Err("git objects dir not found: " + objects_dir)
  }
  let git_dir = @vibe_fs.parent_path(objects_dir)
  let fs = @osfs.OsFs::new()
  let db = @gitlib.ObjectDb::load_lazy(fs, git_dir) catch {
    e =>
      return Err(
        "failed to load git object db `" + objects_dir + "`: " + e.to_string(),
      )
  }
  let id = @bit.ObjectId::from_hex(hash) catch {
    e => return Err("invalid object hash `" + hash + "`: " + e.to_string())
  }
  let obj = db.get(fs, id) catch {
    e =>
      return Err("failed to read git object `" + hash + "`: " + e.to_string())
  }
  match obj {
    Some(pack_obj) => Ok(@utf8.decode_lossy(pack_obj.data[:]))
    None => Err("git object not found: " + hash)
  }
}

///|
fn eval_source_is_import_stmt(source : String) -> Bool {
  source.trim().to_string().has_prefix("import ")
}

///|
fn eval_source_is_import_prefix_line(line : String) -> Bool {
  let trimmed = line.trim().to_string()
  trimmed.length() == 0 ||
  trimmed.has_prefix("//") ||
  trimmed.has_prefix("/*") ||
  trimmed.has_prefix("*") ||
  trimmed.has_prefix("import ")
}

///|
fn append_eval_db_source_hoist_import(
  base_source : String,
  import_stmt : String,
) -> String {
  let head = StringBuilder::new()
  let tail = StringBuilder::new()
  let mut in_prefix = true
  let mut inserted = false
  for line_view in base_source.split("\n") {
    let line = line_view.to_string()
    if in_prefix && eval_source_is_import_prefix_line(line) {
      head.write_string(line)
      head.write_char('\n')
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
  if not(inserted) {
    head.write_string(import_stmt)
    head.write_char('\n')
  }
  head.write_string(tail.to_string())
  head.to_string()
}

///|
fn append_eval_db_source(base_source : String, expr : String) -> String {
  let trimmed = expr.trim().to_string()
  if trimmed.length() == 0 {
    return base_source
  }
  let next_source = if eval_source_is_import_stmt(trimmed) {
    if base_source.length() == 0 {
      trimmed + "\n"
    } else {
      append_eval_db_source_hoist_import(base_source, trimmed)
    }
  } else {
    let out = StringBuilder::new()
    if base_source.length() > 0 {
      out.write_string(base_source)
      if not(base_source.has_suffix("\n")) {
        out.write_char('\n')
      }
    }
    out.write_string(trimmed)
    if not(trimmed.has_suffix("\n")) {
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
fn write_eval_db_source(path : String, source : String) -> Result[Unit, String] {
  match ensure_parent_dir_for_file(path, "eval") {
    Ok(_) => ()
    Err(err) => return Err(err)
  }
  @os_fs.write_string_to_file(path, source) catch {
    e => return Err("failed to write db `" + path + "`: " + e.to_string())
  }
  Ok(())
}

///|
fn write_eval_export(path : String, source : String) -> Result[Unit, String] {
  match ensure_parent_dir_for_file(path, "eval") {
    Ok(_) => ()
    Err(err) => return Err(err)
  }
  @os_fs.write_string_to_file(path, source) catch {
    e => return Err("failed to write export `" + path + "`: " + e.to_string())
  }
  Ok(())
}
