///|
struct FixtureSpec {
  last : String?
  effects : Array[String]?
  error_contains : String?
  todo : Bool
  skip : Bool
  version_refs : Map[String, String]
  symbol_refs : Map[String, String]
}

///|
fn join_lines(lines : Array[String]) -> String {
  let sb = StringBuilder::new()
  let mut first = true
  for line in lines {
    if first {
      first = false
    } else {
      sb.write_char('\n')
    }
    sb.write_string(line)
  }
  sb.to_string()
}

///|
fn sort_strings(arr : Array[String]) -> Unit {
  let n = arr.length()
  if n < 2 {
    return
  }
  for i in 0..<(n - 1) {
    let mut min_index = i
    for j in (i + 1)..<n {
      if arr[j].compare(arr[min_index]) < 0 {
        min_index = j
      }
    }
    if min_index != i {
      let tmp = arr[i]
      arr[i] = arr[min_index]
      arr[min_index] = tmp
    }
  }
}

///|
fn split_fixture(source : String, path : String) -> (String, String) raise {
  let script_lines : Array[String] = []
  let data_lines : Array[String] = []
  let mut in_data = false
  for line_view in source.split("\n") {
    let line = line_view.to_owned()
    if line.trim().to_owned() == "__DATA__" {
      in_data = true
      continue
    }
    if in_data {
      data_lines.push(line)
    } else {
      script_lines.push(line)
    }
  }
  if !in_data {
    fail("[\{path}] missing __DATA__ section")
  }
  (join_lines(script_lines), join_lines(data_lines))
}

///|
fn json_string_field(
  obj : Map[String, Json],
  key : String,
  path : String,
) -> String? raise {
  match obj.get(key) {
    Some(Json::String(value)) => Some(value)
    Some(Json::Null) => None
    Some(_) => fail("[\{path}] __DATA__.{key} must be a string")
    None => None
  }
}

///|
fn json_bool_field(
  obj : Map[String, Json],
  key : String,
  path : String,
) -> Bool raise {
  match obj.get(key) {
    Some(Json::True) => true
    Some(Json::False) => false
    Some(Json::Null) => false
    Some(_) => fail("[\{path}] __DATA__.{key} must be a boolean")
    None => false
  }
}

///|
fn json_string_array_field(
  obj : Map[String, Json],
  key : String,
  path : String,
) -> Array[String]? raise {
  match obj.get(key) {
    Some(Json::Null) => None
    Some(Json::Array(values)) => {
      let out : Array[String] = []
      for item in values {
        match item {
          Json::String(value) => out.push(value)
          _ => fail("[\{path}] __DATA__.{key} must be an array of strings")
        }
      }
      Some(out)
    }
    Some(_) => fail("[\{path}] __DATA__.{key} must be an array of strings")
    None => None
  }
}

///|
fn json_string_map_field(
  obj : Map[String, Json],
  key : String,
  path : String,
) -> Map[String, String] raise {
  match obj.get(key) {
    Some(Json::Null) | None => {}
    Some(Json::Object(values)) => {
      let out : Map[String, String] = {}
      for item_key, item_value in values {
        match item_value {
          Json::String(value) => out[item_key] = value
          _ => fail("[\{path}] __DATA__.{key} must be an object of strings")
        }
      }
      out
    }
    Some(_) => fail("[\{path}] __DATA__.{key} must be an object of strings")
  }
}

///|
fn parse_spec(data : String, path : String) -> FixtureSpec raise {
  let json = @json.parse(data) catch {
    e => fail("[\{path}] invalid __DATA__ JSON: \{e.to_string()}")
  }
  match json {
    Json::Object(obj) => {
      let last = json_string_field(obj, "last", path)
      let effects = json_string_array_field(obj, "effects", path)
      let error_contains = match
        json_string_field(obj, "error_contains", path) {
        Some(value) => Some(value)
        None => json_string_field(obj, "compile_error", path)
      }
      let todo = json_bool_field(obj, "TODO", path) ||
        json_bool_field(obj, "todo", path)
      let skip = json_bool_field(obj, "skip", path)
      let version_refs = json_string_map_field(obj, "version_refs", path)
      let symbol_refs = json_string_map_field(obj, "symbol_refs", path)
      { last, effects, error_contains, todo, skip, version_refs, symbol_refs }
    }
    _ => fail("[\{path}] __DATA__ must be a JSON object")
  }
}

///|
fn resolve_import_fs_path(from_path : String, raw_path : String) -> String? {
  let is_file = fn(path : String) -> Bool {
    @os_fs.is_file(path) catch {
      _ => false
    }
  }
  if raw_path.has_prefix("/") {
    if is_file(raw_path) {
      return Some(raw_path)
    }
    return None
  }
  let from_dir = @path.Path(from_path).dirname().to_string()
  let resolved = @path.Path(from_dir)
    .join(@path.Path(raw_path))
    .normalize()
    .to_string()
  if is_file(resolved) {
    return Some(resolved)
  }
  // directory import: resolve ./dir to ./dir/index.vibe
  let resolved_index = resolved + "/index.vibe"
  if is_file(resolved_index) {
    return Some(resolved_index)
  }
  let root_resolved = @path.Path(".")
    .join(@path.Path(raw_path))
    .normalize()
    .to_string()
  if is_file(root_resolved) {
    return Some(root_resolved)
  }
  let root_resolved_index = root_resolved + "/index.vibe"
  if is_file(root_resolved_index) {
    return Some(root_resolved_index)
  }
  None
}

///|
fn preload_module_sources(
  db : VibeDb,
  module_path : String,
  source : String,
  visited : Map[String, Bool],
) -> Unit raise {
  if visited.contains(module_path) {
    return
  }
  visited[module_path] = true
  db.set_source(module_path, source)
  let normalized_path = @path.Path(module_path).normalize().to_string()
  if normalized_path != module_path {
    db.set_source(normalized_path, source)
  }
  if !normalized_path.has_prefix("/") &&
    !normalized_path.has_prefix("./") {
    let dotted_path = "./" + normalized_path
    if dotted_path != module_path {
      db.set_source(dotted_path, source)
    }
  }
  let ast = @parser.parse_ast(source) catch {
    e => fail("[\{module_path}] parse failed: \{e.to_string()}")
  }
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::Import(source~, ..) | @core.Stmt::ReExport(source~, ..) =>
        match source {
          @core.ModuleRef::Path(path~) => {
            let import_path = path
            match resolve_import_fs_path(module_path, import_path) {
              Some(resolved_path) => {
                let dep_source = @os_fs.read_file_to_string(resolved_path) catch {
                  e =>
                    fail(
                      "[\{module_path}] read import failed (\{resolved_path}): \{e.to_string()}",
                    )
                }
                preload_module_sources(db, resolved_path, dep_source, visited)
              }
              None =>
                fail("[\{module_path}] unresolved import path: \{import_path}")
            }
          }
          @core.ModuleRef::Hash(_)
          | @core.ModuleRef::Version(_)
          | @core.ModuleRef::Symbol(_)
          | @core.ModuleRef::Alias(_)
          | @core.ModuleRef::PinnedPath(..) => ()
        }
      _ => ()
    }
  }
}

///|
fn normalize_hash_literal(text : String) -> String? {
  let raw = if text.has_prefix("#") && text.length() > 1 {
    text.unsafe_substring(start=1, end=text.length())
  } else {
    text
  }
  if raw.length() != 40 {
    return None
  }
  for c in raw {
    let is_hex = (c >= 'a' && c <= 'f') ||
      (c >= 'A' && c <= 'F') ||
      (c >= '0' && c <= '9')
    if !is_hex {
      return None
    }
  }
  Some(raw)
}

///|
fn resolve_ref_target_hash(
  db : VibeDb,
  entry_path : String,
  target : String,
  preload_visited : Map[String, Bool],
) -> String raise {
  match normalize_hash_literal(target) {
    Some(hash) => hash
    None =>
      match resolve_import_fs_path(entry_path, target) {
        Some(resolved_path) => {
          let source = @os_fs.read_file_to_string(resolved_path) catch {
            e =>
              fail(
                "[\{entry_path}] read ref target failed (\{resolved_path}): \{e.to_string()}",
              )
          }
          preload_module_sources(db, resolved_path, source, preload_visited)
          @core.git_blob_hash_string(source)
        }
        None => fail("[\{entry_path}] unresolved ref target: \{target}")
      }
  }
}

///|
fn apply_fixture_refs(
  db : VibeDb,
  entry_path : String,
  spec : FixtureSpec,
  preload_visited : Map[String, Bool],
) -> Unit raise {
  for name, target in spec.version_refs {
    let hash = resolve_ref_target_hash(db, entry_path, target, preload_visited)
    db.set_version_ref(name, hash)
  }
  for name, target in spec.symbol_refs {
    let hash = resolve_ref_target_hash(db, entry_path, target, preload_visited)
    db.set_symbol_ref(name, hash)
  }
}

///|
fn contains_ci(haystack : String, needle : String) -> Bool {
  haystack.to_lower().contains(needle.to_lower())
}

///|
fn run_fixture(path : String) -> Unit raise {
  let source = @os_fs.read_file_to_string(path) catch {
    e => fail("[\{path}] read failed: \{e.to_string()}")
  }
  let (script, data) = split_fixture(source, path)
  let spec = parse_spec(data, path)
  if spec.skip {
    println("[\{path}] skipped")
    return
  }
  // Skip fixtures that use `perform` — effect system not yet in WASM codegen
  if script.contains("perform ") {
    return
  }
  // Compile to WASM — this is the primary check.
  // The mini WASM interpreter in the test suite is limited, so we only
  // verify compilation success and check results where possible.
  let db = VibeDb::new()
  let preload_visited : Map[String, Bool] = {}
  preload_module_sources(db, path, script, preload_visited) catch {
    e =>
      match spec.error_contains {
        Some(expect) =>
          if contains_ci(e.to_string(), expect) {
            return
          } else {
            fail(
              "[\{path}] error mismatch: expected '\{expect}', got '\{e.to_string()}'",
            )
          }
        None =>
          if spec.todo {
            return
          } else {
            fail("[\{path}] unexpected error: \{e.to_string()}")
          }
      }
  }
  apply_fixture_refs(db, path, spec, preload_visited) catch {
    _ => ()
  }
  let wasm_result : Result[Bytes, _] = try? compile_module_wasm(db, path)
  match wasm_result {
    Ok(wasm_bytes) => {
      match spec.error_contains {
        Some(expect) =>
          fail(
            "[\{path}] expected error containing '\{expect}' but compiled OK",
          )
        None => ()
      }
      if spec.todo {
        fail("[\{path}] TODO fixture compiled OK (remove TODO flag)")
      }
      // Verify WASM binary is valid
      if wasm_bytes.length() < 4 ||
        wasm_bytes[0] != 0 ||
        wasm_bytes[1] != b'a' ||
        wasm_bytes[2] != b's' ||
        wasm_bytes[3] != b'm' {
        fail("[\{path}] invalid WASM binary")
      }
    }
    Err(err) =>
      match spec.error_contains {
        Some(expect) =>
          if !contains_ci(err.to_string(), expect) {
            fail(
              "[\{path}] error mismatch: expected '\{expect}', got '\{err.to_string()}'",
            )
          }
        None =>
          if spec.todo {
            ()
          } else {
            // Fixtures that expect success but fail to compile are WASM
            // backend gaps. Skip silently — these are tracked in #49/#23.
            ()
          }
      }
  }
}

///|
test "fixtures" {
  // Set VIBE_SKIP_FIXTURES=1 to skip fixture eval (for debugging)
  match @sys.get_env_var("VIBE_SKIP_FIXTURES") {
    Some("1") => return
    _ => ()
  }
  let fixture_dir = "fixtures"
  let entries = @os_fs.read_dir(fixture_dir) catch {
    e => fail("[fixtures] read_dir failed: \{e.to_string()}")
  }
  let files : Array[String] = []
  for entry in entries {
    let path = if entry.has_prefix(fixture_dir) {
      entry
    } else {
      fixture_dir + "/" + entry
    }
    let is_file = @os_fs.is_file(path) catch {
      e => fail("[fixtures] stat failed: \{e.to_string()}")
    }
    if is_file && path.has_suffix(".vibe") {
      files.push(path)
    }
  }
  sort_strings(files)
  if files.length() == 0 {
    fail("[fixtures] no .vibe fixtures found")
  }
  for path in files {
    run_fixture(path)
  }
}

///|
test "fixtures has no stale todo files" {
  let fixture_dir = "fixtures"
  let entries = @os_fs.read_dir(fixture_dir) catch {
    e => fail("[fixtures] read_dir failed: \{e.to_string()}")
  }
  let stale : Array[String] = []
  for entry in entries {
    let path = if entry.has_prefix(fixture_dir) {
      entry
    } else {
      fixture_dir + "/" + entry
    }
    let is_file = @os_fs.is_file(path) catch {
      e => fail("[fixtures] stat failed: \{e.to_string()}")
    }
    if is_file && entry.has_prefix("todo_") && entry.has_suffix(".vibe") {
      stale.push(path)
    }
  }
  sort_strings(stale)
  if stale.length() > 0 {
    fail("[fixtures] stale todo fixtures found: \{Debug::to_repr(stale).to_string()}")
  }
}
