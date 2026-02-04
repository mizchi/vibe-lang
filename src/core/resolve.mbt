///| Import alias and symbol resolution helpers

///|
/// Derive alias name from import path (strip dirs and .xsh suffix).
pub fn import_alias_name(path : String) -> String {
  let chars : Array[Char] = []
  for c in path {
    chars.push(c)
  }
  let mut last_slash = -1
  for i in 0..<chars.length() {
    if chars[i] == '/' {
      last_slash = i
    }
  }
  let buf = StringBuilder::new()
  for i in (last_slash + 1)..<chars.length() {
    buf.write_char(chars[i])
  }
  let base = buf.to_string()
  if base.has_suffix(".xsh") && base.length() > 4 {
    (try! base[0:base.length() - 4]).to_string()
  } else {
    base
  }
}

///| Resolve module-qualified symbol name using aliases.

///|
/// Example: foo.bar -> ko-doha/xsh/<hash>/bar
pub fn resolve_qualified(name : String, aliases : Map[String, Ref]) -> String {
  let chars : Array[Char] = []
  for c in name {
    chars.push(c)
  }
  let mut dot = -1
  for i in 0..<chars.length() {
    if chars[i] == '.' {
      dot = i
      break
    }
  }
  if dot == -1 {
    return name
  }
  let left = StringBuilder::new()
  for i in 0..<dot {
    left.write_char(chars[i])
  }
  let right = StringBuilder::new()
  for i in (dot + 1)..<chars.length() {
    right.write_char(chars[i])
  }
  let prefix = left.to_string()
  match aliases.get(prefix) {
    None => name
    Some(r) => {
      let module_ref = match r.hash_prefix {
        Some(h) => r.name + "#" + h
        None => r.name
      }
      module_ref + "/" + right.to_string()
    }
  }
}
