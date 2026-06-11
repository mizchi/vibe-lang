///|
extern "c" fn c_exit(code : Int) -> Unit = "exit"

///|
extern "c" fn vibe_getpid() -> Int = "getpid"

///|
extern "C" fn vibe_process_exists(pid : Int) -> Int = "vibe_process_exists"

///|
#borrow(cmd)
extern "c" fn c_system(cmd : Bytes) -> Int = "vibe_shell_system"

///|
fn system_command_bytes(cmd : String) -> Bytes {
  let encoded = @utf8.encode(cmd[:])
  let n = encoded.length()
  Bytes::makei(n + 1, fn(i) { if i == n { b'\x00' } else { encoded[i] } })
}

///|
fn print_cli_test_report(path : String, report : CliTestReport) -> Bool {
  let status = if report.failed == 0 { "ok" } else { "fail" }
  println("\{path}: \{status} (\{report.passed}/\{report.total})")
  if report.failed > 0 {
    println("  failures:")
    for failure in report.failures {
      let name = match failure.name {
        Some(n) => n
        None => "<unnamed>"
      }
      println("  - " + name + ": " + failure.error)
    }
  }
  report.failed == 0
}

///|
fn load_entry_db(
  entry_path : String,
) -> Result[(@runtime.VibeDb, String), String] {
  @loader.load_db(entry_path)
}

///|
fn compile_entry_with_db(
  db : @runtime.VibeDb,
  entry : String,
) -> Result[@runtime_compile.CompiledModule, String] {
  let compiled = @runtime_compile.compile_module(db, entry) catch {
    e => return Err(e.to_string())
  }
  Ok(compiled)
}

///|
fn clone_string_map(src : Map[String, String]) -> Map[String, String] {
  let out : Map[String, String] = {}
  for key, value in src {
    out[key] = value
  }
  out
}

///|
fn normalized_prelude_object() -> (String, String) {
  let prelude_ast = @checker.prelude_ast()
  let bundle = @vibe_core.normalize_with_imports(prelude_ast, fn(_import_path) {
    None
  })
  let prelude_hash = bundle.main_hash
  let prelude_module = match bundle.modules.get(prelude_hash) {
    Some(m) => m
    None => @vibe_core.normalize_module(prelude_ast)
  }
  let prelude_json = @vibe_core.serialize_module(prelude_module)
  (prelude_hash, prelude_json)
}

///|
fn sync_prelude_to_codebase(
  entry : String,
  lock : @codebase.LockData,
) -> @codebase.LockData {
  let (prelude_hash, prelude_json) = normalized_prelude_object()
  let vibe_dir = find_vibe_dir(entry)
  let codebase = @codebase.Codebase::new(vibe_dir)
  let _ = codebase.write_object(prelude_hash, prelude_json) catch {
    e => abort("fetch: sync prelude object: " + e.to_string())
  }
  let path_refs = clone_string_map(lock.path_refs)
  let version_refs = clone_string_map(lock.version_refs)
  version_refs["prelude"] = prelude_hash
  let symbol_refs = clone_string_map(lock.symbol_refs)
  symbol_refs["std/prelude"] = prelude_hash
  let module_refs = clone_string_map(lock.module_refs)
  let annotations = clone_string_map(lock.annotations)
  let next_lock = @codebase.LockData::new_with_meta(
    path_refs, version_refs, symbol_refs, module_refs, annotations,
  )
  let lock_path = @codebase.lock_file_path(entry)
  match @codebase.write_lock_data(lock_path, next_lock) {
    Ok(_) => ()
    Err(err) => abort("fetch: sync prelude lock: " + err)
  }
  next_lock
}

///|
fn fetch_cmd(args : Array[String]) -> Unit {
  if args.length() != 1 {
    abort("fetch: expected <file>")
  }
  let entry = @loader.resolve_entry_path(args[0])
  let lock_path = @codebase.lock_file_path(entry)
  let path_locked = match @codebase.update_lock_path_refs(entry) {
    Ok(lock) => lock
    Err(err) => abort("fetch: " + err)
  }
  let updated_lock = sync_prelude_to_codebase(entry, path_locked)
  println(
    "updated lock refs: " +
    lock_path +
    " (" +
    updated_lock.path_refs.length().to_string() +
    " path refs)",
  )
}

///|
fn apply_cmd(args : Array[String]) -> Unit {
  if args.length() != 1 {
    abort("apply: expected <file>")
  }
  match resolve_entry_artifacts(args[0]) {
    Err(err) => abort("apply: " + err)
    Ok((_, entry, lock, index, graph_head)) => {
      let lock_path = @codebase.lock_file_path(entry)
      let index_root = @codebase.resolve_index_root(entry)
      println(
        "applied: " +
        entry +
        " lock=" +
        lock_path +
        " path_refs=" +
        lock.path_refs.length().to_string() +
        " graph_head=" +
        short_hash(graph_head) +
        " defs=" +
        index.defs.length().to_string() +
        " cache=" +
        index_root +
        "/.vibe/cache.json",
      )
    }
  }
}

///|
struct SymbolsCmdOptions {
  entry_path : String
  output_json : Bool
} derive(Debug, Eq)

///|
struct SymbolsRow {
  status : String
  origin : String
  kind : String
  name : String
  path : String
  def_id : String
  signature : String
  module_hash : String
} derive(Debug, Eq)

///|
fn parse_symbols_cmd_args(
  args : Array[String],
) -> Result[SymbolsCmdOptions, String] {
  let mut output_json = false
  let positional : Array[String] = []
  for arg in args {
    if arg == "--json" {
      output_json = true
      continue
    }
    if arg.has_prefix("--") {
      return Err("symbols: unknown option " + arg)
    }
    positional.push(arg)
  }
  if positional.length() != 1 {
    return Err("symbols: expected [--json] <file>")
  }
  Ok({ entry_path: positional[0], output_json })
}

///|
fn symbols_row_to_json(row : SymbolsRow) -> Json {
  let obj : Map[String, Json] = {}
  obj["status"] = Json::string(row.status)
  obj["origin"] = Json::string(row.origin)
  obj["kind"] = Json::string(row.kind)
  obj["name"] = Json::string(row.name)
  obj["path"] = Json::string(row.path)
  obj["hash"] = Json::string(row.def_id)
  obj["short_hash"] = Json::string(short_hash(row.def_id))
  obj["signature"] = Json::string(row.signature)
  obj["module_hash"] = Json::string(row.module_hash)
  Json::object(obj)
}

///|
fn symbols_rows_to_lines(rows : Array[SymbolsRow]) -> Array[String] {
  let lines : Array[String] = []
  for row in rows {
    lines.push(
      row.status +
      "\t" +
      row.origin +
      "\t" +
      row.kind +
      "\t" +
      row.name +
      "\t" +
      row.path +
      "#" +
      short_hash(row.def_id),
    )
  }
  lines.sort()
  lines
}

///|
fn symbols_lock_has_managed_ref(
  module_refs : Map[String, String],
  path : String,
  name : String,
  index_root : String,
  registry_modules : Map[String, String],
  root_version : String,
) -> Bool {
  let canonical_symbol_with_context = @codebase.lock_module_ref_canonical_symbol_with_context(
    path, name, index_root, registry_modules, root_version,
  )
  if module_refs.contains(canonical_symbol_with_context) {
    return true
  }
  let context_prefix = canonical_symbol_with_context + "#"
  for key, _ in module_refs {
    if key.has_prefix(context_prefix) {
      return true
    }
  }
  false
}

///|
fn collect_symbols_rows(
  entry_path : String,
) -> Result[Array[SymbolsRow], String] {
  let resolved = @loader.resolve_entry_path(entry_path)
  let (_db, _entry, lock, index, _graph_head) = match
    resolve_entry_artifacts(resolved) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let index_root = @codebase.resolve_index_root(resolved)
  let registry_modules = match @codebase.load_registry_modules(index_root) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let root_version = match @codebase.load_registry_root_version(index_root) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let scratch_candidates = match
    load_scratch_write_file_candidates(index_root) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let index_defs : Array[WriteFileDef] = []
  for _, def in index.defs {
    index_defs.push(write_file_def_from_index_def(def))
  }
  let scratch_names : Map[String, Bool] = {}
  for candidate in scratch_candidates {
    scratch_names[candidate.def.name] = true
  }
  let index_names : Map[String, Bool] = {}
  for def in index_defs {
    index_names[def.name] = true
  }
  let rows : Array[SymbolsRow] = []
  for def in index_defs {
    let managed = symbols_lock_has_managed_ref(
      lock.module_refs,
      def.path,
      def.name,
      index_root,
      registry_modules,
      root_version,
    )
    let mut has_conflicting_scratch = false
    if scratch_names.contains(def.name) {
      for candidate in scratch_candidates {
        if candidate.def.name != def.name {
          continue
        }
        if !symbols_defs_equivalent(def, candidate.def) {
          has_conflicting_scratch = true
          break
        }
      }
    }
    let status = if has_conflicting_scratch {
      "shadowed"
    } else if managed {
      "managed"
    } else {
      "scratch-only"
    }
    rows.push({
      status,
      origin: "index",
      kind: def.kind,
      name: def.name,
      path: def.path,
      def_id: def.def_id,
      signature: def.signature,
      module_hash: def.module_hash,
    })
  }
  for candidate in scratch_candidates {
    let mut has_equivalent_index = false
    if index_names.contains(candidate.def.name) {
      for def in index_defs {
        if def.name != candidate.def.name {
          continue
        }
        if symbols_defs_equivalent(def, candidate.def) {
          has_equivalent_index = true
          break
        }
      }
    }
    if has_equivalent_index {
      continue
    }
    let status = if index_names.contains(candidate.def.name) {
      "shadowed"
    } else {
      "scratch-only"
    }
    rows.push({
      status,
      origin: candidate.origin,
      kind: candidate.def.kind,
      name: candidate.def.name,
      path: candidate.def.path,
      def_id: candidate.def.def_id,
      signature: candidate.def.signature,
      module_hash: candidate.def.module_hash,
    })
  }
  Ok(rows)
}

///|
fn symbols_defs_equivalent(a : WriteFileDef, b : WriteFileDef) -> Bool {
  a.name == b.name &&
  a.kind == b.kind &&
  a.signature == b.signature &&
  a.module_hash == b.module_hash
}

///|
fn symbols_cmd(args : Array[String]) -> Unit {
  let options = match parse_symbols_cmd_args(args) {
    Ok(v) => v
    Err(err) => abort(err)
  }
  let rows = match collect_symbols_rows(options.entry_path) {
    Ok(v) => v
    Err(err) => abort("symbols: " + err)
  }
  if options.output_json {
    let arr : Array[Json] = []
    for row in rows {
      arr.push(symbols_row_to_json(row))
    }
    println(Json::array(arr).stringify())
    return
  }
  let lines = symbols_rows_to_lines(rows)
  for line in lines {
    println(line)
  }
  println("symbols: " + rows.length().to_string() + " entries")
}

///|
fn resolve_project_root_path(path : String) -> String {
  if path.has_prefix("/") {
    @vibe_fs.normalize_path(path)
  } else {
    @vibe_fs.normalize_path(@io.current_dir_or_root() + "/" + path)
  }
}

///|
fn is_scaffold_seed_vibe_root(vibe_root : String) -> Bool {
  let prelude_dir = @vibe_fs.normalize_path(vibe_root + "/prelude")
  let json_dir = @vibe_fs.normalize_path(vibe_root + "/json")
  let base64_dir = @vibe_fs.normalize_path(vibe_root + "/base64")
  let sha1_dir = @vibe_fs.normalize_path(vibe_root + "/sha1")
  let has_prelude = @os_fs.path_exists(prelude_dir)
  let string_mod = @vibe_fs.normalize_path(prelude_dir + "/string.vibe")
  let json_mod = @vibe_fs.normalize_path(json_dir + "/json.vibe")
  let base64_mod = @vibe_fs.normalize_path(base64_dir + "/base64.vibe")
  let sha1_mod = @vibe_fs.normalize_path(sha1_dir + "/sha1.vibe")
  if !has_prelude {
    return false
  }
  let prelude_is_dir = @os_fs.is_dir(prelude_dir) catch { _ => false }
  if !prelude_is_dir {
    return false
  }
  let json_is_dir = @os_fs.is_dir(json_dir) catch { _ => false }
  let base64_is_dir = @os_fs.is_dir(base64_dir) catch { _ => false }
  let sha1_is_dir = @os_fs.is_dir(sha1_dir) catch { _ => false }
  if !json_is_dir || !base64_is_dir || !sha1_is_dir {
    return false
  }
  @os_fs.path_exists(string_mod) &&
  @os_fs.path_exists(json_mod) &&
  @os_fs.path_exists(base64_mod) &&
  @os_fs.path_exists(sha1_mod)
}

///|
fn resolve_scaffold_seed_vibe_root_from(start : String) -> String? {
  let mut current = resolve_project_root_path(start)
  while true {
    let candidate = @vibe_fs.normalize_path(current + "/vibe")
    if is_scaffold_seed_vibe_root(candidate) {
      return Some(candidate)
    }
    let parent = @vibe_fs.parent_path(current)
    if parent == current || parent.length() == 0 {
      return None
    }
    current = parent
  }
  None
}

///|
fn resolve_scaffold_seed_vibe_root() -> String? {
  resolve_scaffold_seed_vibe_root_from(@io.current_dir_or_root())
}

///|
fn ensure_dir_recursive(path : String) -> Unit {
  if @os_fs.path_exists(path) {
    let is_dir = @os_fs.is_dir(path) catch { _ => false }
    if !is_dir {
      abort("init: path exists and is not directory: " + path)
    }
    return
  }
  let parent = @vibe_fs.parent_path(path)
  if parent != path && parent.length() > 0 {
    ensure_dir_recursive(parent)
  }
  @os_fs.create_dir(path) catch {
    e =>
      if !@os_fs.path_exists(path) {
        abort("init: mkdir failed: " + path + " (" + e.to_string() + ")")
      }
  }
}

///|
fn write_file_if_missing(path : String, content : String) -> Bool {
  if @os_fs.path_exists(path) {
    return false
  }
  @os_fs.write_string_to_file(path, content) catch {
    e => abort("init: write failed: " + path + " (" + e.to_string() + ")")
  }
  true
}

///|
fn copy_seed_tree_if_missing(src_dir : String, dest_dir : String) -> Bool {
  let src_norm = @vibe_fs.normalize_path(src_dir)
  let dest_norm = @vibe_fs.normalize_path(dest_dir)
  if src_norm == dest_norm {
    return false
  }
  if !@os_fs.path_exists(src_norm) {
    return false
  }
  let src_is_dir = @os_fs.is_dir(src_norm) catch { _ => false }
  if !src_is_dir {
    return false
  }
  let mut changed = false
  if @os_fs.path_exists(dest_norm) {
    let dest_is_dir = @os_fs.is_dir(dest_norm) catch { _ => false }
    if !dest_is_dir {
      abort("init: seed target exists and is not directory: " + dest_norm)
    }
  } else {
    ensure_dir_recursive(dest_norm)
    changed = true
  }
  let entries = @os_fs.read_dir(src_norm) catch {
    e =>
      abort("init: read dir failed: " + src_norm + " (" + e.to_string() + ")")
  }
  for entry in entries {
    if entry == "." || entry == ".." {
      continue
    }
    let src_path = @vibe_fs.normalize_path(src_norm + "/" + entry)
    let dest_path = @vibe_fs.normalize_path(dest_norm + "/" + entry)
    let child_is_dir = @os_fs.is_dir(src_path) catch { _ => false }
    if child_is_dir {
      if copy_seed_tree_if_missing(src_path, dest_path) {
        changed = true
      }
    } else if !@os_fs.path_exists(dest_path) {
      let content = match @io.read_string(src_path) {
        Ok(v) => v
        Err(err) => abort("init: read failed: " + src_path + " (" + err + ")")
      }
      @os_fs.write_string_to_file(dest_path, content) catch {
        e =>
          abort("init: write failed: " + dest_path + " (" + e.to_string() + ")")
      }
      changed = true
    }
  }
  changed
}

///|
fn scaffold_project_root_with_seed(
  root : String,
  with_main : Bool,
  seed_vibe_root : String?,
) -> Array[String] {
  ensure_dir_recursive(root)
  let created : Array[String] = []
  let index_source = "export let version = \"0.1.0\"\n"
  let lock_source = "{\"path\":{},\"version\":{},\"symbol\":{},\"module\":{},\"annotation\":{}}\n"
  if write_file_if_missing(root + "/index.vibe", index_source) {
    created.push("index.vibe")
  }
  if write_file_if_missing(root + "/index.lock", lock_source) {
    created.push("index.lock")
  }
  let vibe_dir = root + "/.vibe"
  if !@os_fs.path_exists(vibe_dir) {
    ensure_dir_recursive(vibe_dir)
    created.push(".vibe/")
  }
  match seed_vibe_root {
    Some(seed_root) => {
      let seed_norm = @vibe_fs.normalize_path(seed_root)
      if is_scaffold_seed_vibe_root(seed_norm) {
        if copy_seed_tree_if_missing(
            seed_norm + "/prelude",
            root + "/vibe/prelude",
          ) {
          created.push("vibe/prelude/")
        }
        if copy_seed_tree_if_missing(seed_norm + "/json", root + "/vibe/json") {
          created.push("vibe/json/")
        }
        if copy_seed_tree_if_missing(
            seed_norm + "/base64",
            root + "/vibe/base64",
          ) {
          created.push("vibe/base64/")
        }
        if copy_seed_tree_if_missing(seed_norm + "/sha1", root + "/vibe/sha1") {
          created.push("vibe/sha1/")
        }
      }
    }
    None => ()
  }
  if with_main {
    let main_source = "let main = 1\nexport { main }\n"
    if write_file_if_missing(root + "/main.vibe", main_source) {
      created.push("main.vibe")
    }
  }
  created
}

///|
fn scaffold_project_root(root : String, with_main : Bool) -> Array[String] {
  scaffold_project_root_with_seed(
    root,
    with_main,
    resolve_scaffold_seed_vibe_root(),
  )
}

///|
fn init_cmd(args : Array[String]) -> Unit {
  if args.length() > 1 {
    abort("init: expected [dir]")
  }
  let target = if args.length() == 0 {
    @io.current_dir_or_root()
  } else {
    args[0]
  }
  let root = resolve_project_root_path(target)
  let created = scaffold_project_root(root, false)
  println(
    "initialized: " + root + " created=" + Debug::to_repr(created).to_string(),
  )
}

///|
fn new_cmd(args : Array[String]) -> Unit {
  if args.length() != 1 {
    abort("new: expected <dir>")
  }
  let root = resolve_project_root_path(args[0])
  if @os_fs.path_exists(root) {
    abort("new: target already exists: " + root)
  }
  let created = scaffold_project_root(root, true)
  println("created: " + root + " files=" + Debug::to_repr(created).to_string())
}

///|
fn history_cmd(args : Array[String]) -> Unit {
  if args.length() == 0 {
    abort("history: expected subcommand (reset)")
  }
  let sub = args[0]
  match sub {
    "reset" => {
      let mut hard = false
      let mut i = 1
      while i < args.length() {
        let arg = args[i]
        match arg {
          "--hard" => hard = true
          _ => abort("history reset: unknown arg " + arg)
        }
        i += 1
      }
      let (namespace_name, scratch_db_path) = match resolve_scratch_db_path() {
        Ok(v) => v
        Err(err) => abort("history reset: " + err)
      }
      let mut removed = false
      if @os_fs.path_exists(scratch_db_path) {
        @os_fs.remove_file(scratch_db_path) catch {
          e =>
            abort("history reset: remove scratch db failed: " + e.to_string())
        }
        removed = true
      }
      if hard {
        let index_root = current_workspace_index_root()
        let cache = load_vibe_cache_object(index_root)
        let next_cache = clone_json_map(cache)
        let namespaces = match cache.get("namespaces") {
          Some(Json::Object(current)) => clone_json_map(current)
          _ => {}
        }
        let ns_obj = match namespaces.get(namespace_name) {
          Some(Json::Object(current)) => clone_json_map(current)
          _ => {}
        }
        ns_obj["head"] = Json::string("")
        ns_obj["history_head"] = Json::string("")
        ns_obj["updated_at"] = Json::string(@env.now().to_string())
        namespaces[namespace_name] = Json::object(ns_obj)
        next_cache["active_namespace"] = Json::string(namespace_name)
        next_cache["namespaces"] = Json::object(namespaces)
        match write_vibe_cache_object(index_root, next_cache) {
          Ok(_) => ()
          Err(err) => abort("history reset: " + err)
        }
      }
      println(
        "history reset: namespace=" +
        namespace_name +
        " db=" +
        scratch_db_path +
        " removed=" +
        removed.to_string() +
        " hard=" +
        hard.to_string(),
      )
    }
    _ => abort("history: unknown subcommand: " + sub)
  }
}

///|
fn clamp_source_offset(source : String, offset : Int) -> Int {
  if offset < 0 {
    0
  } else if offset > source.length() {
    source.length()
  } else {
    offset
  }
}

///|
fn source_slice_by_span(source : String, start : Int, end : Int) -> String {
  let s = clamp_source_offset(source, start)
  let e = clamp_source_offset(source, end)
  let stop = if e < s { s } else { e }
  if stop <= s {
    return ""
  }
  source[s:stop].to_owned()
}

///|
fn hash_cmd(args : Array[String]) -> Unit {
  if args.length() != 1 {
    abort("hash: expected <file>")
  }
  let path = @loader.resolve_entry_path(args[0])
  let source = @os_fs.read_file_to_string(path) catch {
    e => abort("hash: " + e.to_string())
  }
  let ast = @parser.parse_ast(source) catch {
    e => abort("hash: " + e.diagnostic().render(args[0], source))
  }
  let hash = @vibe_core.hash_module(ast)
  println(hash)
}

///|
fn save_cmd(args : Array[String]) -> Unit {
  let mut use_git = false
  let files : Array[String] = []
  for arg in args {
    match arg {
      "--git" => use_git = true
      _ => files.push(arg)
    }
  }
  if files.length() != 1 {
    abort("save: expected <file>")
  }
  let file_arg = files[0]
  let path = @loader.resolve_entry_path(file_arg)
  let base_dir = @vibe_fs.parent_path(path)
  let source = @os_fs.read_file_to_string(path) catch {
    e => abort("save: " + e.to_string())
  }
  let ast = @parser.parse_ast(source) catch {
    e => abort("save: " + e.diagnostic().render(file_arg, source))
  }
  // Build import resolver
  let resolve_import = fn(import_path : String) -> @vibe_core.Module? {
    let resolved = if import_path.has_prefix("/") {
      import_path
    } else {
      @vibe_fs.normalize_path(base_dir + "/" + import_path)
    }
    let import_source = @os_fs.read_file_to_string(resolved) catch {
      _ => return None
    }
    let parsed = @parser.parse_ast(import_source) catch { _ => return None }
    Some(parsed)
  }
  // Normalize with all imports resolved to hashes
  let bundle = @vibe_core.normalize_with_imports(ast, resolve_import)
  // Save all modules in the bundle
  let mut saved_count = 0
  for hash, normalized in bundle.modules {
    let json = @vibe_core.serialize_module(normalized)
    if use_git {
      save_module_to_git(json, hash)
    } else {
      save_module_to_vibe(path, json, hash)
    }
    saved_count += 1
  }
  // Update paths.json for the main module
  if !use_git {
    let base_dir = find_vibe_dir(path)
    let codebase = @codebase.Codebase::new(base_dir)
    let _ = codebase.upsert_path_mapping(file_arg, bundle.main_hash) catch {
      e => abort("save: update paths: " + e.to_string())
    }
  }
  // Print result
  let main_short = @vibe_core.short_hash(bundle.main_hash)
  println("saved: \{file_arg} -> \{main_short} (\{saved_count} module(s))")
}

///|
fn save_module_to_vibe(
  base_path : String,
  json : String,
  hash : String,
) -> Unit {
  let base_dir = find_vibe_dir(base_path)
  let codebase = @codebase.Codebase::new(base_dir)
  let _ = codebase.write_object(hash, json) catch {
    e => abort("save: " + e.to_string())
  }
}

///|
fn save_module_to_git(json : String, hash : String) -> Unit {
  let git_dir = find_git_dir()
  let fs = @osfs.OsFs::new()
  let (blob_id, blob_compressed) = @bit.create_blob_string(json)
  let _ = blob_id // The hash is computed from normalized content
  let obj_id = @bit.ObjectId::from_hex(hash) catch {
    e => abort("save: invalid hash: " + e.to_string())
  }
  @gitlib.write_object_bytes(fs, git_dir, obj_id, blob_compressed) catch {
    e => abort("save: git write: " + e.to_string())
  }
}

///|
fn find_git_dir() -> String {
  // Walk up from current directory to find .git
  let mut dir = "."
  for _ in 0..<20 {
    let git_path = dir + "/.git"
    if @os_fs.path_exists(git_path) {
      return git_path
    }
    dir = dir + "/.."
  }
  abort("save --git: .git directory not found")
}

///|
fn find_vibe_dir(path : String) -> String {
  // Resolve storage root from lock/index hierarchy and keep .vibe aggregated there.
  let normalized = if path.has_prefix("/") {
    @vibe_fs.normalize_path(path)
  } else {
    @vibe_fs.normalize_path(@io.current_dir_or_root() + "/" + path)
  }
  let vibe_dir = @codebase.vibe_dir_path(normalized)
  if @os_fs.path_exists(vibe_dir) {
    return vibe_dir
  }
  // Create .vibe directory at the resolved root.
  @os_fs.create_dir(vibe_dir) catch {
    e =>
      abort(
        "save: cannot create .vibe directory at " +
        vibe_dir +
        ": " +
        e.to_string(),
      )
  }
  vibe_dir
}

///|
/// expand <hash|path> [--depth N] [--json] [--source]
/// Expand a module from storage with its dependencies
fn expand_cmd(args : Array[String]) -> Unit {
  if args.length() == 0 {
    println("usage: vibe expand <hash|path> [--depth N] [--json] [--source]")
    return
  }
  let mut target = ""
  let mut depth : Int? = None
  let mut output_json = false
  let mut output_source = false
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if arg == "--depth" || arg == "-d" {
      i += 1
      if i < args.length() {
        depth = Some(@string.parse_int(args[i]) catch { _ => 0 })
      }
    } else if arg == "--json" {
      output_json = true
    } else if arg == "--source" {
      output_source = true
    } else if target == "" {
      target = arg
    }
    i += 1
  }
  if target == "" {
    abort("expand: no target specified")
  }
  // Default to source output if nothing specified
  if !output_json && !output_source {
    output_source = true
  }
  // Find .vibe directory from target path
  let base_dir = if is_hash_like(target) {
    "."
  } else {
    // Get parent directory of target file
    let last_slash = find_last_slash(target)
    if last_slash > 0 {
      target_substring(target, 0, last_slash)
    } else {
      "."
    }
  }
  let vibe_dir = find_vibe_dir_from(base_dir)
  let codebase = @codebase.Codebase::new(vibe_dir)
  // Resolve target to hash
  let main_hash = resolve_target_to_hash(target, codebase)
  let load_module = fn(hash : String) -> @vibe_core.Module? {
    let json = match codebase.read_object(hash) {
      Some(v) => v
      None => return None
    }
    let m = @vibe_core.deserialize_module(json) catch { _ => return None }
    Some(m)
  }
  // Expand the module
  let bundle = @vibe_core.expand_module(main_hash, load_module, depth)
  // Output results
  if output_json {
    println("{")
    println("  \"main_hash\": \"" + bundle.main_hash + "\",")
    println("  \"order\": [")
    for i, hash in bundle.order {
      let comma = if i < bundle.order.length() - 1 { "," } else { "" }
      println("    \"" + hash + "\"" + comma)
    }
    println("  ],")
    println("  \"modules\": {")
    let mut count = 0
    let total = bundle.modules.length()
    for hash, m in bundle.modules {
      count += 1
      let comma = if count < total { "," } else { "" }
      println("    \"" + hash + "\": " + @vibe_core.serialize_module(m) + comma)
    }
    println("  }")
    println("}")
  }
  if output_source {
    println("// Expanded from: " + main_hash)
    let depth_str = match depth {
      None => "unlimited"
      Some(d) => d.to_string()
    }
    println("// Depth: " + depth_str)
    println("// Modules: " + bundle.modules.length().to_string())
    println("")
    // Print modules in topological order (dependencies first)
    for hash in bundle.order {
      match bundle.modules.get(hash) {
        None => ()
        Some(m) => {
          let short = @vibe_core.short_hash(hash)
          println("// --- Module: " + short + " ---")
          // Use JSON format for now since format_ast is not available
          let json = @vibe_core.serialize_module(m)
          println(json)
          println("")
        }
      }
    }
  }
}

///|
fn resolve_scratch_db_path() -> Result[(String, String), String] {
  resolve_scratch_db_path_for_index_root(current_workspace_index_root())
}

///|
fn resolve_target_to_hash(
  target : String,
  codebase : @codebase.Codebase,
) -> String {
  // If it looks like a hash (40 hex chars or prefix), use it directly
  if is_hash_like(target) {
    return resolve_hash_prefix(target, codebase.root())
  }
  // Otherwise, try to look up as a path in paths.json
  match codebase.resolve_path_mapping(target) {
    Some(hash) => hash
    None => abort("expand: cannot resolve target: " + target)
  }
}

///|
fn is_hash_like(s : String) -> Bool {
  if s.length() < 4 || s.length() > 40 {
    return false
  }
  for c in s {
    if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
      return false
    }
  }
  true
}

///|
fn resolve_hash_prefix(prefix : String, vibe_dir : String) -> String {
  if prefix.length() == 40 {
    return prefix
  }
  // Search for matching hash in objects directory
  let objects_dir = vibe_dir + "/objects"
  if prefix.length() >= 2 {
    let prefix_head = prefix_first_two(prefix)
    let subdir = objects_dir + "/" + prefix_head
    if @os_fs.path_exists(subdir) {
      let entries = @os_fs.read_dir(subdir) catch { _ => return prefix }
      for entry in entries {
        let full_hash = prefix_head + entry
        if full_hash.has_prefix(prefix) {
          return full_hash
        }
      }
    }
  }
  prefix
}

///|
fn prefix_first_two(s : String) -> String {
  let buf = StringBuilder::new()
  for i, c in s {
    if i >= 2 {
      break
    }
    buf.write_char(c)
  }
  buf.to_string()
}

///|
fn find_last_slash(s : String) -> Int {
  let mut last = -1
  for i, c in s {
    if c == '/' {
      last = i
    }
  }
  last
}

///|
fn target_substring(s : String, start : Int, end : Int) -> String {
  let buf = StringBuilder::new()
  for i, c in s {
    if i >= start && i < end {
      buf.write_char(c)
    }
  }
  buf.to_string()
}

///|
fn find_vibe_dir_from(start : String) -> String {
  let base = if start == "" { "." } else { start }
  let normalized_base = if base.has_prefix("/") {
    @vibe_fs.normalize_path(base)
  } else {
    @vibe_fs.normalize_path(@io.current_dir_or_root() + "/" + base)
  }
  let probe = @vibe_fs.normalize_path(normalized_base + "/__probe__.vibe")
  let lock_scoped_vibe = @codebase.vibe_dir_path(probe)
  if @os_fs.path_exists(lock_scoped_vibe) {
    return lock_scoped_vibe
  }
  // Backward-compatible fallback: search nearest existing .vibe directory.
  let mut dir = normalized_base
  for _ in 0..<10 {
    let vibe_path = @vibe_fs.normalize_path(dir + "/.vibe")
    if @os_fs.path_exists(vibe_path) {
      return vibe_path
    }
    let parent = @vibe_fs.parent_path(dir)
    if parent == dir || parent.length() == 0 {
      break
    }
    dir = parent
  }
  abort("expand: .vibe directory not found (searched from: " + start + ")")
}
