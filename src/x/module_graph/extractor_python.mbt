///|
/// Heuristic line-scanner for Python.
/// Extracts top-level def, class, and variable assignments (indent == 0).
pub fn extract_python_graph_ir_rows(
  path : String,
  source : String,
) -> Array[GraphIrRow] {
  let rows : Array[GraphIrRow] = []
  let module_hash = @core.content_address_hash_string(source)
  let lines = source.split("\n")
  let mut offset = 0
  for line_view in lines {
    let line = line_view.to_owned()
    let line_start = offset
    let line_end = offset + line.length()
    // Only process lines at indent level 0 (no leading whitespace)
    if line.length() > 0 && !py_is_whitespace_char(line, 0) {
      let trimmed = line
      // Skip comments, blank, imports
      if !trimmed.has_prefix("#") &&
        !trimmed.has_prefix("import ") &&
        !trimmed.has_prefix("from ") {
        match py_try_extract_declaration(trimmed) {
          Some((kind, name, signature)) =>
            rows.push(GraphIrRow::{
              language_id: "python",
              path,
              name,
              kind,
              signature,
              start: line_start,
              end: line_end,
              module_hash,
              type_terms: ml_extract_type_terms_from_signature(signature),
              refs: [],
              calls: [],
              imports: [],
            })
          None => ()
        }
      }
    }
    offset = line_end + 1
  }
  rows
}

///|
fn py_is_whitespace_char(s : String, i : Int) -> Bool {
  if i >= s.length() {
    return false
  }
  let ch = s.unsafe_get(i).to_int().unsafe_to_char()
  ch == ' ' || ch == '\t'
}

///|
fn py_try_extract_declaration(line : String) -> (String, String, String)? {
  // async def / def
  let rest = if line.has_prefix("async def ") {
    Some(("function", line.unsafe_substring(start=10, end=line.length())))
  } else if line.has_prefix("def ") {
    Some(("function", line.unsafe_substring(start=4, end=line.length())))
  } else {
    None
  }
  match rest {
    Some((kind, name_part)) => {
      let name = py_extract_identifier(name_part)
      if name.length() > 0 {
        return Some((kind, name, py_extract_signature(line)))
      }
    }
    None => ()
  }
  // class
  if line.has_prefix("class ") {
    let name_part = line.unsafe_substring(start=6, end=line.length())
    let name = py_extract_identifier(name_part)
    if name.length() > 0 {
      return Some(("class", name, py_extract_signature(line)))
    }
  }
  // Variable assignment: NAME = ... (uppercase or lowercase, must start with letter/_)
  match py_try_extract_assignment(line) {
    Some(name) => return Some(("variable", name, line))
    None => ()
  }
  // Decorated definitions (@decorator) — skip, the actual def/class follows
  None
}

///|
fn py_extract_identifier(s : String) -> String {
  let buf = StringBuilder::new()
  for c in s {
    if (c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') ||
      (c >= '0' && c <= '9') ||
      c == '_' {
      buf.write_char(c)
    } else {
      break
    }
  }
  buf.to_string()
}

///|
fn py_extract_signature(line : String) -> String {
  // Use line up to colon as signature
  let len = line.length()
  let mut end = len
  for i in 0..<len {
    let ch = line.unsafe_get(i).to_int().unsafe_to_char()
    if ch == ':' {
      end = i
      break
    }
  }
  let sig = line.unsafe_substring(start=0, end~)
  // Trim trailing whitespace
  let sig_len = sig.length()
  let mut trim_end = sig_len
  while trim_end > 0 {
    let ch = sig.unsafe_get(trim_end - 1).to_int().unsafe_to_char()
    if ch == ' ' || ch == '\t' {
      trim_end = trim_end - 1
    } else {
      break
    }
  }
  if trim_end == sig_len {
    sig
  } else {
    sig.unsafe_substring(start=0, end=trim_end)
  }
}

///|
fn py_try_extract_assignment(line : String) -> String? {
  // Match: identifier = ... (but not ==)
  let name = py_extract_identifier(line)
  if name.length() == 0 {
    return None
  }
  // Check for ' = ' after the identifier
  let after_name = name.length()
  let len = line.length()
  // Skip optional type annotation like : Type
  let mut pos = after_name
  // Skip whitespace
  while pos < len {
    let ch = line.unsafe_get(pos).to_int().unsafe_to_char()
    if ch == ' ' || ch == '\t' {
      pos = pos + 1
    } else {
      break
    }
  }
  if pos >= len {
    return None
  }
  let ch = line.unsafe_get(pos).to_int().unsafe_to_char()
  // Direct assignment: name = ...
  if ch == '=' {
    // Not ==
    if pos + 1 < len &&
      line.unsafe_get(pos + 1).to_int().unsafe_to_char() == '=' {
      return None
    }
    return Some(name)
  }
  // Type annotated: name: Type = ...
  if ch == ':' {
    // Scan forward to find '='
    let mut j = pos + 1
    while j < len {
      let c = line.unsafe_get(j).to_int().unsafe_to_char()
      if c == '=' {
        if j + 1 < len &&
          line.unsafe_get(j + 1).to_int().unsafe_to_char() == '=' {
          return None
        }
        return Some(name)
      }
      j = j + 1
    }
  }
  None
}
