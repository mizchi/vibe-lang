///|
test "parse_cmd_args accepts --source input" {
  let parsed = parse_cmd_args(["--source", "1 + true"])
  match parsed {
    Ok({ mode: CommandMode::Check, input: CheckInput::Source(source) }) =>
      assert_eq(source, "1 + true")
    Ok(_) => fail("expected source input")
    Err(err) => fail(err)
  }
}

///|
test "parse_cmd_args accepts positional file input" {
  let parsed = parse_cmd_args(["examples/basic.vibe"])
  match parsed {
    Ok({ mode: CommandMode::Check, input: CheckInput::File(path) }) =>
      assert_eq(path, "examples/basic.vibe")
    Ok(_) => fail("expected file input")
    Err(err) => fail(err)
  }
}

///|
test "parse_cmd_args parses --format mode" {
  let parsed = parse_cmd_args(["--format", "--source", "let  x=1"])
  match parsed {
    Ok({ mode: CommandMode::Format, input: CheckInput::Source(source) }) =>
      assert_eq(source, "let  x=1")
    Ok(_) => fail("expected format source input")
    Err(err) => fail(err)
  }
}

///|
test "parse_cmd_args rejects source and file mixed input" {
  let parsed = parse_cmd_args(["--source", "1", "examples/basic.vibe"])
  match parsed {
    Ok(_) => fail("expected parse error")
    Err(err) => assert_eq(err, "check: --source and file input are exclusive")
  }
}

///|
test "parse_cmd_args rejects check and format mixed input" {
  let parsed = parse_cmd_args(["--check", "--format", "--source", "1 + 2"])
  match parsed {
    Ok(_) => fail("expected parse error")
    Err(err) => assert_eq(err, "check: choose either --check or --format")
  }
}

///|
test "check_source supports method-call desugaring without imports" {
  let source =
    #|let n = 1
    #|let s = n.to_string()
    #|s
  let (_diags, errors, _warnings) = check_source(source)
  assert_eq(errors, 0)
}
