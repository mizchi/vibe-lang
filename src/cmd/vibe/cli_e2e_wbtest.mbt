///|
test "cli save fetch expand workflow keeps codebase artifacts" {
  let root = wbtest_make_temp_dir("save_fetch_expand")
  let entry = root + "/main.vibe"
  let lib = root + "/lib.vibe"
  let entry_source = "import ./lib.vibe {  inc  }\nlet main = inc(1)\nexport { main }\n"
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
    "push", "vibe/prelude@0.1.0", "/tmp/advanced-graph-index.json",
  ])
  match parsed {
    Ok(action) =>
      match action {
        IndexRefAction::PushIndex(scope, path) => {
          assert_eq(scope, "vibe/prelude@0.1.0")
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
  assert_true(wbtest_contains(names, ":type"))
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
  match repl_parse_vibe_shell_invocation("vibe view inc |> Json::get(\"ok\")") {
    Some(invocation) => {
      assert_eq(invocation.subcommand, "view")
      assert_eq(invocation.args, ["inc"])
      match invocation.pipeline_tail {
        Some(tail) => assert_eq(tail, "Json::get(\"ok\")")
        None => fail("expected pipeline tail")
      }
    }
    None => fail("expected vibe shell invocation")
  }
}

///|
test "shell vibe parser accepts bare subcommand" {
  match repl_parse_vibe_shell_invocation("symbols") {
    Some(invocation) => {
      assert_eq(invocation.subcommand, "symbols")
      assert_eq(invocation.args.length(), 0)
      assert_eq(invocation.pipeline_tail, None)
    }
    None => fail("expected bare vibe shell invocation")
  }
}

///|
test "shell symbols options parse default local only" {
  match repl_parse_symbols_options([]) {
    Ok(opts) => {
      assert_true(opts.include_local)
      assert_false(opts.include_builtin)
      assert_false(opts.include_shell)
    }
    Err(err) => fail("unexpected error: " + err)
  }
}

///|
test "shell symbols options parse explicit scopes" {
  match repl_parse_symbols_options(["--scope", "builtin,shell"]) {
    Ok(opts) => {
      assert_false(opts.include_local)
      assert_true(opts.include_builtin)
      assert_true(opts.include_shell)
    }
    Err(err) => fail("unexpected error: " + err)
  }
}

///|
test "shell symbols options reject unknown scope" {
  match repl_parse_symbols_options(["--scope", "wat"]) {
    Ok(_) => fail("expected error")
    Err(err) =>
      assert_eq(
        err, "symbols: unknown scope wat (expected local|builtin|shell|all)",
      )
  }
}

///|
test "shell vibe command prints readable help by default" {
  let lines : Array[String] = []
  let rt = new_cli_runtime(
    @runtime.RuntimeFeatureFlags::stable(),
    enable_llm=false,
  )
  let result = handle_repl_vibe_shell_command(
    rt,
    @runtime.ParserMode::VibeMode,
    "vibe",
    "/tmp/repl_vibe_help.db",
    "",
    fn(s) { lines.push(s) },
  )
  assert_eq(result, ReplMetaCommandResult::HandledContinue)
  let text = wbtest_join_lines(lines)
  assert_true(text.contains("vibe commands:"))
  assert_true(text.contains("symbols"))
}

///|
test "shell vibe command supports --json for help output" {
  let lines : Array[String] = []
  let rt = new_cli_runtime(
    @runtime.RuntimeFeatureFlags::stable(),
    enable_llm=false,
  )
  let result = handle_repl_vibe_shell_command(
    rt,
    @runtime.ParserMode::VibeMode,
    "vibe help --json",
    "/tmp/repl_vibe_help_json.db",
    "",
    fn(s) { lines.push(s) },
  )
  assert_eq(result, ReplMetaCommandResult::HandledContinue)
  assert_eq(lines.length(), 1)
  assert_true(lines[0].contains("\"command\":\"help\""))
  assert_true(lines[0].contains("\"ok\":true"))
}

///|
test "shell vibe bare command prints symbols in readable format" {
  let lines : Array[String] = []
  let rt = new_cli_runtime(
    @runtime.RuntimeFeatureFlags::stable(),
    enable_llm=false,
  )
  let result = handle_repl_vibe_shell_command(
    rt,
    @runtime.ParserMode::VibeMode,
    "symbols",
    "/tmp/repl_symbols_help.db",
    "let x = 1\n",
    fn(s) { lines.push(s) },
  )
  assert_eq(result, ReplMetaCommandResult::HandledContinue)
  let text = wbtest_join_lines(lines)
  assert_true(text.contains("local scope (1)"))
  assert_true(text.contains("| kind | name | signature | address |"))
  assert_true(text.contains("| value | x | Int |"))
  assert_false(text.contains("/tmp/repl_symbols_help.db"))
}

///|
test "shell vibe symbols supports scope flags for builtin and shell" {
  let lines : Array[String] = []
  let rt = new_cli_runtime(
    @runtime.RuntimeFeatureFlags::stable(),
    enable_llm=false,
  )
  let result = handle_repl_vibe_shell_command(
    rt,
    @runtime.ParserMode::VibeMode,
    "symbols --builtin --shell",
    "/tmp/repl_symbols_scope.db",
    "let x = 1\n",
    fn(s) { lines.push(s) },
  )
  assert_eq(result, ReplMetaCommandResult::HandledContinue)
  let text = wbtest_join_lines(lines)
  assert_true(text.contains("builtin scope ("))
  assert_true(text.contains("shell commands ("))
  assert_true(text.contains("| kind | name | signature | address |"))
  assert_true(text.contains("| vibe | vibe |"))
}

///|
test "shell vibe symbols supports --json output" {
  let lines : Array[String] = []
  let rt = new_cli_runtime(
    @runtime.RuntimeFeatureFlags::stable(),
    enable_llm=false,
  )
  let result = handle_repl_vibe_shell_command(
    rt,
    @runtime.ParserMode::VibeMode,
    "symbols --json",
    "/tmp/repl_symbols_json.db",
    "let x = 1\n",
    fn(s) { lines.push(s) },
  )
  assert_eq(result, ReplMetaCommandResult::HandledContinue)
  assert_eq(lines.length(), 1)
  assert_true(lines[0].contains("\"command\":\"symbols\""))
  assert_true(lines[0].contains("\"scopes\":[\"local\"]"))
  assert_true(lines[0].contains("\"address\":\""))
  assert_false(lines[0].contains("/tmp/repl_symbols_json.db"))
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
    @runtime.ParserMode::VibeMode,
    "vibe view inc |> Json::get(\"ok\")",
    "/tmp/repl_vibe_pipeline.db",
    source,
    fn(s) { lines.push(s) },
  )
  assert_eq(result, ReplMetaCommandResult::HandledContinue)
  let text = wbtest_join_lines(lines)
  assert_true(
    text.contains(
      "error: shell pipeline transforms were removed from compiled shell",
    ),
  )
}

///|
test "shell meta type prints symbol signature" {
  let lines : Array[String] = []
  let source = "let inc = (x: Int) -> Int { x + 1 }\n"
  let result = handle_repl_meta_command(
    ":type inc",
    "/tmp/repl_meta_type.db",
    source,
    fn(s) { lines.push(s) },
  )
  assert_eq(result, ReplMetaCommandResult::HandledContinue)
  let text = wbtest_join_lines(lines)
  assert_true(text.contains("inc : (x: Int) -> Int"))
}

///|
test "shell vibe type prints readable signature by default" {
  let lines : Array[String] = []
  let rt = new_cli_runtime(
    @runtime.RuntimeFeatureFlags::stable(),
    enable_llm=false,
  )
  let source = "let inc = (x: Int) -> Int { x + 1 }\n"
  let result = handle_repl_vibe_shell_command(
    rt,
    @runtime.ParserMode::VibeMode,
    "type inc",
    "/tmp/repl_vibe_type.db",
    source,
    fn(s) { lines.push(s) },
  )
  assert_eq(result, ReplMetaCommandResult::HandledContinue)
  let text = wbtest_join_lines(lines)
  assert_true(text.contains("inc : (x: Int) -> Int"))
}

///|
test "shell vibe type supports --json output" {
  let lines : Array[String] = []
  let rt = new_cli_runtime(
    @runtime.RuntimeFeatureFlags::stable(),
    enable_llm=false,
  )
  let source = "let inc = (x: Int) -> Int { x + 1 }\n"
  let result = handle_repl_vibe_shell_command(
    rt,
    @runtime.ParserMode::VibeMode,
    "type inc --json",
    "/tmp/repl_vibe_type_json.db",
    source,
    fn(s) { lines.push(s) },
  )
  assert_eq(result, ReplMetaCommandResult::HandledContinue)
  assert_eq(lines.length(), 1)
  assert_true(lines[0].contains("\"command\":\"type\""))
  assert_true(lines[0].contains("\"signature\":\"(x: Int) -> Int\""))
}

///|
test "shell vibe normalize accepts entry symbols and drops pure expr stmt" {
  let lines : Array[String] = []
  let rt = new_cli_runtime(
    @runtime.RuntimeFeatureFlags::stable(),
    enable_llm=false,
  )
  let source = "let f = (v: Int) { v * 2 }\n" +
    "f(3)\n" +
    "print(\"side\")\n" +
    "let x = 3\n" +
    "let y = f(x)\n"
  let result = handle_repl_vibe_shell_command(
    rt,
    @runtime.ParserMode::VibeMode,
    "normalize x y",
    "/tmp/repl_vibe_normalize_symbols.db",
    source,
    fn(s) { lines.push(s) },
  )
  assert_eq(result, ReplMetaCommandResult::HandledContinue)
  let text = wbtest_join_lines(lines)
  assert_true(text.contains("normalize: scratch"))
  assert_true(text.contains("let f: (Int) -> Int = (v) -> { v * 2 }"))
  assert_true(text.contains("let y: Int = f(x)"))
  assert_false(text.contains("f(3)"))
  assert_false(text.contains("print(\"side\")"))
  assert_true(text.contains("export { x, y }"))
}

///|
test "shell vibe normalize dedups duplicate lets with last wins" {
  let lines : Array[String] = []
  let rt = new_cli_runtime(
    @runtime.RuntimeFeatureFlags::stable(),
    enable_llm=false,
  )
  let source = "let x = 3\n" + "let x = 111\n" + "export { x }\n"
  let result = handle_repl_vibe_shell_command(
    rt,
    @runtime.ParserMode::VibeMode,
    "normalize x",
    "/tmp/repl_vibe_normalize_dedup_last_wins.db",
    source,
    fn(s) { lines.push(s) },
  )
  assert_eq(result, ReplMetaCommandResult::HandledContinue)
  let text = wbtest_join_lines(lines)
  assert_false(text.contains("let x: Int = 3"))
  assert_true(text.contains("let x: Int = 111"))
  assert_true(text.contains("export { x }"))
}

///|
test "shell warns when binding reserved vibe subcommand name" {
  let root = wbtest_make_temp_dir("repl_reserved_binding_warn")
  let scratch_db_path = root + "/scratch.db"
  let source_path = root + "/compiled_repl.vibe"
  let wasm_path = root + "/expr_0.wasm"
  let lines : Array[String] = []
  let rt = new_cli_runtime(
    @runtime.RuntimeFeatureFlags::stable(),
    enable_llm=false,
  )
  let cache = CliEntryDbCache::new()
  let _ = run_compiled_shell_line(
    cache,
    rt,
    @runtime.ParserMode::VibeMode,
    scratch_db_path,
    source_path,
    wasm_path,
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
  wbtest_remove_if_exists(wasm_path)
  wbtest_remove_if_exists(source_path)
  wbtest_remove_if_exists(scratch_db_path)
  wbtest_remove_if_exists(root)
}

///|
test "shell persist failure reports scratch-db context" {
  let root = wbtest_make_temp_dir("repl_persist_failure_reports_scratch_db")
  let scratch_db_path = root
  let source_path = root + "/compiled_repl.vibe"
  let wasm_path = root + "/expr_0.wasm"
  let lines : Array[String] = []
  let rt = new_cli_runtime(
    @runtime.RuntimeFeatureFlags::stable(),
    enable_llm=false,
  )
  let cache = CliEntryDbCache::new()
  let next_source = run_compiled_shell_line(
    cache,
    rt,
    @runtime.ParserMode::VibeMode,
    scratch_db_path,
    source_path,
    wasm_path,
    "",
    "let answer = 1",
    print_line=fn(s) { lines.push(s) },
  )
  assert_eq(next_source, "")
  let text = wbtest_join_lines(lines)
  assert_true(text.contains("error: failed to persist scratch-db:"))
  wbtest_remove_if_exists(wasm_path)
  wbtest_remove_if_exists(source_path)
  wbtest_remove_if_exists(root)
}

///|
test "compiled repl line preserves let bindings across lines" {
  let root = wbtest_make_temp_dir("compiled_repl_state")
  let source_path = root + "/compiled_repl.vibe"
  let wasm0 = root + "/expr_0.wasm"
  let wasm1 = root + "/expr_1.wasm"
  let cache = CliEntryDbCache::new()
  let first = match
    run_compiled_repl_line_with_cache(
      cache, source_path, wasm0, "", "let x = 40",
    ) {
    Ok(v) => v
    Err(err) => fail("first compiled repl line failed: " + err)
  }
  assert_eq(first.value, WasmRunValue::Int(40L))
  assert_true(@os_fs.path_exists(wasm0))
  let second = match
    run_compiled_repl_line_with_cache(
      cache,
      source_path,
      wasm1,
      first.next_source,
      "x + 2",
    ) {
    Ok(v) => v
    Err(err) => fail("second compiled repl line failed: " + err)
  }
  assert_eq(second.value, WasmRunValue::Int(42L))
  assert_true(@os_fs.path_exists(wasm1))
  assert_true(second.total_us > 0)
  wbtest_remove_if_exists(wasm0)
  wbtest_remove_if_exists(wasm1)
  wbtest_remove_if_exists(source_path)
  wbtest_remove_if_exists(root)
}

///|
test "compiled repl line decodes bool result" {
  let root = wbtest_make_temp_dir("compiled_repl_bool")
  let source_path = root + "/compiled_repl.vibe"
  let wasm_path = root + "/expr_0.wasm"
  let cache = CliEntryDbCache::new()
  let result = match
    run_compiled_repl_line_with_cache(
      cache, source_path, wasm_path, "", "1 < 2",
    ) {
    Ok(v) => v
    Err(err) => fail("compiled repl bool line failed: " + err)
  }
  assert_eq(result.value, WasmRunValue::Bool(true))
  assert_true(@os_fs.path_exists(wasm_path))
  wbtest_remove_if_exists(wasm_path)
  wbtest_remove_if_exists(source_path)
  wbtest_remove_if_exists(root)
}

///|
test "compiled repl line preserves function bindings across lines" {
  let root = wbtest_make_temp_dir("compiled_repl_fn_binding")
  let source_path = root + "/compiled_repl.vibe"
  let wasm0 = root + "/expr_0.wasm"
  let wasm1 = root + "/expr_1.wasm"
  let wasm2 = root + "/expr_2.wasm"
  let cache = CliEntryDbCache::new()
  let seed = match
    run_compiled_repl_line_with_cache(
      cache, source_path, wasm0, "", "let x = 40",
    ) {
    Ok(v) => v
    Err(err) => fail("seed compiled repl line failed: " + err)
  }
  let fn_binding = match
    run_compiled_repl_line_with_cache(
      cache,
      source_path,
      wasm1,
      seed.next_source,
      "let add_x = (n: Int) -> Int { n + x }",
    ) {
    Ok(v) => v
    Err(err) => fail("function binding line failed: " + err)
  }
  assert_eq(fn_binding.value, WasmRunValue::Int(0L))
  assert_eq(fn_binding.display_override, Some("<fn add_x>"))
  let result = match
    run_compiled_repl_line_with_cache(
      cache,
      source_path,
      wasm2,
      fn_binding.next_source,
      "add_x(2)",
    ) {
    Ok(v) => v
    Err(err) => fail("function call line failed: " + err)
  }
  assert_eq(result.value, WasmRunValue::Int(42L))
  wbtest_remove_if_exists(wasm0)
  wbtest_remove_if_exists(wasm1)
  wbtest_remove_if_exists(wasm2)
  wbtest_remove_if_exists(source_path)
  wbtest_remove_if_exists(root)
}

///|
test "compiled repl line preserves function alias bindings across lines" {
  let root = wbtest_make_temp_dir("compiled_repl_fn_alias")
  let helper_path = root + "/helper.vibe"
  let source_path = root + "/compiled_repl.vibe"
  let wasm0 = root + "/expr_0.wasm"
  let wasm1 = root + "/expr_1.wasm"
  let wasm2 = root + "/expr_2.wasm"
  @os_fs.write_string_to_file(
    helper_path, "let inc = (x: Int) -> Int { x + 1 }\nexport { inc }\n",
  ) catch {
    e => fail("write helper failed: " + e.to_string())
  }
  let cache = CliEntryDbCache::new()
  let imported = match
    run_compiled_repl_line_with_cache(
      cache, source_path, wasm0, "", "import ./helper.vibe { inc }",
    ) {
    Ok(v) => v
    Err(err) => fail("import line failed: " + err)
  }
  let alias_binding = match
    run_compiled_repl_line_with_cache(
      cache,
      source_path,
      wasm1,
      imported.next_source,
      "let alias = inc",
    ) {
    Ok(v) => v
    Err(err) => fail("alias binding line failed: " + err)
  }
  assert_eq(alias_binding.value, WasmRunValue::Int(0L))
  assert_eq(alias_binding.display_override, Some("<bound alias>"))
  let result = match
    run_compiled_repl_line_with_cache(
      cache,
      source_path,
      wasm2,
      alias_binding.next_source,
      "alias(41)",
    ) {
    Ok(v) => v
    Err(err) => fail("alias call line failed: " + err)
  }
  assert_eq(result.value, WasmRunValue::Int(42L))
  wbtest_remove_if_exists(wasm0)
  wbtest_remove_if_exists(wasm1)
  wbtest_remove_if_exists(wasm2)
  wbtest_remove_if_exists(helper_path)
  wbtest_remove_if_exists(source_path)
  wbtest_remove_if_exists(root)
}

///|
test "compiled repl line renders string literal" {
  let root = wbtest_make_temp_dir("compiled_repl_string_literal")
  let source_path = root + "/compiled_repl.vibe"
  let wasm_path = root + "/expr_0.wasm"
  let cache = CliEntryDbCache::new()
  let result = match
    run_compiled_repl_line_with_cache(
      cache, source_path, wasm_path, "", "\"hi\"",
    ) {
    Ok(v) => v
    Err(err) => fail("compiled repl string literal failed: " + err)
  }
  assert_eq(result.value, WasmRunValue::Int(0L))
  assert_eq(result.display_override, Some("\"hi\""))
  wbtest_remove_if_exists(wasm_path)
  wbtest_remove_if_exists(source_path)
  wbtest_remove_if_exists(root)
}

///|
test "compiled repl line renders string let binding and reuse" {
  let root = wbtest_make_temp_dir("compiled_repl_string_binding")
  let source_path = root + "/compiled_repl.vibe"
  let wasm0 = root + "/expr_0.wasm"
  let wasm1 = root + "/expr_1.wasm"
  let cache = CliEntryDbCache::new()
  let bound = match
    run_compiled_repl_line_with_cache(
      cache, source_path, wasm0, "", "let s = \"hi\"",
    ) {
    Ok(v) => v
    Err(err) => fail("compiled repl string binding failed: " + err)
  }
  assert_eq(bound.value, WasmRunValue::Int(0L))
  assert_eq(bound.display_override, Some("\"hi\""))
  let reused = match
    run_compiled_repl_line_with_cache(
      cache,
      source_path,
      wasm1,
      bound.next_source,
      "s",
    ) {
    Ok(v) => v
    Err(err) => fail("compiled repl string reuse failed: " + err)
  }
  assert_eq(reused.value, WasmRunValue::Int(0L))
  assert_eq(reused.display_override, Some("\"hi\""))
  wbtest_remove_if_exists(wasm0)
  wbtest_remove_if_exists(wasm1)
  wbtest_remove_if_exists(source_path)
  wbtest_remove_if_exists(root)
}

///|
// Test removed: `do` keyword was removed from the language.
// The hint mechanism for `do { ... }` in posix mode is no longer needed.

///|
test "append scratch db source formats persisted script" {
  let saved1 = append_scratch_db_source("", "let f = (v: Int) { v * 2 }")
  assert_true(saved1.contains("let f = (v: Int) {"))
  assert_true(saved1.contains("  v * 2"))
  assert_true(saved1.has_suffix("\n"))
  let saved2 = append_scratch_db_source(saved1, "let x=1")
  assert_true(saved2.contains("let x = 1"))
  assert_true(saved2.has_suffix("\n"))
  let _ = @parser.parse_ast(saved2) catch {
    e => fail("saved source parse failed: " + e.to_string())
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
test "cli normalize directory reports migration error for legacy use syntax" {
  let root = wbtest_make_temp_dir("normalize_dir_legacy_use_syntax")
  @os_fs.write_string_to_file(
    root + "/main.vibe",
    "use ./dep.vibe { value }\nlet run = value\n",
  ) catch {
    e => fail("write main.vibe failed: " + e.to_string())
  }
  match normalize_directory_to_index_source(root, false) {
    Ok(_) => fail("expected migration error for legacy use syntax")
    Err(err) => {
      assert_true(err.contains("`import <module-ref> { ... }`"))
      assert_true(err.contains("`use` is removed"))
    }
  }
  wbtest_remove_if_exists(root)
}

///|
test "cli normalize directory reports migration error for legacy declare syntax" {
  let root = wbtest_make_temp_dir("normalize_dir_legacy_declare_syntax")
  @os_fs.write_string_to_file(
    root + "/main.vibe",
    "declare export let run: () -> Int\n",
  ) catch {
    e => fail("write main.vibe failed: " + e.to_string())
  }
  match normalize_directory_to_index_source(root, false) {
    Ok(_) => fail("expected migration error for legacy declare syntax")
    Err(err) => {
      assert_true(err.contains("`extern let %name: Type`"))
      assert_true(err.contains("`declare` is removed"))
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
  @os_fs.write_string_to_file(lib_demo + "/pkg@0.1.0.lock", "hash:a\n") catch {
    e => fail("write pkg@0.1.0 alias failed: " + e.to_string())
  }
  @os_fs.write_string_to_file(lib_demo + "/pkg@0.2.0.lock", "hash:b\n") catch {
    e => fail("write pkg@0.2.0 alias failed: " + e.to_string())
  }
  @os_fs.write_string_to_file(
    root + "/index.vibe",
    "import demo/pkg { root_value }\nlet root_value = 1\nexport { root_value }\n",
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
test "cli normalize import resolver ignores removed use syntax" {
  let root = wbtest_make_temp_dir("normalize_dir_removed_use_syntax")
  let lib_root = root + "/lib"
  let lib_demo = lib_root + "/demo"
  @os_fs.create_dir(lib_root) catch {
    e => fail("create lib root failed: " + e.to_string())
  }
  @os_fs.create_dir(lib_demo) catch {
    e => fail("create demo lib dir failed: " + e.to_string())
  }
  @os_fs.write_string_to_file(lib_demo + "/pkg@0.1.0.lock", "hash:a\n") catch {
    e => fail("write pkg@0.1.0 alias failed: " + e.to_string())
  }
  @os_fs.write_string_to_file(lib_demo + "/pkg@0.2.0.lock", "hash:b\n") catch {
    e => fail("write pkg@0.2.0 alias failed: " + e.to_string())
  }
  let line = "use demo/pkg { value }"
  let resolved = match normalize_resolve_index_import_line(line, lib_root) {
    Ok(v) => v
    Err(err) => fail("unexpected normalize error: " + err)
  }
  assert_eq(resolved, line)
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
  @os_fs.write_string_to_file(lib_demo + "/pkg@0.1.0.lock", "hash:a\n") catch {
    e => fail("write pkg@0.1.0 alias failed: " + e.to_string())
  }
  @os_fs.write_string_to_file(lib_demo + "/pkg@0.2.0.lock", "hash:b\n") catch {
    e => fail("write pkg@0.2.0 alias failed: " + e.to_string())
  }
  @os_fs.write_string_to_file(
    root + "/a.vibe",
    "import demo/pkg { a_value }\nlet a_value = 1\nexport { a_value }\n",
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
  match parse_bench_backend("compiled") {
    Some(backend) => assert_eq(backend, BenchBackend::Wasm)
    None => fail("expected compiled backend")
  }
  match parse_bench_backend("wasm") {
    Some(backend) => assert_eq(backend, BenchBackend::Wasm)
    None => fail("expected wasm backend")
  }
  match parse_bench_backend("interpreter") {
    Some(_) => fail("unexpected legacy interpreter backend")
    None => ()
  }
  match parse_bench_backend("interp") {
    Some(_) => fail("unexpected legacy interpreter backend alias")
    None => ()
  }
  match parse_bench_backend("unknown") {
    Some(_) => fail("unexpected backend")
    None => ()
  }
}

///|
test "bench script cache paths are stable per source" {
  let paths1 = bench_script_cache_paths(
    "/tmp/project/src/main_bench.vibe", "run_1", "let value = 1\n",
  )
  let paths2 = bench_script_cache_paths(
    "/tmp/project/src/main_bench.vibe", "run_1", "let value = 1\n",
  )
  let paths3 = bench_script_cache_paths(
    "/tmp/project/src/main_bench.vibe", "run_1", "let value = 2\n",
  )
  assert_true(paths1.0.contains("/.vibe/bench/"))
  assert_true(paths1.1.contains("/src/.vibe_bench_run_1_"))
  assert_eq(paths1.1, paths2.1)
  assert_eq(paths1.2, paths2.2)
  assert_true(paths1.2.has_suffix(".wasm"))
  assert_true(paths1.1 != paths3.1)
}

///|
test "cli bench keeps relative imports from the entry directory" {
  let root = wbtest_make_temp_dir("bench_relative_import")
  let helper_path = root + "/helper.vibe"
  let entry_path = root + "/main_bench.vibe"
  @os_fs.write_string_to_file(helper_path, "export let inc = () -> Int { 1 }\n") catch {
    e => fail("write helper failed: " + e.to_string())
  }
  @os_fs.write_string_to_file(
    entry_path, "import ./helper.vibe { inc }\nbench \"relative_import\" {\n  let _ = inc()\n}\n",
  ) catch {
    e => fail("write bench entry failed: " + e.to_string())
  }
  match run_bench_blocks_wasm_entry(entry_path, 1, 0) {
    Ok(report) => {
      assert_eq(report.total, 1)
      assert_eq(report.passed, 1)
      assert_eq(report.failed, 0)
    }
    Err(err) => fail("bench run failed: " + err)
  }
  wbtest_remove_if_exists(root + "/.vibe")
  wbtest_remove_if_exists(entry_path)
  wbtest_remove_if_exists(helper_path)
  wbtest_remove_if_exists(root)
}

///|
test "cli bench supports imported fallback builtins via host runner" {
  let root = wbtest_make_temp_dir("bench_imported_fallback")
  let helper_path = root + "/helper.vibe"
  let entry_path = root + "/main_bench.vibe"
  @os_fs.write_string_to_file(
    helper_path,
    "export let parse_name_len = () -> Int {\n" +
    "  let data = Json::parse(\"{\\\"name\\\":\\\"vibe\\\"}\")\n" +
    "  String::length(Json::string(Json::get(data, \"name\")))\n" +
    "}\n",
  ) catch {
    e => fail("write helper failed: " + e.to_string())
  }
  @os_fs.write_string_to_file(
    entry_path,
    "import ./helper.vibe { parse_name_len }\n" +
    "bench \"imported_fallback\" {\n" +
    "  let _ = parse_name_len()\n" +
    "}\n",
  ) catch {
    e => fail("write bench entry failed: " + e.to_string())
  }
  match
    run_bench_blocks_wasm_entry_with_cases(entry_path, 1, 0, [
      "imported_fallback",
    ]) {
    Ok(report) =>
      if report.total != 1 || report.passed != 1 || report.failed != 0 {
        fail("unexpected bench report: " + Debug::to_repr(report).to_string())
      }
    Err(err) => fail("bench run failed: " + err)
  }
  wbtest_remove_if_exists(root + "/.vibe")
  wbtest_remove_if_exists(entry_path)
  wbtest_remove_if_exists(helper_path)
  wbtest_remove_if_exists(root)
}

///|
test "cli bench can filter cases by name" {
  let root = wbtest_make_temp_dir("bench_case_filter")
  let entry_path = root + "/main_bench.vibe"
  @os_fs.write_string_to_file(
    entry_path, "bench \"alpha\" {\n  let _ = 1\n}\nbench \"beta\" {\n  let _ = 2\n}\n",
  ) catch {
    e => fail("write bench entry failed: " + e.to_string())
  }
  match run_bench_blocks_wasm_entry_with_cases(entry_path, 1, 0, ["beta"]) {
    Ok(report) => {
      assert_eq(report.total, 1)
      assert_eq(report.passed, 1)
      assert_eq(report.failed, 0)
      assert_eq(report.results.length(), 1)
      assert_eq(report.results[0].name, Some("beta"))
    }
    Err(err) => fail("bench run failed: " + err)
  }
  match run_bench_blocks_wasm_entry_with_cases(entry_path, 1, 0, ["missing"]) {
    Ok(_) => fail("expected case filter miss to fail")
    Err(err) => assert_true(err.contains("no cases matched --case"))
  }
  wbtest_remove_if_exists(root + "/.vibe")
  wbtest_remove_if_exists(entry_path)
  wbtest_remove_if_exists(root)
}

///|
test "cli bench extracts bench_setup from shared prelude" {
  let source = "let shared = [0]\n" +
    "let bench_setup = () -> Int {\n  shared[0] = 42\n  0\n}\n" +
    "bench \"setup\" {\n  let _ = shared[0]\n}\n"
  match extract_bench_source_plan(source) {
    Ok(plan) => {
      assert_true(plan.shared_prelude_source.contains("let shared = [0]"))
      assert_true(plan.setup_source.contains("let bench_setup = () -> Int"))
      assert_eq(plan.local_prelude_source, "")
      assert_eq(plan.cases.length(), 1)
    }
    Err(err) => fail("extract bench source plan failed: " + err)
  }
}

///|
test "cli bench runs bench_setup before measured case" {
  let root = wbtest_make_temp_dir("bench_setup_hook")
  let entry_path = root + "/main_bench.vibe"
  @os_fs.write_string_to_file(
    entry_path,
    "let shared = [0]\n" +
    "let bench_setup = () -> Int {\n" +
    "  shared[0] = 42\n" +
    "  0\n" +
    "}\n" +
    "bench \"setup\" {\n" +
    "  let _ = if shared[0] == 42 { 0 } else { throw(\"setup missing\") }\n" +
    "}\n",
  ) catch {
    e => fail("write bench entry failed: " + e.to_string())
  }
  match run_bench_blocks_wasm_entry_with_cases(entry_path, 1, 0, ["setup"]) {
    Ok(report) => {
      assert_eq(report.total, 1)
      assert_eq(report.passed, 1)
      assert_eq(report.failed, 0)
    }
    Err(err) => fail("bench run failed: " + err)
  }
  wbtest_remove_if_exists(root + "/.vibe")
  wbtest_remove_if_exists(entry_path)
  wbtest_remove_if_exists(root)
}

///|
test "cli bench uses expr mode only for removed legacy flags" {
  assert_false(
    bench_uses_expr_mode(["--backend", "wasm", "examples/simple_bench.vibe"]),
  )
  assert_false(
    bench_uses_expr_mode(["--case", "add_one", "examples/simple_bench.vibe"]),
  )
  assert_false(bench_uses_expr_mode(["--json", "examples/simple_bench.vibe"]))
  assert_true(bench_uses_expr_mode(["--expr", "add(1,2)"]))
}

///|
test "cli bench parses json output options" {
  match
    parse_bench_cmd_args([
      "--json", "--json-out", "/tmp/vibe-bench.json", "--runs", "5", "--warmup",
      "1", "--case", "beta", "--backend", "wasm", "examples/simple_bench.vibe",
    ]) {
    Ok(opts) => {
      assert_true(opts.output_json)
      assert_eq(opts.json_out_path, Some("/tmp/vibe-bench.json"))
      assert_eq(opts.runs, 5)
      assert_eq(opts.warmup, 1)
      assert_eq(opts.case_filters, ["beta"])
      assert_eq(opts.backend, BenchBackend::Wasm)
      assert_eq(opts.paths, ["examples/simple_bench.vibe"])
    }
    Err(err) => fail("parse bench args failed: " + err)
  }
}

///|
test "cli bench json report encodes statistical summaries" {
  let summary = @runtime.compute_bench_summary(
    Some("alpha"),
    [10.0, 12.0, 11.0, 14.0, 13.0],
    3,
    1234,
  )
  let file_json = make_wasm_bench_summary_report_json(
    "examples/simple_bench.vibe",
    WasmBenchSummaryReport::{
      total: 1,
      passed: 1,
      failed: 0,
      results: [summary],
      failures: [],
    },
  )
  let root_json = make_cli_bench_report_json(
    "statistical",
    1,
    0,
    1,
    1,
    0,
    true,
    [file_json],
  )
  let text = root_json.stringify()
  assert_true(text.contains("\"cmd\":\"bench\""))
  assert_true(text.contains("\"mode\":\"statistical\""))
  assert_true(text.contains("\"file\":\"examples/simple_bench.vibe\""))
  assert_true(text.contains("\"name\":\"alpha\""))
  assert_true(text.contains("\"median\":"))
  assert_true(text.contains("\"runs\":5"))
  assert_true(text.contains("\"files_failed\":0"))
}

///|
test "cli bench json report encodes legacy run results" {
  let file_json = make_wasm_bench_report_json("examples/simple_bench.vibe", WasmBenchReport::{
    total: 1,
    passed: 1,
    failed: 0,
    results: [
      WasmBenchResult::{
        name: Some("beta"),
        iterations: 10,
        warmup: 2,
        elapsed_ms: 12.5,
        per_us: 1250.0,
        wasm_bytes: 321,
      },
    ],
    failures: [],
  })
  let text = file_json.stringify()
  assert_true(text.contains("\"mode\":\"legacy\""))
  assert_true(text.contains("\"name\":\"beta\""))
  assert_true(text.contains("\"iterations\":10"))
  assert_true(text.contains("\"per_us\":1250"))
}

///|
test "cli bench writes json report to file when requested" {
  let out_path = "/tmp/vibe_bench_json_out/report.json"
  wbtest_remove_if_exists(out_path)
  wbtest_remove_if_exists("/tmp/vibe_bench_json_out")
  match write_cli_bench_report_json(Some(out_path), "{\"ok\":true}") {
    Ok(_) => ()
    Err(err) => fail("write_cli_bench_report_json failed: " + err)
  }
  let saved = @os_fs.read_file_to_string(out_path) catch {
    e => fail("read json out failed: " + e.to_string())
  }
  assert_eq(saved, "{\"ok\":true}")
  wbtest_remove_if_exists(out_path)
  wbtest_remove_if_exists("/tmp/vibe_bench_json_out")
}

///|
test "cli wasm bench compile uses size-oriented optimize level" {
  let root = wbtest_make_temp_dir("bench_wasm_size_opt")
  let entry_path = root + "/case.vibe"
  let source =
    #|let rec repeat = (s: String, n: Int) -> String {
    #|  if eq(n, 0) { "" } else { String::concat(s, repeat(s, sub(n, 1))) }
    #|}
    #|let base = "abcdefghijklmnopqrstuvwxyz"
    #|let s = repeat(base, 12)
    #|String::length(s)
  let (_, source_path, wasm_path) = bench_script_cache_paths(
    entry_path, "size_opt", source,
  )
  let (_, optimized_size, _) = match
    compile_bench_script_to_wasm(entry_path, "size_opt", source) {
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
test "cli bench compile enables host runner for fallback builtins" {
  let root = wbtest_make_temp_dir("bench_host_runner")
  let entry_path = root + "/case.vibe"
  let source =
    #|let data = Json::parse("{\"name\":\"vibe\"}")
    #|String::length(Json::string(Json::get(data, "name")))
  let (wasm_path, _, use_node_runner) = match
    compile_bench_script_to_wasm(entry_path, "host_runner", source) {
    Ok(result) => result
    Err(err) => fail("compile bench wasm failed: " + err)
  }
  assert_true(use_node_runner)
  wbtest_remove_if_exists(wasm_path)
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
test "cli index build writes cache.json graph head" {
  let root = wbtest_make_temp_dir("index_build_cache")
  let entry = root + "/main.vibe"
  let out_path = root + "/advanced-graph-index.json"
  @os_fs.write_string_to_file(entry, "let value = 1\nexport { value }\n") catch {
    e => fail("write entry failed: " + e.to_string())
  }
  index_build_cmd(["-o", out_path, entry])
  assert_true(@os_fs.path_exists(out_path))
  let cache_path = find_vibe_dir(entry) + "/cache.json"
  assert_true(@os_fs.path_exists(cache_path))
  let cache_source = @os_fs.read_file_to_string(cache_path) catch {
    e => fail("read cache.json failed: " + e.to_string())
  }
  let cache_json : Json = @json.parse(cache_source) catch {
    e => fail("parse cache.json failed: " + e.to_string())
  }
  let graph_head = match cache_json {
    Json::Object(obj) =>
      match obj.get("graph_head") {
        Some(Json::String(hash)) => hash
        _ => fail("cache.json must include graph_head")
      }
    _ => fail("cache.json must be object")
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
  let entry_source = "import ./lib.vibe {  inc  }\nlet main = inc(1)\nexport { main }\n"
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
  let cache_path = find_vibe_dir(entry) + "/cache.json"
  assert_true(@os_fs.path_exists(cache_path))
  let cache_source = @os_fs.read_file_to_string(cache_path) catch {
    e => fail("read cache.json failed: " + e.to_string())
  }
  let cache_json : Json = @json.parse(cache_source) catch {
    e => fail("parse cache.json failed: " + e.to_string())
  }
  let graph_head = match cache_json {
    Json::Object(obj) =>
      match obj.get("graph_head") {
        Some(Json::String(hash)) => hash
        _ => fail("cache.json must include graph_head")
      }
    _ => fail("cache.json must be object")
  }
  let codebase = @codebase.Codebase::new(find_vibe_dir(entry))
  match codebase.read_object(graph_head) {
    Some(content) => assert_true(content.contains("\"defs\""))
    None => fail("expected graph snapshot object")
  }
  wbtest_remove_if_exists(root)
}

///|
test "cli check cache refresh keeps renamed same-content module paths out of graph snapshot" {
  let root = wbtest_make_temp_dir("check_refresh_renamed_module_paths")
  let cache_dir = root + "/cache"
  let old_dep_dir = cache_dir + "/persistent"
  let old_dep = old_dep_dir + "/index.vibe"
  let new_dep = cache_dir + "/persistent_cache.vibe"
  let entry = root + "/main.vibe"
  let dep_source = "let value = 1\nexport { value }\n"
  let old_entry_source = "import ./cache/persistent { value }\n" +
    "let main = value\n" +
    "export { main }\n"
  let new_entry_source = "import ./cache/persistent_cache.vibe { value }\n" +
    "let main = value\n" +
    "export { main }\n"
  @os_fs.create_dir(cache_dir) catch {
    e => fail("create cache dir failed: " + e.to_string())
  }
  @os_fs.create_dir(old_dep_dir) catch {
    e => fail("create old dep dir failed: " + e.to_string())
  }
  @os_fs.write_string_to_file(old_dep, dep_source) catch {
    e => fail("write old dep failed: " + e.to_string())
  }
  @os_fs.write_string_to_file(entry, old_entry_source) catch {
    e => fail("write old entry failed: " + e.to_string())
  }
  let cache = CliEntryDbCache::new()
  let (codebase, first_graph_head) = match
    resolve_entry_artifacts_with_cache(cache, entry, skip_types=true) {
    Ok((_db, _entry, _lock, _index, graph_head)) =>
      (@codebase.Codebase::new(find_vibe_dir(entry)), graph_head)
    Err(err) => fail("first resolve failed: " + err)
  }
  let first_graph_source = match codebase.read_object(first_graph_head) {
    Some(content) => content
    None => fail("expected first graph snapshot object")
  }
  assert_true(first_graph_source.contains(old_dep))
  wbtest_remove_if_exists(old_dep)
  @os_fs.write_string_to_file(new_dep, dep_source) catch {
    e => fail("write new dep failed: " + e.to_string())
  }
  @os_fs.write_string_to_file(entry, new_entry_source) catch {
    e => fail("write new entry failed: " + e.to_string())
  }
  let (_db2, _entry2, _lock2, _index2, second_graph_head) = match
    resolve_entry_artifacts_with_cache(cache, entry, skip_types=true) {
    Ok(v) => v
    Err(err) => fail("second resolve failed: " + err)
  }
  let second_graph_source = match codebase.read_object(second_graph_head) {
    Some(content) => content
    None => fail("expected second graph snapshot object")
  }
  assert_false(second_graph_head == first_graph_head)
  assert_true(second_graph_source.contains(new_dep))
  assert_false(second_graph_source.contains(old_dep))
  wbtest_remove_if_exists(root)
}

///|
test "cli resolve entry artifacts: repo compiler index entry" {
  let cwd = @io.current_dir_or_root()
  let entry = @vibe_fs.normalize_path(cwd + "/vibe/compiler/index.vibe")
  let cache = CliEntryDbCache::new()
  match resolve_entry_artifacts_with_cache(cache, entry, skip_types=true) {
    Ok((db, resolved, _lock, _index, graph_head)) => {
      assert_eq(resolved, entry)
      assert_eq(graph_head.length(), 40)
      let _ = db.types(entry)
    }
    Err(err) => fail(err)
  }
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
  let cache_path = find_vibe_dir(entry) + "/cache.json"
  assert_true(@os_fs.path_exists(cache_path))
  let cache_source = @os_fs.read_file_to_string(cache_path) catch {
    e => fail("read cache.json failed: " + e.to_string())
  }
  let cache_json : Json = @json.parse(cache_source) catch {
    e => fail("parse cache.json failed: " + e.to_string())
  }
  let graph_head = match cache_json {
    Json::Object(obj) =>
      match obj.get("graph_head") {
        Some(Json::String(hash)) => hash
        _ => fail("cache.json must include graph_head")
      }
    _ => fail("cache.json must be object")
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
test "cli history reset clears scratch db" {
  let root = wbtest_make_temp_dir("history_reset_scratch")
  let scratch_db = root + "/scratch.db"
  let prev = @sys.get_env_var("VIBE_SCRATCH_DB_PATH")
  @sys.set_env_var("VIBE_SCRATCH_DB_PATH", scratch_db)
  match write_scratch_db_source(scratch_db, "let v = 1\n") {
    Ok(_) => ()
    Err(err) => fail("write scratch db failed: " + err)
  }
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
    entry, "import ./lib.vibe {  inc  }\nlet main = inc(1)\nexport { main }\n",
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
  match write_scratch_db_source(scratch_db, "let foo = 1\n") {
    Ok(_) => ()
    Err(err) => fail("write scratch db failed: " + err)
  }
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
  match write_scratch_db_source(scratch_db, "let foo = 1\n") {
    Ok(_) => ()
    Err(err) => fail("write scratch db failed: " + err)
  }
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
test "cli finalize library mode prunes scratch db toward exports" {
  let root = wbtest_make_temp_dir("finalize_library_mode")
  let db_path = root + "/tmp1.db"
  let source = "let helper = (x: Int) -> Int { x + 1 }\n" +
    "let unused = 100\n" +
    "let answer = helper(41)\n" +
    "helper(0)\n" +
    "test \"answer\" { assert(answer == 42) }\n" +
    "export { answer }\n"
  match write_scratch_db_source(db_path, source) {
    Ok(_) => ()
    Err(err) => fail("write seed db failed: " + err)
  }
  finalize_cmd(["--db=" + db_path, "--library"])
  let finalized = @os_fs.read_file_to_string(db_path) catch {
    e => fail("read finalized db failed: " + e.to_string())
  }
  assert_true(finalized.contains("let helper"))
  assert_true(finalized.contains("helper(41)"))
  assert_true(finalized.contains("export"))
  assert_true(finalized.contains("answer"))
  assert_false(finalized.contains("let unused = 100"))
  assert_false(finalized.contains("helper(0)"))
  assert_false(finalized.contains("test \"answer\""))
  let expected = match normalize_format_source_text(finalized) {
    Ok(v) => v
    Err(err) => fail("normalize finalized library source failed: " + err)
  }
  assert_eq(finalized, expected)
  let db = @runtime.VibeDb::new()
  db.set_source(db_path, finalized)
  let _ = db.types(db_path)
  wbtest_remove_if_exists(db_path)
  wbtest_remove_if_exists(root)
}

///|
test "cli finalize safe mode drops pure expressions after normalization" {
  let root = wbtest_make_temp_dir("finalize_safe_mode")
  let db_path = root + "/tmp1.db"
  let source = "let helper = (x: Int) -> Int { x + 1 }\n" +
    "let answer = helper(41)\n" +
    "helper(0)\n" +
    "test \"answer\" { assert(answer == 42) }\n" +
    "export { answer }\n"
  match write_scratch_db_source(db_path, source) {
    Ok(_) => ()
    Err(err) => fail("write seed db failed: " + err)
  }
  finalize_cmd(["--db=" + db_path])
  let finalized = @os_fs.read_file_to_string(db_path) catch {
    e => fail("read finalized db failed: " + e.to_string())
  }
  assert_true(finalized.contains("let helper"))
  assert_true(finalized.contains("helper(41)"))
  assert_false(finalized.contains("helper(0)"))
  assert_false(finalized.contains("test \"answer\""))
  let expected = match normalize_format_source_text(finalized) {
    Ok(v) => v
    Err(err) => fail("normalize finalized safe source failed: " + err)
  }
  assert_eq(finalized, expected)
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
  match write_scratch_db_source(db_path, source) {
    Ok(_) => ()
    Err(err) => fail("write seed db failed: " + err)
  }
  finalize_cmd(["--db=" + db_path, "--library", "--export=" + out_path])
  let exported = @os_fs.read_file_to_string(out_path) catch {
    e => fail("read exported module failed: " + e.to_string())
  }
  assert_true(exported.contains("let helper"))
  assert_true(exported.contains("helper(41)"))
  assert_true(exported.contains("export"))
  assert_true(exported.contains("answer"))
  assert_false(exported.contains("helper(0)"))
  let expected = match normalize_format_source_text(exported) {
    Ok(v) => v
    Err(err) => fail("normalize exported finalize source failed: " + err)
  }
  assert_eq(exported, expected)
  fetch_cmd([out_path])
  let lock_path = @codebase.lock_file_path(out_path)
  let lock = match @codebase.load_lock_data(lock_path) {
    Ok(v) => v
    Err(err) => fail("load lock failed: " + err)
  }
  let fetched_source = @os_fs.read_file_to_string(out_path) catch {
    e => fail("read fetched module failed: " + e.to_string())
  }
  assert_true(fetched_source.length() > 0)
  let resolved = @loader.resolve_entry_path(out_path)
  match lock.path_refs.get(resolved) {
    Some(hash) => assert_true(hash.length() == 40)
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
  let source = "let local = 1\n" + "local\n" + "export ./mod.vibe { helper }\n"
  match write_scratch_db_source(db_path, source) {
    Ok(_) => ()
    Err(err) => fail("write seed db failed: " + err)
  }
  finalize_cmd(["--db=" + db_path, "--library"])
  let finalized = @os_fs.read_file_to_string(db_path) catch {
    e => fail("read finalized db failed: " + e.to_string())
  }
  assert_true(finalized.contains("export ./mod.vibe"))
  assert_true(finalized.contains("helper"))
  assert_false(finalized.contains("let local = 1"))
  let ast = @parser.parse_ast(finalized) catch {
    e => fail("finalized parse failed: " + e.to_string())
  }
  let mut has_reexport = false
  for stmt in ast.stmts {
    match stmt {
      @vibe_core.Stmt::ReExport(spec~, source~, ..) =>
        if spec.items.length() == 1 &&
          spec.items[0].name == "helper" &&
          spec.items[0].rename is None {
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
struct FunctionTrackingRecord {
  version : String
  renamed_from : String?
}

///|
fn read_function_tracking_record(
  index_root : String,
  key : String,
) -> FunctionTrackingRecord {
  let vibe_dir = find_vibe_dir(index_root + "/index.vibe")
  let path = vibe_dir + "/cache.json"
  let source = @os_fs.read_file_to_string(path) catch {
    e => abort("read cache.json failed: " + e.to_string())
  }
  let json : Json = @json.parse(source) catch {
    e => abort("parse cache.json failed: " + e.to_string())
  }
  let obj = match json {
    Json::Object(map) => map
    _ => abort("cache.json must be object")
  }
  let tracking = match obj.get("function_tracking") {
    Some(Json::Object(value)) => value
    _ => abort("cache.json must include function_tracking object")
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
      if value.trim().to_owned().length() == 0 {
        None
      } else {
        Some(value)
      }
    _ => None
  }
  FunctionTrackingRecord::{ version, renamed_from }
}

///|
test "selfhost compiler source files parse successfully" {
  let compiler_dir = "vibe/compiler"
  let files = [
    "token.vibe", "ast.vibe", "lexer.vibe", "parser.vibe", "printer.vibe", "index.vibe",
    "types.vibe", "builtins.vibe", "checker.vibe", "checker_resolve.vibe", "checker_stmt.vibe",
    "_test_minimal.vibe", "_test_for_simple.vibe", "_test_for_tuple.vibe", "_test_for_tuple2.vibe",
    "_test_manual_while.vibe", "_test_while_no_destr.vibe", "_test_all_arms.vibe",
    "_test_two_fn.vibe", "_test_multi_fn.vibe", "_test_expr_with_pat_call.vibe",
  ]
  for file in files {
    let path = compiler_dir + "/" + file
    let source = @os_fs.read_file_to_string(path) catch {
      e => {
        fail("failed to read " + path + ": " + e.to_string())
        continue
      }
    }
    let ast = @parser.parse_ast(source) catch {
      e => {
        fail("parse failed for " + path + ": " + e.to_string())
        continue
      }
    }
    if ast.stmts.length() == 0 {
      fail("expected non-empty stmts for " + file)
    }
  }
}

///|
test "selfhost compiler source files roundtrip format" {
  let compiler_dir = "vibe/compiler"
  let files = [
    "token.vibe", "ast.vibe", "lexer.vibe", "parser.vibe", "printer.vibe", "index.vibe",
    "types.vibe", "builtins.vibe", "checker.vibe", "checker_resolve.vibe", "checker_stmt.vibe",
  ]
  for file in files {
    let path = compiler_dir + "/" + file
    let source = @os_fs.read_file_to_string(path) catch {
      e => {
        fail("failed to read " + path + ": " + e.to_string())
        continue
      }
    }
    let fmt1 = @parser.format_script(source)
    let fmt2 = @parser.format_script(fmt1)
    if fmt1 != fmt2 {
      fail(
        file +
        " roundtrip unstable:\n--- fmt1 (first 200) ---\n" +
        fmt1[:200].to_owned() +
        "\n--- fmt2 (first 200) ---\n" +
        fmt2[:200].to_owned(),
      )
    }
  }
}
