///|
enum CompletionContext {
  Shell
  VibeLetName
  VibeLetExpr
  VibeExpr
} derive(Show, Eq)

///|
struct TokenSpan {
  text : String
  end : Int
}

///|
fn is_space_char(c : Char) -> Bool {
  c == ' ' || c == '\t'
}

///|
fn is_ident_char(c : Char) -> Bool {
  let code = c.to_int()
  (code >= 48 && code <= 57) ||
  (code >= 65 && code <= 90) ||
  (code >= 97 && code <= 122) ||
  code == 95
}

///|
fn tokenize_line(line : String) -> Array[TokenSpan] {
  let chars = line.to_array()
  let tokens : Array[TokenSpan] = []
  let sb = StringBuilder::new()
  let mut start = -1
  let mut i = 0
  while i < chars.length() {
    let c = chars[i]
    if is_space_char(c) {
      if start >= 0 {
        tokens.push({ text: sb.to_string(), end: i })
        sb.reset()
        start = -1
      }
    } else {
      if start < 0 {
        start = i
      }
      sb.write_char(c)
    }
    i += 1
  }
  if start >= 0 {
    tokens.push({ text: sb.to_string(), end: chars.length() })
  }
  tokens
}

///|
fn detect_let_context(
  line : String,
  col : Int,
  let_end : Int,
) -> CompletionContext {
  let chars = line.to_array()
  let limit = if col < chars.length() { col } else { chars.length() }
  let mut i = if let_end < 0 { 0 } else { let_end }
  while i < limit {
    if chars[i] == '=' {
      return CompletionContext::VibeLetExpr
    }
    i += 1
  }
  CompletionContext::VibeLetName
}

///|
fn detect_completion_context(line : String, col : Int) -> CompletionContext {
  let tokens = tokenize_line(line)
  if tokens.length() == 0 {
    return CompletionContext::Shell
  }
  let first = tokens[0]
  if first.text == "let" {
    return detect_let_context(line, col, first.end)
  }
  let safe_col = if col < 0 { 0 } else { col }
  if safe_col <= first.end {
    return CompletionContext::Shell
  }
  if tokens.length() >= 2 {
    let vibe_token = tokens[1]
    if vibe_token.text == "let" {
      return detect_let_context(line, col, vibe_token.end)
    }
    return CompletionContext::VibeExpr
  }
  CompletionContext::Shell
}

///|
fn is_in_fn_param_context(line : String, col : Int) -> Bool {
  let chars = line.to_array()
  let limit = if col < chars.length() { col } else { chars.length() }
  if limit < 2 {
    return false
  }
  let mut last_fn = -1
  for i in 0..<(limit - 1) {
    if chars[i] == 'f' && chars[i + 1] == 'n' {
      let prev_ok = if i == 0 { true } else { not(is_ident_char(chars[i - 1])) }
      let next_ok = if i + 2 >= chars.length() {
        true
      } else {
        not(is_ident_char(chars[i + 2]))
      }
      if prev_ok && next_ok {
        last_fn = i
      }
    }
  }
  if last_fn < 0 {
    return false
  }
  let mut j = last_fn + 2
  while j < chars.length() && is_space_char(chars[j]) {
    j += 1
  }
  if j >= chars.length() || chars[j] != '(' {
    return false
  }
  if col <= j + 1 {
    return true
  }
  let mut depth = 0
  let mut k = j + 1
  while k < limit {
    let c = chars[k]
    if c == '(' {
      depth += 1
    } else if c == ')' {
      if depth == 0 {
        return false
      }
      depth -= 1
    }
    k += 1
  }
  true
}

///|
struct MethodCompletion {
  receiver : String
  prefix : String
}

///|
struct PipeCompletion {
  receiver : String
  prefix : String
}

///|
fn detect_method_completion(line : String, col : Int) -> MethodCompletion? {
  let chars = line.to_array()
  let limit = if col < chars.length() { col } else { chars.length() }
  if limit <= 0 {
    return None
  }
  let mut start = limit
  while start > 0 && is_ident_char(chars[start - 1]) {
    start -= 1
  }
  if start <= 0 {
    return None
  }
  if chars[start - 1] != '.' {
    return None
  }
  let recv_end = start - 1
  let mut recv_start = recv_end
  while recv_start > 0 && is_ident_char(chars[recv_start - 1]) {
    recv_start -= 1
  }
  if recv_start == recv_end {
    return None
  }
  let receiver_chars : Array[Char] = []
  for i in recv_start..<recv_end {
    receiver_chars.push(chars[i])
  }
  let prefix_chars : Array[Char] = []
  for i in start..<limit {
    prefix_chars.push(chars[i])
  }
  Some(MethodCompletion::{
    receiver: String::from_array(receiver_chars),
    prefix: String::from_array(prefix_chars),
  })
}

///|
fn detect_pipe_completion(line : String, col : Int) -> PipeCompletion? {
  let chars = line.to_array()
  let limit = if col < chars.length() { col } else { chars.length() }
  if limit < 2 {
    return None
  }
  let mut i = limit - 1
  let mut pipe_pos = -1
  while i > 0 {
    if chars[i - 1] == '|' && chars[i] == '>' {
      pipe_pos = i - 1
      break
    }
    i -= 1
  }
  if pipe_pos < 0 {
    return None
  }
  let mut recv_end = pipe_pos
  while recv_end > 0 && is_space_char(chars[recv_end - 1]) {
    recv_end -= 1
  }
  let mut recv_start = recv_end
  while recv_start > 0 && is_ident_char(chars[recv_start - 1]) {
    recv_start -= 1
  }
  if recv_start == recv_end {
    return None
  }
  let mut pref_start = pipe_pos + 2
  while pref_start < limit && is_space_char(chars[pref_start]) {
    pref_start += 1
  }
  if pref_start > limit {
    return None
  }
  let mut pref_end = pref_start
  while pref_end < limit && is_ident_char(chars[pref_end]) {
    pref_end += 1
  }
  let receiver_chars : Array[Char] = []
  for idx in recv_start..<recv_end {
    receiver_chars.push(chars[idx])
  }
  let prefix_chars : Array[Char] = []
  for idx in pref_start..<pref_end {
    prefix_chars.push(chars[idx])
  }
  Some(PipeCompletion::{
    receiver: String::from_array(receiver_chars),
    prefix: String::from_array(prefix_chars),
  })
}

///|
fn extract_let_name(line : String) -> String? {
  let trimmed = line.trim().to_string()
  if trimmed.length() < 4 || not(trimmed.has_prefix("let")) {
    return None
  }
  let chars = trimmed.to_array()
  if chars.length() < 4 {
    return None
  }
  let mut i = 3
  if i >= chars.length() || not(is_space_char(chars[i])) {
    return None
  }
  while i < chars.length() && is_space_char(chars[i]) {
    i += 1
  }
  if i + 2 < chars.length() &&
    chars[i] == 'r' &&
    chars[i + 1] == 'e' &&
    chars[i + 2] == 'c' &&
    (i + 3 >= chars.length() || is_space_char(chars[i + 3])) {
    i += 3
    while i < chars.length() && is_space_char(chars[i]) {
      i += 1
    }
  }
  let start = i
  while i < chars.length() && is_ident_char(chars[i]) {
    i += 1
  }
  if i == start {
    return None
  }
  let out : Array[Char] = []
  let mut j = start
  while j < i {
    out.push(chars[j])
    j += 1
  }
  Some(String::from_array(out))
}
