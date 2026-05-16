///|
fn make_temp_dir(prefix : String) -> String {
  let base = "/tmp/vibe_io_test_" + prefix
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
fn remove_if_exists(path : String) -> Unit {
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
      remove_if_exists(path + "/" + name)
    }
    ignore(@os_fs.remove_dir(path) catch { _ => () })
  }
}

///|
fn contains_entry(entries : Array[String], target : String) -> Bool {
  for entry in entries {
    if entry == target {
      return true
    }
  }
  false
}

///|
test "io current_dir_or_root returns non-empty path" {
  let cwd = current_dir_or_root()
  assert_true(cwd.length() > 0)
}

///|
test "io fs wrappers roundtrip text and bytes" {
  let root = make_temp_dir("roundtrip")
  let nested = root + "/nested"
  match create_dir(nested) {
    Ok(_) => ()
    Err(err) => fail(err)
  }
  let path = nested + "/sample.txt"
  match write_string(path, "hello\n") {
    Ok(_) => ()
    Err(err) => fail(err)
  }
  assert_true(path_exists(path))
  let text = match read_string(path) {
    Ok(v) => v
    Err(err) => fail(err)
  }
  assert_eq(text, "hello\n")
  let bytes = match read_bytes(path) {
    Ok(v) => v
    Err(err) => fail(err)
  }
  assert_eq(bytes.length(), 6)
  remove_if_exists(root)
}

///|
test "io shell wrappers provide ls and cat behavior" {
  let root = make_temp_dir("shell")
  let path = root + "/sample.txt"
  match write_string(path, "a\nb\n") {
    Ok(_) => ()
    Err(err) => fail(err)
  }
  let entries = match shell_ls_lines(root) {
    Ok(v) => v
    Err(err) => fail(err)
  }
  assert_true(contains_entry(entries, "sample.txt"))
  let lines = match shell_cat_lines(path) {
    Ok(v) => v
    Err(err) => fail(err)
  }
  @debug.assert_eq(lines, ["a", "b"])
  remove_if_exists(root)
}

///|
test "io sleep facade accepts milliseconds" {
  sleep_ms(0L)
}
