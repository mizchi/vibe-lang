///| FileSystem backend trait

///|

///| This trait abstracts the underlying storage mechanism.

///| Implementations:

///| - MemFs: In-memory filesystem (default)

///| - Future: IndexedDB, host fs adapter, etc.

///|
/// Minimal filesystem operations required by vposix
pub(open) trait FileSystemBackend {
  // Read operations
  fn read_file(Self, String) -> Bytes raise FsError
  fn read_string(Self, String) -> String raise FsError
  fn exists(Self, String) -> Bool
  fn is_file(Self, String) -> Bool
  fn is_dir(Self, String) -> Bool
  fn stat(Self, String) -> FileStat raise FsError
  fn readdir(Self, String) -> Array[DirEntry] raise FsError

  // Write operations
  fn write_file(Self, String, Bytes) -> Unit raise FsError
  fn write_string(Self, String, String) -> Unit raise FsError
  fn mkdir(Self, String) -> Unit raise FsError
  fn mkdir_p(Self, String) -> Unit raise FsError
  fn remove(Self, String) -> Unit raise FsError
  fn rmdir(Self, String) -> Unit raise FsError
  fn rename(Self, String, String) -> Unit raise FsError
  fn copy_file(Self, String, String) -> Unit raise FsError
  fn rm_rf(Self, String) -> Unit raise FsError
}

///|
/// Path utilities
pub fn normalize_path(path : String) -> String {
  // Simple normalization: remove trailing slash, handle . and ..
  let parts : Array[String] = []
  for part in path.split("/") {
    let s = part.to_owned()
    match s {
      "" | "." => continue
      ".." => if parts.length() > 0 { let _ = parts.pop() }
      _ => parts.push(s)
    }
  }
  if parts.is_empty() {
    "/"
  } else {
    "/" +
    parts
    .iter()
    .intersperse("/")
    .map(fn(s) { s.to_string() })
    .fold(init="", fn(acc, s) { acc + s })
  }
}

///|
/// Get parent directory
pub fn parent_path(path : String) -> String {
  let normalized = normalize_path(path)
  if normalized == "/" {
    return "/"
  }
  // Find last '/' by searching from end
  let mut last_slash = -1
  for i = normalized.length() - 1; i >= 0; i = i - 1 {
    if normalized[i] == '/' {
      last_slash = i
      break
    }
  }
  if last_slash == 0 {
    "/"
  } else if last_slash > 0 {
    let buf = StringBuilder::new()
    for i in 0..<last_slash {
      buf.write_char(normalized[i].to_int().unsafe_to_char())
    }
    buf.to_string()
  } else {
    "/"
  }
}

///|
/// Get basename
pub fn basename(path : String) -> String {
  let normalized = normalize_path(path)
  if normalized == "/" {
    return ""
  }
  // Find last '/'
  let mut last_slash = -1
  for i = normalized.length() - 1; i >= 0; i = i - 1 {
    if normalized[i] == '/' {
      last_slash = i
      break
    }
  }
  if last_slash >= 0 {
    let buf = StringBuilder::new()
    for i = last_slash + 1; i < normalized.length(); i = i + 1 {
      buf.write_char(normalized[i].to_int().unsafe_to_char())
    }
    buf.to_string()
  } else {
    normalized
  }
}
