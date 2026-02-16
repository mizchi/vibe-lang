///|
test "cli save fetch expand workflow keeps codebase artifacts" {
  let root = wbtest_make_temp_dir("save_fetch_expand")
  let entry = root + "/main.vibe"
  let lib = root + "/lib.vibe"
  let entry_source = "use ./lib.vibe {  inc  }\nlet main = inc(1)\nexport { main }\n"
  let lib_source = "let inc = (x: Int) -> Int { x + 1 }\nexport { inc }\n"
  @os_fs.write_string_to_file(entry, entry_source) catch {
    e => fail("write entry failed: " + e.to_string())
  }
  @os_fs.write_string_to_file(lib, lib_source) catch {
    e => fail("write lib failed: " + e.to_string())
  }
  save_cmd([entry])
  let vibe_dir = find_vibe_dir(entry)
  let codebase = @codebase.Codebase::new(vibe_dir)
  let main_hash = match codebase.resolve_path_mapping(entry) {
    Some(hash) => hash
    None => fail("expected path mapping for entry")
  }
  match codebase.read_object(main_hash) {
    Some(json) => {
      let _ = .deserialize_module(json) catch {
        e => fail("deserialize saved module failed: " + e.to_string())
      }
    }
    None => fail("expected object for saved hash")
  }
  fetch_cmd([entry])
  let lock_path = @codebase.lock_file_path(entry)
  assert_true(@os_fs.path_exists(lock_path))
  let lock = match @codebase.load_lock_data(lock_path) {
    Ok(v) => v
    Err(err) => fail(err)
  }
  let entry_norm = @loader.resolve_entry_path(entry)
  let lib_norm = @loader.resolve_import_path(root, "./lib.vibe")
  match lock.path_refs.get(entry_norm) {
    Some(hash) => assert_eq(hash, .git_blob_hash_string(entry_source))
    None => fail("expected entry lock ref")
  }
  match lock.path_refs.get(lib_norm) {
    Some(hash) => assert_eq(hash, .git_blob_hash_string(lib_source))
    None => fail("expected import lock ref")
  }
  let prelude_hash = match lock.version_refs.get("prelude") {
    Some(hash) => hash
    None => fail("expected prelude version ref")
  }
  match lock.symbol_refs.get("std/prelude") {
    Some(hash) => assert_eq(hash, prelude_hash)
    None => fail("expected prelude symbol ref")
  }
  match codebase.read_object(prelude_hash) {
    Some(json) => {
      let _ = .deserialize_module(json) catch {
        e => fail("deserialize prelude module failed: " + e.to_string())
      }
    }
    None => fail("expected prelude object in codebase")
  }
  let resolved = resolve_target_to_hash(entry, codebase)
  assert_eq(resolved, main_hash)
  let short_target = target_substring(main_hash, 0, 8)
  let resolved_short = resolve_target_to_hash(short_target, codebase)
  assert_eq(resolved_short, main_hash)
  expand_cmd([entry, "--json"])
  wbtest_remove_if_exists(root)
}

///|
test "cli index ref args parse push" {
  let parsed = parse_index_ref_args([
    "push", "vibe/std@0.1.0", "/tmp/advanced-graph-index.json",
  ])
  match parsed {
    Ok(action) =>
      match action {
        IndexRefAction::PushIndex(scope, path) => {
          assert_eq(scope, "vibe/std@0.1.0")
          assert_eq(path, "/tmp/advanced-graph-index.json")
        }
        _ => fail("expected push action")
      }
    Err(msg) => fail("unexpected err: " + msg)
  }
}

///|
test "cli index ref args reject unknown action" {
  let parsed = parse_index_ref_args(["unknown", "scope", "/tmp/index.json"])
  match parsed {
    Ok(_) => fail("expected error")
    Err(msg) =>
      assert_eq(
        msg, "index ref: unknown action: unknown (expected push|pull|push-delta|pull-delta)",
      )
  }
}

///|
test "cli symbols cmd options parse default" {
  let parsed = parse_symbols_cmd_args(["main.vibe"])
  match parsed {
    Ok(opts) => {
      assert_eq(opts.entry_path, "main.vibe")
      assert_false(opts.output_json)
    }
    Err(msg) => fail("unexpected err: " + msg)
  }
}

///|
test "cli symbols cmd options parse json" {
  let parsed = parse_symbols_cmd_args(["--json", "main.vibe"])
  match parsed {
    Ok(opts) => {
      assert_eq(opts.entry_path, "main.vibe")
      assert_true(opts.output_json)
    }
    Err(msg) => fail("unexpected err: " + msg)
  }
}

///|
test "cli bench backend parse" {
  match parse_bench_backend("wasm") {
    Some(backend) => assert_eq(bench_backend_name(backend), "wasm")
    None => fail("expected wasm backend")
  }
  match parse_bench_backend("interpreter") {
    Some(backend) => assert_eq(bench_backend_name(backend), "interpreter")
    None => fail("expected interpreter backend")
  }
  match parse_bench_backend("interp") {
    Some(backend) => assert_eq(bench_backend_name(backend), "interpreter")
    None => fail("expected interpreter backend alias")
  }
  match parse_bench_backend("unknown") {
    Some(_) => fail("unexpected backend")
    None => ()
  }
}

///|
test "cli bench uses expr mode ignores backend with path" {
  assert_false(
    bench_uses_expr_mode(["--backend", "wasm", "examples/simple_bench.vibe"]),
  )
  assert_true(bench_uses_expr_mode(["--backend", "interpreter"]))
}

///|
test "cli wasm bench compile uses size-oriented optimize level" {
  let root = wbtest_make_temp_dir("bench_wasm_size_opt")
  let source_path = root + "/case.vibe"
  let wasm_path = root + "/case.wasm"
  let source =
    #|let rec repeat = (s: String, n: Int) -> String {
    #|  if eq(n, 0) { "" } else { string_concat(s, repeat(s, sub(n, 1))) }
    #|}
    #|let base = "abcdefghijklmnopqrstuvwxyz"
    #|let s = repeat(base, 12)
    #|string_length(s)
  let optimized_size = match
    compile_bench_script_to_wasm(source_path, wasm_path, source) {
    Ok(bytes) => bytes
    Err(err) => fail("compile bench wasm failed: " + err)
  }
  let (db, entry) = match @loader.load_db(source_path) {
    Ok(v) => v
    Err(err) => fail("load source db failed: " + err)
  }
  let baseline_wasm = @runtime.compile_module_wasm_with_opt_level(
    db,
    entry,
    no_dce=true,
    opt_level=None,
  ) catch {
    e => fail("compile baseline wasm failed: " + e.to_string())
  }
  assert_true(optimized_size < baseline_wasm.length())
  wbtest_remove_if_exists(wasm_path)
  wbtest_remove_if_exists(source_path)
  wbtest_remove_if_exists(root)
}

///|
test "cli symbols cmd options reject unknown option" {
  let parsed = parse_symbols_cmd_args(["--wat", "main.vibe"])
  match parsed {
    Ok(_) => fail("expected error")
    Err(msg) => assert_eq(msg, "symbols: unknown option --wat")
  }
}

///|
test "cli compile coverage guard rejects outside test mode" {
  match ensure_compile_coverage_allowed(true, false) {
    Ok(_) => fail("expected rejection")
    Err(msg) =>
      assert_eq(
        msg, "compile: --coverage is test-only (set VIBE_TEST_COVERAGE=1)",
      )
  }
}

///|
test "cli compile coverage guard allows test mode" {
  match ensure_compile_coverage_allowed(true, true) {
    Ok(_) => ()
    Err(msg) => fail("unexpected err: " + msg)
  }
  match ensure_compile_coverage_allowed(false, false) {
    Ok(_) => ()
    Err(msg) => fail("unexpected err: " + msg)
  }
}

///|
test "cli index build writes index.vdb graph head" {
  let root = wbtest_make_temp_dir("index_build_vdb")
  let entry = root + "/main.vibe"
  let out_path = root + "/advanced-graph-index.json"
  @os_fs.write_string_to_file(entry, "let value = 1\nexport { value }\n") catch {
    e => fail("write entry failed: " + e.to_string())
  }
  index_build_cmd(["-o", out_path, entry])
  assert_true(@os_fs.path_exists(out_path))
  let vdb_path = root + "/index.vdb"
  assert_true(@os_fs.path_exists(vdb_path))
  let vdb_source = @os_fs.read_file_to_string(vdb_path) catch {
    e => fail("read index.vdb failed: " + e.to_string())
  }
  let vdb_json : Json = @json.parse(vdb_source) catch {
    e => fail("parse index.vdb failed: " + e.to_string())
  }
  let graph_head = match vdb_json {
    Json::Object(obj) =>
      match obj.get("graph_head") {
        Some(Json::String(hash)) => hash
        _ => fail("index.vdb must include graph_head")
      }
    _ => fail("index.vdb must be object")
  }
  assert_eq(graph_head.length(), 40)
  let codebase = @codebase.Codebase::new(find_vibe_dir(entry))
  match codebase.read_object(graph_head) {
    Some(content) => assert_true(content.contains("\"defs\""))
    None => fail("expected graph snapshot object")
  }
  wbtest_remove_if_exists(root)
}

///|
test "cli check resolves lock and graph artifacts" {
  let root = wbtest_make_temp_dir("check_resolve_artifacts")
  let entry = root + "/main.vibe"
  let lib = root + "/lib.vibe"
  let entry_source = "use ./lib.vibe {  inc  }\nlet main = inc(1)\nexport { main }\n"
  let lib_source = "let inc = (x: Int) -> Int { x + 1 }\nexport { inc }\n"
  @os_fs.write_string_to_file(entry, entry_source) catch {
    e => fail("write entry failed: " + e.to_string())
  }
  @os_fs.write_string_to_file(lib, lib_source) catch {
    e => fail("write lib failed: " + e.to_string())
  }
  check_cmd([entry])
  let lock_path = @codebase.lock_file_path(entry)
  assert_true(@os_fs.path_exists(lock_path))
  let lock = match @codebase.load_lock_data(lock_path) {
    Ok(v) => v
    Err(err) => fail(err)
  }
  let entry_norm = @loader.resolve_entry_path(entry)
  let lib_norm = @loader.resolve_import_path(root, "./lib.vibe")
  assert_true(lock.path_refs.contains(entry_norm))
  assert_true(lock.path_refs.contains(lib_norm))
  let vdb_path = root + "/index.vdb"
  assert_true(@os_fs.path_exists(vdb_path))
  let vdb_source = @os_fs.read_file_to_string(vdb_path) catch {
    e => fail("read index.vdb failed: " + e.to_string())
  }
  let vdb_json : Json = @json.parse(vdb_source) catch {
    e => fail("parse index.vdb failed: " + e.to_string())
  }
  let graph_head = match vdb_json {
    Json::Object(obj) =>
      match obj.get("graph_head") {
        Some(Json::String(hash)) => hash
        _ => fail("index.vdb must include graph_head")
      }
    _ => fail("index.vdb must be object")
  }
  let codebase = @codebase.Codebase::new(find_vibe_dir(entry))
  match codebase.read_object(graph_head) {
    Some(content) => assert_true(content.contains("\"defs\""))
    None => fail("expected graph snapshot object")
  }
  wbtest_remove_if_exists(root)
}

///|
test "cli apply resolves lock and graph artifacts" {
  let root = wbtest_make_temp_dir("apply_resolve_artifacts")
  let entry = root + "/main.vibe"
  let source = "let value = 1\nexport { value }\n"
  @os_fs.write_string_to_file(entry, source) catch {
    e => fail("write entry failed: " + e.to_string())
  }
  apply_cmd([entry])
  let lock_path = @codebase.lock_file_path(entry)
  assert_true(@os_fs.path_exists(lock_path))
  let lock = match @codebase.load_lock_data(lock_path) {
    Ok(v) => v
    Err(err) => fail(err)
  }
  let resolved = @loader.resolve_entry_path(entry)
  assert_true(lock.path_refs.contains(resolved))
  let vdb_path = root + "/index.vdb"
  assert_true(@os_fs.path_exists(vdb_path))
  let vdb_source = @os_fs.read_file_to_string(vdb_path) catch {
    e => fail("read index.vdb failed: " + e.to_string())
  }
  let vdb_json : Json = @json.parse(vdb_source) catch {
    e => fail("parse index.vdb failed: " + e.to_string())
  }
  let graph_head = match vdb_json {
    Json::Object(obj) =>
      match obj.get("graph_head") {
        Some(Json::String(hash)) => hash
        _ => fail("index.vdb must include graph_head")
      }
    _ => fail("index.vdb must be object")
  }
  let codebase = @codebase.Codebase::new(find_vibe_dir(entry))
  match codebase.read_object(graph_head) {
    Some(content) => assert_true(content.contains("\"defs\""))
    None => fail("expected graph snapshot object")
  }
  wbtest_remove_if_exists(root)
}

///|
test "cli apply tracks function version on incompatible change" {
  let root = wbtest_make_temp_dir("apply_track_fn_version")
  let entry = root + "/main.vibe"
  let entry_norm = @loader.resolve_entry_path(entry)
  let key = entry_norm + "#inc"
  @os_fs.write_string_to_file(
    entry, "let inc = (x: Int) -> Int { x + 1 }\nexport { inc }\n",
  ) catch {
    e => fail("write entry failed: " + e.to_string())
  }
  apply_cmd([entry])
  let first = read_function_tracking_record(root, key)
  assert_eq(first.version, "1.0.0")
  @os_fs.write_string_to_file(
    entry, "let inc = (x: Int) -> String { \"x\" }\nexport { inc }\n",
  ) catch {
    e => fail("rewrite entry failed: " + e.to_string())
  }
  apply_cmd([entry])
  let second = read_function_tracking_record(root, key)
  assert_eq(second.version, "2.0.0")
  wbtest_remove_if_exists(root)
}

///|
test "cli apply tracks rename continuity for similar function" {
  let root = wbtest_make_temp_dir("apply_track_fn_rename")
  let entry = root + "/main.vibe"
  let entry_norm = @loader.resolve_entry_path(entry)
  let old_key = entry_norm + "#inc"
  let new_key = entry_norm + "#plus"
  @os_fs.write_string_to_file(
    entry, "let inc = (x: Int) -> Int { x + 1 }\nexport { inc }\n",
  ) catch {
    e => fail("write entry failed: " + e.to_string())
  }
  apply_cmd([entry])
  @os_fs.write_string_to_file(
    entry, "let plus = (x: Int) -> Int { x + 1 }\nexport { plus }\n",
  ) catch {
    e => fail("rewrite entry failed: " + e.to_string())
  }
  apply_cmd([entry])
  let tracked = read_function_tracking_record(root, new_key)
  assert_eq(tracked.version, "1.0.0")
  match tracked.renamed_from {
    Some(value) => assert_eq(value, old_key)
    None => fail("expected renamed_from")
  }
  wbtest_remove_if_exists(root)
}

///|
test "cli eval without db uses scratch namespace db" {
  let root = wbtest_make_temp_dir("eval_default_scratch_db")
  let scratch_db = root + "/scratch.db"
  let out_path = root + "/out.vibe"
  let prev = @sys.get_env_var("VIBE_SCRATCH_DB_PATH")
  @sys.set_env_var("VIBE_SCRATCH_DB_PATH", scratch_db)
  let features = @runtime.RuntimeFeatureFlags::stable()
  eval_cmd(["let", "seed", "=", "10"], @runtime.ParserMode::XshMode, features)
  eval_cmd(
    ["let", "answer", "=", "seed", "+", "32"],
    @runtime.ParserMode::XshMode,
    features,
  )
  eval_cmd(["--export=" + out_path], @runtime.ParserMode::XshMode, features)
  match prev {
    Some(value) => @sys.set_env_var("VIBE_SCRATCH_DB_PATH", value)
    None => @sys.unset_env_var("VIBE_SCRATCH_DB_PATH")
  }
  assert_true(@os_fs.path_exists(scratch_db))
  let scratch_source = @os_fs.read_file_to_string(scratch_db) catch {
    e => fail("read scratch db failed: " + e.to_string())
  }
  assert_true(scratch_source.contains("let seed = 10"))
  assert_true(scratch_source.contains("let answer = seed + 32"))
  let exported = @os_fs.read_file_to_string(out_path) catch {
    e => fail("read exported module failed: " + e.to_string())
  }
  assert_true(exported.contains("let seed = 10"))
  assert_true(exported.contains("let answer = seed + 32"))
  wbtest_remove_if_exists(out_path)
  wbtest_remove_if_exists(scratch_db)
  wbtest_remove_if_exists(root)
}

///|
test "cli history reset clears scratch namespace db" {
  let root = wbtest_make_temp_dir("history_reset_scratch")
  let scratch_db = root + "/scratch.db"
  let prev = @sys.get_env_var("VIBE_SCRATCH_DB_PATH")
  @sys.set_env_var("VIBE_SCRATCH_DB_PATH", scratch_db)
  let features = @runtime.RuntimeFeatureFlags::stable()
  eval_cmd(["let", "v", "=", "1"], @runtime.ParserMode::XshMode, features)
  assert_true(@os_fs.path_exists(scratch_db))
  history_cmd(["reset"])
  match prev {
    Some(value) => @sys.set_env_var("VIBE_SCRATCH_DB_PATH", value)
    None => @sys.unset_env_var("VIBE_SCRATCH_DB_PATH")
  }
  assert_false(@os_fs.path_exists(scratch_db))
  wbtest_remove_if_exists(scratch_db)
  wbtest_remove_if_exists(root)
}

///|
test "cli symbols prints status for managed symbols" {
  let root = wbtest_make_temp_dir("symbols_status")
  let entry = root + "/main.vibe"
  let lib = root + "/lib.vibe"
  @os_fs.write_string_to_file(
    entry, "use ./lib.vibe {  inc  }\nlet main = inc(1)\nexport { main }\n",
  ) catch {
    e => fail("write entry failed: " + e.to_string())
  }
  @os_fs.write_string_to_file(
    lib, "let inc = (x: Int) -> Int { x + 1 }\nexport { inc }\n",
  ) catch {
    e => fail("write lib failed: " + e.to_string())
  }
  let rows = match collect_symbols_rows(entry) {
    Ok(v) => v
    Err(err) => fail("collect symbols failed: " + err)
  }
  let mut has_main_managed = false
  let mut has_inc_managed = false
  for row in rows {
    if row.name == "main" && row.status == "managed" {
      has_main_managed = true
    }
    if row.name == "inc" && row.status == "managed" {
      has_inc_managed = true
    }
  }
  assert_true(has_main_managed)
  assert_true(has_inc_managed)
  symbols_cmd(["--json", entry])
  wbtest_remove_if_exists(root)
}

///|
test "cli symbols marks shadowed when scratch overrides index symbol" {
  let root = wbtest_make_temp_dir("symbols_shadowed")
  let entry = root + "/main.vibe"
  let scratch_db = root + "/scratch.db"
  @os_fs.write_string_to_file(entry, "let foo = 10\nexport { foo }\n") catch {
    e => fail("write entry failed: " + e.to_string())
  }
  apply_cmd([entry])
  let prev = @sys.get_env_var("VIBE_SCRATCH_DB_PATH")
  @sys.set_env_var("VIBE_SCRATCH_DB_PATH", scratch_db)
  let features = @runtime.RuntimeFeatureFlags::stable()
  eval_cmd(["let", "foo", "=", "1"], @runtime.ParserMode::XshMode, features)
  let rows = match collect_symbols_rows(entry) {
    Ok(v) => v
    Err(err) => fail("collect symbols failed: " + err)
  }
  match prev {
    Some(value) => @sys.set_env_var("VIBE_SCRATCH_DB_PATH", value)
    None => @sys.unset_env_var("VIBE_SCRATCH_DB_PATH")
  }
  let mut has_shadowed_scratch = false
  let mut has_shadowed_index = false
  for row in rows {
    if row.name == "foo" && row.origin == "scratch" && row.status == "shadowed" {
      has_shadowed_scratch = true
    }
    if row.name == "foo" && row.origin == "index" && row.status == "shadowed" {
      has_shadowed_index = true
    }
  }
  assert_true(has_shadowed_scratch)
  assert_true(has_shadowed_index)
  wbtest_remove_if_exists(scratch_db)
  wbtest_remove_if_exists(root)
}

///|
test "cli write_file selector name prefers scratch namespace symbol" {
  let root = wbtest_make_temp_dir("write_file_selector_name_scratch")
  let entry = root + "/main.vibe"
  let out_path = root + "/foo.vibe"
  let scratch_db = root + "/scratch.db"
  @os_fs.write_string_to_file(entry, "let foo = 10\nexport { foo }\n") catch {
    e => fail("write entry failed: " + e.to_string())
  }
  apply_cmd([entry])
  let prev = @sys.get_env_var("VIBE_SCRATCH_DB_PATH")
  @sys.set_env_var("VIBE_SCRATCH_DB_PATH", scratch_db)
  let features = @runtime.RuntimeFeatureFlags::stable()
  eval_cmd(["let", "foo", "=", "1"], @runtime.ParserMode::XshMode, features)
  write_file_cmd(["--entry=" + entry, "foo", out_path])
  match prev {
    Some(value) => @sys.set_env_var("VIBE_SCRATCH_DB_PATH", value)
    None => @sys.unset_env_var("VIBE_SCRATCH_DB_PATH")
  }
  let written = @os_fs.read_file_to_string(out_path) catch {
    e => fail("read write_file output failed: " + e.to_string())
  }
  assert_true(written.contains("let foo = 1"))
  assert_false(written.contains("let foo = 10"))
  assert_true(written.contains("export { foo }"))
  wbtest_remove_if_exists(out_path)
  wbtest_remove_if_exists(scratch_db)
  wbtest_remove_if_exists(root)
}

///|
test "cli write_file selector hash resolves managed symbol" {
  let root = wbtest_make_temp_dir("write_file_selector_hash")
  let entry = root + "/main.vibe"
  let out_path = root + "/value.vibe"
  @os_fs.write_string_to_file(entry, "let value = 1\nexport { value }\n") catch {
    e => fail("write entry failed: " + e.to_string())
  }
  let (_, _, _, index, _) = match resolve_entry_artifacts(entry) {
    Ok(v) => v
    Err(err) => fail("resolve artifacts failed: " + err)
  }
  let mut target_hash = ""
  for _, def in index.defs {
    if def.name == "value" {
      target_hash = def.def_id
      break
    }
  }
  if target_hash.length() == 0 {
    fail("expected def hash for value")
  }
  write_file_cmd(["--entry=" + entry, "#" + short_hash(target_hash), out_path])
  let written = @os_fs.read_file_to_string(out_path) catch {
    e => fail("read write_file output failed: " + e.to_string())
  }
  assert_true(written.contains("let value = 1"))
  assert_true(written.contains("export { value }"))
  wbtest_remove_if_exists(out_path)
  wbtest_remove_if_exists(root)
}

///|
test "cli write_file no-deps emits selected definition only" {
  let root = wbtest_make_temp_dir("write_file_no_deps")
  let entry = root + "/main.vibe"
  let out_path = root + "/value-nodeps.vibe"
  @os_fs.write_string_to_file(
    entry, "let helper = 1\nlet value = helper + 1\nexport { value }\n",
  ) catch {
    e => fail("write entry failed: " + e.to_string())
  }
  write_file_cmd(["--entry=" + entry, "--no-deps", "value", out_path])
  let written = @os_fs.read_file_to_string(out_path) catch {
    e => fail("read write_file output failed: " + e.to_string())
  }
  assert_true(written.contains("let value = helper + 1"))
  assert_false(written.contains("let helper = 1"))
  assert_true(written.contains("export { value }"))
  wbtest_remove_if_exists(out_path)
  wbtest_remove_if_exists(root)
}

///|
test "cli write_file dry-run does not write output file" {
  let root = wbtest_make_temp_dir("write_file_dry_run")
  let entry = root + "/main.vibe"
  let out_path = root + "/value-dry-run.vibe"
  @os_fs.write_string_to_file(entry, "let value = 1\nexport { value }\n") catch {
    e => fail("write entry failed: " + e.to_string())
  }
  write_file_cmd(["--entry=" + entry, "--dry-run", "value", out_path])
  write_file_cmd(["--entry=" + entry, "--dry-run", "--json", "value", out_path])
  assert_false(@os_fs.path_exists(out_path))
  wbtest_remove_if_exists(out_path)
  wbtest_remove_if_exists(root)
}

///|
test "cli eval db workflow persists namespace and exports module" {
  let root = wbtest_make_temp_dir("eval_db_workflow")
  let db_path = root + "/tmp1.db"
  let out_path = root + "/main.vibe"
  let features = @runtime.RuntimeFeatureFlags::stable()
  eval_cmd(
    ["--db=" + db_path, "let", "base", "=", "40"],
    @runtime.ParserMode::XshMode,
    features,
  )
  eval_cmd(
    ["--db=" + db_path, "let", "answer", "=", "base", "+", "2"],
    @runtime.ParserMode::XshMode,
    features,
  )
  eval_cmd(
    ["--db=" + db_path, "export", "{", "answer", "}"],
    @runtime.ParserMode::XshMode,
    features,
  )
  eval_cmd(
    ["--db=" + db_path, "--export=" + out_path],
    @runtime.ParserMode::XshMode,
    features,
  )
  let exported = @os_fs.read_file_to_string(out_path) catch {
    e => fail("read exported module failed: " + e.to_string())
  }
  assert_true(exported.contains("let base = 40"))
  assert_true(exported.contains("let answer = base + 2"))
  assert_true(exported.contains("export { answer }"))
  fetch_cmd([out_path])
  let lock_path = @codebase.lock_file_path(out_path)
  let lock = match @codebase.load_lock_data(lock_path) {
    Ok(v) => v
    Err(err) => fail("load lock failed: " + err)
  }
  let resolved = @loader.resolve_entry_path(out_path)
  match lock.path_refs.get(resolved) {
    Some(hash) => assert_eq(hash, .git_blob_hash_string(exported))
    None => fail("expected path ref for exported module")
  }
  wbtest_remove_if_exists(out_path)
  wbtest_remove_if_exists(db_path)
  wbtest_remove_if_exists(root)
}

///|
test "cli eval db workflow supports include scripts" {
  let root = wbtest_make_temp_dir("eval_db_include_workflow")
  let db_path = root + "/tmp1.db"
  let include_path = root + "/index.vdb"
  let out_path = root + "/main.vibe"
  let features = @runtime.RuntimeFeatureFlags::stable()
  @os_fs.write_string_to_file(include_path, "let seed = 10\n") catch {
    e => fail("write include source failed: " + e.to_string())
  }
  eval_cmd(
    [
      "--db=" + db_path,
      "--include=" + include_path,
      "let",
      "answer",
      "=",
      "seed",
      "+",
      "2",
    ],
    @runtime.ParserMode::XshMode,
    features,
  )
  eval_cmd(
    [
      "--db=" + db_path,
      "--include=bit:" + include_path,
      "export",
      "{",
      "answer",
      "}",
    ],
    @runtime.ParserMode::XshMode,
    features,
  )
  eval_cmd(
    ["--db=" + db_path, "--include=" + include_path, "--export=" + out_path],
    @runtime.ParserMode::XshMode,
    features,
  )
  let exported = @os_fs.read_file_to_string(out_path) catch {
    e => fail("read exported module failed: " + e.to_string())
  }
  assert_true(exported.contains("let answer = seed + 2"))
  assert_true(exported.contains("export { answer }"))
  wbtest_remove_if_exists(out_path)
  wbtest_remove_if_exists(include_path)
  wbtest_remove_if_exists(db_path)
  wbtest_remove_if_exists(root)
}

///|
test "cli eval include supports hash alias from vdb file" {
  let root = wbtest_make_temp_dir("eval_db_hash_alias")
  let lib_root = root + "/lib"
  let lib_vibe = lib_root + "/vibe"
  @os_fs.create_dir(lib_root) catch {
    e => fail("create lib root failed: " + e.to_string())
  }
  @os_fs.create_dir(lib_vibe) catch {
    e => fail("create lib vibe dir failed: " + e.to_string())
  }
  let db_path = root + "/tmp1.db"
  let include_path = lib_vibe + "/std@0.1.0.vdb"
  let out_path = root + "/main.vibe"
  let seed_source = "let seed = 21\n"
  let seed_hash = .git_blob_hash_string(seed_source)
  let codebase = @codebase.Codebase::new(lib_root)
  let _ = codebase.write_object(seed_hash, seed_source) catch {
    e => fail("write alias object failed: " + e.to_string())
  }
  @os_fs.write_string_to_file(include_path, "hash:" + seed_hash + "\n") catch {
    e => fail("write include alias failed: " + e.to_string())
  }
  let features = @runtime.RuntimeFeatureFlags::stable()
  eval_cmd(
    [
      "--db=" + db_path,
      "--include=" + include_path,
      "let",
      "answer",
      "=",
      "seed",
      "+",
      "1",
    ],
    @runtime.ParserMode::XshMode,
    features,
  )
  eval_cmd(
    [
      "--db=" + db_path,
      "--include=" + include_path,
      "export",
      "{",
      "answer",
      "}",
    ],
    @runtime.ParserMode::XshMode,
    features,
  )
  eval_cmd(
    ["--db=" + db_path, "--include=" + include_path, "--export=" + out_path],
    @runtime.ParserMode::XshMode,
    features,
  )
  let exported = @os_fs.read_file_to_string(out_path) catch {
    e => fail("read exported module failed: " + e.to_string())
  }
  assert_true(exported.contains("let answer = seed + 1"))
  assert_true(exported.contains("export { answer }"))
  wbtest_remove_if_exists(out_path)
  wbtest_remove_if_exists(include_path)
  wbtest_remove_if_exists(db_path)
  wbtest_remove_if_exists(lib_vibe)
  wbtest_remove_if_exists(lib_root)
  wbtest_remove_if_exists(root)
}

///|
test "cli eval db workflow validates scope symbols and types per step" {
  let root = wbtest_make_temp_dir("eval_db_scope_validation")
  let db_path = root + "/tmp1.db"
  let out_path = root + "/main.vibe"
  let features = @runtime.RuntimeFeatureFlags::stable()
  eval_cmd(
    ["--db=" + db_path, "let", "base", "=", "40"],
    @runtime.ParserMode::XshMode,
    features,
  )
  let scope1 = scope_symbol_signatures_from_db(db_path)
  assert_eq(scope1.length(), 1)
  assert_scope_symbol_signature(scope1, "base", "Int")
  eval_cmd(
    [
      "--db=" + db_path,
      "let",
      "inc",
      "=",
      "(x:",
      "Int)",
      "->",
      "Int",
      "{",
      "x",
      "+",
      "base",
      "}",
    ],
    @runtime.ParserMode::XshMode,
    features,
  )
  let scope2 = scope_symbol_signatures_from_db(db_path)
  assert_eq(scope2.length(), 2)
  assert_scope_symbol_signature(scope2, "base", "Int")
  assert_scope_symbol_signature(scope2, "inc", "(x: Int) -> Int")
  eval_cmd(
    ["--db=" + db_path, "let", "answer", "=", "inc", "(", "2", ")"],
    @runtime.ParserMode::XshMode,
    features,
  )
  let scope3 = scope_symbol_signatures_from_db(db_path)
  assert_eq(scope3.length(), 3)
  assert_scope_symbol_signature(scope3, "base", "Int")
  assert_scope_symbol_signature(scope3, "inc", "(x: Int) -> Int")
  assert_scope_symbol_signature(scope3, "answer", "Int")
  eval_cmd(
    ["--db=" + db_path, "export", "{", "answer", "}"],
    @runtime.ParserMode::XshMode,
    features,
  )
  let scope4 = scope_symbol_signatures_from_db(db_path)
  assert_eq(scope4.length(), 3)
  assert_scope_symbol_signature(scope4, "answer", "Int")
  eval_cmd(
    ["--db=" + db_path, "--export=" + out_path],
    @runtime.ParserMode::XshMode,
    features,
  )
  let exported = @os_fs.read_file_to_string(out_path) catch {
    e => fail("read exported module failed: " + e.to_string())
  }
  assert_true(exported.contains("let base = 40"))
  assert_true(exported.contains("let inc = (x: Int) -> Int { x + base }"))
  assert_true(exported.contains("let answer = inc"))
  assert_true(exported.contains("export { answer }"))
  wbtest_remove_if_exists(out_path)
  wbtest_remove_if_exists(db_path)
  wbtest_remove_if_exists(root)
}

///|
test "cli eval db complex workflow validates chained function scope types" {
  let root = wbtest_make_temp_dir("eval_db_scope_complex")
  let db_path = root + "/tmp1.db"
  let out_path = root + "/main.vibe"
  let features = @runtime.RuntimeFeatureFlags::stable()
  eval_cmd(
    ["--db=" + db_path, "let", "base", "=", "10"],
    @runtime.ParserMode::XshMode,
    features,
  )
  let scope1 = scope_symbol_signatures_from_db(db_path)
  assert_eq(scope1.length(), 1)
  assert_scope_symbol_signature(scope1, "base", "Int")
  eval_cmd(
    [
      "--db=" + db_path,
      "let",
      "add_base",
      "=",
      "(x:",
      "Int)",
      "->",
      "Int",
      "{",
      "x",
      "+",
      "base",
      "}",
    ],
    @runtime.ParserMode::XshMode,
    features,
  )
  let scope2 = scope_symbol_signatures_from_db(db_path)
  assert_eq(scope2.length(), 2)
  assert_scope_symbol_signature(scope2, "add_base", "(x: Int) -> Int")
  eval_cmd(
    [
      "--db=" + db_path,
      "let",
      "add_twice",
      "=",
      "(x:",
      "Int)",
      "->",
      "Int",
      "{",
      "add_base",
      "(",
      "add_base",
      "(",
      "x",
      ")",
      ")",
      "}",
    ],
    @runtime.ParserMode::XshMode,
    features,
  )
  let scope3 = scope_symbol_signatures_from_db(db_path)
  assert_eq(scope3.length(), 3)
  assert_scope_symbol_signature(scope3, "add_twice", "(x: Int) -> Int")
  eval_cmd(
    ["--db=" + db_path, "let", "result", "=", "add_twice", "(", "5", ")"],
    @runtime.ParserMode::XshMode,
    features,
  )
  let scope4 = scope_symbol_signatures_from_db(db_path)
  assert_eq(scope4.length(), 4)
  assert_scope_symbol_signature(scope4, "result", "Int")
  eval_cmd(
    [
      "--db=" + db_path,
      "export",
      "{",
      "add_base",
      ",",
      "add_twice",
      ",",
      "result",
      "}",
    ],
    @runtime.ParserMode::XshMode,
    features,
  )
  let scope5 = scope_symbol_signatures_from_db(db_path)
  assert_eq(scope5.length(), 4)
  assert_scope_symbol_signature(scope5, "add_base", "(x: Int) -> Int")
  assert_scope_symbol_signature(scope5, "add_twice", "(x: Int) -> Int")
  assert_scope_symbol_signature(scope5, "result", "Int")
  eval_cmd(
    ["--db=" + db_path, "--export=" + out_path],
    @runtime.ParserMode::XshMode,
    features,
  )
  let exported = @os_fs.read_file_to_string(out_path) catch {
    e => fail("read exported module failed: " + e.to_string())
  }
  assert_true(exported.contains("let base = 10"))
  assert_true(exported.contains("let add_base = (x: Int) -> Int { x + base }"))
  assert_true(exported.contains("let add_twice = (x: Int) -> Int"))
  assert_true(exported.contains("let result = add_twice"))
  assert_true(exported.contains("export { add_base , add_twice , result }"))
  wbtest_remove_if_exists(out_path)
  wbtest_remove_if_exists(db_path)
  wbtest_remove_if_exists(root)
}

///|
test "cli write_file handles complex eval exported module" {
  let root = wbtest_make_temp_dir("eval_write_file_complex")
  let db_path = root + "/tmp1.db"
  let out_path = root + "/main.vibe"
  let no_deps_path = root + "/add_twice_nodeps.vibe"
  let full_path = root + "/result_full.vibe"
  let features = @runtime.RuntimeFeatureFlags::stable()
  eval_cmd(
    ["--db=" + db_path, "let", "base", "=", "10"],
    @runtime.ParserMode::XshMode,
    features,
  )
  eval_cmd(
    [
      "--db=" + db_path,
      "let",
      "add_base",
      "=",
      "(x:",
      "Int)",
      "->",
      "Int",
      "{",
      "x",
      "+",
      "base",
      "}",
    ],
    @runtime.ParserMode::XshMode,
    features,
  )
  eval_cmd(
    [
      "--db=" + db_path,
      "let",
      "add_twice",
      "=",
      "(x:",
      "Int)",
      "->",
      "Int",
      "{",
      "add_base",
      "(",
      "add_base",
      "(",
      "x",
      ")",
      ")",
      "}",
    ],
    @runtime.ParserMode::XshMode,
    features,
  )
  eval_cmd(
    ["--db=" + db_path, "let", "result", "=", "add_twice", "(", "5", ")"],
    @runtime.ParserMode::XshMode,
    features,
  )
  eval_cmd(
    [
      "--db=" + db_path,
      "export",
      "{",
      "add_base",
      ",",
      "add_twice",
      ",",
      "result",
      "}",
    ],
    @runtime.ParserMode::XshMode,
    features,
  )
  eval_cmd(
    ["--db=" + db_path, "--export=" + out_path],
    @runtime.ParserMode::XshMode,
    features,
  )
  apply_cmd([out_path])
  write_file_cmd(["--entry=" + out_path, "--no-deps", "add_twice", no_deps_path])
  let no_deps_source = @os_fs.read_file_to_string(no_deps_path) catch {
    e => fail("read no-deps write_file output failed: " + e.to_string())
  }
  assert_true(no_deps_source.contains("let add_twice = (x: Int) -> Int"))
  assert_false(no_deps_source.contains("let base = 10"))
  assert_false(no_deps_source.contains("let add_base = (x: Int) -> Int"))
  assert_true(no_deps_source.contains("export { add_twice }"))
  write_file_cmd(["--entry=" + out_path, "result", full_path])
  let full_source = @os_fs.read_file_to_string(full_path) catch {
    e => fail("read full write_file output failed: " + e.to_string())
  }
  assert_true(full_source.contains("let base = 10"))
  assert_true(full_source.contains("let add_base = (x: Int) -> Int"))
  assert_true(full_source.contains("let add_twice = (x: Int) -> Int"))
  assert_true(full_source.contains("let result = add_twice"))
  assert_true(full_source.contains("export { add_base , add_twice , result }"))
  wbtest_remove_if_exists(full_path)
  wbtest_remove_if_exists(no_deps_path)
  wbtest_remove_if_exists(out_path)
  wbtest_remove_if_exists(db_path)
  wbtest_remove_if_exists(root)
}

///|
test "cli eval inspect scope and assertions on persisted namespace" {
  let root = wbtest_make_temp_dir("eval_inspect_scope_assert")
  let db_path = root + "/tmp1.db"
  let features = @runtime.RuntimeFeatureFlags::stable()
  eval_cmd(
    ["--db=" + db_path, "let", "base", "=", "10"],
    @runtime.ParserMode::XshMode,
    features,
  )
  eval_cmd(
    [
      "--db=" + db_path,
      "let",
      "inc",
      "=",
      "(x:",
      "Int)",
      "->",
      "Int",
      "{",
      "x",
      "+",
      "base",
      "}",
    ],
    @runtime.ParserMode::XshMode,
    features,
  )
  eval_cmd(
    [
      "--db=" + db_path,
      "--inspect-scope",
      "--assert",
      "base:Int",
      "--assert",
      "inc:(x: Int) -> Int",
    ],
    @runtime.ParserMode::XshMode,
    features,
  )
  let scope = scope_symbol_signatures_from_db(db_path)
  assert_eq(scope.length(), 2)
  assert_scope_symbol_signature(scope, "base", "Int")
  assert_scope_symbol_signature(scope, "inc", "(x: Int) -> Int")
  wbtest_remove_if_exists(db_path)
  wbtest_remove_if_exists(root)
}

///|
test "cli eval test-for stores tests outside dag and accumulates by function" {
  let root = wbtest_make_temp_dir("eval_test_for_sidecar")
  let db_path = root + "/tmp1.db"
  let out_path = root + "/main.vibe"
  let features = @runtime.RuntimeFeatureFlags::stable()
  eval_cmd(
    ["--db=" + db_path, "let", "base", "=", "10"],
    @runtime.ParserMode::XshMode,
    features,
  )
  eval_cmd(
    [
      "--db=" + db_path,
      "let",
      "add_base",
      "=",
      "(x:",
      "Int)",
      "->",
      "Int",
      "{",
      "x",
      "+",
      "base",
      "}",
    ],
    @runtime.ParserMode::XshMode,
    features,
  )
  eval_cmd(
    [
      "--db=" + db_path,
      "--test-for",
      "add_base",
      "test \"add_base/one\" { assert(add_base(1) == 11) }",
    ],
    @runtime.ParserMode::XshMode,
    features,
  )
  eval_cmd(
    [
      "--db=" + db_path,
      "--test-for=add_base",
      "test \"add_base/two\" { assert(add_base(2) == 12) }",
    ],
    @runtime.ParserMode::XshMode,
    features,
  )
  let test_path = eval_test_file_path(db_path, "add_base")
  assert_true(@os_fs.path_exists(test_path))
  let test_source = @os_fs.read_file_to_string(test_path) catch {
    e => fail("read eval test sidecar failed: " + e.to_string())
  }
  assert_true(test_source.contains("test \"add_base/one\""))
  assert_true(test_source.contains("test \"add_base/two\""))
  let db_source = match load_eval_db_source(db_path) {
    Ok(v) => v
    Err(err) => fail("load eval db failed: " + err)
  }
  assert_false(db_source.contains("test \"add_base/one\""))
  assert_false(db_source.contains("test \"add_base/two\""))
  eval_cmd(
    ["--db=" + db_path, "--export=" + out_path],
    @runtime.ParserMode::XshMode,
    features,
  )
  let exported = @os_fs.read_file_to_string(out_path) catch {
    e => fail("read exported module failed: " + e.to_string())
  }
  assert_true(exported.contains("let add_base = (x: Int) -> Int"))
  assert_false(exported.contains("test \"add_base/one\""))
  assert_false(exported.contains("test \"add_base/two\""))
  wbtest_remove_if_exists(eval_tests_dir_path(db_path))
  wbtest_remove_if_exists(out_path)
  wbtest_remove_if_exists(db_path)
  wbtest_remove_if_exists(root)
}

///|
test "cli eval test-for run uses def-level cache key" {
  let root = wbtest_make_temp_dir("eval_test_for_run_cache")
  let db_path = root + "/tmp1.db"
  let features = @runtime.RuntimeFeatureFlags::stable()
  eval_cmd(
    [
      "--db=" + db_path,
      "let",
      "add_one",
      "=",
      "(x:",
      "Int)",
      "->",
      "Int",
      "{",
      "x",
      "+",
      "1",
      "}",
    ],
    @runtime.ParserMode::XshMode,
    features,
  )
  eval_cmd(
    [
      "--db=" + db_path,
      "--test-for",
      "add_one",
      "--run",
      "test \"add_one/basic\" { assert(add_one(1) >= 2) }",
    ],
    @runtime.ParserMode::XshMode,
    features,
  )
  let cache_path = eval_test_cache_file_path(db_path, "add_one")
  assert_true(@os_fs.path_exists(cache_path))
  let first_hash = @os_fs.read_file_to_string(cache_path) catch {
    e => fail("read eval test cache failed: " + e.to_string())
  }
  assert_true(first_hash.trim().to_string().length() > 0)

  // No new test expression: should use existing sidecar and keep cache key.
  eval_cmd(
    ["--db=" + db_path, "--test-for", "add_one", "--run"],
    @runtime.ParserMode::XshMode,
    features,
  )
  let second_hash = @os_fs.read_file_to_string(cache_path) catch {
    e => fail("read eval test cache second failed: " + e.to_string())
  }
  assert_eq(second_hash.trim().to_string(), first_hash.trim().to_string())

  // Unrelated DB edits should not invalidate def-level cache key.
  eval_cmd(
    ["--db=" + db_path, "let", "unrelated", "=", "42"],
    @runtime.ParserMode::XshMode,
    features,
  )
  eval_cmd(
    ["--db=" + db_path, "--test-for", "add_one", "--run"],
    @runtime.ParserMode::XshMode,
    features,
  )
  let third_hash = @os_fs.read_file_to_string(cache_path) catch {
    e => fail("read eval test cache third failed: " + e.to_string())
  }
  assert_true(third_hash.trim().to_string().length() > 0)
  assert_eq(third_hash.trim().to_string(), first_hash.trim().to_string())

  // Editing target definition should update dep snapshot hash.
  let updated_db_source = "let add_one = (x: Int) -> Int { x + 2 }\nlet unrelated = 42\n"
  @os_fs.write_string_to_file(db_path, updated_db_source) catch {
    e => fail("rewrite db failed: " + e.to_string())
  }
  eval_cmd(
    ["--db=" + db_path, "--test-for", "add_one", "--run"],
    @runtime.ParserMode::XshMode,
    features,
  )
  let fourth_hash = @os_fs.read_file_to_string(cache_path) catch {
    e => fail("read eval test cache fourth failed: " + e.to_string())
  }
  assert_true(fourth_hash.trim().to_string().length() > 0)
  assert_true(fourth_hash.trim().to_string() != first_hash.trim().to_string())
  wbtest_remove_if_exists(eval_tests_dir_path(db_path))
  wbtest_remove_if_exists(db_path)
  wbtest_remove_if_exists(root)
}

///|
test "cli finalize library mode prunes scratch db toward exports" {
  let root = wbtest_make_temp_dir("finalize_library_mode")
  let db_path = root + "/tmp1.db"
  let source = "let helper = (x: Int) -> Int { x + 1 }\n" +
    "let unused = 100\n" +
    "let answer = helper(41)\n" +
    "helper(0)\n" +
    "test \"answer\" { assert(answer == 42) }\n" +
    "export { answer }\n"
  match write_eval_db_source(db_path, source) {
    Ok(_) => ()
    Err(err) => fail("write seed db failed: " + err)
  }
  finalize_cmd(["--db=" + db_path, "--library"])
  let finalized = @os_fs.read_file_to_string(db_path) catch {
    e => fail("read finalized db failed: " + e.to_string())
  }
  assert_true(finalized.contains("let helper = (x: Int) -> Int"))
  assert_true(finalized.contains("let answer = helper(41)"))
  assert_true(finalized.contains("export { answer }"))
  assert_false(finalized.contains("let unused = 100"))
  assert_false(finalized.contains("helper(0)"))
  assert_false(finalized.contains("test \"answer\""))
  let db = @runtime.VibeDb::new()
  db.set_source(db_path, finalized)
  let _ = db.types(db_path)
  wbtest_remove_if_exists(db_path)
  wbtest_remove_if_exists(root)
}

///|
test "cli finalize safe mode keeps side-effect expressions" {
  let root = wbtest_make_temp_dir("finalize_safe_mode")
  let db_path = root + "/tmp1.db"
  let source = "let helper = (x: Int) -> Int { x + 1 }\n" +
    "let answer = helper(41)\n" +
    "helper(0)\n" +
    "test \"answer\" { assert(answer == 42) }\n" +
    "export { answer }\n"
  match write_eval_db_source(db_path, source) {
    Ok(_) => ()
    Err(err) => fail("write seed db failed: " + err)
  }
  finalize_cmd(["--db=" + db_path])
  let finalized = @os_fs.read_file_to_string(db_path) catch {
    e => fail("read finalized db failed: " + e.to_string())
  }
  assert_true(finalized.contains("let helper = (x: Int) -> Int"))
  assert_true(finalized.contains("let answer = helper(41)"))
  assert_true(finalized.contains("helper(0)"))
  assert_false(finalized.contains("test \"answer\""))
  let _ = @parser.parse_ast(finalized) catch {
    e => fail("finalized parse failed: " + e.to_string())
  }
  wbtest_remove_if_exists(db_path)
  wbtest_remove_if_exists(root)
}

///|
test "cli finalize export workflow supports fetch and apply" {
  let root = wbtest_make_temp_dir("finalize_export_apply")
  let db_path = root + "/tmp1.db"
  let out_path = root + "/main.vibe"
  let source = "let helper = (x: Int) -> Int { x + 1 }\n" +
    "let answer = helper(41)\n" +
    "helper(0)\n" +
    "export { answer }\n"
  match write_eval_db_source(db_path, source) {
    Ok(_) => ()
    Err(err) => fail("write seed db failed: " + err)
  }
  finalize_cmd(["--db=" + db_path, "--library", "--export=" + out_path])
  let exported = @os_fs.read_file_to_string(out_path) catch {
    e => fail("read exported module failed: " + e.to_string())
  }
  assert_true(exported.contains("let helper = (x: Int) -> Int"))
  assert_true(exported.contains("let answer = helper(41)"))
  assert_true(exported.contains("export { answer }"))
  assert_false(exported.contains("helper(0)"))
  fetch_cmd([out_path])
  let lock_path = @codebase.lock_file_path(out_path)
  let lock = match @codebase.load_lock_data(lock_path) {
    Ok(v) => v
    Err(err) => fail("load lock failed: " + err)
  }
  let resolved = @loader.resolve_entry_path(out_path)
  match lock.path_refs.get(resolved) {
    Some(hash) => assert_eq(hash, .git_blob_hash_string(exported))
    None => fail("expected path ref for exported module")
  }
  apply_cmd([out_path])
  match resolve_entry_artifacts(out_path) {
    Ok((db, entry, _lock, _index, _graph_head)) => {
      let _ = db.types(entry)
    }
    Err(err) => fail("resolve entry artifacts failed: " + err)
  }
  wbtest_remove_if_exists(out_path)
  wbtest_remove_if_exists(@codebase.lock_file_path(out_path))
  wbtest_remove_if_exists(db_path)
  wbtest_remove_if_exists(root)
}

///|
test "cli finalize library mode keeps re-export stmt parseable" {
  let root = wbtest_make_temp_dir("finalize_library_mode_reexport")
  let db_path = root + "/tmp1.db"
  let source = "let local = 1\n" +
    "local\n" +
    "export { helper } from \"./mod.vibe\"\n"
  match write_eval_db_source(db_path, source) {
    Ok(_) => ()
    Err(err) => fail("write seed db failed: " + err)
  }
  finalize_cmd(["--db=" + db_path, "--library"])
  let finalized = @os_fs.read_file_to_string(db_path) catch {
    e => fail("read finalized db failed: " + e.to_string())
  }
  assert_true(finalized.contains("export { helper } from ./mod.vibe"))
  assert_false(finalized.contains("let local = 1"))
  let ast = @parser.parse_ast(finalized) catch {
    e => fail("finalized parse failed: " + e.to_string())
  }
  let mut has_reexport = false
  for stmt in ast.stmts {
    match stmt {
      @vibe_core.Stmt::ReExport(names~, source~, ..) =>
        if names == ["helper"] {
          match source {
            @vibe_core.ModuleRef::Path(path~) =>
              if path == "./mod.vibe" {
                has_reexport = true
              }
            _ => ()
          }
        }
      _ => ()
    }
  }
  assert_true(has_reexport)
  wbtest_remove_if_exists(db_path)
  wbtest_remove_if_exists(root)
}

///|
fn scope_symbol_signatures_from_db(db_path : String) -> Map[String, String] {
  let source = match load_eval_db_source(db_path) {
    Ok(v) => v
    Err(err) => abort("load eval db failed: " + err)
  }
  let db = @runtime.VibeDb::new()
  db.set_source(db_path, source)
  let index = @runtime.build_symbol_index(db, [db_path])
  let out : Map[String, String] = {}
  for entry in index.entries {
    if entry.path == db_path {
      out[entry.name] = entry.signature
    }
  }
  out
}

///|
fn assert_scope_symbol_signature(
  scope : Map[String, String],
  symbol_name : String,
  expected_signature : String,
) -> Unit {
  match scope.get(symbol_name) {
    Some(signature) =>
      if signature != expected_signature {
        abort(
          "unexpected signature for `" +
          symbol_name +
          "` expected=`" +
          expected_signature +
          "` actual=`" +
          signature +
          "`",
        )
      }
    None => abort("missing scope symbol: " + symbol_name)
  }
}

///|
struct FunctionTrackingRecord {
  version : String
  renamed_from : String?
}

///|
fn read_function_tracking_record(
  index_root : String,
  key : String,
) -> FunctionTrackingRecord {
  let path = index_root + "/index.vdb"
  let source = @os_fs.read_file_to_string(path) catch {
    e => abort("read index.vdb failed: " + e.to_string())
  }
  let json : Json = @json.parse(source) catch {
    e => abort("parse index.vdb failed: " + e.to_string())
  }
  let obj = match json {
    Json::Object(map) => map
    _ => abort("index.vdb must be object")
  }
  let tracking = match obj.get("function_tracking") {
    Some(Json::Object(value)) => value
    _ => abort("index.vdb must include function_tracking object")
  }
  let records = match tracking.get("records") {
    Some(Json::Object(value)) => value
    _ => abort("function_tracking.records must be object")
  }
  let record = match records.get(key) {
    Some(Json::Object(value)) => value
    _ => abort("missing function_tracking record for " + key)
  }
  let version = match record.get("version") {
    Some(Json::String(value)) => value
    _ => abort("function_tracking record must include version")
  }
  let renamed_from = match record.get("renamed_from") {
    Some(Json::String(value)) =>
      if value.trim().to_string().length() == 0 {
        None
      } else {
        Some(value)
      }
    _ => None
  }
  FunctionTrackingRecord::{ version, renamed_from }
}
