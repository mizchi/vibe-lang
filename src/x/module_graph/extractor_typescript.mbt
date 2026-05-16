///|
/// Heuristic line-scanner for TypeScript/JavaScript.
/// Extracts top-level function, class, interface, type, enum, const/let declarations.
pub fn extract_typescript_graph_ir_rows(
  path : String,
  source : String,
) -> Array[GraphIrRow] {
  let rows : Array[GraphIrRow] = []
  let module_hash = @core.content_address_hash_string(source)
  let language_id = if path.to_lower().has_suffix(".ts") ||
    path.to_lower().has_suffix(".tsx") {
    "typescript"
  } else {
    "javascript"
  }
  let lines = source.split("\n")
  let mut offset = 0
  for line_view in lines {
    let line = line_view.to_owned()
    let trimmed = ts_trim_start(line)
    let line_start = offset
    let line_end = offset + line.length()
    // Skip empty lines, comments, imports
    if trimmed.length() > 0 &&
      !trimmed.has_prefix("//") &&
      !trimmed.has_prefix("/*") &&
      !trimmed.has_prefix("*") &&
      !trimmed.has_prefix("import ") {
      // Strip leading export/declare/async/default keywords
      let stripped = ts_strip_modifiers(trimmed)
      match ts_try_extract_declaration(stripped) {
        Some((kind, name, signature)) =>
          rows.push(GraphIrRow::{
            language_id,
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
    // +1 for newline
    offset = line_end + 1
  }
  rows
}

///|
fn ts_trim_start(s : String) -> String {
  let len = s.length()
  let mut i = 0
  while i < len {
    let ch = s.unsafe_get(i).to_int().unsafe_to_char()
    if ch == ' ' || ch == '\t' {
      i = i + 1
    } else {
      break
    }
  }
  if i == 0 {
    s
  } else {
    s.unsafe_substring(start=i, end=len)
  }
}

///|
fn ts_strip_modifiers(s : String) -> String {
  let mut cur = s
  let modifiers = [
    "export default ", "export ", "declare ", "async ", "abstract ",
  ]
  let mut changed = true
  while changed {
    changed = false
    for modifier in modifiers {
      if cur.has_prefix(modifier[:]) {
        cur = cur.unsafe_substring(start=modifier.length(), end=cur.length())
        changed = true
      }
    }
  }
  cur
}

///|
fn ts_try_extract_declaration(line : String) -> (String, String, String)? {
  if line.has_prefix("function ") ||
    line.has_prefix("function*(") ||
    line.has_prefix("function*") {
    let rest = if line.has_prefix("function*") {
      line.unsafe_substring(start=9, end=line.length())
    } else {
      line.unsafe_substring(start=9, end=line.length())
    }
    let name = ts_extract_identifier(ts_trim_start(rest))
    if name.length() > 0 {
      return Some(("function", name, ts_extract_signature(line)))
    }
  }
  if line.has_prefix("class ") {
    let rest = line.unsafe_substring(start=6, end=line.length())
    let name = ts_extract_identifier(rest)
    if name.length() > 0 {
      return Some(("class", name, ts_extract_signature(line)))
    }
  }
  if line.has_prefix("interface ") {
    let rest = line.unsafe_substring(start=10, end=line.length())
    let name = ts_extract_identifier(rest)
    if name.length() > 0 {
      return Some(("interface", name, ts_extract_signature(line)))
    }
  }
  if line.has_prefix("type ") {
    let rest = line.unsafe_substring(start=5, end=line.length())
    let name = ts_extract_identifier(rest)
    if name.length() > 0 {
      return Some(("type", name, ts_extract_signature(line)))
    }
  }
  if line.has_prefix("enum ") {
    let rest = line.unsafe_substring(start=5, end=line.length())
    let name = ts_extract_identifier(rest)
    if name.length() > 0 {
      return Some(("enum", name, ts_extract_signature(line)))
    }
  }
  if line.has_prefix("const ") {
    let rest = line.unsafe_substring(start=6, end=line.length())
    let name = ts_extract_identifier(rest)
    if name.length() > 0 {
      return Some(("const", name, ts_extract_signature(line)))
    }
  }
  if line.has_prefix("let ") {
    let rest = line.unsafe_substring(start=4, end=line.length())
    let name = ts_extract_identifier(rest)
    if name.length() > 0 {
      return Some(("let", name, ts_extract_signature(line)))
    }
  }
  if line.has_prefix("var ") {
    let rest = line.unsafe_substring(start=4, end=line.length())
    let name = ts_extract_identifier(rest)
    if name.length() > 0 {
      return Some(("var", name, ts_extract_signature(line)))
    }
  }
  None
}

///|
fn ts_extract_identifier(s : String) -> String {
  let buf = StringBuilder::new()
  for c in s {
    if (c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') ||
      (c >= '0' && c <= '9') ||
      c == '_' ||
      c == '$' {
      buf.write_char(c)
    } else {
      break
    }
  }
  buf.to_string()
}

///|
fn ts_extract_signature(line : String) -> String {
  // Use first line up to opening brace as signature
  let len = line.length()
  let mut end = len
  for i in 0..<len {
    let ch = line.unsafe_get(i).to_int().unsafe_to_char()
    if ch == '{' {
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
