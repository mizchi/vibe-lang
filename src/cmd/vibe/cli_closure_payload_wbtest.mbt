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
test "build_closure_payload_with_fs serializes entry and imported sources" {
  let root = "/workspace"
  let fs = MemIoAdapter::new(root)
  let main_path = root + "/main.vibe"
  let lib_path = root + "/lib.vibe"
  let main_source = "import ./lib.vibe { helper }\n" +
    "let answer = () -> Int { helper() }\n"
  let lib_source = "export let helper = () -> Int { 40 + 2 }\nexport { helper }\n"
  ignore(fs.write_string(main_path, main_source))
  ignore(fs.write_string(lib_path, lib_source))
  let payload = match build_closure_payload_with_fs(main_path, fs) {
    Ok(v) => v
    Err(err) => fail(err)
  }
  let parts = split_payload_parts(payload)
  @debug.assert_eq(parts, [
    "/workspace/main.vibe", main_source, "/workspace/lib.vibe", lib_source,
  ])
}

///|
test "emit_closure_payload_file writes payload to output" {
  let root = "/workspace"
  let fs = MemIoAdapter::new(root)
  let main_path = root + "/main.vibe"
  let out_path = root + "/payload.txt"
  ignore(fs.write_string(main_path, "let answer = () -> Int { 42 }\n"))
  match emit_closure_payload_file(main_path, out_path, fs) {
    Ok(_) => ()
    Err(err) => fail(err)
  }
  let payload = match fs.read_string(out_path) {
    Ok(v) => v
    Err(err) => fail(err)
  }
  let parts = split_payload_parts(payload)
  @debug.assert_eq(parts, [
    "/workspace/main.vibe", "let answer = () -> Int { 42 }\n",
  ])
}

///|
test "compile_closure_payload_file compiles import closure payload" {
  let root = "/workspace"
  let fs = MemIoAdapter::new(root)
  let main_path = root + "/main.vibe"
  let lib_path = root + "/lib.vibe"
  let payload_path = root + "/payload.txt"
  let out_path = root + "/out.wasm"
  ignore(
    fs.write_string(
      main_path, "import ./lib.vibe { helper }\nlet answer = () -> Int { helper() }\n",
    ),
  )
  ignore(
    fs.write_string(
      lib_path, "export let helper = () -> Int { 40 + 2 }\nexport { helper }\n",
    ),
  )
  match emit_closure_payload_file(main_path, payload_path, fs) {
    Ok(_) => ()
    Err(err) => fail(err)
  }
  match compile_closure_payload_file(payload_path, out_path, "mvp", fs) {
    Ok(_) => ()
    Err(err) => fail(err)
  }
  let wasm = match fs.read_bytes(out_path) {
    Ok(v) => v
    Err(err) => fail(err)
  }
  assert_true(wasm.length() > 0)
}

///|
fn split_payload_parts(payload : String) -> Array[String] {
  let parts : Array[String] = []
  for part in payload.split("\u{0}") {
    parts.push(part.to_owned())
  }
  parts
}
