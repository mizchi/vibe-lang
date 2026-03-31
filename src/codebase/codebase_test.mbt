///|
fn test_repo_root() -> String {
  let cwd = match @env.current_dir() {
    Some(path) => path
    None => "/tmp"
  }
  let git_ref_path = cwd + "/.git"
  let git_ref_is_file = @os_fs.is_file(git_ref_path) catch { _ => false }
  if !git_ref_is_file {
    return cwd
  }
  let git_ref = @os_fs.read_file_to_string(git_ref_path) catch {
    _ => return cwd
  }
  let prefix = "gitdir: "
  if !git_ref.has_prefix(prefix) {
    return cwd
  }
  let gitdir = git_ref[prefix.length():].trim().to_string()
  let parts = gitdir.split("/.git/").map(StringView::to_string).collect()
  if parts.length() == 0 || parts[0].length() == 0 {
    return cwd
  }
  parts[0]
}

///|
fn make_temp_dir(prefix : String) -> String {
  let tmp_root = test_repo_root() + "/_build/vibe_codebase_test"
  if not(@os_fs.path_exists(tmp_root)) {
    @os_fs.create_dir(tmp_root) catch {
      e => abort("create temp root failed: " + e.to_string())
    }
  }
  let base = tmp_root + "/vibe_codebase_test_" + prefix
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
  let _ = cb.upsert_path_mapping("main.vibe", "aaaaaaaa") catch {
    e => fail(e.to_string())
  }
  let _ = cb.upsert_path_mapping("lib/util.vibe", "bbbbbbbb") catch {
    e => fail(e.to_string())
  }
  let _ = cb.upsert_path_mapping("main.vibe", "cccccccc") catch {
    e => fail(e.to_string())
  }
  let mappings = cb.load_path_mappings()
  assert_eq(mappings.length(), 2)
  match mapping_hash(mappings, "main.vibe") {
    Some(hash) => assert_eq(hash, "cccccccc")
    None => fail("expected main.vibe mapping")
  }
  match cb.resolve_path_mapping("util.vibe") {
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
  let main_path = root + "/main.vibe"
  let lib_path = root + "/lib.vibe"
  let util_path = nested + "/util.vibe"
  let main_source = "import ./lib.vibe {  libv  }\nlet main = libv\nexport { main }\n"
  let lib_source = "import ./nested/util.vibe {  utilv  }\nlet libv = utilv\nexport { libv }\n"
  let util_source = "let utilv = 1\nexport { utilv }\n"
  write_file(main_path, main_source)
  write_file(lib_path, lib_source)
  write_file(util_path, util_source)
  let refs = match update_lock_path_refs(main_path) {
    Ok(v) => v
    Err(err) => fail(err)
  }
  assert_eq(refs.path_refs.length(), 3)
  let main_norm = @vibe_fs.normalize_path(main_path)
  let lib_norm = @vibe_fs.normalize_path(lib_path)
  let util_norm = @vibe_fs.normalize_path(util_path)
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
test "codebase update_lock_path_refs resolves directory index import without explicit /index.vibe" {
  let root = make_temp_dir("collect_refs_index_dir")
  let main_path = root + "/main.vibe"
  let lib_dir = root + "/lib"
  let lib_index = lib_dir + "/index.vibe"
  @os_fs.create_dir(lib_dir) catch {
    e => fail(e.to_string())
  }
  let main_source = "import ./lib {  libv  }\nlet main = libv\nexport { main }\n"
  let lib_source = "let libv = 1\nexport { libv }\n"
  write_file(main_path, main_source)
  write_file(lib_index, lib_source)
  let refs = match update_lock_path_refs(main_path) {
    Ok(v) => v
    Err(err) => fail(err)
  }
  assert_eq(refs.path_refs.length(), 2)
  let main_norm = @vibe_fs.normalize_path(main_path)
  let lib_norm = @vibe_fs.normalize_path(lib_index)
  assert_true(refs.path_refs.contains(main_norm))
  assert_true(refs.path_refs.contains(lib_norm))
  match refs.path_refs.get(lib_norm) {
    Some(hash) => assert_eq(hash, @core.git_blob_hash_string(lib_source))
    None => fail("expected lib index source hash")
  }
  remove_if_exists(root)
}

///|
test "codebase update_lock_path_refs prunes stale path/module refs and keeps non-path refs" {
  let root = make_temp_dir("update_lock")
  let entry = root + "/main.vibe"
  let lib = root + "/lib.vibe"
  let old = root + "/old.vibe"
  write_file(
    entry, "import ./lib.vibe {  libv  }\nlet main = libv\nexport { main }\n",
  )
  write_file(lib, "let libv = 1\nexport { libv }\n")
  let lock_path = lock_file_path(entry)
  let lock_json = "{\"path\":{\"./old.vibe\":\"1111\"},\"version\":{\"main\":\"2222\"},\"symbol\":{\"std/io\":\"3333\"},\"module\":{\"legacy#x\":\"4444\"},\"annotation\":{\"legacy#x\":\"note\"}}"
  write_file(lock_path, lock_json)
  let updated = match update_lock_path_refs(entry) {
    Ok(v) => v
    Err(err) => fail(err)
  }
  let entry_norm = @vibe_fs.normalize_path(entry)
  let lib_norm = @vibe_fs.normalize_path(lib)
  let old_norm = @vibe_fs.normalize_path(old)
  assert_true(updated.path_refs.contains(entry_norm))
  assert_true(updated.path_refs.contains(lib_norm))
  assert_false(updated.path_refs.contains(old_norm))
  match updated.version_refs.get("main") {
    Some(hash) => assert_eq(hash, "2222")
    None => fail("expected version ref")
  }
  match updated.symbol_refs.get("std/io") {
    Some(hash) => assert_eq(hash, "3333")
    None => fail("expected symbol ref")
  }
  assert_false(updated.module_refs.contains("legacy#x"))
  assert_false(updated.annotations.contains("legacy#x"))
  let root_norm = @vibe_fs.normalize_path(root)
  let registry_modules : Map[String, String] = {}
  let entry_symbol = lock_module_ref_canonical_symbol_with_context(
    entry_norm, "main", root_norm, registry_modules, "0.0.0",
  )
  let mut found_entry_ref = false
  for key, hash in updated.module_refs {
    if key.has_prefix(entry_symbol + "#") {
      assert_true(hash.length() > 0)
      found_entry_ref = true
    }
  }
  assert_true(found_entry_ref)
  let lib_symbol = lock_module_ref_canonical_symbol_with_context(
    lib_norm, "libv", root_norm, registry_modules, "0.0.0",
  )
  let mut found_lib_ref = false
  for key, hash in updated.module_refs {
    if key.has_prefix(lib_symbol + "#") {
      assert_true(hash.length() > 0)
      found_lib_ref = true
    }
  }
  assert_true(found_lib_ref)
  let loaded = match load_lock_data(lock_path) {
    Ok(v) => v
    Err(err) => fail(err)
  }
  assert_eq(loaded, updated)
  remove_if_exists(root)
}

///|
test "codebase lock module ref key uses canonical-symbol#hash format" {
  let path = "/tmp/proj/vibe/prelude/result/index.vibe"
  let canonical = lock_module_ref_canonical_symbol(path, "Result::and_then")
  assert_eq(canonical, "/tmp/proj/vibe/prelude/result/Result::and_then")
  let key = lock_module_ref_key(path, "Result::and_then", "abc123")
  assert_eq(key, canonical + "#abc123")
}

///|
test "codebase lock module ref canonical symbol with context uses local namespace" {
  let root = "/tmp/proj"
  let path = root + "/pkg/math.vibe"
  let modules : Map[String, String] = {}
  let canonical = lock_module_ref_canonical_symbol_with_context(
    path, "sum", root, modules, "0.1.0",
  )
  assert_eq(canonical, "/local@0.1.0/pkg/math/sum")
  let key = lock_module_ref_key_with_context(
    path, "sum", "abc123", root, modules, "0.1.0",
  )
  assert_eq(key, canonical + "#abc123")
}

///|
test "codebase lock module ref canonical symbol with context resolves namespace deterministically" {
  let root = "/tmp/proj"
  let path = root + "/vibe/prelude/result/index.vibe"
  let modules : Map[String, String] = {}
  modules["std"] = root + "/vibe/prelude"
  modules["prelude"] = root + "/vibe/prelude"
  let canonical = lock_module_ref_canonical_symbol_with_context(
    path, "Result::and_then", root, modules, "0.1.0",
  )
  assert_eq(canonical, "/std@0.1.0/result/Result::and_then")
}

///|
test "codebase update_lock_path_refs reports collect_path_refs errors" {
  let root = make_temp_dir("update_lock_cycle")
  let a_path = root + "/a.vibe"
  let b_path = root + "/b.vibe"
  write_file(a_path, "import ./b.vibe {  b  }\nlet a = b\nexport { a }\n")
  write_file(b_path, "import ./a.vibe {  a  }\nlet b = a\nexport { b }\n")
  match update_lock_path_refs(a_path) {
    Ok(_) => fail("expected update_lock_path_refs to fail")
    Err(err) => assert_true(err.contains("import cycle detected"))
  }
  remove_if_exists(root)
}

///|
test "codebase lock roundtrip keeps refs and normalizes path keys" {
  let root = make_temp_dir("lock")
  let entry = root + "/main.vibe"
  let lock_path = lock_file_path(entry)
  let lib_path = @vibe_fs.normalize_path(root + "/lib.vibe")
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
  assert_true(content.contains("\"./lib.vibe\""))
  assert_true(content.contains("\"module\""))
  assert_true(content.contains("\"annotation\""))
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
  let lock_path = root + "/index.lock"
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

///|
test "codebase lock_file_path uses index.lock filename" {
  let root = make_temp_dir("lock_file_name")
  let entry = root + "/main.vibe"
  assert_eq(lock_file_path(entry), root + "/index.lock")
  remove_if_exists(root)
}

///|
test "codebase lock_file_path prefers ancestor index.lock plus .vibe" {
  let root = make_temp_dir("lock_file_ancestor_lock_vibe")
  let project = root + "/project"
  let nested = project + "/nested"
  @os_fs.create_dir(project) catch {
    e => fail(e.to_string())
  }
  @os_fs.create_dir(nested) catch {
    e => fail(e.to_string())
  }
  @os_fs.create_dir(project + "/.vibe") catch {
    e => fail(e.to_string())
  }
  write_file(
    project + "/index.lock",
    "{\"path\":{},\"version\":{},\"symbol\":{}}",
  )
  let entry = nested + "/main.vibe"
  assert_eq(lock_file_path(entry), project + "/index.lock")
  assert_eq(vibe_dir_path(entry), project + "/.vibe")
  remove_if_exists(root)
}

///|
test "codebase resolve_lock_root prefers ancestor index.lock even without .vibe" {
  let root = make_temp_dir("lock_root_ancestor_lock_only")
  let project = root + "/project"
  let nested = project + "/nested"
  @os_fs.create_dir(project) catch {
    e => fail(e.to_string())
  }
  @os_fs.create_dir(nested) catch {
    e => fail(e.to_string())
  }
  write_file(root + "/index.lock", "{\"path\":{},\"version\":{},\"symbol\":{}}")
  write_file(project + "/index.vibe", "export let version = \"0.1.0\"\n")
  let entry = nested + "/main.vibe"
  assert_eq(resolve_lock_root(entry), root)
  assert_eq(lock_file_path(entry), root + "/index.lock")
  assert_eq(vibe_dir_path(entry), root + "/.vibe")
  remove_if_exists(root)
}

///|
test "codebase vibe_dir_path prefers shared vibe/.vibe for vibe subtree" {
  let root = make_temp_dir("vibe_shared_vibe_dir")
  let vibe_root = root + "/vibe"
  let prelude_dir = vibe_root + "/prelude"
  let json_dir = vibe_root + "/json"
  let base64_dir = vibe_root + "/base64"
  let sha1_dir = vibe_root + "/sha1"
  @os_fs.create_dir(vibe_root) catch {
    e => fail(e.to_string())
  }
  @os_fs.create_dir(prelude_dir) catch {
    e => fail(e.to_string())
  }
  @os_fs.create_dir(json_dir) catch {
    e => fail(e.to_string())
  }
  @os_fs.create_dir(base64_dir) catch {
    e => fail(e.to_string())
  }
  @os_fs.create_dir(sha1_dir) catch {
    e => fail(e.to_string())
  }
  write_file(
    prelude_dir + "/index.lock",
    "{\"path\":{},\"version\":{},\"symbol\":{}}",
  )
  write_file(
    json_dir + "/index.lock",
    "{\"path\":{},\"version\":{},\"symbol\":{}}",
  )
  write_file(
    base64_dir + "/index.lock",
    "{\"path\":{},\"version\":{},\"symbol\":{}}",
  )
  write_file(
    sha1_dir + "/index.lock",
    "{\"path\":{},\"version\":{},\"symbol\":{}}",
  )
  let entry = prelude_dir + "/main.vibe"
  assert_eq(lock_file_path(entry), prelude_dir + "/index.lock")
  assert_eq(vibe_dir_path(entry), vibe_root + "/.vibe")
  remove_if_exists(root)
}

///|
test "codebase vibe_dir_path keeps local root for non-repo vibe dir" {
  let root = make_temp_dir("vibe_local_non_repo")
  let vibe_root = root + "/vibe"
  let pkg_dir = vibe_root + "/pkg"
  @os_fs.create_dir(vibe_root) catch {
    e => fail(e.to_string())
  }
  @os_fs.create_dir(pkg_dir) catch {
    e => fail(e.to_string())
  }
  write_file(
    pkg_dir + "/index.lock",
    "{\"path\":{},\"version\":{},\"symbol\":{}}",
  )
  let entry = pkg_dir + "/main.vibe"
  assert_eq(lock_file_path(entry), pkg_dir + "/index.lock")
  assert_eq(vibe_dir_path(entry), pkg_dir + "/.vibe")
  remove_if_exists(root)
}

///|
test "codebase resolve_index_root uses shared vibe root for repo subtree" {
  let root = make_temp_dir("index_root_repo_vibe")
  let vibe_root = root + "/vibe"
  let compiler_dir = vibe_root + "/compiler"
  let prelude_dir = vibe_root + "/prelude"
  let json_dir = vibe_root + "/json"
  let base64_dir = vibe_root + "/base64"
  let sha1_dir = vibe_root + "/sha1"
  @os_fs.create_dir(vibe_root) catch {
    e => fail(e.to_string())
  }
  @os_fs.create_dir(compiler_dir) catch {
    e => fail(e.to_string())
  }
  @os_fs.create_dir(prelude_dir) catch {
    e => fail(e.to_string())
  }
  @os_fs.create_dir(json_dir) catch {
    e => fail(e.to_string())
  }
  @os_fs.create_dir(base64_dir) catch {
    e => fail(e.to_string())
  }
  @os_fs.create_dir(sha1_dir) catch {
    e => fail(e.to_string())
  }
  write_file(
    prelude_dir + "/index.lock",
    "{\"path\":{},\"version\":{},\"symbol\":{}}",
  )
  write_file(
    json_dir + "/index.lock",
    "{\"path\":{},\"version\":{},\"symbol\":{}}",
  )
  write_file(
    base64_dir + "/index.lock",
    "{\"path\":{},\"version\":{},\"symbol\":{}}",
  )
  write_file(
    sha1_dir + "/index.lock",
    "{\"path\":{},\"version\":{},\"symbol\":{}}",
  )
  write_file(compiler_dir + "/index.vibe", "export let version = \"0.1.0\"\n")
  let entry = compiler_dir + "/main.vibe"
  assert_eq(resolve_index_root(entry), vibe_root)
  remove_if_exists(root)
}

///|
test "codebase load_lock_data falls back to legacy vibe.lock" {
  let root = make_temp_dir("legacy_lock")
  let entry = root + "/main.vibe"
  let legacy_path = root + "/vibe.lock"
  write_file(
    legacy_path, "{\"path\":{\"./main.vibe\":\"abcd\"},\"version\":{},\"symbol\":{}}",
  )
  let loaded = match load_lock_data(lock_file_path(entry)) {
    Ok(v) => v
    Err(err) => fail(err)
  }
  let entry_norm = @vibe_fs.normalize_path(entry)
  match loaded.path_refs.get(entry_norm) {
    Some(hash) => assert_eq(hash, "abcd")
    None => fail("expected legacy path ref")
  }
  remove_if_exists(root)
}

///|
test "codebase load_lock_data reads from index.lock" {
  let root = make_temp_dir("load_lock_from_index_lock")
  let entry = root + "/main.vibe"
  let lock_path = lock_file_path(entry)
  write_file(
    lock_path, "{\"path\":{\"./main.vibe\":\"from_lock\"},\"version\":{},\"symbol\":{}}",
  )
  let loaded = match load_lock_data(lock_path) {
    Ok(v) => v
    Err(err) => fail(err)
  }
  let entry_norm = @vibe_fs.normalize_path(entry)
  match loaded.path_refs.get(entry_norm) {
    Some(hash) => assert_eq(hash, "from_lock")
    None => fail("expected path ref from index.lock")
  }
  remove_if_exists(root)
}

///|
test "codebase write_lock_data round-trips through index.lock" {
  let root = make_temp_dir("write_lock_roundtrip")
  let entry = root + "/main.vibe"
  let entry_norm = @vibe_fs.normalize_path(entry)
  let lock_path = lock_file_path(entry)
  let path_refs : Map[String, String] = {}
  path_refs[entry_norm] = "from_lock_write"
  let lock = LockData::new_with_meta(
    path_refs,
    { "main": "bbbb" },
    { "std/prelude": "cccc" },
    {},
    {},
  )
  match write_lock_data(lock_path, lock) {
    Ok(_) => ()
    Err(err) => fail(err)
  }
  let loaded = match load_lock_data(lock_path) {
    Ok(v) => v
    Err(err) => fail(err)
  }
  match loaded.path_refs.get(entry_norm) {
    Some(hash) => assert_eq(hash, "from_lock_write")
    None => fail("expected path ref from index.lock round-trip")
  }
  remove_if_exists(root)
}

///|
test "codebase update_lock_path_refs rejects imports outside index root" {
  let root = make_temp_dir("root_guard")
  let outside_name = "vibe_codebase_test_outside_guard"
  let outside = @vibe_fs.normalize_path(root + "/../" + outside_name)
  remove_if_exists(outside)
  @os_fs.create_dir(outside) catch {
    e => fail(e.to_string())
  }
  let entry = root + "/main.vibe"
  let outside_lib = outside + "/lib.vibe"
  write_file(
    root + "/index.vibe",
    "export let version = \"0.1.0\"\nexport let module = record { std: \"./vibe/prelude\" }\n",
  )
  write_file(outside_lib, "let libv = 1\nexport { libv }\n")
  write_file(
    entry,
    "import ../" +
    outside_name +
    "/lib.vibe { libv }\nlet main = libv\nexport { main }\n",
  )
  match update_lock_path_refs(entry) {
    Ok(_) => fail("expected root guard error")
    Err(err) => assert_true(err.contains("outside root"))
  }
  remove_if_exists(root)
  remove_if_exists(outside)
}

///|
test "codebase update_lock_path_refs requires index version export" {
  let root = make_temp_dir("registry_version_required")
  let std_dir = root + "/vibe/prelude"
  @os_fs.create_dir(root + "/vibe") catch {
    e => fail(e.to_string())
  }
  @os_fs.create_dir(std_dir) catch {
    e => fail(e.to_string())
  }
  let entry = root + "/main.vibe"
  let std_mod = std_dir + "/math.vibe"
  write_file(
    root + "/index.vibe",
    "export let module = record { std: \"./vibe/prelude\" }\n",
  )
  write_file(std_mod, "let value = 1\nexport { value }\n")
  write_file(
    entry, "import std/math.vibe {  value  }\nlet main = value\nexport { main }\n",
  )
  match update_lock_path_refs(entry) {
    Ok(_) => fail("expected missing version error")
    Err(err) =>
      assert_true(err.contains("missing required `export let version"))
  }
  remove_if_exists(root)
}

///|
test "codebase update_lock_path_refs validates index version format" {
  let root = make_temp_dir("registry_version_format")
  let std_dir = root + "/vibe/prelude"
  @os_fs.create_dir(root + "/vibe") catch {
    e => fail(e.to_string())
  }
  @os_fs.create_dir(std_dir) catch {
    e => fail(e.to_string())
  }
  let entry = root + "/main.vibe"
  let std_mod = std_dir + "/math.vibe"
  write_file(
    root + "/index.vibe",
    "export let version = \"v1\"\nexport let module = record { std: \"./vibe/prelude\" }\n",
  )
  write_file(std_mod, "let value = 1\nexport { value }\n")
  write_file(
    entry, "import std/math.vibe {  value  }\nlet main = value\nexport { main }\n",
  )
  match update_lock_path_refs(entry) {
    Ok(_) => fail("expected invalid semver error")
    Err(err) => assert_true(err.contains("must be semver"))
  }
  remove_if_exists(root)
}

///|
test "codebase update_lock_path_refs accepts export version" {
  let root = make_temp_dir("registry_declared_version")
  let std_dir = root + "/vibe/prelude"
  @os_fs.create_dir(root + "/vibe") catch {
    e => fail(e.to_string())
  }
  @os_fs.create_dir(std_dir) catch {
    e => fail(e.to_string())
  }
  let entry = root + "/main.vibe"
  let std_mod = std_dir + "/math.vibe"
  write_file(
    root + "/index.vibe",
    "export let version = \"0.1.0\"\nexport let module = record { std: \"./vibe/prelude\" }\n",
  )
  write_file(std_mod, "let value = 1\nexport { value }\n")
  write_file(
    entry, "import std/math.vibe { value }\nlet main = value\nexport { main }\n",
  )
  let updated = match update_lock_path_refs(entry) {
    Ok(v) => v
    Err(err) => fail(err)
  }
  let entry_norm = @vibe_fs.normalize_path(entry)
  let std_norm = @vibe_fs.normalize_path(std_mod)
  assert_true(updated.path_refs.contains(entry_norm))
  assert_true(updated.path_refs.contains(std_norm))
  remove_if_exists(root)
}

///|
test "codebase load_registry_modules falls back to prelude std json base64 sha1 path and collection" {
  let root = make_temp_dir("registry_default_namespaces")
  let modules = match load_registry_modules(root) {
    Ok(v) => v
    Err(err) => fail(err)
  }
  let prelude_path = @vibe_fs.normalize_path(root + "/vibe/prelude")
  let json_path = @vibe_fs.normalize_path(root + "/vibe/json")
  let base64_path = @vibe_fs.normalize_path(root + "/vibe/base64")
  let sha1_path = @vibe_fs.normalize_path(root + "/vibe/sha1")
  let path_path = @vibe_fs.normalize_path(root + "/vibe/path")
  let collection_path = @vibe_fs.normalize_path(root + "/vibe/collection")
  assert_eq(modules["prelude"], prelude_path)
  assert_eq(modules["std"], prelude_path)
  assert_eq(modules["json"], json_path)
  assert_eq(modules["base64"], base64_path)
  assert_eq(modules["sha1"], sha1_path)
  assert_eq(modules["path"], path_path)
  assert_eq(modules["collection"], collection_path)
  remove_if_exists(root)
}

///|
test "codebase update_lock_path_refs resolves std namespace via index.vibe" {
  let root = make_temp_dir("registry_std")
  let std_dir = root + "/vibe/prelude"
  @os_fs.create_dir(root + "/vibe") catch {
    e => fail(e.to_string())
  }
  @os_fs.create_dir(std_dir) catch {
    e => fail(e.to_string())
  }
  let entry = root + "/main.vibe"
  let std_mod = std_dir + "/math.vibe"
  write_file(
    root + "/index.vibe",
    "export let version = \"0.1.0\"\nexport let module = record { std: \"./vibe/prelude\" }\n",
  )
  write_file(std_mod, "let value = 1\nexport { value }\n")
  write_file(
    entry, "import std/math.vibe {  value  }\nlet main = value\nexport { main }\n",
  )
  let updated = match update_lock_path_refs(entry) {
    Ok(v) => v
    Err(err) => fail(err)
  }
  let entry_norm = @vibe_fs.normalize_path(entry)
  let std_norm = @vibe_fs.normalize_path(std_mod)
  assert_true(updated.path_refs.contains(entry_norm))
  assert_true(updated.path_refs.contains(std_norm))
  remove_if_exists(root)
}

///|
test "codebase update_lock_path_refs ignores normalize section separators in path hash" {
  let root = make_temp_dir("lock_hash_ignore_section")
  let entry = root + "/main.vibe"
  let source_plain = "let main = 1\n\nexport { main }\n"
  write_file(entry, source_plain)
  let updated_plain = match update_lock_path_refs(entry) {
    Ok(v) => v
    Err(err) => fail(err)
  }
  let norm = @vibe_fs.normalize_path(entry)
  let hash_plain = match updated_plain.path_refs.get(norm) {
    Some(v) => v
    None => fail("expected plain path hash")
  }
  let source_with_sections = "//# Functions\nlet main = 1\n\nexport { main }\n"
  write_file(entry, source_with_sections)
  let updated_sectioned = match update_lock_path_refs(entry) {
    Ok(v) => v
    Err(err) => fail(err)
  }
  let hash_sectioned = match updated_sectioned.path_refs.get(norm) {
    Some(v) => v
    None => fail("expected sectioned path hash")
  }
  assert_eq(hash_plain, hash_sectioned)
  remove_if_exists(root)
}

///|
test "codebase update_lock_path_refs captures export comments as annotations" {
  let root = make_temp_dir("annotations_capture")
  let entry = root + "/main.vibe"
  write_file(
    entry, "// first line\n// second line\nlet main = 1\nexport { main }\n",
  )
  let updated = match update_lock_path_refs(entry) {
    Ok(v) => v
    Err(err) => fail(err)
  }
  let key = @vibe_fs.normalize_path(entry) + "#main"
  match updated.annotations.get(key) {
    Some(note) => assert_eq(note, "first line\nsecond line")
    None => fail("expected annotation")
  }
  remove_if_exists(root)
}

///|
test "codebase update_lock_path_refs clears removed comments in annotations" {
  let root = make_temp_dir("annotations_remove")
  let entry = root + "/main.vibe"
  write_file(entry, "// note\nlet main = 1\nexport { main }\n")
  let _ = match update_lock_path_refs(entry) {
    Ok(v) => v
    Err(err) => fail(err)
  }
  write_file(entry, "let main = 1\nexport { main }\n")
  let updated = match update_lock_path_refs(entry) {
    Ok(v) => v
    Err(err) => fail(err)
  }
  let key = @vibe_fs.normalize_path(entry) + "#main"
  assert_false(updated.annotations.contains(key))
  remove_if_exists(root)
}

///|
test "codebase apply_annotations_to_source injects export comments" {
  let root = make_temp_dir("annotations_apply")
  let path = @vibe_fs.normalize_path(root + "/main.vibe")
  let source = "let main = 1\nexport { main }\n"
  let annotations : Map[String, String] = {}
  annotations[path + "#main"] = "hello\nworld"
  let applied = match apply_annotations_to_source(path, source, annotations) {
    Ok(v) => v
    Err(err) => fail(err)
  }
  assert_true(applied.contains("// hello\n// world\nlet main = 1"))
  remove_if_exists(root)
}

///|
test "codebase apply_annotations_to_source avoids duplicate when comment exists" {
  let root = make_temp_dir("annotations_apply_existing")
  let path = @vibe_fs.normalize_path(root + "/main.vibe")
  let source = "// hello\nlet main = 1\nexport { main }\n"
  let annotations : Map[String, String] = {}
  annotations[path + "#main"] = "hello"
  let applied = match apply_annotations_to_source(path, source, annotations) {
    Ok(v) => v
    Err(err) => fail(err)
  }
  assert_eq(applied, source)
  remove_if_exists(root)
}

///|
test "codebase refresh_lock cross-directory transitive import" {
  // Simulate url_test.vibe pattern:
  // root/url_test.vibe -> ./url/pattern.vibe -> ../regexp/index.vibe
  let root = make_temp_dir("cross_dir_import")
  // index.vibe at root
  write_file(root + "/index.vibe", "export let version = \"0.1.0\"\n")
  // regexp module (sibling of url/)
  @os_fs.create_dir(root + "/regexp") catch {
    e => fail(e.to_string())
  }
  write_file(
    root + "/regexp/regexp.vibe",
    "export let compile = (s: String) -> String { s }\n",
  )
  write_file(
    root + "/regexp/index.vibe",
    "export ./regexp.vibe { compile }\nexport { compile }\n",
  )
  // url/ subdirectory
  @os_fs.create_dir(root + "/url") catch {
    e => fail(e.to_string())
  }
  write_file(
    root + "/url/pattern.vibe",
    "import ../regexp { compile }\nexport let make_pattern = (s: String) -> String { compile(s) }\n",
  )
  // Entry test file at root level
  let entry = root + "/url_test.vibe"
  write_file(
    entry, "import ./url/pattern.vibe { make_pattern }\nlet result = make_pattern(\"test\")\nexport { result }\n",
  )
  match refresh_lock_path_refs(entry) {
    Ok(lock) => {
      // Verify all transitive dependencies are in the lock
      let pattern_path = @vibe_fs.normalize_path(root + "/url/pattern.vibe")
      let regexp_index = @vibe_fs.normalize_path(root + "/regexp/index.vibe")
      let regexp_impl = @vibe_fs.normalize_path(root + "/regexp/regexp.vibe")
      let mut found_pattern = false
      let mut found_regexp_index = false
      let mut found_regexp_impl = false
      for path, _ in lock.path_refs {
        if path == pattern_path {
          found_pattern = true
        }
        if path == regexp_index {
          found_regexp_index = true
        }
        if path == regexp_impl {
          found_regexp_impl = true
        }
      }
      assert_true(found_pattern)
      assert_true(found_regexp_index)
      assert_true(found_regexp_impl)
    }
    Err(err) => fail("cross-directory transitive import should succeed: " + err)
  }
  remove_if_exists(root)
}
