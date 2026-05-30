///|
fn make_temp_dir(prefix : String) -> String {
  let tmp_root = @vibe_fs.normalize_path(@io.current_dir_or_root() + "/.tmp")
  if !@os_fs.path_exists(tmp_root) {
    @os_fs.create_dir(tmp_root) catch {
      e => abort("create temp root failed: " + e.to_string())
    }
  }
  let base = tmp_root + "/vibe_loader_test_" + prefix
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
test "loader load_db_with_paths_with_fs resolves alias imports declared in index.vibe" {
  let root = "/workspace/pkg"
  let entry = root + "/main.vibe"
  let alias_target = root + "/types.vibe"
  let index_path = root + "/index.vibe"
  let fs = MemIoAdapter::new(root)
  match
    fs.write_string(
      index_path, "export let version = \"0.1.0\"\nimport ./types.vibe @types\n",
    ) {
    Ok(_) => ()
    Err(err) => fail(err)
  }
  match fs.write_string(alias_target, "let value = 41\nexport { value }\n") {
    Ok(_) => ()
    Err(err) => fail(err)
  }
  match
    fs.write_string(
      entry, "import @types { value }\nlet main = value\nexport { main }\n",
    ) {
    Ok(_) => ()
    Err(err) => fail(err)
  }
  let loaded = match load_db_with_paths_with_fs(entry, fs) {
    Ok(v) => v
    Err(err) => fail(err)
  }
  let (db, resolved, paths) = loaded
  let entry_norm = @vibe_fs.normalize_path(entry)
  let index_norm = @vibe_fs.normalize_path(index_path)
  let alias_norm = @vibe_fs.normalize_path(alias_target)
  assert_eq(resolved, entry_norm)
  assert_true(contains_path(paths, alias_norm))
  match db.get_source(index_norm) {
    Some(source) => assert_true(source.contains("import ./types.vibe @types"))
    None => fail("expected index.vibe source for alias resolution")
  }
  let env = db.types(resolved)
  let diags = db.diagnostics(resolved)
  if !diags.is_empty() {
    let lines : Array[String] = []
    for diag in diags {
      lines.push(diag.stage + ":" + diag.message)
    }
    fail("unexpected diagnostics: " + lines.join(","))
  }
  match env.get_scheme("value") {
    Some(_) => ()
    None => fail("expected alias-imported value in env")
  }
}

///|
test "loader load_db_with_paths_with_fs reports unresolved alias declaration" {
  let root = "/workspace/missing_alias"
  let entry = root + "/main.vibe"
  let fs = MemIoAdapter::new(root)
  match
    fs.write_string(root + "/index.vibe", "export let version = \"0.1.0\"\n") {
    Ok(_) => ()
    Err(err) => fail(err)
  }
  match
    fs.write_string(
      entry, "import @types { value }\nlet main = value\nexport { main }\n",
    ) {
    Ok(_) => ()
    Err(err) => fail(err)
  }
  match load_db_with_paths_with_fs(entry, fs) {
    Ok(_) => fail("expected unresolved alias error")
    Err(err) => {
      assert_true(err.contains("alias @types not found"))
      assert_true(err.contains("index.vibe"))
    }
  }
}

///|
test "loader load_db_with_paths_with_fs resolves alias re-exports declared in index.vibe" {
  let root = "/workspace/alias_reexport"
  let entry = root + "/main.vibe"
  let alias_target = root + "/types.vibe"
  let index_path = root + "/index.vibe"
  let fs = MemIoAdapter::new(root)
  match
    fs.write_string(
      index_path,
      "export let version = \"0.1.0\"\n" +
      "import ./types.vibe @types\n" +
      "export @types { value }\n",
    ) {
    Ok(_) => ()
    Err(err) => fail(err)
  }
  match fs.write_string(alias_target, "let value = 41\nexport { value }\n") {
    Ok(_) => ()
    Err(err) => fail(err)
  }
  match
    fs.write_string(
      entry, "import ./index.vibe { value }\nlet main = value\nexport { main }\n",
    ) {
    Ok(_) => ()
    Err(err) => fail(err)
  }
  let loaded = match load_db_with_paths_with_fs(entry, fs) {
    Ok(v) => v
    Err(err) => fail(err)
  }
  let (db, resolved, paths) = loaded
  let alias_norm = @vibe_fs.normalize_path(alias_target)
  assert_true(contains_path(paths, alias_norm))
  let diags = db.import_diagnostics(resolved)
  if !diags.is_empty() {
    let lines : Array[String] = []
    for diag in diags {
      lines.push(diag.stage + ":" + diag.message)
    }
    fail("unexpected import diagnostics: " + lines.join(","))
  }
  let env = db.types(resolved)
  match env.get_scheme("value") {
    Some(_) => ()
    None => fail("expected alias re-exported value in env")
  }
}

///|
test "loader load_db_with_paths_with_fs extracts vibe blocks from markdown entry" {
  let root = "/workspace/docs"
  let entry = root + "/guide.md"
  let lib = root + "/lib.vibe"
  let fs = MemIoAdapter::new(root)
  match fs.write_string(lib, "let value = 7\nexport { value }\n") {
    Ok(_) => ()
    Err(err) => fail(err)
  }
  match
    fs.write_string(
      entry, "# Guide\n\n```js\nconst hidden = 1\n```\n\n```vibe\nimport ./lib.vibe { value }\nlet main = value\nexport { main }\n```\n\n```vibe\nlet extra = main + 1\n```\n",
    ) {
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
  assert_true(contains_path(paths, lib_norm))
  match db.get_source(entry_norm) {
    Some(source) => {
      assert_true(source.contains("let main = value"))
      assert_true(source.contains("let extra = main + 1"))
      assert_false(source.contains("const hidden = 1"))
    }
    None => fail("expected markdown source to be extracted")
  }
  let diags = db.import_diagnostics(resolved)
  if !diags.is_empty() {
    let lines : Array[String] = []
    for diag in diags {
      lines.push(diag.stage + ":" + diag.message)
    }
    fail("unexpected import diagnostics: " + lines.join(","))
  }
}

///|
test "loader load_db_with_paths_with_fs loads wasm binary imports" {
  let lib_db = @runtime.VibeDb::new()
  lib_db.set_source(
    "lib", "export let inflate = (src: Int, dst: Int) -> Int { src + dst }\n",
  )
  let wasm = try @runtime_compile.compile_module_wasm(lib_db, "lib") catch {
    e => fail("failed to build wasm fixture: " + e.to_string())
  } noraise {
    b => b
  }
  let root = "/workspace/wasm_loader"
  let entry = root + "/main.vibe"
  let wasm_path = root + "/zlib.wasm"
  let fs = MemIoAdapter::new(root)
  match fs.write_bytes(wasm_path, wasm) {
    Ok(_) => ()
    Err(err) => fail(err)
  }
  match
    fs.write_string(
      entry, "import ./zlib.wasm { inflate }\nlet main = inflate(1, 2, 0)\nexport { main }\n",
    ) {
    Ok(_) => ()
    Err(err) => fail(err)
  }
  let loaded = match load_db_with_paths_with_fs(entry, fs) {
    Ok(v) => v
    Err(err) => fail(err)
  }
  let (db, resolved, paths) = loaded
  let entry_norm = @vibe_fs.normalize_path(entry)
  let wasm_norm = @vibe_fs.normalize_path(wasm_path)
  assert_eq(resolved, entry_norm)
  assert_true(contains_path(paths, wasm_norm))
  let imports = db.imports(resolved)
  assert_eq(imports.length(), 1)
  assert_eq(imports[0].path, wasm_norm)
  assert_true(imports[0].hash is Some(_))
  let _ = db.types(resolved)
  let diags = db.diagnostics(resolved)
  if !diags.is_empty() {
    let lines : Array[String] = []
    for diag in diags {
      lines.push(diag.stage + ":" + diag.message)
    }
    fail("unexpected diagnostics: " + lines.join(","))
  }
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
test "loader load_db_with_paths keeps transitive import diagnostics clean" {
  let root = make_temp_dir("transitive_diags")
  let entry = root + "/main.vibe"
  let lib = root + "/lib.vibe"
  let dep = root + "/dep.vibe"
  write_file(
    entry, "import ./lib.vibe { value }\nlet main = value\nexport { main }\n",
  )
  write_file(
    lib, "import ./dep.vibe { dep }\nlet value = dep\nexport { value }\n",
  )
  write_file(dep, "let dep = 1\nexport { dep }\n")
  let loaded = match load_db_with_paths(entry) {
    Ok(v) => v
    Err(err) => fail(err)
  }
  let (db, resolved, _) = loaded
  let entry_diags = db.import_diagnostics(resolved)
  if !entry_diags.is_empty() {
    let lines : Array[String] = []
    for diag in entry_diags {
      lines.push(diag.stage + ":" + diag.message)
    }
    fail("unexpected entry import diagnostics: " + lines.join(","))
  }
  let lib_diags = db.import_diagnostics(@vibe_fs.normalize_path(lib))
  if !lib_diags.is_empty() {
    let lines : Array[String] = []
    for diag in lib_diags {
      lines.push(diag.stage + ":" + diag.message)
    }
    fail("unexpected lib import diagnostics: " + lines.join(","))
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
test "loader resolve_entry_graph_head_with_fs reads graph_head from .vibe/cache.json" {
  let root = "/workspace"
  let pkg = root + "/pkg"
  let fs = MemIoAdapter::new(root)
  match fs.create_dir(pkg) {
    Ok(_) => ()
    Err(err) => fail(err)
  }
  match fs.write_string(pkg + "/index.vibe", "let version = \"0.1.0\"\n") {
    Ok(_) => ()
    Err(err) => fail(err)
  }
  match fs.create_dir(pkg + "/.vibe") {
    Ok(_) => ()
    Err(err) => fail(err)
  }
  match
    fs.write_string(
      pkg + "/.vibe/cache.json",
      "{\"graph_head\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}",
    ) {
    Ok(_) => ()
    Err(err) => fail(err)
  }
  match resolve_entry_graph_head_with_fs(pkg, fs) {
    Some(hash) => assert_eq(hash, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    None => fail("expected graph_head")
  }
}

///|
test "loader resolve_entry_graph_head_with_fs returns None without graph_head" {
  let root = "/workspace"
  let pkg = root + "/pkg"
  let fs = MemIoAdapter::new(root)
  match fs.create_dir(pkg) {
    Ok(_) => ()
    Err(err) => fail(err)
  }
  match fs.write_string(pkg + "/index.vibe", "let version = \"0.1.0\"\n") {
    Ok(_) => ()
    Err(err) => fail(err)
  }
  match fs.create_dir(pkg + "/.vibe") {
    Ok(_) => ()
    Err(err) => fail(err)
  }
  match fs.write_string(pkg + "/.vibe/cache.json", "{\"lock\":{}}") {
    Ok(_) => ()
    Err(err) => fail(err)
  }
  @debug.assert_eq(resolve_entry_graph_head_with_fs(pkg, fs), None)
}

///|
test "loader resolve_import_path maps extensionless path to index.vibe endpoint" {
  let base = "/workspace/pkg"
  let resolved = resolve_import_path(base, "./dep")
  assert_eq(resolved, @vibe_fs.normalize_path("/workspace/pkg/dep/index.vibe"))
}

///|
test "loader resolve_import_path keeps explicit file extension" {
  let base = "/workspace/pkg"
  let resolved = resolve_import_path(base, "./dep.vibe")
  assert_eq(resolved, @vibe_fs.normalize_path("/workspace/pkg/dep.vibe"))
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
    "export let version = \"0.1.0\"\nexport let module = record { std: \"./vibe/prelude\" }\n",
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
  let std_root = root + "/vibe/prelude"
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
    "export let version = \"0.1.0\"\nexport let module = record { std: \"./vibe/prelude\" }\n",
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
  let std_root = root + "/vibe/prelude"
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
    "export let module = record { std: \"./vibe/prelude\" }\n",
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
test "loader load_db_for_test keeps stale index.lock untouched" {
  let root = make_temp_dir("lock_refresh_for_test")
  let entry = root + "/main.vibe"
  let lib = root + "/lib.vibe"
  let entry_source = "import ./lib.vibe {  libv  }\nlet main = libv\nexport { main }\n"
  let lib_source = "let libv = 1\nexport { libv }\n"
  write_file(entry, entry_source)
  write_file(lib, lib_source)
  let lock_path = @codebase.lock_file_path(entry)
  let stale_lock = "{\"path\":{\"./main.vibe\":\"stale_main\",\"./lib.vibe\":\"stale_lib\"},\"version\":{},\"symbol\":{}}"
  write_file(lock_path, stale_lock)
  let before = @os_fs.read_file_to_string(lock_path) catch {
    e => fail("read stale lock failed: " + e.to_string())
  }
  match load_db_for_test(entry) {
    Ok(_) => ()
    Err(err) => fail(err)
  }
  let after = @os_fs.read_file_to_string(lock_path) catch {
    e => fail("read lock after load_db_for_test failed: " + e.to_string())
  }
  assert_eq(after, before)
  remove_if_exists(root)
}

///|
test "loader load_db_for_test_into reuses existing db across entry loads" {
  let root = make_temp_dir("reuse_for_test")
  let entry_a = root + "/a.vibe"
  let entry_b = root + "/b.vibe"
  let lib = root + "/lib.vibe"
  let source_a = "import ./lib.vibe { value }\nlet main = value\nexport { main }\n"
  let source_b = "import ./lib.vibe { value }\nlet other = value + 1\nexport { other }\n"
  let lib_source = "let value = 41\nexport { value }\n"
  write_file(entry_a, source_a)
  write_file(entry_b, source_b)
  write_file(lib, lib_source)
  let db = @runtime.VibeDb::new()
  match load_db_for_test_into(db, entry_a) {
    Ok(_) => ()
    Err(err) => fail(err)
  }
  match load_db_for_test_into(db, entry_b) {
    Ok(_) => ()
    Err(err) => fail(err)
  }
  let entry_a_norm = @vibe_fs.normalize_path(entry_a)
  let entry_b_norm = @vibe_fs.normalize_path(entry_b)
  let lib_norm = @vibe_fs.normalize_path(lib)
  match db.get_source(entry_a_norm) {
    Some(source) => assert_eq(source, source_a)
    None => fail("expected cached first entry source")
  }
  match db.get_source(entry_b_norm) {
    Some(source) => assert_eq(source, source_b)
    None => fail("expected cached second entry source")
  }
  match db.get_source(lib_norm) {
    Some(source) => assert_eq(source, lib_source)
    None => fail("expected cached shared import source")
  }
  remove_if_exists(root)
}

///|
test "loader load_db_with_paths_into refreshes changed source in reused db" {
  let root = make_temp_dir("reuse_refresh")
  let entry = root + "/main.vibe"
  let lib = root + "/lib.vibe"
  let entry_source = "import ./lib.vibe { value }\nlet main = value\nexport { main }\n"
  let lib_source1 = "let value = 1\nexport { value }\n"
  let lib_source2 = "let value = 2\nexport { value }\n"
  write_file(entry, entry_source)
  write_file(lib, lib_source1)
  let db = @runtime.VibeDb::new()
  match load_db_with_paths_into(db, entry) {
    Ok(_) => ()
    Err(err) => fail(err)
  }
  write_file(lib, lib_source2)
  match load_db_with_paths_into(db, entry) {
    Ok(_) => ()
    Err(err) => fail(err)
  }
  let lib_norm = @vibe_fs.normalize_path(lib)
  match db.get_source(lib_norm) {
    Some(source) => assert_eq(source, lib_source2)
    None => fail("expected refreshed imported source")
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
    "let call = () -> Array[String] with { Process } { run_lines(\"ok\") }\n" +
    "0\n",
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
  if !type_diags.is_empty() {
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
    cwd + "/vibe/prelude/threads_runtime_test.vibe",
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

///|
test "loader load_db_with_paths: repo url_test cross-directory import" {
  let cwd = @io.current_dir_or_root()
  let entry = @vibe_fs.normalize_path(cwd + "/vibe/x/url_test.vibe")
  let loaded = match load_db_with_paths(entry) {
    Ok(v) => v
    Err(err) => fail("url_test.vibe should load: " + err)
  }
  let (db, resolved, paths) = loaded
  // Verify cross-directory transitive dependencies were loaded
  let regexp_index = @vibe_fs.normalize_path(cwd + "/vibe/x/regexp/index.vibe")
  let pattern_path = @vibe_fs.normalize_path(cwd + "/vibe/x/url/pattern.vibe")
  assert_true(contains_path(paths, regexp_index))
  assert_true(contains_path(paths, pattern_path))
  // Verify no import-stage errors
  let diags = db.import_diagnostics(resolved)
  let import_errors = diags.filter(fn(diag) {
    diag.stage == "import" && diag.message.contains("missing:")
  })
  if !import_errors.is_empty() {
    let lines : Array[String] = []
    for diag in import_errors {
      lines.push(diag.message)
    }
    fail("unexpected import errors: " + lines.join(","))
  }
}

///|
test "loader load_db_with_paths: repo url/url_test cross-directory import" {
  let cwd = @io.current_dir_or_root()
  let entry = @vibe_fs.normalize_path(cwd + "/vibe/x/url/url_test.vibe")
  let loaded = match load_db_with_paths(entry) {
    Ok(v) => v
    Err(err) => fail("url/url_test.vibe should load: " + err)
  }
  let (db, resolved, paths) = loaded
  // Verify cross-directory transitive dependencies were loaded
  let regexp_index = @vibe_fs.normalize_path(cwd + "/vibe/x/regexp/index.vibe")
  assert_true(contains_path(paths, regexp_index))
  // Verify no import-stage errors
  let diags = db.import_diagnostics(resolved)
  let import_errors = diags.filter(fn(diag) {
    diag.stage == "import" && diag.message.contains("missing:")
  })
  if !import_errors.is_empty() {
    let lines : Array[String] = []
    for diag in import_errors {
      lines.push(diag.message)
    }
    fail("unexpected import errors: " + lines.join(","))
  }
}

///|
test "loader load_db_with_paths: repo scan_root_import_test cross-directory" {
  let cwd = @io.current_dir_or_root()
  let entry = @vibe_fs.normalize_path(
    cwd + "/vibe/x/url/scan_root_import_test.vibe",
  )
  let loaded = match load_db_with_paths(entry) {
    Ok(v) => v
    Err(err) => fail("scan_root_import_test.vibe should load: " + err)
  }
  let (db, resolved, paths) = loaded
  // Verify cross-directory import was loaded
  let scan_index = @vibe_fs.normalize_path(cwd + "/vibe/x/scan/index.vibe")
  assert_true(contains_path(paths, scan_index))
  let diags = db.import_diagnostics(resolved)
  let import_errors = diags.filter(fn(diag) {
    diag.stage == "import" && diag.message.contains("missing:")
  })
  if !import_errors.is_empty() {
    let lines : Array[String] = []
    for diag in import_errors {
      lines.push(diag.message)
    }
    fail("unexpected import errors: " + lines.join(","))
  }
}

///|
test "loader load_db_with_paths: repo compiler index entry" {
  let cwd = @io.current_dir_or_root()
  let entry = @vibe_fs.normalize_path(cwd + "/vibe/compiler/index.vibe")
  let loader_path = @vibe_fs.normalize_path(
    cwd + "/vibe/compiler/loader/index.vibe",
  )
  let cache_path = @vibe_fs.normalize_path(
    cwd + "/vibe/compiler/cache/persistent_cache.vibe",
  )
  let header_codec_path = @vibe_fs.normalize_path(
    cwd + "/vibe/compiler/cache/persistent_module_header_codec.vibe",
  )
  let loaded = match load_db_with_paths(entry) {
    Ok(v) => v
    Err(err) => fail("compiler index should load: " + err)
  }
  let (db, resolved, paths) = loaded
  assert_eq(resolved, entry)
  assert_true(contains_path(paths, loader_path))
  assert_true(contains_path(paths, cache_path))
  assert_true(contains_path(paths, header_codec_path))
  match db.get_source(entry) {
    Some(source) => assert_true(source.contains("selfbuild_entry"))
    None => fail("expected compiler entry source in db")
  }
  match db.get_source(loader_path) {
    Some(source) => assert_true(source.contains("collect_all_sources_fs"))
    None => fail("expected loader source in db")
  }
  match db.get_source(cache_path) {
    Some(source) =>
      assert_true(source.contains("persistent_module_header_cache_path"))
    None => fail("expected persistent cache source in db")
  }
  match db.get_source(header_codec_path) {
    Some(source) =>
      assert_true(source.contains("parse_persistent_module_header_text"))
    None => fail("expected persistent header codec source in db")
  }
}

///|
test "loader cross-root import via transitive dependency" {
  // Simulate url_test.vibe scenario:
  // /project/x/url_test.vibe imports ./url/pattern.vibe
  // /project/x/url/pattern.vibe imports ../regexp (cross-dir, still under root)
  let fs = MemIoAdapter::new("/project/x")
  // index.vibe at root so resolve_index_root finds /project/x
  fs.fs.write_string(
    "/project/x/index.vibe", "export let version = \"0.1.0\"\n",
  ) catch {
    e => fail(e.to_string())
  }
  // regexp module (sibling of url/ under x/)
  fs.fs.mkdir_p("/project/x/regexp") catch {
    e => fail(e.to_string())
  }
  fs.fs.write_string(
    "/project/x/regexp/index.vibe", "export ./regexp.vibe { compile }\nexport { compile }\n",
  ) catch {
    e => fail(e.to_string())
  }
  fs.fs.write_string(
    "/project/x/regexp/regexp.vibe", "export let compile = (s: String) -> String { s }\n",
  ) catch {
    e => fail(e.to_string())
  }
  // url/ subdirectory
  fs.fs.mkdir_p("/project/x/url") catch {
    e => fail(e.to_string())
  }
  fs.fs.write_string(
    "/project/x/url/pattern.vibe", "import ../regexp { compile }\nexport let make_pattern = (s: String) -> String { compile(s) }\n",
  ) catch {
    e => fail(e.to_string())
  }
  // Entry test file at root level
  fs.fs.write_string(
    "/project/x/url_test.vibe", "import ./url/pattern.vibe { make_pattern }\ntest \"basic\" {\n  let _ = make_pattern(\"x\")\n  assert(true)\n}\n",
  ) catch {
    e => fail(e.to_string())
  }
  match load_db_with_paths_with_fs("/project/x/url_test.vibe", fs) {
    Ok((db, resolved, paths)) => {
      assert_eq(resolved, "/project/x/url_test.vibe")
      // Verify all transitive dependencies were loaded
      assert_true(contains_path(paths, "/project/x/url/pattern.vibe"))
      assert_true(contains_path(paths, "/project/x/regexp/index.vibe"))
      assert_true(contains_path(paths, "/project/x/regexp/regexp.vibe"))
      // Verify import resolution is clean
      let diags = db.import_diagnostics(resolved)
      if !diags.is_empty() {
        let lines : Array[String] = []
        for diag in diags {
          lines.push(diag.stage + ":" + diag.message)
        }
        fail("unexpected diagnostics: " + lines.join(","))
      }
    }
    Err(err) => fail("cross-root import should succeed: " + err)
  }
}

///|
test "loader resolve_entry_path_with_fs preserves .md extension" {
  let root = "/workspace"
  let fs = MemIoAdapter::new(root)
  let resolved = resolve_entry_path_with_fs(root + "/guide.md", fs)
  assert_eq(resolved, @vibe_fs.normalize_path(root + "/guide.md"))
}

///|
test "loader resolve_entry_path_with_fs preserves .wasm extension" {
  let root = "/workspace"
  let fs = MemIoAdapter::new(root)
  let resolved = resolve_entry_path_with_fs(root + "/mod.wasm", fs)
  assert_eq(resolved, @vibe_fs.normalize_path(root + "/mod.wasm"))
}

///|
test "loader resolve_entry_path_with_fs joins relative path against cwd" {
  let root = "/workspace/proj"
  let fs = MemIoAdapter::new(root)
  let resolved = resolve_entry_path_with_fs("./main.vibe", fs)
  assert_eq(resolved, @vibe_fs.normalize_path(root + "/main.vibe"))
}

///|
test "loader resolve_entry_path_with_fs returns missing extensionless path unchanged" {
  let root = "/workspace"
  let fs = MemIoAdapter::new(root)
  let resolved = resolve_entry_path_with_fs(root + "/does_not_exist", fs)
  assert_eq(resolved, @vibe_fs.normalize_path(root + "/does_not_exist"))
}

///|
test "loader resolve_entry_graph_head_with_fs returns None when cache.json is missing" {
  let root = "/workspace"
  let pkg = root + "/pkg"
  let fs = MemIoAdapter::new(root)
  match fs.create_dir(pkg) {
    Ok(_) => ()
    Err(err) => fail(err)
  }
  match fs.write_string(pkg + "/index.vibe", "let version = \"0.1.0\"\n") {
    Ok(_) => ()
    Err(err) => fail(err)
  }
  @debug.assert_eq(resolve_entry_graph_head_with_fs(pkg, fs), None)
}

///|
test "loader resolve_entry_graph_head_with_fs returns None for malformed cache.json" {
  let root = "/workspace"
  let pkg = root + "/pkg"
  let fs = MemIoAdapter::new(root)
  match fs.create_dir(pkg) {
    Ok(_) => ()
    Err(err) => fail(err)
  }
  match fs.write_string(pkg + "/index.vibe", "let version = \"0.1.0\"\n") {
    Ok(_) => ()
    Err(err) => fail(err)
  }
  match fs.create_dir(pkg + "/.vibe") {
    Ok(_) => ()
    Err(err) => fail(err)
  }
  match fs.write_string(pkg + "/.vibe/cache.json", "not-json{") {
    Ok(_) => ()
    Err(err) => fail(err)
  }
  @debug.assert_eq(resolve_entry_graph_head_with_fs(pkg, fs), None)
}

///|
test "loader resolve_entry_graph_head_with_fs returns None when graph_head is non-string" {
  let root = "/workspace"
  let pkg = root + "/pkg"
  let fs = MemIoAdapter::new(root)
  match fs.create_dir(pkg) {
    Ok(_) => ()
    Err(err) => fail(err)
  }
  match fs.write_string(pkg + "/index.vibe", "let version = \"0.1.0\"\n") {
    Ok(_) => ()
    Err(err) => fail(err)
  }
  match fs.create_dir(pkg + "/.vibe") {
    Ok(_) => ()
    Err(err) => fail(err)
  }
  match fs.write_string(pkg + "/.vibe/cache.json", "{\"graph_head\":42}") {
    Ok(_) => ()
    Err(err) => fail(err)
  }
  @debug.assert_eq(resolve_entry_graph_head_with_fs(pkg, fs), None)
}

///|
test "loader resolve_import_path preserves absolute path" {
  let base = "/workspace/pkg"
  let resolved = resolve_import_path(base, "/other/dep.vibe")
  assert_eq(resolved, @vibe_fs.normalize_path("/other/dep.vibe"))
}

///|
test "loader resolve_import_path preserves .wasm extension" {
  let base = "/workspace/pkg"
  let resolved = resolve_import_path(base, "./plugin.wasm")
  assert_eq(resolved, @vibe_fs.normalize_path("/workspace/pkg/plugin.wasm"))
}

///|
test "loader load_db_with_paths_with_fs ignores unlabeled fenced block in markdown entry" {
  let root = "/workspace/docs"
  let entry = root + "/notes.md"
  let fs = MemIoAdapter::new(root)
  match
    fs.write_string(
      entry, "# Notes\n\n```\nplain prose\n```\n\n```vibe\nlet main = 1\nexport { main }\n```\n",
    ) {
    Ok(_) => ()
    Err(err) => fail(err)
  }
  let loaded = match load_db_with_paths_with_fs(entry, fs) {
    Ok(v) => v
    Err(err) => fail(err)
  }
  let (db, resolved, _) = loaded
  match db.get_source(resolved) {
    Some(source) => {
      assert_true(source.contains("let main = 1"))
      assert_false(source.contains("plain prose"))
    }
    None => fail("expected extracted markdown source")
  }
}

///|
test "loader load_db_with_paths_with_fs joins multiple vibe blocks with blank line" {
  // Verifies the "\n\n" block separator in extract_vibe_from_markdown
  // (lib.mbt:42-47) which previously had no direct assertion.
  let root = "/workspace/docs"
  let entry = root + "/multi.md"
  let fs = MemIoAdapter::new(root)
  match
    fs.write_string(
      entry, "```vibe\nlet a = 1\n```\n\n```vibe\nlet b = 2\n```\n\n```vibe\nlet main = a + b\nexport { main }\n```\n",
    ) {
    Ok(_) => ()
    Err(err) => fail(err)
  }
  let loaded = match load_db_with_paths_with_fs(entry, fs) {
    Ok(v) => v
    Err(err) => fail(err)
  }
  let (db, resolved, _) = loaded
  match db.get_source(resolved) {
    Some(source) => {
      assert_true(source.contains("let a = 1\n\nlet b = 2"))
      assert_true(source.contains("let b = 2\n\nlet main = a + b"))
    }
    None => fail("expected extracted markdown source")
  }
}

///|
test "loader load_db_with_paths_with_fs closes vibe block on trimmed fence" {
  // Verifies that a closing fence with trailing whitespace still terminates
  // the block (extract_vibe_from_markdown uses line.trim(), lib.mbt:21).
  let root = "/workspace/docs"
  let entry = root + "/spacey.md"
  let fs = MemIoAdapter::new(root)
  match
    fs.write_string(
      entry, "```vibe\nlet main = 1\nexport { main }\n```   \n\nTrailing prose that must not leak.\n",
    ) {
    Ok(_) => ()
    Err(err) => fail(err)
  }
  let loaded = match load_db_with_paths_with_fs(entry, fs) {
    Ok(v) => v
    Err(err) => fail(err)
  }
  let (db, resolved, _) = loaded
  match db.get_source(resolved) {
    Some(source) => {
      assert_true(source.contains("let main = 1"))
      assert_false(source.contains("Trailing prose"))
    }
    None => fail("expected extracted markdown source")
  }
}
