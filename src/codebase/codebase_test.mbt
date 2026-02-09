///|
fn make_temp_dir(prefix : String) -> String {
  let base = "/tmp/xsh_codebase_test_" + prefix
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
fn mapping_hash(mappings : Array[@core.PathMapping], path : String) -> String? {
  for mapping in mappings {
    if mapping.path == path {
      return Some(mapping.hash)
    }
  }
  None
}

///|
test "codebase writes and reads object blobs" {
  let root = make_temp_dir("object")
  let cb = Codebase::new(root)
  let hash = "abcdef0123456789abcdef0123456789abcdef01"
  let first = "{\"x\":1}"
  let second = "{\"x\":2}"
  let _ = cb.write_object(hash, first) catch { e => fail(e.to_string()) }
  assert_true(@os_fs.path_exists(cb.object_path(hash)))
  match cb.read_object(hash) {
    Some(content) => assert_eq(content, first)
    None => fail("expected object content")
  }
  // Content-addressed write is immutable once present.
  let _ = cb.write_object(hash, second) catch { e => fail(e.to_string()) }
  match cb.read_object(hash) {
    Some(content) => assert_eq(content, first)
    None => fail("expected object content")
  }
  remove_if_exists(root)
}

///|
test "codebase upserts path mappings" {
  let root = make_temp_dir("paths")
  let cb = Codebase::new(root)
  let _ = cb.upsert_path_mapping("main.xsh", "aaaaaaaa") catch {
    e => fail(e.to_string())
  }
  let _ = cb.upsert_path_mapping("lib/util.xsh", "bbbbbbbb") catch {
    e => fail(e.to_string())
  }
  let _ = cb.upsert_path_mapping("main.xsh", "cccccccc") catch {
    e => fail(e.to_string())
  }
  let mappings = cb.load_path_mappings()
  assert_eq(mappings.length(), 2)
  match mapping_hash(mappings, "main.xsh") {
    Some(hash) => assert_eq(hash, "cccccccc")
    None => fail("expected main.xsh mapping")
  }
  match cb.resolve_path_mapping("util.xsh") {
    Some(hash) => assert_eq(hash, "bbbbbbbb")
    None => fail("expected suffix path resolution")
  }
  remove_if_exists(root)
}

///|
test "codebase update_lock_path_refs gathers transitive local imports" {
  let root = make_temp_dir("collect_refs")
  let nested = root + "/nested"
  @os_fs.create_dir(nested) catch {
    e => fail(e.to_string())
  }
  let main_path = root + "/main.xsh"
  let lib_path = root + "/lib.xsh"
  let util_path = nested + "/util.xsh"
  let main_source = "import { libv } from \"./lib.xsh\"\nlet main = libv\nexport { main }\n"
  let lib_source = "import { utilv } from \"./nested/util.xsh\"\nlet libv = utilv\nexport { libv }\n"
  let util_source = "let utilv = 1\nexport { utilv }\n"
  write_file(main_path, main_source)
  write_file(lib_path, lib_source)
  write_file(util_path, util_source)
  let refs = match update_lock_path_refs(main_path) {
    Ok(v) => v
    Err(err) => fail(err)
  }
  assert_eq(refs.path_refs.length(), 3)
  let main_norm = @xsh_fs.normalize_path(main_path)
  let lib_norm = @xsh_fs.normalize_path(lib_path)
  let util_norm = @xsh_fs.normalize_path(util_path)
  match refs.path_refs.get(main_norm) {
    Some(hash) => assert_eq(hash, @core.git_blob_hash_string(main_source))
    None => fail("expected main source hash")
  }
  match refs.path_refs.get(lib_norm) {
    Some(hash) => assert_eq(hash, @core.git_blob_hash_string(lib_source))
    None => fail("expected lib source hash")
  }
  match refs.path_refs.get(util_norm) {
    Some(hash) => assert_eq(hash, @core.git_blob_hash_string(util_source))
    None => fail("expected util source hash")
  }
  remove_if_exists(root)
}

///|
test "codebase update_lock_path_refs merges path refs and keeps non-path refs" {
  let root = make_temp_dir("update_lock")
  let entry = root + "/main.xsh"
  let lib = root + "/lib.xsh"
  let old = root + "/old.xsh"
  write_file(
    entry, "import { libv } from \"./lib.xsh\"\nlet main = libv\nexport { main }\n",
  )
  write_file(lib, "let libv = 1\nexport { libv }\n")
  let lock_path = lock_file_path(entry)
  let lock_json = "{\"path\":{\"./old.xsh\":\"1111\"},\"version\":{\"main\":\"2222\"},\"symbol\":{\"std/io\":\"3333\"}}"
  write_file(lock_path, lock_json)
  let updated = match update_lock_path_refs(entry) {
    Ok(v) => v
    Err(err) => fail(err)
  }
  let entry_norm = @xsh_fs.normalize_path(entry)
  let lib_norm = @xsh_fs.normalize_path(lib)
  let old_norm = @xsh_fs.normalize_path(old)
  assert_true(updated.path_refs.contains(entry_norm))
  assert_true(updated.path_refs.contains(lib_norm))
  match updated.path_refs.get(old_norm) {
    Some(hash) => assert_eq(hash, "1111")
    None => fail("expected existing path ref to remain")
  }
  match updated.version_refs.get("main") {
    Some(hash) => assert_eq(hash, "2222")
    None => fail("expected version ref")
  }
  match updated.symbol_refs.get("std/io") {
    Some(hash) => assert_eq(hash, "3333")
    None => fail("expected symbol ref")
  }
  let loaded = match load_lock_data(lock_path) {
    Ok(v) => v
    Err(err) => fail(err)
  }
  assert_eq(loaded, updated)
  remove_if_exists(root)
}

///|
test "codebase update_lock_path_refs reports collect_path_refs errors" {
  let root = make_temp_dir("update_lock_cycle")
  let a_path = root + "/a.xsh"
  let b_path = root + "/b.xsh"
  write_file(a_path, "import { b } from \"./b.xsh\"\nlet a = b\nexport { a }\n")
  write_file(b_path, "import { a } from \"./a.xsh\"\nlet b = a\nexport { b }\n")
  match update_lock_path_refs(a_path) {
    Ok(_) => fail("expected update_lock_path_refs to fail")
    Err(err) => assert_true(err.contains("import cycle detected"))
  }
  remove_if_exists(root)
}

///|
test "codebase lock roundtrip keeps refs and normalizes path keys" {
  let root = make_temp_dir("lock")
  let entry = root + "/main.xsh"
  let lock_path = lock_file_path(entry)
  let lib_path = @xsh_fs.normalize_path(root + "/lib.xsh")
  let path_refs : Map[String, String] = {}
  path_refs[lib_path] = "aaaaaaaa"
  let version_refs : Map[String, String] = {}
  version_refs["main"] = "bbbbbbbb"
  let symbol_refs : Map[String, String] = {}
  symbol_refs["std/math"] = "cccccccc"
  let lock = LockData::new(path_refs, version_refs, symbol_refs)
  match write_lock_data(lock_path, lock) {
    Ok(_) => ()
    Err(err) => fail(err)
  }
  let content = @os_fs.read_file_to_string(lock_path) catch {
    e => fail(e.to_string())
  }
  assert_true(content.contains("\"./lib.xsh\""))
  let loaded = match load_lock_data(lock_path) {
    Ok(v) => v
    Err(err) => fail(err)
  }
  match loaded.path_refs.get(lib_path) {
    Some(hash) => assert_eq(hash, "aaaaaaaa")
    None => fail("expected path ref")
  }
  match loaded.version_refs.get("main") {
    Some(hash) => assert_eq(hash, "bbbbbbbb")
    None => fail("expected version ref")
  }
  match loaded.symbol_refs.get("std/math") {
    Some(hash) => assert_eq(hash, "cccccccc")
    None => fail("expected symbol ref")
  }
  remove_if_exists(root)
}

///|
test "codebase lock parser accepts #hash form" {
  let root = make_temp_dir("lock_hash")
  let lock_path = root + "/xsh.lock"
  let _ = @os_fs.write_string_to_file(
    lock_path, "{\"path\":{},\"version\":{\"main\":\"#abcd\"},\"symbol\":{}}",
  )
  let loaded = match load_lock_data(lock_path) {
    Ok(v) => v
    Err(err) => fail(err)
  }
  match loaded.version_refs.get("main") {
    Some(hash) => assert_eq(hash, "abcd")
    None => fail("expected version ref")
  }
  remove_if_exists(root)
}
