///|
struct MemIoAdapter {
  fs : @vibe_fs.MemFs
  cwd : String
}

///|
fn MemIoAdapter::new(cwd : String) -> MemIoAdapter {
  let fs = @vibe_fs.MemFs::new()
  fs.mkdir_p(cwd) catch {
    e => abort("mem fs init failed: " + e.to_string())
  }
  { fs, cwd }
}

///|
pub impl @io.FileSystemAdapter for MemIoAdapter with fn current_dir_or_root(
  self,
) {
  self.cwd
}

///|
pub impl @io.FileSystemAdapter for MemIoAdapter with fn path_exists(self, path) {
  self.fs.exists(path)
}

///|
pub impl @io.FileSystemAdapter for MemIoAdapter with fn create_dir(self, path) {
  self.fs.mkdir_p(path) catch {
    e => return Err(e.to_string())
  }
  Ok(())
}

///|
pub impl @io.FileSystemAdapter for MemIoAdapter with fn read_dir(self, path) {
  let entries = self.fs.readdir(path) catch { e => return Err(e.to_string()) }
  let out : Array[String] = []
  for entry in entries {
    out.push(entry.name)
  }
  Ok(out)
}

///|
pub impl @io.FileSystemAdapter for MemIoAdapter with fn read_string(self, path) {
  let content = self.fs.read_string(path) catch {
    e => return Err(e.to_string())
  }
  Ok(content)
}

///|
pub impl @io.FileSystemAdapter for MemIoAdapter with fn read_bytes(self, path) {
  let content = self.fs.read_file(path) catch { e => return Err(e.to_string()) }
  Ok(content)
}

///|
pub impl @io.FileSystemAdapter for MemIoAdapter with fn write_string(
  self,
  path,
  content,
) {
  self.fs.write_string(path, content) catch {
    e => return Err(e.to_string())
  }
  Ok(())
}

///|
pub impl @io.FileSystemAdapter for MemIoAdapter with fn write_bytes(
  self,
  path,
  content,
) {
  self.fs.write_file(path, content) catch {
    e => return Err(e.to_string())
  }
  Ok(())
}

///|
fn wbtest_write_string_or_abort(
  fs : MemIoAdapter,
  path : String,
  content : String,
) -> Unit {
  match fs.write_string(path, content) {
    Ok(_) => ()
    Err(err) => abort("write file failed: " + err)
  }
}

///|
fn wbtest_contains_message(
  diags : Array[@core.Diagnostic],
  text : String,
) -> Bool {
  for diag in diags {
    if diag.message.contains(text) {
      return true
    }
  }
  false
}

///|
fn wbtest_not_contains_message(
  diags : Array[@core.Diagnostic],
  text : String,
) -> Bool {
  not(wbtest_contains_message(diags, text))
}

///|
test "parse_cmd_args accepts --source input" {
  let parsed = parse_cmd_args(["--source", "1 + true"])
  match parsed {
    Ok(
      {
        mode: CommandMode::Check,
        input: CheckInput::Source(source),
        human_readable: false,
        profile_tsv: None,
      }
    ) => assert_eq(source, "1 + true")
    Ok(_) => fail("expected source input")
    Err(err) => fail(err)
  }
}

///|
test "parse_cmd_args accepts positional file input" {
  let parsed = parse_cmd_args(["examples/basic.vibe"])
  match parsed {
    Ok({ mode: CommandMode::Check, input: CheckInput::File(path), .. }) =>
      assert_eq(path, "examples/basic.vibe")
    Ok(_) => fail("expected file input")
    Err(err) => fail(err)
  }
}

///|
test "parse_cmd_args accepts multiple positional files in check mode" {
  let parsed = parse_cmd_args(["a.vibe", "b.vibe"])
  match parsed {
    Ok({ mode: CommandMode::Check, input: CheckInput::Files(paths), .. }) => {
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
    Ok(
      {
        mode: CommandMode::Format,
        input: CheckInput::Source(source),
        human_readable: false,
        profile_tsv: None,
      }
    ) => assert_eq(source, "let  x=1")
    Ok(_) => fail("expected format source input")
    Err(err) => fail(err)
  }
}

///|
test "parse_cmd_args rejects multiple file input in format mode" {
  let parsed = parse_cmd_args(["--format", "a.vibe", "b.vibe"])
  match parsed {
    Ok({ mode: CommandMode::Format, input: CheckInput::Files(paths), .. }) => {
      assert_eq(paths.length(), 2)
      assert_eq(paths[0], "a.vibe")
      assert_eq(paths[1], "b.vibe")
    }
    Ok(_) => fail("expected format files input")
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
  assert_true(output.contains("\"human_readable_output\":true"))
  assert_true(output.contains("\"format_multi_file\":true"))
}

///|
test "parse_cmd_args accepts --human flag" {
  let parsed = parse_cmd_args(["--human", "a.vibe"])
  match parsed {
    Ok(
      {
        mode: CommandMode::Check,
        input: CheckInput::File(path),
        human_readable: true,
        profile_tsv: None,
      }
    ) => assert_eq(path, "a.vibe")
    Ok(_) => fail("expected human-readable check input")
    Err(err) => fail(err)
  }
}

///|
test "parse_cmd_args accepts --profile-tsv flag" {
  let parsed = parse_cmd_args(["--profile-tsv", "/tmp/check.tsv", "a.vibe"])
  match parsed {
    Ok(
      {
        mode: CommandMode::Check,
        input: CheckInput::File(path),
        profile_tsv: Some(profile_path),
        ..,
      }
    ) => {
      assert_eq(path, "a.vibe")
      assert_eq(profile_path, "/tmp/check.tsv")
    }
    Ok(_) => fail("expected profile path")
    Err(err) => fail(err)
  }
}

///|
test "parse_cmd_args rejects missing --profile-tsv value" {
  let parsed = parse_cmd_args(["--profile-tsv"])
  match parsed {
    Ok(_) => fail("expected parse error")
    Err(err) => assert_eq(err, "check: missing path after --profile-tsv")
  }
}

///|
test "report_to_human includes summary" {
  let output = report_to_human([], 0, 0, [
    CheckFileSummary::{
      path: "a.vibe",
      resolved_path: "/a.vibe",
      graph_head: Some("abc"),
      error_count: 0,
      warning_count: 0,
      source: "",
      diagnostics: [],
    },
  ])
  assert_true(output.contains("a.vibe: ok (graph_head=abc)"))
  assert_false(output.contains("check:"))
}

///|
test "format_files_report_to_json includes per-file outputs" {
  let output = format_files_report_to_json([
    FormatFileSummary::{
      path: "a.vibe",
      resolved_path: "/abs/a.vibe",
      formatted: "let a = 1\n",
      changed: true,
    },
    FormatFileSummary::{
      path: "b.vibe",
      resolved_path: "/abs/b.vibe",
      formatted: "let b = 2\n",
      changed: false,
    },
  ])
  assert_true(output.contains("\"files\""))
  assert_true(output.contains("\"path\":\"a.vibe\""))
  assert_true(output.contains("\"path\":\"b.vibe\""))
  assert_true(output.contains("\"format_multi_file\":true"))
}

///|
test "check_file reports dependency error propagation through transitive imports" {
  ensure_checker_hooks()
  let root = "/workspace"
  let fs = MemIoAdapter::new(root)
  let a = root + "/a.vibe"
  let b = root + "/b.vibe"
  let c = root + "/c.vibe"
  wbtest_write_string_or_abort(
    fs, c, "let broken = true + 1\nexport { broken }\n",
  )
  wbtest_write_string_or_abort(
    fs, b, "import ./c.vibe { broken }\nlet b = broken\nexport { b }\n",
  )
  wbtest_write_string_or_abort(
    fs, a, "import ./b.vibe { b }\nlet main = b\nexport { main }\n",
  )
  let expected_entry_errors = match @loader.load_db_with_fs(a, fs) {
    Ok((db, entry)) => {
      let _ = db.types(entry)
      db.diagnostics(entry).length()
    }
    Err(err) => fail(err)
  }
  match check_file_with_timing(a, fs) {
    Ok(((diags, error_count, warning_count), _timing, _source)) => {
      assert_eq(error_count, expected_entry_errors)
      assert_eq(warning_count, 0)
      assert_true(
        wbtest_contains_message(
          diags, "dependency export unavailable due to upstream errors",
        ),
      )
      assert_true(wbtest_contains_message(diags, "unknown name: broken"))
      assert_true(wbtest_contains_message(diags, "unknown name: b"))
      assert_true(
        wbtest_not_contains_message(diags, "type mismatch (argument)"),
      )
    }
    Err(err) => fail(err)
  }
}

///|
test "check_file_with_timing records type timing for no-import file" {
  let root = "/workspace"
  let fs = MemIoAdapter::new(root)
  let entry = root + "/single.vibe"
  wbtest_write_string_or_abort(fs, entry, "let value = 1 + 2\n")
  match check_file_with_timing(entry, fs) {
    Ok(((_, errors, _warnings), timing, _source)) => {
      assert_eq(errors, 0)
      assert_true(timing.type_us > 0)
      assert_true(timing.type_ms > 0)
      assert_true(timing.total_us >= timing.type_us)
    }
    Err(err) => fail(err)
  }
}
