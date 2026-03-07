///|
fn wbtest_make_temp_dir(prefix : String) -> String {
  let tmp_root = @vibe_fs.normalize_path(@io.current_dir_or_root() + "/.tmp")
  if not(@os_fs.path_exists(tmp_root)) {
    @os_fs.create_dir(tmp_root) catch {
      e => fail("create temp root failed: " + e.to_string())
    }
  }
  let base = tmp_root + "/vibe_check_wasi_test_" + prefix
  for i in 0..<1000 {
    let path = if i == 0 { base } else { base + "_" + i.to_string() }
    if not(@os_fs.path_exists(path)) {
      @os_fs.create_dir(path) catch {
        e => fail("create temp dir failed: " + e.to_string())
      }
      return path
    }
  }
  fail("failed to allocate temp dir")
  base
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
fn wbtest_write_file(path : String, content : String) -> Unit {
  @os_fs.write_string_to_file(path, content) catch {
    e => fail("write file failed: " + e.to_string())
  }
}

///|
fn wbtest_contains_message(diags : Array[@core.Diagnostic], text : String) -> Bool {
  for diag in diags {
    if diag.message.contains(text) {
      return true
    }
  }
  false
}

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
test "parse_cmd_args accepts multiple positional files in check mode" {
  let parsed = parse_cmd_args(["a.vibe", "b.vibe"])
  match parsed {
    Ok({ mode: CommandMode::Check, input: CheckInput::Files(paths) }) => {
      assert_eq(paths.length(), 2)
      assert_eq(paths[0], "a.vibe")
      assert_eq(paths[1], "b.vibe")
    }
    Ok(_) => fail("expected files input")
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
test "parse_cmd_args rejects multiple file input in format mode" {
  let parsed = parse_cmd_args(["--format", "a.vibe", "b.vibe"])
  match parsed {
    Ok(_) => fail("expected parse error")
    Err(err) => assert_eq(err, "check: --format expects exactly one file input")
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
test "check_source supports pipe call without imports" {
  let source =
    #|let n = 1
    #|let s = n |> to_string
    #|s
  let (_diags, errors, _warnings) = check_source(source)
  assert_eq(errors, 0)
}

///|
test "std_layering_violations_for_source detects pure-data to effect import" {
  let path = "/tmp/vibe/prelude/array.vibe"
  let source =
    #|import ./io.vibe { println }
    #|let x = 1
  let violations = std_layering_violations_for_source(path, source)
  assert_eq(violations.length(), 1)
  assert_true(violations[0].contains("std layering violation"))
}

///|
test "report_to_json includes parity capability flags" {
  let output = report_to_json([], 0, 0, [])
  assert_true(output.contains("\"parity\""))
  assert_true(output.contains("\"graph_head_available\":true"))
  assert_true(output.contains("\"human_readable_output\":false"))
  assert_true(output.contains("\"format_multi_file\":false"))
}

///|
test "check_file reports dependency error propagation through transitive imports" {
  let root = wbtest_make_temp_dir("dep_scope")
  defer wbtest_remove_if_exists(root)
  let a = root + "/a.vibe"
  let b = root + "/b.vibe"
  let c = root + "/c.vibe"
  wbtest_write_file(c, "let broken = true + 1\nexport { broken }\n")
  wbtest_write_file(
    b, "import ./c.vibe { broken }\nlet b = broken\nexport { b }\n",
  )
  wbtest_write_file(a, "import ./b.vibe { b }\nlet main = b\nexport { main }\n")
  let fs = @io.default_fs_adapter()
  match check_file(a, fs) {
    Ok((diags, error_count, warning_count)) => {
      assert_eq(error_count, 4)
      assert_eq(warning_count, 0)
      assert_true(
        wbtest_contains_message(
          diags, "dependency export unavailable due to upstream errors",
        ),
      )
      assert_true(wbtest_contains_message(diags, "unknown name: b"))
    }
    Err(err) => fail(err)
  }
}
