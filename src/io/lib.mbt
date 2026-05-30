///|
/// Filesystem adapter trait for compiler/runtime boundary.
pub(open) trait FileSystemAdapter {
  fn current_dir_or_root(Self) -> String
  fn path_exists(Self, String) -> Bool
  fn create_dir(Self, String) -> Result[Unit, String]
  fn read_dir(Self, String) -> Result[Array[String], String]
  fn read_string(Self, String) -> Result[String, String]
  fn read_bytes(Self, String) -> Result[Bytes, String]
  fn write_string(Self, String, String) -> Result[Unit, String]
  fn write_bytes(Self, String, Bytes) -> Result[Unit, String]
}

///|
pub struct OsFsAdapter {
  priv _dummy : Int
}

///|
pub fn OsFsAdapter::new() -> OsFsAdapter {
  { _dummy: 0 }
}

///|
pub impl FileSystemAdapter for OsFsAdapter with fn current_dir_or_root(_self) {
  match @env.current_dir() {
    Some(dir) => dir
    None => "/"
  }
}

///|
pub impl FileSystemAdapter for OsFsAdapter with fn path_exists(_self, path) {
  @os_fs.path_exists(path)
}

///|
pub impl FileSystemAdapter for OsFsAdapter with fn create_dir(_self, path) {
  @os_fs.create_dir(path) catch {
    e => return Err(e.to_string())
  }
  Ok(())
}

///|
pub impl FileSystemAdapter for OsFsAdapter with fn read_dir(_self, path) {
  let entries = @os_fs.read_dir(path) catch { e => return Err(e.to_string()) }
  Ok(entries)
}

///|
pub impl FileSystemAdapter for OsFsAdapter with fn read_string(_self, path) {
  let content = @os_fs.read_file_to_string(path) catch {
    e => return Err(e.to_string())
  }
  Ok(content)
}

///|
pub impl FileSystemAdapter for OsFsAdapter with fn read_bytes(_self, path) {
  let content = @os_fs.read_file_to_bytes(path) catch {
    e => return Err(e.to_string())
  }
  Ok(content)
}

///|
pub impl FileSystemAdapter for OsFsAdapter with fn write_string(
  _self,
  path,
  content,
) {
  @os_fs.write_string_to_file(path, content) catch {
    e => return Err(e.to_string())
  }
  Ok(())
}

///|
pub impl FileSystemAdapter for OsFsAdapter with fn write_bytes(
  _self,
  path,
  content,
) {
  @os_fs.write_bytes_to_file(path, content) catch {
    e => return Err(e.to_string())
  }
  Ok(())
}

///|
pub fn current_dir_or_root_with(fs : &FileSystemAdapter) -> String {
  fs.current_dir_or_root()
}

///|
pub fn path_exists_with(fs : &FileSystemAdapter, path : String) -> Bool {
  fs.path_exists(path)
}

///|
pub fn create_dir_with(
  fs : &FileSystemAdapter,
  path : String,
) -> Result[Unit, String] {
  fs.create_dir(path)
}

///|
pub fn read_dir_with(
  fs : &FileSystemAdapter,
  path : String,
) -> Result[Array[String], String] {
  fs.read_dir(path)
}

///|
pub fn read_string_with(
  fs : &FileSystemAdapter,
  path : String,
) -> Result[String, String] {
  fs.read_string(path)
}

///|
pub fn read_bytes_with(
  fs : &FileSystemAdapter,
  path : String,
) -> Result[Bytes, String] {
  fs.read_bytes(path)
}

///|
pub fn write_string_with(
  fs : &FileSystemAdapter,
  path : String,
  content : String,
) -> Result[Unit, String] {
  fs.write_string(path, content)
}

///|
pub fn write_bytes_with(
  fs : &FileSystemAdapter,
  path : String,
  content : Bytes,
) -> Result[Unit, String] {
  fs.write_bytes(path, content)
}

///|
pub fn default_fs_adapter() -> OsFsAdapter {
  OsFsAdapter::new()
}

///|
pub fn current_dir_or_root() -> String {
  current_dir_or_root_with(default_fs_adapter())
}

///|
pub fn path_exists(path : String) -> Bool {
  path_exists_with(default_fs_adapter(), path)
}

///|
pub fn create_dir(path : String) -> Result[Unit, String] {
  create_dir_with(default_fs_adapter(), path)
}

///|
pub fn read_dir(path : String) -> Result[Array[String], String] {
  read_dir_with(default_fs_adapter(), path)
}

///|
pub fn read_string(path : String) -> Result[String, String] {
  read_string_with(default_fs_adapter(), path)
}

///|
pub fn read_bytes(path : String) -> Result[Bytes, String] {
  read_bytes_with(default_fs_adapter(), path)
}

///|
pub fn write_string(path : String, content : String) -> Result[Unit, String] {
  write_string_with(default_fs_adapter(), path, content)
}

///|
pub fn write_bytes(path : String, content : Bytes) -> Result[Unit, String] {
  write_bytes_with(default_fs_adapter(), path, content)
}

///|
pub fn is_directory(path : String) -> Bool {
  @os_fs.is_dir(path) catch {
    _ => false
  }
}

///|
pub fn is_file(path : String) -> Bool {
  @os_fs.is_file(path) catch {
    _ => false
  }
}

///|
pub fn remove_file(path : String) -> Result[Unit, String] {
  @os_fs.remove_file(path) catch {
    e => return Err(e.to_string())
  }
  Ok(())
}

///|
pub fn remove_dir(path : String) -> Result[Unit, String] {
  @os_fs.remove_dir(path) catch {
    e => return Err(e.to_string())
  }
  Ok(())
}

///|
pub fn get_env_var(name : String) -> String? {
  @sys.get_env_var(name)
}

///|
fn split_output_lines(text : String) -> Array[String] {
  let out : Array[String] = []
  for part in text.split("\n") {
    out.push(part.to_owned())
  }
  if out.length() > 0 && out[out.length() - 1] == "" {
    ignore(out.pop())
  }
  out
}

///|
pub fn shell_ls_lines(dir : String) -> Result[Array[String], String] {
  read_dir(dir)
}

///|
pub fn shell_cat_lines(path : String) -> Result[Array[String], String] {
  match read_string(path) {
    Ok(content) => Ok(split_output_lines(content))
    Err(err) => Err(err)
  }
}

///|
pub fn sleep_ms(ms : Int64) -> Unit {
  @backend.sleep_ms(ms)
}
