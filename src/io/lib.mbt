///|
pub fn current_dir_or_root() -> String {
  match @env.current_dir() {
    Some(dir) => dir
    None => "/"
  }
}

///|
pub fn path_exists(path : String) -> Bool {
  @os_fs.path_exists(path)
}

///|
pub fn create_dir(path : String) -> Result[Unit, String] {
  @os_fs.create_dir(path) catch {
    e => return Err(e.to_string())
  }
  Ok(())
}

///|
pub fn read_dir(path : String) -> Result[Array[String], String] {
  let entries = @os_fs.read_dir(path) catch { e => return Err(e.to_string()) }
  Ok(entries)
}

///|
pub fn read_string(path : String) -> Result[String, String] {
  let content = @os_fs.read_file_to_string(path) catch {
    e => return Err(e.to_string())
  }
  Ok(content)
}

///|
pub fn read_bytes(path : String) -> Result[Bytes, String] {
  let bytes = @os_fs.read_file_to_bytes(path) catch {
    e => return Err(e.to_string())
  }
  Ok(bytes)
}

///|
pub fn write_string(path : String, content : String) -> Result[Unit, String] {
  @os_fs.write_string_to_file(path, content) catch {
    e => return Err(e.to_string())
  }
  Ok(())
}

///|
pub fn write_bytes(path : String, content : Bytes) -> Result[Unit, String] {
  @os_fs.write_bytes_to_file(path, content) catch {
    e => return Err(e.to_string())
  }
  Ok(())
}

///|
fn split_output_lines(text : String) -> Array[String] {
  let out : Array[String] = []
  for part in text.split("\n") {
    out.push(part.to_string())
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
