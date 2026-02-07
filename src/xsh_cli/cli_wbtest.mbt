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
