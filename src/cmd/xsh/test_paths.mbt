///|
pub fn resolve_test_entry_paths(args : Array[String]) -> Array[String] {
  let out : Array[String] = []
  let seen : Map[String, Bool] = {}
  for path in args {
    let is_file = @os_fs.is_file(path) catch { _ => false }
    if is_file {
      push_unique_path(out, seen, path)
      continue
    }
    let is_dir = @os_fs.is_dir(path) catch { _ => false }
    if is_dir {
      collect_test_entry_paths_from_dir(path, out, seen)
      continue
    }
    abort("test: path not found: " + path)
  }
  out
}

///|
pub fn resolve_bench_entry_paths(args : Array[String]) -> Array[String] {
  let out : Array[String] = []
  let seen : Map[String, Bool] = {}
  for path in args {
    let is_file = @os_fs.is_file(path) catch { _ => false }
    if is_file {
      push_unique_path(out, seen, path)
      continue
    }
    let is_dir = @os_fs.is_dir(path) catch { _ => false }
    if is_dir {
      collect_bench_entry_paths_from_dir(path, out, seen)
      continue
    }
    abort("bench: path not found: " + path)
  }
  out
}

///|
fn collect_test_entry_paths_from_dir(
  dir : String,
  out : Array[String],
  seen : Map[String, Bool],
) -> Unit {
  let entries = @os_fs.read_dir(dir) catch {
    e => abort("test: failed to read dir " + dir + ": " + e.to_string())
  }
  for name in entries {
    if name == "." || name == ".." {
      continue
    }
    let path = if name.has_prefix(dir + "/") { name } else { dir + "/" + name }
    let is_file = @os_fs.is_file(path) catch { _ => false }
    if is_file {
      if path.has_suffix(".vibe") {
        push_unique_path(out, seen, path)
      }
    }
  }
}

///|
fn collect_bench_entry_paths_from_dir(
  dir : String,
  out : Array[String],
  seen : Map[String, Bool],
) -> Unit {
  let entries = @os_fs.read_dir(dir) catch {
    e => abort("bench: failed to read dir " + dir + ": " + e.to_string())
  }
  for name in entries {
    if name == "." || name == ".." {
      continue
    }
    let path = if name.has_prefix(dir + "/") { name } else { dir + "/" + name }
    let is_file = @os_fs.is_file(path) catch { _ => false }
    if is_file {
      if path.has_suffix("_bench.vibe") {
        push_unique_path(out, seen, path)
      }
    }
  }
}

///|
fn push_unique_path(
  out : Array[String],
  seen : Map[String, Bool],
  path : String,
) -> Unit {
  match seen.get(path) {
    Some(_) => ()
    None => {
      seen[path] = true
      out.push(path)
    }
  }
}
