///| Git blob compatible hash helpers

///|
/// Compute Git blob hash (sha1) for UTF-8 text content.
/// Avoids intermediate Bytes allocation by computing UTF-8 byte length
/// separately and feeding bytes directly to the hasher.
pub fn git_blob_hash_string(content : String) -> String {
  let byte_len = utf8_byte_length(content)
  let header = "blob " + byte_len.to_string() + "\u0000"
  let hasher = @bit.Sha1State::new()
  hasher.update_string(header)
  sha1_update_utf8(hasher, content)
  hasher.finish().to_hex()
}

///|
/// Compute UTF-8 byte length of a string without allocating a Bytes buffer.
fn utf8_byte_length(s : String) -> Int {
  let mut len = 0
  for c in s {
    let cp = c.to_int()
    if cp < 0x80 {
      len += 1
    } else if cp < 0x800 {
      len += 2
    } else if cp < 0x10000 {
      len += 3
    } else {
      len += 4
    }
  }
  len
}

///|
/// Feed a string's UTF-8 bytes directly to a SHA1 hasher without Bytes allocation.
fn sha1_update_utf8(hasher : @bit.Sha1State, s : String) -> Unit {
  for c in s {
    let cp = c.to_int()
    if cp < 0x80 {
      hasher.update_byte(cp.to_byte())
    } else if cp < 0x800 {
      hasher.update_byte((0xC0 | (cp >> 6)).to_byte())
      hasher.update_byte((0x80 | (cp & 0x3F)).to_byte())
    } else if cp < 0x10000 {
      hasher.update_byte((0xE0 | (cp >> 12)).to_byte())
      hasher.update_byte((0x80 | ((cp >> 6) & 0x3F)).to_byte())
      hasher.update_byte((0x80 | (cp & 0x3F)).to_byte())
    } else {
      hasher.update_byte((0xF0 | (cp >> 18)).to_byte())
      hasher.update_byte((0x80 | ((cp >> 12) & 0x3F)).to_byte())
      hasher.update_byte((0x80 | ((cp >> 6) & 0x3F)).to_byte())
      hasher.update_byte((0x80 | (cp & 0x3F)).to_byte())
    }
  }
}

///|
fn content_hash_collect_line_starts(source : String) -> Array[Int] {
  let starts : Array[Int] = [0]
  for i, c in source {
    if c == '\n' && i + 1 < source.length() {
      starts.push(i + 1)
    }
  }
  starts
}

///|
fn content_hash_source_line_text(
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
fn content_hash_line_is_blank(line : String) -> Bool {
  for c in line {
    if c != ' ' && c != '\t' && c != '\r' {
      return false
    }
  }
  true
}

///|
fn content_hash_line_is_section_separator(line : String) -> Bool {
  let mut i = 0
  while i < line.length() {
    let c = line[i].to_int().unsafe_to_char()
    if c == ' ' || c == '\t' || c == '\r' {
      i += 1
      continue
    }
    if c != '/' || i + 2 >= line.length() {
      return false
    }
    let c1 = line[i + 1].to_int().unsafe_to_char()
    let c2 = line[i + 2].to_int().unsafe_to_char()
    return c1 == '/' && c2 == '#'
  }
  false
}

///|
/// Remove normalize section separators (`//# ...`) from source text and
/// collapse duplicate blank lines introduced by those separators.
pub fn normalize_content_address_source(source : String) -> String {
  if !source.contains("//#") {
    return source
  }
  let line_starts = content_hash_collect_line_starts(source)
  let out = StringBuilder::new()
  let mut wrote = false
  let mut prev_blank = false
  for i in 0..<line_starts.length() {
    let line = content_hash_source_line_text(source, line_starts, i)
    if content_hash_line_is_section_separator(line) {
      continue
    }
    let blank = content_hash_line_is_blank(line)
    if blank && prev_blank {
      continue
    }
    if wrote {
      out.write_char('\n')
    }
    out.write_string(line)
    wrote = true
    prev_blank = blank
  }
  if source.has_suffix("\n") && wrote {
    out.write_char('\n')
  }
  out.to_string()
}

///|
/// Compute content-address hash for source text with normalize section
/// separators ignored.
pub fn content_address_hash_string(source : String) -> String {
  git_blob_hash_string(normalize_content_address_source(source))
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
  "ko-doha/vibe/" + hash
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
