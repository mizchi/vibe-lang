///| Lexer for vibe

///|
/// Lexer state
pub struct Lexer {
  input : String
  mut pos : Int
} derive(Show)

///|
pub fn Lexer::new(input : String) -> Lexer {
  Lexer::{ input, pos: 0 }
}

///|
fn Lexer::peek(self : Lexer) -> Char? {
  if self.pos >= self.input.length() {
    None
  } else {
    Some(self.input[self.pos].to_int().unsafe_to_char())
  }
}

///|
fn Lexer::advance(self : Lexer) -> Char? {
  match self.peek() {
    Some(c) => {
      self.pos += 1
      Some(c)
    }
    None => None
  }
}

///|
fn is_alpha(c : Char) -> Bool {
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'
}

///|
fn is_digit(c : Char) -> Bool {
  c >= '0' && c <= '9'
}

///|
fn is_hex_digit(c : Char) -> Bool {
  (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
}

///|
fn is_alnum(c : Char) -> Bool {
  is_alpha(c) || is_digit(c)
}

///|
fn is_ident_extra(c : Char) -> Bool {
  c == '#' || c == '?' || c == '~' || c == '@'
}

///|
fn parse_raw_identifier(text : String) -> String? {
  if text.length() < 3 {
    return None
  }
  if text[0] != 'r' || text[1] != '#' {
    return None
  }
  let body = text.unsafe_substring(start=2, end=text.length())
  if body.length() == 0 {
    return None
  }
  let first = body[0].to_int().unsafe_to_char()
  if not(is_alpha(first)) {
    return None
  }
  let mut i = 1
  while i < body.length() {
    let c = body[i].to_int().unsafe_to_char()
    if not(is_alnum(c) || c == '_') {
      return None
    }
    i += 1
  }
  Some(body)
}

///|
fn is_ident_delim(c : Char) -> Bool {
  is_whitespace_char(c) ||
  c == '\n' ||
  c == '(' ||
  c == ')' ||
  c == '{' ||
  c == '}' ||
  c == '[' ||
  c == ']' ||
  c == ',' ||
  c == ';' ||
  c == '=' ||
  c == ':' ||
  c == '+' ||
  c == '*' ||
  c == '-' ||
  c == '/' ||
  c == '%' ||
  c == '.' ||
  c == '|' ||
  c == '!' ||
  c == '<' ||
  c == '>' ||
  c == '&' ||
  c == '^' ||
  c == '\''
}

///|
fn is_whitespace_char(c : Char) -> Bool {
  c == ' ' || c == '\t'
}

///|
/// Lex a string literal ("...") with basic escapes
fn Lexer::lex_string(self : Lexer) -> Token {
  let start = self.pos
  let _ = self.advance() // opening quote
  let buf = StringBuilder::new()
  let raw = StringBuilder::new()
  let mut has_interp = false
  while (match self.peek() {
          Some('"') => false
          Some(_) => true
          None => false
        }) {
    match self.advance() {
      Some('\\') =>
        match self.peek() {
          Some('(') => {
            has_interp = true
            raw.write_char('\\')
            raw.write_char('(')
            let _ = self.advance()
            let mut depth = 1
            while depth > 0 {
              match self.advance() {
                Some('(') => {
                  depth += 1
                  raw.write_char('(')
                }
                Some(')') => {
                  depth -= 1
                  if depth > 0 {
                    raw.write_char(')')
                  } else {
                    raw.write_char(')')
                  }
                }
                Some(c) => raw.write_char(c)
                None => break
              }
            }
          }
          _ =>
            match self.advance() {
              Some('"') => {
                buf.write_char('"')
                raw.write_char('\\')
                raw.write_char('"')
              }
              Some('\\') => {
                buf.write_char('\\')
                raw.write_char('\\')
                raw.write_char('\\')
              }
              Some('n') => {
                buf.write_char('\n')
                raw.write_char('\\')
                raw.write_char('n')
              }
              Some('t') => {
                buf.write_char('\t')
                raw.write_char('\\')
                raw.write_char('t')
              }
              Some(c) => {
                buf.write_char(c)
                raw.write_char('\\')
                raw.write_char(c)
              }
              None => ()
            }
        }
      Some(c) => {
        buf.write_char(c)
        raw.write_char(c)
      }
      None => ()
    }
  }
  match self.peek() {
    Some('"') => {
      let _ = self.advance()
      let width = self.pos - start
      if has_interp {
        Token::new_with_width(string_interp_lit(), raw.to_string(), width)
      } else {
        Token::new_with_width(string_lit(), buf.to_string(), width)
      }
    }
    _ => Token::new_with_width(error_kind(), buf.to_string(), self.pos - start)
  }
}

///|
/// Lex a char literal ('a') with simple escapes
fn Lexer::lex_char(self : Lexer) -> Token {
  let start = self.pos
  let _ = self.advance() // opening quote
  match self.peek() {
    None => Token::new_with_width(error_kind(), "'", self.pos - start)
    Some('\n') => Token::new_with_width(error_kind(), "'", self.pos - start)
    Some('\\') => {
      let _ = self.advance()
      match self.peek() {
        None => Token::new_with_width(error_kind(), "'", self.pos - start)
        Some(ch) => {
          let c = match ch {
            'n' => '\n'
            't' => '\t'
            'r' => '\r'
            '\'' => '\''
            '\\' => '\\'
            _ => ch
          }
          let _ = self.advance()
          if self.peek() == Some('\'') {
            let _ = self.advance()
            let buf = StringBuilder::new()
            buf.write_char(c)
            Token::new_with_width(char_lit(), buf.to_string(), self.pos - start)
          } else {
            Token::new_with_width(error_kind(), "'", self.pos - start)
          }
        }
      }
    }
    Some(ch) => {
      let _ = self.advance()
      if self.peek() == Some('\'') {
        let _ = self.advance()
        let buf = StringBuilder::new()
        buf.write_char(ch)
        Token::new_with_width(char_lit(), buf.to_string(), self.pos - start)
      } else {
        Token::new_with_width(error_kind(), "'", self.pos - start)
      }
    }
  }
}

///|
/// Lex a single token
pub fn Lexer::next_token(self : Lexer) -> Token {
  match self.peek() {
    None => Token::new(eof(), "")
    Some(c) => {
      if is_whitespace_char(c) {
        let start = self.pos
        while (match self.peek() {
                Some(ch) => is_whitespace_char(ch)
                None => false
              }) {
          let _ = self.advance()
        }
        let text = try { self.input[start:self.pos].to_string() } catch { _ => "" }
        return Token::new(whitespace(), text)
      }
      if c == '\n' {
        let _ = self.advance()
        return Token::new(newline(), "\n")
      }
      if c == '"' {
        return self.lex_string()
      }
      if c == '\'' {
        return self.lex_char()
      }
      if is_alpha(c) {
        let text = self.lex_ident()
        match parse_raw_identifier(text) {
          Some(raw_name) =>
            return Token::new_with_width(name(), raw_name, text.length())
          None => ()
        }
        let kind = match text {
          "let" => let_kw()
          "import" => import_kw()
          "use" => use_kw()
          "declare" => declare_kw()
          "test" => test_kw()
          "if" => if_kw()
          "else" => else_kw()
          "match" => match_kw()
          "record" => record_kw()
          "map" =>
            if self.peek_next_significant_char() == Some('{') {
              map_kw()
            } else {
              name()
            }
          "fn" => fn_kw()
          "rec" => rec_kw()
          "type" => type_kw()
          "enum" => enum_kw()
          "while" => while_kw()
          "loop" =>
            if self.peek_next_significant_char() == Some('{') {
              loop_kw()
            } else {
              name()
            }
          "bench" => bench_kw()
          "mut" => mut_kw()
          "raise" => raise_kw()
          "yield" => yield_kw()
          "handle" => handle_kw()
          "break" => break_kw()
          "continue" => continue_kw()
          "export" => export_kw()
          "from" => from_kw()
          "as" => as_kw()
          "struct" => struct_kw()
          "trait" => trait_kw()
          "impl" => impl_kw()
          "true" => bool_lit()
          "false" => bool_lit()
          _ => name()
        }
        return Token::new(kind, text)
      }
      if is_digit(c) {
        let start = self.pos
        // Check for hex prefix: 0x or 0X
        if c == '0' && self.pos + 1 < self.input.length() {
          let next_c = self.input[self.pos + 1].to_int().unsafe_to_char()
          if next_c == 'x' || next_c == 'X' {
            let _ = self.advance() // consume '0'
            let _ = self.advance() // consume 'x'/'X'
            while (match self.peek() {
                    Some(ch) => is_hex_digit(ch)
                    None => false
                  }) {
              let _ = self.advance()
            }
            let text = try { self.input[start:self.pos].to_string() } catch { _ => "" }
            return Token::new(int_lit(), text)
          }
        }
        while (match self.peek() {
                Some(ch) => is_digit(ch)
                None => false
              }) {
          let _ = self.advance()
        }
        let mut is_float = false
        if self.peek() == Some('.') {
          is_float = true
          let _ = self.advance()
          while (match self.peek() {
                  Some(ch) => is_digit(ch)
                  None => false
                }) {
            let _ = self.advance()
          }
        }
        match self.peek() {
          Some('e') | Some('E') => {
            is_float = true
            let _ = self.advance()
            match self.peek() {
              Some('+') | Some('-') => ignore(self.advance())
              _ => ()
            }
            while (match self.peek() {
                    Some(ch) => is_digit(ch)
                    None => false
                  }) {
              let _ = self.advance()
            }
          }
          _ => ()
        }
        match self.peek() {
          Some('f') | Some('F') => {
            is_float = true
            let _ = self.advance()
          }
          _ => ()
        }
        let text = try { self.input[start:self.pos].to_string() } catch { _ => "" }
        if is_float {
          return Token::new(float_lit(), text)
        }
        return Token::new(int_lit(), text)
      }
      let _ = self.advance()
      match c {
        '=' =>
          match self.peek() {
            Some('>') => {
              let _ = self.advance()
              Token::new(arrow(), "=>")
            }
            Some('=') => {
              let _ = self.advance()
              Token::new(eqeq(), "==")
            }
            _ => Token::new(eq(), "=")
          }
        '-' =>
          match self.peek() {
            Some('=') => {
              let _ = self.advance()
              Token::new(minus_eq(), "-=")
            }
            Some('>') => {
              let _ = self.advance()
              Token::new(thin_arrow(), "->")
            }
            _ => Token::new(minus(), "-")
          }
        ';' => Token::new(semicolon(), ";")
        '{' => Token::new(lbrace(), "{")
        '}' => Token::new(rbrace(), "}")
        '(' => Token::new(lparen(), "(")
        ')' => Token::new(rparen(), ")")
        '[' => Token::new(lbracket(), "[")
        ']' => Token::new(rbracket(), "]")
        ',' => Token::new(comma(), ",")
        ':' =>
          match self.peek() {
            Some(':') => {
              let _ = self.advance()
              Token::new(double_colon(), "::")
            }
            _ => Token::new(colon(), ":")
          }
        '/' =>
          match self.peek() {
            Some('=') => {
              let _ = self.advance()
              Token::new(slash_eq(), "/=")
            }
            Some('/') => {
              let start = self.pos - 1
              let _ = self.advance()
              while (match self.peek() {
                      Some('\n') | None => false
                      _ => true
                    }) {
                let _ = self.advance()
              }
              let text = try { self.input[start:self.pos].to_string() } catch { _ => "" }
              Token::new(comment(), text)
            }
            _ => Token::new(slash(), "/")
          }
        '+' =>
          match self.peek() {
            Some('=') => {
              let _ = self.advance()
              Token::new(plus_eq(), "+=")
            }
            _ => Token::new(plus(), "+")
          }
        '*' =>
          match self.peek() {
            Some('=') => {
              let _ = self.advance()
              Token::new(star_eq(), "*=")
            }
            _ => Token::new(star(), "*")
          }
        '%' =>
          match self.peek() {
            Some('=') => {
              let _ = self.advance()
              Token::new(percent_eq(), "%=")
            }
            _ => Token::new(percent(), "%")
          }
        '!' =>
          match self.peek() {
            Some('=') => {
              let _ = self.advance()
              Token::new(neq(), "!=")
            }
            _ => Token::new(bang(), "!")
          }
        '<' =>
          match self.peek() {
            Some('<') => {
              let _ = self.advance()
              Token::new(lshift(), "<<")
            }
            Some('=') => {
              let _ = self.advance()
              Token::new(lte(), "<=")
            }
            _ => Token::new(lt(), "<")
          }
        '>' =>
          match self.peek() {
            Some('>') => {
              let _ = self.advance()
              Token::new(rshift(), ">>")
            }
            Some('=') => {
              let _ = self.advance()
              Token::new(gte(), ">=")
            }
            _ => Token::new(gt(), ">")
          }
        '&' =>
          match self.peek() {
            Some('&') => {
              let _ = self.advance()
              Token::new(and_and(), "&&")
            }
            _ => Token::new(bit_and(), "&")
          }
        '|' =>
          match self.peek() {
            Some('|') => {
              let _ = self.advance()
              Token::new(or_or(), "||")
            }
            Some('>') => {
              let _ = self.advance()
              Token::new(pipe_gt(), "|>")
            }
            _ => Token::new(bit_or(), "|")
          }
        '^' => Token::new(bit_xor(), "^")
        '.' =>
          if self.pos + 1 < self.input.length() &&
            self.input[self.pos].to_int().unsafe_to_char() == '.' &&
            self.input[self.pos + 1].to_int().unsafe_to_char() == '.' {
            let _ = self.advance()
            let _ = self.advance()
            Token::new(dotdotdot(), "...")
          } else {
            Token::new(dot(), ".")
          }
        '#' =>
          if self.peek() == Some('|') {
            // Multiline string literal: #| lines joined by newline
            self.lex_multiline_string()
          } else {
            // Hash reference: #abc12345
            let start = self.pos - 1
            while (match self.peek() {
                    Some(ch) => is_alnum(ch)
                    None => false
                  }) {
              let _ = self.advance()
            }
            let text = self.input.unsafe_substring(start~, end=self.pos)
            Token::new(hash_ref(), text)
          }
        _ => Token::new(error_kind(), c.to_string())
      }
    }
  }
}

///|
/// Lex a multiline string literal starting with #|
/// Consecutive #| lines are joined by newlines.
fn Lexer::lex_multiline_string(self : Lexer) -> Token {
  let start = self.pos - 1 // include the '#' already consumed
  let buf = StringBuilder::new()
  let mut first_line = true
  let mut running = true
  // We are positioned after '#', peek should be '|'
  while running {
    // Consume '|'
    let _ = self.advance()
    // Read content until end of line
    let line_buf = StringBuilder::new()
    while (match self.peek() {
            Some('\n') | None => false
            _ => true
          }) {
      let _ = self.advance()
      // Re-read the char we just consumed from the position before advance
      let ch = self.input[self.pos - 1].to_int().unsafe_to_char()
      line_buf.write_char(ch)
    }
    if not(first_line) {
      buf.write_char('\n')
    }
    first_line = false
    buf.write_string(line_buf.to_string())
    // Consume the newline if present
    if self.peek() == Some('\n') {
      let _ = self.advance()
    } else {
      running = false
      continue
    }
    // Check if next line starts with optional whitespace followed by #|
    let saved_pos = self.pos
    while (match self.peek() {
            Some(' ') | Some('\t') => true
            _ => false
          }) {
      let _ = self.advance()
    }
    if self.peek() == Some('#') {
      let _ = self.advance()
      if self.peek() == Some('|') {
        continue // next #| line
      } else {
        // Not a continuation, restore position
        self.pos = saved_pos
        running = false
      }
    } else {
      self.pos = saved_pos
      running = false
    }
  }
  let width = self.pos - start
  Token::new_with_width(string_lit(), buf.to_string(), width)
}

///|
fn Lexer::lex_ident(self : Lexer) -> String {
  let start = self.pos
  let mut allow_qual = false
  while (match self.peek() {
          Some(_) => true
          None => false
        }) {
    match self.peek() {
      Some(ch) =>
        if is_alnum(ch) || ch == '_' {
          let _ = self.advance()
        } else if ch == '.' {
          if allow_qual {
            let _ = self.advance()
          } else {
            break
          }
        } else if is_ident_extra(ch) {
          if ch == '@' {
            allow_qual = true
          }
          let _ = self.advance()
        } else if ch == '/' {
          if allow_qual || self.should_continue_qualified() {
            allow_qual = true
            let _ = self.advance()
          } else {
            break
          }
        } else if ch == '-' {
          if allow_qual {
            let _ = self.advance()
          } else {
            break
          }
        } else {
          break
        }
      None => break
    }
  }
  try { self.input[start:self.pos].to_string() } catch { _ => "" }
}

///|
fn Lexer::should_continue_qualified(self : Lexer) -> Bool {
  let mut i = self.pos + 1
  while i < self.input.length() {
    let ch = self.input[i].to_int().unsafe_to_char()
    if is_ident_delim(ch) {
      break
    }
    if ch == '@' || ch == '/' {
      return true
    }
    i += 1
  }
  false
}

///|
fn Lexer::peek_next_significant_char(self : Lexer) -> Char? {
  let mut i = self.pos
  while i < self.input.length() {
    let ch = self.input[i].to_int().unsafe_to_char()
    if is_whitespace_char(ch) || ch == '\n' {
      i += 1
      continue
    }
    if ch == '/' &&
      i + 1 < self.input.length() &&
      self.input[i + 1].to_int().unsafe_to_char() == '/' {
      i += 2
      while i < self.input.length() {
        let c = self.input[i].to_int().unsafe_to_char()
        if c == '\n' {
          break
        }
        i += 1
      }
      continue
    }
    return Some(ch)
  }
  None
}

///|
/// Check if lexer is at end
pub fn Lexer::is_eof(self : Lexer) -> Bool {
  self.pos >= self.input.length()
}

///|
/// Tokenize entire input
pub fn tokenize(input : String) -> Array[Token] {
  let lexer = Lexer::new(input)
  let tokens : Array[Token] = []
  while not(lexer.is_eof()) {
    tokens.push(lexer.next_token())
  }
  tokens.push(Token::new(eof(), ""))
  tokens
}
