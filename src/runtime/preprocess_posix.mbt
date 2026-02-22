///|
/// Preprocess PosixMode source: rewrite command-like lines to sh_lines("...") calls.
/// Handles {{ expr }} interpolation and $() command substitution.
/// Lines starting with keywords, function calls, or assignments are left unchanged.
fn preprocess_posix_source(script : String) -> String {
  let buf = StringBuilder::new()
  let mut first = true
  for line_view in script.split("\n") {
    if not(first) {
      buf.write_char('\n')
    }
    first = false
    buf.write_string(preprocess_posix_line(line_view.to_string()))
  }
  buf.to_string()
}

///|
fn chars_slice(chars : Array[Char], start : Int, end : Int) -> String {
  let buf = StringBuilder::new()
  let mut i = start
  while i < end {
    buf.write_char(chars[i])
    i = i + 1
  }
  buf.to_string()
}

///|
fn is_posix_operator_char(c : Char) -> Bool {
  c == '|' ||
  c == '+' ||
  c == '*' ||
  c == '%' ||
  c == '^' ||
  c == '&' ||
  c == '.' ||
  c == ')' ||
  c == ']' ||
  c == '{' ||
  c == ';' ||
  c == ':' ||
  c == ','
}

///|
fn preprocess_posix_line(line : String) -> String {
  let chars = line.to_array()
  let len = chars.length()
  // Skip leading whitespace
  let mut ws_end = 0
  while ws_end < len && (chars[ws_end] == ' ' || chars[ws_end] == '\t') {
    ws_end = ws_end + 1
  }
  if ws_end == len {
    return line
  }
  let first_char = chars[ws_end]
  if not(
      (first_char >= 'a' && first_char <= 'z') ||
      (first_char >= 'A' && first_char <= 'Z') ||
      first_char == '_',
    ) {
    return line
  }
  // Extract first word
  let mut word_end = ws_end
  while word_end < len && chars[word_end] != ' ' && chars[word_end] != '\t' {
    word_end = word_end + 1
  }
  let first_word = chars_slice(chars, ws_end, word_end)
  if is_posix_keyword(first_word) {
    return line
  }
  // Skip whitespace after first word
  let mut rest_start = word_end
  while rest_start < len &&
        (chars[rest_start] == ' ' || chars[rest_start] == '\t') {
    rest_start = rest_start + 1
  }
  // No arguments → leave for existing desugar
  if rest_start >= len {
    return line
  }
  let c = chars[rest_start]
  if c == '(' {
    return line
  }
  if c == '=' && (rest_start + 1 >= len || chars[rest_start + 1] != '=') {
    return line
  }
  if is_posix_operator_char(c) {
    return line
  }
  // Command with arguments → wrap in sh_lines(...)
  let leading = chars_slice(chars, 0, ws_end)
  let content = chars_slice(chars, ws_end, len)
  leading + convert_posix_command(content)
}

///|
fn is_posix_keyword(word : String) -> Bool {
  let keywords : Array[String] = [
    "let", "if", "else", "while", "for", "match", "test", "bench", "type", "enum",
    "export", "use", "fn", "do", "return", "break", "continue", "rec", "mut", "handle",
    "raise", "yield", "impl", "trait", "struct", "declare", "import", "from", "as",
    "loop", "true", "false",
  ]
  for kw in keywords {
    if word == kw {
      return true
    }
  }
  false
}

///|
/// Scan {{ expr }} interpolation. Returns (replacement, next_pos) or None.
fn scan_brace_interp(chars : Array[Char], i : Int, len : Int) -> (String, Int)? {
  if i + 1 >= len || chars[i] != '{' || chars[i + 1] != '{' {
    return None
  }
  let start = i + 2
  let mut j = start
  let mut depth = 1
  while j + 1 < len && depth > 0 {
    if chars[j] == '{' && chars[j + 1] == '{' {
      depth = depth + 1
      j = j + 2
    } else if chars[j] == '}' && chars[j + 1] == '}' {
      depth = depth - 1
      if depth == 0 {
        break
      }
      j = j + 2
    } else {
      j = j + 1
    }
  }
  if depth != 0 {
    return None
  }
  let expr = chars_slice(chars, start, j).trim().to_string()
  Some(("\\(" + expr + ")", j + 2))
}

///|
/// Scan $() command substitution. Returns (replacement, next_pos) or None.
fn scan_cmd_subst(chars : Array[Char], i : Int, len : Int) -> (String, Int)? {
  if i + 1 >= len || chars[i] != '$' || chars[i + 1] != '(' {
    return None
  }
  let start = i + 2
  let mut j = start
  let mut depth = 1
  while j < len && depth > 0 {
    if chars[j] == '(' {
      depth = depth + 1
    } else if chars[j] == ')' {
      depth = depth - 1
    }
    if depth > 0 {
      j = j + 1
    }
  }
  if depth != 0 {
    return None
  }
  let cmd = chars_slice(chars, start, j).trim().to_string()
  let escaped = escape_posix_for_vibe_string(cmd)
  let s = "\\(do { match sh_lines(\"" +
    escaped +
    "\") { r if array_length(r) > 0 => array_get(r, 0), _ => \"\" } })"
  Some((s, j + 1))
}

///|
/// Convert a command line to sh_lines("...") with interpolation support.
fn convert_posix_command(content : String) -> String {
  let chars = content.to_array()
  let len = chars.length()
  let buf = StringBuilder::new()
  buf.write_string("sh_lines(\"")
  let mut i = 0
  while i < len {
    match scan_brace_interp(chars, i, len) {
      Some((s, next)) => {
        buf.write_string(s)
        i = next
        continue
      }
      None => ()
    }
    match scan_cmd_subst(chars, i, len) {
      Some((s, next)) => {
        buf.write_string(s)
        i = next
        continue
      }
      None => ()
    }
    let c = chars[i]
    if c == '\\' {
      buf.write_string("\\\\")
    } else if c == '"' {
      buf.write_string("\\\"")
    } else {
      buf.write_char(c)
    }
    i = i + 1
  }
  buf.write_string("\")")
  buf.to_string()
}

///|
fn escape_posix_for_vibe_string(s : String) -> String {
  let chars = s.to_array()
  let buf = StringBuilder::new()
  for c in chars {
    if c == '\\' {
      buf.write_string("\\\\")
    } else if c == '"' {
      buf.write_string("\\\"")
    } else {
      buf.write_char(c)
    }
  }
  buf.to_string()
}
