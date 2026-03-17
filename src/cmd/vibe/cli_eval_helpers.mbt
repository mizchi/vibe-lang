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
fn eval_scope_symbols_json(scope : Array[EvalScopeSymbol]) -> Json {
  let symbols : Array[Json] = []
  for symbol in scope {
    let obj : Map[String, Json] = {}
    obj["name"] = Json::string(symbol.name)
    obj["kind"] = Json::string(symbol.kind)
    obj["signature"] = Json::string(symbol.signature)
    obj["path"] = Json::string(symbol.path)
    obj["hash"] = Json::string(symbol.def_id)
    obj["short_hash"] = Json::string(short_hash(symbol.def_id))
    symbols.push(Json::object(obj))
  }
  let out : Map[String, Json] = {}
  out["ok"] = Json::boolean(true)
  out["symbols"] = Json::array(symbols)
  Json::object(out)
}

///|
fn eval_scope_signature_for_name(
  scope : Array[EvalScopeSymbol],
  name : String,
) -> String? {
  for symbol in scope {
    if symbol.name == name {
      return Some(symbol.signature)
    }
  }
  None
}

///|
fn validate_eval_type_assertions(
  assertions : Array[EvalTypeAssertion],
  scope : Array[EvalScopeSymbol],
) -> Result[Unit, String] {
  for assertion in assertions {
    let actual = match eval_scope_signature_for_name(scope, assertion.name) {
      Some(signature) => signature
      None => return Err("assert symbol not found: " + assertion.name)
    }
    if actual != assertion.expected_signature {
      return Err(
        "assert type mismatch: " +
        assertion.name +
        " expected `" +
        assertion.expected_signature +
        "` actual `" +
        actual +
        "`",
      )
    }
  }
  Ok(())
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
    @os_fs.mkdir(dir) catch {
      e => return Err("mkdir .vibe: " + e.to_string())
    }
  }
  @os_fs.write_string_to_file(
    path,
    Json::object(obj).stringify() + "\n",
  ) catch {
    e => return Err("write .vibe/cache.json: " + e.to_string())
  }
  Ok(())
}

///|
fn resolve_active_ns_name_from_cache(
  vbundle : Map[String, Json],
) -> String {
  match vbundle.get("active_namespace") {
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
  vbundle : Map[String, Json],
  ns_name : String,
) -> String {
  match vbundle.get("namespaces") {
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
      let db_path_in_vbundle = if db_path.has_prefix(vibe_dir) {
        default_ns_db_rel_path(ns_name)
      } else {
        db_path
      }
      ns_obj["db_path"] = Json::string(db_path_in_vbundle)
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
fn eval_include_base_dir(options : EvalCmdOptions) -> String {
  match options.db_path {
    Some(path) => @vibe_fs.parent_path(@loader.resolve_entry_path(path))
    None => "."
  }
}

///|
fn eval_include_candidate_paths(
  include_spec : String,
  base_dir : String,
  include_lib_dir : String,
) -> Array[String] {
  let cwd_path = resolve_eval_include_path(".", include_spec, include_lib_dir)
  let base_path = resolve_eval_include_path(
    base_dir, include_spec, include_lib_dir,
  )
  if base_path == cwd_path {
    [cwd_path]
  } else {
    [cwd_path, base_path]
  }
}

///|
fn render_eval_include_candidates(paths : Array[String]) -> String {
  if paths.length() == 0 {
    ""
  } else if paths.length() == 1 {
    paths[0]
  } else {
    "tried: " + paths.join(", ")
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
fn parse_include_hash_alias(source : String) -> String? {
  let trimmed = source.trim().to_string()
  if trimmed.has_prefix("hash:") {
    let hash = trimmed
      .unsafe_substring(start=5, end=trimmed.length())
      .trim()
      .to_string()
    if hash.length() == 0 {
      None
    } else {
      Some(hash)
    }
  } else {
    let parsed : Json = @json.parse(trimmed) catch { _ => return None }
    match parsed {
      Json::Object(obj) =>
        match obj.get("hash") {
          Some(Json::String(hash)) => {
            let normalized = hash.trim().to_string()
            if normalized.length() == 0 {
              None
            } else {
              Some(normalized)
            }
          }
          _ => None
        }
      _ => None
    }
  }
}

///|
fn parse_include_vbundle_entry_source(source : String) -> String? {
  let trimmed = source.trim().to_string()
  if trimmed.length() == 0 {
    return None
  }
  let parsed : Json = @json.parse(trimmed) catch { _ => return None }
  let root = match parsed {
    Json::Object(obj) => obj
    _ => return None
  }
  let is_vbundle = match root.get("format") {
    Some(Json::String(format)) => format == "vbundle-1"
    _ => false
  }
  if not(is_vbundle) {
    return None
  }
  let entry_hash = match root.get("meta") {
    Some(Json::Object(meta)) =>
      match meta.get("entry_hash") {
        Some(Json::String(hash)) => bundle_normalize_hash(hash)
        _ => ""
      }
    _ => ""
  }
  let objects = match root.get("objects") {
    Some(Json::Object(obj)) => obj
    _ => return None
  }
  if entry_hash.length() > 0 {
    match objects.get(entry_hash) {
      Some(Json::String(content)) => return Some(content)
      _ => ()
    }
  }
  if objects.length() == 1 {
    for _, value in objects {
      match value {
        Json::String(content) => return Some(content)
        _ => return None
      }
    }
  }
  None
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
fn try_load_hash_source_from_root(root : String, hash : String) -> String? {
  let codebase = @codebase.Codebase::new(root)
  match codebase.read_object(hash) {
    Some(content) => return Some(content)
    None => ()
  }
  let objects_dir = @vibe_fs.normalize_path(root + "/.git/objects")
  match load_git_blob_source_from_objects_dir(objects_dir, hash) {
    Ok(content) => Some(content)
    Err(_) => None
  }
}

///|
fn load_eval_include_source(
  include_spec : String,
  base_dir : String,
  include_lib_dir : String,
) -> Result[String, String] {
  let candidates = eval_include_candidate_paths(
    include_spec, base_dir, include_lib_dir,
  )
  let mut path : String? = None
  for candidate in candidates {
    if not(@os_fs.path_exists(candidate)) {
      continue
    }
    let is_file = @os_fs.is_file(candidate) catch { _ => false }
    if not(is_file) {
      return Err(
        "include path is not a file: " + include_spec + " -> " + candidate,
      )
    }
    path = Some(candidate)
    break
  }
  let resolved_path = match path {
    Some(v) => v
    None =>
      return Err(
        "include not found: " +
        include_spec +
        " -> " +
        render_eval_include_candidates(candidates),
      )
  }
  let source = @os_fs.read_file_to_string(resolved_path) catch {
    e =>
      return Err(
        "failed to read include `" +
        include_spec +
        "` (" +
        resolved_path +
        "): " +
        e.to_string(),
      )
  }
  match parse_include_hash_alias(source) {
    Some(hash) => {
      let roots : Array[String] = []
      let include_parent = @vibe_fs.parent_path(resolved_path)
      if path_last_segment(include_parent) == "vibe" {
        roots.push(@vibe_fs.parent_path(include_parent))
      }
      if roots.length() == 0 || roots[0] != include_lib_dir {
        roots.push(include_lib_dir)
      }
      for root in roots {
        match try_load_hash_source_from_root(root, hash) {
          Some(content) =>
            match parse_include_vbundle_entry_source(content) {
              Some(entry_source) => return Ok(entry_source)
              None => return Ok(content)
            }
          None => ()
        }
      }
      Err(
        "hash alias `" +
        include_spec +
        "` unresolved: object `" +
        hash +
        "` not found in local stores",
      )
    }
    None =>
      match parse_include_vbundle_entry_source(source) {
        Some(entry_source) => Ok(entry_source)
        None => Ok(source)
      }
  }
}

///|
fn eval_test_target_from_sidecar_entry(entry : String) -> String? {
  let file_name = path_last_segment(entry)
  if not(file_name.has_suffix("_test.vibe")) || file_name.length() <= 10 {
    return None
  }
  let target = file_name.unsafe_substring(start=0, end=file_name.length() - 10)
  if target.length() == 0 {
    None
  } else {
    Some(target)
  }
}

///|
fn eval_collect_run_target_candidates(
  db_path : String,
  source : String,
) -> Array[String] {
  let out : Array[String] = []
  let seen : Map[String, Bool] = {}
  let scope = collect_eval_scope_symbols(db_path, source)
  for symbol in scope {
    if not(symbol.signature.contains("->")) {
      continue
    }
    if seen.get(symbol.name) is None {
      seen[symbol.name] = true
      out.push(symbol.name)
    }
  }
  let tests_dir = eval_tests_dir_path(db_path)
  if @os_fs.path_exists(tests_dir) {
    let entries = @os_fs.read_dir(tests_dir) catch { _ => [] }
    for entry in entries {
      match eval_test_target_from_sidecar_entry(entry) {
        Some(target) =>
          if seen.get(target) is None {
            seen[target] = true
            out.push(target)
          }
        None => ()
      }
    }
  }
  out.sort_by((a, b) => String::compare(a, b))
  out
}

///|
fn eval_run_missing_test_target_message(
  db_path : String,
  source : String,
) -> String {
  let candidates = eval_collect_run_target_candidates(db_path, source)
  if candidates.length() == 0 {
    "eval: --run requires --test-for (no test targets found; add tests with --test-for <name> <test ...>)"
  } else {
    "eval: --run requires --test-for (candidates: " +
    candidates.join(", ") +
    ")"
  }
}

///|
fn append_eval_db_source(base_source : String, expr : String) -> String {
  let trimmed = expr.trim().to_string()
  if trimmed.length() == 0 {
    return base_source
  }
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
  let next_source = out.to_string()
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
fn eval_tests_dir_path(db_path : String) -> String {
  if db_path.has_suffix(".db") && db_path.length() > 3 {
    db_path.unsafe_substring(start=0, end=db_path.length() - 3) + ".tests"
  } else {
    db_path + ".tests"
  }
}

///|
fn is_test_target_safe_char(ch : Char) -> Bool {
  (ch >= 'a' && ch <= 'z') ||
  (ch >= 'A' && ch <= 'Z') ||
  (ch >= '0' && ch <= '9') ||
  ch == '_' ||
  ch == '-'
}

///|
fn sanitize_eval_test_target(target : String) -> String {
  let out = StringBuilder::new()
  for _, ch in target {
    if is_test_target_safe_char(ch) {
      out.write_char(ch)
    } else {
      out.write_char('_')
    }
  }
  let value = out.to_string()
  if value.length() == 0 {
    "unnamed"
  } else {
    value
  }
}

///|
fn eval_test_file_path(db_path : String, target : String) -> String {
  eval_tests_dir_path(db_path) +
  "/" +
  sanitize_eval_test_target(target) +
  "_test.vibe"
}

///|
fn eval_test_cache_dir_path(db_path : String) -> String {
  eval_tests_dir_path(db_path) + "/.cache"
}

///|
fn eval_test_cache_file_path(db_path : String, target : String) -> String {
  eval_test_cache_dir_path(db_path) +
  "/" +
  sanitize_eval_test_target(target) +
  ".ok"
}

///|
fn load_eval_test_cache_hash(db_path : String, target : String) -> String? {
  let cache_path = eval_test_cache_file_path(db_path, target)
  if not(@os_fs.path_exists(cache_path)) {
    return None
  }
  let is_file = @os_fs.is_file(cache_path) catch { _ => false }
  if not(is_file) {
    return None
  }
  let source = @os_fs.read_file_to_string(cache_path) catch { _ => return None }
  let hash = source.trim().to_string()
  if hash.length() == 0 {
    None
  } else {
    Some(hash)
  }
}

///|
fn write_eval_test_cache_hash(
  db_path : String,
  target : String,
  closure_hash : String,
) -> Result[Unit, String] {
  write_eval_db_source(
    eval_test_cache_file_path(db_path, target),
    closure_hash + "\n",
  )
}

///|
fn clear_eval_test_cache_hash(db_path : String, target : String) -> Unit {
  let cache_path = eval_test_cache_file_path(db_path, target)
  if @os_fs.path_exists(cache_path) {
    ignore(@os_fs.remove_file(cache_path) catch { _ => () })
  }
}

///|
fn eval_test_dep_snapshot_hash(
  test_source : String,
  target : String,
  dep_snapshot : Map[String, String],
) -> String {
  let sorted = dep_snapshot.to_array()
  sorted.sort_by((a, b) => {
    let (a_name, _) = a
    let (b_name, _) = b
    String::compare(a_name, b_name)
  })
  let out = StringBuilder::new()
  out.write_string("target:")
  out.write_string(target)
  out.write_char('\n')
  for item in sorted {
    let (name, addr) = item
    out.write_string(name)
    out.write_char(':')
    out.write_string(addr)
    out.write_char('\n')
  }
  out.write_string("tests:")
  out.write_string(@vibe_core.git_blob_hash_string(test_source))
  out.write_char('\n')
  @vibe_core.git_blob_hash_string(out.to_string())
}

///|
fn eval_test_closure_hash_from_runtime(
  rt : @runtime.Runtime,
  syntax_mode : @runtime.ParserMode,
  test_source : String,
  target : String,
) -> Result[String?, String] {
  let target_addr = match rt.get_addr(target) {
    Some(addr) => addr
    None =>
      match rt.get_hash(target) {
        Some(addr) => addr
        None => return Ok(None)
      }
  }
  let dep_snapshot = rt.collect_script_test_dep_snapshot_with_mode(
    test_source, syntax_mode,
  ) catch {
    e => return Err("failed to analyze test deps: " + e.to_string())
  }
  let deps = match dep_snapshot {
    Some(snapshot) => snapshot.copy()
    None => {}
  }
  deps[target] = target_addr
  Ok(Some(eval_test_dep_snapshot_hash(test_source, target, deps)))
}

///|
fn eval_test_target_is_pure(rt : @runtime.Runtime, target : String) -> Bool {
  match rt.type_env().get_purity(target) {
    Some(v) => v
    None => false
  }
}

///|
fn run_eval_sidecar_tests(
  db_source : String,
  test_source : String,
  include_sources : Array[String],
  syntax_mode : @runtime.ParserMode,
  features : @runtime.RuntimeFeatureFlags,
) -> Result[@runtime.TestReport, String] {
  let rt = new_runtime_with_features(features)
  for include_source in include_sources {
    if include_source.trim().to_string().length() == 0 {
      continue
    }
    let _ = rt.eval_script_with_mode(include_source, syntax_mode) catch {
      e => return Err("failed to restore include for --run: " + e.to_string())
    }
  }
  if db_source.trim().to_string().length() > 0 {
    let _ = rt.eval_script_with_mode(db_source, syntax_mode) catch {
      e => return Err("failed to restore db for --run: " + e.to_string())
    }
  }
  let report = rt.run_script_tests_with_mode(test_source, syntax_mode) catch {
    e => return Err("failed to run sidecar tests: " + e.to_string())
  }
  Ok(report)
}

///|
fn write_eval_test_source(
  db_path : String,
  target : String,
  expr : String,
) -> Result[String, String] {
  let test_path = eval_test_file_path(db_path, target)
  let current = match load_eval_db_source(test_path) {
    Ok(source) => source
    Err(err) => return Err(err)
  }
  let next = append_eval_db_source(current, expr)
  match write_eval_db_source(test_path, next) {
    Ok(_) => Ok(test_path)
    Err(err) => Err(err)
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

///|
fn eval_cmd(
  args : Array[String],
  syntax_mode : @runtime.ParserMode,
  features : @runtime.RuntimeFeatureFlags,
  enable_llm? : Bool = false,
) -> Unit {
  let options = match parse_eval_cmd_options(args, "eval") {
    Ok(opts) => opts
    Err(msg) => abort(msg)
  }
  let rt = new_cli_runtime(features, enable_llm~)
  let (namespace_name, db_path) = match options.db_path {
    Some(path) => ("explicit", @loader.resolve_entry_path(path))
    None =>
      match resolve_scratch_db_path() {
        Ok(v) => v
        Err(err) => abort("eval: " + err)
      }
  }
  let mut next_source = ""
  let include_base_dir = eval_include_base_dir(options)
  let include_lib_dir = resolve_vibe_lib_dir(@io.current_dir_or_root())
  let include_sources : Array[String] = []
  let mut eval_test_sidecar_path : String? = None
  for include_spec in options.include_paths {
    let include_source = match
      load_eval_include_source(include_spec, include_base_dir, include_lib_dir) {
      Ok(source) => source
      Err(err) => abort("eval: " + err)
    }
    include_sources.push(include_source)
    if include_source.trim().length() > 0 {
      let _ = rt.eval_script_with_mode(include_source, syntax_mode) catch {
        e =>
          abort(
            "eval: failed to load include `" +
            include_spec +
            "`: " +
            e.to_string(),
          )
      }
    }
  }
  let source = match load_eval_db_source(db_path) {
    Ok(content) => content
    Err(err) => abort("eval: " + err)
  }
  next_source = source
  if source.trim().length() > 0 {
    try rt.eval_script_with_mode(source, syntax_mode) |> ignore catch {
      e => {
        let err = e.to_string()
        let diagnosis = eval_restore_diagnose(err)
        let message = eval_restore_message(db_path, err, diagnosis)
        match diagnosis.severity {
          EvalRestoreSeverity::Fatal => abort("eval: " + message)
          EvalRestoreSeverity::NonFatal => println("warn: " + message)
        }
      }
    }
  }
  match options.expr {
    Some(expr) => {
      let result = rt.eval_script_with_mode(expr, syntax_mode) catch {
        e => abort("eval: " + e.to_string())
      }
      print_eval_result(result)
      match extract_let_name(expr) {
        Some(name) =>
          match rt.get_addr(name) {
            Some(addr) => println("addr: " + name + "#" + short_hash(addr))
            None => ()
          }
        None => ()
      }
      match options.test_target {
        Some(target) =>
          match write_eval_test_source(db_path, target, expr) {
            Ok(path) => {
              eval_test_sidecar_path = Some(path)
              println(
                "test stored: target=" +
                target +
                " path=" +
                path +
                " db=" +
                db_path,
              )
            }
            Err(err) => abort("eval: " + err)
          }
        None => {
          next_source = append_eval_db_source(next_source, expr)
          match write_eval_db_source(db_path, next_source) {
            Ok(_) => ()
            Err(err) => abort("eval: " + err)
          }
        }
      }
    }
    None => ()
  }
  if options.test_run {
    let target = match options.test_target {
      Some(v) => v
      None => abort(eval_run_missing_test_target_message(db_path, next_source))
    }
    let test_path = match eval_test_sidecar_path {
      Some(path) => path
      None => eval_test_file_path(db_path, target)
    }
    let test_source = match load_eval_db_source(test_path) {
      Ok(v) => v
      Err(err) => abort("eval: " + err)
    }
    if test_source.trim().to_string().length() == 0 {
      abort("eval: no tests found for --test-for `" + target + "`")
    }
    let pure_target = eval_test_target_is_pure(rt, target)
    if not(pure_target) {
      clear_eval_test_cache_hash(db_path, target)
    }
    let closure_hash = if pure_target {
      match
        eval_test_closure_hash_from_runtime(
          rt, syntax_mode, test_source, target,
        ) {
        Ok(value) => value
        Err(err) => abort("eval: " + err)
      }
    } else {
      None
    }
    let mut should_run = true
    match closure_hash {
      Some(hash) =>
        match load_eval_test_cache_hash(db_path, target) {
          Some(cached_hash) =>
            if cached_hash == hash {
              println(
                test_path +
                ": cache hit (pure, closure=" +
                short_hash(hash) +
                ")",
              )
              should_run = false
            }
          None => ()
        }
      None => ()
    }
    if should_run {
      let report = match
        run_eval_sidecar_tests(
          next_source, test_source, include_sources, syntax_mode, features,
        ) {
        Ok(v) => v
        Err(err) => abort("eval: " + err)
      }
      if not(print_test_report(test_path, report)) {
        clear_eval_test_cache_hash(db_path, target)
        abort("eval: test-for failed: " + target)
      }
      match closure_hash {
        Some(hash) =>
          match write_eval_test_cache_hash(db_path, target, hash) {
            Ok(_) => ()
            Err(err) => abort("eval: " + err)
          }
        None => clear_eval_test_cache_hash(db_path, target)
      }
    }
  }
  let scope_symbols = collect_eval_scope_symbols(db_path, next_source)
  match validate_eval_type_assertions(options.assertions, scope_symbols) {
    Ok(_) => ()
    Err(err) => abort("eval: " + err)
  }
  if options.inspect_scope {
    println(eval_scope_symbols_json(scope_symbols).stringify())
  }
  match options.export_path {
    Some(path) => {
      if next_source.trim().length() == 0 {
        abort("eval: no source to export")
      }
      match write_eval_export(path, next_source) {
        Ok(_) => ()
        Err(err) => abort("eval: " + err)
      }
      println("exported: " + path)
    }
    None => ()
  }
  if namespace_name != "explicit" {
    println("namespace: " + namespace_name + " db=" + db_path)
  }
}
