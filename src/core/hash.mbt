///| Git blob compatible hash helpers

///|
/// Compute Git blob hash (sha1) for UTF-8 text content.
pub fn git_blob_hash_string(content : String) -> String {
  let bytes = @utf8.encode(content)
  let header = "blob " + bytes.length().to_string() + "\u0000"
  let hasher = @bit.Sha1State::new()
  hasher.update_string(header)
  hasher.update(bytes)
  hasher.finish().to_hex()
}

///|
/// Compute Git blob hash (sha1) for binary content.
pub fn git_blob_hash_bytes(content : Bytes) -> String {
  let header = "blob " + content.length().to_string() + "\u0000"
  let hasher = @bit.Sha1State::new()
  hasher.update_string(header)
  hasher.update(content)
  hasher.finish().to_hex()
}

///|
/// Build canonical module reference for a hash.
pub fn module_ref_from_hash(hash : String) -> String {
  "ko-doha/xsh/" + hash
}

///|
/// Compute content-addressed hash for a module AST.
/// This normalizes the AST (alpha-conversion, span removal) before hashing.
pub fn hash_module(m : Module) -> String {
  let normalized = normalize_module(m)
  let json = serialize_module(normalized)
  git_blob_hash_string(json)
}

///|
/// Short hash (first 8 characters) for display
pub fn short_hash(hash : String) -> String {
  if hash.length() >= 8 {
    hash.unsafe_substring(start=0, end=8)
  } else {
    hash
  }
}
