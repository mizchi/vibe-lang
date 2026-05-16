///|
test "completion context for let" {
  let line = "let add2 = (x: Int, y: Int) { add(x, y) }"
  let ctx = detect_completion_context(line, line.length())
  match ctx {
    CompletionContext::VibeLetExpr => ()
    _ => fail("expected let expr context")
  }
  let ctx2 = detect_completion_context("let ", 4)
  match ctx2 {
    CompletionContext::VibeLetName => ()
    _ => fail("expected let name context")
  }
}

///|
test "extract let name" {
  match extract_let_name("let foo = 1") {
    Some(name) => assert_eq(name, "foo")
    None => fail("missing name")
  }
  match extract_let_name("let bar") {
    Some(name) => assert_eq(name, "bar")
    None => fail("missing name")
  }
  match extract_let_name("let rec foo = (a: Int) { a }") {
    Some(name) => assert_eq(name, "foo")
    None => fail("missing rec name")
  }
  match extract_let_name("add(1,2)") {
    Some(_) => fail("unexpected name")
    None => ()
  }
}

///|
test "completion suppressed inside fn params" {
  let line = "let x = fn(a"
  assert_true(is_in_fn_param_context(line, line.length()))
  let line2 = "let x = fn (a: Int) { a }"
  assert_false(is_in_fn_param_context(line2, line2.length()))
}

///|
test "method completion detection" {
  match detect_method_completion("t.foo", 5) {
    Some(info) => {
      assert_eq(info.receiver, "t")
      assert_eq(info.prefix, "foo")
    }
    None => fail("missing method info")
  }
  match detect_method_completion("t.", 2) {
    Some(info) => {
      assert_eq(info.receiver, "t")
      assert_eq(info.prefix, "")
    }
    None => fail("missing method info for empty prefix")
  }
  match detect_method_completion("foo bar", 7) {
    Some(_) => fail("unexpected method info")
    None => ()
  }
}

///|
test "pipe completion detection" {
  match detect_pipe_completion("x |> inc", 9) {
    Some(info) => {
      assert_eq(info.receiver, "x")
      assert_eq(info.prefix, "inc")
    }
    None => fail("missing pipe info")
  }
  match detect_pipe_completion("x |> ", 5) {
    Some(info) => {
      assert_eq(info.receiver, "x")
      assert_eq(info.prefix, "")
    }
    None => fail("missing pipe info for empty prefix")
  }
  match detect_pipe_completion("x | inc", 7) {
    Some(_) => fail("unexpected pipe info")
    None => ()
  }
}

///|
test "shell input rows grow with height" {
  assert_eq(repl_input_rows_for_height(20), 9)
  assert_eq(repl_input_rows_for_height(10), 5)
  assert_eq(repl_input_rows_for_height(6), 1)
}

///|
test "editor content start col reflects gutter" {
  let editor = @editor.EditorState::new_with_kind(
    "",
    1,
    @editor.HighlightKind::Plain,
  )
  assert_eq(editor_content_start_col(editor), 2)
  let buf = StringBuilder::new()
  for i in 0..<10 {
    if i > 0 {
      buf.write_char('\n')
    }
    buf.write_string("x")
  }
  let editor2 = @editor.EditorState::new_with_kind(
    buf.to_string(),
    1,
    @editor.HighlightKind::Plain,
  )
  assert_eq(editor_content_start_col(editor2), 3)
}

///|
test "line shell options parse default" {
  let parsed = parse_line_repl_options([], "shell-stdin", "vibe> ")
  match parsed {
    Ok(opts) => {
      assert_eq(opts.prompt, "vibe> ")
      assert_true(opts.prompt_enabled)
      assert_false(opts.restore_namespace)
      match opts.io_mode {
        LineReplIoMode::Plain => ()
        _ => fail("expected plain mode")
      }
    }
    Err(msg) => fail("unexpected err: " + msg)
  }
}

///|
test "line shell options parse tty and no prompt" {
  let parsed = parse_line_repl_options(
    ["--no-prompt", "--tty", "--restore"],
    "shell-stdin",
    "vibe> ",
  )
  match parsed {
    Ok(opts) => {
      assert_false(opts.prompt_enabled)
      assert_true(opts.restore_namespace)
      match opts.io_mode {
        LineReplIoMode::Tty => ()
        _ => fail("expected tty mode")
      }
    }
    Err(msg) => fail("unexpected err: " + msg)
  }
}

///|
test "line shell options reject unknown arg" {
  let parsed = parse_line_repl_options(["--wat"], "shell-stdin", "vibe> ")
  match parsed {
    Ok(_) => fail("expected error")
    Err(msg) => assert_eq(msg, "shell-stdin: unknown arg --wat")
  }
}

///|
test "line shell options show help" {
  let parsed = parse_line_repl_options(["--help"], "shell-stdin", "vibe> ")
  match parsed {
    Ok(_) => fail("expected help text")
    Err(msg) =>
      assert_eq(
        msg, "usage: shell-stdin [--no-prompt] [--tty|--no-tty] [--restore]",
      )
  }
}

///|
test "check failure message returns exit text only for errors" {
  @debug.assert_eq(check_failure_message(0), None)
  @debug.assert_eq(check_failure_message(1), Some("check: 1 error(s) found"))
  @debug.assert_eq(check_failure_message(3), Some("check: 3 error(s) found"))
}

///|
test "http host run command quotes default node wasm flag" {
  let prev = @sys.get_env_var("VIBE_NODE_WASM_FLAGS")
  defer wbtest_restore_env_var("VIBE_NODE_WASM_FLAGS", prev)
  @sys.unset_env_var("VIBE_NODE_WASM_FLAGS")
  let cmd = build_http_host_run_command(
    {
      node_bin: "/tmp/node",
      node_flags: resolve_http_host_runner_node_flags(),
      runner_script: "/tmp/runner.js",
    },
    "/tmp/app.wasm",
  )
  assert_eq(
    cmd, "\"/tmp/node\" \"--experimental-wasm-exnref\" \"/tmp/runner.js\" --invoke _vibe_run_tagged \"/tmp/app.wasm\"",
  )
}

///|
test "http host run command splits node wasm flags into quoted args" {
  let prev = @sys.get_env_var("VIBE_NODE_WASM_FLAGS")
  defer wbtest_restore_env_var("VIBE_NODE_WASM_FLAGS", prev)
  @sys.set_env_var(
    "VIBE_NODE_WASM_FLAGS", "--experimental-wasm-exnref --trace-wasm",
  )
  let cmd = build_http_host_run_command(
    {
      node_bin: "/tmp/node",
      node_flags: resolve_http_host_runner_node_flags(),
      runner_script: "/tmp/runner.js",
    },
    "/tmp/app.wasm",
  )
  assert_eq(
    cmd, "\"/tmp/node\" \"--experimental-wasm-exnref\" \"--trace-wasm\" \"/tmp/runner.js\" --invoke _vibe_run_tagged \"/tmp/app.wasm\"",
  )
}

///|
test "http host run command can invoke multiple exports in order" {
  let cmd = build_http_host_run_command_with_invokes(
    {
      node_bin: "/tmp/node",
      node_flags: ["--experimental-wasm-exnref"],
      runner_script: "/tmp/runner.js",
    },
    "/tmp/app.wasm",
    ["_bench_setup", "_bench_run"],
  )
  assert_eq(
    cmd, "\"/tmp/node\" \"--experimental-wasm-exnref\" \"/tmp/runner.js\" --invoke \"_bench_setup\" --invoke \"_bench_run\" \"/tmp/app.wasm\"",
  )
}

///|
test "resolve repl initial source ignores scratch db by default" {
  let root = wbtest_make_temp_dir("repl_initial_source_fresh")
  let scratch_db_path = root + "/scratch.db"
  @os_fs.write_string_to_file(scratch_db_path, "let x = 41\n") catch {
    e => fail("write scratch db failed: " + e.to_string())
  }
  let source = match resolve_repl_initial_source(scratch_db_path, false) {
    Ok(v) => v
    Err(err) => fail("expected fresh source: " + err)
  }
  assert_eq(source, "")
  wbtest_remove_if_exists(scratch_db_path)
  wbtest_remove_if_exists(root)
}

///|
test "resolve repl initial source restores scratch db when requested" {
  let root = wbtest_make_temp_dir("repl_initial_source_restore")
  let scratch_db_path = root + "/scratch.db"
  @os_fs.write_string_to_file(scratch_db_path, "let x = 41\n") catch {
    e => fail("write scratch db failed: " + e.to_string())
  }
  let source = match resolve_repl_initial_source(scratch_db_path, true) {
    Ok(v) => v
    Err(err) => fail("expected restored source: " + err)
  }
  assert_eq(source, "let x = 41\n")
  wbtest_remove_if_exists(scratch_db_path)
  wbtest_remove_if_exists(root)
}

///|
test "load scratch db source reports scratch-db context for non-file path" {
  let root = wbtest_make_temp_dir("load_scratch_db_not_file")
  match load_scratch_db_source(root) {
    Ok(_) => fail("expected non-file error")
    Err(err) => assert_eq(err, "scratch-db path is not a file: " + root)
  }
  wbtest_remove_if_exists(root)
}

///|
test "collect scratch scope symbols returns stable local defs" {
  let root = wbtest_make_temp_dir("collect_scratch_scope_symbols")
  let scratch_db_path = root + "/scratch.db"
  let scratch_source =
    #|let answer = 41
    #|let add_one = (x: Int) -> Int {
    #|  answer + x
    #|}
  let symbols = collect_scratch_scope_symbols(scratch_db_path, scratch_source)
  assert_eq(symbols.length(), 2)
  let names : Array[String] = []
  for symbol in symbols {
    names.push(symbol.name)
    assert_eq(symbol.path, scratch_db_path)
    assert_true(symbol.def_id.length() > 0)
  }
  assert_true(names.contains("answer"))
  assert_true(names.contains("add_one"))
  let symbols2 = collect_scratch_scope_symbols(scratch_db_path, scratch_source)
  assert_eq(symbols2.length(), symbols.length())
  for i in 0..<symbols.length() {
    assert_eq(symbols2[i].name, symbols[i].name)
    assert_eq(symbols2[i].path, symbols[i].path)
    assert_eq(symbols2[i].signature, symbols[i].signature)
    assert_eq(symbols2[i].kind, symbols[i].kind)
    assert_eq(symbols2[i].def_id, symbols[i].def_id)
  }
  wbtest_remove_if_exists(root)
}

///|
test "repl parser mode hint removed with do keyword" {
  // do keyword was removed; these tests are no longer relevant.
  // Kept as placeholder to maintain test count stability.
  ()
}

///|
test "resolve vibe lib dir prefers VIBE_LIB_ROOT over VIBE_LIB_DIR" {
  let prev_root = @sys.get_env_var("VIBE_LIB_ROOT")
  let prev_dir = @sys.get_env_var("VIBE_LIB_DIR")
  let prev_home = @sys.get_env_var("HOME")
  @sys.set_env_var("VIBE_LIB_ROOT", "/tmp/vibe-lib-root")
  @sys.set_env_var("VIBE_LIB_DIR", "/tmp/vibe-lib-dir")
  @sys.set_env_var("HOME", "/tmp/vibe-home")
  let resolved = resolve_vibe_lib_dir("/work/project")
  wbtest_restore_env_var("VIBE_LIB_ROOT", prev_root)
  wbtest_restore_env_var("VIBE_LIB_DIR", prev_dir)
  wbtest_restore_env_var("HOME", prev_home)
  assert_eq(resolved, "/tmp/vibe-lib-root")
}

///|
test "resolve vibe lib dir falls back to VIBE_LIB_DIR" {
  let prev_root = @sys.get_env_var("VIBE_LIB_ROOT")
  let prev_dir = @sys.get_env_var("VIBE_LIB_DIR")
  let prev_home = @sys.get_env_var("HOME")
  @sys.unset_env_var("VIBE_LIB_ROOT")
  @sys.set_env_var("VIBE_LIB_DIR", "local/lib")
  @sys.set_env_var("HOME", "/tmp/vibe-home")
  let resolved = resolve_vibe_lib_dir("/work/project")
  wbtest_restore_env_var("VIBE_LIB_ROOT", prev_root)
  wbtest_restore_env_var("VIBE_LIB_DIR", prev_dir)
  wbtest_restore_env_var("HOME", prev_home)
  assert_eq(resolved, "/work/project/local/lib")
}

///|
test "resolve vibe lib dir falls back to HOME default" {
  let prev_root = @sys.get_env_var("VIBE_LIB_ROOT")
  let prev_dir = @sys.get_env_var("VIBE_LIB_DIR")
  let prev_home = @sys.get_env_var("HOME")
  @sys.unset_env_var("VIBE_LIB_ROOT")
  @sys.unset_env_var("VIBE_LIB_DIR")
  @sys.set_env_var("HOME", "/tmp/vibe-home")
  let resolved = resolve_vibe_lib_dir("/work/project")
  wbtest_restore_env_var("VIBE_LIB_ROOT", prev_root)
  wbtest_restore_env_var("VIBE_LIB_DIR", prev_dir)
  wbtest_restore_env_var("HOME", prev_home)
  assert_eq(resolved, "/tmp/vibe-home/.vibe/lib")
}

///|
test "finalize cmd options parse default" {
  let parsed = parse_finalize_cmd_args([])
  match parsed {
    Ok(opts) => {
      match opts.db_path {
        Some(_) => fail("unexpected db path")
        None => ()
      }
      match opts.export_path {
        Some(_) => fail("unexpected export path")
        None => ()
      }
      assert_false(opts.library_mode)
      assert_false(opts.print_source)
      assert_false(opts.dry_run)
    }
    Err(msg) => fail("unexpected err: " + msg)
  }
}

///|
test "finalize cmd options parse db export and flags" {
  let parsed = parse_finalize_cmd_args([
    "--db=tmp1.db", "--export", "dist/out.vibe", "--library", "--print", "--dry-run",
  ])
  match parsed {
    Ok(opts) => {
      match opts.db_path {
        Some(path) => assert_eq(path, "tmp1.db")
        None => fail("expected db path")
      }
      match opts.export_path {
        Some(path) => assert_eq(path, "dist/out.vibe")
        None => fail("expected export path")
      }
      assert_true(opts.library_mode)
      assert_true(opts.print_source)
      assert_true(opts.dry_run)
    }
    Err(msg) => fail("unexpected err: " + msg)
  }
}

///|
test "finalize cmd options reject positional arg" {
  let parsed = parse_finalize_cmd_args(["foo"])
  match parsed {
    Ok(_) => fail("expected error")
    Err(msg) => assert_eq(msg, "finalize: unexpected arg foo")
  }
}

///|
test "fmt cmd options parse default write mode" {
  let parsed = parse_fmt_cmd_options(["a.vibe", "b.vibe"])
  match parsed {
    Ok(opts) => {
      assert_false(opts.dry_run)
      @debug.assert_eq(opts.files, ["a.vibe", "b.vibe"])
    }
    Err(msg) => fail("unexpected err: " + msg)
  }
}

///|
test "fmt cmd options parse dry-run and legacy write flags" {
  let parsed = parse_fmt_cmd_options(["--dry-run", "--write", "-w", "a.vibe"])
  match parsed {
    Ok(opts) => {
      assert_true(opts.dry_run)
      @debug.assert_eq(opts.files, ["a.vibe"])
    }
    Err(msg) => fail("unexpected err: " + msg)
  }
}

///|
test "fmt cmd options reject unknown option" {
  let parsed = parse_fmt_cmd_options(["--wat", "a.vibe"])
  match parsed {
    Ok(_) => fail("expected error")
    Err(msg) => assert_eq(msg, "fmt: unknown option --wat")
  }
}

///|
test "fmt dry-run diff renders changed lines" {
  let diff = render_fmt_dry_run_diff(
    "sample.vibe", "let value = 1\n", "let value = 2\n",
  )
  assert_true(diff.contains("--- sample.vibe\n"))
  assert_true(diff.contains("+++ sample.vibe\n"))
  assert_true(diff.contains("-let value = 1\n"))
  assert_true(diff.contains("+let value = 2\n"))
}

///|
test "fmt dry-run diff is empty when unchanged" {
  let diff = render_fmt_dry_run_diff(
    "sample.vibe", "let value = 1\n", "let value = 1\n",
  )
  assert_eq(diff, "")
}

///|
test "cli syntax mode parse default" {
  let parsed = parse_cli_syntax_args(["main.vibe"], "run")
  match parsed {
    Ok((mode, rest)) => {
      assert_eq(mode, @runtime.ParserMode::VibeMode)
      @debug.assert_eq(rest, ["main.vibe"])
    }
    Err(msg) => fail("unexpected err: " + msg)
  }
}

///|
test "cli syntax mode parse explicit vibe" {
  let parsed = parse_cli_syntax_args(["--syntax", "vibe", "main.vibe"], "run")
  match parsed {
    Ok((mode, rest)) => {
      assert_eq(mode, @runtime.ParserMode::VibeMode)
      @debug.assert_eq(rest, ["main.vibe"])
    }
    Err(msg) => fail("unexpected err: " + msg)
  }
}

///|
test "cli syntax mode parse rejects explicit posix" {
  let parsed = parse_cli_syntax_args(["--syntax", "posix", "main.vibe"], "run")
  match parsed {
    Ok(_) => fail("expected error")
    Err(msg) =>
      assert_eq(msg, "run: unsupported syntax `posix` (expected: vibe)")
  }
}

///|
test "cli syntax mode parse rejects explicit posix-ext" {
  let parsed = parse_cli_syntax_args(
    ["--syntax", "posix-ext", "main.vibe"],
    "run",
  )
  match parsed {
    Ok(_) => fail("expected error")
    Err(msg) =>
      assert_eq(msg, "run: unsupported syntax `posix-ext` (expected: vibe)")
  }
}

///|
test "cli syntax mode parse rejects explicit posix-strict" {
  let parsed = parse_cli_syntax_args(
    ["--syntax", "posix-strict", "main.vibe"],
    "run",
  )
  match parsed {
    Ok(_) => fail("expected error")
    Err(msg) =>
      assert_eq(msg, "run: unsupported syntax `posix-strict` (expected: vibe)")
  }
}

///|
test "cli runtime flags parse default" {
  let parsed = parse_cli_runtime_args(["main.vibe"], "run")
  match parsed {
    Ok(opts) => {
      assert_eq(opts.syntax_mode, @runtime.ParserMode::VibeMode)
      @debug.assert_eq(opts.cmd_args, ["main.vibe"])
      assert_false(opts.unstable_async)
      assert_false(opts.unstable_threads)
    }
    Err(msg) => fail("unexpected err: " + msg)
  }
}

///|
test "cli runtime flags parse with unstable flags" {
  let parsed = parse_cli_runtime_args(
    ["--unstable-async", "--syntax", "vibe", "--unstable-threads", "main.vibe"],
    "run",
  )
  match parsed {
    Ok(opts) => {
      assert_eq(opts.syntax_mode, @runtime.ParserMode::VibeMode)
      @debug.assert_eq(opts.cmd_args, ["main.vibe"])
      assert_true(opts.unstable_async)
      assert_true(opts.unstable_threads)
    }
    Err(msg) => fail("unexpected err: " + msg)
  }
}

///|
test "test cmd normalize jobs uses bounded auto default for non-positive input" {
  let prev = @sys.get_env_var("VIBE_TEST_JOBS")
  @sys.unset_env_var("VIBE_TEST_JOBS")
  defer wbtest_restore_env_var("VIBE_TEST_JOBS", prev)
  assert_eq(normalize_test_jobs(0), 1)
  assert_eq(normalize_test_jobs(-1), 1)
}

///|
test "test cmd normalize jobs keeps explicit positive value" {
  assert_eq(normalize_test_jobs(2), 2)
  assert_eq(normalize_test_jobs(8), 8)
}

///|
test "cli dispatch args parse leading unstable flags" {
  let parsed = parse_cli_dispatch_args([
    "vibe", "--unstable-async", "--unstable-threads", "run", "main.vibe",
  ])
  match parsed {
    Ok(v) => {
      assert_eq(v.cmd, "run")
      assert_eq(v.syntax_mode, @runtime.ParserMode::VibeMode)
      @debug.assert_eq(v.cmd_args, ["main.vibe"])
      assert_true(v.unstable_async)
      assert_true(v.unstable_threads)
    }
    Err(msg) => fail("unexpected err: " + msg)
  }
}

///|
test "cli dispatch args merges leading and trailing unstable flags" {
  let parsed = parse_cli_dispatch_args([
    "vibe", "--unstable-async", "run", "--unstable-threads", "--syntax", "vibe",
    "main.vibe",
  ])
  match parsed {
    Ok(v) => {
      assert_eq(v.cmd, "run")
      assert_eq(v.syntax_mode, @runtime.ParserMode::VibeMode)
      @debug.assert_eq(v.cmd_args, ["main.vibe"])
      assert_true(v.unstable_async)
      assert_true(v.unstable_threads)
    }
    Err(msg) => fail("unexpected err: " + msg)
  }
}

///|
test "cli dispatch args rejects missing command" {
  let parsed = parse_cli_dispatch_args([
    "vibe", "--unstable-async", "--unstable-threads",
  ])
  match parsed {
    Ok(_) => fail("expected error")
    Err(msg) => assert_eq(msg, "missing command")
  }
}

///|
test "removed public commands stay blocked" {
  @debug.assert_eq(
    removed_command_message("eval"),
    Some(
      "eval: command was removed. Use 'vibe shell' or 'vibe shell-stdin' for interactive evaluation, and 'vibe finalize --db <path>' for persisted scratch-db workflows.",
    ),
  )
  @debug.assert_eq(
    removed_command_message("bundle"),
    Some(
      "bundle: command was removed. Use 'vibe compile' to compile modules, or 'vibe precompile' for precompilation.",
    ),
  )
  @debug.assert_eq(removed_command_message("run"), None)
}

///|
test "cli usage advertises scratch workflow replacements" {
  let text = wbtest_join_lines(usage_lines())
  assert_true(text.contains("shell-stdin"))
  assert_true(text.contains("finalize --db <path>"))
  assert_false(text.contains("  eval "))
  assert_false(text.contains("  bundle "))
  assert_false(text.contains("REPL"))
}

///|
test "bench help advertises compiled-only surface" {
  let text = wbtest_join_lines(bench_help_lines())
  assert_true(text.contains("--backend compiled|wasm"))
  assert_true(text.contains("compiled backend"))
  assert_false(text.contains("interpreter"))
  assert_false(text.contains("--expr"))
}

///|
test "shell meta help uses shell terminology" {
  let lines : Array[String] = []
  let result = handle_repl_meta_command(":help", "/tmp/scratch.db", "", fn(
    line,
  ) {
    lines.push(line)
  })
  assert_eq(result, ReplMetaCommandResult::HandledContinue)
  let text = wbtest_join_lines(lines)
  assert_true(text.contains("Exit the shell"))
  assert_false(text.contains("REPL"))
}

///|
test "cli dispatch args parse init command" {
  let parsed = parse_cli_dispatch_args(["vibe", "init", "my-lib"])
  match parsed {
    Ok(v) => {
      assert_eq(v.cmd, "init")
      @debug.assert_eq(v.cmd_args, ["my-lib"])
    }
    Err(msg) => fail("unexpected err: " + msg)
  }
}

///|
test "cli dispatch args parse new command" {
  let parsed = parse_cli_dispatch_args(["vibe", "new", "my-lib"])
  match parsed {
    Ok(v) => {
      assert_eq(v.cmd, "new")
      @debug.assert_eq(v.cmd_args, ["my-lib"])
    }
    Err(msg) => fail("unexpected err: " + msg)
  }
}

///|
test "cli dispatch args parse explain-import command" {
  let parsed = parse_cli_dispatch_args(["vibe", "explain-import", "main.vibe"])
  match parsed {
    Ok(v) => {
      assert_eq(v.cmd, "explain-import")
      @debug.assert_eq(v.cmd_args, ["main.vibe"])
    }
    Err(msg) => fail("unexpected err: " + msg)
  }
}

///|
test "explain import report resolves lock-backed refs" {
  let root = wbtest_make_temp_dir("explain_import_hits")
  let entry = root + "/main.vibe"
  let dep = root + "/dep.vibe"
  let dep_source = "export let value = 1\n"
  @os_fs.write_string_to_file(dep, dep_source) catch {
    e => fail("write dep failed: " + e.to_string())
  }
  let version_source = "export let value = 2\n"
  let symbol_source = "export let value = 3\n"
  let direct_source = "export let value = 4\n"
  let dep_hash = @vibe_core.content_address_hash_string(dep_source)
  let version_hash = @vibe_core.content_address_hash_string(version_source)
  let symbol_hash = @vibe_core.content_address_hash_string(symbol_source)
  let direct_hash = @vibe_core.content_address_hash_string(direct_source)
  let main_source = "import ./dep.vibe { value }\n" +
    "import version@main { value }\n" +
    "import symbol@main/sym { value }\n" +
    "import #\{direct_hash} { value }\n" +
    "let x = value\n"
  @os_fs.write_string_to_file(entry, main_source) catch {
    e => fail("write entry failed: " + e.to_string())
  }
  let lock_path = @codebase.lock_file_path(entry)
  let dep_norm = @vibe_fs.normalize_path(dep)
  let path_refs : Map[String, String] = {}
  path_refs[dep_norm] = dep_hash
  let version_refs : Map[String, String] = {}
  version_refs["main"] = version_hash
  let symbol_refs : Map[String, String] = {}
  symbol_refs["main/sym"] = symbol_hash
  let lock = @codebase.LockData::new(path_refs, version_refs, symbol_refs)
  match @codebase.write_lock_data(lock_path, lock) {
    Ok(_) => ()
    Err(err) => fail("write lock failed: " + err)
  }
  let codebase = @codebase.Codebase::new(@codebase.vibe_dir_path(entry))
  ignore(
    codebase.write_object(version_hash, version_source) catch {
      e => fail("write version object failed: " + e.to_string())
    },
  )
  ignore(
    codebase.write_object(symbol_hash, symbol_source) catch {
      e => fail("write symbol object failed: " + e.to_string())
    },
  )
  ignore(
    codebase.write_object(direct_hash, direct_source) catch {
      e => fail("write hash object failed: " + e.to_string())
    },
  )
  let report = match explain_import_report(entry) {
    Ok(v) => v
    Err(err) => fail("unexpected explain-import error: " + err)
  }
  assert_eq(report.imports.length(), 4)
  let path_item = wbtest_find_explain_import_item(report.imports, "./dep.vibe")
  assert_eq(path_item.ref_kind, "PathRef")
  assert_eq(path_item.lock_lookup_status, "hit")
  @debug.assert_eq(path_item.resolved_hash, Some(dep_hash))
  let version_item = wbtest_find_explain_import_item(
    report.imports,
    "version@main",
  )
  assert_eq(version_item.ref_kind, "VersionRef")
  assert_eq(version_item.lock_lookup_status, "hit")
  @debug.assert_eq(version_item.resolved_hash, Some(version_hash))
  let symbol_item = wbtest_find_explain_import_item(
    report.imports,
    "symbol@main/sym",
  )
  assert_eq(symbol_item.ref_kind, "SymbolRef")
  assert_eq(symbol_item.lock_lookup_status, "hit")
  @debug.assert_eq(symbol_item.resolved_hash, Some(symbol_hash))
  let hash_item = wbtest_find_explain_import_item(
    report.imports,
    "#" + direct_hash,
  )
  assert_eq(hash_item.ref_kind, "HashRef")
  assert_eq(hash_item.lock_lookup_status, "n/a")
  @debug.assert_eq(hash_item.resolved_hash, Some(direct_hash))
  wbtest_remove_if_exists(root)
}

///|
test "explain import report shows miss mismatch and resolution errors" {
  let root = wbtest_make_temp_dir("explain_import_errors")
  let entry = root + "/main.vibe"
  let dep = root + "/dep.vibe"
  let dep_source = "export let value = 1\n"
  @os_fs.write_string_to_file(dep, dep_source) catch {
    e => fail("write dep failed: " + e.to_string())
  }
  let missing_hash = "1111111111111111111111111111111111111111"
  let main_source = "import ./dep.vibe { value }\n" +
    "import version@missing { value }\n" +
    "import symbol@missing/sym { value }\n" +
    "import #\{missing_hash} { value }\n" +
    "import unknown_ns/lib.vibe { value }\n" +
    "let x = value\n"
  @os_fs.write_string_to_file(entry, main_source) catch {
    e => fail("write entry failed: " + e.to_string())
  }
  let lock_path = @codebase.lock_file_path(entry)
  let dep_norm = @vibe_fs.normalize_path(dep)
  let wrong_hash = @vibe_core.content_address_hash_string(
    "export let value = 2\n",
  )
  let path_refs : Map[String, String] = {}
  path_refs[dep_norm] = wrong_hash
  let lock = @codebase.LockData::new(path_refs, {}, {})
  match @codebase.write_lock_data(lock_path, lock) {
    Ok(_) => ()
    Err(err) => fail("write lock failed: " + err)
  }
  let report = match explain_import_report(entry) {
    Ok(v) => v
    Err(err) => fail("unexpected explain-import error: " + err)
  }
  let path_item = wbtest_find_explain_import_item(report.imports, "./dep.vibe")
  assert_eq(path_item.ref_kind, "PathRef")
  assert_eq(path_item.lock_lookup_status, "mismatch")
  assert_true(
    match path_item.reason {
      Some(reason) => reason.contains("lock hash differs")
      None => false
    },
  )
  let version_item = wbtest_find_explain_import_item(
    report.imports,
    "version@missing",
  )
  assert_eq(version_item.lock_lookup_status, "miss")
  let symbol_item = wbtest_find_explain_import_item(
    report.imports,
    "symbol@missing/sym",
  )
  assert_eq(symbol_item.lock_lookup_status, "miss")
  let hash_item = wbtest_find_explain_import_item(
    report.imports,
    "#" + missing_hash,
  )
  assert_eq(hash_item.lock_lookup_status, "n/a")
  assert_true(
    match hash_item.reason {
      Some(reason) => reason.contains("hash object not found")
      None => false
    },
  )
  let ns_item = wbtest_find_explain_import_item(
    report.imports,
    "unknown_ns/lib.vibe",
  )
  assert_eq(ns_item.lock_lookup_status, "error")
  assert_true(
    match ns_item.reason {
      Some(reason) => reason.contains("unknown namespace")
      None => false
    },
  )
  wbtest_remove_if_exists(root)
}

///|
test "cli syntax mode parse rejects unknown value" {
  let parsed = parse_cli_syntax_args(["--syntax", "foo"], "run")
  match parsed {
    Ok(_) => fail("expected error")
    Err(msg) => assert_eq(msg, "run: unsupported syntax `foo` (expected: vibe)")
  }
}

///|
test "cli syntax mode parse rejects missing value" {
  let parsed = parse_cli_syntax_args(["--syntax"], "run")
  match parsed {
    Ok(_) => fail("expected error")
    Err(msg) =>
      assert_eq(msg, "run: missing value for --syntax (expected: vibe)")
  }
}

///|
test "compile args parse wite default level" {
  let parsed = parse_compile_cmd_args([
    "--wasm", "--wite", "-o", "/tmp/out.wasm", "main.vibe",
  ])
  match parsed {
    Ok(opts) => {
      assert_eq(opts.mode, CompileMode::Wasm)
      assert_false(opts.no_dce)
      assert_eq(opts.entry_path, "main.vibe")
      match opts.out_path {
        Some(path) => assert_eq(path, "/tmp/out.wasm")
        None => fail("expected out path")
      }
      match opts.opt_level {
        Some(level) => assert_eq(level, "-Oz")
        None => fail("expected opt level")
      }
    }
    Err(msg) => fail("unexpected err: " + msg)
  }
}

///|
test "compile args parse explicit O level for component" {
  let parsed = parse_compile_cmd_args(["--component", "-O3", "main.vibe"])
  match parsed {
    Ok(opts) => {
      assert_eq(opts.mode, CompileMode::Component)
      match opts.opt_level {
        Some(level) => assert_eq(level, "-O3")
        None => fail("expected opt level")
      }
    }
    Err(msg) => fail("unexpected err: " + msg)
  }
}

///|
test "compile args parse http host imports for wasm" {
  let parsed = parse_compile_cmd_args([
    "--wasm", "--http-host-imports", "main.vibe",
  ])
  match parsed {
    Ok(opts) => {
      assert_eq(opts.mode, CompileMode::Wasm)
      assert_true(opts.http_host_imports)
      assert_eq(opts.entry_path, "main.vibe")
    }
    Err(msg) => fail("unexpected err: " + msg)
  }
}

///|
test "compile args parse http host imports for component" {
  let parsed = parse_compile_cmd_args([
    "--component", "--http-host-imports", "main.vibe",
  ])
  match parsed {
    Ok(opts) => {
      assert_eq(opts.mode, CompileMode::Component)
      assert_true(opts.http_host_imports)
      assert_eq(opts.entry_path, "main.vibe")
    }
    Err(msg) => fail("unexpected err: " + msg)
  }
}

///|
test "compile args reject http host imports on wit" {
  let parsed = parse_compile_cmd_args([
    "--wit", "--http-host-imports", "main.vibe",
  ])
  match parsed {
    Ok(_) => fail("expected error")
    Err(msg) =>
      assert_eq(
        msg, "compile: --http-host-imports is only supported with --wasm or --component",
      )
  }
}

///|
test "compile args parse explicit O4 level for component" {
  let parsed = parse_compile_cmd_args(["--component", "-O4", "main.vibe"])
  match parsed {
    Ok(opts) => {
      assert_eq(opts.mode, CompileMode::Component)
      match opts.opt_level {
        Some(level) => assert_eq(level, "-O4")
        None => fail("expected opt level")
      }
    }
    Err(msg) => fail("unexpected err: " + msg)
  }
}

///|
test "compile args parse wac mode with wite default level" {
  let parsed = parse_compile_cmd_args(["--wac", "--wite", "main.wac"])
  match parsed {
    Ok(opts) => {
      assert_eq(opts.mode, CompileMode::Wac)
      assert_eq(opts.entry_path, "main.wac")
      match opts.opt_level {
        Some(level) => assert_eq(level, "-Oz")
        None => fail("expected opt level")
      }
    }
    Err(msg) => fail("unexpected err: " + msg)
  }
}

///|
test "sync wac deps skips when wite config is missing" {
  let root = wbtest_make_temp_dir("wac_deps_skip_missing_config")
  let wac_path = root + "/main.wac"
  @os_fs.write_string_to_file(wac_path, "package app:composition;\n") catch {
    e => fail("write wac failed: " + e.to_string())
  }
  let fs = @io.default_fs_adapter()
  let synced = match sync_wac_dependencies_if_configured(wac_path, fs) {
    Ok(v) => v
    Err(msg) => fail("unexpected sync error: " + msg)
  }
  assert_eq(synced, 0U)
  assert_eq(default_wac_config_path(wac_path), root + "/wite.config.jsonc")
}

///|
test "compile args parse coverage for wasm" {
  let parsed = parse_compile_cmd_args([
    "--wasm", "--coverage", "-o", "/tmp/out.wasm", "main.vibe",
  ])
  match parsed {
    Ok(opts) => {
      assert_eq(opts.mode, CompileMode::Wasm)
      assert_true(opts.coverage)
      assert_false(opts.coverage_run_tests)
      assert_eq(opts.entry_path, "main.vibe")
      match opts.out_path {
        Some(path) => assert_eq(path, "/tmp/out.wasm")
        None => fail("expected out path")
      }
    }
    Err(msg) => fail("unexpected err: " + msg)
  }
}

///|
test "compile args parse coverage run tests for wasm" {
  let parsed = parse_compile_cmd_args([
    "--wasm", "--coverage", "--coverage-run-tests", "main.vibe",
  ])
  match parsed {
    Ok(opts) => {
      assert_eq(opts.mode, CompileMode::Wasm)
      assert_true(opts.coverage)
      assert_true(opts.coverage_run_tests)
      assert_eq(opts.entry_path, "main.vibe")
    }
    Err(msg) => fail("unexpected err: " + msg)
  }
}

///|
test "compile args parse debug errors for wasm" {
  let parsed = parse_compile_cmd_args(["--wasm", "--debug-errors", "main.vibe"])
  match parsed {
    Ok(opts) => {
      assert_eq(opts.mode, CompileMode::Wasm)
      assert_true(opts.debug_errors)
      assert_eq(opts.entry_path, "main.vibe")
    }
    Err(msg) => fail("unexpected err: " + msg)
  }
}

///|
test "compile args reject coverage run tests without coverage" {
  let parsed = parse_compile_cmd_args([
    "--wasm", "--coverage-run-tests", "main.vibe",
  ])
  match parsed {
    Ok(_) => fail("expected error")
    Err(msg) =>
      assert_eq(msg, "compile: --coverage-run-tests requires --coverage")
  }
}

///|
test "compile args reject debug errors on non-wasm mode" {
  let parsed = parse_compile_cmd_args(["--wit", "--debug-errors", "main.vibe"])
  match parsed {
    Ok(_) => fail("expected error")
    Err(msg) =>
      assert_eq(
        msg, "compile: --debug-errors is only supported with --wasm or --wasm-js-string",
      )
  }
}

///|
test "compile args reject coverage on non-wasm mode" {
  let parsed = parse_compile_cmd_args(["--wit", "--coverage", "main.vibe"])
  match parsed {
    Ok(_) => fail("expected error")
    Err(msg) =>
      assert_eq(
        msg, "compile: --coverage is only supported with --wasm or --wasm-js-string",
      )
  }
}

///|
test "compile args reject no-dce on non-wasm mode" {
  let parsed = parse_compile_cmd_args(["--wit", "--no-dce", "main.vibe"])
  match parsed {
    Ok(_) => fail("expected error")
    Err(msg) =>
      assert_eq(
        msg, "compile: --no-dce is only supported with --wasm, --wasm-js-string, or --wasm-gc",
      )
  }
}

///|
test "compile args reject optimize flags on non-binary mode" {
  let parsed = parse_compile_cmd_args(["--wit", "-Oz", "main.vibe"])
  match parsed {
    Ok(_) => fail("expected error")
    Err(msg) =>
      assert_eq(
        msg, "compile: --wite/-O* is only supported with --wasm, --wasm-js-string, --wasm-gc, --component, or --wac",
      )
  }
}

///|
test "compile-lite validate allows wasm no-dce" {
  let parsed = parse_compile_cmd_args([
    "--wasm", "--no-dce", "-o", "/tmp/out.wasm", "main.vibe",
  ])
  match parsed {
    Ok(opts) =>
      match compile_lite_validate_opts(opts, false) {
        Ok(_) => ()
        Err(msg) => fail("unexpected err: " + msg)
      }
    Err(msg) => fail("unexpected parse err: " + msg)
  }
}

///|
test "compile-lite validate allows wasm-linear no-dce" {
  let parsed = parse_compile_cmd_args([
    "--wasm-linear", "--no-dce", "-o", "/tmp/out.wasm", "main.vibe",
  ])
  match parsed {
    Ok(opts) => {
      assert_eq(opts.mode, CompileMode::Wasm)
      match compile_lite_validate_opts(opts, false) {
        Ok(_) => ()
        Err(msg) => fail("unexpected err: " + msg)
      }
    }
    Err(msg) => fail("unexpected parse err: " + msg)
  }
}

///|
test "compile-lite validate allows wasm-gc" {
  let parsed = parse_compile_cmd_args([
    "--wasm-gc", "-o", "/tmp/out.wasm", "main.vibe",
  ])
  match parsed {
    Ok(opts) => {
      assert_eq(opts.mode, CompileMode::WasmGc)
      match compile_lite_validate_opts(opts, false) {
        Ok(_) => ()
        Err(msg) => fail("unexpected err: " + msg)
      }
    }
    Err(msg) => fail("unexpected parse err: " + msg)
  }
}

///|
test "compile-lite validate rejects coverage" {
  let parsed = parse_compile_cmd_args([
    "--wasm", "--coverage", "-o", "/tmp/out.wasm", "main.vibe",
  ])
  match parsed {
    Ok(opts) =>
      match compile_lite_validate_opts(opts, false) {
        Ok(_) => fail("expected validation error")
        Err(msg) =>
          assert_eq(
            msg, "compile-lite: --coverage/--coverage-run-tests are not supported",
          )
      }
    Err(msg) => fail("unexpected parse err: " + msg)
  }
}

///|
test "compile-lite split args extracts profile tsv path" {
  let parsed = split_compile_lite_args([
    "--wasm", "--profile-tsv", "/tmp/profile.tsv", "-o", "/tmp/out.wasm", "main.vibe",
  ])
  match parsed {
    Ok((args, Some(path), _, in_memory)) => {
      assert_eq(path, "/tmp/profile.tsv")
      assert_eq(args.length(), 4)
      assert_eq(args[0], "--wasm")
      assert_eq(args[1], "-o")
      assert_false(in_memory)
    }
    Ok(_) => fail("expected profile path")
    Err(msg) => fail(msg)
  }
}

///|
test "compile-lite split args rejects missing profile path" {
  let parsed = split_compile_lite_args(["--wasm", "--profile-tsv"])
  match parsed {
    Ok(_) => fail("expected parse error")
    Err(msg) => assert_eq(msg, "compile-lite: missing path after --profile-tsv")
  }
}

///|
test "compile-lite validate allows in-memory without out" {
  let parsed = parse_compile_cmd_args(["--wasm", "main.vibe"])
  match parsed {
    Ok(opts) =>
      match compile_lite_validate_opts(opts, true) {
        Ok(_) => ()
        Err(msg) => fail("unexpected err: " + msg)
      }
    Err(msg) => fail("unexpected parse err: " + msg)
  }
}

///|
test "check split args extracts profile tsv path" {
  let parsed = split_check_cmd_args([
    "--profile-tsv", "/tmp/check.tsv", "a.vibe", "b.vibe",
  ])
  match parsed {
    Ok((args, Some(path), _)) => {
      assert_eq(path, "/tmp/check.tsv")
      assert_eq(args.length(), 2)
      assert_eq(args[0], "a.vibe")
      assert_eq(args[1], "b.vibe")
    }
    Ok(_) => fail("expected profile path")
    Err(msg) => fail(msg)
  }
}

///|
test "check split args rejects missing profile path" {
  let parsed = split_check_cmd_args(["--profile-tsv"])
  match parsed {
    Ok(_) => fail("expected parse error")
    Err(msg) => assert_eq(msg, "check: missing path after --profile-tsv")
  }
}

///|
test "check split args extracts builtin-contract flag" {
  let parsed = split_check_cmd_args(["--builtin-contract=warn", "a.vibe"])
  match parsed {
    Ok((args, None, contract)) => {
      assert_eq(args.length(), 1)
      assert_eq(args[0], "a.vibe")
      assert_eq(contract, "warn")
    }
    Ok(_) => fail("unexpected result")
    Err(msg) => fail(msg)
  }
}

///|
test "check split args builtin-contract separate value" {
  let parsed = split_check_cmd_args(["--builtin-contract", "error", "a.vibe"])
  match parsed {
    Ok((args, None, contract)) => {
      assert_eq(args.length(), 1)
      assert_eq(contract, "error")
    }
    Ok(_) => fail("unexpected result")
    Err(msg) => fail(msg)
  }
}

///|
test "check split args builtin-contract invalid value" {
  let parsed = split_check_cmd_args(["--builtin-contract=invalid", "a.vibe"])
  match parsed {
    Ok(_) => fail("expected error")
    Err(msg) =>
      assert_eq(
        msg, "check: invalid --builtin-contract value: invalid (expected warn|error|ignore)",
      )
  }
}

///|
test "check split args builtin-contract default is ignore" {
  let parsed = split_check_cmd_args(["a.vibe"])
  match parsed {
    Ok((_, _, contract)) => assert_eq(contract, "ignore")
    Err(msg) => fail(msg)
  }
}

///|
test "bench case arg parse named" {
  let parsed = parse_bench_case_arg("sum=add(1,2)", 1)
  match parsed {
    Ok(case_item) => {
      assert_eq(case_item.name, "sum")
      assert_eq(case_item.expr, "add(1,2)")
    }
    Err(msg) => fail("unexpected err: " + msg)
  }
}

///|
test "bench case arg parse unnamed expression" {
  let parsed = parse_bench_case_arg("add(1,2)", 2)
  match parsed {
    Ok(case_item) => {
      assert_eq(case_item.name, "case2")
      assert_eq(case_item.expr, "add(1,2)")
    }
    Err(msg) => fail("unexpected err: " + msg)
  }
}

///|
test "bench case arg keeps equality expression" {
  let parsed = parse_bench_case_arg("eq(1,1) == true", 3)
  match parsed {
    Ok(case_item) => {
      assert_eq(case_item.name, "case3")
      assert_eq(case_item.expr, "eq(1,1) == true")
    }
    Err(msg) => fail("unexpected err: " + msg)
  }
}

///|
test "bench case source parse skips comments and blanks" {
  let source =
    #|# warm paths
    #|
    #|sum = add(1,2)
    #|eq(1,1) == true
    #|   # trailing comment line
  let parsed = parse_bench_case_source(source, 1)
  match parsed {
    Ok(cases) => {
      assert_eq(cases.length(), 2)
      assert_eq(cases[0].name, "sum")
      assert_eq(cases[0].expr, "add(1,2)")
      assert_eq(cases[1].name, "case2")
      assert_eq(cases[1].expr, "eq(1,1) == true")
    }
    Err(msg) => fail("unexpected err: " + msg)
  }
}

///|
test "line shell extract let name" {
  match extract_let_name_line("let foo = 1") {
    Some(name) => assert_eq(name, "foo")
    None => fail("missing foo")
  }
  match extract_let_name_line("let rec bar = (x: Int) { x }") {
    Some(name) => assert_eq(name, "bar")
    None => fail("missing bar")
  }
  match extract_let_name_line("add(1,2)") {
    Some(_) => fail("unexpected let name")
    None => ()
  }
}

///|
test "resolve test entry paths includes top-level vibe files" {
  let root = wbtest_make_temp_dir("resolve_tests")
  let sub = root + "/sub"
  let deep = sub + "/deep"
  @os_fs.create_dir(sub) catch {
    e => fail("create sub dir failed: " + e.to_string())
  }
  @os_fs.create_dir(deep) catch {
    e => fail("create deep dir failed: " + e.to_string())
  }
  let top = root + "/top.vibe"
  let nested = sub + "/nested.vibe"
  let deep_nested = deep + "/deep_nested.vibe"
  let ignored = deep + "/ignored.txt"
  @os_fs.write_string_to_file(top, "") catch {
    e => fail("write top failed: " + e.to_string())
  }
  @os_fs.write_string_to_file(nested, "") catch {
    e => fail("write nested failed: " + e.to_string())
  }
  @os_fs.write_string_to_file(deep_nested, "") catch {
    e => fail("write deep nested failed: " + e.to_string())
  }
  @os_fs.write_string_to_file(ignored, "") catch {
    e => fail("write ignored failed: " + e.to_string())
  }
  let files = resolve_test_entry_paths([root])
  assert_eq(files.length(), 1)
  assert_true(wbtest_contains(files, top))
  assert_false(wbtest_contains(files, nested))
  assert_false(wbtest_contains(files, deep_nested))
  assert_false(wbtest_contains(files, ignored))
  let files2 = resolve_test_entry_paths([root, nested])
  assert_eq(files2.length(), 2)
  assert_true(wbtest_contains(files2, top))
  assert_true(wbtest_contains(files2, nested))
  wbtest_remove_if_exists(ignored)
  wbtest_remove_if_exists(deep_nested)
  wbtest_remove_if_exists(nested)
  wbtest_remove_if_exists(top)
  wbtest_remove_if_exists(deep)
  wbtest_remove_if_exists(sub)
  wbtest_remove_if_exists(root)
}

///|
test "resolve test entry paths ignores generated hidden wasm probe files" {
  let root = wbtest_make_temp_dir("resolve_tests_hidden")
  let top = root + "/top.vibe"
  let generated_vibe = root + "/.vibe_test_wasm_123456.vibe"
  let hidden_vibe = root + "/.hidden.vibe"
  @os_fs.write_string_to_file(top, "") catch {
    e => fail("write top failed: " + e.to_string())
  }
  @os_fs.write_string_to_file(generated_vibe, "") catch {
    e => fail("write generated vibe failed: " + e.to_string())
  }
  @os_fs.write_string_to_file(hidden_vibe, "") catch {
    e => fail("write hidden vibe failed: " + e.to_string())
  }
  let files = resolve_test_entry_paths([root])
  assert_eq(files.length(), 1)
  assert_true(wbtest_contains(files, top))
  assert_false(wbtest_contains(files, generated_vibe))
  assert_false(wbtest_contains(files, hidden_vibe))
  wbtest_remove_if_exists(hidden_vibe)
  wbtest_remove_if_exists(generated_vibe)
  wbtest_remove_if_exists(top)
  wbtest_remove_if_exists(root)
}

///|
test "resolve bench entry paths includes top-level _bench.vibe files" {
  let root = wbtest_make_temp_dir("resolve_bench")
  let sub = root + "/sub"
  @os_fs.create_dir(sub) catch {
    e => fail("create sub dir failed: " + e.to_string())
  }
  let top = root + "/top_bench.vibe"
  let top_non_bench = root + "/top.vibe"
  let nested = sub + "/nested_bench.vibe"
  @os_fs.write_string_to_file(top, "") catch {
    e => fail("write top bench failed: " + e.to_string())
  }
  @os_fs.write_string_to_file(top_non_bench, "") catch {
    e => fail("write top non bench failed: " + e.to_string())
  }
  @os_fs.write_string_to_file(nested, "") catch {
    e => fail("write nested bench failed: " + e.to_string())
  }
  let files = resolve_bench_entry_paths([root])
  assert_eq(files.length(), 1)
  assert_true(wbtest_contains(files, top))
  assert_false(wbtest_contains(files, top_non_bench))
  assert_false(wbtest_contains(files, nested))
  let files2 = resolve_bench_entry_paths([root, nested])
  assert_eq(files2.length(), 2)
  assert_true(wbtest_contains(files2, top))
  assert_true(wbtest_contains(files2, nested))
  wbtest_remove_if_exists(nested)
  wbtest_remove_if_exists(top_non_bench)
  wbtest_remove_if_exists(top)
  wbtest_remove_if_exists(sub)
  wbtest_remove_if_exists(root)
}

///|
test "normalize source sorts declarations and prunes unreachable defs" {
  let source =
    #|let dead = () -> Int { 0 }
    #|import ./dep.vibe { dep }
    #|trait Eq
    #|impl Eq for Int
    #|type Alias = Int
    #|let helper = () -> Int { 1 }
    #|export let run = () -> Int { helper() }
    #|export let run_io = () -> Int with {Error} { run() }
    #|export { run, run_io }
  let normalized = match normalize_source_text(source) {
    Ok(v) => v
    Err(msg) => fail("normalize failed: " + msg)
  }
  assert_false(normalized.contains("let dead ="))
  assert_false(normalized.contains("type Alias = Int"))
  // Fn expressions should NOT produce declare+assign
  assert_false(normalized.contains("declare export let run"))
  assert_false(normalized.contains("declare export let run_io"))
  let idx_use = wbtest_substring_index(normalized, "import ./dep.vibe {")
  let idx_trait = wbtest_substring_index(normalized, "trait Eq")
  let idx_helper = wbtest_substring_index(normalized, "let helper =")
  let idx_run = wbtest_substring_index(normalized, "export let run =")
  let idx_run_io = wbtest_substring_index(normalized, "export let run_io =")
  assert_true(idx_use >= 0)
  assert_true(idx_trait >= 0)
  assert_true(idx_helper >= 0)
  assert_true(idx_run >= 0)
  assert_true(idx_run_io >= 0)
  assert_true(idx_use < idx_trait)
  assert_true(idx_trait < idx_helper)
  assert_true(idx_helper < idx_run)
  assert_true(idx_run < idx_run_io)
}

///|
test "normalize source flattens module body and sorts functions" {
  let source =
    #|export module math {
    #|  let dead = () -> Int { 0 }
    #|  let helper = () -> Int { 1 }
    #|  export let run = () -> Int { helper() }
    #|  export let run_io = () -> Int with {Error} { run() }
    #|}
  let normalized = match normalize_source_text(source) {
    Ok(v) => v
    Err(msg) => fail("normalize failed: " + msg)
  }
  assert_false(normalized.contains("export module math {"))
  assert_false(normalized.contains("let dead ="))
  // Fn expressions should NOT produce declare+assign
  assert_false(normalized.contains("declare export let"))
  let idx_helper = wbtest_substring_index(normalized, "let math::helper:")
  let idx_run = wbtest_substring_index(normalized, "export let math::run:")
  let idx_run_io = wbtest_substring_index(
    normalized, "export let math::run_io:",
  )
  assert_true(idx_helper >= 0)
  assert_true(idx_run >= 0)
  assert_true(idx_run_io >= 0)
  assert_true(idx_helper < idx_run)
  assert_true(idx_run < idx_run_io)
}

///|
test "normalize source sorts function defs topologically with alpha tie" {
  let source =
    #|export let z = () -> Int { b() }
    #|export let b = () -> Int { 1 }
    #|export let a = () -> Int { 2 }
    #|export let io_z = () -> Int with {Error} { io_b() }
    #|export let io_b = () -> Int with {Error} { 1 }
    #|export let io_a = () -> Int with {Error} { 2 }
    #|export { a, b, z, io_a, io_b, io_z }
  let normalized = match normalize_source_text(source) {
    Ok(v) => v
    Err(msg) => fail("normalize failed: " + msg)
  }
  // Fn expressions should NOT produce declare+assign
  assert_false(normalized.contains("declare export let"))
  // Pure fns sorted: a (leaf), b (leaf), z (depends on b)
  let idx_a = wbtest_substring_index(normalized, "export let a:")
  let idx_b = wbtest_substring_index(normalized, "export let b:")
  let idx_z = wbtest_substring_index(normalized, "export let z:")
  // Effect fns sorted: io_a (leaf), io_b (leaf), io_z (depends on io_b)
  let idx_io_a = wbtest_substring_index(normalized, "export let io_a:")
  let idx_io_b = wbtest_substring_index(normalized, "export let io_b:")
  let idx_io_z = wbtest_substring_index(normalized, "export let io_z:")
  assert_true(idx_a >= 0)
  assert_true(idx_b >= 0)
  assert_true(idx_z >= 0)
  assert_true(idx_io_a >= 0)
  assert_true(idx_io_b >= 0)
  assert_true(idx_io_z >= 0)
  assert_true(idx_a < idx_b)
  assert_true(idx_b < idx_z)
  assert_true(idx_z < idx_io_a)
  assert_true(idx_io_a < idx_io_b)
  assert_true(idx_io_b < idx_io_z)
}

///|
test "normalize source keeps Type:: wrappers after plain defs on alpha tie" {
  let source =
    #|export let Int::foo = (x: Int) -> Int { x }
    #|export let bar = () -> Int { 1 }
    #|export let baz = () -> Int { 2 }
  let normalized = match normalize_source_text(source) {
    Ok(v) => v
    Err(msg) => fail("normalize failed: " + msg)
  }
  // Fn expressions should NOT produce declare+assign
  assert_false(normalized.contains("declare export let"))
  let idx_bar = wbtest_substring_index(normalized, "export let bar:")
  let idx_baz = wbtest_substring_index(normalized, "export let baz:")
  let idx_member = wbtest_substring_index(normalized, "export let Int::foo:")
  assert_true(idx_bar >= 0)
  assert_true(idx_baz >= 0)
  assert_true(idx_member >= 0)
  assert_true(idx_bar < idx_baz)
  assert_true(idx_baz < idx_member)
}

///|
test "normalize source inlines single-use zero-arg fn and folds const" {
  let source =
    #|let helper = () -> Int { 1 + 2 }
    #|let value = helper()
    #|export let run = () -> Int { value }
    #|export { run }
  let normalized = match normalize_source_text(source) {
    Ok(v) => v
    Err(msg) => fail("normalize failed: " + msg)
  }
  assert_false(normalized.contains("let helper ="))
  assert_true(normalized.contains("let value: Int = 3"))
}

///|
test "normalize source inserts inferred annotation on non-fn let" {
  let source =
    #|let answer = 40 + 2
    #|let id = (x: Int) -> Int { x }
    #|export let run = () -> Int { answer }
    #|export let keep = () -> Int { id(1) }
    #|export { run, keep }
  let normalized = match normalize_source_text(source) {
    Ok(v) => v
    Err(msg) => fail("normalize failed: " + msg)
  }
  assert_true(normalized.contains("let answer: Int = 42"))
  // With new-style fn definitions, fn lets now get type annotations too
  assert_true(normalized.contains("let id: (Int) -> Int ="))
}

///|
test "normalize source keeps export let for fn expressions without declare" {
  let source =
    #|let helper = () -> Int { 1 }
    #|export let run = () -> Int { helper() }
    #|export { run }
  let normalized = match normalize_source_text(source) {
    Ok(v) => v
    Err(msg) => fail("normalize failed: " + msg)
  }
  // Fn expressions should NOT produce declare+assign
  assert_false(normalized.contains("declare export let run"))
  assert_true(normalized.contains("export let run:"))
}

///|
test "normalize source emits section separators for types and functions" {
  let source =
    #|type Box = Int
    #|let value = 1
  let normalized = match normalize_source_text(source) {
    Ok(v) => v
    Err(msg) => fail("normalize failed: " + msg)
  }
  let idx_types = wbtest_substring_index(normalized, "//# Types")
  let idx_functions = wbtest_substring_index(normalized, "//# Functions")
  assert_true(idx_types >= 0)
  assert_true(idx_functions >= 0)
  assert_true(idx_types < idx_functions)
}

///|
test "normalize source keeps blank line between top-level definitions" {
  let source =
    #|let a = 1
    #|let b = 2
  let normalized = match normalize_source_text(source) {
    Ok(v) => v
    Err(msg) => fail("normalize failed: " + msg)
  }
  assert_true(normalized.contains("let a: Int = 1\n\nlet b: Int = 2"))
}

///|
test "normalize source keeps extern signature declarations" {
  let source =
    #|extern let %inc: (Int) -> Int
  let normalized = match normalize_source_text(source) {
    Ok(v) => v
    Err(msg) => fail("normalize failed: " + msg)
  }
  assert_true(normalized.contains("extern let %inc: (Int) -> Int"))
}

///|
test "std layer classification covers primary modules" {
  let trait_layer = match
    std_layer_for_path("/tmp/repo/vibe/prelude/builtin_traits.vibe") {
    Some(v) => std_layer_name(v)
    None => "none"
  }
  assert_eq(trait_layer, "trait-contract")

  let primitive_layer = match
    std_layer_for_path("/tmp/repo/vibe/prelude/string.vibe") {
    Some(v) => std_layer_name(v)
    None => "none"
  }
  assert_eq(primitive_layer, "pure-primitive")
  let primitive_layer_cmp = match
    std_layer_for_path("/tmp/repo/vibe/prelude/cmp.vibe") {
    Some(v) => std_layer_name(v)
    None => "none"
  }
  assert_eq(primitive_layer_cmp, "pure-primitive")
  let primitive_layer_char = match
    std_layer_for_path("/tmp/repo/vibe/prelude/char.vibe") {
    Some(v) => std_layer_name(v)
    None => "none"
  }
  assert_eq(primitive_layer_char, "pure-primitive")

  let data_layer = match
    std_layer_for_path("/tmp/repo/vibe/prelude/array.vibe") {
    Some(v) => std_layer_name(v)
    None => "none"
  }
  assert_eq(data_layer, "pure-data")
  let list_layer = match
    std_layer_for_path("/tmp/repo/vibe/prelude/list.vibe") {
    Some(v) => std_layer_name(v)
    None => "none"
  }
  assert_eq(list_layer, "none")
  let data_layer_bytes = match
    std_layer_for_path("/tmp/repo/vibe/prelude/bytes.vibe") {
    Some(v) => std_layer_name(v)
    None => "none"
  }
  assert_eq(data_layer_bytes, "pure-data")
  let data_layer_result = match
    std_layer_for_path("/tmp/repo/vibe/prelude/result.vibe") {
    Some(v) => std_layer_name(v)
    None => "none"
  }
  assert_eq(data_layer_result, "pure-data")

  let ref_layer = match std_layer_for_path("/tmp/repo/vibe/path/ref.vibe") {
    Some(v) => std_layer_name(v)
    None => "none"
  }
  assert_eq(ref_layer, "ref-model")

  let effect_layer = match
    std_layer_for_path("/tmp/repo/vibe/prelude/threads/runtime.vibe") {
    Some(v) => std_layer_name(v)
    None => "none"
  }
  assert_eq(effect_layer, "effect-boundary")
}

///|
test "std layering rejects pure-data to effect import" {
  let source =
    #|import ./io.vibe { stdout_write }
  let violations = std_layering_violations_for_source(
    "/tmp/repo/vibe/prelude/array.vibe", source,
  )
  assert_eq(violations.length(), 1)
  assert_true(violations[0].contains("pure-data"))
  assert_true(violations[0].contains("effect-boundary"))
}

///|
test "std layering allows effect to primitive import and ignores std tests" {
  let allowed_source =
    #|import ./string.vibe { String }
  let allowed = std_layering_violations_for_source(
    "/tmp/repo/vibe/prelude/io.vibe", allowed_source,
  )
  assert_eq(allowed.length(), 0)

  let test_source =
    #|import ./io.vibe { stdout_write }
  let test_file = std_layering_violations_for_source(
    "/tmp/repo/vibe/prelude/io_test.vibe", test_source,
  )
  assert_eq(test_file.length(), 0)
}

///|
test "normalize source succeeds for vibe std files" {
  let files = wbtest_collect_vibe_files_recursive("vibe/prelude")
  if files.length() == 0 {
    fail("[vibe/prelude] no .vibe files found")
  }
  for path in files {
    if path.has_suffix("_test.vibe") {
      continue
    }
    if path.has_suffix("/view.vibe") {
      continue
    }
    let source = @os_fs.read_file_to_string(path) catch {
      e => fail("[\{path}] read failed: \{e.to_string()}")
    }
    let _ = match normalize_source_text(source) {
      Ok(v) => v
      Err(msg) => fail("[\{path}] normalize failed: " + msg)
    }
  }
}

///|
test "fmt pipeline applies normalize rules" {
  let source =
    #|let dead = () -> Int { 0 }
    #|let helper = () -> Int { 1 }
    #|export let run = () -> Int { helper() }
    #|export { run }
  let output = match normalize_format_source_text(source) {
    Ok(v) => v
    Err(err) => fail("fmt pipeline failed: " + err)
  }
  assert_false(output.contains("let dead ="))
  assert_true(output.contains("let helper:"))
  // Fn expressions should NOT produce declare+assign
  assert_false(output.contains("declare export let run"))
  assert_true(output.contains("export let run:"))
}

///|
test "normalize fixtures input output pairs" {
  let fixture_dir = "src/cmd/vibe/fixtures/normalize"
  let entries = @os_fs.read_dir(fixture_dir) catch {
    e => fail("[\{fixture_dir}] read_dir failed: \{e.to_string()}")
  }
  let input_files : Array[String] = []
  for entry in entries {
    let path = if entry.has_prefix(fixture_dir) {
      entry
    } else {
      fixture_dir + "/" + entry
    }
    let is_file = @os_fs.is_file(path) catch {
      e => fail("[\{fixture_dir}] stat failed: \{e.to_string()}")
    }
    if is_file && path.has_suffix(".in.vibe") {
      input_files.push(path)
    }
  }
  wbtest_sort_strings(input_files)
  if input_files.length() == 0 {
    fail("[\{fixture_dir}] no .in.vibe fixtures found")
  }
  for input_path in input_files {
    let output_path = wbtest_replace_suffix(input_path, ".in.vibe", ".out.vibe")
    if !@os_fs.path_exists(output_path) {
      fail("[\{input_path}] missing expected output fixture: \{output_path}")
    }
    let source = @os_fs.read_file_to_string(input_path) catch {
      e => fail("[\{input_path}] read failed: \{e.to_string()}")
    }
    let expected = @os_fs.read_file_to_string(output_path) catch {
      e => fail("[\{output_path}] read failed: \{e.to_string()}")
    }
    let actual = match normalize_source_text(source) {
      Ok(v) => v
      Err(msg) => fail("[\{input_path}] normalize failed: " + msg)
    }
    let actual_norm = wbtest_normalize_fixture_text(actual)
    let expected_norm = wbtest_normalize_fixture_text(expected)
    if actual_norm != expected_norm {
      fail(
        "[\{input_path}] normalize mismatch\n-- actual --\n\{actual_norm}\n-- expected --\n\{expected_norm}",
      )
    }
  }
}

///|
test "normalize fixtures has no stale output files" {
  let fixture_dir = "src/cmd/vibe/fixtures/normalize"
  let entries = @os_fs.read_dir(fixture_dir) catch {
    e => fail("[\{fixture_dir}] read_dir failed: \{e.to_string()}")
  }
  let stale_outputs : Array[String] = []
  for entry in entries {
    let path = if entry.has_prefix(fixture_dir) {
      entry
    } else {
      fixture_dir + "/" + entry
    }
    let is_file = @os_fs.is_file(path) catch {
      e => fail("[\{fixture_dir}] stat failed: \{e.to_string()}")
    }
    if !is_file || !path.has_suffix(".out.vibe") {
      continue
    }
    let input_path = wbtest_replace_suffix(path, ".out.vibe", ".in.vibe")
    if !@os_fs.path_exists(input_path) {
      stale_outputs.push(path)
    }
  }
  wbtest_sort_strings(stale_outputs)
  if stale_outputs.length() > 0 {
    fail(
      "[\{fixture_dir}] stale .out.vibe fixtures found: \{stale_outputs.to_string()}",
    )
  }
}

///|
test "collect vibe files recursive skips .vibe internal directories" {
  let root = wbtest_make_temp_dir("collect_vibe_files_skip_internal")
  let pkg_dir = root + "/pkg"
  @os_fs.create_dir(pkg_dir) catch {
    e => fail("create pkg dir failed: " + e.to_string())
  }
  @os_fs.write_string_to_file(pkg_dir + "/main.vibe", "let x = 1") catch {
    e => fail("write main failed: " + e.to_string())
  }

  let internal_root = pkg_dir + "/.vibe"
  @os_fs.create_dir(internal_root) catch {
    e => fail("create internal root failed: " + e.to_string())
  }
  let objects_dir = internal_root + "/objects"
  @os_fs.create_dir(objects_dir) catch {
    e => fail("create objects dir failed: " + e.to_string())
  }
  let blob_dir = objects_dir + "/ab"
  @os_fs.create_dir(blob_dir) catch {
    e => fail("create blob dir failed: " + e.to_string())
  }
  let internal_vibe = blob_dir + "/blob.vibe"
  @os_fs.write_string_to_file(internal_vibe, "let should_skip = true") catch {
    e => fail("write internal blob failed: " + e.to_string())
  }

  let files = wbtest_collect_vibe_files_recursive(pkg_dir)
  assert_true(wbtest_contains(files, pkg_dir + "/main.vibe"))
  assert_false(wbtest_contains(files, internal_vibe))

  wbtest_remove_if_exists(root)
}

///|
test "ensure_parent_dir_for_file creates nested directories" {
  let root = wbtest_make_temp_dir("ensure_parent_nested")
  let target = root + "/nested/dir/.vibe/namespaces/scratch.db"
  match ensure_parent_dir_for_file(target, "scratch-db") {
    Ok(_) => ()
    Err(err) => fail("expected mkdir success: " + err)
  }
  let parent = @vibe_fs.parent_path(target)
  assert_true(@os_fs.path_exists(parent))
  let is_dir = @os_fs.is_dir(parent) catch {
    e => fail("is_dir failed: " + e.to_string())
  }
  assert_true(is_dir)
  wbtest_remove_if_exists(root)
}

///|
test "ensure_parent_dir_for_file resolves relative target from current directory" {
  let cwd = @io.current_dir_or_root()
  let rel_root = "tmp_probe/wbtest_relative_parent_dir"
  let rel_target = rel_root + "/nested/export.vibe"
  let expected_parent = @vibe_fs.normalize_path(
    cwd + "/" + rel_root + "/nested",
  )
  wbtest_remove_if_exists(@vibe_fs.normalize_path(cwd + "/" + rel_root))
  match ensure_parent_dir_for_file(rel_target, "scratch-db") {
    Ok(_) => ()
    Err(err) => fail("expected relative mkdir success: " + err)
  }
  assert_true(@os_fs.path_exists(expected_parent))
  wbtest_remove_if_exists(@vibe_fs.normalize_path(cwd + "/" + rel_root))
}

///|
test "ensure_parent_dir_for_file errors when parent path is file" {
  let root = wbtest_make_temp_dir("ensure_parent_parent_file")
  let parent_file = root + "/nested"
  @os_fs.write_string_to_file(parent_file, "x") catch {
    e => fail("write failed: " + e.to_string())
  }
  let target = parent_file + "/child/out.vibe"
  match ensure_parent_dir_for_file(target, "scratch-db") {
    Ok(_) => fail("expected mkdir error")
    Err(err) => {
      assert_true(err.contains("scratch-db:"))
      assert_true(err.contains("not directory"))
    }
  }
  wbtest_remove_if_exists(root)
}

///|
test "split test entry path batches caps workers and balances paths" {
  let capped = split_test_entry_path_batches(["a.vibe", "b.vibe", "c.vibe"], 10)
  assert_eq(capped.length(), 3)
  @debug.assert_eq(capped[0], ["a.vibe"])
  @debug.assert_eq(capped[1], ["b.vibe"])
  @debug.assert_eq(capped[2], ["c.vibe"])

  let balanced = split_test_entry_path_batches(
    ["a.vibe", "b.vibe", "c.vibe", "d.vibe", "e.vibe"],
    2,
  )
  assert_eq(balanced.length(), 2)
  @debug.assert_eq(balanced[0], ["a.vibe", "b.vibe", "c.vibe"])
  @debug.assert_eq(balanced[1], ["d.vibe", "e.vibe"])
}

///|
test "split test entry path batches keeps sibling files in same worker chunk" {
  let grouped = split_test_entry_path_batches(
    [
      "vibe/prelude/a_test.vibe", "vibe/fs/a_test.vibe", "vibe/prelude/b_test.vibe",
      "vibe/fs/b_test.vibe",
    ],
    2,
  )
  assert_eq(grouped.length(), 2)
  let builtin_group = ["vibe/prelude/a_test.vibe", "vibe/prelude/b_test.vibe"]
  let fs_group = ["vibe/fs/a_test.vibe", "vibe/fs/b_test.vibe"]
  let first_is_builtin = grouped[0] == builtin_group
  let second_is_builtin = grouped[1] == builtin_group
  assert_true(first_is_builtin || second_is_builtin)
  let first_is_fs = grouped[0] == fs_group
  let second_is_fs = grouped[1] == fs_group
  assert_true(first_is_fs || second_is_fs)
}

///|
test "split test entry path batches with weights keeps same root on same worker when possible" {
  let base = wbtest_make_temp_dir("path_batch_root_affinity")
  let root_a = base + "/root_a"
  let root_b = base + "/root_b"
  let root_a_vibe = root_a + "/vibe"
  let root_b_vibe = root_b + "/vibe"
  let root_a_compiler = root_a_vibe + "/compiler"
  let root_a_prelude = root_a_vibe + "/prelude"
  let root_a_json = root_a_vibe + "/json"
  let root_b_compiler = root_b_vibe + "/compiler"
  let root_b_prelude = root_b_vibe + "/prelude"
  let root_b_json = root_b_vibe + "/json"
  let a1 = root_a_compiler + "/a_test.vibe"
  let a2 = root_a_json + "/b_test.vibe"
  let b1 = root_b_compiler + "/c_test.vibe"
  let b2 = root_b_json + "/d_test.vibe"
  @os_fs.create_dir(root_a) catch {
    e => fail(e.to_string())
  }
  @os_fs.create_dir(root_b) catch {
    e => fail(e.to_string())
  }
  @os_fs.create_dir(root_a_vibe) catch {
    e => fail(e.to_string())
  }
  @os_fs.create_dir(root_b_vibe) catch {
    e => fail(e.to_string())
  }
  @os_fs.create_dir(root_a_compiler) catch {
    e => fail(e.to_string())
  }
  @os_fs.create_dir(root_a_prelude) catch {
    e => fail(e.to_string())
  }
  @os_fs.create_dir(root_a_json) catch {
    e => fail(e.to_string())
  }
  @os_fs.create_dir(root_b_compiler) catch {
    e => fail(e.to_string())
  }
  @os_fs.create_dir(root_b_prelude) catch {
    e => fail(e.to_string())
  }
  @os_fs.create_dir(root_b_json) catch {
    e => fail(e.to_string())
  }
  @os_fs.write_string_to_file(
    root_a_compiler + "/index.vibe",
    "export let version = \"0.1.0\"\n",
  ) catch {
    e => fail(e.to_string())
  }
  @os_fs.write_string_to_file(
    root_b_compiler + "/index.vibe",
    "export let version = \"0.1.0\"\n",
  ) catch {
    e => fail(e.to_string())
  }
  @os_fs.write_string_to_file(
    root_a_prelude + "/index.vibe",
    "export let version = \"0.1.0\"\n",
  ) catch {
    e => fail(e.to_string())
  }
  @os_fs.write_string_to_file(
    root_a_json + "/index.vibe",
    "export let version = \"0.1.0\"\n",
  ) catch {
    e => fail(e.to_string())
  }
  @os_fs.write_string_to_file(
    root_b_prelude + "/index.vibe",
    "export let version = \"0.1.0\"\n",
  ) catch {
    e => fail(e.to_string())
  }
  @os_fs.write_string_to_file(
    root_b_json + "/index.vibe",
    "export let version = \"0.1.0\"\n",
  ) catch {
    e => fail(e.to_string())
  }
  @os_fs.write_string_to_file(a1, "") catch {
    e => fail(e.to_string())
  }
  @os_fs.write_string_to_file(a2, "") catch {
    e => fail(e.to_string())
  }
  @os_fs.write_string_to_file(b1, "") catch {
    e => fail(e.to_string())
  }
  @os_fs.write_string_to_file(b2, "") catch {
    e => fail(e.to_string())
  }

  let grouped = split_test_entry_path_batches_with_weights(
    [a1, a2, b1, b2],
    2,
    {},
  )
  assert_eq(grouped.length(), 2)
  let batch0_has_a = wbtest_contains(grouped[0], a1) ||
    wbtest_contains(grouped[0], a2)
  let batch0_has_b = wbtest_contains(grouped[0], b1) ||
    wbtest_contains(grouped[0], b2)
  let batch1_has_a = wbtest_contains(grouped[1], a1) ||
    wbtest_contains(grouped[1], a2)
  let batch1_has_b = wbtest_contains(grouped[1], b1) ||
    wbtest_contains(grouped[1], b2)
  assert_false(batch0_has_a && batch0_has_b)
  assert_false(batch1_has_a && batch1_has_b)

  wbtest_remove_if_exists(a1)
  wbtest_remove_if_exists(a2)
  wbtest_remove_if_exists(b1)
  wbtest_remove_if_exists(b2)
  wbtest_remove_if_exists(root_a_compiler + "/index.vibe")
  wbtest_remove_if_exists(root_b_compiler + "/index.vibe")
  wbtest_remove_if_exists(root_a_prelude + "/index.vibe")
  wbtest_remove_if_exists(root_b_prelude + "/index.vibe")
  wbtest_remove_if_exists(root_a_json + "/index.vibe")
  wbtest_remove_if_exists(root_b_json + "/index.vibe")
  wbtest_remove_if_exists(root_a_compiler)
  wbtest_remove_if_exists(root_a_prelude)
  wbtest_remove_if_exists(root_a_json)
  wbtest_remove_if_exists(root_b_compiler)
  wbtest_remove_if_exists(root_b_prelude)
  wbtest_remove_if_exists(root_b_json)
  wbtest_remove_if_exists(root_a_vibe)
  wbtest_remove_if_exists(root_b_vibe)
  wbtest_remove_if_exists(root_a)
  wbtest_remove_if_exists(root_b)
  wbtest_remove_if_exists(base)
}

///|
test "split test entry path batches with weights isolates heavy module first" {
  let weights : Map[String, Int] = {}
  weights["vibe/heavy/a_test.vibe"] = 100
  weights["vibe/light/b_test.vibe"] = 1
  weights["vibe/light/c_test.vibe"] = 1
  let grouped = split_test_entry_path_batches_with_weights(
    [
      "vibe/heavy/a_test.vibe", "vibe/light/b_test.vibe", "vibe/light/c_test.vibe",
    ],
    2,
    weights,
  )
  assert_eq(grouped.length(), 2)
  let heavy_isolated = grouped[0] == ["vibe/heavy/a_test.vibe"] ||
    grouped[1] == ["vibe/heavy/a_test.vibe"]
  assert_true(heavy_isolated)
}

///|
test "split test entry task batches with weights caps large sibling chunks" {
  let grouped = split_test_entry_task_batches_with_weights(
    [
      "vibe/compiler/a_test.vibe", "vibe/compiler/b_test.vibe", "vibe/compiler/c_test.vibe",
      "vibe/compiler/d_test.vibe", "vibe/compiler/e_test.vibe", "vibe/compiler/f_test.vibe",
      "vibe/compiler/g_test.vibe", "vibe/compiler/h_test.vibe", "vibe/compiler/i_test.vibe",
      "vibe/compiler/j_test.vibe",
    ],
    2,
    {},
  )
  assert_eq(grouped.length(), 2)
  assert_eq(grouped[0].length() + grouped[1].length(), 10)
}

///|
test "split test entry task batches with weights uses file granularity" {
  let weights : Map[String, Int] = {}
  weights["vibe/compiler/a_test.vibe"] = 10
  weights["vibe/compiler/b_test.vibe"] = 20
  weights["vibe/compiler/c_test.vibe"] = 30
  let grouped = split_test_entry_task_batches_with_weights(
    [
      "vibe/compiler/a_test.vibe", "vibe/compiler/b_test.vibe", "vibe/compiler/c_test.vibe",
    ],
    2,
    weights,
  )
  assert_eq(grouped.length(), 2)
  assert_eq(grouped[0].length() + grouped[1].length(), 3)
  let isolated_heavy = grouped[0] == ["vibe/compiler/c_test.vibe"] ||
    grouped[1] == ["vibe/compiler/c_test.vibe"]
  assert_true(isolated_heavy)
}

///|
test "test entry batch env chunk size accepts positive int only" {
  let prev = @sys.get_env_var("VIBE_TEST_BATCH_CHUNK_SIZE")
  defer wbtest_restore_env_var("VIBE_TEST_BATCH_CHUNK_SIZE", prev)
  @sys.unset_env_var("VIBE_TEST_BATCH_CHUNK_SIZE")
  @debug.assert_eq(test_entry_batch_env_chunk_size(), None)
  @sys.set_env_var("VIBE_TEST_BATCH_CHUNK_SIZE", "3")
  @debug.assert_eq(test_entry_batch_env_chunk_size(), Some(3))
  @sys.set_env_var("VIBE_TEST_BATCH_CHUNK_SIZE", "0")
  @debug.assert_eq(test_entry_batch_env_chunk_size(), None)
  @sys.set_env_var("VIBE_TEST_BATCH_CHUNK_SIZE", "bad")
  @debug.assert_eq(test_entry_batch_env_chunk_size(), None)
}

///|
test "split test entry task batches with weights respects env chunk size" {
  let prev = @sys.get_env_var("VIBE_TEST_BATCH_CHUNK_SIZE")
  defer wbtest_restore_env_var("VIBE_TEST_BATCH_CHUNK_SIZE", prev)
  @sys.set_env_var("VIBE_TEST_BATCH_CHUNK_SIZE", "2")
  let weights : Map[String, Int] = {}
  weights["vibe/compiler/a_test.vibe"] = 10
  weights["vibe/compiler/b_test.vibe"] = 20
  weights["vibe/compiler/c_test.vibe"] = 30
  let grouped = split_test_entry_task_batches_with_weights(
    [
      "vibe/compiler/a_test.vibe", "vibe/compiler/b_test.vibe", "vibe/compiler/c_test.vibe",
    ],
    2,
    weights,
  )
  assert_eq(grouped.length(), 2)
  assert_eq(grouped[0].length() + grouped[1].length(), 3)
}

///|
test "split test entry task batches keeps heavy weighted files isolated" {
  let prev = @sys.get_env_var("VIBE_TEST_BATCH_CHUNK_SIZE")
  defer wbtest_restore_env_var("VIBE_TEST_BATCH_CHUNK_SIZE", prev)
  @sys.set_env_var("VIBE_TEST_BATCH_CHUNK_SIZE", "4")
  let weights : Map[String, Int] = {}
  weights["vibe/compiler/a_test.vibe"] = 100
  weights["vibe/compiler/b_test.vibe"] = 90
  weights["vibe/compiler/c_test.vibe"] = 10
  weights["vibe/compiler/d_test.vibe"] = 10
  let grouped = split_test_entry_task_batches_with_weights(
    [
      "vibe/compiler/a_test.vibe", "vibe/compiler/b_test.vibe", "vibe/compiler/c_test.vibe",
      "vibe/compiler/d_test.vibe",
    ],
    2,
    weights,
  )
  assert_eq(grouped.length(), 2)
  assert_eq(grouped[0].length() + grouped[1].length(), 4)
  for batch in grouped {
    assert_eq(
      batch.contains("vibe/compiler/a_test.vibe") &&
      batch.contains("vibe/compiler/b_test.vibe"),
      false,
    )
  }
}

///|
test "split test entry task batches with weights keeps same root on same worker when possible" {
  let base = wbtest_make_temp_dir("test_batch_root_affinity")
  let root_a = base + "/root_a"
  let root_b = base + "/root_b"
  let root_a_vibe = root_a + "/vibe"
  let root_b_vibe = root_b + "/vibe"
  let root_a_compiler = root_a_vibe + "/compiler"
  let root_a_prelude = root_a_vibe + "/prelude"
  let root_a_json = root_a_vibe + "/json"
  let root_b_compiler = root_b_vibe + "/compiler"
  let root_b_prelude = root_b_vibe + "/prelude"
  let root_b_json = root_b_vibe + "/json"
  let a1 = root_a_compiler + "/a_test.vibe"
  let a2 = root_a_json + "/b_test.vibe"
  let b1 = root_b_compiler + "/c_test.vibe"
  let b2 = root_b_json + "/d_test.vibe"
  @os_fs.create_dir(root_a) catch {
    e => fail(e.to_string())
  }
  @os_fs.create_dir(root_b) catch {
    e => fail(e.to_string())
  }
  @os_fs.create_dir(root_a_vibe) catch {
    e => fail(e.to_string())
  }
  @os_fs.create_dir(root_b_vibe) catch {
    e => fail(e.to_string())
  }
  @os_fs.create_dir(root_a_compiler) catch {
    e => fail(e.to_string())
  }
  @os_fs.create_dir(root_a_prelude) catch {
    e => fail(e.to_string())
  }
  @os_fs.create_dir(root_a_json) catch {
    e => fail(e.to_string())
  }
  @os_fs.create_dir(root_b_compiler) catch {
    e => fail(e.to_string())
  }
  @os_fs.create_dir(root_b_prelude) catch {
    e => fail(e.to_string())
  }
  @os_fs.create_dir(root_b_json) catch {
    e => fail(e.to_string())
  }
  @os_fs.write_string_to_file(
    root_a_compiler + "/index.vibe",
    "export let version = \"0.1.0\"\n",
  ) catch {
    e => fail(e.to_string())
  }
  @os_fs.write_string_to_file(
    root_b_compiler + "/index.vibe",
    "export let version = \"0.1.0\"\n",
  ) catch {
    e => fail(e.to_string())
  }
  @os_fs.write_string_to_file(
    root_a_prelude + "/index.vibe",
    "export let version = \"0.1.0\"\n",
  ) catch {
    e => fail(e.to_string())
  }
  @os_fs.write_string_to_file(
    root_a_json + "/index.vibe",
    "export let version = \"0.1.0\"\n",
  ) catch {
    e => fail(e.to_string())
  }
  @os_fs.write_string_to_file(
    root_b_prelude + "/index.vibe",
    "export let version = \"0.1.0\"\n",
  ) catch {
    e => fail(e.to_string())
  }
  @os_fs.write_string_to_file(
    root_b_json + "/index.vibe",
    "export let version = \"0.1.0\"\n",
  ) catch {
    e => fail(e.to_string())
  }
  @os_fs.write_string_to_file(a1, "") catch {
    e => fail(e.to_string())
  }
  @os_fs.write_string_to_file(a2, "") catch {
    e => fail(e.to_string())
  }
  @os_fs.write_string_to_file(b1, "") catch {
    e => fail(e.to_string())
  }
  @os_fs.write_string_to_file(b2, "") catch {
    e => fail(e.to_string())
  }

  let grouped = split_test_entry_task_batches_with_weights(
    [a1, a2, b1, b2],
    2,
    {},
  )
  assert_eq(grouped.length(), 2)
  let batch0_has_a = wbtest_contains(grouped[0], a1) ||
    wbtest_contains(grouped[0], a2)
  let batch0_has_b = wbtest_contains(grouped[0], b1) ||
    wbtest_contains(grouped[0], b2)
  let batch1_has_a = wbtest_contains(grouped[1], a1) ||
    wbtest_contains(grouped[1], a2)
  let batch1_has_b = wbtest_contains(grouped[1], b1) ||
    wbtest_contains(grouped[1], b2)
  assert_false(batch0_has_a && batch0_has_b)
  assert_false(batch1_has_a && batch1_has_b)

  wbtest_remove_if_exists(a1)
  wbtest_remove_if_exists(a2)
  wbtest_remove_if_exists(b1)
  wbtest_remove_if_exists(b2)
  wbtest_remove_if_exists(root_a_compiler + "/index.vibe")
  wbtest_remove_if_exists(root_b_compiler + "/index.vibe")
  wbtest_remove_if_exists(root_a_prelude + "/index.vibe")
  wbtest_remove_if_exists(root_b_prelude + "/index.vibe")
  wbtest_remove_if_exists(root_a_json + "/index.vibe")
  wbtest_remove_if_exists(root_b_json + "/index.vibe")
  wbtest_remove_if_exists(root_a_compiler)
  wbtest_remove_if_exists(root_a_prelude)
  wbtest_remove_if_exists(root_a_json)
  wbtest_remove_if_exists(root_b_compiler)
  wbtest_remove_if_exists(root_b_prelude)
  wbtest_remove_if_exists(root_b_json)
  wbtest_remove_if_exists(root_a_vibe)
  wbtest_remove_if_exists(root_b_vibe)
  wbtest_remove_if_exists(root_a)
  wbtest_remove_if_exists(root_b)
  wbtest_remove_if_exists(base)
}

///|
test "test batch weight cache key relativizes cwd absolute path" {
  let cwd = @io.current_dir_or_root()
  let abs = @vibe_fs.normalize_path(cwd + "/vibe/compiler/fixture_test.vibe")
  if @vibe_fs.normalize_path(cwd).has_prefix("/") {
    assert_eq(
      test_batch_weight_cache_key(abs),
      "vibe/compiler/fixture_test.vibe",
    )
  } else {
    assert_eq(test_batch_weight_cache_key(abs), abs)
  }
  assert_eq(
    test_batch_weight_cache_key("vibe/compiler/fixture_test.vibe"),
    "vibe/compiler/fixture_test.vibe",
  )
}

///|
test "find json lines extracts all object-looking lines" {
  let output =
    #|log: start
    #|{"file":"a.vibe","total":1}
    #|
    #|warn: skip
    #|{"file":"b.vibe","total":2}
    #|done
  let lines = find_json_lines(output)
  assert_eq(lines.length(), 2)
  assert_eq(lines[0], "{\"file\":\"a.vibe\",\"total\":1}")
  assert_eq(lines[1], "{\"file\":\"b.vibe\",\"total\":2}")
}

///|
test "decode process output lossy keeps later json lines" {
  let prefix = Bytes::from_array([b'\xff', b'\n'])
  let json = @utf8.encode("{\"file\":\"a.vibe\",\"total\":1}\n")
  let text = decode_process_output_lossy(prefix + json)
  let lines = find_json_lines(text)
  assert_eq(lines.length(), 1)
  assert_eq(lines[0], "{\"file\":\"a.vibe\",\"total\":1}")
}

///|
test "default test jobs uses safe fallback when env is unset" {
  let prev = @sys.get_env_var("VIBE_TEST_JOBS")
  @sys.unset_env_var("VIBE_TEST_JOBS")
  defer wbtest_restore_env_var("VIBE_TEST_JOBS", prev)
  assert_eq(default_test_jobs(), 1)
}

///|
test "default test jobs accepts env override and rejects invalid values" {
  let prev = @sys.get_env_var("VIBE_TEST_JOBS")
  defer wbtest_restore_env_var("VIBE_TEST_JOBS", prev)

  @sys.set_env_var("VIBE_TEST_JOBS", "3")
  assert_eq(default_test_jobs(), 3)

  @sys.set_env_var("VIBE_TEST_JOBS", "invalid")
  assert_eq(default_test_jobs(), 1)
}

///|
test "normalize test jobs clamps extreme values" {
  let prev = @sys.get_env_var("VIBE_TEST_JOBS")
  @sys.unset_env_var("VIBE_TEST_JOBS")
  defer wbtest_restore_env_var("VIBE_TEST_JOBS", prev)

  assert_eq(normalize_test_jobs(-1), 1)
  assert_eq(normalize_test_jobs(1), 1)
  assert_eq(normalize_test_jobs(64), 16)
}

///|
test "test worker parent pid parses env value safely" {
  let prev_generic = @sys.get_env_var("VIBE_INTERNAL_PARENT_PID")
  let prev = @sys.get_env_var("VIBE_INTERNAL_TEST_PARENT_PID")
  defer wbtest_restore_env_var("VIBE_INTERNAL_PARENT_PID", prev_generic)
  defer wbtest_restore_env_var("VIBE_INTERNAL_TEST_PARENT_PID", prev)

  @sys.unset_env_var("VIBE_INTERNAL_PARENT_PID")
  @sys.unset_env_var("VIBE_INTERNAL_TEST_PARENT_PID")
  @debug.assert_eq(test_worker_parent_pid(), None)

  @sys.set_env_var("VIBE_INTERNAL_PARENT_PID", "invalid")
  @debug.assert_eq(test_worker_parent_pid(), None)

  @sys.unset_env_var("VIBE_INTERNAL_PARENT_PID")
  @sys.set_env_var("VIBE_INTERNAL_TEST_PARENT_PID", "invalid")
  @debug.assert_eq(test_worker_parent_pid(), None)

  let pid = vibe_getpid()
  @sys.set_env_var("VIBE_INTERNAL_PARENT_PID", pid.to_string())
  @debug.assert_eq(test_worker_parent_pid(), Some(pid))

  @sys.unset_env_var("VIBE_INTERNAL_PARENT_PID")
  @sys.set_env_var("VIBE_INTERNAL_TEST_PARENT_PID", pid.to_string())
  @debug.assert_eq(test_worker_parent_pid(), Some(pid))
}

///|
test "report json worker exits only when tracked parent is gone" {
  let pid = vibe_getpid()
  assert_eq(should_exit_report_json_worker(None), false)
  assert_eq(should_exit_report_json_worker(Some(pid)), false)
}

///|
test "compiled test case db load does not persist temporary lock refs" {
  let root = wbtest_make_temp_dir("compiled_test_case_db_lock")
  let lock_seed = "{\"path\":{},\"version\":{},\"symbol\":{},\"module\":{},\"annotation\":{}}\n"
  @os_fs.write_string_to_file(root + "/index.lock", lock_seed) catch {
    e => fail("write seed lock failed: " + e.to_string())
  }
  @os_fs.write_string_to_file(
    root + "/index.vibe",
    "export let version = \"0.1.0\"\n",
  ) catch {
    e => fail("write index.vibe failed: " + e.to_string())
  }
  let source_path = root + "/.vibe_test_wasm_case.vibe"
  @os_fs.write_string_to_file(source_path, "0\n") catch {
    e => fail("write temp source failed: " + e.to_string())
  }
  match wbtest_load_compiled_test_case_db(source_path) {
    Ok(_) => ()
    Err(err) => fail("load compiled test db failed: " + err)
  }
  let lock_path = root + "/index.lock"
  if @os_fs.path_exists(lock_path) {
    let lock_source = @os_fs.read_file_to_string(lock_path) catch {
      e => fail("read lock failed: " + e.to_string())
    }
    assert_false(lock_source.contains(".vibe_test_wasm_"))
  }
  wbtest_remove_if_exists(lock_path)
  wbtest_remove_if_exists(source_path)
  wbtest_remove_if_exists(root)
}

///|
test "compiled test generated source path is stable per content" {
  let parent = "/tmp/compiled_test_generated_source_path"
  let path1 = compiled_test_generated_source_path(
    parent, "batch", "let x = 1\n",
  )
  let path2 = compiled_test_generated_source_path(
    parent, "batch", "let x = 1\n",
  )
  let path3 = compiled_test_generated_source_path(
    parent, "batch", "let x = 2\n",
  )
  assert_eq(path1, path2)
  assert_true(path1 != path3)
}

///|
test "compiled test case db load with cache reuses same root db" {
  let root = wbtest_make_temp_dir("compiled_test_case_db_cache")
  let lock_seed = "{\"path\":{},\"version\":{},\"symbol\":{},\"module\":{},\"annotation\":{}}\n"
  @os_fs.write_string_to_file(root + "/index.lock", lock_seed) catch {
    e => fail("write seed lock failed: " + e.to_string())
  }
  @os_fs.write_string_to_file(
    root + "/index.vibe",
    "export let version = \"0.1.0\"\n",
  ) catch {
    e => fail("write index.vibe failed: " + e.to_string())
  }
  let cache = CliEntryDbCache::new()
  let source1 = "0\n"
  let source2 = "1\n"
  let path1 = compiled_test_generated_source_path(root, "case", source1)
  let path2 = compiled_test_generated_source_path(root, "case", source2)
  match load_compiled_test_case_db_with_cache(cache, path1, source1) {
    Ok(_) => ()
    Err(err) => fail("load compiled test db with cache failed: " + err)
  }
  match load_compiled_test_case_db_with_cache(cache, path2, source2) {
    Ok(_) => ()
    Err(err) => fail("load compiled test db with cache failed: " + err)
  }
  assert_eq(cache.by_root.length(), 1)
  wbtest_remove_if_exists(path1)
  wbtest_remove_if_exists(path2)
  wbtest_remove_if_exists(root + "/index.lock")
  wbtest_remove_if_exists(root + "/index.vibe")
  wbtest_remove_if_exists(root)
}

///|
test "compiled test prelude omits wrapper conflict names" {
  let ast = @parser.parse_ast(
    "let main = 1\n" +
    "export let run = 2\n" +
    "let keep = 3\n" +
    "let __vibe_compiled_test_case = 4\n" +
    "export { main, keep }\n",
  ) catch {
    e => fail("parse failed: " + e.to_string())
  }
  assert_true(should_omit_compiled_test_prelude_stmt(ast.stmts[0]))
  assert_true(should_omit_compiled_test_prelude_stmt(ast.stmts[1]))
  assert_false(should_omit_compiled_test_prelude_stmt(ast.stmts[2]))
  assert_true(should_omit_compiled_test_prelude_stmt(ast.stmts[3]))
  assert_true(should_omit_compiled_test_prelude_stmt(ast.stmts[4]))
}

///|
test "compiled test prelude moves plain lets into wrapper" {
  let ast = @parser.parse_ast(
    "import ./dep.vibe { helper }\n" +
    "let base = 1\n" +
    "let derived = helper(base)\n" +
    "export let kept = helper\n",
  ) catch {
    e => fail("parse failed: " + e.to_string())
  }
  assert_false(compiled_test_prelude_stmt_runs_in_wrapper(ast.stmts[0]))
  assert_true(compiled_test_prelude_stmt_runs_in_wrapper(ast.stmts[1]))
  assert_true(compiled_test_prelude_stmt_runs_in_wrapper(ast.stmts[2]))
  assert_false(compiled_test_prelude_stmt_runs_in_wrapper(ast.stmts[3]))
}

///|
test "compiled test case source omits example main binding" {
  let source = @os_fs.read_file_to_string("examples/perform_handle.vibe") catch {
    e => fail("read example failed: " + e.to_string())
  }
  let ast = @parser.parse_ast(source) catch {
    e => fail("parse example failed: " + e.to_string())
  }
  let top_level_stmts : Array[@vibe_core.Stmt] = []
  let wrapper_prelude_stmts : Array[@vibe_core.Stmt] = []
  for stmt in ast.stmts {
    match stmt {
      @vibe_core.Stmt::Test(..) | @vibe_core.Stmt::Bench(..) => ()
      _ =>
        if !should_omit_compiled_test_prelude_stmt(stmt) {
          if compiled_test_prelude_stmt_runs_in_wrapper(stmt) {
            wrapper_prelude_stmts.push(stmt)
          } else {
            top_level_stmts.push(stmt)
          }
        }
    }
  }
  let top_level_source = render_stmt_snippets(source, top_level_stmts)
  let wrapper_prelude_source = render_stmt_snippets(
    source, wrapper_prelude_stmts,
  )
  assert_false(top_level_source.contains("let main ="))
  assert_false(wrapper_prelude_source.contains("let main ="))
  let cases = collect_compiled_test_cases(ast)
  let case_source = build_compiled_test_case_source(
    top_level_source,
    wrapper_prelude_source,
    render_stmt_snippets(source, cases[0].body.stmts),
  )
  assert_false(case_source.contains("let main ="))
}

///|
test "compiled test case source keeps imported run visible in body" {
  let case_source = build_compiled_test_case_source(
    "import ./string_parser.vibe { run }\n", "", "let _ = run\n",
  )
  assert_true(case_source.contains("let __vibe_compiled_test_case = () -> Int"))
  assert_true(case_source.contains("__vibe_compiled_test_case()"))
  assert_true(case_source.contains("let _ = run"))
  assert_false(case_source.contains("let run = () -> Int"))
}

///|
test "compiled test wrapper executes top-level computed let bindings" {
  let cwd = @io.current_dir_or_root()
  let rel_path = "tmp_probe/wbtest_compiled_top_level_computed.vibe"
  let source_path = @vibe_fs.normalize_path(cwd + "/" + rel_path)
  wbtest_remove_if_exists(source_path)
  match ensure_parent_dir_for_file(source_path, "compiled-test-wbtest") {
    Ok(_) => ()
    Err(err) => fail("create temp source dir failed: " + err)
  }
  @os_fs.write_string_to_file(
    source_path,
    "let base = \"he\"\n" +
    "let text = String::concat(base, \"llo\")\n" +
    "test \"computed string let\" {\n" +
    "  assert(String::equals(text, \"hello\"))\n" +
    "}\n",
  ) catch {
    e => fail("write temp source failed: " + e.to_string())
  }
  match wbtest_run_test_file_compiled(source_path, false) {
    CompiledTestAttempt::Success(report) => {
      assert_eq(report.total, 1)
      if report.passed != 1 || report.failed != 0 {
        fail("unexpected compiled report: " + report.to_string())
      }
    }
    CompiledTestAttempt::Unsupported(err) =>
      fail("compiled test unexpectedly unsupported: " + err)
    CompiledTestAttempt::Error(err) =>
      fail("compiled test unexpectedly errored: " + err)
  }
  wbtest_remove_if_exists(source_path)
}

///|
test "compiled test wrapper executes closure-captured string condition" {
  let cwd = @io.current_dir_or_root()
  let source_path = @vibe_fs.normalize_path(
    cwd + "/.wbtest_compiled_closure_captured_string_eq.vibe",
  )
  wbtest_remove_if_exists(source_path)
  match ensure_parent_dir_for_file(source_path, "compiled-test-wbtest") {
    Ok(_) => ()
    Err(err) => fail("create temp source dir failed: " + err)
  }
  @os_fs.write_string_to_file(
    source_path,
    "let mk = (expected: String) -> ((String, Int) -> Int) {\n" +
    "  (input: String, pos: Int) -> Int {\n" +
    "    let got = String::substring(input, pos, pos + 1)\n" +
    "    if got == expected { 1 } else { 0 }\n" +
    "  }\n" +
    "}\n" +
    "let p = mk(\"a\")\n" +
    "test \"closure captured string eq\" {\n" +
    "  assert(p(\"a\", 0) == 1)\n" +
    "}\n",
  ) catch {
    e => fail("write temp source failed: " + e.to_string())
  }
  match wbtest_run_test_file_compiled(source_path, false) {
    CompiledTestAttempt::Success(report) => {
      assert_eq(report.total, 1)
      if report.passed != 1 || report.failed != 0 {
        fail("unexpected compiled report: " + report.to_string())
      }
    }
    CompiledTestAttempt::Unsupported(err) =>
      fail("compiled test unexpectedly unsupported: " + err)
    CompiledTestAttempt::Error(err) =>
      fail("compiled test unexpectedly errored: " + err)
  }
  wbtest_remove_if_exists(source_path)
}

///|
test "compiled test wrapper supports paren string interpolation syntax" {
  let cwd = @io.current_dir_or_root()
  let source_path = @vibe_fs.normalize_path(
    cwd + "/.wbtest_compiled_string_interp_paren.vibe",
  )
  wbtest_remove_if_exists(source_path)
  match ensure_parent_dir_for_file(source_path, "compiled-test-wbtest") {
    Ok(_) => ()
    Err(err) => fail("create temp source dir failed: " + err)
  }
  @os_fs.write_string_to_file(
    source_path,
    "let name = \"vibe\"\n" +
    "let msg = \"hello \\(name)\"\n" +
    "test \"paren string interpolation\" {\n" +
    "  assert(msg == \"hello vibe\")\n" +
    "  assert(String::length(msg) == 10)\n" +
    "}\n",
  ) catch {
    e => fail("write temp source failed: " + e.to_string())
  }
  match wbtest_run_test_file_compiled(source_path, false) {
    CompiledTestAttempt::Success(report) => {
      assert_eq(report.total, 1)
      if report.passed != 1 || report.failed != 0 {
        fail("unexpected compiled report: " + report.to_string())
      }
    }
    CompiledTestAttempt::Unsupported(err) =>
      fail("compiled test unexpectedly unsupported: " + err)
    CompiledTestAttempt::Error(err) =>
      fail("compiled test unexpectedly errored: " + err)
  }
  wbtest_remove_if_exists(source_path)
}

///|
test "compiled test wrapper executes imported let aliases" {
  let cwd = @io.current_dir_or_root()
  let source_path = @vibe_fs.normalize_path(
    cwd + "/.wbtest_compiled_option_alias.vibe",
  )
  wbtest_remove_if_exists(source_path)
  match ensure_parent_dir_for_file(source_path, "compiled-test-wbtest") {
    Ok(_) => ()
    Err(err) => fail("create temp source dir failed: " + err)
  }
  @os_fs.write_string_to_file(
    source_path,
    "import ./vibe/prelude/option.vibe { or, is_some }\n" +
    "let option_or = or\n" +
    "let option_is_some = is_some\n" +
    "test \"option alias\" {\n" +
    "  assert(option_is_some(option_or(Some(1), Some(2))))\n" +
    "}\n",
  ) catch {
    e => fail("write temp source failed: " + e.to_string())
  }
  match wbtest_run_test_file_compiled(source_path, false) {
    CompiledTestAttempt::Success(report) => {
      assert_eq(report.total, 1)
      assert_eq(report.passed, 1)
      assert_eq(report.failed, 0)
    }
    CompiledTestAttempt::Unsupported(err) =>
      fail("compiled option alias unexpectedly unsupported: " + err)
    CompiledTestAttempt::Error(err) =>
      fail("compiled option alias unexpectedly errored: " + err)
  }
  wbtest_remove_if_exists(source_path)
}

///|
test "compiled test wrapper keeps higher-order imported aliases valid" {
  let cwd = @io.current_dir_or_root()
  let source_path = @vibe_fs.normalize_path(
    cwd + "/.wbtest_compiled_option_hof_aliases.vibe",
  )
  wbtest_remove_if_exists(source_path)
  match ensure_parent_dir_for_file(source_path, "compiled-test-wbtest") {
    Ok(_) => ()
    Err(err) => fail("create temp source dir failed: " + err)
  }
  @os_fs.write_string_to_file(
    source_path,
    "import ./vibe/prelude/option.vibe {\n" +
    "  Eq, Option, and, equals, filter, flatmap, flatten, is_none, is_some, map_opt, map_or, or, or_else, unwrap_or, unwrap_or_else, zip, zip_sum\n" +
    "}\n" +
    "let option_or = or\n" +
    "let option_and = and\n" +
    "let option_map = map_opt\n" +
    "let option_zip = zip\n" +
    "let option_equals = equals\n" +
    "let option_filter = filter\n" +
    "let option_map_or = map_or\n" +
    "let option_flatmap = flatmap\n" +
    "let option_flatten = flatten\n" +
    "let option_is_none = is_none\n" +
    "let option_is_some = is_some\n" +
    "let option_or_else = or_else\n" +
    "let option_unwrap_or = unwrap_or\n" +
    "let option_unwrap_or_else = unwrap_or_else\n" +
    "test \"option alias table\" {\n" +
    "  assert(option_is_some(Some(42)))\n" +
    "  assert(option_is_none(None))\n" +
    "}\n",
  ) catch {
    e => fail("write temp source failed: " + e.to_string())
  }
  match wbtest_run_test_file_compiled(source_path, false) {
    CompiledTestAttempt::Success(report) => {
      assert_eq(report.total, 1)
      assert_eq(report.passed, 1)
      assert_eq(report.failed, 0)
    }
    CompiledTestAttempt::Unsupported(err) =>
      fail("compiled option alias unexpectedly unsupported: " + err)
    CompiledTestAttempt::Error(err) =>
      fail("compiled option alias unexpectedly errored: " + err)
  }
  wbtest_remove_if_exists(source_path)
}

///|
test "compiled test wrapper keeps export helper chain top-level" {
  let cwd = @io.current_dir_or_root()
  let source_path = @vibe_fs.normalize_path(
    cwd + "/.wbtest_compiled_export_helper_chain.vibe",
  )
  wbtest_remove_if_exists(source_path)
  match ensure_parent_dir_for_file(source_path, "compiled-test-wbtest") {
    Ok(_) => ()
    Err(err) => fail("create temp source dir failed: " + err)
  }
  @os_fs.write_string_to_file(
    source_path,
    "let table = \"ABCDEF\"\n" +
    "let to_chunk = (i: Int) -> String {\n" +
    "  table|>String::substring(i, i + 1)\n" +
    "}\n" +
    "let rec enc_loop = (rest: Int, out: String) -> String {\n" +
    "  if rest <= 0 {\n" +
    "    out\n" +
    "  } else {\n" +
    "    enc_loop(rest - 1, out|>String::concat(to_chunk(1)))\n" +
    "  }\n" +
    "}\n" +
    "export let encode = () -> String {\n" +
    "  enc_loop(2, \"\")\n" +
    "}\n" +
    "test \"export helper chain\" {\n" +
    "  assert(String::equals(encode(), \"BB\"))\n" +
    "}\n",
  ) catch {
    e => fail("write temp source failed: " + e.to_string())
  }
  match wbtest_run_test_file_compiled(source_path, false) {
    CompiledTestAttempt::Success(report) => {
      assert_eq(report.total, 1)
      assert_eq(report.passed, 1)
      assert_eq(report.failed, 0)
    }
    CompiledTestAttempt::Unsupported(err) =>
      fail("compiled export helper unexpectedly unsupported: " + err)
    CompiledTestAttempt::Error(err) =>
      fail("compiled export helper unexpectedly errored: " + err)
  }
  wbtest_remove_if_exists(source_path)
}

///|
test "compiled test wrapper keeps recursive string helpers valid" {
  let cwd = @io.current_dir_or_root()
  let source_path = @vibe_fs.normalize_path(
    cwd + "/.wbtest_compiled_recursive_string_helper.vibe",
  )
  wbtest_remove_if_exists(source_path)
  match ensure_parent_dir_for_file(source_path, "compiled-test-wbtest") {
    Ok(_) => ()
    Err(err) => fail("create temp source dir failed: " + err)
  }
  @os_fs.write_string_to_file(
    source_path,
    "let table = \"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/\"\n" +
    "let to_b64 = (i: Int) -> String {\n" +
    "  table|>String::substring(i, i + 1)\n" +
    "}\n" +
    "let encode_triplet = (a: Int, b: Int, c: Int) -> String {\n" +
    "  let c0 = to_b64(a / 4)\n" +
    "  let x1 = a % 4 * 16\n" +
    "  let y1 = b / 16\n" +
    "  let c1 = to_b64(x1 + y1)\n" +
    "  let x2 = b % 16 * 4\n" +
    "  let y2 = c / 64\n" +
    "  let c2 = to_b64(x2 + y2)\n" +
    "  let c3 = to_b64(c % 64)\n" +
    "  c0|>String::concat(c1)|>String::concat(c2)|>String::concat(c3)\n" +
    "}\n" +
    "let rec enc_loop = (s: String, i: Int, out: String) -> String {\n" +
    "  let len = s|>String::length()\n" +
    "  if i + 3 <= len {\n" +
    "    let j = i + 1\n" +
    "    let k = i + 2\n" +
    "    let a = s|>String::char_code_at(i)\n" +
    "    let b = s|>String::char_code_at(j)\n" +
    "    let c = s|>String::char_code_at(k)\n" +
    "    enc_loop(s, i + 3, out|>String::concat(encode_triplet(a, b, c)))\n" +
    "  } else {\n" +
    "    out\n" +
    "  }\n" +
    "}\n" +
    "let encode = (s: String) -> String {\n" +
    "  enc_loop(s, 0, \"\")\n" +
    "}\n" +
    "test \"recursive string helper\" {\n" +
    "  assert(String::equals(encode(\"Man\"), \"TWFu\"))\n" +
    "}\n",
  ) catch {
    e => fail("write temp source failed: " + e.to_string())
  }
  match wbtest_run_test_file_compiled(source_path, false) {
    CompiledTestAttempt::Success(report) => {
      assert_eq(report.total, 1)
      assert_eq(report.passed, 1)
      assert_eq(report.failed, 0)
    }
    CompiledTestAttempt::Unsupported(err) =>
      fail("compiled recursive string helper unexpectedly unsupported: " + err)
    CompiledTestAttempt::Error(err) =>
      fail("compiled recursive string helper unexpectedly errored: " + err)
  }
  wbtest_remove_if_exists(source_path)
}

///|
test "compiled test wrapper keeps array fold lambda valid" {
  let cwd = @io.current_dir_or_root()
  let source_path = @vibe_fs.normalize_path(
    cwd + "/.wbtest_compiled_array_fold_lambda.vibe",
  )
  wbtest_remove_if_exists(source_path)
  match ensure_parent_dir_for_file(source_path, "compiled-test-wbtest") {
    Ok(_) => ()
    Err(err) => fail("create temp source dir failed: " + err)
  }
  @os_fs.write_string_to_file(
    source_path,
    "let sum_array = (xs: Array[Int]) -> Int {\n" +
    "  Array::fold(xs, 0, (acc: Int, x: Int) -> Int { acc + x })\n" +
    "}\n" +
    "test \"array fold lambda\" {\n" +
    "  assert(sum_array([1, 2, 3, 4]) == 10)\n" +
    "}\n",
  ) catch {
    e => fail("write temp source failed: " + e.to_string())
  }
  match wbtest_run_test_file_compiled(source_path, false) {
    CompiledTestAttempt::Success(report) => {
      assert_eq(report.total, 1)
      assert_eq(report.passed, 1)
      assert_eq(report.failed, 0)
    }
    CompiledTestAttempt::Unsupported(err) =>
      fail("compiled array fold lambda unexpectedly unsupported: " + err)
    CompiledTestAttempt::Error(err) =>
      fail("compiled array fold lambda unexpectedly errored: " + err)
  }
  wbtest_remove_if_exists(source_path)
}

///|
test "compiled test wrapper keeps mixed iterable fold specializations valid" {
  let cwd = @io.current_dir_or_root()
  let source_path = @vibe_fs.normalize_path(
    cwd + "/vibe/prelude/wbtest_compiled_mixed_iterable_fold.vibe",
  )
  wbtest_remove_if_exists(source_path)
  match ensure_parent_dir_for_file(source_path, "compiled-test-wbtest") {
    Ok(_) => ()
    Err(err) => fail("create temp source dir failed: " + err)
  }
  @os_fs.write_string_to_file(
    source_path,
    "import ./iterator.vibe {\n" +
    "  Iterator::fold\n" +
    "}\n" +
    "import ../collection/list.vibe {\n" +
    "  list_of3\n" +
    "}\n" +
    "enum Trio[T] {\n" +
    "  Trio(T, T, T)\n" +
    "}\n" +
    "impl [T] Iterable for Trio[T]\n" +
    "let trio_of3 = [T](a: T, b: T, c: T) -> Trio[T] {\n" +
    "  Trio(a, b, c)\n" +
    "}\n" +
    "let Trio::iter_length = [T](_xs: Trio[T]) -> Int {\n" +
    "  3\n" +
    "}\n" +
    "let Trio::iter_get = [T](xs: Trio[T], index: Int) -> T {\n" +
    "  match xs {\n" +
    "    Trio(a, b, c) => if index == 0 {\n" +
    "      a\n" +
    "    } else if index == 1 {\n" +
    "      b\n" +
    "    } else {\n" +
    "      c\n" +
    "    }\n" +
    "  }\n" +
    "}\n" +
    "test \"mixed iterable fold specializations\" {\n" +
    "  let xs = trio_of3(2, 4, 6)\n" +
    "  assert(eq(Iterator::fold(xs, 0, (acc: Int, x: Int) -> Int {\n" +
    "    acc + x\n" +
    "  }), 12))\n" +
    "  assert(eq(Iterator::fold(list_of3(1, 2, 3), 0, (acc: Int, x: Int) -> Int {\n" +
    "    acc + x\n" +
    "  }), 6))\n" +
    "}\n",
  ) catch {
    e => fail("write temp source failed: " + e.to_string())
  }
  match wbtest_run_test_file_compiled(source_path, false) {
    CompiledTestAttempt::Success(report) => {
      assert_eq(report.total, 1)
      assert_eq(report.passed, 1)
      assert_eq(report.failed, 0)
    }
    CompiledTestAttempt::Unsupported(err) =>
      fail("compiled mixed iterable fold unexpectedly unsupported: " + err)
    CompiledTestAttempt::Error(err) =>
      fail("compiled mixed iterable fold unexpectedly errored: " + err)
  }
  wbtest_remove_if_exists(source_path)
}

///|
test "compiled test wrapper keeps Map::keys results as strings" {
  let cwd = @io.current_dir_or_root()
  let source_path = @vibe_fs.normalize_path(
    cwd + "/.wbtest_compiled_map_keys_strings.vibe",
  )
  wbtest_remove_if_exists(source_path)
  match ensure_parent_dir_for_file(source_path, "compiled-test-wbtest") {
    Ok(_) => ()
    Err(err) => fail("create temp source dir failed: " + err)
  }
  @os_fs.write_string_to_file(
    source_path,
    "test \"Map::keys strings\" {\n" +
    "  let m: Map[String, Int] = map {\n" +
    "    \"name\": 1,\n" +
    "    \"ok\": 2\n" +
    "  }\n" +
    "  let keys = Map::keys(m)\n" +
    "  let k0 = Array::get(keys, 0)\n" +
    "  let k1 = Array::get(keys, 1)\n" +
    "  let pair = String::concat(k0, k1)\n" +
    "  assert(String::equals(pair, \"nameok\") || String::equals(pair, \"okname\"))\n" +
    "}\n",
  ) catch {
    e => fail("write temp source failed: " + e.to_string())
  }
  match wbtest_run_test_file_compiled(source_path, false) {
    CompiledTestAttempt::Success(report) => {
      assert_eq(report.total, 1)
      if report.passed != 1 || report.failed != 0 {
        fail("unexpected compiled report: " + report.to_string())
      }
    }
    CompiledTestAttempt::Unsupported(err) =>
      fail("compiled Map::keys strings unexpectedly unsupported: " + err)
    CompiledTestAttempt::Error(err) =>
      fail("compiled Map::keys strings unexpectedly errored: " + err)
  }
  wbtest_remove_if_exists(source_path)
}

///|
test "compiled test wrapper overwrites duplicate map builder keys" {
  let cwd = @io.current_dir_or_root()
  let source_path = @vibe_fs.normalize_path(
    cwd + "/.wbtest_compiled_map_builder_dedupe.vibe",
  )
  wbtest_remove_if_exists(source_path)
  match ensure_parent_dir_for_file(source_path, "compiled-test-wbtest") {
    Ok(_) => ()
    Err(err) => fail("create temp source dir failed: " + err)
  }
  @os_fs.write_string_to_file(
    source_path,
    "test \"map builder dedupe\" {\n" +
    "  let b = MapBuilder::new()\n" +
    "  MapBuilder::set(b, \"name\", 1)\n" +
    "  MapBuilder::set(b, \"name\", 2)\n" +
    "  let m = MapBuilder::freeze(b)\n" +
    "  assert(eq(Array::length(Map::keys(m)), 1))\n" +
    "  assert(eq(Map::get(m, \"name\"), 2))\n" +
    "}\n",
  ) catch {
    e => fail("write temp source failed: " + e.to_string())
  }
  match wbtest_run_test_file_compiled(source_path, false) {
    CompiledTestAttempt::Success(report) => {
      assert_eq(report.total, 1)
      assert_eq(report.passed, 1)
      assert_eq(report.failed, 0)
    }
    CompiledTestAttempt::Unsupported(err) =>
      fail("compiled map builder dedupe unexpectedly unsupported: " + err)
    CompiledTestAttempt::Error(err) =>
      fail("compiled map builder dedupe unexpectedly errored: " + err)
  }
  wbtest_remove_if_exists(source_path)
}

///|
test "compiled test wrapper keeps float add assertions valid" {
  let cwd = @io.current_dir_or_root()
  let source_path = @vibe_fs.normalize_path(
    cwd + "/.wbtest_compiled_float_add_assert.vibe",
  )
  wbtest_remove_if_exists(source_path)
  match ensure_parent_dir_for_file(source_path, "compiled-test-wbtest") {
    Ok(_) => ()
    Err(err) => fail("create temp source dir failed: " + err)
  }
  @os_fs.write_string_to_file(
    source_path,
    "test \"float add\" {\n" + "  assert(eq(add(1.5f, 2.5f), 4.0f))\n" + "}\n",
  ) catch {
    e => fail("write temp source failed: " + e.to_string())
  }
  match wbtest_run_test_file_compiled(source_path, false) {
    CompiledTestAttempt::Success(report) => {
      assert_eq(report.total, 1)
      assert_eq(report.passed, 1)
      assert_eq(report.failed, 0)
    }
    CompiledTestAttempt::Unsupported(err) =>
      fail("compiled float add unexpectedly unsupported: " + err)
    CompiledTestAttempt::Error(err) =>
      fail("compiled float add unexpectedly errored: " + err)
  }
  wbtest_remove_if_exists(source_path)
}

///|
test "compiled test wrapper keeps nested let record destructuring valid" {
  let cwd = @io.current_dir_or_root()
  let source_path = @vibe_fs.normalize_path(
    cwd + "/.wbtest_compiled_nested_let_record_pattern.vibe",
  )
  wbtest_remove_if_exists(source_path)
  match ensure_parent_dir_for_file(source_path, "compiled-test-wbtest") {
    Ok(_) => ()
    Err(err) => fail("create temp source dir failed: " + err)
  }
  @os_fs.write_string_to_file(
    source_path,
    "test \"nested let record pattern\" {\n" +
    "  let Some((a, record {\n" +
    "    x: b,\n" +
    "    y: c\n" +
    "  })) = Some((1, record {\n" +
    "    x: 2,\n" +
    "    y: 3\n" +
    "  }))\n" +
    "  assert(eq(a + b + c, 6))\n" +
    "}\n",
  ) catch {
    e => fail("write temp source failed: " + e.to_string())
  }
  match wbtest_run_test_file_compiled(source_path, false) {
    CompiledTestAttempt::Success(report) => {
      assert_eq(report.total, 1)
      assert_eq(report.passed, 1)
      assert_eq(report.failed, 0)
    }
    CompiledTestAttempt::Unsupported(err) =>
      fail(
        "compiled nested let record pattern unexpectedly unsupported: " + err,
      )
    CompiledTestAttempt::Error(err) =>
      fail("compiled nested let record pattern unexpectedly errored: " + err)
  }
  wbtest_remove_if_exists(source_path)
}

///|
test "compiled test marks Json::parse builtins unsupported for fallback" {
  let cwd = @io.current_dir_or_root()
  let source_path = @vibe_fs.normalize_path(
    cwd + "/.wbtest_compiled_from_json_fallback.vibe",
  )
  wbtest_remove_if_exists(source_path)
  match ensure_parent_dir_for_file(source_path, "compiled-test-wbtest") {
    Ok(_) => ()
    Err(err) => fail("create temp source dir failed: " + err)
  }
  @os_fs.write_string_to_file(
    source_path,
    "test \"Json::parse fallback\" {\n" +
    "  let data = Json::parse(\"{\\\"name\\\":\\\"vibe\\\"}\")\n" +
    "  assert(String::equals(Json::string(Json::get(data, \"name\")), \"vibe\"))\n" +
    "}\n",
  ) catch {
    e => fail("write temp source failed: " + e.to_string())
  }
  match wbtest_run_test_file_compiled(source_path, false) {
    CompiledTestAttempt::Success(report) => {
      // Json::parse/get/string now run through fs host imports.
      assert_true(report.total > 0)
      assert_eq(report.failed, 0)
      assert_eq(report.passed, report.total)
    }
    CompiledTestAttempt::Unsupported(err) =>
      fail("expected success via host imports, got unsupported: " + err)
    CompiledTestAttempt::Error(err) =>
      fail("compiled Json::parse unexpectedly errored: " + err)
  }
  wbtest_remove_if_exists(source_path)
}

///|
test "compiled test marks imported jq fallback builtins unsupported" {
  let cwd = @io.current_dir_or_root()
  let source_path = @vibe_fs.normalize_path(
    cwd + "/.wbtest_compiled_jq_fallback.vibe",
  )
  wbtest_remove_if_exists(source_path)
  match ensure_parent_dir_for_file(source_path, "compiled-test-wbtest") {
    Ok(_) => ()
    Err(err) => fail("create temp source dir failed: " + err)
  }
  @os_fs.write_string_to_file(
    source_path,
    "import ./vibe/shell/pipeline.vibe { jq }\n" +
    "test \"jq fallback\" {\n" +
    "  assert(String::equals(jq(\"{\\\"x\\\":1}\", \"x\"), \"1\"))\n" +
    "}\n",
  ) catch {
    e => fail("write temp source failed: " + e.to_string())
  }
  match wbtest_run_test_file_compiled(source_path, false) {
    CompiledTestAttempt::Success(report) => assert_true(report.total > 0)
    CompiledTestAttempt::Unsupported(err) =>
      fail("expected success via host imports, got unsupported: " + err)
    CompiledTestAttempt::Error(err) =>
      fail("compiled jq fallback unexpectedly errored: " + err)
  }
  wbtest_remove_if_exists(source_path)
}

///|
test "compiled test marks perform resume builtins unsupported for fallback" {
  let cwd = @io.current_dir_or_root()
  let source_path = @vibe_fs.normalize_path(
    cwd + "/.wbtest_compiled_perform_resume_fallback.vibe",
  )
  wbtest_remove_if_exists(source_path)
  match ensure_parent_dir_for_file(source_path, "compiled-test-wbtest") {
    Ok(_) => ()
    Err(err) => fail("create temp source dir failed: " + err)
  }
  @os_fs.write_string_to_file(
    source_path,
    "effect Ask {\n" +
    "  Ask(Int) -> Int\n" +
    "}\n" +
    "let ask_once = () -> Int with { Ask } {\n" +
    "  perform Ask::Ask(41)\n" +
    "}\n" +
    "test \"perform fallback\" {\n" +
    "  let value = handle {\n" +
    "    add(1, ask_once())\n" +
    "  } with Ask {\n" +
    "    Ask(_) => resume(42)\n" +
    "  }\n" +
    "  assert(eq(value, 43))\n" +
    "}\n",
  ) catch {
    e => fail("write temp source failed: " + e.to_string())
  }
  match wbtest_run_test_file_compiled(source_path, false) {
    CompiledTestAttempt::Success(report) => assert_true(report.total > 0)
    CompiledTestAttempt::Unsupported(err) =>
      fail("expected success via host imports, got unsupported: " + err)
    CompiledTestAttempt::Error(err) =>
      fail("compiled perform/resume fallback unexpectedly errored: " + err)
  }
  wbtest_remove_if_exists(source_path)
}

///|
fn wbtest_make_temp_dir(prefix : String) -> String {
  let base = "/tmp/cmd_vibe_wbtest_" + prefix + "_" + @env.now().to_string()
  for i in 0..<1000 {
    let path = if i == 0 { base } else { base + "_" + i.to_string() }
    if !@os_fs.path_exists(path) {
      @os_fs.create_dir(path) catch {
        e => abort("create temp dir failed: " + e.to_string())
      }
      return path
    }
  }
  abort("failed to allocate temp dir")
  base
}

///|
fn wbtest_contains(paths : Array[String], target : String) -> Bool {
  for path in paths {
    if path == target {
      return true
    }
  }
  false
}

///|
fn wbtest_find_explain_import_item(
  items : Array[ExplainImportItem],
  source : String,
) -> ExplainImportItem {
  for item in items {
    if item.source == source {
      return item
    }
  }
  abort("missing explain-import item: " + source)
  items[0]
}

///|
fn wbtest_substring_index(haystack : String, needle : String) -> Int {
  let h_len = haystack.length()
  let n_len = needle.length()
  if n_len == 0 {
    return 0
  }
  if n_len > h_len {
    return -1
  }
  let mut i = 0
  let limit = h_len - n_len
  while i <= limit {
    let slice = try haystack[i:i + n_len] catch {
      _ => ""
    } noraise {
      value => value.to_owned()
    }
    if slice == needle {
      return i
    }
    i += 1
  }
  -1
}

///|
fn wbtest_join_lines(lines : Array[String]) -> String {
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
fn wbtest_normalize_fixture_text(text : String) -> String {
  let lines : Array[String] = []
  for line_view in text.split("\n") {
    lines.push(line_view.trim_end().to_owned())
  }
  while lines.length() > 0 && lines[lines.length() - 1].trim().to_owned() == "" {
    ignore(lines.pop())
  }
  wbtest_join_lines(lines)
}

///|
fn wbtest_sort_strings(arr : Array[String]) -> Unit {
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
fn wbtest_replace_suffix(
  path : String,
  suffix : String,
  new_suffix : String,
) -> String {
  match path.strip_suffix(suffix) {
    Some(view) => view.to_owned() + new_suffix
    None => path
  }
}

///|
fn wbtest_collect_vibe_files_recursive(root : String) -> Array[String] {
  let out : Array[String] = []
  wbtest_collect_vibe_files_recursive_impl(root, out)
  wbtest_sort_strings(out)
  out
}

///|
fn wbtest_collect_vibe_files_recursive_impl(
  dir : String,
  out : Array[String],
) -> Unit {
  let entries = @os_fs.read_dir(dir) catch {
    e => abort("[\{dir}] read_dir failed: \{e.to_string()}")
  }
  for entry in entries {
    let path = if entry.has_prefix(dir + "/") {
      entry
    } else {
      dir + "/" + entry
    }
    if path.has_suffix("/.vibe") || path.contains("/.vibe/") {
      continue
    }
    let is_dir = @os_fs.is_dir(path) catch { _ => false }
    if is_dir {
      wbtest_collect_vibe_files_recursive_impl(path, out)
      continue
    }
    let is_file = @os_fs.is_file(path) catch { _ => false }
    if is_file && path.has_suffix(".vibe") {
      out.push(path)
    }
  }
}

///|
fn wbtest_remove_if_exists(path : String) -> Unit {
  if !@os_fs.path_exists(path) {
    return
  }
  let is_file = @os_fs.is_file(path) catch { _ => false }
  if is_file {
    ignore(@os_fs.remove_file(path) catch { _ => () })
    return
  }
  let is_dir = @os_fs.is_dir(path) catch { _ => false }
  if is_dir {
    let entries = @os_fs.read_dir(path) catch { _ => [] }
    for name in entries {
      wbtest_remove_if_exists(path + "/" + name)
    }
    ignore(@os_fs.remove_dir(path) catch { _ => () })
  }
}

///|
fn wbtest_bytes_contains_ascii(bytes : Bytes, needle : String) -> Bool {
  let hay = bytes.to_array()
  let pat = @utf8.encode(needle).to_array()
  if pat.length() == 0 {
    return true
  }
  if hay.length() < pat.length() {
    return false
  }
  let limit = hay.length() - pat.length()
  for i in 0..<=limit {
    let mut ok = true
    for j in 0..<pat.length() {
      if hay[i + j] != pat[j] {
        ok = false
        break
      }
    }
    if ok {
      return true
    }
  }
  false
}

///|
fn wbtest_restore_env_var(name : String, prev : String?) -> Unit {
  match prev {
    Some(value) => @sys.set_env_var(name, value)
    None => @sys.unset_env_var(name)
  }
}

///|
fn write_wbtest_json_parse_fallback_source(source_path : String) -> Unit {
  wbtest_remove_if_exists(source_path)
  match ensure_parent_dir_for_file(source_path, "compiled-test-wbtest") {
    Ok(_) => ()
    Err(err) => abort("create temp source dir failed: " + err)
  }
  @os_fs.write_string_to_file(
    source_path,
    "test \"Json::parse fallback\" {\n" +
    "  let data = Json::parse(\"{\\\"name\\\":\\\"vibe\\\"}\")\n" +
    "  assert(String::equals(Json::string(Json::get(data, \"name\")), \"vibe\"))\n" +
    "}\n",
  ) catch {
    e => abort("write temp source failed: " + e.to_string())
  }
}

///|
fn wbtest_load_compiled_test_case_db(
  source_path : String,
) -> Result[(@runtime.VibeDb, String), String] {
  load_db_for_test_with_cache(CliEntryDbCache::new(), source_path)
}

///|
fn wbtest_run_test_file_compiled(
  entry_path : String,
  stop_on_first_failure : Bool,
) -> CompiledTestAttempt {
  run_test_file_compiled_with_cache(
    CliEntryDbCache::new(),
    entry_path,
    stop_on_first_failure,
  )
}

///|
fn wbtest_run_test_file_with_backend(
  entry_path : String,
  features : @runtime.RuntimeFeatureFlags,
) -> Result[CliTestReport, String] {
  match
    run_test_file_with_backend_with_cache(
      CliEntryDbCache::new(),
      entry_path,
      features,
    ) {
    TestFileOutcome::Done(report) => Ok(report)
    TestFileOutcome::Skipped(reason) => Err(reason)
    TestFileOutcome::Errored(err) => Err(err)
  }
}

///|
fn write_wbtest_basic_test_source(source_path : String) -> Unit {
  wbtest_remove_if_exists(source_path)
  match ensure_parent_dir_for_file(source_path, "compiled-test-wbtest") {
    Ok(_) => ()
    Err(err) => abort("create temp source dir failed: " + err)
  }
  @os_fs.write_string_to_file(
    source_path,
    "test \"basic\" {\n" + "  assert(eq(add(1, 2), 3))\n" + "}\n",
  ) catch {
    e => abort("write temp source failed: " + e.to_string())
  }
}

///|
test "cli entry db cache reuses db for same root" {
  let cache = CliEntryDbCache::new()
  let db1 = cache.db_for_resolved_entry("/tmp/workspace/pkg/a.vibe")
  db1.set_source("/tmp/workspace/pkg/shared.vibe", "let value = 1\n")
  let db2 = cache.db_for_resolved_entry("/tmp/workspace/pkg/b.vibe")
  match db2.get_source("/tmp/workspace/pkg/shared.vibe") {
    Some(source) => assert_eq(source, "let value = 1\n")
    None => fail("expected same-root cache reuse")
  }
}

///|
test "cli entry db cache isolates different roots" {
  let cache = CliEntryDbCache::new()
  let db1 = cache.db_for_resolved_entry("/tmp/workspace/pkg1/a.vibe")
  db1.set_source("/tmp/workspace/pkg1/shared.vibe", "let value = 1\n")
  let db2 = cache.db_for_resolved_entry("/tmp/workspace/pkg2/b.vibe")
  match db2.get_source("/tmp/workspace/pkg1/shared.vibe") {
    Some(_) => fail("unexpected cross-root cache reuse")
    None => ()
  }
}

///|
test "serialize source hash cache roundtrips" {
  let hashes : Map[String, String] = {}
  hashes["/tmp/a.vibe"] = "aaa"
  hashes["/tmp/b.vibe"] = "bbb"
  let parsed = parse_source_hash_cache(serialize_source_hash_cache(hashes))
  assert_eq(parsed.length(), 2)
  @debug.assert_eq(parsed.get("/tmp/a.vibe"), Some("aaa"))
  @debug.assert_eq(parsed.get("/tmp/b.vibe"), Some("bbb"))
}

///|
test "source hash cache match requires identical entries" {
  let saved : Map[String, String] = {}
  saved["/tmp/a.vibe"] = "aaa"
  let same : Map[String, String] = {}
  same["/tmp/a.vibe"] = "aaa"
  let changed : Map[String, String] = {}
  changed["/tmp/a.vibe"] = "bbb"
  let extra : Map[String, String] = {}
  extra["/tmp/a.vibe"] = "aaa"
  extra["/tmp/b.vibe"] = "bbb"
  assert_true(source_hash_cache_matches(saved, same))
  assert_false(source_hash_cache_matches(saved, changed))
  assert_false(source_hash_cache_matches(saved, extra))
}

///|
test "source hash cache includes transitive imports" {
  @runtime_compile.init_hooks()
  let db = @runtime.VibeDb::new()
  let main_path = "/tmp/source_hash_cache/main.vibe"
  let dep_path = "/tmp/source_hash_cache/dep.vibe"
  let leaf_path = "/tmp/source_hash_cache/leaf.vibe"
  let main_source = "import ./dep.vibe { dep }\nlet run = dep\n"
  let dep_source = "import ./leaf.vibe { leaf }\nlet dep = leaf\n"
  let leaf_source = "let leaf = 1\n"
  db.set_source(main_path, main_source)
  db.set_source(dep_path, dep_source)
  db.set_source(leaf_path, leaf_source)
  let hashes = collect_source_hash_cache(db, main_path, true)
  assert_eq(hashes.length(), 3)
  assert_true(hashes.contains(main_path))
  assert_true(hashes.contains(dep_path))
  assert_true(hashes.contains(leaf_path))
}

///|
test "save source hashes includes entry for linked cache" {
  @runtime_compile.init_hooks()
  let root = wbtest_make_temp_dir("save_source_hashes_includes_entry")
  let cache_dir = root + "/.vibe/debug/test"
  let hash_path = cache_dir + "/source_hashes.txt"
  let entry_path = root + "/main.vibe"
  let dep_path = root + "/dep.vibe"
  let db = @runtime.VibeDb::new()
  db.set_source(entry_path, "import ./dep.vibe { dep }\nlet main = dep\n")
  db.set_source(dep_path, "let dep = 1\n")
  let _ = c_system(
    system_command_bytes("mkdir -p " + shell_quote_command_arg(cache_dir)),
  )
  save_source_hashes(db, entry_path, cache_dir, hash_path)
  let saved = parse_source_hash_cache(
    @os_fs.read_file_to_string(hash_path) catch {
      _ => ""
    },
  )
  assert_true(saved.contains(entry_path))
  assert_true(saved.contains(dep_path))
  wbtest_remove_if_exists(hash_path)
  wbtest_remove_if_exists(cache_dir)
  wbtest_remove_if_exists(root + "/.vibe/debug")
  wbtest_remove_if_exists(root + "/.vibe")
  wbtest_remove_if_exists(root)
}

///|
test "run monolithic cache paths separate http mode" {
  let paths1 = run_monolithic_cache_paths("/tmp/project/src/main.vibe", false)
  let paths2 = run_monolithic_cache_paths("/tmp/project/src/main.vibe", true)
  assert_true(paths1.0.contains("/.vibe/run/"))
  assert_true(paths1.1.has_suffix("/app.wasm"))
  assert_true(paths1.2.has_suffix("/source_hashes.txt"))
  assert_true(paths2.1.has_suffix("/app_http.wasm"))
  assert_true(paths1.1 != paths2.1)
}

///|
test "compiled test batch cache paths separate http mode" {
  let paths1 = compiled_test_batch_cache_paths(
    "/tmp/project/src/main_test.vibe", false,
  )
  let paths2 = compiled_test_batch_cache_paths(
    "/tmp/project/src/main_test.vibe", true,
  )
  assert_true(paths1.0.contains("/.vibe/test/"))
  assert_true(paths1.1.has_suffix("/batch.wasm"))
  assert_true(paths1.2.has_suffix("/source_hashes.txt"))
  assert_true(paths2.1.has_suffix("/batch_http.wasm"))
  assert_true(paths1.1 != paths2.1)
}

///|
test "session http port is stable per entry root" {
  let features = @runtime.RuntimeFeatureFlags::new(false, false)
  let port1 = session_http_port_for_entry_with_features(
    "/tmp/project/src/main.vibe", features,
  )
  let port2 = session_http_port_for_entry_with_features(
    "/tmp/project/src/main.vibe", features,
  )
  let port3 = session_http_port_for_entry_with_features(
    "/tmp/project/src/other.vibe", features,
  )
  assert_eq(port1, port2)
  assert_eq(port1, port3)
  assert_true(port1 >= 36000)
}

///|
test "session http defaults on when self binary exists" {
  assert_true(cli_use_session_http_with(None, true))
}

///|
test "session http defaults off without self binary" {
  assert_false(cli_use_session_http_with(None, false))
}

///|
test "session http env overrides default" {
  assert_false(cli_use_session_http_with(Some("0"), true))
  assert_true(cli_use_session_http_with(Some("1"), false))
}

///|
test "session http worker token changes with binary contents" {
  let bin = "/tmp/vibe-session-token"
  let token1 = session_http_worker_token_from_bytes(bin, @utf8.encode("v1"))
  let token2 = session_http_worker_token_from_bytes(bin, @utf8.encode("v1"))
  let token3 = session_http_worker_token_from_bytes(bin, @utf8.encode("v2"))
  assert_eq(token1, token2)
  assert_true(token1 != token3)
}

///|
test "session http reuse requires matching worker token" {
  let expected = "worker-token"
  assert_true(
    session_http_can_reuse_worker(
      SessionHttpPingState::Alive(Some(expected)),
      expected,
    ),
  )
  assert_false(
    session_http_can_reuse_worker(
      SessionHttpPingState::Alive(Some("stale-worker")),
      expected,
    ),
  )
  assert_false(
    session_http_can_reuse_worker(SessionHttpPingState::Alive(None), expected),
  )
  assert_false(
    session_http_can_reuse_worker(SessionHttpPingState::Unreachable, expected),
  )
}

///|
test "session http ping reports worker token" {
  let req = CliSessionRequest::{ kind: CliSessionRequestKind::Ping, path: None }
  let (json, should_shutdown) = handle_cli_session_request(
    CliEntryDbCache::new(),
    req,
    @runtime.RuntimeFeatureFlags::new(false, false),
    "worker-token",
  )
  assert_false(should_shutdown)
  assert_eq(
    parse_session_http_ping_state(json),
    SessionHttpPingState::Alive(Some("worker-token")),
  )
}

///|
test "session http spawn command exports worker token" {
  let cmd = build_session_http_spawn_command(
    "/tmp/vibe.exe",
    36123,
    @runtime.RuntimeFeatureFlags::new(true, true),
    "worker-token",
    424242,
  )
  assert_true(cmd.contains("VIBE_SESSION_WORKER_TOKEN="))
  assert_true(cmd.contains("VIBE_INTERNAL_PARENT_PID=424242"))
  assert_true(cmd.contains("session-http --port 36123"))
  assert_true(cmd.contains("--unstable-async"))
  assert_true(cmd.contains("--unstable-threads"))
  assert_true(cmd.contains("/proc/$$/fd/*"))
  assert_true(cmd.contains("eval \"exec $n<&-\""))
}

///|
test "session http spawn command escapes embedded single quotes in self_bin" {
  let cmd = build_session_http_spawn_command(
    "/tmp/O'Neil/vibe.exe",
    36123,
    @runtime.RuntimeFeatureFlags::new(false, false),
    "tok",
    1,
  )
  // The outer single-quote wrap around `sh -c '…'` would otherwise be
  // truncated by the `'` in the path. Make sure the apostrophe is
  // re-quoted as `'\''` so the entire script is one POSIX argument.
  assert_true(cmd.contains("'\\''Neil"))
  assert_false(cmd.contains("/tmp/O' "))
}

///|
test "session http port separates runtime feature sets" {
  let baseline = @runtime.RuntimeFeatureFlags::new(false, false)
  let async_only = @runtime.RuntimeFeatureFlags::new(true, false)
  let threads_only = @runtime.RuntimeFeatureFlags::new(false, true)
  let both = @runtime.RuntimeFeatureFlags::new(true, true)
  let base_port = session_http_port_for_entry_with_features(
    "/tmp/project/src/main.vibe", baseline,
  )
  assert_true(
    base_port !=
    session_http_port_for_entry_with_features(
      "/tmp/project/src/main.vibe", async_only,
    ),
  )
  assert_true(
    base_port !=
    session_http_port_for_entry_with_features(
      "/tmp/project/src/main.vibe", threads_only,
    ),
  )
  assert_true(
    session_http_port_for_entry_with_features(
      "/tmp/project/src/main.vibe", async_only,
    ) !=
    session_http_port_for_entry_with_features(
      "/tmp/project/src/main.vibe", both,
    ),
  )
}

///|
test "cli session request parses check json" {
  let req = match
    parse_cli_session_request(
      "{\"cmd\":\"check\",\"path\":\"/tmp/project/main.vibe\"}",
    ) {
    Ok(v) => v
    Err(err) => fail("expected check request: " + err)
  }
  assert_eq(req.kind, CliSessionRequestKind::Check)
  @debug.assert_eq(req.path, Some("/tmp/project/main.vibe"))
}

///|
test "cli session request parses run json" {
  let req = match
    parse_cli_session_request(
      "{\"cmd\":\"run\",\"path\":\"/tmp/project/main.vibe\"}",
    ) {
    Ok(v) => v
    Err(err) => fail("expected run request: " + err)
  }
  assert_eq(req.kind, CliSessionRequestKind::Run)
  @debug.assert_eq(req.path, Some("/tmp/project/main.vibe"))
}

///|
test "cli session request parses shutdown json" {
  let req = match parse_cli_session_request("{\"cmd\":\"shutdown\"}") {
    Ok(v) => v
    Err(err) => fail("expected shutdown request: " + err)
  }
  assert_eq(req.kind, CliSessionRequestKind::Shutdown)
  @debug.assert_eq(req.path, None)
}

///|
test "cli session request parses ping json" {
  let req = match parse_cli_session_request("{\"cmd\":\"ping\"}") {
    Ok(v) => v
    Err(err) => fail("expected ping request: " + err)
  }
  assert_eq(req.kind, CliSessionRequestKind::Ping)
  @debug.assert_eq(req.path, None)
}

///|
test "cli session request rejects missing path" {
  match parse_cli_session_request("{\"cmd\":\"test\"}") {
    Ok(_) => fail("expected missing path error")
    Err(err) => assert_true(err.contains("missing path"))
  }
}

///|
test "cli session test report json roundtrips" {
  let failures : Array[CliTestFailure] = [{ name: Some("demo"), error: "boom" }]
  let report : CliTestReport = { total: 2, passed: 1, failed: 1, failures }
  let parsed = match
    parse_cli_test_report_json(
      make_cli_session_test_report_json(
        "/tmp/project/main_test.vibe", report, 12,
      ),
    ) {
    Ok(v) => v
    Err(err) => fail("expected parsed report: " + err)
  }
  assert_eq(parsed.total, 2)
  assert_eq(parsed.passed, 1)
  assert_eq(parsed.failed, 1)
  assert_eq(parsed.failures.length(), 1)
  @debug.assert_eq(parsed.failures[0].name, Some("demo"))
  assert_eq(parsed.failures[0].error, "boom")
}

///|
test "cli session run json roundtrips" {
  let parsed_int = match
    parse_cli_run_value_json(
      make_cli_session_run_result_json(
        "/tmp/project/main.vibe",
        WasmRunValue::Int(42L),
      ),
    ) {
    Ok(v) => v
    Err(err) => fail("expected parsed int result: " + err)
  }
  assert_eq(parsed_int, WasmRunValue::Int(42L))
  let parsed_bool = match
    parse_cli_run_value_json(
      make_cli_session_run_result_json(
        "/tmp/project/main.vibe",
        WasmRunValue::Bool(true),
      ),
    ) {
    Ok(v) => v
    Err(err) => fail("expected parsed bool result: " + err)
  }
  assert_eq(parsed_bool, WasmRunValue::Bool(true))
}

///|
test "test backend reports unsupported compiled cases by default" {
  let cwd = @io.current_dir_or_root()
  let source_path = @vibe_fs.normalize_path(
    cwd + "/.wbtest_backend_default_compiled_json_parse.vibe",
  )
  write_wbtest_json_parse_fallback_source(source_path)
  match
    wbtest_run_test_file_with_backend(
      source_path,
      @runtime.RuntimeFeatureFlags::stable(),
    ) {
    Ok(report) => {
      // Json::parse/get/string now handled via host imports.
      assert_true(report.total > 0)
      assert_eq(report.failed, 0)
      assert_eq(report.passed, report.total)
    }
    Err(err) => fail("expected success via host imports, got error: " + err)
  }
  wbtest_remove_if_exists(source_path)
}

///|
test "compiled exec detects modules that use http builtins and emits host imports" {
  let db = @runtime.VibeDb::new()
  let src =
    #|export let _start = () -> Int with {Net} {
    #|  let req = Http::request("GET", "https://example.com", "", "")
    #|  let status = Http::response_status(req)
    #|  Http::close(req)
    #|  status
    #|}
  db.set_source("main", src)
  let ast = db.ast("main")
  assert_true(module_uses_http_builtins(ast))
  let wasm = try
    compile_module_wasm_for_exec(db, "main", http_host_imports=true)
  catch {
    e => fail("compile error: " + e.to_string())
  } noraise {
    v => v
  }
  assert_true(wbtest_bytes_contains_ascii(wasm, "vibe:http"))
  assert_true(wbtest_bytes_contains_ascii(wasm, "vibe_http_host_string_new"))
}

///|
test "compiled exec detects modules without http builtins" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|export let _start = () -> Int {
      #|  42
      #|},
    ),
  )
  let ast = db.ast("main")
  assert_false(module_uses_http_builtins(ast))
}

///|
test "compiled exec keeps >= lowering away from imported or helpers" {
  let root = wbtest_make_temp_dir("compiled_exec_cmp_or_intrinsic_wb")
  let entry_path = root + "/main.vibe"
  let helper_path = root + "/result.vibe"
  let wasm_path = root + "/main.wasm"
  let db = @runtime.VibeDb::new()
  db.set_source(
    helper_path,
    (
      #|export enum Result[T, E] {
      #|  Ok(T);
      #|  Err(E)
      #|}
      #|
      #|export let or = [T](res: T, default: T) -> T {
      #|  default
      #|}
    ),
  )
  db.set_source(
    entry_path,
    (
      #|import ./result.vibe { Result }
      #|
      #|export let _start = () -> Int {
      #|  if 49 >= 48 { 1 } else { 99 }
      #|}
    ),
  )
  let wasm = try compile_module_wasm_for_exec(db, entry_path) catch {
    e => fail("compile error: " + e.to_string())
  } noraise {
    v => v
  }
  @os_fs.write_bytes_to_file(wasm_path, wasm) catch {
    e => fail("write wasm failed: " + e.to_string())
  }
  let runner = match resolve_bench_wasm_runner(entry_path) {
    Ok(v) => v
    Err(err) => fail("resolve runner failed: " + err)
  }
  let run_out = run_wasmtime_invoke_run_capture(runner, wasm_path, wasm_path)
  if run_out.status != 0 {
    fail(
      "run failed: " + wasmtime_failure_detail(run_out.stdout, run_out.stderr),
    )
  }
  let tagged = match parse_last_numeric_line_int64(run_out.stdout) {
    Some(v) => v
    None => fail("missing numeric result")
  }
  let value = match decode_tagged_wasm_run_value(tagged) {
    Some(v) => v
    None => fail("unsupported tagged result: " + tagged.to_string())
  }
  assert_eq(value, WasmRunValue::Int(1L))
  wbtest_remove_if_exists(wasm_path)
  wbtest_remove_if_exists(entry_path)
  wbtest_remove_if_exists(helper_path)
  wbtest_remove_if_exists(root)
}

///|
test "compiled exec wasm embeds throw literal for handler parity" {
  let db = @runtime.VibeDb::new()
  let needle = "WB_EXEC_THROW_LITERAL_PARITY_3f64"
  let src =
    #|let fail = () -> Int with { Error } {
    #|  throw("@MSG@")
    #|}
    #|handle {
    #|  fail()
    #|} with Error {
    #|  Throw(msg) => if String::equals(msg, "@MSG@") { 1 } else { 2 }
    #|}
  db.set_source("main", src.replace(old="@MSG@", new=needle))
  let wasm = try compile_module_wasm_for_exec(db, "main") catch {
    e => fail("compile error: " + e.to_string())
  } noraise {
    v => v
  }
  assert_true(wbtest_bytes_contains_ascii(wasm, needle))
}

///|
test "decode tagged wasm run value" {
  @debug.assert_eq(decode_tagged_wasm_run_value(168L), Some(WasmRunValue::Int(42L)))
  @debug.assert_eq(decode_tagged_wasm_run_value(7L), Some(WasmRunValue::Bool(true)))
  @debug.assert_eq(decode_tagged_wasm_run_value(3L), Some(WasmRunValue::Bool(false)))
}

///|
test "cli tagged run export name stays stable" {
  assert_eq(cli_tagged_run_export_name, "_vibe_run_tagged")
}

///|
test "graph ir query helpers support exact and partial search" {
  let rows : Array[@x_exp.GraphIrRow] = [
    @x_exp.new_graph_ir_row(
      "typescript",
      "app.ts",
      "add",
      "function",
      "function add(a: number, b: number): number",
      0,
      40,
      "h1",
      [],
      [],
      [],
      [],
    ),
    @x_exp.new_graph_ir_row(
      "typescript",
      "app.ts",
      "Point",
      "interface",
      "interface Point { x: number }",
      41,
      80,
      "h1",
      [],
      [],
      [],
      [],
    ),
  ]
  assert_eq(graph_ir_find_exact_rows(rows, "add").length(), 1)
  assert_eq(graph_ir_find_exact_rows(rows, "ad").length(), 0)
  assert_eq(graph_ir_search_rows(rows, "Point").length(), 1)
  assert_eq(graph_ir_search_rows(rows, "number").length(), 2)
  assert_eq(graph_ir_search_rows(rows, "").length(), 2)
}

///|
test "graph ir semantic option parser keeps positional args" {
  let parsed = match
    graph_ir_parse_semantic_rows_flag(
      ["query", "entry.ts", "--semantic-rows", "rows.json"],
      "ide search",
    ) {
    Ok(v) => v
    Err(err) => fail(err)
  }
  assert_eq(parsed.0.length(), 2)
  assert_eq(parsed.0[0], "query")
  assert_eq(parsed.0[1], "entry.ts")
  @debug.assert_eq(parsed.1, Some("rows.json"))
}

///|
test "graph ir semantic option parser rejects malformed flags" {
  let missing = graph_ir_parse_semantic_rows_flag(
    ["entry.ts", "--semantic-rows"],
    "ide outline",
  )
  match missing {
    Ok(_) => fail("expected error")
    Err(err) => assert_true(err.contains("missing path"))
  }
  let duplicate = graph_ir_parse_semantic_rows_flag(
    ["entry.ts", "--semantic-rows", "a.json", "--semantic-rows", "b.json"],
    "ide outline",
  )
  match duplicate {
    Ok(_) => fail("expected error")
    Err(err) => assert_true(err.contains("duplicate"))
  }
}

///|
test "graph ir semantic rows json parser applies defaults" {
  let row_obj : Map[String, Json] = {}
  row_obj["name"] = Json::string("greet")
  row_obj["kind"] = Json::string("function")
  row_obj["signature"] = Json::string("function greet(name: string): string")
  row_obj["start"] = Json::number(0.0)
  row_obj["end"] = Json::number(32.0)
  let parsed = match
    graph_ir_parse_semantic_rows_json(
      Json::array([Json::object(row_obj)]),
      "typescript",
      "app.ts",
      "hash-default",
    ) {
    Ok(v) => v
    Err(err) => fail(err)
  }
  assert_eq(parsed.length(), 1)
  assert_eq(parsed[0].language_id, "typescript")
  assert_eq(parsed[0].path, "app.ts")
  assert_eq(parsed[0].module_hash, "hash-default")
  assert_eq(parsed[0].name, "greet")
}

///|
test "graph ir semantic rows json parser accepts object with rows field" {
  let row_obj : Map[String, Json] = {}
  row_obj["name"] = Json::string("from_object")
  row_obj["kind"] = Json::string("function")
  row_obj["signature"] = Json::string("function from_object(): void")
  row_obj["start"] = Json::number(10.0)
  row_obj["end"] = Json::number(30.0)
  let root : Map[String, Json] = {}
  root["rows"] = Json::array([Json::object(row_obj)])
  let parsed = match
    graph_ir_parse_semantic_rows_json(
      Json::object(root),
      "typescript",
      "obj.ts",
      "hash-obj",
    ) {
    Ok(v) => v
    Err(err) => fail(err)
  }
  assert_eq(parsed.length(), 1)
  assert_eq(parsed[0].name, "from_object")
  assert_eq(parsed[0].path, "obj.ts")
}

///|
test "graph ir semantic rows json parser rejects invalid row shape" {
  let bad_row : Map[String, Json] = {}
  bad_row["name"] = Json::string("bad")
  bad_row["kind"] = Json::string("function")
  bad_row["signature"] = Json::string("function bad(): void")
  bad_row["start"] = Json::string("zero")
  bad_row["end"] = Json::number(10.0)
  let parsed = graph_ir_parse_semantic_rows_json(
    Json::array([Json::object(bad_row)]),
    "typescript",
    "bad.ts",
    "hash-bad",
  )
  match parsed {
    Ok(_) => fail("expected parse error")
    Err(err) => {
      assert_true(err.contains("semantic_rows[0].start"))
      assert_true(err.contains("expected number"))
    }
  }
}

///|
test "graph ir line helpers resolve line and snippet from start offset" {
  let source = "x\nfoo()"
  let row = @x_exp.new_graph_ir_row(
    "python",
    "main.py",
    "foo",
    "function",
    "def foo()",
    2,
    7,
    "h2",
    [],
    [],
    [],
    [],
  )
  @debug.assert_eq(graph_ir_line_col(source, row), (2, 1))
  assert_eq(graph_ir_line_text(source, row), "foo()")
}

///|
test "graph ir rows convert to symbol index for lsif emission" {
  let rows : Array[@x_exp.GraphIrRow] = [
    @x_exp.new_graph_ir_row(
      "typescript",
      "/workspace/main.ts",
      "add",
      "function",
      "function add(a: number, b: number): number",
      0,
      40,
      "h3",
      [],
      [],
      [],
      [],
    ),
    @x_exp.new_graph_ir_row(
      "typescript",
      "/workspace/main.ts",
      "Point",
      "interface",
      "interface Point { x: number }",
      41,
      80,
      "h3",
      [],
      [],
      [],
      [],
    ),
  ]
  let index = graph_ir_rows_to_symbol_index(rows)
  let add_hits = index.find_exact("add")
  assert_eq(add_hits.length(), 1)
  assert_eq(@frontend.symbol_kind_name(add_hits[0].kind), "function")
  let point_hits = index.find_exact("Point")
  assert_eq(point_hits.length(), 1)
  assert_eq(@frontend.symbol_kind_name(point_hits[0].kind), "struct")
}

///|
test "append scratch db source hoists late import ahead of prior bindings" {
  let saved1 = append_scratch_db_source("", "let x=1")
  let saved2 = append_scratch_db_source(saved1, "import ./helper.vibe { inc }")
  let ast = @parser.parse_ast(saved2) catch {
    e => fail("saved source parse failed: " + e.to_string())
  }
  assert_true(saved2.contains("let x = 1"))
  match ast.stmts {
    [@vibe_core.Stmt::Import(..), @vibe_core.Stmt::Let(..), ..] => ()
    _ => fail("expected hoisted import before prior binding")
  }
}

///|
test "append scratch db source does not duplicate same import" {
  let saved1 = append_scratch_db_source("", "import ./helper.vibe { inc }")
  let saved2 = append_scratch_db_source(saved1, "let x=1")
  let saved3 = append_scratch_db_source(saved2, "import ./helper.vibe { inc }")
  let ast = @parser.parse_ast(saved3) catch {
    e => fail("saved source parse failed: " + e.to_string())
  }
  let mut import_count = 0
  for stmt in ast.stmts {
    match stmt {
      @vibe_core.Stmt::Import(
        source=@vibe_core.ModuleRef::Path(path="./helper.vibe"),
        ..
      ) => import_count += 1
      _ => ()
    }
  }
  assert_eq(import_count, 1)
  assert_true(saved3.contains("let x = 1"))
}

///|
test "compiled repl temp source path stays under workspace root" {
  let path = compiled_repl_temp_source_path()
  assert_true(path.has_prefix("/tmp/vibe-compiled-repl-"))
  assert_true(path.has_suffix(".vibe"))
}

///|
test "raw repl output text ends with trailing newline" {
  assert_eq(repl_raw_output_text("last: 3"), "\r\nlast: 3\r\n")
}

///|
test "raw repl output text preserves multiline boundaries" {
  assert_eq(repl_raw_output_text("a\nb"), "\r\na\r\nb\r\n")
}

///|
test "compiled repl string fallback decodes _start export" {
  let root = wbtest_make_temp_dir("compiled_repl_string_literal_wb")
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
  @debug.assert_eq(result.display_override, Some("\"hi\""))
  wbtest_remove_if_exists(wasm_path)
  wbtest_remove_if_exists(source_path)
  wbtest_remove_if_exists(root)
}

///|
test "compiled repl array fallback renders duplicate strings" {
  let root = wbtest_make_temp_dir("compiled_repl_array_literal_wb")
  let source_path = root + "/compiled_repl.vibe"
  let wasm_path = root + "/expr_0.wasm"
  let cache = CliEntryDbCache::new()
  let result = match
    run_compiled_repl_line_with_cache(
      cache, source_path, wasm_path, "", "[\"hi\", \"hi\"]",
    ) {
    Ok(v) => v
    Err(err) => fail("compiled repl array literal failed: " + err)
  }
  assert_eq(result.value, WasmRunValue::Int(0L))
  @debug.assert_eq(result.display_override, Some("[\"hi\", \"hi\"]"))
  wbtest_remove_if_exists(wasm_path)
  wbtest_remove_if_exists(source_path)
  wbtest_remove_if_exists(root)
}

///|
test "compiled repl array binding renders on reuse" {
  let root = wbtest_make_temp_dir("compiled_repl_array_binding_wb")
  let source_path = root + "/compiled_repl.vibe"
  let wasm0 = root + "/expr_0.wasm"
  let wasm1 = root + "/expr_1.wasm"
  let cache = CliEntryDbCache::new()
  let bound = match
    run_compiled_repl_line_with_cache(
      cache, source_path, wasm0, "", "let xs = [1, 2]",
    ) {
    Ok(v) => v
    Err(err) => fail("compiled repl array binding failed: " + err)
  }
  assert_eq(bound.value, WasmRunValue::Int(0L))
  @debug.assert_eq(bound.display_override, Some("[1, 2]"))
  let reused = match
    run_compiled_repl_line_with_cache(
      cache,
      source_path,
      wasm1,
      bound.next_source,
      "xs",
    ) {
    Ok(v) => v
    Err(err) => fail("compiled repl array reuse failed: " + err)
  }
  assert_eq(reused.value, WasmRunValue::Int(0L))
  @debug.assert_eq(reused.display_override, Some("[1, 2]"))
  wbtest_remove_if_exists(wasm0)
  wbtest_remove_if_exists(wasm1)
  wbtest_remove_if_exists(source_path)
  wbtest_remove_if_exists(root)
}

///|
test "compiled repl map fallback renders entries" {
  let root = wbtest_make_temp_dir("compiled_repl_map_literal_wb")
  let source_path = root + "/compiled_repl.vibe"
  let wasm_path = root + "/expr_0.wasm"
  let cache = CliEntryDbCache::new()
  let result = match
    run_compiled_repl_line_with_cache(
      cache, source_path, wasm_path, "", "map { a: 1, b: 2 }",
    ) {
    Ok(v) => v
    Err(err) => fail("compiled repl map literal failed: " + err)
  }
  assert_eq(result.value, WasmRunValue::Int(0L))
  @debug.assert_eq(result.display_override, Some("{|\"a\": 1, \"b\": 2|}"))
  wbtest_remove_if_exists(wasm_path)
  wbtest_remove_if_exists(source_path)
  wbtest_remove_if_exists(root)
}

///|
test "compiled repl hoists import entered after prior binding" {
  let root = wbtest_make_temp_dir("compiled_repl_import_hoist_wb")
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
  let seeded = match
    run_compiled_repl_line_with_cache(
      cache, source_path, wasm0, "", "let x = 41",
    ) {
    Ok(v) => v
    Err(err) => fail("seed compiled repl line failed: " + err)
  }
  let imported = match
    run_compiled_repl_line_with_cache(
      cache,
      source_path,
      wasm1,
      seeded.next_source,
      "import ./helper.vibe { inc }",
    ) {
    Ok(v) => v
    Err(err) => fail("late import line failed: " + err)
  }
  let result = match
    run_compiled_repl_line_with_cache(
      cache,
      source_path,
      wasm2,
      imported.next_source,
      "inc(x)",
    ) {
    Ok(v) => v
    Err(err) => fail("late import call failed: " + err)
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
test "pure_test_cache_key is deterministic" {
  let hashes1 : Map[String, String] = {}
  hashes1["/tmp/a.vibe"] = "hash_a"
  hashes1["/tmp/b.vibe"] = "hash_b"
  let hashes2 : Map[String, String] = {}
  hashes2["/tmp/b.vibe"] = "hash_b"
  hashes2["/tmp/a.vibe"] = "hash_a"
  let key1 = pure_test_cache_key(hashes1)
  let key2 = pure_test_cache_key(hashes2)
  assert_eq(key1, key2)
}

///|
test "pure_test_cache_key changes when hash changes" {
  let hashes1 : Map[String, String] = {}
  hashes1["/tmp/a.vibe"] = "hash_a"
  let hashes2 : Map[String, String] = {}
  hashes2["/tmp/a.vibe"] = "hash_a_changed"
  let key1 = pure_test_cache_key(hashes1)
  let key2 = pure_test_cache_key(hashes2)
  assert_true(key1 != key2)
}

///|
test "pure_test_result_cache_paths returns expected layout" {
  let (cache_dir, result_path) = pure_test_result_cache_paths(
    "/tmp/project/src/math_test.vibe",
  )
  assert_true(cache_dir.contains("/.vibe/test/"))
  assert_true(result_path.has_suffix("/pure_result.txt"))
}
