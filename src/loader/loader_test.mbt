///|
fn make_temp_dir(prefix : String) -> String {
  let tmp_root = @vibe_fs.normalize_path(@io.current_dir_or_root() + "/.tmp")
  if not(@os_fs.path_exists(tmp_root)) {
    @os_fs.create_dir(tmp_root) catch {
      e => abort("create temp root failed: " + e.to_string())
    }
  }
  let base = tmp_root + "/vibe_loader_test_" + prefix
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
pub impl @io.FileSystemAdapter for MemIoAdapter with current_dir_or_root(self) {
  self.cwd
}

///|
pub impl @io.FileSystemAdapter for MemIoAdapter with path_exists(self, path) {
  self.fs.exists(path)
}

///|
pub impl @io.FileSystemAdapter for MemIoAdapter with create_dir(self, path) {
  self.fs.mkdir_p(path) catch {
    e => return Err(e.to_string())
  }
  Ok(())
}

///|
pub impl @io.FileSystemAdapter for MemIoAdapter with read_dir(self, path) {
  let entries = self.fs.readdir(path) catch { e => return Err(e.to_string()) }
  let out : Array[String] = []
  for entry in entries {
    out.push(entry.name)
  }
  Ok(out)
}

///|
pub impl @io.FileSystemAdapter for MemIoAdapter with read_string(self, path) {
  let content = self.fs.read_string(path) catch {
    e => return Err(e.to_string())
  }
  Ok(content)
}

///|
pub impl @io.FileSystemAdapter for MemIoAdapter with read_bytes(self, path) {
  let content = self.fs.read_file(path) catch { e => return Err(e.to_string()) }
  Ok(content)
}

///|
pub impl @io.FileSystemAdapter for MemIoAdapter with write_string(
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
pub impl @io.FileSystemAdapter for MemIoAdapter with write_bytes(
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
test "loader load_db_with_paths loads transitive modules" {
  let root = make_temp_dir("transitive")
  let entry = root + "/main.vibe"
  let lib = root + "/lib.vibe"
  let entry_source = "import ./lib.vibe {  libv  }\nlet main = libv\nexport { main }\n"
  let lib_source = "let libv = 1\nexport { libv }\n"
  write_file(entry, entry_source)
  write_file(lib, lib_source)
  let loaded = match load_db_with_paths(entry) {
    Ok(v) => v
    Err(err) => fail(err)
  }
  let (db, resolved, paths) = loaded
  let entry_norm = @vibe_fs.normalize_path(entry)
  let lib_norm = @vibe_fs.normalize_path(lib)
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
test "loader resolve_entry_path_with_fs uses index.vibe for directory" {
  let root = "/workspace"
  let pkg = root + "/pkg"
  let fs = MemIoAdapter::new(root)
  match fs.create_dir(pkg) {
    Ok(_) => ()
    Err(err) => fail(err)
  }
  match
    fs.write_string(
      pkg + "/index.vibe",
      "export let version = \"0.1.0\"\nlet main = 1\nexport { main }\n",
    ) {
    Ok(_) => ()
    Err(err) => fail(err)
  }
  let resolved = resolve_entry_path_with_fs(pkg, fs)
  assert_eq(resolved, @vibe_fs.normalize_path(pkg + "/index.vibe"))
}

///|
test "loader load_db_with_paths_with_fs loads transitive modules via adapter" {
  let root = "/workspace"
  let entry = root + "/main.vibe"
  let lib = root + "/lib.vibe"
  let fs = MemIoAdapter::new(root)
  match
    fs.write_string(
      entry, "import ./lib.vibe {  libv  }\nlet main = libv\nexport { main }\n",
    ) {
    Ok(_) => ()
    Err(err) => fail(err)
  }
  match fs.write_string(lib, "let libv = 1\nexport { libv }\n") {
    Ok(_) => ()
    Err(err) => fail(err)
  }
  let loaded = match load_db_with_paths_with_fs(entry, fs) {
    Ok(v) => v
    Err(err) => fail(err)
  }
  let (db, resolved, paths) = loaded
  let entry_norm = @vibe_fs.normalize_path(entry)
  let lib_norm = @vibe_fs.normalize_path(lib)
  assert_eq(resolved, entry_norm)
  assert_true(contains_path(paths, entry_norm))
  assert_true(contains_path(paths, lib_norm))
  match db.get_source(entry_norm) {
    Some(source) =>
      assert_eq(
        source, "import ./lib.vibe {  libv  }\nlet main = libv\nexport { main }\n",
      )
    None => fail("expected entry source")
  }
  match db.get_source(lib_norm) {
    Some(source) => assert_eq(source, "let libv = 1\nexport { libv }\n")
    None => fail("expected imported source")
  }
}

///|
test "loader load_db_with_paths_with_fs resolves directory index import without explicit /index.vibe" {
  let root = "/workspace"
  let entry = root + "/main.vibe"
  let lib_dir = root + "/lib"
  let lib_index = lib_dir + "/index.vibe"
  let fs = MemIoAdapter::new(root)
  match fs.create_dir(lib_dir) {
    Ok(_) => ()
    Err(err) => fail(err)
  }
  match
    fs.write_string(
      entry, "import ./lib {  libv  }\nlet main = libv\nexport { main }\n",
    ) {
    Ok(_) => ()
    Err(err) => fail(err)
  }
  let lib_source = "let libv = 1\nexport { libv }\n"
  match fs.write_string(lib_index, lib_source) {
    Ok(_) => ()
    Err(err) => fail(err)
  }
  let loaded = match load_db_with_paths_with_fs(entry, fs) {
    Ok(v) => v
    Err(err) => fail(err)
  }
  let (db, resolved, paths) = loaded
  let entry_norm = @vibe_fs.normalize_path(entry)
  let lib_norm = @vibe_fs.normalize_path(lib_index)
  assert_eq(resolved, entry_norm)
  assert_true(contains_path(paths, entry_norm))
  assert_true(contains_path(paths, lib_norm))
  match db.get_source(lib_norm) {
    Some(source) => assert_eq(source, lib_source)
    None => fail("expected imported index source")
  }
}

///|
test "loader load_db_with_paths resolves directory to index.vibe" {
  let root = make_temp_dir("dir_index_entry")
  write_file(
    root + "/index.vibe",
    "export let version = \"0.1.0\"\nlet main = 1\nexport { main }\n",
  )
  let loaded = match load_db_with_paths(root) {
    Ok(v) => v
    Err(err) => fail(err)
  }
  let (_db, resolved, paths) = loaded
  let index_path = @vibe_fs.normalize_path(root + "/index.vibe")
  assert_eq(resolved, index_path)
  assert_true(contains_path(paths, index_path))
  remove_if_exists(root)
}

///|
test "loader load_db_with_paths requires version in directory index.vibe" {
  let root = make_temp_dir("dir_index_version_required")
  write_file(root + "/index.vibe", "let main = 1\nexport { main }\n")
  match load_db_with_paths(root) {
    Ok(_) => fail("expected missing version error")
    Err(err) =>
      assert_true(err.contains("missing required `export let version"))
  }
  remove_if_exists(root)
}

///|
test "loader load_db_with_paths reports import cycle" {
  let root = make_temp_dir("cycle")
  let a_path = root + "/a.vibe"
  let b_path = root + "/b.vibe"
  write_file(a_path, "import ./b.vibe {  b  }\nlet a = b\nexport { a }\n")
  write_file(b_path, "import ./a.vibe {  a  }\nlet b = a\nexport { b }\n")
  match load_db_with_paths(a_path) {
    Ok(_) => fail("expected import cycle error")
    Err(err) => assert_true(err.contains("import cycle detected"))
  }
  remove_if_exists(root)
}

///|
test "loader load_db_with_paths rejects import outside index root" {
  let root = make_temp_dir("root_guard")
  let outside_name = "vibe_loader_test_outside_guard"
  let outside = @vibe_fs.normalize_path(root + "/../" + outside_name)
  remove_if_exists(outside)
  @os_fs.create_dir(outside) catch {
    e => fail(e.to_string())
  }
  let entry = root + "/main.vibe"
  let outside_lib = outside + "/lib.vibe"
  write_file(
    root + "/index.vibe",
    "export let version = \"0.1.0\"\nexport let module = record { std: \"./vibe/builtin\" }\n",
  )
  write_file(outside_lib, "let libv = 1\nexport { libv }\n")
  write_file(
    entry,
    "import ../" +
    outside_name +
    "/lib.vibe { libv }\nlet main = libv\nexport { main }\n",
  )
  match load_db_with_paths(entry) {
    Ok(_) => fail("expected outside root error")
    Err(err) => assert_true(err.contains("outside root"))
  }
  remove_if_exists(root)
  remove_if_exists(outside)
}

///|
test "loader load_db_with_paths resolves std namespace from index registry" {
  let root = make_temp_dir("registry_std")
  let std_root = root + "/vibe/builtin"
  @os_fs.create_dir(root + "/vibe") catch {
    e => fail(e.to_string())
  }
  @os_fs.create_dir(std_root) catch {
    e => fail(e.to_string())
  }
  let entry = root + "/main.vibe"
  let std_mod = std_root + "/math.vibe"
  write_file(
    root + "/index.vibe",
    "export let version = \"0.1.0\"\nexport let module = record { std: \"./vibe/builtin\" }\n",
  )
  write_file(std_mod, "let value = 1\nexport { value }\n")
  write_file(
    entry, "import std/math.vibe {  value  }\nlet main = value\nexport { main }\n",
  )
  let loaded = match load_db_with_paths(entry) {
    Ok(v) => v
    Err(err) => fail(err)
  }
  let (_db, _resolved, paths) = loaded
  let std_norm = @vibe_fs.normalize_path(std_mod)
  assert_true(contains_path(paths, std_norm))
  remove_if_exists(root)
}

///|
test "loader load_db_with_paths reports unknown namespace import" {
  let root = make_temp_dir("unknown_namespace")
  let entry = root + "/main.vibe"
  write_file(
    entry, "import stdd/string.vibe {  join  }\nlet main = join([\"a\"], \",\")\nexport { main }\n",
  )
  match load_db_with_paths(entry) {
    Ok(_) => fail("expected unknown namespace error")
    Err(err) => {
      assert_true(err.contains("unknown namespace"))
      assert_true(err.contains("stdd"))
    }
  }
  remove_if_exists(root)
}

///|
test "loader load_db_with_paths requires index version export" {
  let root = make_temp_dir("registry_version_required")
  let std_root = root + "/vibe/builtin"
  @os_fs.create_dir(root + "/vibe") catch {
    e => fail(e.to_string())
  }
  @os_fs.create_dir(std_root) catch {
    e => fail(e.to_string())
  }
  let entry = root + "/main.vibe"
  let std_mod = std_root + "/math.vibe"
  write_file(
    root + "/index.vibe",
    "export let module = record { std: \"./vibe/builtin\" }\n",
  )
  write_file(std_mod, "let value = 1\nexport { value }\n")
  write_file(
    entry, "import std/math.vibe {  value  }\nlet main = value\nexport { main }\n",
  )
  match load_db_with_paths(entry) {
    Ok(_) => fail("expected missing version error")
    Err(err) =>
      assert_true(err.contains("missing required `export let version"))
  }
  remove_if_exists(root)
}

///|
test "loader load_db_with_paths refreshes stale index.lock path hashes" {
  let root = make_temp_dir("lock_refresh")
  let entry = root + "/main.vibe"
  let lib = root + "/lib.vibe"
  let entry_source = "import ./lib.vibe {  libv  }\nlet main = libv\nexport { main }\n"
  let lib_source = "let libv = 1\nexport { libv }\n"
  write_file(entry, entry_source)
  write_file(lib, lib_source)
  let lock_path = @codebase.lock_file_path(entry)
  write_file(
    lock_path, "{\"path\":{\"./main.vibe\":\"stale_main\",\"./lib.vibe\":\"stale_lib\"},\"version\":{},\"symbol\":{}}",
  )
  match load_db_with_paths(entry) {
    Ok(_) => ()
    Err(err) => fail(err)
  }
  let updated = match @codebase.load_lock_data(lock_path) {
    Ok(v) => v
    Err(err) => fail(err)
  }
  let entry_norm = @vibe_fs.normalize_path(entry)
  let lib_norm = @vibe_fs.normalize_path(lib)
  match updated.path_refs.get(entry_norm) {
    Some(hash) => assert_eq(hash, @vibe_core.git_blob_hash_string(entry_source))
    None => fail("expected entry hash in refreshed lock")
  }
  match updated.path_refs.get(lib_norm) {
    Some(hash) => assert_eq(hash, @vibe_core.git_blob_hash_string(lib_source))
    None => fail("expected lib hash in refreshed lock")
  }
  remove_if_exists(root)
}

///|
test "loader load_db_with_paths keeps re-exported Process function callable" {
  let root = make_temp_dir("process_reexport")
  let pkg_dir = root + "/pkg"
  let proc_dir = pkg_dir + "/process"
  @os_fs.create_dir(pkg_dir) catch {
    e => fail(e.to_string())
  }
  @os_fs.create_dir(proc_dir) catch {
    e => fail(e.to_string())
  }
  write_file(pkg_dir + "/index.vibe", "export let version = \"0.1.0\"\n")
  write_file(
    proc_dir + "/index.vibe",
    "export let version = \"0.1.0\"\n" +
    "export ./process.vibe { run_lines }\n" +
    "export { run_lines }\n",
  )
  write_file(
    proc_dir + "/process.vibe",
    "export let run_lines = (cmd: String) -> Array[String] with { Process } {\n" +
    "  [cmd]\n" +
    "}\n" +
    "export { run_lines }\n",
  )
  let entry = proc_dir + "/index_import_test.vibe"
  write_file(
    entry,
    "import ./index.vibe { run_lines }\n" +
    "let lines = run_lines(\"ok\")\n" +
    "assert(eq(array_length(lines), 1))\n",
  )
  let loaded = match load_db_with_paths(entry) {
    Ok(v) => v
    Err(err) => fail(err)
  }
  let (db, resolved, _) = loaded
  let env = db.types(resolved)
  let diags = db.diagnostics(resolved)
  let has_type_diag = diags.any(fn(diag) { diag.stage == "type" })
  if has_type_diag {
    let lines : Array[String] = []
    for diag in diags {
      lines.push(diag.stage + ":" + diag.message)
    }
    fail("unexpected diagnostics: " + lines.join(","))
  }
  match env.get_scheme("run_lines") {
    Some(scheme) =>
      match scheme.ty {
        @vibe_core.Type::Func(..) => ()
        _ => fail("expected function scheme: run_lines")
      }
    None => fail("expected imported scheme: run_lines")
  }
  remove_if_exists(root)
}

///|
test "loader load_db_with_paths: repo process index_import_test has callable run_lines" {
  let cwd = @io.current_dir_or_root()
  let entry = @vibe_fs.normalize_path(
    cwd + "/vibe/process/index_import_test.vibe",
  )
  let loaded = match load_db_with_paths(entry) {
    Ok(v) => v
    Err(err) => fail(err)
  }
  let (db, resolved, _) = loaded
  let env = db.types(resolved)
  let diags = db.diagnostics(resolved)
  let type_diags = diags.filter(fn(diag) { diag.stage == "type" })
  if not(type_diags.is_empty()) {
    let lines : Array[String] = []
    for diag in type_diags {
      lines.push(diag.stage + ":" + diag.message)
    }
    fail("unexpected type diagnostics: " + lines.join(","))
  }
  match env.get_scheme("run_lines") {
    Some(scheme) =>
      match scheme.ty {
        @vibe_core.Type::Func(..) => ()
        _ => fail("expected function scheme: run_lines")
      }
    None => fail("expected imported scheme: run_lines")
  }
}

///|
test "loader load_db_with_paths: repo threads_runtime_test imports runtime_hints" {
  let cwd = @io.current_dir_or_root()
  let entry = @vibe_fs.normalize_path(
    cwd + "/vibe/builtin/threads_runtime_test.vibe",
  )
  let loaded = match load_db_with_paths(entry) {
    Ok(v) => v
    Err(err) => fail(err)
  }
  let (db, resolved, _) = loaded
  let env = db.types(resolved)
  let diags = db.diagnostics(resolved)
  match env.get_scheme("runtime_hints") {
    Some(scheme) =>
      match scheme.ty {
        @vibe_core.Type::Func(..) => ()
        _ => fail("expected function scheme: runtime_hints")
      }
    None => {
      let lines : Array[String] = []
      for diag in diags {
        lines.push(diag.stage + ":" + diag.message)
      }
      fail("expected imported scheme: runtime_hints; diags=" + lines.join(","))
    }
  }
}
