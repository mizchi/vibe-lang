///| Module store for content-addressed AST storage

///|

///| Uses git-style object format: .vibe/objects/ab/cdef1234...

///|
pub(all) suberror StoreError {
  StoreError(String)
} derive(Show)

///|
/// Object path from hash (git-style: first 2 chars as directory)
pub fn object_path_from_hash(base_dir : String, hash : String) -> String {
  let dir = hash.unsafe_substring(start=0, end=2)
  let file = hash.unsafe_substring(start=2, end=hash.length())
  base_dir + "/objects/" + dir + "/" + file
}

///|
/// Get directory path for object (for mkdir)
pub fn object_dir_from_hash(base_dir : String, hash : String) -> String {
  let dir = hash.unsafe_substring(start=0, end=2)
  base_dir + "/objects/" + dir
}

///|
/// Parse object path back to hash
pub fn hash_from_object_path(path : String) -> String? {
  // Find last two path components
  let parts : Array[String] = []
  for p in path.split("/") {
    parts.push(p.to_string())
  }
  if parts.length() < 2 {
    return None
  }
  let file = parts[parts.length() - 1]
  let dir = parts[parts.length() - 2]
  if dir.length() != 2 {
    return None
  }
  Some(dir + file)
}

///|
/// Path mapping entry
pub(all) struct PathMapping {
  path : String
  hash : String
} derive(Show, Eq)

///|
/// Serialize path mappings to JSON
pub fn serialize_path_mappings(mappings : Array[PathMapping]) -> String {
  let buf = StringBuilder::new()
  buf.write_char('{')
  for i, m in mappings {
    if i > 0 {
      buf.write_char(',')
    }
    buf.write_char('"')
    write_json_escaped_string(m.path, buf)
    buf.write_string("\":\"")
    buf.write_string(m.hash)
    buf.write_char('"')
  }
  buf.write_char('}')
  buf.to_string()
}

///|
fn write_json_escaped_string(s : String, buf : StringBuilder) -> Unit {
  for c in s {
    match c {
      '"' => buf.write_string("\\\"")
      '\\' => buf.write_string("\\\\")
      '\n' => buf.write_string("\\n")
      '\r' => buf.write_string("\\r")
      '\t' => buf.write_string("\\t")
      _ => buf.write_char(c)
    }
  }
}

///|
/// Parse path mappings from JSON
pub fn parse_path_mappings(
  json : String,
) -> Array[PathMapping] raise StoreError {
  let mappings : Array[PathMapping] = []
  let chars = json.to_array()
  let len = chars.length()
  if len == 0 {
    return mappings
  }
  let mut pos = 0

  // Skip whitespace
  while pos < len && is_ws(chars[pos]) {
    pos += 1
  }

  // Expect '{'
  if pos >= len || chars[pos] != '{' {
    raise StoreError("Expected '{'")
  }
  pos += 1
  while pos < len {
    // Skip whitespace
    while pos < len && is_ws(chars[pos]) {
      pos += 1
    }

    // Check for end
    if pos >= len {
      raise StoreError("Unexpected end of input")
    }
    if chars[pos] == '}' {
      break
    }

    // Skip comma if not first
    if mappings.length() > 0 {
      if chars[pos] != ',' {
        raise StoreError("Expected ','")
      }
      pos += 1
      while pos < len && is_ws(chars[pos]) {
        pos += 1
      }
    }

    // Parse key string
    if pos >= len || chars[pos] != '"' {
      raise StoreError("Expected '\"' for key")
    }
    let (path, new_pos) = parse_json_str(chars, pos) catch { e => raise e }
    pos = new_pos

    // Skip whitespace and colon
    while pos < len && is_ws(chars[pos]) {
      pos += 1
    }
    if pos >= len || chars[pos] != ':' {
      raise StoreError("Expected ':'")
    }
    pos += 1
    while pos < len && is_ws(chars[pos]) {
      pos += 1
    }

    // Parse value string
    if pos >= len || chars[pos] != '"' {
      raise StoreError("Expected '\"' for value")
    }
    let (hash, new_pos2) = parse_json_str(chars, pos) catch { e => raise e }
    pos = new_pos2
    mappings.push(PathMapping::{ path, hash })
  }
  mappings
}

///|
fn is_ws(c : Char) -> Bool {
  c == ' ' || c == '\n' || c == '\r' || c == '\t'
}

///|
fn parse_json_str(
  chars : Array[Char],
  start : Int,
) -> (String, Int) raise StoreError {
  let len = chars.length()
  if start >= len || chars[start] != '"' {
    raise StoreError("Expected '\"'")
  }
  let buf = StringBuilder::new()
  let mut pos = start + 1
  while pos < len {
    let c = chars[pos]
    if c == '"' {
      return (buf.to_string(), pos + 1)
    }
    if c == '\\' {
      pos += 1
      if pos >= len {
        raise StoreError("Unexpected end after escape")
      }
      match chars[pos] {
        '"' => buf.write_char('"')
        '\\' => buf.write_char('\\')
        'n' => buf.write_char('\n')
        'r' => buf.write_char('\r')
        't' => buf.write_char('\t')
        _ => buf.write_char(chars[pos])
      }
    } else {
      buf.write_char(c)
    }
    pos += 1
  }
  raise StoreError("Unterminated string")
}

///|
/// Resolve import paths to hashes
/// Returns array of (original_path, hash) pairs
pub fn resolve_import_hashes(
  ast : Module,
  path_to_hash : (String) -> String?,
) -> Array[(String, String)] {
  let results : Array[(String, String)] = []
  for stmt in ast.stmts {
    match stmt {
      Stmt::Import(source~, ..) | Stmt::ReExport(source~, ..) =>
        match source {
          ModuleRef::Path(path~) =>
            match path_to_hash(path) {
              Some(hash) => results.push((path, hash))
              None => ()
            }
          ModuleRef::Hash(_)
          | ModuleRef::Version(_)
          | ModuleRef::Symbol(_)
          | ModuleRef::Alias(_)
          | ModuleRef::PinnedPath(..) => ()
        }
      _ => ()
    }
  }
  results
}

///|
/// Convert path-based imports to hash-based in an AST
pub fn convert_imports_to_hash(
  ast : Module,
  path_to_hash : (String) -> String?,
) -> Module {
  let new_stmts : Array[Stmt] = []
  for stmt in ast.stmts {
    match stmt {
      Stmt::Import(spec~, source~, span~) =>
        match source {
          ModuleRef::Path(path~) =>
            match path_to_hash(path) {
              Some(hash) =>
                new_stmts.push(
                  Stmt::Import(spec~, source=ModuleRef::Hash(hash~), span~),
                )
              None => new_stmts.push(stmt)
            }
          ModuleRef::PinnedPath(path=_, hash~) =>
            new_stmts.push(
              Stmt::Import(spec~, source=ModuleRef::Hash(hash~), span~),
            )
          ModuleRef::Hash(_)
          | ModuleRef::Version(_)
          | ModuleRef::Symbol(_)
          | ModuleRef::Alias(_) => new_stmts.push(stmt)
        }
      Stmt::ReExport(spec~, source~, span~) =>
        match source {
          ModuleRef::Path(path~) =>
            match path_to_hash(path) {
              Some(hash) =>
                new_stmts.push(
                  Stmt::ReExport(spec~, source=ModuleRef::Hash(hash~), span~),
                )
              None => new_stmts.push(stmt)
            }
          ModuleRef::PinnedPath(path=_, hash~) =>
            new_stmts.push(
              Stmt::ReExport(spec~, source=ModuleRef::Hash(hash~), span~),
            )
          ModuleRef::Hash(_)
          | ModuleRef::Version(_)
          | ModuleRef::Symbol(_)
          | ModuleRef::Alias(_) => new_stmts.push(stmt)
        }
      _ => new_stmts.push(stmt)
    }
  }
  Module::{ stmts: new_stmts }
}

///|
/// Extract exported bindings from a module
/// Returns a map from exported name to statement
pub fn extract_exports(ast : Module) -> Map[String, Stmt] {
  let exports : Map[String, Stmt] = {}
  let defined : Map[String, Stmt] = {}

  // First pass: collect all definitions
  for stmt in ast.stmts {
    match stmt {
      Stmt::Let(name~, ..) | Stmt::LetMut(name~, ..) => defined.set(name, stmt)
      Stmt::EnumDef(name~, ..) => defined.set(name, stmt)
      Stmt::TypeAlias(name~, ..) => defined.set(name, stmt)
      Stmt::TraitDef(name~, exported~, ..) =>
        if exported {
          defined.set(name, stmt)
          exports.set(name, stmt)
        } else {
          defined.set(name, stmt)
        }
      Stmt::ExportLet(name~, ..) => {
        defined.set(name, stmt)
        exports.set(name, stmt)
      }
      Stmt::ExportEnumDef(name~, ..) => {
        defined.set(name, stmt)
        exports.set(name, stmt)
      }
      Stmt::ExportTypeAlias(name~, ..) => {
        defined.set(name, stmt)
        exports.set(name, stmt)
      }
      Stmt::StructDef(name~, ..) => defined.set(name, stmt)
      Stmt::ExportStructDef(name~, ..) => {
        defined.set(name, stmt)
        exports.set(name, stmt)
      }
      Stmt::ExportEffectDef(name~, ..) => {
        defined.set(name, stmt)
        exports.set(name, stmt)
      }
      Stmt::EffectDef(name~, ..) => defined.set(name, stmt)
      Stmt::ReExport(spec~, ..) =>
        for item in spec.items {
          exports.set(import_item_local_name(item), stmt)
        }
      _ => ()
    }
  }

  // Second pass: handle export statements
  for stmt in ast.stmts {
    match stmt {
      Stmt::Export(names~, ..) =>
        for name in names {
          match defined.get(name) {
            Some(s) => exports.set(name, s)
            None => ()
          }
        }
      _ => ()
    }
  }
  exports
}

///|
/// Extract a single exported value expression by name
pub fn get_exported_expr(ast : Module, name : String) -> Expr? {
  let exports = extract_exports(ast)
  match exports.get(name) {
    Some(Stmt::Let(expr~, ..)) => Some(expr)
    Some(Stmt::ExportLet(expr~, ..)) => Some(expr)
    _ => None
  }
}
