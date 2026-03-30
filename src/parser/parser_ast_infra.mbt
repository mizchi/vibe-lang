///|
/// AST parser state
pub struct AstParser {
  tokens : Array[Token]
  offsets : Array[Int]
  mut pos : Int
  mut pending_stmts : Array[@core.Stmt]
  errors : Array[ParseError]
}

///|
pub fn AstParser::new(tokens : Array[Token]) -> AstParser {
  let len = tokens.length()
  let offsets = Array::make(len + 1, 0)
  let mut acc = 0
  for i in 0..<len {
    offsets[i] = acc
    acc += tokens[i].width()
  }
  offsets[len] = acc
  AstParser::{ tokens, offsets, pos: 0, pending_stmts: [], errors: [] }
}

///|
fn AstParser::peek(self : AstParser) -> Token {
  if self.pos >= self.tokens.length() {
    Token::new(eof(), "")
  } else {
    self.tokens[self.pos]
  }
}

///|
fn AstParser::peek_kind(self : AstParser) -> @cst.SyntaxKind {
  self.peek().kind()
}

///|
fn AstParser::peek_non_trivia_kind(
  self : AstParser,
  pos : Int,
) -> @cst.SyntaxKind {
  let mut i = pos
  while i < self.tokens.length() && is_trivia(self.tokens[i].kind()) {
    i += 1
  }
  if i >= self.tokens.length() {
    eof()
  } else {
    self.tokens[i].kind()
  }
}

///|
fn AstParser::peek_non_trivia_ahead(
  self : AstParser,
  nth : Int,
) -> @cst.SyntaxKind {
  let mut i = self.pos + 1
  let mut seen = 0
  while i < self.tokens.length() {
    if !is_trivia(self.tokens[i].kind()) {
      seen += 1
      if seen == nth {
        return self.tokens[i].kind()
      }
    }
    i += 1
  }
  eof()
}

///|
fn AstParser::offset_at(self : AstParser, pos : Int) -> Int {
  let idx = if pos > self.tokens.length() { self.tokens.length() } else { pos }
  self.offsets[idx]
}

///|
fn AstParser::span_from(self : AstParser, start_pos : Int) -> @core.Span {
  @core.Span::new(self.offset_at(start_pos), self.offset_at(self.pos))
}

///|
fn AstParser::token_span(self : AstParser) -> @core.Span {
  let start = self.offset_at(self.pos)
  let tok = self.peek()
  @core.Span::new(start, start + tok.width())
}

///|
fn AstParser::skip_trivia(self : AstParser) -> Unit {
  while is_trivia(self.peek_kind()) {
    self.pos += 1
  }
}

///|
fn AstParser::bump(self : AstParser) -> Token {
  let tok = self.peek()
  self.pos += 1
  tok
}

///|
fn AstParser::eat(self : AstParser, kind : @cst.SyntaxKind) -> Bool {
  self.skip_trivia()
  if self.peek_kind() == kind {
    self.pos += 1
    true
  } else {
    false
  }
}

///|
fn AstParser::expect(
  self : AstParser,
  kind : @cst.SyntaxKind,
  label : String,
) -> Token raise ParseError {
  self.skip_trivia()
  let tok = self.peek()
  if tok.kind() == kind {
    self.pos += 1
    tok
  } else if tok.kind() == eof() {
    raise ParseError::UnexpectedEof(span=self.token_span())
  } else {
    raise ParseError::UnexpectedToken(
      expected=label,
      got=tok.text(),
      span=self.token_span(),
    )
  }
}

///|
pub fn AstParser::parse(self : AstParser) -> @core.Module raise ParseError {
  let stmts : Array[@core.Stmt] = []
  while ({
          self.skip_trivia()
          self.peek_kind() != eof()
        }) {
    let result : @core.Stmt? = try {
      self.parse_stmt()
    } catch {
      e => {
        self.errors.push(e)
        self.skip_to_sync_point()
        None
      }
    }
    match result {
      Some(stmt) => stmts.push(stmt)
      None => ()
    }
    for pending in self.pending_stmts {
      stmts.push(pending)
    }
    self.pending_stmts = []
  }
  if self.errors.length() > 0 {
    raise self.errors[0]
  }
  @core.Module::{ stmts, }
}

///|
/// Parse with error recovery, returning partial AST and all collected errors.
pub fn AstParser::parse_with_recovery(
  self : AstParser,
) -> (@core.Module, Array[ParseError]) {
  let stmts : Array[@core.Stmt] = []
  while ({
          self.skip_trivia()
          self.peek_kind() != eof()
        }) {
    let result : @core.Stmt? = try {
      self.parse_stmt()
    } catch {
      e => {
        self.errors.push(e)
        self.skip_to_sync_point()
        None
      }
    }
    match result {
      Some(stmt) => stmts.push(stmt)
      None => ()
    }
    for pending in self.pending_stmts {
      stmts.push(pending)
    }
    self.pending_stmts = []
  }
  (@core.Module::{ stmts, }, self.errors)
}

///|
/// Check if a token kind is a statement-start synchronization point.
fn is_stmt_sync_point(kind : @cst.SyntaxKind) -> Bool {
  kind == let_kw() ||
  kind == enum_kw() ||
  kind == struct_kw() ||
  kind == type_kw() ||
  kind == trait_kw() ||
  kind == impl_kw() ||
  kind == import_kw() ||
  kind == export_kw() ||
  kind == test_kw() ||
  kind == bench_kw() ||
  kind == rbrace()
}

///|
/// Skip tokens until a synchronization point (statement-start keyword or `}`).
fn AstParser::skip_to_sync_point(self : AstParser) -> Unit {
  while self.peek_kind() != eof() {
    self.skip_trivia()
    let kind = self.peek_kind()
    if is_stmt_sync_point(kind) {
      return
    }
    // Consume the unrecognized token
    self.pos += 1
  }
}
