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
  read_file(Self, String) -> Bytes raise FsError
  read_string(Self, String) -> String raise FsError
  exists(Self, String) -> Bool
  is_file(Self, String) -> Bool
  is_dir(Self, String) -> Bool
  stat(Self, String) -> FileStat raise FsError
  readdir(Self, String) -> Array[DirEntry] raise FsError

  // Write operations
  write_file(Self, String, Bytes) -> Unit raise FsError
  write_string(Self, String, String) -> Unit raise FsError
  mkdir(Self, String) -> Unit raise FsError
  mkdir_p(Self, String) -> Unit raise FsError
  remove(Self, String) -> Unit raise FsError
  rmdir(Self, String) -> Unit raise FsError
  rename(Self, String, String) -> Unit raise FsError
  copy_file(Self, String, String) -> Unit raise FsError
  rm_rf(Self, String) -> Unit raise FsError
}

///|
/// Path utilities
pub fn normalize_path(path : String) -> String {
  // Simple normalization: remove trailing slash, handle . and ..
  let parts : Array[String] = []
  for part in path.split("/") {
    let s = part.to_string()
    match s {
      "" | "." => continue
      ".." =>
        if parts.length() > 0 {
          let _ = parts.pop()

        }
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
