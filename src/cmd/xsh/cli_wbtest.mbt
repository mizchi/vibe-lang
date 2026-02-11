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
  let parsed = parse_line_repl_options([], "repl-stdin", "xsh> ")
  match parsed {
    Ok(opts) => {
      assert_eq(opts.prompt, "xsh> ")
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
    "xsh> ",
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
  let parsed = parse_line_repl_options(["--wat"], "repl-stdin", "xsh> ")
  match parsed {
    Ok(_) => fail("expected error")
    Err(msg) => assert_eq(msg, "repl-stdin: unknown arg --wat")
  }
}

///|
test "eval cmd options parse db and expression" {
  let parsed = parse_eval_cmd_options(
    ["--db=tmp1.db", "--include=index.xdb", "let", "value", "=", "1"],
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
      assert_eq(opts.include_paths, ["index.xdb"])
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
    ["--db", "tmp1.db", "--include", "index.xdb", "--export", "out.xsh"],
    "eval",
  )
  match parsed {
    Ok(opts) => {
      match opts.db_path {
        Some(path) => assert_eq(path, "tmp1.db")
        None => fail("expected db path")
      }
      match opts.export_path {
        Some(path) => assert_eq(path, "out.xsh")
        None => fail("expected export path")
      }
      assert_eq(opts.include_paths, ["index.xdb"])
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
  let parsed = parse_eval_cmd_options(["--export", "out.xsh"], "eval")
  match parsed {
    Ok(opts) => {
      match opts.db_path {
        Some(_) => fail("unexpected db path")
        None => ()
      }
      match opts.export_path {
        Some(path) => assert_eq(path, "out.xsh")
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
      "--db", "tmp1.db", "--include", "index.xdb", "--include=bit:/tmp/std.xdb",
      "let", "x", "=", "1",
    ],
    "eval",
  )
  match parsed {
    Ok(opts) => {
      assert_eq(opts.include_paths, ["index.xdb", "bit:/tmp/std.xdb"])
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
test "eval include path resolves named xdb alias from lib dir" {
  let resolved = resolve_eval_include_path(
    "/work/project", "xsh/std@0.1.0.xdb", "/home/test/.xsh/lib",
  )
  assert_eq(resolved, "/home/test/.xsh/lib/xsh/std@0.1.0.xdb")
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
    "--db=tmp1.db", "--export", "dist/out.xsh", "--library", "--print", "--dry-run",
  ])
  match parsed {
    Ok(opts) => {
      match opts.db_path {
        Some(path) => assert_eq(path, "tmp1.db")
        None => fail("expected db path")
      }
      match opts.export_path {
        Some(path) => assert_eq(path, "dist/out.xsh")
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
test "cli syntax mode parse default" {
  let parsed = parse_cli_syntax_args(["main.xsh"], "run")
  match parsed {
    Ok((mode, rest)) => {
      assert_eq(mode, @xsh_lib.ParserMode::XshMode)
      assert_eq(rest, ["main.xsh"])
    }
    Err(msg) => fail("unexpected err: " + msg)
  }
}

///|
test "cli syntax mode parse explicit posix" {
  let parsed = parse_cli_syntax_args(["--syntax", "posix", "main.xsh"], "run")
  match parsed {
    Ok((mode, rest)) => {
      assert_eq(mode, @xsh_lib.ParserMode::PosixMode)
      assert_eq(rest, ["main.xsh"])
    }
    Err(msg) => fail("unexpected err: " + msg)
  }
}

///|
test "cli runtime flags parse default" {
  let parsed = parse_cli_runtime_args(["main.xsh"], "run")
  match parsed {
    Ok(opts) => {
      assert_eq(opts.syntax_mode, @xsh_lib.ParserMode::XshMode)
      assert_eq(opts.cmd_args, ["main.xsh"])
      assert_false(opts.unstable_async)
      assert_false(opts.unstable_threads)
    }
    Err(msg) => fail("unexpected err: " + msg)
  }
}

///|
test "cli runtime flags parse with unstable flags" {
  let parsed = parse_cli_runtime_args(
    ["--unstable-async", "--syntax", "posix", "--unstable-threads", "main.xsh"],
    "run",
  )
  match parsed {
    Ok(opts) => {
      assert_eq(opts.syntax_mode, @xsh_lib.ParserMode::PosixMode)
      assert_eq(opts.cmd_args, ["main.xsh"])
      assert_true(opts.unstable_async)
      assert_true(opts.unstable_threads)
    }
    Err(msg) => fail("unexpected err: " + msg)
  }
}

///|
test "cli dispatch args parse leading unstable flags" {
  let parsed = parse_cli_dispatch_args([
    "xsh", "--unstable-async", "--unstable-threads", "run", "main.xsh",
  ])
  match parsed {
    Ok(v) => {
      assert_eq(v.cmd, "run")
      assert_eq(v.syntax_mode, @xsh_lib.ParserMode::XshMode)
      assert_eq(v.cmd_args, ["main.xsh"])
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
    "main.xsh",
  ])
  match parsed {
    Ok(v) => {
      assert_eq(v.cmd, "run")
      assert_eq(v.syntax_mode, @xsh_lib.ParserMode::PosixMode)
      assert_eq(v.cmd_args, ["main.xsh"])
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
    ensure_cli_parser_mode_supported(@xsh_lib.ParserMode::PosixMode, "run") {
    Ok(_) => ()
    Err(msg) => fail("unexpected run error: " + msg)
  }
  match
    ensure_cli_parser_mode_supported(@xsh_lib.ParserMode::PosixMode, "eval") {
    Ok(_) => ()
    Err(msg) => fail("unexpected eval error: " + msg)
  }
  match
    ensure_cli_parser_mode_supported(@xsh_lib.ParserMode::PosixMode, "repl") {
    Ok(_) => ()
    Err(msg) => fail("unexpected repl error: " + msg)
  }
  match
    ensure_cli_parser_mode_supported(@xsh_lib.ParserMode::PosixMode, "compile") {
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
    "--wasm", "--wite", "-o", "/tmp/out.wasm", "main.xsh",
  ])
  match parsed {
    Ok(opts) => {
      assert_eq(opts.mode, CompileMode::Wasm)
      assert_false(opts.no_dce)
      assert_eq(opts.entry_path, "main.xsh")
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
  let parsed = parse_compile_cmd_args(["--component", "-O3", "main.xsh"])
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
test "compile args parse coverage for wasm" {
  let parsed = parse_compile_cmd_args([
    "--wasm", "--coverage", "-o", "/tmp/out.wasm", "main.xsh",
  ])
  match parsed {
    Ok(opts) => {
      assert_eq(opts.mode, CompileMode::Wasm)
      assert_true(opts.coverage)
      assert_false(opts.coverage_run_tests)
      assert_eq(opts.entry_path, "main.xsh")
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
    "--wasm", "--coverage", "--coverage-run-tests", "main.xsh",
  ])
  match parsed {
    Ok(opts) => {
      assert_eq(opts.mode, CompileMode::Wasm)
      assert_true(opts.coverage)
      assert_true(opts.coverage_run_tests)
      assert_eq(opts.entry_path, "main.xsh")
    }
    Err(msg) => fail("unexpected err: " + msg)
  }
}

///|
test "compile args reject coverage run tests without coverage" {
  let parsed = parse_compile_cmd_args([
    "--wasm", "--coverage-run-tests", "main.xsh",
  ])
  match parsed {
    Ok(_) => fail("expected error")
    Err(msg) =>
      assert_eq(msg, "compile: --coverage-run-tests requires --coverage")
  }
}

///|
test "compile args reject coverage on non-wasm mode" {
  let parsed = parse_compile_cmd_args(["--wit", "--coverage", "main.xsh"])
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
  let parsed = parse_compile_cmd_args(["--wit", "--no-dce", "main.xsh"])
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
  let parsed = parse_compile_cmd_args(["--wit", "-Oz", "main.xsh"])
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
test "resolve test entry paths includes top-level xsh files" {
  let root = wbtest_make_temp_dir("resolve_tests")
  let sub = root + "/sub"
  let deep = sub + "/deep"
  @os_fs.create_dir(sub) catch {
    e => fail("create sub dir failed: " + e.to_string())
  }
  @os_fs.create_dir(deep) catch {
    e => fail("create deep dir failed: " + e.to_string())
  }
  let top = root + "/top.xsh"
  let nested = sub + "/nested.xsh"
  let deep_nested = deep + "/deep_nested.xsh"
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
test "resolve bench entry paths includes top-level _bench.xsh files" {
  let root = wbtest_make_temp_dir("resolve_bench")
  let sub = root + "/sub"
  @os_fs.create_dir(sub) catch {
    e => fail("create sub dir failed: " + e.to_string())
  }
  let top = root + "/top_bench.xsh"
  let top_non_bench = root + "/top.xsh"
  let nested = sub + "/nested_bench.xsh"
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
    #|use ./dep.xsh { dep }
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
  let idx_use = wbtest_substring_index(normalized, "use ./dep.xsh {")
  let idx_trait = wbtest_substring_index(normalized, "trait Eq")
  let idx_pure_fn = wbtest_substring_index(normalized, "let helper =")
  let idx_effect_fn = wbtest_substring_index(
    normalized, "export let run_io = () -> Int with {",
  )
  assert_true(idx_use >= 0)
  assert_true(idx_trait >= 0)
  assert_true(idx_pure_fn >= 0)
  assert_true(idx_effect_fn >= 0)
  assert_true(idx_use < idx_trait)
  assert_true(idx_trait < idx_pure_fn)
  assert_true(idx_pure_fn < idx_effect_fn)
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
  let idx_helper = wbtest_substring_index(normalized, "let helper =")
  let idx_run = wbtest_substring_index(normalized, "export let run =")
  let idx_run_io = wbtest_substring_index(
    normalized, "export let run_io = () -> Int with {",
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
  let idx_a = wbtest_substring_index(normalized, "export let a =")
  let idx_b = wbtest_substring_index(normalized, "export let b =")
  let idx_z = wbtest_substring_index(normalized, "export let z =")
  let idx_io_a = wbtest_substring_index(
    normalized, "export let io_a = () -> Int with {",
  )
  let idx_io_b = wbtest_substring_index(
    normalized, "export let io_b = () -> Int with {",
  )
  let idx_io_z = wbtest_substring_index(
    normalized, "export let io_z = () -> Int with {",
  )
  assert_true(idx_a >= 0)
  assert_true(idx_b >= 0)
  assert_true(idx_z >= 0)
  assert_true(idx_io_a >= 0)
  assert_true(idx_io_b >= 0)
  assert_true(idx_io_z >= 0)
  assert_true(idx_a < idx_b)
  assert_true(idx_b < idx_z)
  assert_true(idx_io_a < idx_io_b)
  assert_true(idx_io_b < idx_io_z)
  assert_true(idx_z < idx_io_a)
}

///|
fn wbtest_make_temp_dir(prefix : String) -> String {
  let base = "/tmp/cmd_xsh_wbtest_" + prefix + "_" + @env.now().to_string()
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
