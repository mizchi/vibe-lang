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
    @vibe_fs.normalize_path(import_path)
  } else {
    @vibe_fs.normalize_path(base + "/" + import_path)
  }
}

///|
fn resolve_import_module_entry(path : String) -> String {
  let normalized = @vibe_fs.normalize_path(path)
  if normalized.has_suffix(".vibe") ||
    normalized.has_suffix(".xm") ||
    normalized.has_suffix(".wasm") ||
    normalized.has_suffix(".db") ||
    normalized.has_suffix(".lock") ||
    normalized.has_suffix(".vbundle") {
    normalized
  } else {
    @vibe_fs.normalize_path(normalized + "/index.vibe")
  }
}

///|
fn is_within_root(root : String, path : String) -> Bool {
  let root_norm = @vibe_fs.normalize_path(root)
  let path_norm = @vibe_fs.normalize_path(path)
  if root_norm == "/" {
    return path_norm.has_prefix("/")
  }
  if path_norm == root_norm {
    return true
  }
  path_norm.has_prefix(root_norm + "/")
}

///|
fn first_slash_index(path : String) -> Int? {
  for i, c in path {
    if c == '/' {
      return Some(i)
    }
  }
  None
}

///|
fn split_registry_import_path(path : String) -> (String, String)? {
  match first_slash_index(path) {
    Some(idx) =>
      if idx <= 0 || idx + 1 >= path.length() {
        None
      } else {
        let ns = path.unsafe_substring(start=0, end=idx)
        let rest = path.unsafe_substring(start=idx + 1, end=path.length())
        Some((ns, rest))
      }
    None => None
  }
}

///|
fn default_registry_modules(root : String) -> Map[String, String] {
  let out : Map[String, String] = {}
  out["builtin"] = @vibe_fs.normalize_path(root + "/vibe/builtin")
  out["std"] = @vibe_fs.normalize_path(root + "/vibe/builtin")
  out["encoding"] = @vibe_fs.normalize_path(root + "/vibe/encoding")
  out["collection"] = @vibe_fs.normalize_path(root + "/vibe/collection")
  out["rlm"] = @vibe_fs.normalize_path(root + "/vibe/rlm")
  out
}

///|
fn has_lock_file_with_fs(dir : String, fs : &@io.FileSystemAdapter) -> Bool {
  let index_lock = @vibe_fs.normalize_path(dir + "/index.lock")
  if @io.path_exists_with(fs, index_lock) {
    return true
  }
  let legacy_lock = @vibe_fs.normalize_path(dir + "/vibe.lock")
  @io.path_exists_with(fs, legacy_lock)
}

///|
fn has_vibe_dir_with_fs(dir : String, fs : &@io.FileSystemAdapter) -> Bool {
  let vibe_dir = @vibe_fs.normalize_path(dir + "/.vibe")
  @io.path_exists_with(fs, vibe_dir)
}

///|
fn find_storage_root_with_fs(
  start_dir : String,
  fs : &@io.FileSystemAdapter,
) -> String {
  let normalized_start = @vibe_fs.normalize_path(start_dir)
  let mut dir = normalized_start
  let mut nearest_index_root : String? = None
  let mut lock_root_with_index_descendant : String? = None
  let mut local_lock_only_root : String? = None
  let mut has_index_descendant = false
  for _ in 0..<64 {
    let has_lock = has_lock_file_with_fs(dir, fs)
    if has_lock && has_vibe_dir_with_fs(dir, fs) {
      return dir
    }
    if has_lock && dir == normalized_start && local_lock_only_root == None {
      local_lock_only_root = Some(dir)
    }
    if has_lock &&
      has_index_descendant &&
      lock_root_with_index_descendant == None {
      lock_root_with_index_descendant = Some(dir)
    }
    let index_path = @vibe_fs.normalize_path(dir + "/index.vibe")
    if @io.path_exists_with(fs, index_path) {
      if nearest_index_root == None {
        nearest_index_root = Some(dir)
      }
      has_index_descendant = true
    }
    let parent = @vibe_fs.parent_path(dir)
    if parent == dir || parent.length() == 0 {
      break
    }
    dir = parent
  }
  match lock_root_with_index_descendant {
    Some(root) => root
    None =>
      match local_lock_only_root {
        Some(root) => root
        None =>
          match nearest_index_root {
            Some(root) => root
            None => normalized_start
          }
      }
  }
}

///|
fn find_named_ancestor_dir(start_dir : String, name : String) -> String? {
  let mut dir = @vibe_fs.normalize_path(start_dir)
  for _ in 0..<64 {
    if @vibe_fs.basename(dir) == name {
      return Some(dir)
    }
    let parent = @vibe_fs.parent_path(dir)
    if parent == dir || parent.length() == 0 {
      break
    }
    dir = parent
  }
  None
}

///|
fn is_repo_vibe_root_with_fs(dir : String, fs : &@io.FileSystemAdapter) -> Bool {
  let builtin_lock = @vibe_fs.normalize_path(dir + "/builtin/index.lock")
  let std_lock = @vibe_fs.normalize_path(dir + "/std/index.lock")
  let encoding_lock = @vibe_fs.normalize_path(dir + "/encoding/index.lock")
  (@io.path_exists_with(fs, builtin_lock) || @io.path_exists_with(fs, std_lock)) &&
  @io.path_exists_with(fs, encoding_lock)
}

///|
fn find_index_root_with_fs(
  start_dir : String,
  fs : &@io.FileSystemAdapter,
) -> String {
  let mut dir = @vibe_fs.normalize_path(start_dir)
  for _ in 0..<64 {
    let index_path = @vibe_fs.normalize_path(dir + "/index.vibe")
    if @io.path_exists_with(fs, index_path) {
      return dir
    }
    let parent = @vibe_fs.parent_path(dir)
    if parent == dir || parent.length() == 0 {
      break
    }
    dir = parent
  }
  @vibe_fs.normalize_path(start_dir)
}

///|
pub fn resolve_index_root_with_fs(
  entry : String,
  fs : &@io.FileSystemAdapter,
) -> String {
  let normalized_entry = if entry.has_prefix("/") {
    @vibe_fs.normalize_path(entry)
  } else {
    @vibe_fs.normalize_path(@io.current_dir_or_root_with(fs) + "/" + entry)
  }
  let start_dir = @vibe_fs.parent_path(normalized_entry)
  find_index_root_with_fs(start_dir, fs)
}

///|
pub fn resolve_index_root(entry : String) -> String {
  resolve_index_root_with_fs(entry, @io.default_fs_adapter())
}

///|
pub fn resolve_lock_root_with_fs(
  entry : String,
  fs : &@io.FileSystemAdapter,
) -> String {
  let normalized_entry = if entry.has_prefix("/") {
    @vibe_fs.normalize_path(entry)
  } else {
    @vibe_fs.normalize_path(@io.current_dir_or_root_with(fs) + "/" + entry)
  }
  let start_dir = @vibe_fs.parent_path(normalized_entry)
  find_storage_root_with_fs(start_dir, fs)
}

///|
pub fn resolve_lock_root(entry : String) -> String {
  resolve_lock_root_with_fs(entry, @io.default_fs_adapter())
}

///|
fn unwrap_local_type_assert_expr(expr : @core.Expr) -> @core.Expr {
  match expr {
    @core.Expr::Block(body~, ..) => {
      if body.stmts.length() != 2 {
        return expr
      }
      let helper_name = match body.stmts[0] {
        @core.Stmt::Let(
          rec~,
          name~,
          expr=@core.Expr::Fn(params~, ret~, body=helper_body, ..),
          ..
        ) =>
          if rec ||
            not(name.has_prefix("__vibe_local_type_assert_")) ||
            params.length() != 1 ||
            helper_body.stmts.length() != 1 {
            return expr
          } else {
            let ret_ty = match ret {
              Some(v) => v
              None => return expr
            }
            if params[0].ty != ret_ty {
              return expr
            }
            match helper_body.stmts[0] {
              @core.Stmt::Expr(
                expr=@core.Expr::Ident(name=returned_name, ..),
                ..
              ) => if returned_name != params[0].name { return expr }
              _ => return expr
            }
            name
          }
        _ => return expr
      }
      match body.stmts[1] {
        @core.Stmt::Expr(expr=@core.Expr::Call(name~, args~, ..), ..) =>
          if name == helper_name && args.length() == 1 {
            unwrap_local_type_assert_expr(args[0].expr)
          } else {
            expr
          }
        _ => expr
      }
    }
    _ => expr
  }
}

///|
fn extract_record_string_map(expr : @core.Expr) -> Map[String, String]? {
  match unwrap_local_type_assert_expr(expr) {
    @core.Expr::Record(fields~, ..) => {
      let out : Map[String, String] = {}
      for field in fields {
        match field.expr {
          @core.Expr::String(value~, ..) => out[field.name] = value
          _ => ()
        }
      }
      Some(out)
    }
    _ => None
  }
}

///|
fn extract_registry_map(ast : @core.Module) -> Map[String, String]? {
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::Let(name~, expr~, ..)
      | @core.Stmt::ExportLet(name~, expr~, ..) =>
        if name == "module" || name == "registry" {
          match extract_record_string_map(expr) {
            Some(out) => return Some(out)
            None => ()
          }
        }
      _ => ()
    }
  }
  None
}

///|
fn is_ascii_digits(text : String) -> Bool {
  if text.length() == 0 {
    return false
  }
  for _, c in text {
    if c < '0' || c > '9' {
      return false
    }
  }
  true
}

///|
fn is_simple_semver(version : String) -> Bool {
  let parts : Array[String] = []
  for part in version.split(".") {
    parts.push(part.to_string())
  }
  if parts.length() != 3 {
    return false
  }
  for part in parts {
    if not(is_ascii_digits(part)) {
      return false
    }
  }
  true
}

///|
fn require_index_version(ast : @core.Module) -> Result[String, String] {
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::ExportLet(name~, expr~, ..) =>
        if name == "version" {
          match unwrap_local_type_assert_expr(expr) {
            @core.Expr::String(value~, ..) =>
              if is_simple_semver(value) {
                return Ok(value)
              } else {
                return Err(
                  "index.vibe: `export let version` must be semver like \"0.1.0\"",
                )
              }
            _ =>
              return Err(
                "index.vibe: `export let version` must be a string literal",
              )
          }
        }
      _ => ()
    }
  }
  Err("index.vibe: missing required `export let version = \"0.1.0\"`")
}

///|
fn normalize_registry_modules(
  root : String,
  raw : Map[String, String],
) -> Result[Map[String, String], String] {
  let out = default_registry_modules(root)
  for ns, raw_path in raw {
    let resolved = if raw_path.has_prefix("/") {
      @vibe_fs.normalize_path(raw_path)
    } else {
      @vibe_fs.normalize_path(root + "/" + raw_path)
    }
    if not(is_within_root(root, resolved)) {
      return Err(
        "index.vibe registry path outside root: " + ns + " -> " + resolved,
      )
    }
    out[ns] = resolved
  }
  Ok(out)
}

///|
pub fn load_registry_modules_with_fs(
  root : String,
  fs : &@io.FileSystemAdapter,
) -> Result[Map[String, String], String] {
  let root_norm = @vibe_fs.normalize_path(root)
  let index_path = @vibe_fs.normalize_path(root_norm + "/index.vibe")
  if not(@io.path_exists_with(fs, index_path)) {
    return Ok(default_registry_modules(root_norm))
  }
  let content = match @io.read_string_with(fs, index_path) {
    Ok(v) => v
    Err(err) => return Err("failed to read index.vibe: " + err)
  }
  let ast = @parser.parse_ast(content) catch {
    e => return Err("index.vibe parse: " + e.to_string())
  }
  let _ = match require_index_version(ast) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let raw = match extract_registry_map(ast) {
    Some(v) => v
    None => {}
  }
  normalize_registry_modules(root_norm, raw)
}

///|
pub fn load_registry_modules(
  root : String,
) -> Result[Map[String, String], String] {
  load_registry_modules_with_fs(root, @io.default_fs_adapter())
}

///|
pub fn resolve_import_path_with_registry(
  base : String,
  import_path : String,
  root : String,
  registry_modules : Map[String, String],
) -> Result[String, String] {
  let resolved_raw = if import_path.has_prefix("/") {
    @vibe_fs.normalize_path(import_path)
  } else if import_path.has_prefix("./") || import_path.has_prefix("../") {
    @vibe_fs.normalize_path(base + "/" + import_path)
  } else {
    match split_registry_import_path(import_path) {
      Some((ns, rest)) =>
        match registry_modules.get(ns) {
          Some(ns_root) => @vibe_fs.normalize_path(ns_root + "/" + rest)
          None =>
            return Err(
              "unknown namespace: " +
              ns +
              " (import: " +
              import_path +
              "). use ./ or ../ for local paths",
            )
      }
      None => resolve_import_path(base, import_path)
    }
  }
  let resolved = resolve_import_module_entry(resolved_raw)
  if not(is_within_root(root, resolved)) {
    return Err(
      "import path outside root: " + resolved + " (root: " + root + ")",
    )
  }
  Ok(resolved)
}

///|
fn collect_module_export_refs(
  path : String,
  ast : @core.Module,
  module_refs : Map[String, String],
) -> Unit {
  let exports = @core.extract_exports(ast)
  let zero = @core.Span::empty(0)
  for name, stmt in exports {
    let export_module = @core.Module::{
      stmts: [stmt, @core.Stmt::Export(names=[name], span=zero)],
    }
    let normalized = @core.normalize_module(export_module)
    let export_hash = @core.hash_module(normalized)
    module_refs[path + "#" + name] = export_hash
  }
}

///|
fn collect_line_starts(source : String) -> Array[Int] {
  let starts : Array[Int] = [0]
  for i, c in source {
    if c == '\n' && i + 1 < source.length() {
      starts.push(i + 1)
    }
  }
  starts
}

///|
fn line_index_for_offset(
  line_starts : Array[Int],
  source_len : Int,
  offset : Int,
) -> Int {
  if line_starts.length() == 0 {
    return 0
  }
  let off = if offset < 0 {
    0
  } else if offset > source_len {
    source_len
  } else {
    offset
  }
  let mut idx = 0
  for i in 0..<line_starts.length() {
    let start = line_starts[i]
    if start > off {
      break
    }
    idx = i
  }
  idx
}

///|
fn source_line_text(
  source : String,
  line_starts : Array[Int],
  line_idx : Int,
) -> String {
  if line_starts.length() == 0 {
    return ""
  }
  let start = line_starts[line_idx]
  let mut end = source.length()
  if line_idx + 1 < line_starts.length() {
    end = line_starts[line_idx + 1]
  }
  if end > start {
    let last = source[end - 1].to_int().unsafe_to_char()
    if last == '\n' {
      end -= 1
    }
  }
  if end <= start {
    ""
  } else {
    source.unsafe_substring(start~, end~)
  }
}

///|
fn line_comment_body(line : String) -> String? {
  let mut i = 0
  while i < line.length() {
    let c = line[i].to_int().unsafe_to_char()
    if c == ' ' || c == '\t' {
      i += 1
      continue
    }
    if c != '/' || i + 1 >= line.length() {
      return None
    }
    let next = line[i + 1].to_int().unsafe_to_char()
    if next != '/' {
      return None
    }
    let mut start = i + 2
    if start < line.length() && line[start].to_int().unsafe_to_char() == ' ' {
      start += 1
    }
    return Some(line.unsafe_substring(start~, end=line.length()))
  }
  None
}

///|
fn line_is_blank(line : String) -> Bool {
  for c in line {
    if c != ' ' && c != '\t' && c != '\r' {
      return false
    }
  }
  true
}

///|
fn leading_comment_block_at(
  source : String,
  line_starts : Array[Int],
  offset : Int,
) -> String? {
  if line_starts.length() == 0 {
    return None
  }
  let line_idx = line_index_for_offset(line_starts, source.length(), offset)
  if line_idx == 0 {
    return None
  }
  let prev_idx = line_idx - 1
  match line_comment_body(source_line_text(source, line_starts, prev_idx)) {
    None => return None
    Some(_) => ()
  }
  let mut start_idx = prev_idx
  while start_idx > 0 {
    let cand = start_idx - 1
    match line_comment_body(source_line_text(source, line_starts, cand)) {
      Some(_) => start_idx = cand
      None => break
    }
  }
  let buf = StringBuilder::new()
  let mut first = true
  for i in start_idx..<line_idx {
    match line_comment_body(source_line_text(source, line_starts, i)) {
      Some(body) => {
        if first {
          first = false
        } else {
          buf.write_char('\n')
        }
        buf.write_string(body)
      }
      None => ()
    }
  }
  Some(buf.to_string())
}

///|
fn statement_anchor_offset(source : String, offset : Int) -> Int {
  let mut start = if offset < 0 {
    0
  } else if offset > source.length() {
    source.length()
  } else {
    offset
  }
  while start > 0 {
    let prev = source[start - 1].to_int().unsafe_to_char()
    if prev == '\n' {
      break
    }
    start -= 1
  }
  while start < source.length() {
    let mut end = start
    while end < source.length() {
      let c = source[end].to_int().unsafe_to_char()
      if c == '\n' {
        break
      }
      end += 1
    }
    let line = if end <= start {
      ""
    } else {
      source.unsafe_substring(start~, end~)
    }
    if line_is_blank(line) || line_comment_body(line) is Some(_) {
      if end >= source.length() {
        return source.length()
      }
      start = end + 1
      continue
    }
    let mut i = start
    while i < end {
      let c = source[i].to_int().unsafe_to_char()
      if c == ' ' || c == '\t' || c == '\r' {
        i += 1
        continue
      }
      return i
    }
    return end
  }
  source.length()
}

///|
fn line_leading_indent(line : String) -> String {
  let mut end = 0
  while end < line.length() {
    let c = line[end].to_int().unsafe_to_char()
    if c == ' ' || c == '\t' {
      end += 1
    } else {
      break
    }
  }
  if end == 0 {
    ""
  } else {
    line.unsafe_substring(start=0, end~)
  }
}

///|
fn render_comment_block(note : String, indent : String) -> String {
  let buf = StringBuilder::new()
  for part in note.split("\n") {
    let line = part.to_string()
    buf.write_string(indent)
    buf.write_string("//")
    if line.length() > 0 {
      buf.write_char(' ')
      buf.write_string(line)
    }
    buf.write_char('\n')
  }
  buf.to_string()
}

///|
fn collect_module_export_annotations(
  path : String,
  source : String,
  ast : @core.Module,
  annotations : Map[String, String],
) -> Unit {
  let exports = @core.extract_exports(ast)
  if exports.length() == 0 {
    return
  }
  let line_starts = collect_line_starts(source)
  for name, stmt in exports {
    let key = path + "#" + name
    let span = stmt.span()
    let anchor = statement_anchor_offset(source, span.start)
    match leading_comment_block_at(source, line_starts, anchor) {
      Some(note) => annotations[key] = note
      None => ()
    }
  }
}

///|
pub fn apply_annotations_to_source(
  path : String,
  source : String,
  annotations : Map[String, String],
) -> Result[String, String] {
  if annotations.length() == 0 {
    return Ok(source)
  }
  let ast = @parser.parse_ast(source) catch {
    e => return Err("parse: " + e.to_string())
  }
  let exports = @core.extract_exports(ast)
  if exports.length() == 0 {
    return Ok(source)
  }
  let line_starts = collect_line_starts(source)
  let line_notes : Map[Int, String] = {}
  for name, stmt in exports {
    let key = path + "#" + name
    let note = match annotations.get(key) {
      Some(v) => v
      None => continue
    }
    let span = stmt.span()
    let anchor = statement_anchor_offset(source, span.start)
    match leading_comment_block_at(source, line_starts, anchor) {
      Some(_) => continue
      None => ()
    }
    let line_idx = line_index_for_offset(line_starts, source.length(), anchor)
    if not(line_notes.contains(line_idx)) {
      line_notes[line_idx] = note
    }
  }
  if line_notes.length() == 0 {
    return Ok(source)
  }
  let out = StringBuilder::new()
  let mut cursor = 0
  for line_idx in 0..<line_starts.length() {
    match line_notes.get(line_idx) {
      Some(note) => {
        let line_start = line_starts[line_idx]
        out.write_string(source.unsafe_substring(start=cursor, end=line_start))
        let line = source_line_text(source, line_starts, line_idx)
        let indent = line_leading_indent(line)
        out.write_string(render_comment_block(note, indent))
        cursor = line_start
      }
      None => ()
    }
  }
  out.write_string(source.unsafe_substring(start=cursor, end=source.length()))
  Ok(out.to_string())
}

///|
fn collect_path_refs_impl(
  path : String,
  out : Map[String, String],
  module_refs : Map[String, String],
  annotations : Map[String, String],
  visited : Map[String, Bool],
  stack : Array[String],
  root : String,
  registry_modules : Map[String, String],
  fs : &@io.FileSystemAdapter,
) -> Result[Unit, String] {
  let norm = @vibe_fs.normalize_path(path)
  if not(is_within_root(root, norm)) {
    return Err("import path outside root: " + norm + " (root: " + root + ")")
  }
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
  let source = match @io.read_string_with(fs, norm) {
    Ok(v) => v
    Err(err) => {
      let _ = stack.pop()
      return Err("io: " + err)
    }
  }
  out[norm] = @core.content_address_hash_string(source)
  let ast = @parser.parse_ast(source) catch {
    e => {
      let _ = stack.pop()
      return Err("parse: " + e.to_string())
    }
  }
  collect_module_export_refs(norm, ast, module_refs)
  collect_module_export_annotations(norm, source, ast, annotations)
  let base = @vibe_fs.parent_path(norm)
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::Import(spec~, source~, ..) => {
        if spec.items.length() == 0 {
          continue
        }
        match source {
          @core.ModuleRef::Path(path~) => {
            let resolved = match
              resolve_import_path_with_registry(
                base, path, root, registry_modules,
              ) {
              Ok(v) => v
              Err(err) => {
                let _ = stack.pop()
                return Err(err)
              }
            }
            match
              collect_path_refs_impl(
                resolved, out, module_refs, annotations, visited, stack, root, registry_modules,
                fs,
              ) {
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
      }
      @core.Stmt::ReExport(source~, ..) =>
        match source {
          @core.ModuleRef::Path(path~) => {
            let resolved = match
              resolve_import_path_with_registry(
                base, path, root, registry_modules,
              ) {
              Ok(v) => v
              Err(err) => {
                let _ = stack.pop()
                return Err(err)
              }
            }
            match
              collect_path_refs_impl(
                resolved, out, module_refs, annotations, visited, stack, root, registry_modules,
                fs,
              ) {
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
fn collect_path_refs(
  entry : String,
  root : String,
  registry_modules : Map[String, String],
  fs : &@io.FileSystemAdapter,
) -> Result[
  (Map[String, String], Map[String, String], Map[String, String]),
  String,
] {
  let out : Map[String, String] = {}
  let module_refs : Map[String, String] = {}
  let annotations : Map[String, String] = {}
  let visited : Map[String, Bool] = {}
  let stack : Array[String] = []
  match
    collect_path_refs_impl(
      entry, out, module_refs, annotations, visited, stack, root, registry_modules,
      fs,
    ) {
    Ok(_) => Ok((out, module_refs, annotations))
    Err(err) => Err(err)
  }
}

///|
pub struct LockData {
  path_refs : Map[String, String]
  version_refs : Map[String, String]
  symbol_refs : Map[String, String]
  module_refs : Map[String, String]
  annotations : Map[String, String]
} derive(Show, Eq)

///|
pub fn LockData::new(
  path_refs : Map[String, String],
  version_refs : Map[String, String],
  symbol_refs : Map[String, String],
) -> LockData {
  { path_refs, version_refs, symbol_refs, module_refs: {}, annotations: {} }
}

///|
pub fn LockData::new_with_meta(
  path_refs : Map[String, String],
  version_refs : Map[String, String],
  symbol_refs : Map[String, String],
  module_refs : Map[String, String],
  annotations : Map[String, String],
) -> LockData {
  { path_refs, version_refs, symbol_refs, module_refs, annotations }
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
              @vibe_fs.normalize_path(key)
            } else {
              @vibe_fs.normalize_path(base_dir + "/" + key)
            }
            out[normalized] = normalize_lock_hash(hash)
          }
          _ => return Err("index.lock: path.\{key} must be a string hash")
        }
      }
      Ok(out)
    }
    Some(_) => Err("index.lock: `path` must be an object")
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
            return Err("index.lock: \{field_name}.\{key} must be a string hash")
        }
      }
      Ok(out)
    }
    Some(_) => Err("index.lock: `\{field_name}` must be an object")
  }
}

///|
fn parse_lock_string_map(
  json : Json?,
  field_name : String,
) -> Result[Map[String, String], String] {
  let out : Map[String, String] = {}
  match json {
    None => Ok(out)
    Some(Json::Object(entries)) => {
      for key, value in entries {
        match value {
          Json::String(v) => out[key] = v
          _ => return Err("index.lock: \{field_name}.\{key} must be a string")
        }
      }
      Ok(out)
    }
    Some(_) => Err("index.lock: `\{field_name}` must be an object")
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
    e => return Err("index.lock: invalid JSON: " + e.to_string())
  }
  match json {
    Json::Object(obj) => parse_lock_data_from_object(obj, base_dir)
    _ => Err("index.lock: top-level JSON must be an object")
  }
}

///|
fn parse_lock_data_from_object(
  obj : Map[String, Json],
  base_dir : String,
) -> Result[LockData, String] {
  let path_refs = match parse_lock_path_map(obj.get("path"), base_dir) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let version_refs = match parse_lock_ref_map(obj.get("version"), "version") {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let symbol_refs = match parse_lock_ref_map(obj.get("symbol"), "symbol") {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let module_refs = match parse_lock_ref_map(obj.get("module"), "module") {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let annotations = match
    parse_lock_string_map(obj.get("annotation"), "annotation") {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  Ok(
    LockData::new_with_meta(
      path_refs, version_refs, symbol_refs, module_refs, annotations,
    ),
  )
}

///|
fn has_lock_payload_fields(obj : Map[String, Json]) -> Bool {
  obj.contains("path") ||
  obj.contains("version") ||
  obj.contains("symbol") ||
  obj.contains("module") ||
  obj.contains("annotation")
}

///|
fn parse_lock_data_from_index_vbundle(
  content : String,
  base_dir : String,
) -> Result[LockData?, String] {
  let trimmed = content.trim().to_string()
  if trimmed.length() == 0 {
    return Ok(None)
  }
  let json : Json = @json.parse(trimmed) catch {
    // Keep compatibility with non-lock `index.vbundle` payloads.
    _ => return Ok(None)
  }
  match json {
    Json::Object(obj) =>
      if has_lock_payload_fields(obj) {
        match parse_lock_data_from_object(obj, base_dir) {
          Ok(v) => Ok(Some(v))
          Err(err) => Err("index.vbundle: " + err)
        }
      } else {
        match obj.get("lock") {
          Some(Json::Object(lock_obj)) =>
            match parse_lock_data_from_object(lock_obj, base_dir) {
              Ok(v) => Ok(Some(v))
              Err(err) => Err("index.vbundle: " + err)
            }
          Some(_) => Err("index.vbundle: `lock` must be an object")
          None => Ok(None)
        }
      }
    _ => Ok(None)
  }
}

///|
fn read_index_vbundle_object_with_fs(
  path : String,
  fs : &@io.FileSystemAdapter,
) -> Result[Map[String, Json], String] {
  let obj : Map[String, Json] = {}
  if not(@io.path_exists_with(fs, path)) {
    return Ok(obj)
  }
  let source = match @io.read_string_with(fs, path) {
    Ok(v) => v
    Err(err) => return Err("failed to read index.vbundle: " + err)
  }
  let trimmed = source.trim().to_string()
  if trimmed.length() == 0 {
    return Ok(obj)
  }
  let parsed : Json = @json.parse(trimmed) catch {
    e => return Err("index.vbundle: invalid JSON: " + e.to_string())
  }
  match parsed {
    Json::Object(current) => {
      for key, value in current {
        obj[key] = value
      }
      Ok(obj)
    }
    _ => Err("index.vbundle: top-level JSON must be an object")
  }
}

///|
fn write_index_vbundle_object_with_fs(
  path : String,
  obj : Map[String, Json],
  fs : &@io.FileSystemAdapter,
) -> Result[Unit, String] {
  match @io.write_string_with(fs, path, Json::object(obj).stringify() + "\n") {
    Ok(_) => ()
    Err(err) => return Err("failed to write index.vbundle: " + err)
  }
  Ok(())
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
  let base = @vibe_fs.normalize_path(base_dir)
  let target = @vibe_fs.normalize_path(target_path)
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
  let keys : Array[String] = []
  for key, _ in map {
    keys.push(key)
  }
  keys.sort()
  buf.write_char('{')
  let mut first = true
  for key in keys {
    let value = match map.get(key) {
      Some(v) => v
      None => continue
    }
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
  buf.write_char(',')
  write_json_string_literal("module", buf)
  buf.write_char(':')
  write_lock_map_json(lock.module_refs, buf, None)
  buf.write_char(',')
  write_json_string_literal("annotation", buf)
  buf.write_char(':')
  write_lock_map_json(lock.annotations, buf, None)
  buf.write_char('}')
  buf.to_string()
}

///|
fn lock_data_to_json_object(
  lock : LockData,
  lock_base_dir : String,
) -> Map[String, Json] {
  let obj : Map[String, Json] = {}
  let parsed : Json = @json.parse(lock_data_to_json(lock, lock_base_dir)) catch {
    _ => return obj
  }
  match parsed {
    Json::Object(current) => {
      for key, value in current {
        obj[key] = value
      }
      obj
    }
    _ => obj
  }
}

///|
pub fn lock_file_path_with_fs(
  entry : String,
  fs : &@io.FileSystemAdapter,
) -> String {
  resolve_lock_root_with_fs(entry, fs) + "/index.lock"
}

///|
pub fn lock_file_path(entry : String) -> String {
  lock_file_path_with_fs(entry, @io.default_fs_adapter())
}

///|
pub fn vibe_dir_path_with_fs(
  entry : String,
  fs : &@io.FileSystemAdapter,
) -> String {
  let normalized_entry = if entry.has_prefix("/") {
    @vibe_fs.normalize_path(entry)
  } else {
    @vibe_fs.normalize_path(@io.current_dir_or_root_with(fs) + "/" + entry)
  }
  let start_dir = @vibe_fs.parent_path(normalized_entry)
  match find_named_ancestor_dir(start_dir, "vibe") {
    Some(vibe_root) =>
      if is_repo_vibe_root_with_fs(vibe_root, fs) {
        vibe_root + "/.vibe"
      } else {
        resolve_lock_root_with_fs(normalized_entry, fs) + "/.vibe"
      }
    None => resolve_lock_root_with_fs(normalized_entry, fs) + "/.vibe"
  }
}

///|
pub fn vibe_dir_path(entry : String) -> String {
  vibe_dir_path_with_fs(entry, @io.default_fs_adapter())
}

///|
pub fn load_lock_data_with_fs(
  lock_path : String,
  fs : &@io.FileSystemAdapter,
) -> Result[LockData, String] {
  let base_dir = @vibe_fs.parent_path(lock_path)
  let index_vbundle_path = base_dir + "/index.vbundle"
  if @io.path_exists_with(fs, index_vbundle_path) {
    let index_vbundle_content = match
      @io.read_string_with(fs, index_vbundle_path) {
      Ok(v) => v
      Err(err) => return Err("failed to read index.vbundle: " + err)
    }
    match parse_lock_data_from_index_vbundle(index_vbundle_content, base_dir) {
      Ok(Some(lock)) => return Ok(lock)
      Ok(None) => ()
      Err(err) => return Err(err)
    }
  }
  let mut target = lock_path
  if not(@io.path_exists_with(fs, target)) {
    let legacy_path = base_dir + "/vibe.lock"
    if @io.path_exists_with(fs, legacy_path) {
      target = legacy_path
    } else {
      return Ok(empty_lock_data())
    }
  }
  let base_dir = @vibe_fs.parent_path(target)
  let content = match @io.read_string_with(fs, target) {
    Ok(v) => v
    Err(err) => return Err("failed to read index.lock: " + err)
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
  let base_dir = @vibe_fs.parent_path(lock_path)
  let content = lock_data_to_json(lock, base_dir)
  match @io.write_string_with(fs, lock_path, content) {
    Ok(_) => ()
    Err(err) => return Err("failed to write index.lock: " + err)
  }
  let index_vbundle_path = base_dir + "/index.vbundle"
  let index_vbundle_obj = match
    read_index_vbundle_object_with_fs(index_vbundle_path, fs) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  index_vbundle_obj["lock"] = Json::object(
    lock_data_to_json_object(lock, base_dir),
  )
  match
    write_index_vbundle_object_with_fs(
      index_vbundle_path, index_vbundle_obj, fs,
    ) {
    Ok(_) => ()
    Err(err) => return Err(err)
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
pub fn update_lock_path_refs_with_fs(
  entry : String,
  fs : &@io.FileSystemAdapter,
) -> Result[LockData, String] {
  let normalized_entry = if entry.has_prefix("/") {
    @vibe_fs.normalize_path(entry)
  } else {
    @vibe_fs.normalize_path(@io.current_dir_or_root_with(fs) + "/" + entry)
  }
  let root = resolve_index_root_with_fs(normalized_entry, fs)
  let registry_modules = match load_registry_modules_with_fs(root, fs) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let lock_path = lock_file_path_with_fs(normalized_entry, fs)
  let current = match load_lock_data_with_fs(lock_path, fs) {
    Ok(lock) => lock
    Err(err) => return Err(err)
  }
  let (path_refs, module_refs, annotations) = match
    collect_path_refs(normalized_entry, root, registry_modules, fs) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let next_lock = LockData::new_with_meta(
    path_refs,
    current.version_refs,
    current.symbol_refs,
    module_refs,
    annotations,
  )
  match write_lock_data_with_fs(lock_path, next_lock, fs) {
    Ok(_) => Ok(next_lock)
    Err(err) => Err(err)
  }
}

///|
pub fn update_lock_path_refs(entry : String) -> Result[LockData, String] {
  update_lock_path_refs_with_fs(entry, @io.default_fs_adapter())
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
