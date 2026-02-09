///|
fn make_temp_dir(prefix : String) -> String {
  let base = "/tmp/xsh_loader_test_" + prefix
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
fn remove_if_exists(path : String) -> Unit {
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
      remove_if_exists(path + "/" + name)
    }
    ignore(@os_fs.remove_dir(path) catch { _ => () })
  }
}

///|
fn write_file(path : String, content : String) -> Unit {
  @os_fs.write_string_to_file(path, content) catch {
    e => abort("write file failed: " + e.to_string())
  }
}

///|
fn contains_path(paths : Array[String], target : String) -> Bool {
  for path in paths {
    if path == target {
      return true
    }
  }
  false
}

///|
test "loader load_db_with_paths loads transitive modules" {
  let root = make_temp_dir("transitive")
  let entry = root + "/main.xsh"
  let lib = root + "/lib.xsh"
  let entry_source = "import { libv } from \"./lib.xsh\"\nlet main = libv\nexport { main }\n"
  let lib_source = "let libv = 1\nexport { libv }\n"
  write_file(entry, entry_source)
  write_file(lib, lib_source)
  let loaded = match load_db_with_paths(entry) {
    Ok(v) => v
    Err(err) => fail(err)
  }
  let (db, resolved, paths) = loaded
  let entry_norm = @xsh_fs.normalize_path(entry)
  let lib_norm = @xsh_fs.normalize_path(lib)
  assert_eq(resolved, entry_norm)
  assert_true(contains_path(paths, entry_norm))
  assert_true(contains_path(paths, lib_norm))
  match db.get_source(entry_norm) {
    Some(source) => assert_eq(source, entry_source)
    None => fail("expected entry source")
  }
  match db.get_source(lib_norm) {
    Some(source) => assert_eq(source, lib_source)
    None => fail("expected imported source")
  }
  remove_if_exists(root)
}

///|
test "loader load_db_with_paths reports import cycle" {
  let root = make_temp_dir("cycle")
  let a_path = root + "/a.xsh"
  let b_path = root + "/b.xsh"
  write_file(a_path, "import { b } from \"./b.xsh\"\nlet a = b\nexport { a }\n")
  write_file(b_path, "import { a } from \"./a.xsh\"\nlet b = a\nexport { b }\n")
  match load_db_with_paths(a_path) {
    Ok(_) => fail("expected import cycle error")
    Err(err) => assert_true(err.contains("import cycle detected"))
  }
  remove_if_exists(root)
}
