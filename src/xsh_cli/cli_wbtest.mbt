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
fn wbtest_make_temp_dir(prefix : String) -> String {
  let base = "/tmp/xsh_cli_wbtest_" + prefix + "_" + @env.now().to_string()
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
    ignore(@os_fs.remove_dir(path) catch { _ => () })
  }
}
