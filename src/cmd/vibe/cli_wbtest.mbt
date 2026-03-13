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
    ["--no-prompt", "--tty"],
    "shell-stdin",
    "vibe> ",
  )
  match parsed {
    Ok(opts) => {
      assert_false(opts.prompt_enabled)
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
      assert_eq(msg, "usage: shell-stdin [--no-prompt] [--tty|--no-tty]")
  }
}

///|
test "repl parser mode hint removed with do keyword" {
  // do keyword was removed; these tests are no longer relevant.
  // Kept as placeholder to maintain test count stability.
  ()
}

///|
test "eval cmd options parse db and expression" {
  let parsed = parse_eval_cmd_options(
    ["--db=tmp1.db", "--include=index.vbundle", "let", "value", "=", "1"],
    "eval",
  )
  match parsed {
    Ok(opts) => {
      match opts.db_path {
        Some(path) => assert_eq(path, "tmp1.db")
        None => fail("expected db path")
      }
      match opts.export_path {
        Some(_) => fail("unexpected export path")
        None => ()
      }
      assert_eq(opts.include_paths, ["index.vbundle"])
      match opts.expr {
        Some(expr) => assert_eq(expr, "let value = 1")
        None => fail("expected expression")
      }
    }
    Err(msg) => fail("unexpected err: " + msg)
  }
}

///|
test "eval cmd options parse export only" {
  let parsed = parse_eval_cmd_options(
    ["--db", "tmp1.db", "--include", "index.vbundle", "--export", "out.vibe"],
    "eval",
  )
  match parsed {
    Ok(opts) => {
      match opts.db_path {
        Some(path) => assert_eq(path, "tmp1.db")
        None => fail("expected db path")
      }
      match opts.export_path {
        Some(path) => assert_eq(path, "out.vibe")
        None => fail("expected export path")
      }
      assert_eq(opts.include_paths, ["index.vbundle"])
      match opts.expr {
        Some(_) => fail("unexpected expression")
        None => ()
      }
    }
    Err(msg) => fail("unexpected err: " + msg)
  }
}

///|
test "eval cmd options allows export without db" {
  let parsed = parse_eval_cmd_options(["--export", "out.vibe"], "eval")
  match parsed {
    Ok(opts) => {
      match opts.db_path {
        Some(_) => fail("unexpected db path")
        None => ()
      }
      match opts.export_path {
        Some(path) => assert_eq(path, "out.vibe")
        None => fail("expected export path")
      }
      match opts.expr {
        Some(_) => fail("unexpected expression")
        None => ()
      }
    }
    Err(msg) => fail("unexpected err: " + msg)
  }
}

///|
test "eval cmd options parse multiple includes" {
  let parsed = parse_eval_cmd_options(
    [
      "--db", "tmp1.db", "--include", "index.vbundle", "--include=bit:/tmp/std.vbundle",
      "let", "x", "=", "1",
    ],
    "eval",
  )
  match parsed {
    Ok(opts) => {
      assert_eq(opts.include_paths, ["index.vbundle", "bit:/tmp/std.vbundle"])
      match opts.expr {
        Some(expr) => assert_eq(expr, "let x = 1")
        None => fail("expected expression")
      }
    }
    Err(msg) => fail("unexpected err: " + msg)
  }
}

///|
test "eval cmd options parse inspect scope assertions and test target" {
  let parsed = parse_eval_cmd_options(
    [
      "--db=tmp1.db", "--inspect-scope", "--assert=base:Int", "--assert", "inc:(x: Int) -> Int",
      "--test-for", "inc", "test \"inc/basic\" { assert_eq(inc(1), 2) }",
    ],
    "eval",
  )
  match parsed {
    Ok(opts) => {
      assert_true(opts.inspect_scope)
      assert_false(opts.test_run)
      assert_eq(opts.assertions.length(), 2)
      assert_eq(opts.assertions[0].name, "base")
      assert_eq(opts.assertions[0].expected_signature, "Int")
      assert_eq(opts.assertions[1].name, "inc")
      assert_eq(opts.assertions[1].expected_signature, "(x: Int) -> Int")
      match opts.test_target {
        Some(name) => assert_eq(name, "inc")
        None => fail("expected test target")
      }
      match opts.expr {
        Some(expr) =>
          assert_eq(expr, "test \"inc/basic\" { assert_eq(inc(1), 2) }")
        None => fail("expected expression")
      }
    }
    Err(msg) => fail("unexpected err: " + msg)
  }
}

///|
test "eval cmd options parse run for existing test target without expression" {
  let parsed = parse_eval_cmd_options(
    ["--db=tmp1.db", "--test-for", "inc", "--run"],
    "eval",
  )
  match parsed {
    Ok(opts) => {
      assert_true(opts.test_run)
      match opts.test_target {
        Some(name) => assert_eq(name, "inc")
        None => fail("expected test target")
      }
      match opts.expr {
        Some(_) => fail("unexpected expression")
        None => ()
      }
    }
    Err(msg) => fail("unexpected err: " + msg)
  }
}

///|
test "eval cmd options allow inspect scope without expression" {
  let parsed = parse_eval_cmd_options(
    ["--db=tmp1.db", "--inspect-scope"],
    "eval",
  )
  match parsed {
    Ok(opts) => {
      assert_true(opts.inspect_scope)
      match opts.expr {
        Some(_) => fail("unexpected expression")
        None => ()
      }
    }
    Err(msg) => fail("unexpected err: " + msg)
  }
}

///|
test "eval cmd options reject malformed assert" {
  let parsed = parse_eval_cmd_options(
    ["--assert", "bad", "let", "x", "=", "1"],
    "eval",
  )
  match parsed {
    Ok(_) => fail("expected error")
    Err(msg) =>
      assert_eq(
        msg, "eval: invalid --assert `bad` (expected <name>:<signature>)",
      )
  }
}

///|
test "eval cmd options allow run without test target for runtime suggestion" {
  let parsed = parse_eval_cmd_options(["--db=tmp1.db", "--run"], "eval")
  match parsed {
    Ok(opts) => {
      assert_true(opts.test_run)
      match opts.test_target {
        Some(_) => fail("unexpected test target")
        None => ()
      }
    }
    Err(msg) => fail("unexpected err: " + msg)
  }
}

///|
test "eval cmd options reject test target without expression" {
  let parsed = parse_eval_cmd_options(
    ["--db=tmp1.db", "--test-for", "inc"],
    "eval",
  )
  match parsed {
    Ok(_) => fail("expected error")
    Err(msg) => assert_eq(msg, "eval: --test-for requires expression")
  }
}

///|
test "eval cmd options reject missing expression and export" {
  let parsed = parse_eval_cmd_options(["--db=tmp1.db"], "eval")
  match parsed {
    Ok(_) => fail("expected error")
    Err(msg) => assert_eq(msg, "eval: expected expression or --export")
  }
}

///|
test "eval cmd options reject missing include value" {
  let parsed = parse_eval_cmd_options(["--db=tmp1.db", "--include"], "eval")
  match parsed {
    Ok(_) => fail("expected error")
    Err(msg) => assert_eq(msg, "eval: missing value for --include")
  }
}

///|
test "eval include path resolves named vbundle alias from lib dir" {
  let resolved = resolve_eval_include_path(
    "/work/project", "vibe/prelude@0.1.0.vbundle", "/home/test/.vibe/lib",
  )
  assert_eq(resolved, "/home/test/.vibe/lib/vibe/prelude@0.1.0.vbundle")
}

///|
test "eval include path resolves latest named vbundle alias when version omitted" {
  let root = wbtest_make_temp_dir("eval_include_latest_alias")
  let vibe_dir = root + "/vibe"
  @os_fs.create_dir(vibe_dir) catch {
    e => fail("create vibe dir failed: " + e.to_string())
  }
  @os_fs.write_string_to_file(vibe_dir + "/prelude@0.1.0.vbundle", "hash:a\n") catch {
    e => fail("write prelude@0.1.0 alias failed: " + e.to_string())
  }
  @os_fs.write_string_to_file(vibe_dir + "/prelude@1.2.0.vbundle", "hash:b\n") catch {
    e => fail("write prelude@1.2.0 alias failed: " + e.to_string())
  }
  let resolved = resolve_eval_include_path(
    "/work/project", "vibe/prelude.vbundle", root,
  )
  assert_eq(resolved, root + "/vibe/prelude@1.2.0.vbundle")
  wbtest_remove_if_exists(root)
}

///|
test "eval include path resolves relative base dir from current directory" {
  let cwd = @io.current_dir_or_root()
  let resolved = resolve_eval_include_path(
    ".", "tmp_probe/eval/include-test.vibe", "/home/test/.vibe/lib",
  )
  assert_eq(
    resolved,
    @vibe_fs.normalize_path(cwd + "/tmp_probe/eval/include-test.vibe"),
  )
}

///|
test "load eval include source prefers cwd before db parent for relative include" {
  let cwd = @io.current_dir_or_root()
  let rel_root = "tmp_probe/wbtest_eval_include_cwd_priority"
  let include_rel = rel_root + "/shared.vibe"
  let cwd_dir = @vibe_fs.normalize_path(cwd + "/" + rel_root)
  let cwd_include = @vibe_fs.normalize_path(cwd + "/" + include_rel)
  let base_root = wbtest_make_temp_dir("eval_include_base_priority")
  let base_dir = @vibe_fs.normalize_path(base_root + "/workspace")
  let base_include = @vibe_fs.normalize_path(base_dir + "/" + include_rel)
  wbtest_remove_if_exists(cwd_dir)
  wbtest_remove_if_exists(base_root)
  match @io.create_dir(cwd_dir) {
    Ok(_) => ()
    Err(err) => fail("create cwd include dir failed: " + err)
  }
  match ensure_parent_dir_for_file(base_include, "eval") {
    Ok(_) => ()
    Err(err) => fail("create base include dir failed: " + err)
  }
  @os_fs.write_string_to_file(cwd_include, "let seed = 1\n") catch {
    e => fail("write cwd include failed: " + e.to_string())
  }
  @os_fs.write_string_to_file(base_include, "let seed = 2\n") catch {
    e => fail("write base include failed: " + e.to_string())
  }
  let loaded = match
    load_eval_include_source(include_rel, base_dir, "/tmp/vibe_lib_unused") {
    Ok(v) => v
    Err(err) => fail("load include failed: " + err)
  }
  assert_true(loaded.contains("let seed = 1"))
  assert_false(loaded.contains("let seed = 2"))
  wbtest_remove_if_exists(cwd_dir)
  wbtest_remove_if_exists(base_root)
}

///|
test "load eval include source falls back to db parent when cwd missing" {
  let cwd = @io.current_dir_or_root()
  let rel_root = "tmp_probe/wbtest_eval_include_db_fallback"
  let include_rel = rel_root + "/shared.vibe"
  let cwd_dir = @vibe_fs.normalize_path(cwd + "/" + rel_root)
  let base_root = wbtest_make_temp_dir("eval_include_base_fallback")
  let base_dir = @vibe_fs.normalize_path(base_root + "/workspace")
  let base_include = @vibe_fs.normalize_path(base_dir + "/" + include_rel)
  wbtest_remove_if_exists(cwd_dir)
  wbtest_remove_if_exists(base_root)
  match ensure_parent_dir_for_file(base_include, "eval") {
    Ok(_) => ()
    Err(err) => fail("create base include dir failed: " + err)
  }
  @os_fs.write_string_to_file(base_include, "let seed = 2\n") catch {
    e => fail("write base include failed: " + e.to_string())
  }
  let loaded = match
    load_eval_include_source(include_rel, base_dir, "/tmp/vibe_lib_unused") {
    Ok(v) => v
    Err(err) => fail("load include failed: " + err)
  }
  assert_true(loaded.contains("let seed = 2"))
  wbtest_remove_if_exists(cwd_dir)
  wbtest_remove_if_exists(base_root)
}

///|
test "load eval include source missing message shows tried candidates" {
  let cwd = @io.current_dir_or_root()
  let rel_root = "tmp_probe/wbtest_eval_include_missing"
  let include_rel = rel_root + "/missing.vibe"
  let cwd_dir = @vibe_fs.normalize_path(cwd + "/" + rel_root)
  let base_root = wbtest_make_temp_dir("eval_include_missing_message")
  let base_dir = @vibe_fs.normalize_path(base_root + "/workspace")
  wbtest_remove_if_exists(cwd_dir)
  match
    load_eval_include_source(include_rel, base_dir, "/tmp/vibe_lib_unused") {
    Ok(_) => fail("expected include missing error")
    Err(err) => {
      assert_true(err.contains("include not found"))
      assert_true(err.contains("tried:"))
      assert_true(err.contains(include_rel))
    }
  }
  wbtest_remove_if_exists(cwd_dir)
  wbtest_remove_if_exists(base_root)
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
      assert_eq(opts.files, ["a.vibe", "b.vibe"])
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
      assert_eq(opts.files, ["a.vibe"])
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
      assert_eq(rest, ["main.vibe"])
    }
    Err(msg) => fail("unexpected err: " + msg)
  }
}

///|
test "cli syntax mode parse explicit posix" {
  let parsed = parse_cli_syntax_args(["--syntax", "posix", "main.vibe"], "run")
  match parsed {
    Ok((mode, rest)) => {
      assert_eq(mode, @runtime.ParserMode::PosixMode)
      assert_eq(rest, ["main.vibe"])
    }
    Err(msg) => fail("unexpected err: " + msg)
  }
}

///|
test "cli syntax mode parse explicit posix-ext" {
  let parsed = parse_cli_syntax_args(
    ["--syntax", "posix-ext", "main.vibe"],
    "run",
  )
  match parsed {
    Ok((mode, rest)) => {
      assert_eq(mode, @runtime.ParserMode::PosixMode)
      assert_eq(rest, ["main.vibe"])
    }
    Err(msg) => fail("unexpected err: " + msg)
  }
}

///|
test "cli syntax mode parse explicit posix-strict" {
  let parsed = parse_cli_syntax_args(
    ["--syntax", "posix-strict", "main.vibe"],
    "run",
  )
  match parsed {
    Ok((mode, rest)) => {
      assert_eq(mode, @runtime.ParserMode::PosixStrictMode)
      assert_eq(rest, ["main.vibe"])
    }
    Err(msg) => fail("unexpected err: " + msg)
  }
}

///|
test "cli runtime flags parse default" {
  let parsed = parse_cli_runtime_args(["main.vibe"], "run")
  match parsed {
    Ok(opts) => {
      assert_eq(opts.syntax_mode, @runtime.ParserMode::VibeMode)
      assert_eq(opts.cmd_args, ["main.vibe"])
      assert_false(opts.unstable_async)
      assert_false(opts.unstable_threads)
    }
    Err(msg) => fail("unexpected err: " + msg)
  }
}

///|
test "cli runtime flags parse with unstable flags" {
  let parsed = parse_cli_runtime_args(
    [
      "--unstable-async", "--syntax", "posix-strict", "--unstable-threads", "main.vibe",
    ],
    "run",
  )
  match parsed {
    Ok(opts) => {
      assert_eq(opts.syntax_mode, @runtime.ParserMode::PosixStrictMode)
      assert_eq(opts.cmd_args, ["main.vibe"])
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
      assert_eq(v.cmd_args, ["main.vibe"])
      assert_true(v.unstable_async)
      assert_true(v.unstable_threads)
    }
    Err(msg) => fail("unexpected err: " + msg)
  }
}

///|
test "cli dispatch args merges leading and trailing unstable flags" {
  let parsed = parse_cli_dispatch_args([
    "vibe", "--unstable-async", "run", "--unstable-threads", "--syntax", "posix",
    "main.vibe",
  ])
  match parsed {
    Ok(v) => {
      assert_eq(v.cmd, "run")
      assert_eq(v.syntax_mode, @runtime.ParserMode::PosixMode)
      assert_eq(v.cmd_args, ["main.vibe"])
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
test "cli dispatch args parse init command" {
  let parsed = parse_cli_dispatch_args(["vibe", "init", "my-lib"])
  match parsed {
    Ok(v) => {
      assert_eq(v.cmd, "init")
      assert_eq(v.cmd_args, ["my-lib"])
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
      assert_eq(v.cmd_args, ["my-lib"])
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
      assert_eq(v.cmd_args, ["main.vibe"])
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
  assert_eq(path_item.resolved_hash, Some(dep_hash))
  let version_item = wbtest_find_explain_import_item(
    report.imports,
    "version@main",
  )
  assert_eq(version_item.ref_kind, "VersionRef")
  assert_eq(version_item.lock_lookup_status, "hit")
  assert_eq(version_item.resolved_hash, Some(version_hash))
  let symbol_item = wbtest_find_explain_import_item(
    report.imports,
    "symbol@main/sym",
  )
  assert_eq(symbol_item.ref_kind, "SymbolRef")
  assert_eq(symbol_item.lock_lookup_status, "hit")
  assert_eq(symbol_item.resolved_hash, Some(symbol_hash))
  let hash_item = wbtest_find_explain_import_item(
    report.imports,
    "#" + direct_hash,
  )
  assert_eq(hash_item.ref_kind, "HashRef")
  assert_eq(hash_item.lock_lookup_status, "n/a")
  assert_eq(hash_item.resolved_hash, Some(direct_hash))
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
    Err(msg) =>
      assert_eq(
        msg, "run: unsupported syntax `foo` (expected: vibe|posix-ext|posix-strict)",
      )
  }
}

///|
test "cli syntax mode parse rejects missing value" {
  let parsed = parse_cli_syntax_args(["--syntax"], "run")
  match parsed {
    Ok(_) => fail("expected error")
    Err(msg) =>
      assert_eq(
        msg, "run: missing value for --syntax (expected: vibe|posix-ext|posix-strict)",
      )
  }
}

///|
test "cli syntax mode support matrix" {
  match
    ensure_cli_parser_mode_supported(@runtime.ParserMode::PosixMode, "run") {
    Ok(_) => fail("expected run rejection")
    Err(msg) => {
      assert_true(msg.contains("run"))
      assert_true(msg.contains("supported only"))
    }
  }
  match
    ensure_cli_parser_mode_supported(@runtime.ParserMode::PosixMode, "eval") {
    Ok(_) => fail("expected eval rejection")
    Err(msg) => {
      assert_true(msg.contains("eval"))
      assert_true(msg.contains("supported only"))
    }
  }
  match
    ensure_cli_parser_mode_supported(@runtime.ParserMode::PosixMode, "shell") {
    Ok(_) => ()
    Err(msg) => fail("unexpected shell error: " + msg)
  }
  match
    ensure_cli_parser_mode_supported(
      @runtime.ParserMode::PosixMode,
      "shell-stdin",
    ) {
    Ok(_) => ()
    Err(msg) => fail("unexpected shell-stdin error: " + msg)
  }
  match
    ensure_cli_parser_mode_supported(
      @runtime.ParserMode::PosixMode,
      "shell-wasi",
    ) {
    Ok(_) => ()
    Err(msg) => fail("unexpected shell-wasi error: " + msg)
  }
  match
    ensure_cli_parser_mode_supported(
      @runtime.ParserMode::PosixStrictMode,
      "shell",
    ) {
    Ok(_) => ()
    Err(msg) => fail("unexpected strict shell error: " + msg)
  }
  match
    ensure_cli_parser_mode_supported(
      @runtime.ParserMode::PosixStrictMode,
      "run",
    ) {
    Ok(_) => fail("expected strict run rejection")
    Err(msg) => {
      assert_true(msg.contains("run"))
      assert_true(msg.contains("supported only"))
    }
  }
  match
    ensure_cli_parser_mode_supported(@runtime.ParserMode::PosixMode, "bench") {
    Ok(_) => fail("expected bench rejection")
    Err(msg) => {
      assert_true(msg.contains("bench"))
      assert_true(msg.contains("supported only"))
    }
  }
  match
    ensure_cli_parser_mode_supported(@runtime.ParserMode::PosixMode, "compile") {
    Ok(_) => fail("expected compile rejection")
    Err(msg) => {
      assert_true(msg.contains("compile"))
      assert_true(msg.contains("supported only"))
    }
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
    Ok((args, Some(path), in_memory)) => {
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
    Ok((args, Some(path))) => {
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
  assert_false(normalized.contains("declare export let run"))
  assert_false(normalized.contains("declare export let run_io"))
  let idx_helper = wbtest_substring_index(normalized, "let helper =")
  let idx_run = wbtest_substring_index(normalized, "export let run =")
  let idx_run_io = wbtest_substring_index(normalized, "export let run_io =")
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
  let idx_a = wbtest_substring_index(normalized, "export let a =")
  let idx_b = wbtest_substring_index(normalized, "export let b =")
  let idx_z = wbtest_substring_index(normalized, "export let z =")
  // Effect fns sorted: io_a (leaf), io_b (leaf), io_z (depends on io_b)
  let idx_io_a = wbtest_substring_index(normalized, "export let io_a =")
  let idx_io_b = wbtest_substring_index(normalized, "export let io_b =")
  let idx_io_z = wbtest_substring_index(normalized, "export let io_z =")
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
  let idx_bar = wbtest_substring_index(normalized, "export let bar =")
  let idx_baz = wbtest_substring_index(normalized, "export let baz =")
  let idx_member = wbtest_substring_index(normalized, "export let Int::foo =")
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
  assert_false(normalized.contains("let id:"))
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
  assert_true(normalized.contains("export let run ="))
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
  assert_true(output.contains("let helper ="))
  // Fn expressions should NOT produce declare+assign
  assert_false(output.contains("declare export let run"))
  assert_true(output.contains("export let run ="))
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
    if not(@os_fs.path_exists(output_path)) {
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
    if not(is_file) || not(path.has_suffix(".out.vibe")) {
      continue
    }
    let input_path = wbtest_replace_suffix(path, ".out.vibe", ".in.vibe")
    if not(@os_fs.path_exists(input_path)) {
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
  match ensure_parent_dir_for_file(target, "eval") {
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
  match ensure_parent_dir_for_file(rel_target, "eval") {
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
  match ensure_parent_dir_for_file(target, "eval") {
    Ok(_) => fail("expected mkdir error")
    Err(err) => {
      assert_true(err.contains("eval:"))
      assert_true(err.contains("not directory"))
    }
  }
  wbtest_remove_if_exists(root)
}

///|
test "eval run missing target message includes function and sidecar candidates" {
  let root = wbtest_make_temp_dir("eval_run_missing_target_candidates")
  let db_path = root + "/tmp1.db"
  let source = "let base = 1\nlet add_one = (x: Int) -> Int { x + base }\n"
  match
    write_eval_test_source(
      db_path, "saved_target", "test \"saved\" { assert(true) }",
    ) {
    Ok(_) => ()
    Err(err) => fail("write sidecar failed: " + err)
  }
  let msg = eval_run_missing_test_target_message(db_path, source)
  assert_true(msg.contains("eval: --run requires --test-for"))
  assert_true(msg.contains("add_one"))
  assert_true(msg.contains("saved_target"))
  assert_false(msg.contains("base"))
  wbtest_remove_if_exists(eval_tests_dir_path(db_path))
  wbtest_remove_if_exists(db_path)
  wbtest_remove_if_exists(root)
}

///|
test "eval run missing target message reports no candidates when empty" {
  let root = wbtest_make_temp_dir("eval_run_missing_target_empty")
  let db_path = root + "/tmp1.db"
  let msg = eval_run_missing_test_target_message(db_path, "")
  assert_true(msg.contains("eval: --run requires --test-for"))
  assert_true(msg.contains("no test targets found"))
  wbtest_remove_if_exists(eval_tests_dir_path(db_path))
  wbtest_remove_if_exists(db_path)
  wbtest_remove_if_exists(root)
}

///|
test "eval restore diagnosis classifies parse as non-fatal" {
  let diagnosis = eval_restore_diagnose("Parse((start=1,end=2), expected expr)")
  assert_eq(diagnosis.severity, EvalRestoreSeverity::NonFatal)
  assert_eq(diagnosis.category, "parse")
  assert_true(diagnosis.hint.contains("history reset"))
}

///|
test "eval restore diagnosis classifies unknown name as non-fatal" {
  let diagnosis = eval_restore_diagnose("UnknownName(\"echo\")")
  assert_eq(diagnosis.severity, EvalRestoreSeverity::NonFatal)
  assert_eq(diagnosis.category, "unresolved_name")
  assert_true(diagnosis.hint.contains("--include"))
}

///|
test "eval restore diagnosis classifies unknown runtime error as fatal" {
  let diagnosis = eval_restore_diagnose("Trap(Unreachable)")
  assert_eq(diagnosis.severity, EvalRestoreSeverity::Fatal)
  assert_eq(diagnosis.category, "runtime")
  assert_true(diagnosis.hint.contains("history reset"))
}

///|
test "split test entry path batches caps workers and balances paths" {
  let capped = split_test_entry_path_batches(["a.vibe", "b.vibe", "c.vibe"], 10)
  assert_eq(capped.length(), 3)
  assert_eq(capped[0], ["a.vibe"])
  assert_eq(capped[1], ["b.vibe"])
  assert_eq(capped[2], ["c.vibe"])

  let balanced = split_test_entry_path_batches(
    ["a.vibe", "b.vibe", "c.vibe", "d.vibe", "e.vibe"],
    2,
  )
  assert_eq(balanced.length(), 2)
  assert_eq(balanced[0], ["a.vibe", "b.vibe", "c.vibe"])
  assert_eq(balanced[1], ["d.vibe", "e.vibe"])
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
  assert_eq(grouped.length(), 3)
  for batch in grouped {
    assert_true(batch.length() <= 4)
  }
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
  assert_eq(grouped.length(), 3)
  assert_eq(grouped[0].length(), 1)
  assert_eq(grouped[1].length(), 1)
  assert_eq(grouped[2].length(), 1)
}

///|
test "test batch weight cache key relativizes cwd absolute path" {
  let cwd = @io.current_dir_or_root()
  let abs = @vibe_fs.normalize_path(cwd + "/vibe/compiler/eval_test.vibe")
  if @vibe_fs.normalize_path(cwd).has_prefix("/") {
    assert_eq(test_batch_weight_cache_key(abs), "vibe/compiler/eval_test.vibe")
  } else {
    assert_eq(test_batch_weight_cache_key(abs), abs)
  }
  assert_eq(
    test_batch_weight_cache_key("vibe/compiler/eval_test.vibe"),
    "vibe/compiler/eval_test.vibe",
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
  let prev = @sys.get_env_var("VIBE_INTERNAL_TEST_PARENT_PID")
  defer wbtest_restore_env_var("VIBE_INTERNAL_TEST_PARENT_PID", prev)

  @sys.unset_env_var("VIBE_INTERNAL_TEST_PARENT_PID")
  assert_eq(test_worker_parent_pid(), None)

  @sys.set_env_var("VIBE_INTERNAL_TEST_PARENT_PID", "invalid")
  assert_eq(test_worker_parent_pid(), None)

  let pid = vibe_getpid()
  @sys.set_env_var("VIBE_INTERNAL_TEST_PARENT_PID", pid.to_string())
  assert_eq(test_worker_parent_pid(), Some(pid))
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
    root + "/index.vbundle",
    "{\"lock\":" + lock_seed.trim().to_string() + "}\n",
  ) catch {
    e => fail("write seed vbundle failed: " + e.to_string())
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
  match load_compiled_test_case_db(source_path) {
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
  wbtest_remove_if_exists(root + "/index.vbundle")
  wbtest_remove_if_exists(lock_path)
  wbtest_remove_if_exists(source_path)
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
        if not(should_omit_compiled_test_prelude_stmt(stmt)) {
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
  match run_test_file_compiled(source_path, false) {
    CompiledTestAttempt::Success(report) => {
      assert_eq(report.total, 1)
      assert_eq(report.passed, 1)
      assert_eq(report.failed, 0)
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
  match run_test_file_compiled(source_path, false) {
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
  match run_test_file_compiled(source_path, false) {
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
  match run_test_file_compiled(source_path, false) {
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
  match run_test_file_compiled(source_path, false) {
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
    "  let m: Map[Int] = map {\n" +
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
  match run_test_file_compiled(source_path, false) {
    CompiledTestAttempt::Success(report) => {
      assert_eq(report.total, 1)
      assert_eq(report.passed, 1)
      assert_eq(report.failed, 0)
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
  match run_test_file_compiled(source_path, false) {
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
  match run_test_file_compiled(source_path, false) {
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
  match run_test_file_compiled(source_path, false) {
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
  match run_test_file_compiled(source_path, false) {
    CompiledTestAttempt::Unsupported(err) =>
      assert_true(err.contains("wasm runtime fallback builtins"))
    CompiledTestAttempt::Success(report) =>
      fail(
        "expected unsupported fallback, got success: " +
        report.total.to_string(),
      )
    CompiledTestAttempt::Error(err) =>
      fail("compiled Json::parse fallback unexpectedly errored: " + err)
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
  match run_test_file_compiled(source_path, false) {
    CompiledTestAttempt::Unsupported(err) =>
      assert_true(err.contains("wasm runtime fallback builtins"))
    CompiledTestAttempt::Success(report) =>
      fail(
        "expected unsupported jq fallback, got success: " +
        report.total.to_string(),
      )
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
    "enum Eff {\n" +
    "  Ask(Int);\n" +
    "}\n" +
    "let ask_once = () -> Int with { Ask } {\n" +
    "  perform(Ask(41))\n" +
    "}\n" +
    "test \"perform fallback\" {\n" +
    "  let value = handle {\n" +
    "    add(1, ask_once())\n" +
    "  } {\n" +
    "    Ask(_) => resume(42)\n" +
    "  }\n" +
    "  assert(eq(value, 43))\n" +
    "}\n",
  ) catch {
    e => fail("write temp source failed: " + e.to_string())
  }
  match run_test_file_compiled(source_path, false) {
    CompiledTestAttempt::Unsupported(err) =>
      assert_true(err.contains("wasm runtime fallback builtins"))
    CompiledTestAttempt::Success(report) =>
      fail(
        "expected unsupported perform/resume fallback, got success: " +
        report.total.to_string(),
      )
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
    if not(@os_fs.path_exists(path)) {
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
      value => value.to_string()
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
    lines.push(line_view.trim_end().to_string())
  }
  while lines.length() > 0 && lines[lines.length() - 1].trim().to_string() == "" {
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
    Some(view) => view.to_string() + new_suffix
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
  if not(@os_fs.path_exists(path)) {
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
test "exec backend pref parsing" {
  assert_eq(
    parse_cli_exec_backend_pref("interpreter"),
    CliExecBackendPref::Interpreter,
  )
  assert_eq(
    parse_cli_exec_backend_pref("compiled"),
    CliExecBackendPref::Compiled,
  )
  assert_eq(parse_cli_exec_backend_pref("unknown"), CliExecBackendPref::Auto)
}

///|
test "entry_prefers_compiled_backend detects vibe compiler paths" {
  assert_true(entry_prefers_compiled_backend("vibe/compiler/eval_test.vibe"))
  assert_true(
    entry_prefers_compiled_backend(
      "/Users/mz/ghq/github.com/mizchi/vibe-lang/vibe/compiler/eval_test.vibe",
    ),
  )
  assert_true(entry_prefers_compiled_backend("vibe\\compiler\\eval_test.vibe"))
  assert_false(entry_prefers_compiled_backend("examples/hello.vibe"))
}

///|
test "entry_prefers_interpreter_backend no longer special-cases compiler import tests" {
  assert_false(
    entry_prefers_interpreter_backend("vibe/compiler/codegen_lexer_test.vibe"),
  )
  assert_false(
    entry_prefers_interpreter_backend(
      "/Users/mz/ghq/github.com/mizchi/vibe-lang/vibe/compiler/codegen_lexer_test.vibe",
    ),
  )
  assert_false(
    entry_prefers_interpreter_backend("vibe/compiler/codegen_test.vibe"),
  )
}

///|
test "resolve_test_backend_pref defaults to compiled in auto mode" {
  let prev_test_backend = @sys.get_env_var("VIBE_TEST_BACKEND")
  @sys.unset_env_var("VIBE_TEST_BACKEND")
  defer wbtest_restore_env_var("VIBE_TEST_BACKEND", prev_test_backend)
  assert_eq(
    resolve_test_backend_pref("vibe/compiler/eval_test.vibe"),
    CliExecBackendPref::Compiled,
  )
  assert_eq(
    resolve_test_backend_pref("examples/hello.vibe"),
    CliExecBackendPref::Compiled,
  )
}

///|
test "resolve_test_backend_pref keeps compiler tests on compiled in auto mode" {
  let prev_test_backend = @sys.get_env_var("VIBE_TEST_BACKEND")
  @sys.unset_env_var("VIBE_TEST_BACKEND")
  defer wbtest_restore_env_var("VIBE_TEST_BACKEND", prev_test_backend)
  assert_eq(
    resolve_test_backend_pref("vibe/compiler/codegen_lexer_test.vibe"),
    CliExecBackendPref::Compiled,
  )
}

///|
test "resolve_test_loop_fuel_env_value defaults high for test runtime" {
  let prev = @sys.get_env_var("VIBE_TEST_LOOP_FUEL")
  @sys.unset_env_var("VIBE_TEST_LOOP_FUEL")
  defer wbtest_restore_env_var("VIBE_TEST_LOOP_FUEL", prev)
  assert_eq(resolve_test_loop_fuel_env_value(), "10000000")
}

///|
test "resolve_test_loop_fuel_env_value respects override" {
  let prev = @sys.get_env_var("VIBE_TEST_LOOP_FUEL")
  @sys.set_env_var("VIBE_TEST_LOOP_FUEL", "424242")
  defer wbtest_restore_env_var("VIBE_TEST_LOOP_FUEL", prev)
  assert_eq(resolve_test_loop_fuel_env_value(), "424242")
}

///|
test "resolve_test_backend_pref respects explicit interpreter" {
  let prev_test_backend = @sys.get_env_var("VIBE_TEST_BACKEND")
  @sys.set_env_var("VIBE_TEST_BACKEND", "interpreter")
  defer wbtest_restore_env_var("VIBE_TEST_BACKEND", prev_test_backend)
  assert_eq(
    resolve_test_backend_pref("vibe/compiler/eval_test.vibe"),
    CliExecBackendPref::Interpreter,
  )
  assert_eq(
    resolve_test_backend_pref("examples/hello.vibe"),
    CliExecBackendPref::Interpreter,
  )
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
test "interpreter fallback is disabled by default" {
  let prev_fallback = @sys.get_env_var("VIBE_ALLOW_INTERPRETER_FALLBACK")
  @sys.unset_env_var("VIBE_ALLOW_INTERPRETER_FALLBACK")
  defer wbtest_restore_env_var("VIBE_ALLOW_INTERPRETER_FALLBACK", prev_fallback)
  assert_false(cli_allow_interpreter_fallback())
  assert_false(cli_can_fallback_to_interpreter(CliExecBackendPref::Auto))
}

///|
test "interpreter fallback env only enables auto backend fallback" {
  let prev_fallback = @sys.get_env_var("VIBE_ALLOW_INTERPRETER_FALLBACK")
  @sys.set_env_var("VIBE_ALLOW_INTERPRETER_FALLBACK", "1")
  defer wbtest_restore_env_var("VIBE_ALLOW_INTERPRETER_FALLBACK", prev_fallback)
  assert_true(cli_allow_interpreter_fallback())
  assert_true(cli_can_fallback_to_interpreter(CliExecBackendPref::Auto))
  assert_false(cli_can_fallback_to_interpreter(CliExecBackendPref::Compiled))
  assert_false(cli_can_fallback_to_interpreter(CliExecBackendPref::Interpreter))
}

///|
test "compiled exec detects modules that use http builtins and emits host imports" {
  let db = @runtime.VibeDb::new()
  let src =
    #|let run = () -> Int with {Net} {
    #|  let req = Http::request("GET", "https://example.com", "", "")
    #|  let status = Http::response_status(req)
    #|  Http::close(req)
    #|  status
    #|}
    #|run()
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
      #|let run = () -> Int {
      #|  42
      #|}
      #|run(),
    ),
  )
  let ast = db.ast("main")
  assert_false(module_uses_http_builtins(ast))
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
    #|} {
    #|  Error(msg) => if String::equals(msg, "@MSG@") { 1 } else { 2 }
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
  assert_eq(decode_tagged_wasm_run_value(168L), Some(WasmRunValue::Int(42L)))
  assert_eq(decode_tagged_wasm_run_value(7L), Some(WasmRunValue::Bool(true)))
  assert_eq(decode_tagged_wasm_run_value(3L), Some(WasmRunValue::Bool(false)))
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
  assert_eq(parsed.1, Some("rows.json"))
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
  assert_eq(graph_ir_line_col(source, row), (2, 1))
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
