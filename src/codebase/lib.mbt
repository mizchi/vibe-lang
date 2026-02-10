///|
/// Nix-like codebase object/lock management.
pub struct Codebase {
  root : String
} derive(Show, Eq)

///|
suberror CodebaseError {
  Io(String)
} derive(Show, Eq)

///|
pub fn Codebase::new(root : String) -> Codebase {
  Codebase::{ root, }
}

///|
pub fn Codebase::root(self : Codebase) -> String {
  self.root
}

///|
pub fn Codebase::object_path(self : Codebase, hash : String) -> String {
  @core.object_path_from_hash(self.root, hash)
}

///|
pub fn Codebase::object_dir(self : Codebase, hash : String) -> String {
  @core.object_dir_from_hash(self.root, hash)
}

///|
pub fn Codebase::read_object(self : Codebase, hash : String) -> String? {
  let path = self.object_path(hash)
  let content = match @io.read_string(path) {
    Ok(v) => v
    Err(_) => return None
  }
  Some(content)
}

///|
pub fn Codebase::write_object(
  self : Codebase,
  hash : String,
  content : String,
) -> Unit raise CodebaseError {
  ensure_dir(self.root)
  let objects_dir = self.root + "/objects"
  ensure_dir(objects_dir)
  ensure_dir(self.object_dir(hash))
  let path = self.object_path(hash)
  if not(@io.path_exists(path)) {
    match @io.write_string(path, content) {
      Ok(_) => ()
      Err(err) => raise CodebaseError::Io("write object: " + err)
    }
  }
}

///|
pub fn Codebase::load_path_mappings(
  self : Codebase,
) -> Array[@core.PathMapping] {
  let path = self.root + "/paths.json"
  if not(@io.path_exists(path)) {
    return []
  }
  let json = match @io.read_string(path) {
    Ok(v) => v
    Err(_) => return []
  }
  @core.parse_path_mappings(json) catch {
    _ => []
  }
}

///|
pub fn Codebase::save_path_mappings(
  self : Codebase,
  mappings : Array[@core.PathMapping],
) -> Unit raise CodebaseError {
  ensure_dir(self.root)
  let json = @core.serialize_path_mappings(mappings)
  match @io.write_string(self.root + "/paths.json", json) {
    Ok(_) => ()
    Err(err) => raise CodebaseError::Io("write paths.json: " + err)
  }
}

///|
pub fn Codebase::upsert_path_mapping(
  self : Codebase,
  path : String,
  hash : String,
) -> Unit raise CodebaseError {
  let mappings = self.load_path_mappings()
  let mut found = false
  for i, m in mappings {
    if m.path == path {
      mappings[i] = @core.PathMapping::{ path, hash }
      found = true
      break
    }
  }
  if not(found) {
    mappings.push(@core.PathMapping::{ path, hash })
  }
  self.save_path_mappings(mappings)
}

///|
pub fn Codebase::resolve_path_mapping(
  self : Codebase,
  target : String,
) -> String? {
  let mappings = self.load_path_mappings()
  for m in mappings {
    if m.path == target || m.path.has_suffix(target) {
      return Some(m.hash)
    }
  }
  None
}

///|
fn resolve_import_path(base : String, import_path : String) -> String {
  if import_path.has_prefix("/") {
    @xsh_fs.normalize_path(import_path)
  } else {
    @xsh_fs.normalize_path(base + "/" + import_path)
  }
}

///|
fn collect_path_refs_impl(
  path : String,
  out : Map[String, String],
  visited : Map[String, Bool],
  stack : Array[String],
) -> Result[Unit, String] {
  let norm = @xsh_fs.normalize_path(path)
  for i, p in stack {
    if p == norm {
      let cycle_path = StringBuilder::new()
      for j = i; j < stack.length(); j = j + 1 {
        cycle_path.write_string(stack[j])
        cycle_path.write_string(" -> ")
      }
      cycle_path.write_string(norm)
      return Err("import cycle detected: " + cycle_path.to_string())
    }
  }
  if visited.contains(norm) {
    return Ok(())
  }
  stack.push(norm)
  visited[norm] = true
  let source = match @io.read_string(norm) {
    Ok(v) => v
    Err(err) => {
      let _ = stack.pop()
      return Err("io: " + err)
    }
  }
  out[norm] = @core.git_blob_hash_string(source)
  let ast = @parser.parse_ast(source) catch {
    e => {
      let _ = stack.pop()
      return Err("parse: " + e.to_string())
    }
  }
  let base = @xsh_fs.parent_path(norm)
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::Import(source~, ..) =>
        match source {
          @core.ModuleRef::Path(path~) => {
            let resolved = resolve_import_path(base, path)
            match collect_path_refs_impl(resolved, out, visited, stack) {
              Ok(_) => ()
              Err(err) => {
                let _ = stack.pop()
                return Err(err)
              }
            }
          }
          @core.ModuleRef::Hash(..)
          | @core.ModuleRef::Version(..)
          | @core.ModuleRef::Symbol(..) => ()
        }
      _ => ()
    }
  }
  let _ = stack.pop()
  Ok(())
}

///|
fn collect_path_refs(entry : String) -> Result[Map[String, String], String] {
  let out : Map[String, String] = {}
  let visited : Map[String, Bool] = {}
  let stack : Array[String] = []
  match collect_path_refs_impl(entry, out, visited, stack) {
    Ok(_) => Ok(out)
    Err(err) => Err(err)
  }
}

///|
pub struct LockData {
  path_refs : Map[String, String]
  version_refs : Map[String, String]
  symbol_refs : Map[String, String]
} derive(Show, Eq)

///|
pub fn LockData::new(
  path_refs : Map[String, String],
  version_refs : Map[String, String],
  symbol_refs : Map[String, String],
) -> LockData {
  { path_refs, version_refs, symbol_refs }
}

///|
pub fn empty_lock_data() -> LockData {
  LockData::new({}, {}, {})
}

///|
fn normalize_lock_hash(hash : String) -> String {
  if hash.has_prefix("#") && hash.length() > 1 {
    hash.unsafe_substring(start=1, end=hash.length())
  } else {
    hash
  }
}

///|
fn parse_lock_path_map(
  json : Json?,
  base_dir : String,
) -> Result[Map[String, String], String] {
  let out : Map[String, String] = {}
  match json {
    None => Ok(out)
    Some(Json::Object(entries)) => {
      for key, value in entries {
        match value {
          Json::String(hash) => {
            let normalized = if key.has_prefix("/") {
              @xsh_fs.normalize_path(key)
            } else {
              @xsh_fs.normalize_path(base_dir + "/" + key)
            }
            out[normalized] = normalize_lock_hash(hash)
          }
          _ => return Err("xsh.lock: path.\{key} must be a string hash")
        }
      }
      Ok(out)
    }
    Some(_) => Err("xsh.lock: `path` must be an object")
  }
}

///|
fn parse_lock_ref_map(
  json : Json?,
  field_name : String,
) -> Result[Map[String, String], String] {
  let out : Map[String, String] = {}
  match json {
    None => Ok(out)
    Some(Json::Object(entries)) => {
      for key, value in entries {
        match value {
          Json::String(hash) => out[key] = normalize_lock_hash(hash)
          _ =>
            return Err("xsh.lock: \{field_name}.\{key} must be a string hash")
        }
      }
      Ok(out)
    }
    Some(_) => Err("xsh.lock: `\{field_name}` must be an object")
  }
}

///|
fn parse_lock_data(
  content : String,
  base_dir : String,
) -> Result[LockData, String] {
  if content.trim().to_string().length() == 0 {
    return Ok(empty_lock_data())
  }
  let json : Json = @json.parse(content) catch {
    e => return Err("xsh.lock: invalid JSON: " + e.to_string())
  }
  match json {
    Json::Object(obj) => {
      let path_refs = match parse_lock_path_map(obj.get("path"), base_dir) {
        Ok(v) => v
        Err(err) => return Err(err)
      }
      let version_refs = match
        parse_lock_ref_map(obj.get("version"), "version") {
        Ok(v) => v
        Err(err) => return Err(err)
      }
      let symbol_refs = match parse_lock_ref_map(obj.get("symbol"), "symbol") {
        Ok(v) => v
        Err(err) => return Err(err)
      }
      Ok(LockData::new(path_refs, version_refs, symbol_refs))
    }
    _ => Err("xsh.lock: top-level JSON must be an object")
  }
}

///|
fn write_json_string_literal(text : String, buf : StringBuilder) -> Unit {
  buf.write_char('"')
  for c in text {
    match c {
      '"' => buf.write_string("\\\"")
      '\\' => buf.write_string("\\\\")
      '\n' => buf.write_string("\\n")
      '\r' => buf.write_string("\\r")
      '\t' => buf.write_string("\\t")
      _ => buf.write_char(c)
    }
  }
  buf.write_char('"')
}

///|
fn split_path_parts(path : String) -> Array[String] {
  let parts : Array[String] = []
  for part in path.split("/") {
    let s = part.to_string()
    if s.length() > 0 {
      parts.push(s)
    }
  }
  parts
}

///|
fn relativize_lock_path(base_dir : String, target_path : String) -> String {
  let base = @xsh_fs.normalize_path(base_dir)
  let target = @xsh_fs.normalize_path(target_path)
  if not(base.has_prefix("/")) || not(target.has_prefix("/")) {
    return target
  }
  let base_parts = split_path_parts(base)
  let target_parts = split_path_parts(target)
  let mut common = 0
  while common < base_parts.length() &&
        common < target_parts.length() &&
        base_parts[common] == target_parts[common] {
    common += 1
  }
  let rel_buf = StringBuilder::new()
  let mut wrote = false
  for _ in common..<base_parts.length() {
    if wrote {
      rel_buf.write_char('/')
    }
    rel_buf.write_string("..")
    wrote = true
  }
  for i in common..<target_parts.length() {
    if wrote {
      rel_buf.write_char('/')
    }
    rel_buf.write_string(target_parts[i])
    wrote = true
  }
  let rel = rel_buf.to_string()
  if rel.length() == 0 {
    "."
  } else if rel.has_prefix("..") {
    rel
  } else {
    "./" + rel
  }
}

///|
fn write_lock_map_json(
  map : Map[String, String],
  buf : StringBuilder,
  base_dir : String?,
) -> Unit {
  buf.write_char('{')
  let mut first = true
  for key, value in map {
    if first {
      first = false
    } else {
      buf.write_char(',')
    }
    let rendered_key = match base_dir {
      Some(base) => relativize_lock_path(base, key)
      None => key
    }
    write_json_string_literal(rendered_key, buf)
    buf.write_char(':')
    write_json_string_literal(value, buf)
  }
  buf.write_char('}')
}

///|
fn lock_data_to_json(lock : LockData, lock_base_dir : String) -> String {
  let buf = StringBuilder::new()
  buf.write_char('{')
  write_json_string_literal("path", buf)
  buf.write_char(':')
  write_lock_map_json(lock.path_refs, buf, Some(lock_base_dir))
  buf.write_char(',')
  write_json_string_literal("version", buf)
  buf.write_char(':')
  write_lock_map_json(lock.version_refs, buf, None)
  buf.write_char(',')
  write_json_string_literal("symbol", buf)
  buf.write_char(':')
  write_lock_map_json(lock.symbol_refs, buf, None)
  buf.write_char('}')
  buf.to_string()
}

///|
pub fn lock_file_path(entry : String) -> String {
  @xsh_fs.parent_path(entry) + "/xsh.lock"
}

///|
pub fn load_lock_data_with_fs(
  lock_path : String,
  fs : &@io.FileSystemAdapter,
) -> Result[LockData, String] {
  if not(@io.path_exists_with(fs, lock_path)) {
    return Ok(empty_lock_data())
  }
  let base_dir = @xsh_fs.parent_path(lock_path)
  let content = match @io.read_string_with(fs, lock_path) {
    Ok(v) => v
    Err(err) => return Err("failed to read xsh.lock: " + err)
  }
  parse_lock_data(content, base_dir)
}

///|
pub fn load_lock_data(lock_path : String) -> Result[LockData, String] {
  load_lock_data_with_fs(lock_path, @io.default_fs_adapter())
}

///|
pub fn write_lock_data_with_fs(
  lock_path : String,
  lock : LockData,
  fs : &@io.FileSystemAdapter,
) -> Result[Unit, String] {
  let base_dir = @xsh_fs.parent_path(lock_path)
  let content = lock_data_to_json(lock, base_dir)
  match @io.write_string_with(fs, lock_path, content) {
    Ok(_) => ()
    Err(err) => return Err("failed to write xsh.lock: " + err)
  }
  Ok(())
}

///|
pub fn write_lock_data(
  lock_path : String,
  lock : LockData,
) -> Result[Unit, String] {
  write_lock_data_with_fs(lock_path, lock, @io.default_fs_adapter())
}

///|
fn clone_lock_map(src : Map[String, String]) -> Map[String, String] {
  let out : Map[String, String] = {}
  for key, value in src {
    out[key] = value
  }
  out
}

///|
pub fn update_lock_path_refs(entry : String) -> Result[LockData, String] {
  let lock_path = lock_file_path(entry)
  let current = match load_lock_data(lock_path) {
    Ok(lock) => lock
    Err(err) => return Err(err)
  }
  let path_refs = match collect_path_refs(entry) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let merged_path_refs = clone_lock_map(current.path_refs)
  for path, hash in path_refs {
    merged_path_refs[path] = hash
  }
  let next_lock = LockData::new(
    merged_path_refs,
    current.version_refs,
    current.symbol_refs,
  )
  match write_lock_data(lock_path, next_lock) {
    Ok(_) => Ok(next_lock)
    Err(err) => Err(err)
  }
}

///|
fn ensure_dir(path : String) -> Unit raise CodebaseError {
  if not(@io.path_exists(path)) {
    match @io.create_dir(path) {
      Ok(_) => ()
      Err(err) => raise CodebaseError::Io("mkdir: " + err)
    }
  }
}
