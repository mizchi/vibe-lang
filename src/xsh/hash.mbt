///| Git blob compatible hash helpers

///| Compute Git blob hash (sha1) for UTF-8 text content.
pub fn git_blob_hash_string(content : String) -> String {
  let bytes = @utf8.encode(content)
  let header = "blob " + bytes.length().to_string() + "\u0000"
  let hasher = @bit.Sha1State::new()
  hasher.update_string(header)
  hasher.update(bytes)
  hasher.finish().to_hex()
}

///| Build canonical module reference for a hash.
pub fn module_ref_from_hash(hash : String) -> String {
  "ko-doha/xsh/" + hash
}
