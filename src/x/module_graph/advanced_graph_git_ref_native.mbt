///|
fn ag_path_parent(path : String) -> String {
  if path == "/" || path.length() == 0 {
    return path
  }
  let mut last = -1
  for i, c in path {
    if c == '/' {
      last = i
    }
  }
  if last <= 0 {
    "."
  } else {
    path.unsafe_substring(start=0, end=last)
  }
}

///|
fn ensure_dir_recursive(path : String) -> Result[Unit, String] {
  if path.length() == 0 || path == "." || path == "/" {
    return Ok(())
  }
  if @os_fs.path_exists(path) {
    return Ok(())
  }
  let parent = ag_path_parent(path)
  match ensure_dir_recursive(parent) {
    Ok(_) => ()
    Err(err) => return Err(err)
  }
  @os_fs.create_dir(path) catch {
    e =>
      if @os_fs.path_exists(path) {
        ()
      } else {
        return Err("mkdir `" + path + "`: " + e.to_string())
      }
  }
  Ok(())
}

///|
fn normalize_ref_scope(scope : String) -> Result[String, String] {
  let trimmed = scope.trim().to_string()
  if trimmed.length() == 0 {
    return Err("ref scope must not be empty")
  }
  let parts : Array[String] = []
  for part in trimmed.split("/") {
    let text = part.to_string()
    if text.length() == 0 || text == "." {
      continue
    }
    if text == ".." {
      return Err("ref scope must not contain `..`: " + scope)
    }
    parts.push(text)
  }
  if parts.length() == 0 {
    return Err("ref scope must not be empty")
  }
  let buf = StringBuilder::new()
  for i, part in parts {
    if i > 0 {
      buf.write_char('/')
    }
    buf.write_string(part)
  }
  Ok(buf.to_string())
}

///|
fn distributed_ref_scope_root(git_dir : String, scope : String) -> String {
  git_dir + "/refs/bit/index/" + scope
}

///|
fn distributed_graph_head_ref_path(git_dir : String, scope : String) -> String {
  distributed_ref_scope_root(git_dir, scope) + "/graph/head"
}

///|
fn distributed_graph_wal_head_ref_path(
  git_dir : String,
  scope : String,
) -> String {
  distributed_ref_scope_root(git_dir, scope) + "/graph/wal_head"
}

///|
fn distributed_graph_delta_chain_kind() -> String {
  "advanced-graph-delta-chain@v1"
}

///|
fn write_ref_hash(path : String, hash : String) -> Result[Unit, String] {
  let parent = ag_path_parent(path)
  match ensure_dir_recursive(parent) {
    Ok(_) => ()
    Err(err) => return Err(err)
  }
  @os_fs.write_string_to_file(path, hash + "\n") catch {
    e => return Err("write ref `" + path + "`: " + e.to_string())
  }
  Ok(())
}

///|
fn read_ref_hash(path : String) -> Result[String, String] {
  let content = @os_fs.read_file_to_string(path) catch {
    e => return Err("read ref `" + path + "`: " + e.to_string())
  }
  let hash = content.trim().to_string()
  if hash.length() == 0 {
    return Err("ref `" + path + "` is empty")
  }
  let _ = @bit.ObjectId::from_hex(hash) catch {
    e => return Err("invalid ref hash `" + hash + "`: " + e.to_string())
  }
  Ok(hash)
}

///|
fn write_git_blob_bytes(
  git_dir : String,
  payload : Bytes,
) -> Result[String, String] {
  let objects_dir = git_dir + "/objects"
  match ensure_dir_recursive(objects_dir) {
    Ok(_) => ()
    Err(err) => return Err(err)
  }
  let fs = @osfs.OsFs::new()
  let (obj_id, compressed) = @bit.create_blob(payload)
  @gitlib.write_object_bytes(fs, git_dir, obj_id, compressed) catch {
    e => return Err("write git object: " + e.to_string())
  }
  Ok(obj_id.to_hex())
}

///|
fn load_git_blob_bytes(
  git_dir : String,
  hash : String,
) -> Result[Bytes, String] {
  let objects_dir = git_dir + "/objects"
  if not(@os_fs.path_exists(objects_dir)) {
    return Err("git objects dir not found: " + objects_dir)
  }
  let fs = @osfs.OsFs::new()
  let db = @gitlib.ObjectDb::load_lazy(fs, git_dir) catch {
    e => return Err("load git object db: " + e.to_string())
  }
  let obj_id = @bit.ObjectId::from_hex(hash) catch {
    e => return Err("invalid object hash `" + hash + "`: " + e.to_string())
  }
  let obj = db.get(fs, obj_id) catch {
    e => return Err("read git object `" + hash + "`: " + e.to_string())
  }
  match obj {
    Some(pack_obj) => Ok(pack_obj.data)
    None => Err("git object not found: " + hash)
  }
}

///|
pub fn write_advanced_graph_index_to_git_ref(
  git_dir : String,
  scope : String,
  index : AdvancedGraphIndex,
) -> Result[String, String] {
  let scope = match normalize_ref_scope(scope) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let hash = match write_git_blob_bytes(git_dir, index.to_cbor_bytes()) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  match write_ref_hash(distributed_graph_head_ref_path(git_dir, scope), hash) {
    Ok(_) => ()
    Err(err) => return Err(err)
  }
  Ok(hash)
}

///|
pub fn read_advanced_graph_index_from_git_ref(
  git_dir : String,
  scope : String,
) -> Result[AdvancedGraphIndex, String] {
  let scope = match normalize_ref_scope(scope) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let hash = match
    read_ref_hash(distributed_graph_head_ref_path(git_dir, scope)) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let payload = match load_git_blob_bytes(git_dir, hash) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  match advanced_graph_index_from_cbor_bytes(payload) {
    Ok(v) => Ok(v)
    Err(err) => Err("decode index from git ref: " + err)
  }
}

///|
pub fn write_advanced_graph_delta_to_git_ref(
  git_dir : String,
  scope : String,
  delta : AdvancedGraphDelta,
) -> Result[String, String] {
  let scope = match normalize_ref_scope(scope) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let delta_hash = match write_git_blob_bytes(git_dir, delta.to_cbor_bytes()) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let ref_path = distributed_graph_wal_head_ref_path(git_dir, scope)
  let prev_hash = match try_read_ref_hash(ref_path) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let node_payload = encode_delta_chain_node_payload(delta_hash, prev_hash)
  let node_hash = match write_git_blob_bytes(git_dir, node_payload) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  match write_ref_hash(ref_path, node_hash) {
    Ok(_) => ()
    Err(err) => return Err(err)
  }
  Ok(node_hash)
}

///|
fn try_read_ref_hash(path : String) -> Result[String?, String] {
  if not(@os_fs.path_exists(path)) {
    return Ok(None)
  }
  match read_ref_hash(path) {
    Ok(hash) => Ok(Some(hash))
    Err(err) => Err(err)
  }
}

///|
fn validate_hex_hash(hash : String, field : String) -> Result[String, String] {
  let normalized = hash.trim().to_string()
  if normalized.length() == 0 {
    return Err(field + " must not be empty")
  }
  let _ = @bit.ObjectId::from_hex(normalized) catch {
    e => return Err(field + " is not a valid object hash: " + e.to_string())
  }
  Ok(normalized)
}

///|
fn encode_delta_chain_node_payload(
  delta_hash : String,
  prev_hash : String?,
) -> Bytes {
  let obj : Map[String, Json] = {}
  obj["kind"] = Json::string(distributed_graph_delta_chain_kind())
  obj["delta_hash"] = Json::string(delta_hash)
  obj["prev"] = match prev_hash {
    Some(hash) => Json::string(hash)
    None => Json::null()
  }
  @utf8.encode(Json::object(obj).stringify())
}

///|
fn parse_delta_chain_node_payload(
  payload : Bytes,
) -> Result[(String, String?), String]? {
  let text = @utf8.decode_lossy(payload[:])
  let json : Json = @json.parse(text) catch { _ => return None }
  match json {
    Json::Object(obj) => {
      let kind = match obj.get("kind") {
        Some(Json::String(v)) => v
        _ => return None
      }
      if kind != distributed_graph_delta_chain_kind() {
        return None
      }
      let delta_hash = match obj.get("delta_hash") {
        Some(Json::String(v)) =>
          match validate_hex_hash(v, "delta_hash") {
            Ok(hash) => hash
            Err(err) => return Some(Err(err))
          }
        Some(_) => return Some(Err("delta_hash must be string"))
        None => return Some(Err("missing delta_hash"))
      }
      let prev_hash = match obj.get("prev") {
        Some(Json::String(v)) =>
          match validate_hex_hash(v, "prev") {
            Ok(hash) => Some(hash)
            Err(err) => return Some(Err(err))
          }
        Some(Json::Null) | None => None
        Some(_) => return Some(Err("prev must be string or null"))
      }
      Some(Ok((delta_hash, prev_hash)))
    }
    _ => None
  }
}

///|
fn decode_delta_payload_from_bytes(
  payload : Bytes,
) -> Result[AdvancedGraphDelta, String] {
  match advanced_graph_delta_from_cbor_bytes(payload) {
    Ok(v) => Ok(v)
    Err(err) => Err("decode delta from git ref: " + err)
  }
}

///|
fn read_delta_payload_from_hash(
  git_dir : String,
  hash : String,
) -> Result[AdvancedGraphDelta, String] {
  let payload = match load_git_blob_bytes(git_dir, hash) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  decode_delta_payload_from_bytes(payload)
}

///|
pub fn read_advanced_graph_delta_from_git_ref(
  git_dir : String,
  scope : String,
) -> Result[AdvancedGraphDelta, String] {
  let scope = match normalize_ref_scope(scope) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let hash = match
    read_ref_hash(distributed_graph_wal_head_ref_path(git_dir, scope)) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let payload = match load_git_blob_bytes(git_dir, hash) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  match parse_delta_chain_node_payload(payload) {
    Some(Ok((delta_hash, _))) =>
      read_delta_payload_from_hash(git_dir, delta_hash)
    Some(Err(err)) => Err("decode wal_head chain node: " + err)
    None => decode_delta_payload_from_bytes(payload)
  }
}

///|
pub fn read_advanced_graph_delta_chain_from_git_ref(
  git_dir : String,
  scope : String,
) -> Result[Array[AdvancedGraphDelta], String] {
  let scope = match normalize_ref_scope(scope) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let ref_path = distributed_graph_wal_head_ref_path(git_dir, scope)
  let head_hash = match read_ref_hash(ref_path) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let visited : Map[String, Bool] = {}
  let deltas_rev : Array[AdvancedGraphDelta] = []
  let mut cursor : String? = Some(head_hash)
  while true {
    match cursor {
      Some(current) => {
        if visited.contains(current) {
          return Err("wal_head chain contains cycle at " + current)
        }
        visited[current] = true
        let payload = match load_git_blob_bytes(git_dir, current) {
          Ok(v) => v
          Err(err) => return Err(err)
        }
        match parse_delta_chain_node_payload(payload) {
          Some(Ok((delta_hash, prev_hash))) => {
            let delta = match
              read_delta_payload_from_hash(git_dir, delta_hash) {
              Ok(v) => v
              Err(err) => return Err(err)
            }
            deltas_rev.push(delta)
            cursor = prev_hash
          }
          Some(Err(err)) => return Err("decode wal_head chain node: " + err)
          None => {
            let delta = match decode_delta_payload_from_bytes(payload) {
              Ok(v) => v
              Err(err) => return Err(err)
            }
            deltas_rev.push(delta)
            cursor = None
          }
        }
      }
      None => break
    }
  }
  let deltas : Array[AdvancedGraphDelta] = []
  let mut i = deltas_rev.length()
  while i > 0 {
    i -= 1
    deltas.push(deltas_rev[i])
  }
  Ok(deltas)
}
