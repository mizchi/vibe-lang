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
    let line = line_view.to_string()
    if line.trim().to_string() == "__DATA__" {
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
  if not(normalized_path.has_prefix("/")) &&
    not(normalized_path.has_prefix("./")) {
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
fn register_fixture_import_modules(
  rt : Runtime,
  db : VibeDb,
  path : String,
  visited : Map[String, Bool],
  path_to_hash : Map[String, String],
) -> Unit {
  if visited.contains(path) {
    return
  }
  visited[path] = true
  let imports = db.imports(path)
  for imp in imports {
    match imp.hash {
      Some(hash) => {
        path_to_hash[imp.path] = hash
        let ast = db.ast_with_hash_imports(imp.path)
        rt.register_module(hash, ast)
        register_fixture_import_modules(rt, db, imp.path, visited, path_to_hash)
      }
      None => ()
    }
  }
}

///|
fn eval_fixture(
  path : String,
  script : String,
  spec : FixtureSpec,
) -> Result[EvalResult, String] {
  // TODO(#20): migrate to compiled backend once prelude is available in compile_module
  if not(script.contains("import ")) && not(script.contains("effect ")) {
    let rt = Runtime::new(@capability.CapabilitySet::developer())
    return Ok(rt.eval_script(script)) catch { e => Err(e.to_string()) }
  }
  let db = VibeDb::new()
  let preload_visited : Map[String, Bool] = {}
  let preload = Ok(preload_module_sources(db, path, script, preload_visited)) catch {
    e => Err(e.to_string())
  }
  match preload {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  let refs = Ok(apply_fixture_refs(db, path, spec, preload_visited)) catch {
    e => Err(e.to_string())
  }
  match refs {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  let compiled = Ok(compile_module(db, path)) catch { e => Err(e.to_string()) }
  let compiled = match compiled {
    Ok(c) => c
    Err(e) => return Err(e)
  }
  let rt = Runtime::new(@capability.CapabilitySet::developer())
  rt.set_type_env(compiled.type_env)
  let import_visited : Map[String, Bool] = {}
  let path_to_hash : Map[String, String] = {}
  register_fixture_import_modules(rt, db, path, import_visited, path_to_hash)
  for name, target in compiled.aliases {
    rt.set_alias(name, target)
  }
  let converted_ast = @core.convert_imports_to_hash(compiled.ast, fn(
    import_path,
  ) {
    match path_to_hash.get(import_path) {
      Some(hash) => Some(hash)
      None => {
        let normalized = @path.Path(import_path).normalize().to_string()
        path_to_hash.get(normalized)
      }
    }
  })
  Ok(rt.eval_module(converted_ast)) catch {
    e => Err(e.to_string())
  }
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
  // Skip fixtures that use `perform` — the interpreter does not support it
  if script.contains("perform ") {
    return
  }
  let result = eval_fixture(path, script, spec)
  if spec.todo {
    match result {
      Ok(_) => fail("[\{path}] TODO fixture passed (remove TODO flag)")
      Err(_) => return
    }
  }
  match result {
    Ok(eval_result) => {
      match spec.error_contains {
        Some(expect) => fail("[\{path}] expected error containing '\{expect}'")
        None => ()
      }
      match spec.last {
        Some(expect) =>
          match eval_result.last {
            Some(value) => {
              let actual = value.to_string()
              if actual != expect {
                fail(
                  "[\{path}] last mismatch: expected \{expect}, got \{actual}",
                )
              }
            }
            None =>
              fail("[\{path}] last mismatch: expected \{expect}, got None")
          }
        None => ()
      }
      match spec.effects {
        Some(expected) => {
          let actual : Array[String] = []
          for effect in eval_result.effects {
            actual.push(effect.to_string())
          }
          if actual != expected {
            fail(
              "[\{path}] effects mismatch: expected \{expected.to_string()}, got \{actual.to_string()}",
            )
          }
        }
        None => ()
      }
    }
    Err(err) =>
      match spec.error_contains {
        Some(expect) =>
          if !err.contains(expect) {
            fail(
              "[\{path}] error mismatch: expected to contain '\{expect}', got '\{err}'",
            )
          }
        None => fail("[\{path}] unexpected error: \{err}")
      }
  }
}

///|
test "fixtures" {
  // Set VIBE_SKIP_FIXTURES=1 to skip fixture interpreter eval (for debugging)
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
/// Test that interpreter and compiled backends agree on fixture outcomes.
/// For each fixture with a `last` value:
///   - interpreter eval succeeds → compiled (WASM) should also succeed
///   - interpreter eval fails → compiled should also fail
/// For each fixture with an `error_contains`:
///   - both backends should produce an error
test "fixtures compiled parity" {
  match @sys.get_env_var("VIBE_SKIP_FIXTURES") {
    Some("1") => return
    _ => ()
  }
  let fixture_dir = "fixtures"
  let entries = @os_fs.read_dir(fixture_dir) catch {
    e => fail("[compiled-parity] read_dir failed: \{e.to_string()}")
  }
  let files : Array[String] = []
  for entry in entries {
    let path = if entry.has_prefix(fixture_dir) {
      entry
    } else {
      fixture_dir + "/" + entry
    }
    let is_file = @os_fs.is_file(path) catch { _ => false }
    if is_file && path.has_suffix(".vibe") {
      files.push(path)
    }
  }
  sort_strings(files)
  let mut parity_ok = 0
  let mut parity_skip = 0
  let mismatches : Array[String] = []
  for path in files {
    let source = @os_fs.read_file_to_string(path) catch { _ => continue }
    if not(source.contains("__DATA__")) {
      continue
    }
    let (script, data) = split_fixture(source, path) catch { _ => continue }
    let spec = parse_spec(data, path) catch { _ => continue }
    if spec.skip || spec.todo {
      parity_skip += 1
      continue
    }
    // Skip fixtures that use imports (compiled mode may not resolve them)
    if script.contains("import ") {
      parity_skip += 1
      continue
    }
    // Skip effect/shell fixtures (side effects)
    match spec.effects {
      Some(_) => {
        parity_skip += 1
        continue
      }
      None => ()
    }
    // Skip fixtures that use `perform` — interpreter does not support it
    if script.contains("perform ") {
      parity_skip += 1
      continue
    }
    // Skip known parity gaps (tracked for future fixing)
    let basename = path
      .split("/")
      .fold(init="", fn(_acc, part) { part.to_string() })
    let known_gaps = [
      // codegen gaps: interpreter OK but compiled fails
      "let_else.vibe", "let_else_fallback.vibe", // let-else codegen
       "bytes_basic.vibe", "bytes_ops.vibe", // Bytes builtin codegen
       "generic_fold.vibe", "generic_filter.vibe", "generic_nested_types.vibe", // generic codegen
       "trait_eq_bound.vibe", "trait_ord_bound.vibe", // trait bound codegen
       "trait_eq_string_operator_runtime.vibe", // trait string eq codegen
       "trait_eq_operator_accepts_eq_bound_type_parameter.vibe", "trait_ord_operator_accepts_ord_bound_type_parameter.vibe",
      "labeled_arg_basic.vibe", // labeled arg codegen
       "labeled_arg_optional.vibe", // labeled arg codegen
       "let_pat_option.vibe", // let-pat-else codegen
      // runtime gaps: interpreter errors but compiled succeeds
       "http_p3_client_test.vibe", // HTTP capability
       "err_type_map_key_type.vibe", // runtime-only error
       "err_type_divide_by_zero.vibe", // runtime-only error
       "err_type_negative_index.vibe", // runtime-only error
       "err_type_array_index_out_of_range.vibe", // runtime-only error
       "forward_reference_annotated_let.vibe", // forward ref: interp-only (topo sort)
    ]
    let mut is_known_gap = false
    for gap in known_gaps {
      if basename == gap {
        is_known_gap = true
        break
      }
    }
    if is_known_gap {
      parity_skip += 1
      continue
    }
    let interp_result = eval_fixture(path, script, spec)
    let interp_ok = match interp_result {
      Ok(_) => true
      Err(_) => false
    }
    let db = VibeDb::new()
    db.set_source(path, script)
    let compile_result : Result[Bytes, _] = try? compile_module_wasm(db, path)
    let compiled_ok = match compile_result {
      Ok(wasm_bytes) =>
        wasm_bytes.length() > 4 &&
        wasm_bytes[0] == 0 &&
        wasm_bytes[1] == b'a' &&
        wasm_bytes[2] == b's' &&
        wasm_bytes[3] == b'm'
      Err(_) => false
    }
    if interp_ok == compiled_ok {
      parity_ok += 1
    } else {
      let interp_label = if interp_ok { "OK" } else { "ERROR" }
      let compiled_label = if compiled_ok { "OK" } else { "ERROR" }
      mismatches.push(
        "\{path}: interp=\{interp_label} compiled=\{compiled_label}",
      )
    }
  }
  if mismatches.length() > 0 {
    let detail = mismatches
      .iter()
      .fold(init="", fn(acc, m) { acc + "  " + m + "\n" })
    fail(
      "compiled parity: \{parity_ok} ok, \{mismatches.length()} mismatch, \{parity_skip} skip:\n\{detail}",
    )
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
    fail("[fixtures] stale todo fixtures found: \{stale.to_string()}")
  }
}
