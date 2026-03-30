///|
fn find_vibe_cache_root(entry_path : String) -> (String, String) {
  let entry_dir = @vibe_fs.parent_path(entry_path)
  // Extract basename without extension
  let mut last_slash = -1
  for i, c in entry_path {
    if c == '/' {
      last_slash = i
    }
  }
  let file_name = if last_slash >= 0 {
    entry_path.unsafe_substring(start=last_slash + 1, end=entry_path.length())
  } else {
    entry_path
  }
  let entry_basename = if file_name.has_suffix(".vibe") {
    file_name.unsafe_substring(start=0, end=file_name.length() - 5)
  } else {
    file_name
  }
  // Walk up to find nearest .vibe directory with cache.json (project root).
  // Sub-module .vibe dirs without cache.json are skipped.
  let mut dir = entry_dir
  for _ in 0..<20 {
    let vibe_dir = dir + "/.vibe"
    if @os_fs.path_exists(vibe_dir) &&
      @os_fs.path_exists(vibe_dir + "/cache.json") {
      // Compute relative path from dir to entry for cache key
      let rel = if entry_dir.length() > dir.length() + 1 {
        entry_dir.unsafe_substring(
          start=dir.length() + 1,
          end=entry_dir.length(),
        )
      } else {
        ""
      }
      // Slugify: replace / with _ and append basename
      let mut key = ""
      for c in rel {
        if c == '/' {
          key = key + "_"
        } else {
          key = key + Char::to_string(c)
        }
      }
      if key.length() > 0 {
        key = key + "_" + entry_basename
      } else {
        key = entry_basename
      }
      return (vibe_dir, key)
    }
    let parent = @vibe_fs.parent_path(dir)
    if parent == dir || parent.length() == 0 {
      break
    }
    dir = parent
  }
  // Fallback: use entry's parent .vibe directory
  (entry_dir + "/.vibe", entry_basename)
}

///|
fn maybe_create_linked_cache_background(entry_path : String) -> Unit {
  let resolved = @loader.resolve_entry_path(entry_path)
  let (vibe_root, cache_key) = find_vibe_cache_root(resolved)
  let cache_dir = vibe_root + "/debug/" + cache_key
  let imports_cache = cache_dir + "/linked_imports.txt"
  if @os_fs.path_exists(imports_cache) {
    return // cache already exists
  }
  // Find our own binary path
  let self_bin = match @sys.get_env_var("_") {
    Some(bin) if bin.has_suffix("vibe.exe") || bin.has_suffix("vibe") => bin
    _ => return // can't find self
  }
  let cmd = "VIBE_INTERNAL_PARENT_PID=" +
    vibe_getpid().to_string() +
    " " +
    shell_quote_command_arg(self_bin) +
    " build --debug " +
    shell_quote_command_arg(entry_path) +
    " -o /dev/null >/dev/null 2>&1 &"
  let _ = c_system(system_command_bytes(cmd))
}

///|
fn save_source_hashes(
  db : @runtime.VibeDb,
  entry : String,
  cache_dir : String,
  hash_cache_path : String,
) -> Unit {
  let _ = cache_dir
  let hashes = collect_source_hash_cache(db, entry, false)
  @os_fs.write_string_to_file(
    hash_cache_path,
    serialize_source_hash_cache(hashes),
  ) catch {
    _ => ()
  }
}

///|
fn collect_source_hash_cache(
  db : @runtime.VibeDb,
  entry : String,
  include_entry : Bool,
) -> Map[String, String] {
  let out : Map[String, String] = {}
  if include_entry {
    match db.get_source(entry) {
      Some(source) if source.length() > 0 =>
        out[entry] = @vibe_core.content_address_hash_string(source)
      _ => ()
    }
  }
  let imports = db.imports(entry)
  for imp in imports {
    match db.get_source(imp.path) {
      Some(source) if source.length() > 0 =>
        out[imp.path] = @vibe_core.content_address_hash_string(source)
      _ => ()
    }
  }
  out
}

///|
fn serialize_source_hash_cache(hashes : Map[String, String]) -> String {
  let keys : Array[String] = []
  for path, _ in hashes {
    keys.push(path)
  }
  keys.sort()
  let buf = StringBuilder::new()
  for path in keys {
    match hashes.get(path) {
      Some(hash) => {
        buf.write_string(path)
        buf.write_char('\t')
        buf.write_string(hash)
        buf.write_char('\n')
      }
      None => ()
    }
  }
  buf.to_string()
}

///|
fn parse_source_hash_cache(text : String) -> Map[String, String] {
  let out : Map[String, String] = {}
  for line_view in text.split("\n") {
    let line = line_view.to_string().trim().to_string()
    if line.length() == 0 {
      continue
    }
    let parts : Array[String] = []
    for part_view in line.split("\t") {
      parts.push(part_view.to_string())
    }
    if parts.length() >= 2 {
      out[parts[0]] = parts[1]
    }
  }
  out
}

///|
fn source_hash_cache_matches(
  saved : Map[String, String],
  current : Map[String, String],
) -> Bool {
  if saved.length() != current.length() {
    return false
  }
  for path, current_hash in current {
    match saved.get(path) {
      Some(saved_hash) => if saved_hash != current_hash { return false }
      None => return false
    }
  }
  true
}

///|
fn run_monolithic_cache_paths(
  entry_path : String,
  use_http_host_runner : Bool,
) -> (String, String, String) {
  let resolved = @loader.resolve_entry_path(entry_path)
  let (vibe_root, cache_key) = find_vibe_cache_root(resolved)
  let cache_dir = vibe_root + "/run/" + cache_key
  let wasm_name = if use_http_host_runner {
    "app_http.wasm"
  } else {
    "app.wasm"
  }
  let hash_name = if use_http_host_runner {
    "source_hashes_http.txt"
  } else {
    "source_hashes.txt"
  }
  (cache_dir, cache_dir + "/" + wasm_name, cache_dir + "/" + hash_name)
}

///|
fn compiled_test_batch_cache_paths(
  entry_path : String,
  use_http_host_runner : Bool,
) -> (String, String, String) {
  let resolved = @loader.resolve_entry_path(entry_path)
  let (vibe_root, cache_key) = find_vibe_cache_root(resolved)
  let cache_dir = vibe_root + "/test/" + cache_key
  let wasm_name = if use_http_host_runner {
    "batch_http.wasm"
  } else {
    "batch.wasm"
  }
  let hash_name = if use_http_host_runner {
    "source_hashes_http.txt"
  } else {
    "source_hashes.txt"
  }
  (cache_dir, cache_dir + "/" + wasm_name, cache_dir + "/" + hash_name)
}

///|
fn parse_linked_imports_cache(text : String) -> Array[@runtime.LinkedImport] {
  let out : Array[@runtime.LinkedImport] = []
  for line_view in text.split("\n") {
    let line = line_view.to_string().trim().to_string()
    if line.length() == 0 {
      continue
    }
    let parts : Array[String] = []
    for part_view in line.split("\t") {
      parts.push(part_view.to_string())
    }
    if parts.length() >= 4 {
      let pc : Result[Int, _] = try? @strconv.parse_int(parts[2])
      let rc : Result[Int, _] = try? @strconv.parse_int(parts[3])
      match (pc, rc) {
        (Ok(param_count), Ok(return_count)) =>
          out.push(@runtime.LinkedImport::{
            module_name: parts[0],
            func_name: parts[1],
            param_count,
            return_count,
          })
        _ => ()
      }
    }
  }
  out
}

///|
/// ADR-0026: Check if all test blocks in a module are effect-free (pure).
/// Returns true when every test body can be safely cached.
fn all_test_blocks_pure(
  db : @runtime.VibeDb,
  entry : String,
  cases : Array[CompiledTestCase],
) -> Bool {
  let env = db.types(entry)
  for case in cases {
    if not(@checker.purity_block(env, case.body)) {
      return false
    }
  }
  true
}

///|
/// ADR-0026: Build the cache key for pure test results.
/// Combines all source hashes into a single deterministic string.
fn pure_test_cache_key(current_hashes : Map[String, String]) -> String {
  let buf = StringBuilder::new()
  let keys : Array[String] = []
  for path, _ in current_hashes {
    keys.push(path)
  }
  keys.sort()
  for path in keys {
    match current_hashes.get(path) {
      Some(hash) => {
        buf.write_string(path)
        buf.write_char(':')
        buf.write_string(hash)
        buf.write_char('\n')
      }
      None => ()
    }
  }
  @vibe_core.content_address_hash_string(buf.to_string())
}

///|
/// ADR-0026: Compute the file paths for pure test result cache.
fn pure_test_result_cache_paths(entry : String) -> (String, String) {
  let resolved = @loader.resolve_entry_path(entry)
  let (vibe_root, cache_key) = find_vibe_cache_root(resolved)
  let cache_dir = vibe_root + "/test/" + cache_key
  let result_path = cache_dir + "/pure_result.txt"
  (cache_dir, result_path)
}

///|
/// ADR-0026: Look up cached test results for pure test files.
/// Returns Some(report) if cache hit (all tests pure + hashes match), None otherwise.
fn pure_test_cache_lookup(
  db : @runtime.VibeDb,
  entry : String,
  ast : @vibe_core.Module,
  cases : Array[CompiledTestCase],
  current_hashes : Map[String, String],
) -> CliTestReport? {
  let _ = ast
  // Skip cache if env var says so
  match @sys.get_env_var("VIBE_NO_TEST_CACHE") {
    Some(v) if v.length() > 0 => return None
    _ => ()
  }
  if not(all_test_blocks_pure(db, entry, cases)) {
    return None
  }
  let (_cache_dir, result_path) = pure_test_result_cache_paths(entry)
  if not(@os_fs.path_exists(result_path)) {
    return None
  }
  let saved_text = @os_fs.read_file_to_string(result_path) catch {
    _ => return None
  }
  // Format: "hash\tcount\n" where hash is the combined source hash
  let lines : Array[String] = []
  for line_view in saved_text.split("\n") {
    let line = line_view.to_string().trim().to_string()
    if line.length() > 0 {
      lines.push(line)
    }
  }
  if lines.length() == 0 {
    return None
  }
  let parts : Array[String] = []
  for part_view in lines[0].split("\t") {
    parts.push(part_view.to_string())
  }
  if parts.length() < 2 {
    return None
  }
  let saved_hash = parts[0]
  let saved_count : Result[Int, _] = try? @strconv.parse_int(parts[1])
  let expected_count = match saved_count {
    Ok(n) => n
    Err(_) => return None
  }
  let current_hash = pure_test_cache_key(current_hashes)
  if saved_hash != current_hash {
    return None
  }
  if expected_count != cases.length() {
    return None
  }
  Some(CliTestReport::{
    total: expected_count,
    passed: expected_count,
    failed: 0,
    failures: [],
  })
}

///|
/// ADR-0026: Save pure test result to cache after successful execution.
fn pure_test_cache_save(
  db : @runtime.VibeDb,
  entry : String,
  ast : @vibe_core.Module,
  cases : Array[CompiledTestCase],
  current_hashes : Map[String, String],
) -> Unit {
  let _ = ast
  if not(all_test_blocks_pure(db, entry, cases)) {
    return
  }
  let (cache_dir, result_path) = pure_test_result_cache_paths(entry)
  match ensure_parent_dir_for_file(result_path, "pure test cache") {
    Ok(_) => {
      let _ = cache_dir
      let hash = pure_test_cache_key(current_hashes)
      let content = hash + "\t" + cases.length().to_string() + "\n"
      @os_fs.write_string_to_file(result_path, content) catch {
        _ => ()
      }
    }
    Err(_) => ()
  }
}
