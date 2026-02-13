///|
test "completion context for let" {
  let line = "let add2 = (x: Int, y: Int) { add(x, y) }"
  let ctx = detect_completion_context(line, line.length())
  match ctx {
    CompletionContext::XshLetExpr => ()
    _ => fail("expected let expr context")
  }
  let ctx2 = detect_completion_context("let ", 4)
  match ctx2 {
    CompletionContext::XshLetName => ()
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
test "repl input rows grow with height" {
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
test "line repl options parse default" {
  let parsed = parse_line_repl_options([], "repl-stdin", "vibe> ")
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
test "line repl options parse tty and no prompt" {
  let parsed = parse_line_repl_options(
    ["--no-prompt", "--tty"],
    "repl-stdin",
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
test "line repl options reject unknown arg" {
  let parsed = parse_line_repl_options(["--wat"], "repl-stdin", "vibe> ")
  match parsed {
    Ok(_) => fail("expected error")
    Err(msg) => assert_eq(msg, "repl-stdin: unknown arg --wat")
  }
}

///|
test "eval cmd options parse db and expression" {
  let parsed = parse_eval_cmd_options(
    ["--db=tmp1.db", "--include=index.vdb", "let", "value", "=", "1"],
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
      assert_eq(opts.include_paths, ["index.vdb"])
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
    ["--db", "tmp1.db", "--include", "index.vdb", "--export", "out.vibe"],
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
      assert_eq(opts.include_paths, ["index.vdb"])
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
      "--db", "tmp1.db", "--include", "index.vdb", "--include=bit:/tmp/std.vdb",
      "let", "x", "=", "1",
    ],
    "eval",
  )
  match parsed {
    Ok(opts) => {
      assert_eq(opts.include_paths, ["index.vdb", "bit:/tmp/std.vdb"])
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
test "eval cmd options reject run without test target" {
  let parsed = parse_eval_cmd_options(["--db=tmp1.db", "--run"], "eval")
  match parsed {
    Ok(_) => fail("expected error")
    Err(msg) => assert_eq(msg, "eval: --run requires --test-for")
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
test "eval include path resolves named vdb alias from lib dir" {
  let resolved = resolve_eval_include_path(
    "/work/project", "vibe/std@0.1.0.vdb", "/home/test/.vibe/lib",
  )
  assert_eq(resolved, "/home/test/.vibe/lib/vibe/std@0.1.0.vdb")
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
      assert_eq(mode, @runtime.ParserMode::XshMode)
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
test "cli runtime flags parse default" {
  let parsed = parse_cli_runtime_args(["main.vibe"], "run")
  match parsed {
    Ok(opts) => {
      assert_eq(opts.syntax_mode, @runtime.ParserMode::XshMode)
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
    ["--unstable-async", "--syntax", "posix", "--unstable-threads", "main.vibe"],
    "run",
  )
  match parsed {
    Ok(opts) => {
      assert_eq(opts.syntax_mode, @runtime.ParserMode::PosixMode)
      assert_eq(opts.cmd_args, ["main.vibe"])
      assert_true(opts.unstable_async)
      assert_true(opts.unstable_threads)
    }
    Err(msg) => fail("unexpected err: " + msg)
  }
}

///|
test "cli dispatch args parse leading unstable flags" {
  let parsed = parse_cli_dispatch_args([
    "xsh", "--unstable-async", "--unstable-threads", "run", "main.vibe",
  ])
  match parsed {
    Ok(v) => {
      assert_eq(v.cmd, "run")
      assert_eq(v.syntax_mode, @runtime.ParserMode::XshMode)
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
    "xsh", "--unstable-async", "run", "--unstable-threads", "--syntax", "posix",
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
    "xsh", "--unstable-async", "--unstable-threads",
  ])
  match parsed {
    Ok(_) => fail("expected error")
    Err(msg) => assert_eq(msg, "missing command")
  }
}

///|
test "cli dispatch args parse init command" {
  let parsed = parse_cli_dispatch_args(["xsh", "init", "my-lib"])
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
  let parsed = parse_cli_dispatch_args(["xsh", "new", "my-lib"])
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
  let parsed = parse_cli_dispatch_args(["xsh", "explain-import", "main.vibe"])
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
  let main_source = "use ./dep.vibe { value }\n" +
    "use version@main { value }\n" +
    "use symbol@main/sym { value }\n" +
    "use #\{direct_hash} { value }\n" +
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
  let main_source = "use ./dep.vibe { value }\n" +
    "use version@missing { value }\n" +
    "use symbol@missing/sym { value }\n" +
    "use #\{missing_hash} { value }\n" +
    "use unknown_ns/lib.vibe { value }\n" +
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
      assert_eq(msg, "run: unsupported syntax `foo` (expected: xsh|posix)")
  }
}

///|
test "cli syntax mode parse rejects missing value" {
  let parsed = parse_cli_syntax_args(["--syntax"], "run")
  match parsed {
    Ok(_) => fail("expected error")
    Err(msg) =>
      assert_eq(msg, "run: missing value for --syntax (expected: xsh|posix)")
  }
}

///|
test "cli syntax mode support matrix" {
  match
    ensure_cli_parser_mode_supported(@runtime.ParserMode::PosixMode, "run") {
    Ok(_) => ()
    Err(msg) => fail("unexpected run error: " + msg)
  }
  match
    ensure_cli_parser_mode_supported(@runtime.ParserMode::PosixMode, "eval") {
    Ok(_) => ()
    Err(msg) => fail("unexpected eval error: " + msg)
  }
  match
    ensure_cli_parser_mode_supported(@runtime.ParserMode::PosixMode, "repl") {
    Ok(_) => ()
    Err(msg) => fail("unexpected repl error: " + msg)
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
        msg, "compile: --wite/-O* is only supported with --wasm, --wasm-js-string, --wasm-gc, or --component",
      )
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
test "line repl extract let name" {
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
    #|use ./dep.vibe { dep }
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
  let idx_use = wbtest_substring_index(normalized, "use ./dep.vibe {")
  let idx_trait = wbtest_substring_index(normalized, "trait Eq")
  let idx_decl_run = wbtest_substring_index(
    normalized, "declare export let run: () -> Int",
  )
  let idx_decl_run_io = wbtest_substring_index(
    normalized, "declare export let run_io: () -> Int with {",
  )
  let idx_pure_fn = wbtest_substring_index(normalized, "let helper =")
  let idx_effect_fn = wbtest_substring_index(
    normalized, "run_io = () -> Int with {",
  )
  assert_true(idx_use >= 0)
  assert_true(idx_trait >= 0)
  assert_true(idx_decl_run >= 0)
  assert_true(idx_decl_run_io >= 0)
  assert_true(idx_pure_fn >= 0)
  assert_true(idx_effect_fn >= 0)
  assert_true(idx_use < idx_trait)
  assert_true(idx_trait < idx_decl_run)
  assert_true(idx_decl_run < idx_decl_run_io)
  assert_true(idx_decl_run_io < idx_pure_fn)
  assert_true(idx_pure_fn < idx_effect_fn)
  assert_false(normalized.contains("export let run ="))
  assert_false(normalized.contains("export let run_io ="))
}

///|
test "normalize source keeps module blocks and sorts module body" {
  let source =
    #|export module math {
    #|  let dead = () -> Int { 0 }
    #|  let helper = () -> Int { 1 }
    #|  type Alias = Int
    #|  export let run = () -> Int { helper() }
    #|  export let run_io = () -> Int with {Error} { run() }
    #|}
  let normalized = match normalize_source_text(source) {
    Ok(v) => v
    Err(msg) => fail("normalize failed: " + msg)
  }
  assert_true(normalized.contains("export module math {"))
  assert_false(normalized.contains("let dead ="))
  assert_false(normalized.contains("type Alias = Int"))
  let idx_decl_run = wbtest_substring_index(
    normalized, "declare export let run: () -> Int",
  )
  let idx_decl_run_io = wbtest_substring_index(
    normalized, "declare export let run_io: () -> Int with {",
  )
  let idx_helper = wbtest_substring_index(normalized, "let helper =")
  let idx_run = wbtest_substring_index(normalized, "run =")
  let idx_run_io = wbtest_substring_index(
    normalized, "run_io = () -> Int with {",
  )
  assert_true(idx_decl_run >= 0)
  assert_true(idx_decl_run_io >= 0)
  assert_true(idx_helper >= 0)
  assert_true(idx_run >= 0)
  assert_true(idx_run_io >= 0)
  assert_true(idx_decl_run < idx_decl_run_io)
  assert_true(idx_decl_run_io < idx_helper)
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
  let idx_decl_a = wbtest_substring_index(
    normalized, "declare export let a: () -> Int",
  )
  let idx_decl_b = wbtest_substring_index(
    normalized, "declare export let b: () -> Int",
  )
  let idx_decl_z = wbtest_substring_index(
    normalized, "declare export let z: () -> Int",
  )
  let idx_a = wbtest_substring_index(normalized, "a =")
  let idx_b = wbtest_substring_index(normalized, "b =")
  let idx_z = wbtest_substring_index(normalized, "z =")
  let idx_decl_io_a = wbtest_substring_index(
    normalized, "declare export let io_a: () -> Int with {",
  )
  let idx_decl_io_b = wbtest_substring_index(
    normalized, "declare export let io_b: () -> Int with {",
  )
  let idx_decl_io_z = wbtest_substring_index(
    normalized, "declare export let io_z: () -> Int with {",
  )
  let idx_io_a = wbtest_substring_index(normalized, "io_a = () -> Int with {")
  let idx_io_b = wbtest_substring_index(normalized, "io_b = () -> Int with {")
  let idx_io_z = wbtest_substring_index(normalized, "io_z = () -> Int with {")
  assert_true(idx_decl_a >= 0)
  assert_true(idx_decl_b >= 0)
  assert_true(idx_decl_z >= 0)
  assert_true(idx_a >= 0)
  assert_true(idx_b >= 0)
  assert_true(idx_z >= 0)
  assert_true(idx_decl_io_a >= 0)
  assert_true(idx_decl_io_b >= 0)
  assert_true(idx_decl_io_z >= 0)
  assert_true(idx_io_a >= 0)
  assert_true(idx_io_b >= 0)
  assert_true(idx_io_z >= 0)
  assert_true(idx_decl_a < idx_decl_b)
  assert_true(idx_decl_b < idx_decl_z)
  assert_true(idx_decl_z < idx_decl_io_a)
  assert_true(idx_decl_io_a < idx_decl_io_b)
  assert_true(idx_decl_io_b < idx_decl_io_z)
  assert_true(idx_decl_io_z < idx_a)
  assert_true(idx_a < idx_b)
  assert_true(idx_b < idx_z)
  assert_true(idx_io_a < idx_io_b)
  assert_true(idx_io_b < idx_io_z)
  assert_true(idx_z < idx_io_a)
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
  let idx_decl_bar = wbtest_substring_index(
    normalized, "declare export let bar: () -> Int",
  )
  let idx_decl_baz = wbtest_substring_index(
    normalized, "declare export let baz: () -> Int",
  )
  let idx_decl_member = wbtest_substring_index(
    normalized, "declare export let Int::foo: (Int) -> Int",
  )
  let idx_bar = wbtest_substring_index(normalized, "bar =")
  let idx_baz = wbtest_substring_index(normalized, "baz =")
  let idx_member = wbtest_substring_index(normalized, "Int::foo =")
  assert_true(idx_decl_bar >= 0)
  assert_true(idx_decl_baz >= 0)
  assert_true(idx_decl_member >= 0)
  assert_true(idx_bar >= 0)
  assert_true(idx_baz >= 0)
  assert_true(idx_member >= 0)
  assert_true(idx_decl_bar < idx_decl_baz)
  assert_true(idx_decl_baz < idx_decl_member)
  assert_true(idx_decl_member < idx_bar)
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
test "normalize source renders export let as declare signature + assignment" {
  let source =
    #|let helper = () -> Int { 1 }
    #|export let run = () -> Int { helper() }
    #|export { run }
  let normalized = match normalize_source_text(source) {
    Ok(v) => v
    Err(msg) => fail("normalize failed: " + msg)
  }
  let idx_decl = wbtest_substring_index(
    normalized, "declare export let run: () -> Int",
  )
  let idx_assign = wbtest_substring_index(normalized, "run = () -> Int {")
  assert_true(idx_decl >= 0)
  assert_true(idx_assign >= 0)
  assert_true(idx_decl < idx_assign)
  assert_false(normalized.contains("export let run ="))
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
test "normalize source drops rhs param annotation for declared export let assignment" {
  let source =
    #|declare export let inc: (Int) -> Int
    #|inc = (v: Int) -> Int { 1 }
  let normalized = match normalize_source_text(source) {
    Ok(v) => v
    Err(msg) => fail("normalize failed: " + msg)
  }
  assert_true(normalized.contains("declare export let inc: (Int) -> Int"))
  assert_true(normalized.contains("inc = (v) -> Int {"))
  assert_false(normalized.contains("(v: Int) -> Int { 1 }"))
}

///|
test "normalize source keeps rhs param annotation when type params exist" {
  let source = "export let id = [T](v: T) -> T { v }"
  let ast = @parser.parse_ast(source) catch {
    e => fail("parse failed: " + e.to_string())
  }
  let expr = match ast.stmts[0] {
    @vibe_core.Stmt::ExportLet(expr~, ..) => expr
    _ => fail("expected export let")
  }
  let stripped = normalize_render_decl_assign_fn_without_param_annotations(
    source,
    "id",
    None,
    expr,
  )
  assert_eq(stripped, None)
}

///|
test "std layer classification covers primary modules" {
  let trait_layer = match
    std_layer_for_path("/tmp/repo/vibe/std/builtin_traits.vibe") {
    Some(v) => std_layer_name(v)
    None => "none"
  }
  assert_eq(trait_layer, "trait-contract")

  let primitive_layer = match
    std_layer_for_path("/tmp/repo/vibe/std/string.vibe") {
    Some(v) => std_layer_name(v)
    None => "none"
  }
  assert_eq(primitive_layer, "pure-primitive")
  let primitive_layer_cmp = match
    std_layer_for_path("/tmp/repo/vibe/std/cmp.vibe") {
    Some(v) => std_layer_name(v)
    None => "none"
  }
  assert_eq(primitive_layer_cmp, "pure-primitive")
  let primitive_layer_char = match
    std_layer_for_path("/tmp/repo/vibe/std/char.vibe") {
    Some(v) => std_layer_name(v)
    None => "none"
  }
  assert_eq(primitive_layer_char, "pure-primitive")

  let data_layer = match std_layer_for_path("/tmp/repo/vibe/std/array.vibe") {
    Some(v) => std_layer_name(v)
    None => "none"
  }
  assert_eq(data_layer, "pure-data")
  let list_layer = match std_layer_for_path("/tmp/repo/vibe/std/list.vibe") {
    Some(v) => std_layer_name(v)
    None => "none"
  }
  assert_eq(list_layer, "none")
  let data_layer_bytes = match
    std_layer_for_path("/tmp/repo/vibe/std/bytes.vibe") {
    Some(v) => std_layer_name(v)
    None => "none"
  }
  assert_eq(data_layer_bytes, "pure-data")
  let data_layer_result = match
    std_layer_for_path("/tmp/repo/vibe/std/result.vibe") {
    Some(v) => std_layer_name(v)
    None => "none"
  }
  assert_eq(data_layer_result, "pure-data")

  let ref_layer = match std_layer_for_path("/tmp/repo/vibe/std/path/ref.vibe") {
    Some(v) => std_layer_name(v)
    None => "none"
  }
  assert_eq(ref_layer, "ref-model")

  let effect_layer = match
    std_layer_for_path("/tmp/repo/vibe/std/threads/runtime.vibe") {
    Some(v) => std_layer_name(v)
    None => "none"
  }
  assert_eq(effect_layer, "effect-boundary")

  let backend_layer = match
    std_layer_for_path("/tmp/repo/vibe/std/wasm/types.vibe") {
    Some(v) => std_layer_name(v)
    None => "none"
  }
  assert_eq(backend_layer, "backend-specific")
}

///|
test "std layering rejects effect to backend import" {
  let source =
    #|use ./wasm/types.vibe { i32 }
  let violations = std_layering_violations_for_source(
    "/tmp/repo/vibe/std/io.vibe", source,
  )
  assert_eq(violations.length(), 1)
  assert_true(violations[0].contains("effect-boundary"))
  assert_true(violations[0].contains("backend-specific"))
}

///|
test "std layering allows effect to primitive import and ignores std tests" {
  let allowed_source =
    #|use ./string.vibe { String }
  let allowed = std_layering_violations_for_source(
    "/tmp/repo/vibe/std/io.vibe", allowed_source,
  )
  assert_eq(allowed.length(), 0)

  let test_source =
    #|use ./wasm/types.vibe { i32 }
  let test_file = std_layering_violations_for_source(
    "/tmp/repo/vibe/std/io_test.vibe", test_source,
  )
  assert_eq(test_file.length(), 0)
}

///|
test "normalize source succeeds for vibe std files" {
  let files = wbtest_collect_vibe_files_recursive("vibe/std")
  if files.length() == 0 {
    fail("[vibe/std] no .vibe files found")
  }
  for path in files {
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
  assert_true(output.contains("declare export let run: () -> Int"))
  assert_true(output.contains("run = () -> Int {"))
  assert_false(output.contains("export let run ="))
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
