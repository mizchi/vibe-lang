///|
fn resolve_eval_path(path : String) -> String {
  if path.has_prefix("/") {
    @vibe_fs.normalize_path(path)
  } else {
    @vibe_fs.normalize_path(@io.current_dir_or_root() + "/" + path)
  }
}

///|
pub fn resolve_vibe_lib_dir(base_dir : String) -> String {
  let lib_root = match @sys.get_env_var("VIBE_LIB_ROOT") {
    Some(path) => Some(path)
    None => @sys.get_env_var("VIBE_LIB_DIR")
  }
  match lib_root {
    Some(path) =>
      if path.has_prefix("/") {
        @vibe_fs.normalize_path(path)
      } else {
        @vibe_fs.normalize_path(base_dir + "/" + path)
      }
    None =>
      match @sys.get_env_var("HOME") {
        Some(home) => @vibe_fs.normalize_path(home + "/.vibe/lib")
        None => @vibe_fs.normalize_path(base_dir + "/.vibe/lib")
      }
  }
}

///|
fn ensure_dir_recursive_for_eval(path : String) -> Result[Unit, String] {
  let normalized = @vibe_fs.normalize_path(path)
  if normalized.length() == 0 || normalized == "." || normalized == "/" {
    return Ok(())
  }
  if @os_fs.path_exists(normalized) {
    let is_dir = @os_fs.is_dir(normalized) catch { _ => false }
    if is_dir {
      return Ok(())
    }
    return Err("path exists and is not directory: " + normalized)
  }
  let parent = @vibe_fs.parent_path(normalized)
  if parent != normalized && parent.length() > 0 {
    match ensure_dir_recursive_for_eval(parent) {
      Ok(_) => ()
      Err(err) => return Err(err)
    }
  }
  match @io.create_dir(normalized) {
    Ok(_) => Ok(())
    Err(err) =>
      if @os_fs.path_exists(normalized) {
        let is_dir = @os_fs.is_dir(normalized) catch { _ => false }
        if is_dir {
          Ok(())
        } else {
          Err("mkdir failed: " + normalized + " (" + err + ")")
        }
      } else {
        Err("mkdir failed: " + normalized + " (" + err + ")")
      }
  }
}

///|
pub fn ensure_parent_dir_for_file(
  path : String,
  context : String,
) -> Result[Unit, String] {
  let resolved_path = resolve_eval_path(path)
  let parent = @vibe_fs.parent_path(resolved_path)
  if parent == "." || parent.length() == 0 {
    return Ok(())
  }
  match ensure_dir_recursive_for_eval(parent) {
    Ok(_) => Ok(())
    Err(err) => Err(context + ": " + err)
  }
}
