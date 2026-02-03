///| Lexer for xsh

///| Lexer state
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
fn is_alnum(c : Char) -> Bool {
  is_alpha(c) || is_digit(c)
}

///|
fn is_ident_continue(c : Char) -> Bool {
  is_alnum(c) || c == '#' || c == '.' || c == '/'
}

///|
fn is_whitespace_char(c : Char) -> Bool {
  c == ' ' || c == '\t'
}

///| Lex a string literal ("...") with basic escapes
fn Lexer::lex_string(self : Lexer) -> Token {
  let _ = self.advance() // opening quote
  let buf = StringBuilder::new()
  while {
    match self.peek() {
      Some('"') => false
      Some(_) => true
      None => false
    }
  } {
    match self.advance() {
      Some('\\') =>
        match self.advance() {
          Some('"') => buf.write_char('"')
          Some('\\') => buf.write_char('\\')
          Some('n') => buf.write_char('\n')
          Some('t') => buf.write_char('\t')
          Some(c) => buf.write_char(c)
          None => ()
        }
      Some(c) => buf.write_char(c)
      None => ()
    }
  }
  match self.peek() {
    Some('"') => {
      let _ = self.advance()
      Token::new(string_lit(), buf.to_string())
    }
    _ => Token::new(error_kind(), buf.to_string())
  }
}

///| Lex a single token
pub fn Lexer::next_token(self : Lexer) -> Token {
  match self.peek() {
    None => Token::new(eof(), "")
    Some(c) => {
      if is_whitespace_char(c) {
        let start = self.pos
        while {
          match self.peek() {
            Some(ch) => is_whitespace_char(ch)
            None => false
          }
        } {
          let _ = self.advance()
        }
        let text = (try! self.input[start:self.pos]).to_string()
        return Token::new(whitespace(), text)
      }
      if c == '\n' {
        let _ = self.advance()
        return Token::new(newline(), "\n")
      }
      if c == '"' {
        return self.lex_string()
      }
      if is_alpha(c) {
        let start = self.pos
        while {
          match self.peek() {
            Some(ch) => is_ident_continue(ch)
            None => false
          }
        } {
          let _ = self.advance()
        }
        let text = (try! self.input[start:self.pos]).to_string()
        let kind = match text {
          "let" => let_kw()
          "flake" => flake_kw()
          "alias" => alias_kw()
          "import" => import_kw()
          "test" => test_kw()
          "if" => if_kw()
          "else" => else_kw()
          "match" => match_kw()
          "do" => do_kw()
          "record" => record_kw()
          "true" => bool_lit()
          "false" => bool_lit()
          _ => name()
        }
        return Token::new(kind, text)
      }
      if is_digit(c) {
        let start = self.pos
        while {
          match self.peek() {
            Some(ch) => is_digit(ch)
            None => false
          }
        } {
          let _ = self.advance()
        }
        let text = (try! self.input[start:self.pos]).to_string()
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
            _ => Token::new(eq(), "=")
          }
        ';' => Token::new(semicolon(), ";")
        '{' => Token::new(lbrace(), "{")
        '}' => Token::new(rbrace(), "}")
        '(' => Token::new(lparen(), "(")
        ')' => Token::new(rparen(), ")")
        ',' => Token::new(comma(), ",")
        ':' => Token::new(colon(), ":")
        _ => Token::new(error_kind(), c.to_string())
      }
    }
  }
}

///| Check if lexer is at end
pub fn Lexer::is_eof(self : Lexer) -> Bool {
  self.pos >= self.input.length()
}

///| Tokenize entire input
pub fn tokenize(input : String) -> Array[Token] {
  let lexer = Lexer::new(input)
  let tokens : Array[Token] = []
  while not(lexer.is_eof()) {
    tokens.push(lexer.next_token())
  }
  tokens.push(Token::new(eof(), ""))
  tokens
}
