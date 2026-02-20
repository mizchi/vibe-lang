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
      let _ = @vibe_core.deserialize_module(json) catch {
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
    Some(hash) => assert_eq(hash, @vibe_core.git_blob_hash_string(entry_source))
    None => fail("expected entry lock ref")
  }
  match lock.path_refs.get(lib_norm) {
    Some(hash) => assert_eq(hash, @vibe_core.git_blob_hash_string(lib_source))
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
      let _ = @vibe_core.deserialize_module(json) catch {
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
    "push", "vibe/builtin@0.1.0", "/tmp/advanced-graph-index.json",
  ])
  match parsed {
    Ok(action) =>
      match action {
        IndexRefAction::PushIndex(scope, path) => {
          assert_eq(scope, "vibe/builtin@0.1.0")
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
test "shell meta command names include ide helpers" {
  let names = repl_meta_command_names()
  assert_true(wbtest_contains(names, ":view"))
  assert_true(wbtest_contains(names, ":outline"))
  assert_true(wbtest_contains(names, ":peek"))
}

///|
test "shell meta command ignores non-meta input" {
  let lines : Array[String] = []
  let result = handle_repl_meta_command(
    "let value = 1",
    "/tmp/repl_meta_ignore.db",
    "",
    fn(s) { lines.push(s) },
  )
  assert_eq(result, ReplMetaCommandResult::NotMeta)
  assert_eq(lines.length(), 0)
}

///|
test "shell meta view resolves current module symbol" {
  let lines : Array[String] = []
  let source = "let base = 10\nlet inc = (x: Int) -> Int { x + base }\n"
  let result = handle_repl_meta_command(
    ":view inc",
    "/tmp/repl_meta_view.db",
    source,
    fn(s) { lines.push(s) },
  )
  assert_eq(result, ReplMetaCommandResult::HandledContinue)
  let text = wbtest_join_lines(lines)
  assert_true(text.contains("inc : (x: Int) -> Int"))
}

///|
test "shell meta outline defaults to current module" {
  let lines : Array[String] = []
  let source = "let base = 10\nlet inc = (x: Int) -> Int { x + base }\n"
  let result = handle_repl_meta_command(
    ":outline",
    "/tmp/repl_meta_outline.db",
    source,
    fn(s) { lines.push(s) },
  )
  assert_eq(result, ReplMetaCommandResult::HandledContinue)
  let text = wbtest_join_lines(lines)
  assert_true(text.contains("outline: current"))
  assert_true(text.contains("\tbase\t"))
  assert_true(text.contains("\tinc\t"))
}

///|
test "shell meta peek reports missing symbol" {
  let lines : Array[String] = []
  let source = "let base = 10\n"
  let result = handle_repl_meta_command(
    ":peek __wb_missing_symbol_1",
    "/tmp/repl_meta_peek.db",
    source,
    fn(s) { lines.push(s) },
  )
  assert_eq(result, ReplMetaCommandResult::HandledContinue)
  assert_eq(lines.length(), 1)
  assert_eq(lines[0], "symbol not found: __wb_missing_symbol_1")
}

///|
test "shell meta unknown command is handled" {
  let lines : Array[String] = []
  let result = handle_repl_meta_command(
    ":unknown",
    "/tmp/repl_meta_unknown.db",
    "",
    fn(s) { lines.push(s) },
  )
  assert_eq(result, ReplMetaCommandResult::HandledContinue)
  assert_eq(lines.length(), 1)
  assert_eq(lines[0], "unknown command: :unknown")
}

///|
test "shell vibe parser extracts subcommand args and pipeline" {
  match repl_parse_vibe_shell_invocation("vibe view inc |> json_get(\"ok\")") {
    Some(invocation) => {
      assert_eq(invocation.subcommand, "view")
      assert_eq(invocation.args, ["inc"])
      match invocation.pipeline_tail {
        Some(tail) => assert_eq(tail, "json_get(\"ok\")")
        None => fail("expected pipeline tail")
      }
    }
    None => fail("expected vibe shell invocation")
  }
}

///|
test "shell vibe command prints help json by default" {
  let lines : Array[String] = []
  let rt = new_cli_runtime(
    @runtime.RuntimeFeatureFlags::stable(),
    enable_llm=false,
  )
  let result = handle_repl_vibe_shell_command(
    rt,
    @runtime.ParserMode::XshMode,
    "vibe",
    "/tmp/repl_vibe_help.db",
    "",
    fn(s) { lines.push(s) },
  )
  assert_eq(result, ReplMetaCommandResult::HandledContinue)
  assert_eq(lines.length(), 1)
  assert_true(lines[0].contains("\"command\":\"help\""))
  assert_true(lines[0].contains("\"ok\":true"))
}

///|
test "shell vibe command supports pipeline transform over json payload" {
  let lines : Array[String] = []
  let rt = new_cli_runtime(
    @runtime.RuntimeFeatureFlags::stable(),
    enable_llm=false,
  )
  let source = "let inc = (x: Int) -> Int { x + 1 }\n"
  let result = handle_repl_vibe_shell_command(
    rt,
    @runtime.ParserMode::XshMode,
    "vibe view inc |> json_get(\"ok\")",
    "/tmp/repl_vibe_pipeline.db",
    source,
    fn(s) { lines.push(s) },
  )
  assert_eq(result, ReplMetaCommandResult::HandledContinue)
  let text = wbtest_join_lines(lines)
  assert_true(text.contains("last: true"))
}

///|
test "shell warns when binding reserved vibe subcommand name" {
  let root = wbtest_make_temp_dir("repl_reserved_binding_warn")
  let scratch_db_path = root + "/scratch.db"
  let lines : Array[String] = []
  let rt = new_cli_runtime(
    @runtime.RuntimeFeatureFlags::stable(),
    enable_llm=false,
  )
  let _ = run_interactive_line(
    rt,
    @runtime.ParserMode::XshMode,
    scratch_db_path,
    "",
    "let view = 1",
    print_line=fn(s) { lines.push(s) },
  )
  let text = wbtest_join_lines(lines)
  assert_true(
    text.contains(
      "warn: `view` is reserved for shell commands; use `view(...)` for explicit function call.",
    ),
  )
  wbtest_remove_if_exists(scratch_db_path)
  wbtest_remove_if_exists(root)
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
test "normalize options parse check single file" {
  let parsed = parse_normalize_cmd_options(["--check", "examples/main.vibe"])
  match parsed {
    Ok(opts) => {
      assert_true(opts.check)
      assert_false(opts.write)
      assert_eq(opts.files, ["examples/main.vibe"])
    }
    Err(msg) => fail("unexpected err: " + msg)
  }
}

///|
test "normalize options parse check multiple files" {
  let parsed = parse_normalize_cmd_options([
    "--check", "examples/a.vibe", "examples/b.vibe",
  ])
  match parsed {
    Ok(opts) => {
      assert_true(opts.check)
      assert_eq(opts.files.length(), 2)
    }
    Err(msg) => fail("unexpected err: " + msg)
  }
}

///|
test "normalize options reject check and write together" {
  let parsed = parse_normalize_cmd_options(["--check", "--write", "a.vibe"])
  match parsed {
    Ok(_) => fail("expected error")
    Err(msg) =>
      assert_eq(msg, "normalize: --check cannot be combined with --write")
  }
}

///|
test "normalize options reject unknown option" {
  let parsed = parse_normalize_cmd_options(["--check", "--wat", "a.vibe"])
  match parsed {
    Ok(_) => fail("expected error")
    Err(msg) => assert_eq(msg, "normalize: unknown option --wat")
  }
}

///|
test "normalize options reject -o without merge" {
  let parsed = parse_normalize_cmd_options(["-o", "/tmp/out.vibe", "a.vibe"])
  match parsed {
    Ok(_) => fail("expected error")
    Err(msg) => assert_eq(msg, "normalize: -o is only valid with --merge")
  }
}

///|
test "cli normalize directory writes merged index with version" {
  let root = wbtest_make_temp_dir("normalize_dir_index")
  let a_path = root + "/a.vibe"
  let b_path = root + "/b.vibe"
  @os_fs.write_string_to_file(a_path, "let foo = 1\nexport { foo }\n") catch {
    e => fail("write a.vibe failed: " + e.to_string())
  }
  @os_fs.write_string_to_file(b_path, "let bar = 2\nexport { bar }\n") catch {
    e => fail("write b.vibe failed: " + e.to_string())
  }
  normalize_cmd(["--write", root])
  let index_path = root + "/index.vibe"
  assert_true(@os_fs.path_exists(index_path))
  let index_source = @os_fs.read_file_to_string(index_path) catch {
    e => fail("read index.vibe failed: " + e.to_string())
  }
  assert_true(index_source.contains("export let version = \"0.1.0\""))
  assert_true(index_source.contains("foo"))
  assert_true(index_source.contains("bar"))
  assert_true(@os_fs.path_exists(a_path))
  assert_true(@os_fs.path_exists(b_path))
  wbtest_remove_if_exists(root)
}

///|
test "cli normalize directory rejects duplicate top-level definitions" {
  let root = wbtest_make_temp_dir("normalize_dir_conflict")
  @os_fs.write_string_to_file(root + "/a.vibe", "let foo = 1\nexport { foo }\n") catch {
    e => fail("write a.vibe failed: " + e.to_string())
  }
  @os_fs.write_string_to_file(root + "/b.vibe", "let foo = 2\nexport { foo }\n") catch {
    e => fail("write b.vibe failed: " + e.to_string())
  }
  match normalize_directory_to_index_source(root, false) {
    Ok(_) => fail("expected duplicate definition error")
    Err(err) => {
      assert_true(err.contains("duplicate value"))
      assert_true(err.contains("`foo`"))
    }
  }
  wbtest_remove_if_exists(root)
}

///|
test "cli normalize directory resolves latest import version in index" {
  let root = wbtest_make_temp_dir("normalize_dir_import_latest")
  let lib_root = root + "/lib"
  let lib_demo = lib_root + "/demo"
  @os_fs.create_dir(lib_root) catch {
    e => fail("create lib root failed: " + e.to_string())
  }
  @os_fs.create_dir(lib_demo) catch {
    e => fail("create demo lib dir failed: " + e.to_string())
  }
  @os_fs.write_string_to_file(lib_demo + "/pkg@0.1.0.vbundle", "hash:a\n") catch {
    e => fail("write pkg@0.1.0 alias failed: " + e.to_string())
  }
  @os_fs.write_string_to_file(lib_demo + "/pkg@0.2.0.vbundle", "hash:b\n") catch {
    e => fail("write pkg@0.2.0 alias failed: " + e.to_string())
  }
  @os_fs.write_string_to_file(
    root + "/index.vibe",
    "import demo/pkg\nlet root_value = 1\nexport { root_value }\n",
  ) catch {
    e => fail("write index.vibe failed: " + e.to_string())
  }
  @os_fs.write_string_to_file(
    root + "/util.vibe",
    "let util_value = 2\nexport { util_value }\n",
  ) catch {
    e => fail("write util.vibe failed: " + e.to_string())
  }
  let prev_root = @sys.get_env_var("VIBE_LIB_ROOT")
  let prev_dir = @sys.get_env_var("VIBE_LIB_DIR")
  @sys.set_env_var("VIBE_LIB_ROOT", lib_root)
  @sys.set_env_var("VIBE_LIB_DIR", root + "/legacy-lib")
  normalize_cmd(["--write", root])
  wbtest_restore_env_var("VIBE_LIB_ROOT", prev_root)
  wbtest_restore_env_var("VIBE_LIB_DIR", prev_dir)
  let index_source = @os_fs.read_file_to_string(root + "/index.vibe") catch {
    e => fail("read merged index.vibe failed: " + e.to_string())
  }
  assert_true(index_source.contains("import demo/pkg@0.2.0"))
  assert_true(index_source.contains("root_value"))
  assert_true(index_source.contains("util_value"))
  wbtest_remove_if_exists(root)
}

///|
test "cli normalize directory hoists non-index import into index" {
  let root = wbtest_make_temp_dir("normalize_dir_hoist_import")
  let lib_root = root + "/lib"
  let lib_demo = lib_root + "/demo"
  @os_fs.create_dir(lib_root) catch {
    e => fail("create lib root failed: " + e.to_string())
  }
  @os_fs.create_dir(lib_demo) catch {
    e => fail("create demo lib dir failed: " + e.to_string())
  }
  @os_fs.write_string_to_file(lib_demo + "/pkg@0.1.0.vbundle", "hash:a\n") catch {
    e => fail("write pkg@0.1.0 alias failed: " + e.to_string())
  }
  @os_fs.write_string_to_file(lib_demo + "/pkg@0.2.0.vbundle", "hash:b\n") catch {
    e => fail("write pkg@0.2.0 alias failed: " + e.to_string())
  }
  @os_fs.write_string_to_file(
    root + "/a.vibe",
    "import demo/pkg\nlet a_value = 1\nexport { a_value }\n",
  ) catch {
    e => fail("write a.vibe failed: " + e.to_string())
  }
  @os_fs.write_string_to_file(
    root + "/b.vibe",
    "let b_value = 2\nexport { b_value }\n",
  ) catch {
    e => fail("write b.vibe failed: " + e.to_string())
  }
  let prev_root = @sys.get_env_var("VIBE_LIB_ROOT")
  let prev_dir = @sys.get_env_var("VIBE_LIB_DIR")
  @sys.set_env_var("VIBE_LIB_ROOT", lib_root)
  @sys.set_env_var("VIBE_LIB_DIR", root + "/legacy-lib")
  normalize_cmd(["--write", root])
  wbtest_restore_env_var("VIBE_LIB_ROOT", prev_root)
  wbtest_restore_env_var("VIBE_LIB_DIR", prev_dir)
  let index_source = @os_fs.read_file_to_string(root + "/index.vibe") catch {
    e => fail("read merged index.vibe failed: " + e.to_string())
  }
  assert_true(index_source.contains("import demo/pkg@0.2.0"))
  assert_true(index_source.contains("a_value"))
  assert_true(index_source.contains("b_value"))
  wbtest_remove_if_exists(root)
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
  let baseline_wasm = @runtime_compile.compile_module_wasm_with_opt_level(
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
test "cli index build writes index.vbundle graph head" {
  let root = wbtest_make_temp_dir("index_build_vdb")
  let entry = root + "/main.vibe"
  let out_path = root + "/advanced-graph-index.json"
  @os_fs.write_string_to_file(entry, "let value = 1\nexport { value }\n") catch {
    e => fail("write entry failed: " + e.to_string())
  }
  index_build_cmd(["-o", out_path, entry])
  assert_true(@os_fs.path_exists(out_path))
  let vdb_path = root + "/index.vbundle"
  assert_true(@os_fs.path_exists(vdb_path))
  let vdb_source = @os_fs.read_file_to_string(vdb_path) catch {
    e => fail("read index.vbundle failed: " + e.to_string())
  }
  let vdb_json : Json = @json.parse(vdb_source) catch {
    e => fail("parse index.vbundle failed: " + e.to_string())
  }
  let graph_head = match vdb_json {
    Json::Object(obj) =>
      match obj.get("graph_head") {
        Some(Json::String(hash)) => hash
        _ => fail("index.vbundle must include graph_head")
      }
    _ => fail("index.vbundle must be object")
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
test "cli bundle pack verify and cat workflow" {
  let root = wbtest_make_temp_dir("bundle_pack_verify")
  let entry = root + "/index.vibe"
  let out_path = root + "/demo@0.1.0.vbundle"
  @os_fs.write_string_to_file(
    entry, "export let version = \"0.1.0\"\nlet value = 1\nexport { value }\n",
  ) catch {
    e => fail("write entry failed: " + e.to_string())
  }
  bundle_pack_cmd([
    "--scope", "demo/pkg", "--version", "0.1.0", "--entry", root, "-o", out_path,
  ])
  assert_true(@os_fs.path_exists(out_path))
  bundle_verify_cmd([out_path])
  let source = @os_fs.read_file_to_string(out_path) catch {
    e => fail("read vbundle failed: " + e.to_string())
  }
  let json : Json = @json.parse(source) catch {
    e => fail("parse vbundle failed: " + e.to_string())
  }
  let first_hash = match json {
    Json::Object(obj) =>
      match obj.get("objects") {
        Some(Json::Object(objects)) => {
          let mut found = ""
          for hash, _ in objects {
            found = hash
            break
          }
          if found.length() == 0 {
            fail("bundle must include at least one object")
          }
          found
        }
        _ => fail("bundle objects missing")
      }
    _ => fail("bundle root must be object")
  }
  bundle_cat_cmd([out_path, "--hash", first_hash])
  wbtest_remove_if_exists(root)
}

///|
test "cli bundle sync options parse target and base" {
  let parsed = parse_bundle_sync_cmd_options([
    "--base", "demo/pkg@0.1.0.vbundle", "--scope", "demo/pkg", "--version", "0.2.0",
    "demo/pkg@0.2.0.vbundle",
  ])
  match parsed {
    Ok(opts) => {
      assert_eq(opts.target_path, "demo/pkg@0.2.0.vbundle")
      assert_eq(opts.base_path, Some("demo/pkg@0.1.0.vbundle"))
      assert_eq(opts.scope, Some("demo/pkg"))
      assert_eq(opts.bundle_version, Some("0.2.0"))
      assert_eq(opts.lib_root, None)
    }
    Err(msg) => fail("unexpected err: " + msg)
  }
}

///|
test "cli bundle sync options reject unknown arg" {
  let parsed = parse_bundle_sync_cmd_options(["--wat", "demo/pkg@0.2.0.vbundle"])
  match parsed {
    Ok(_) => fail("expected error")
    Err(msg) => assert_eq(msg, "bundle sync: unknown arg --wat")
  }
}

///|
test "cli bundle sync collect plan skips base object hashes" {
  let hash_a = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  let hash_b = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  let hash_c = "cccccccccccccccccccccccccccccccccccccccc"
  let target : Map[String, Json] = {}
  target[hash_a] = Json::string("A")
  target[hash_b] = Json::string("B")
  target[hash_c] = Json::string("C")
  let base : Map[String, Json] = {}
  base["#" + hash_a] = Json::string("A")
  base[hash_b] = Json::string("B")
  let base_hashes = bundle_hash_set_from_objects_obj(base)
  let plan = match bundle_sync_collect_plan(target, base_hashes) {
    Ok(v) => v
    Err(err) => fail("unexpected plan error: " + err)
  }
  assert_eq(plan.total_objects, 3)
  assert_eq(plan.skipped_base_objects, 2)
  assert_eq(plan.entries.length(), 1)
  let (hash, content) = plan.entries[0]
  assert_eq(hash, hash_c)
  assert_eq(content, "C")
}

///|
test "cli bundle sync with explicit base keeps missing shared objects" {
  let root = wbtest_make_temp_dir("bundle_sync_base_missing")
  let lib_root = root + "/lib-root"
  let legacy_lib = root + "/legacy-lib"
  let v1_path = root + "/pkg@0.1.0.vbundle"
  let v2_path = root + "/pkg@0.2.0.vbundle"
  let common_source = "let shared = 1\nexport { shared }\n"
  let v1_source = "let old_value = 2\nexport { old_value }\n"
  let v2_source = "let new_value = 3\nexport { new_value }\n"
  let common_hash = @vibe_core.git_blob_hash_string(common_source)
  let v1_hash = @vibe_core.git_blob_hash_string(v1_source)
  let v2_hash = @vibe_core.git_blob_hash_string(v2_source)
  let objects_v1 : Map[String, Json] = {}
  objects_v1[common_hash] = Json::string(common_source)
  objects_v1[v1_hash] = Json::string(v1_source)
  let meta_v1 : Map[String, Json] = {}
  meta_v1["scope"] = Json::string("demo/pkg")
  meta_v1["version"] = Json::string("0.1.0")
  meta_v1["entry_hash"] = Json::string(common_hash)
  let root_v1 : Map[String, Json] = {}
  root_v1["format"] = Json::string("vbundle-1")
  root_v1["meta"] = Json::object(meta_v1)
  root_v1["refs"] = Json::object({})
  root_v1["objects"] = Json::object(objects_v1)
  @os_fs.write_string_to_file(v1_path, Json::object(root_v1).stringify() + "\n") catch {
    e => fail("write v1 bundle failed: " + e.to_string())
  }
  let objects_v2 : Map[String, Json] = {}
  objects_v2[common_hash] = Json::string(common_source)
  objects_v2[v2_hash] = Json::string(v2_source)
  let meta_v2 : Map[String, Json] = {}
  meta_v2["scope"] = Json::string("demo/pkg")
  meta_v2["version"] = Json::string("0.2.0")
  meta_v2["entry_hash"] = Json::string(common_hash)
  let root_v2 : Map[String, Json] = {}
  root_v2["format"] = Json::string("vbundle-1")
  root_v2["meta"] = Json::object(meta_v2)
  root_v2["refs"] = Json::object({})
  root_v2["objects"] = Json::object(objects_v2)
  @os_fs.write_string_to_file(v2_path, Json::object(root_v2).stringify() + "\n") catch {
    e => fail("write v2 bundle failed: " + e.to_string())
  }
  let prev_root = @sys.get_env_var("VIBE_LIB_ROOT")
  let prev_dir = @sys.get_env_var("VIBE_LIB_DIR")
  @sys.set_env_var("VIBE_LIB_ROOT", lib_root)
  @sys.set_env_var("VIBE_LIB_DIR", legacy_lib)
  bundle_cmd(["sync", "--base", v1_path, v2_path])
  wbtest_restore_env_var("VIBE_LIB_ROOT", prev_root)
  wbtest_restore_env_var("VIBE_LIB_DIR", prev_dir)
  let codebase = @codebase.Codebase::new(lib_root)
  assert_true(@os_fs.path_exists(codebase.object_path(common_hash)))
  assert_true(@os_fs.path_exists(codebase.object_path(v2_hash)))
  wbtest_remove_if_exists(root)
}

///|
test "cli bundle pack writes alias and object cache under VIBE_LIB_ROOT" {
  let root = wbtest_make_temp_dir("bundle_pack_cache_root")
  let lib_root = root + "/lib-root"
  let entry = root + "/index.vibe"
  let out_path = root + "/demo@0.1.0.vbundle"
  @os_fs.write_string_to_file(
    entry, "export let version = \"0.1.0\"\nlet value = 1\nexport { value }\n",
  ) catch {
    e => fail("write entry failed: " + e.to_string())
  }
  let prev_root = @sys.get_env_var("VIBE_LIB_ROOT")
  let prev_dir = @sys.get_env_var("VIBE_LIB_DIR")
  @sys.set_env_var("VIBE_LIB_ROOT", lib_root)
  @sys.set_env_var("VIBE_LIB_DIR", root + "/legacy-lib")
  bundle_pack_cmd([
    "--scope", "demo/pkg", "--version", "0.1.0", "--entry", root, "-o", out_path,
  ])
  wbtest_restore_env_var("VIBE_LIB_ROOT", prev_root)
  wbtest_restore_env_var("VIBE_LIB_DIR", prev_dir)
  let alias_path = lib_root + "/demo/pkg@0.1.0.vbundle"
  assert_true(@os_fs.path_exists(alias_path))
  let alias_source = @os_fs.read_file_to_string(alias_path) catch {
    e => fail("read alias failed: " + e.to_string())
  }
  let alias_trimmed = alias_source.trim().to_string()
  assert_true(alias_trimmed.has_prefix("hash:"))
  let bundle_hash = alias_trimmed
    .unsafe_substring(start=5, end=alias_trimmed.length())
    .trim()
    .to_string()
  assert_eq(bundle_hash.length(), 40)
  let hash_dir = bundle_hash.unsafe_substring(start=0, end=2)
  let hash_file = bundle_hash.unsafe_substring(
    start=2,
    end=bundle_hash.length(),
  )
  let object_path = lib_root + "/objects/" + hash_dir + "/" + hash_file
  assert_true(@os_fs.path_exists(object_path))
  let object_source = @os_fs.read_file_to_string(object_path) catch {
    e => fail("read object failed: " + e.to_string())
  }
  let object_json : Json = @json.parse(object_source) catch {
    e => fail("parse object failed: " + e.to_string())
  }
  match object_json {
    Json::Object(obj) =>
      match obj.get("format") {
        Some(Json::String(value)) => assert_eq(value, "vbundle-1")
        _ => fail("cached object must be packed vbundle")
      }
    _ => fail("cached object must be JSON object")
  }
  wbtest_remove_if_exists(root)
}

///|
test "cli bundle and eval named alias workflow covers root priority and dir fallback" {
  let root = wbtest_make_temp_dir("bundle_eval_named_alias_workflow")
  let lib_root = root + "/lib-root"
  let legacy_lib = root + "/legacy-lib"
  let pkg_root = root + "/pkg"
  @os_fs.create_dir(pkg_root) catch {
    e => fail("create pkg root failed: " + e.to_string())
  }
  @os_fs.write_string_to_file(
    pkg_root + "/index.vibe",
    "export let version = \"0.1.0\"\nlet seed = 70\nexport { seed }\n",
  ) catch {
    e => fail("write package entry failed: " + e.to_string())
  }
  let bundle_out = root + "/seed@0.1.0.vbundle"
  let include_spec = "seed/pkg@0.1.0.vbundle"
  let alias_path = lib_root + "/" + include_spec
  let legacy_alias_path = legacy_lib + "/" + include_spec
  let prev_root = @sys.get_env_var("VIBE_LIB_ROOT")
  let prev_dir = @sys.get_env_var("VIBE_LIB_DIR")
  @sys.set_env_var("VIBE_LIB_ROOT", lib_root)
  @sys.set_env_var("VIBE_LIB_DIR", legacy_lib)
  bundle_cmd([
    "pack", "--scope", "seed/pkg", "--version", "0.1.0", "--entry", pkg_root, "-o",
    bundle_out,
  ])
  bundle_cmd(["verify", bundle_out])
  assert_true(@os_fs.path_exists(alias_path))
  let alias_source = @os_fs.read_file_to_string(alias_path) catch {
    e => fail("read alias failed: " + e.to_string())
  }
  let alias_trimmed = alias_source.trim().to_string()
  assert_true(alias_trimmed.has_prefix("hash:"))
  let bundle_hash = alias_trimmed
    .unsafe_substring(start=5, end=alias_trimmed.length())
    .trim()
    .to_string()
  let hash_dir = bundle_hash.unsafe_substring(start=0, end=2)
  let hash_file = bundle_hash.unsafe_substring(
    start=2,
    end=bundle_hash.length(),
  )
  let object_path = lib_root + "/objects/" + hash_dir + "/" + hash_file
  assert_true(@os_fs.path_exists(object_path))
  match ensure_parent_dir_for_file(legacy_alias_path, "test setup") {
    Ok(_) => ()
    Err(err) => fail("ensure legacy alias dir failed: " + err)
  }
  @os_fs.write_string_to_file(
    legacy_alias_path, "hash:0000000000000000000000000000000000000000\n",
  ) catch {
    e => fail("write legacy alias failed: " + e.to_string())
  }
  let features = @runtime.RuntimeFeatureFlags::stable()
  let db_root_priority = root + "/root_priority.db"
  let out_root_priority = root + "/root_priority.vibe"
  eval_cmd(
    [
      "--db=" + db_root_priority,
      "--include=" + include_spec,
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
      "--db=" + db_root_priority,
      "--include=" + include_spec,
      "export",
      "{",
      "answer",
      "}",
    ],
    @runtime.ParserMode::XshMode,
    features,
  )
  eval_cmd(
    [
      "--db=" + db_root_priority,
      "--include=" + include_spec,
      "--export=" + out_root_priority,
    ],
    @runtime.ParserMode::XshMode,
    features,
  )
  let exported_root_priority = @os_fs.read_file_to_string(out_root_priority) catch {
    e => fail("read root priority export failed: " + e.to_string())
  }
  assert_true(exported_root_priority.contains("let answer = seed + 1"))
  @sys.unset_env_var("VIBE_LIB_ROOT")
  @sys.set_env_var("VIBE_LIB_DIR", lib_root)
  let db_dir_fallback = root + "/dir_fallback.db"
  let out_dir_fallback = root + "/dir_fallback.vibe"
  eval_cmd(
    [
      "--db=" + db_dir_fallback,
      "--include=" + include_spec,
      "let",
      "answer",
      "=",
      "seed",
      "+",
      "3",
    ],
    @runtime.ParserMode::XshMode,
    features,
  )
  eval_cmd(
    [
      "--db=" + db_dir_fallback,
      "--include=" + include_spec,
      "export",
      "{",
      "answer",
      "}",
    ],
    @runtime.ParserMode::XshMode,
    features,
  )
  eval_cmd(
    [
      "--db=" + db_dir_fallback,
      "--include=" + include_spec,
      "--export=" + out_dir_fallback,
    ],
    @runtime.ParserMode::XshMode,
    features,
  )
  let exported_dir_fallback = @os_fs.read_file_to_string(out_dir_fallback) catch {
    e => fail("read dir fallback export failed: " + e.to_string())
  }
  assert_true(exported_dir_fallback.contains("let answer = seed + 3"))
  wbtest_restore_env_var("VIBE_LIB_ROOT", prev_root)
  wbtest_restore_env_var("VIBE_LIB_DIR", prev_dir)
  wbtest_remove_if_exists(out_root_priority)
  wbtest_remove_if_exists(out_dir_fallback)
  wbtest_remove_if_exists(db_root_priority)
  wbtest_remove_if_exists(db_dir_fallback)
  wbtest_remove_if_exists(root)
}

///|
test "cli bundle migrate copies legacy vdb to vbundle" {
  let root = wbtest_make_temp_dir("bundle_migrate")
  let legacy = root + "/legacy.vdb"
  let out = root + "/legacy.vbundle"
  @os_fs.write_string_to_file(
    legacy, "{\"graph_head\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}\n",
  ) catch {
    e => fail("write legacy vdb failed: " + e.to_string())
  }
  bundle_migrate_cmd([legacy])
  assert_true(@os_fs.path_exists(out))
  let migrated = @os_fs.read_file_to_string(out) catch {
    e => fail("read migrated vbundle failed: " + e.to_string())
  }
  assert_true(migrated.contains("graph_head"))
  wbtest_remove_if_exists(root)
}

///|
test "cli bundle sync auto-resolves previous version and syncs object delta" {
  let root = wbtest_make_temp_dir("bundle_sync_delta")
  let lib_root = root + "/lib-root"
  let legacy_lib = root + "/legacy-lib"
  let v1_path = root + "/pkg@0.1.0.vbundle"
  let v2_path = root + "/pkg@0.2.0.vbundle"
  let common_source = "let shared = 1\nexport { shared }\n"
  let v1_source = "let old_value = 2\nexport { old_value }\n"
  let v2_source = "let new_value = 3\nexport { new_value }\n"
  let common_hash = @vibe_core.git_blob_hash_string(common_source)
  let v1_hash = @vibe_core.git_blob_hash_string(v1_source)
  let v2_hash = @vibe_core.git_blob_hash_string(v2_source)
  let objects_v1 : Map[String, Json] = {}
  objects_v1[common_hash] = Json::string(common_source)
  objects_v1[v1_hash] = Json::string(v1_source)
  let meta_v1 : Map[String, Json] = {}
  meta_v1["scope"] = Json::string("demo/pkg")
  meta_v1["version"] = Json::string("0.1.0")
  meta_v1["entry_hash"] = Json::string(common_hash)
  let root_v1 : Map[String, Json] = {}
  root_v1["format"] = Json::string("vbundle-1")
  root_v1["meta"] = Json::object(meta_v1)
  root_v1["refs"] = Json::object({})
  root_v1["objects"] = Json::object(objects_v1)
  let bundle_v1_source = Json::object(root_v1).stringify() + "\n"
  @os_fs.write_string_to_file(v1_path, bundle_v1_source) catch {
    e => fail("write v1 bundle failed: " + e.to_string())
  }
  let objects_v2 : Map[String, Json] = {}
  objects_v2[common_hash] = Json::string(common_source)
  objects_v2[v1_hash] = Json::string(v1_source)
  objects_v2[v2_hash] = Json::string(v2_source)
  let meta_v2 : Map[String, Json] = {}
  meta_v2["scope"] = Json::string("demo/pkg")
  meta_v2["version"] = Json::string("0.2.0")
  meta_v2["entry_hash"] = Json::string(common_hash)
  let root_v2 : Map[String, Json] = {}
  root_v2["format"] = Json::string("vbundle-1")
  root_v2["meta"] = Json::object(meta_v2)
  root_v2["refs"] = Json::object({})
  root_v2["objects"] = Json::object(objects_v2)
  let bundle_v2_source = Json::object(root_v2).stringify() + "\n"
  @os_fs.write_string_to_file(v2_path, bundle_v2_source) catch {
    e => fail("write v2 bundle failed: " + e.to_string())
  }
  let prev_root = @sys.get_env_var("VIBE_LIB_ROOT")
  let prev_dir = @sys.get_env_var("VIBE_LIB_DIR")
  @sys.set_env_var("VIBE_LIB_ROOT", lib_root)
  @sys.set_env_var("VIBE_LIB_DIR", legacy_lib)
  bundle_cmd(["sync", v1_path])
  let codebase = @codebase.Codebase::new(lib_root)
  assert_true(@os_fs.path_exists(codebase.object_path(common_hash)))
  assert_true(@os_fs.path_exists(codebase.object_path(v1_hash)))
  let v1_bundle_hash = @vibe_core.git_blob_hash_string(bundle_v1_source)
  assert_true(@os_fs.path_exists(codebase.object_path(v1_bundle_hash)))
  let alias_v1_path = lib_root + "/demo/pkg@0.1.0.vbundle"
  assert_true(@os_fs.path_exists(alias_v1_path))
  let alias_v1_source = @os_fs.read_file_to_string(alias_v1_path) catch {
    e => fail("read alias v1 failed: " + e.to_string())
  }
  assert_eq(alias_v1_source.trim().to_string(), "hash:" + v1_bundle_hash)
  bundle_cmd(["sync", v2_path])
  wbtest_restore_env_var("VIBE_LIB_ROOT", prev_root)
  wbtest_restore_env_var("VIBE_LIB_DIR", prev_dir)
  assert_true(@os_fs.path_exists(codebase.object_path(common_hash)))
  assert_true(@os_fs.path_exists(codebase.object_path(v1_hash)))
  assert_true(@os_fs.path_exists(codebase.object_path(v2_hash)))
  let v2_bundle_hash = @vibe_core.git_blob_hash_string(bundle_v2_source)
  assert_true(@os_fs.path_exists(codebase.object_path(v2_bundle_hash)))
  let alias_v2_path = lib_root + "/demo/pkg@0.2.0.vbundle"
  assert_true(@os_fs.path_exists(alias_v2_path))
  let alias_v2_source = @os_fs.read_file_to_string(alias_v2_path) catch {
    e => fail("read alias v2 failed: " + e.to_string())
  }
  assert_eq(alias_v2_source.trim().to_string(), "hash:" + v2_bundle_hash)
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
  let vdb_path = root + "/index.vbundle"
  assert_true(@os_fs.path_exists(vdb_path))
  let vdb_source = @os_fs.read_file_to_string(vdb_path) catch {
    e => fail("read index.vbundle failed: " + e.to_string())
  }
  let vdb_json : Json = @json.parse(vdb_source) catch {
    e => fail("parse index.vbundle failed: " + e.to_string())
  }
  let graph_head = match vdb_json {
    Json::Object(obj) =>
      match obj.get("graph_head") {
        Some(Json::String(hash)) => hash
        _ => fail("index.vbundle must include graph_head")
      }
    _ => fail("index.vbundle must be object")
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
  let vdb_path = root + "/index.vbundle"
  assert_true(@os_fs.path_exists(vdb_path))
  let vdb_source = @os_fs.read_file_to_string(vdb_path) catch {
    e => fail("read index.vbundle failed: " + e.to_string())
  }
  let vdb_json : Json = @json.parse(vdb_source) catch {
    e => fail("parse index.vbundle failed: " + e.to_string())
  }
  let graph_head = match vdb_json {
    Json::Object(obj) =>
      match obj.get("graph_head") {
        Some(Json::String(hash)) => hash
        _ => fail("index.vbundle must include graph_head")
      }
    _ => fail("index.vbundle must be object")
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
    Some(hash) => assert_eq(hash, @vibe_core.git_blob_hash_string(exported))
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
  let include_path = root + "/index.vbundle"
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
test "cli eval include supports hash alias from vbundle file" {
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
  let include_path = lib_vibe + "/std@0.1.0.vbundle"
  let out_path = root + "/main.vibe"
  let seed_source = "let seed = 21\n"
  let seed_hash = @vibe_core.git_blob_hash_string(seed_source)
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
test "cli eval include resolves named alias from VIBE_LIB_ROOT first" {
  let root = wbtest_make_temp_dir("eval_db_named_alias_lib_root")
  let lib_root = root + "/lib-root"
  let legacy_lib = root + "/legacy-lib"
  let db_path = root + "/tmp1.db"
  let out_path = root + "/main.vibe"
  let alias_path = lib_root + "/vibe/builtin@0.1.0.vbundle"
  let legacy_alias_path = legacy_lib + "/vibe/builtin@0.1.0.vbundle"
  let seed_source = "let seed = 50\n"
  let seed_hash = @vibe_core.git_blob_hash_string(seed_source)
  let codebase = @codebase.Codebase::new(lib_root)
  let _ = codebase.write_object(seed_hash, seed_source) catch {
    e => fail("write alias object failed: " + e.to_string())
  }
  @os_fs.create_dir(lib_root + "/vibe") catch {
    e => fail("create lib_root/vibe failed: " + e.to_string())
  }
  @os_fs.write_string_to_file(alias_path, "hash:" + seed_hash + "\n") catch {
    e => fail("write lib root alias failed: " + e.to_string())
  }
  @os_fs.create_dir(legacy_lib) catch {
    e => fail("create legacy lib failed: " + e.to_string())
  }
  @os_fs.create_dir(legacy_lib + "/vibe") catch {
    e => fail("create legacy lib/vibe failed: " + e.to_string())
  }
  @os_fs.write_string_to_file(
    legacy_alias_path, "hash:0000000000000000000000000000000000000000\n",
  ) catch {
    e => fail("write legacy alias failed: " + e.to_string())
  }
  let prev_root = @sys.get_env_var("VIBE_LIB_ROOT")
  let prev_dir = @sys.get_env_var("VIBE_LIB_DIR")
  @sys.set_env_var("VIBE_LIB_ROOT", lib_root)
  @sys.set_env_var("VIBE_LIB_DIR", legacy_lib)
  let features = @runtime.RuntimeFeatureFlags::stable()
  eval_cmd(
    [
      "--db=" + db_path,
      "--include=vibe/builtin@0.1.0.vbundle",
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
      "--include=vibe/builtin@0.1.0.vbundle",
      "export",
      "{",
      "answer",
      "}",
    ],
    @runtime.ParserMode::XshMode,
    features,
  )
  eval_cmd(
    [
      "--db=" + db_path,
      "--include=vibe/builtin@0.1.0.vbundle",
      "--export=" + out_path,
    ],
    @runtime.ParserMode::XshMode,
    features,
  )
  wbtest_restore_env_var("VIBE_LIB_ROOT", prev_root)
  wbtest_restore_env_var("VIBE_LIB_DIR", prev_dir)
  let exported = @os_fs.read_file_to_string(out_path) catch {
    e => fail("read exported module failed: " + e.to_string())
  }
  assert_true(exported.contains("let answer = seed + 2"))
  assert_true(exported.contains("export { answer }"))
  wbtest_remove_if_exists(out_path)
  wbtest_remove_if_exists(db_path)
  wbtest_remove_if_exists(root)
}

///|
test "cli eval include resolves latest named alias when version omitted" {
  let root = wbtest_make_temp_dir("eval_db_named_alias_latest")
  let lib_root = root + "/lib-root"
  let db_path = root + "/tmp1.db"
  let out_path = root + "/main.vibe"
  let alias_v1 = lib_root + "/vibe/builtin@0.1.0.vbundle"
  let alias_v2 = lib_root + "/vibe/builtin@0.2.0.vbundle"
  let seed_source = "let seed = 60\n"
  let seed_hash = @vibe_core.git_blob_hash_string(seed_source)
  let codebase = @codebase.Codebase::new(lib_root)
  let _ = codebase.write_object(seed_hash, seed_source) catch {
    e => fail("write alias object failed: " + e.to_string())
  }
  @os_fs.create_dir(lib_root + "/vibe") catch {
    e => fail("create lib_root/vibe failed: " + e.to_string())
  }
  // Old version intentionally points to missing object. Latest must be selected.
  @os_fs.write_string_to_file(
    alias_v1, "hash:0000000000000000000000000000000000000000\n",
  ) catch {
    e => fail("write older alias failed: " + e.to_string())
  }
  @os_fs.write_string_to_file(alias_v2, "hash:" + seed_hash + "\n") catch {
    e => fail("write latest alias failed: " + e.to_string())
  }
  let prev_root = @sys.get_env_var("VIBE_LIB_ROOT")
  let prev_dir = @sys.get_env_var("VIBE_LIB_DIR")
  @sys.set_env_var("VIBE_LIB_ROOT", lib_root)
  @sys.set_env_var("VIBE_LIB_DIR", root + "/legacy-lib")
  let features = @runtime.RuntimeFeatureFlags::stable()
  eval_cmd(
    [
      "--db=" + db_path,
      "--include=vibe/builtin.vbundle",
      "let",
      "answer",
      "=",
      "seed",
      "+",
      "3",
    ],
    @runtime.ParserMode::XshMode,
    features,
  )
  eval_cmd(
    [
      "--db=" + db_path,
      "--include=vibe/builtin.vbundle",
      "export",
      "{",
      "answer",
      "}",
    ],
    @runtime.ParserMode::XshMode,
    features,
  )
  eval_cmd(
    [
      "--db=" + db_path,
      "--include=vibe/builtin.vbundle",
      "--export=" + out_path,
    ],
    @runtime.ParserMode::XshMode,
    features,
  )
  wbtest_restore_env_var("VIBE_LIB_ROOT", prev_root)
  wbtest_restore_env_var("VIBE_LIB_DIR", prev_dir)
  let exported = @os_fs.read_file_to_string(out_path) catch {
    e => fail("read exported module failed: " + e.to_string())
  }
  assert_true(exported.contains("let answer = seed + 3"))
  assert_true(exported.contains("export { answer }"))
  wbtest_remove_if_exists(out_path)
  wbtest_remove_if_exists(db_path)
  wbtest_remove_if_exists(root)
}

///|
test "cli eval include supports packed vbundle entry source" {
  let root = wbtest_make_temp_dir("eval_db_include_packed_vbundle")
  let include_entry = root + "/index.vibe"
  let include_bundle = root + "/seed@0.1.0.vbundle"
  let db_path = root + "/tmp1.db"
  let out_path = root + "/main.vibe"
  @os_fs.write_string_to_file(
    include_entry, "export let version = \"0.1.0\"\nlet seed = 30\nexport { seed }\n",
  ) catch {
    e => fail("write include entry failed: " + e.to_string())
  }
  bundle_pack_cmd([
    "--scope", "seed/pkg", "--version", "0.1.0", "--entry", root, "-o", include_bundle,
  ])
  let features = @runtime.RuntimeFeatureFlags::stable()
  eval_cmd(
    [
      "--db=" + db_path,
      "--include=" + include_bundle,
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
      "--include=" + include_bundle,
      "export",
      "{",
      "answer",
      "}",
    ],
    @runtime.ParserMode::XshMode,
    features,
  )
  eval_cmd(
    ["--db=" + db_path, "--include=" + include_bundle, "--export=" + out_path],
    @runtime.ParserMode::XshMode,
    features,
  )
  let exported = @os_fs.read_file_to_string(out_path) catch {
    e => fail("read exported module failed: " + e.to_string())
  }
  assert_true(exported.contains("let answer = seed + 2"))
  assert_true(exported.contains("export { answer }"))
  wbtest_remove_if_exists(out_path)
  wbtest_remove_if_exists(db_path)
  wbtest_remove_if_exists(include_bundle)
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
    Some(hash) => assert_eq(hash, @vibe_core.git_blob_hash_string(exported))
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
    "export { helper } from ./mod.vibe\n"
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
  let path = index_root + "/index.vbundle"
  let source = @os_fs.read_file_to_string(path) catch {
    e => abort("read index.vbundle failed: " + e.to_string())
  }
  let json : Json = @json.parse(source) catch {
    e => abort("parse index.vbundle failed: " + e.to_string())
  }
  let obj = match json {
    Json::Object(map) => map
    _ => abort("index.vbundle must be object")
  }
  let tracking = match obj.get("function_tracking") {
    Some(Json::Object(value)) => value
    _ => abort("index.vbundle must include function_tracking object")
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
