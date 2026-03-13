///|
let closure_payload_separator = "\u{0}"

///|
struct ClosurePayloadSource {
  path : String
  source : String
}

///|
struct ClosurePayloadFsAdapter {
  fs : @vibe_fs.MemFs
  cwd : String
}

///|
fn ClosurePayloadFsAdapter::new(cwd : String) -> ClosurePayloadFsAdapter {
  let fs = @vibe_fs.MemFs::new()
  fs.mkdir_p(cwd) catch {
    _ => ()
  }
  { fs, cwd }
}

///|
pub impl @io.FileSystemAdapter for ClosurePayloadFsAdapter with current_dir_or_root(
  self,
) {
  self.cwd
}

///|
pub impl @io.FileSystemAdapter for ClosurePayloadFsAdapter with path_exists(
  self,
  path,
) {
  self.fs.exists(path)
}

///|
pub impl @io.FileSystemAdapter for ClosurePayloadFsAdapter with create_dir(
  self,
  path,
) {
  self.fs.mkdir_p(path) catch {
    e => return Err(e.to_string())
  }
  Ok(())
}

///|
pub impl @io.FileSystemAdapter for ClosurePayloadFsAdapter with read_dir(
  self,
  path,
) {
  let entries = self.fs.readdir(path) catch { e => return Err(e.to_string()) }
  let out : Array[String] = []
  for entry in entries {
    out.push(entry.name)
  }
  Ok(out)
}

///|
pub impl @io.FileSystemAdapter for ClosurePayloadFsAdapter with read_string(
  self,
  path,
) {
  let content = self.fs.read_string(path) catch {
    e => return Err(e.to_string())
  }
  Ok(content)
}

///|
pub impl @io.FileSystemAdapter for ClosurePayloadFsAdapter with read_bytes(
  self,
  path,
) {
  let content = self.fs.read_file(path) catch { e => return Err(e.to_string()) }
  Ok(content)
}

///|
pub impl @io.FileSystemAdapter for ClosurePayloadFsAdapter with write_string(
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
pub impl @io.FileSystemAdapter for ClosurePayloadFsAdapter with write_bytes(
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
fn append_closure_payload_part(
  buf : StringBuilder,
  first : Bool,
  part : String,
) -> Unit {
  if not(first) {
    buf.write_string(closure_payload_separator)
  }
  buf.write_string(part)
}

///|
pub fn build_closure_payload_with_fs(
  input_path : String,
  fs : &@io.FileSystemAdapter,
) -> Result[String, String] {
  let (_, entry_path, paths) = match
    @loader.load_db_with_paths_with_fs(input_path, fs) {
    Ok(v) => v
    Err(err) => return Err("load failed: " + err)
  }
  let main_source = match @io.read_string_with(fs, entry_path) {
    Ok(v) => v
    Err(err) => return Err("read failed: " + err)
  }
  let buf = StringBuilder::new()
  append_closure_payload_part(buf, true, entry_path)
  append_closure_payload_part(buf, false, main_source)
  for path in paths {
    if path == entry_path {
      continue
    }
    let source = match @io.read_string_with(fs, path) {
      Ok(v) => v
      Err(err) => return Err("read failed: " + err)
    }
    append_closure_payload_part(buf, false, path)
    append_closure_payload_part(buf, false, source)
  }
  Ok(buf.to_string())
}

///|
fn split_closure_payload_parts(payload : String) -> Array[String] {
  let parts : Array[String] = []
  for part in payload.split(closure_payload_separator) {
    parts.push(part.to_string())
  }
  parts
}

///|
fn decode_closure_payload(
  payload : String,
) -> Result[Array[ClosurePayloadSource], String] {
  let parts = split_closure_payload_parts(payload)
  if parts.length() == 0 {
    return Err("payload is empty")
  }
  if parts.length() % 2 != 0 {
    return Err("payload has odd part count")
  }
  let out : Array[ClosurePayloadSource] = []
  let mut i = 0
  while i < parts.length() {
    out.push({ path: parts[i], source: parts[i + 1] })
    i = i + 2
  }
  Ok(out)
}

///|
fn closure_payload_dirname(path : String) -> String {
  let mut last_slash = -1
  let mut i = 0
  for _, ch in path {
    if ch == '/' {
      last_slash = i
    }
    i = i + 1
  }
  if last_slash <= 0 {
    "/"
  } else {
    path[:last_slash].to_string() catch {
      _ => "/"
    }
  }
}

///|
pub fn emit_closure_payload_file(
  input_path : String,
  output_path : String,
  fs : &@io.FileSystemAdapter,
) -> Result[Unit, String] {
  let payload = match build_closure_payload_with_fs(input_path, fs) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  match @io.write_string_with(fs, output_path, payload) {
    Ok(_) => Ok(())
    Err(err) => Err("write failed: " + err)
  }
}

///|
pub fn compile_closure_payload_file(
  payload_path : String,
  output_path : String,
  mode : String,
  fs : &@io.FileSystemAdapter,
) -> Result[Unit, String] {
  let payload = match @io.read_string_with(fs, payload_path) {
    Ok(v) => v
    Err(err) => return Err("read failed: " + err)
  }
  let sources = match decode_closure_payload(payload) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let no_dce = match mode {
    "mvp" => false
    "no-dce" => true
    _ => return Err("unsupported mode: " + mode)
  }
  let entry_path = sources[0].path
  let cwd = closure_payload_dirname(entry_path)
  let mem_fs = ClosurePayloadFsAdapter::new(cwd)
  for item in sources {
    let dir = closure_payload_dirname(item.path)
    ignore(mem_fs.create_dir(dir))
    match mem_fs.write_string(item.path, item.source) {
      Ok(_) => ()
      Err(err) => return Err("write payload source failed: " + err)
    }
  }
  let (db, entry) = match @loader.load_db_with_fs(entry_path, mem_fs) {
    Ok(v) => v
    Err(err) => return Err("load failed: " + err)
  }
  let wasm = @runtime_compile.compile_module_wasm_with_opt_level(
    db,
    entry,
    no_dce~,
    opt_level=None,
  ) catch {
    err => return Err("compile failed: " + err.user_message())
  }
  match @io.write_bytes_with(fs, output_path, wasm) {
    Ok(_) => Ok(())
    Err(err) => Err("write failed: " + err)
  }
}
