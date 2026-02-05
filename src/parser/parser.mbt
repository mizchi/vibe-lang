///|
/// Parser for xsh (CST + AST)
suberror ParseError {
  UnexpectedToken(expected~ : String, got~ : String, span~ : @core.Span)
  UnexpectedEof(span~ : @core.Span)
  InvalidHashSuffix(value~ : String, span~ : @core.Span)
} derive(Show, Eq)

///|
pub fn ParseError::diagnostic(self : ParseError) -> @core.Diagnostic {
  match self {
    ParseError::UnexpectedToken(expected~, got~, span~) => {
      let got_display = if got.is_empty() {
        "<eof>"
      } else {
        let trimmed = got.trim().to_string()
        if trimmed.is_empty() {
          "<whitespace>"
        } else {
          "`" + trimmed + "`"
        }
      }
      @core.Diagnostic::{
        stage: "parse",
        message: "expected " + expected + ", got " + got_display,
        span: Some(span),
        hint: None,
        note: None,
      }
    }
    ParseError::UnexpectedEof(span~) =>
      @core.Diagnostic::{
        stage: "parse",
        message: "unexpected end of file",
        span: Some(span),
        hint: None,
        note: None,
      }
    ParseError::InvalidHashSuffix(value~, span~) =>
      @core.Diagnostic::{
        stage: "parse",
        message: "invalid hash suffix: " + value,
        span: Some(span),
        hint: None,
        note: None,
      }
  }
}

///|
/// CST parser state
pub struct Parser {
  tokens : Array[Token]
  mut pos : Int
  builder : @cst.GreenNodeBuilder
}

///|
pub fn Parser::new(tokens : Array[Token]) -> Parser {
  Parser::{ tokens, pos: 0, builder: @cst.GreenNodeBuilder::new() }
}

///|
fn Parser::peek(self : Parser) -> Token {
  if self.pos >= self.tokens.length() {
    Token::new(eof(), "")
  } else {
    self.tokens[self.pos]
  }
}

///|
fn Parser::peek_kind(self : Parser) -> @cst.SyntaxKind {
  self.peek().kind()
}

///|
fn Parser::peek_non_trivia_kind(self : Parser, pos : Int) -> @cst.SyntaxKind {
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
fn Parser::is_labeled_arg(self : Parser) -> Bool {
  if self.peek_kind() != name() {
    return false
  }
  self.peek_non_trivia_kind(self.pos + 1) == eq()
}

///|
fn Parser::at(self : Parser, kind : @cst.SyntaxKind) -> Bool {
  self.peek_kind() == kind
}

///|
fn Parser::bump(self : Parser) -> Unit {
  let tok = self.peek()
  self.builder.token(tok.kind(), tok.text())
  self.pos += 1
}

///|
fn Parser::skip_trivia(self : Parser) -> Unit {
  while is_trivia(self.peek_kind()) {
    self.bump()
  }
}

///|
fn Parser::expect(self : Parser, kind : @cst.SyntaxKind) -> Unit {
  self.skip_trivia()
  if self.at(kind) {
    self.bump()
  } else {
    self.builder.token(error_kind(), "")
  }
}

///|
pub fn Parser::parse(self : Parser) -> @cst.GreenNode {
  self.builder.start_node(source_file())
  while not(self.at(eof())) {
    self.skip_trivia()
    if self.at(eof()) {
      break
    }
    self.parse_stmt()
  }
  self.builder.finish_node()
  self.builder.finish()
}

///|
fn Parser::parse_stmt(self : Parser) -> Unit {
  self.skip_trivia()
  match self.peek_kind() {
    k if k == let_kw() => self.parse_let_stmt()
    k if k == enum_kw() => self.parse_enum_stmt()
    k if k == type_kw() => self.parse_type_alias_stmt()
    k if k == alias_kw() => self.parse_alias_stmt()
    k if k == import_kw() => self.parse_import_stmt()
    k if k == test_kw() => self.parse_test_block()
    k if k == flake_kw() => self.parse_flake_block()
    _ => self.parse_expr_stmt()
  }
}

///|
fn Parser::parse_let_stmt(self : Parser) -> Unit {
  self.builder.start_node(let_stmt())
  self.bump() // let
  self.skip_trivia()
  if self.at(rec_kw()) {
    self.bump()
    self.skip_trivia()
  }
  if self.at(mut_kw()) {
    self.bump()
    self.skip_trivia()
  }
  self.expect(name())
  self.skip_trivia()
  self.expect(eq())
  self.skip_trivia()
  self.parse_expr()
  self.skip_trivia()
  if self.at(semicolon()) {
    self.bump()
  }
  self.builder.finish_node()
}

///|
fn Parser::parse_enum_stmt(self : Parser) -> Unit {
  self.builder.start_node(enum_def())
  self.bump() // enum
  self.skip_trivia()
  self.expect(name())
  self.skip_trivia()
  if self.at(lbracket()) {
    self.parse_bracket_tokens()
  }
  self.skip_trivia()
  self.expect(lbrace())
  let mut depth = 1
  while depth > 0 && not(self.at(eof())) {
    match self.peek_kind() {
      k if k == lbrace() => {
        self.bump()
        depth += 1
      }
      k if k == rbrace() => {
        self.bump()
        depth -= 1
      }
      _ => self.bump()
    }
  }
  self.skip_trivia()
  if self.at(semicolon()) {
    self.bump()
  }
  self.builder.finish_node()
}

///|
fn Parser::parse_type_alias_stmt(self : Parser) -> Unit {
  self.builder.start_node(type_alias())
  self.bump() // type
  self.skip_trivia()
  self.expect(name())
  self.skip_trivia()
  if self.at(lbracket()) {
    self.parse_bracket_tokens()
  }
  self.skip_trivia()
  self.expect(eq())
  self.skip_trivia()
  self.parse_type_tokens()
  self.skip_trivia()
  if self.at(semicolon()) {
    self.bump()
  }
  self.builder.finish_node()
}

///|
fn Parser::parse_flake_block(self : Parser) -> Unit {
  self.builder.start_node(flake_block())
  self.bump() // flake
  self.skip_trivia()
  self.expect(lbrace())
  let mut depth = 1
  while depth > 0 && not(self.at(eof())) {
    match self.peek_kind() {
      k if k == lbrace() => {
        self.bump()
        depth += 1
      }
      k if k == rbrace() => {
        self.bump()
        depth -= 1
      }
      _ => self.bump()
    }
  }
  self.builder.finish_node()
}

///|
fn Parser::parse_test_block(self : Parser) -> Unit {
  self.builder.start_node(test_block())
  self.bump() // test
  self.skip_trivia()
  if self.at(string_lit()) {
    self.bump()
    self.skip_trivia()
  }
  self.expect(lbrace())
  let mut depth = 1
  while depth > 0 && not(self.at(eof())) {
    match self.peek_kind() {
      k if k == lbrace() => {
        self.bump()
        depth += 1
      }
      k if k == rbrace() => {
        self.bump()
        depth -= 1
      }
      _ => self.bump()
    }
  }
  self.builder.finish_node()
}

///|
fn Parser::parse_alias_stmt(self : Parser) -> Unit {
  self.builder.start_node(alias_stmt())
  self.bump() // alias
  self.skip_trivia()
  self.expect(name())
  self.skip_trivia()
  self.expect(eq())
  self.skip_trivia()
  self.expect(name())
  self.skip_trivia()
  if self.at(semicolon()) {
    self.bump()
  }
  self.builder.finish_node()
}

///|
fn Parser::parse_import_stmt(self : Parser) -> Unit {
  self.builder.start_node(import_stmt())
  self.bump() // import
  self.skip_trivia()
  if self.at(name()) || self.at(string_lit()) {
    self.bump()
  } else {
    self.builder.token(error_kind(), "")
  }
  self.skip_trivia()
  if self.at(semicolon()) {
    self.bump()
  }
  self.builder.finish_node()
}

///|
fn Parser::parse_expr_stmt(self : Parser) -> Unit {
  self.builder.start_node(expr_stmt())
  self.parse_expr()
  self.skip_trivia()
  if self.at(semicolon()) {
    self.bump()
  }
  self.builder.finish_node()
}

///|
fn Parser::parse_expr(self : Parser) -> Unit {
  self.skip_trivia()
  if self.at(if_kw()) {
    self.parse_if_expr()
  } else if self.at(while_kw()) {
    self.parse_while_expr()
  } else if self.at(match_kw()) {
    self.parse_match_expr()
  } else if self.at(do_kw()) {
    self.parse_do_expr()
  } else if self.at(try_kw()) {
    self.parse_try_expr()
  } else if self.at(record_kw()) {
    self.parse_record_expr()
  } else if self.at(map_kw()) {
    self.parse_map_expr()
  } else if self.at(lparen()) {
    self.parse_paren_expr()
  } else if self.at(lbracket()) {
    self.parse_array_expr()
  } else if self.at(lbrace()) {
    self.parse_block_expr()
  } else {
    self.parse_or_expr()
  }
}

///|
fn Parser::parse_while_expr(self : Parser) -> Unit {
  self.builder.start_node(while_expr())
  self.bump() // while
  self.skip_trivia()
  self.parse_expr()
  self.skip_trivia()
  self.parse_brace_block_tokens()
  self.builder.finish_node()
}

///|
fn Parser::parse_pipe_expr(self : Parser) -> Unit {
  self.parse_cmp_expr()
  while {
          self.skip_trivia()
          self.at(pipe()) && self.peek_non_trivia_kind(self.pos + 1) == gt()
        } {
    self.bump()
    self.skip_trivia()
    if self.at(gt()) {
      self.bump()
    }
    self.parse_cmp_expr()
  }
}

///|
fn Parser::parse_or_expr(self : Parser) -> Unit {
  self.parse_and_expr()
  while {
          self.skip_trivia()
          self.at(or_or())
        } {
    self.bump()
    self.parse_and_expr()
  }
}

///|
fn Parser::parse_and_expr(self : Parser) -> Unit {
  self.parse_pipe_expr()
  while {
          self.skip_trivia()
          self.at(and_and())
        } {
    self.bump()
    self.parse_pipe_expr()
  }
}

///|
fn Parser::parse_cmp_expr(self : Parser) -> Unit {
  self.parse_add_expr()
  while {
          self.skip_trivia()
          self.at(eqeq()) ||
          self.at(neq()) ||
          self.at(lt()) ||
          self.at(lte()) ||
          self.at(gt()) ||
          self.at(gte())
        } {
    self.bump()
    self.parse_add_expr()
  }
}

///|
fn Parser::parse_add_expr(self : Parser) -> Unit {
  self.parse_mul_expr()
  while {
          self.skip_trivia()
          self.at(plus()) || self.at(minus())
        } {
    self.bump()
    self.parse_mul_expr()
  }
}

///|
fn Parser::parse_mul_expr(self : Parser) -> Unit {
  self.parse_unary_expr()
  while {
          self.skip_trivia()
          self.at(star()) || self.at(slash())
        } {
    self.bump()
    self.parse_unary_expr()
  }
}

///|
fn Parser::parse_unary_expr(self : Parser) -> Unit {
  self.skip_trivia()
  match self.peek_kind() {
    k if k == minus() || k == bang() => {
      self.bump()
      self.parse_unary_expr()
    }
    _ => self.parse_call_or_primary()
  }
}

///|
fn Parser::parse_do_expr(self : Parser) -> Unit {
  self.builder.start_node(do_expr())
  self.bump() // do
  self.skip_trivia()
  self.parse_brace_block_tokens()
  self.builder.finish_node()
}

///|
fn Parser::parse_try_expr(self : Parser) -> Unit {
  self.builder.start_node(try_expr())
  self.bump() // try
  self.skip_trivia()
  self.parse_brace_block_tokens()
  self.skip_trivia()
  self.expect(catch_kw())
  self.skip_trivia()
  self.parse_brace_block_tokens()
  self.builder.finish_node()
}

///|
fn Parser::parse_block_expr(self : Parser) -> Unit {
  self.builder.start_node(block_expr())
  self.parse_brace_block_tokens()
  self.builder.finish_node()
}

///|
fn Parser::parse_if_expr(self : Parser) -> Unit {
  self.builder.start_node(if_expr())
  self.bump() // if
  self.skip_trivia()
  self.parse_expr()
  self.skip_trivia()
  self.parse_brace_block_tokens()
  self.skip_trivia()
  if self.at(else_kw()) {
    self.bump()
    self.skip_trivia()
    if self.at(lbrace()) {
      self.parse_brace_block_tokens()
    } else {
      self.parse_expr()
    }
  } else {
    self.builder.token(error_kind(), "")
  }
  self.builder.finish_node()
}

///|
fn Parser::parse_match_expr(self : Parser) -> Unit {
  self.builder.start_node(match_expr())
  self.bump() // match
  self.skip_trivia()
  self.parse_expr()
  self.skip_trivia()
  self.parse_brace_block_tokens()
  self.builder.finish_node()
}

///|
fn Parser::parse_record_expr(self : Parser) -> Unit {
  self.builder.start_node(record_expr())
  self.bump() // record
  self.skip_trivia()
  self.parse_brace_block_tokens()
  self.builder.finish_node()
}

///|
fn Parser::parse_map_expr(self : Parser) -> Unit {
  self.builder.start_node(map_expr())
  self.bump() // map
  self.skip_trivia()
  self.parse_brace_block_tokens()
  self.builder.finish_node()
}

///|
fn Parser::parse_array_expr(self : Parser) -> Unit {
  self.builder.start_node(array_expr())
  self.expect(lbracket())
  let mut depth = 1
  while depth > 0 && not(self.at(eof())) {
    match self.peek_kind() {
      k if k == lbracket() => {
        self.bump()
        depth += 1
      }
      k if k == rbracket() => {
        self.bump()
        depth -= 1
      }
      _ => self.bump()
    }
  }
  self.builder.finish_node()
}

///|
fn Parser::parse_paren_expr(self : Parser) -> Unit {
  self.builder.start_node(paren_expr())
  self.expect(lparen())
  let mut depth = 1
  while depth > 0 && not(self.at(eof())) {
    match self.peek_kind() {
      k if k == lparen() => {
        self.bump()
        depth += 1
      }
      k if k == rparen() => {
        self.bump()
        depth -= 1
      }
      _ => self.bump()
    }
  }
  self.builder.finish_node()
}

///|
fn Parser::parse_bracket_tokens(self : Parser) -> Unit {
  self.expect(lbracket())
  let mut depth = 1
  while depth > 0 && not(self.at(eof())) {
    match self.peek_kind() {
      k if k == lbracket() => {
        self.bump()
        depth += 1
      }
      k if k == rbracket() => {
        self.bump()
        depth -= 1
      }
      _ => self.bump()
    }
  }
}

///|
fn Parser::parse_brace_block_tokens(self : Parser) -> Unit {
  self.expect(lbrace())
  let mut depth = 1
  while depth > 0 && not(self.at(eof())) {
    match self.peek_kind() {
      k if k == lbrace() => {
        self.bump()
        depth += 1
      }
      k if k == rbrace() => {
        self.bump()
        depth -= 1
      }
      _ => self.bump()
    }
  }
}

///|
fn Parser::parse_type_tokens(self : Parser) -> Unit {
  let mut depth = 0
  while not(self.at(eof())) {
    match self.peek_kind() {
      k if k == lbrace() && depth == 0 => break
      k if k == lparen() => {
        self.bump()
        depth += 1
      }
      k if k == rparen() => {
        self.bump()
        depth -= 1
      }
      _ => self.bump()
    }
  }
}

///|
fn Parser::parse_call_or_primary(self : Parser) -> Unit {
  self.skip_trivia()
  let checkpoint = self.builder.checkpoint()
  self.parse_primary()
  self.skip_trivia()
  if self.at(lparen()) {
    self.builder.start_node_at(checkpoint, call_expr())
    self.bump()
    self.parse_args()
    self.expect(rparen())
    self.builder.finish_node()
  }
}

///|
fn Parser::parse_args(self : Parser) -> Unit {
  self.builder.start_node(arg_list())
  self.skip_trivia()
  if not(self.at(rparen())) {
    self.parse_arg()
    while {
            self.skip_trivia()
            self.at(comma())
          } {
      self.bump()
      self.skip_trivia()
      self.parse_arg()
    }
  }
  self.builder.finish_node()
}

///|
fn Parser::parse_arg(self : Parser) -> Unit {
  self.skip_trivia()
  if self.is_labeled_arg() {
    self.expect(name())
    self.skip_trivia()
    self.expect(eq())
    self.skip_trivia()
    self.parse_expr()
  } else {
    self.parse_expr()
  }
}

///|
fn Parser::parse_primary(self : Parser) -> Unit {
  self.skip_trivia()
  match self.peek_kind() {
    k if k == name() => {
      self.builder.start_node(name_ref())
      self.bump()
      self.builder.finish_node()
    }
    k if k == int_lit() ||
      k == string_lit() ||
      k == string_interp_lit() ||
      k == bool_lit() ||
      k == char_lit() => {
      self.builder.start_node(literal())
      self.bump()
      self.builder.finish_node()
    }
    _ => {
      self.builder.token(error_kind(), "")
      self.bump()
    }
  }
}

///|
/// Parse input into CST (red tree root)
pub fn parse_cst(input : String) -> @cst.SyntaxNode {
  let tokens = tokenize(input)
  let parser = Parser::new(tokens)
  let green = parser.parse()
  @cst.SyntaxNode::new_root(green)
}

///|
/// AST parser state
pub struct AstParser {
  tokens : Array[Token]
  mut pos : Int
}

///|
pub fn AstParser::new(tokens : Array[Token]) -> AstParser {
  AstParser::{ tokens, pos: 0 }
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
fn AstParser::offset_at(self : AstParser, pos : Int) -> Int {
  let mut i = 0
  let mut offset = 0
  let limit = if pos > self.tokens.length() {
    self.tokens.length()
  } else {
    pos
  }
  while i < limit {
    offset += self.tokens[i].text().length()
    i += 1
  }
  offset
}

///|
fn AstParser::span_from(self : AstParser, start_pos : Int) -> @core.Span {
  @core.Span::new(self.offset_at(start_pos), self.offset_at(self.pos))
}

///|
fn AstParser::token_span(self : AstParser) -> @core.Span {
  let start = self.offset_at(self.pos)
  let tok = self.peek()
  @core.Span::new(start, start + tok.text().length())
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
  while {
          self.skip_trivia()
          self.peek_kind() != eof()
        } {
    stmts.push(self.parse_stmt())
  }
  @core.Module::{ stmts, }
}

///|
fn AstParser::parse_stmt(self : AstParser) -> @core.Stmt raise ParseError {
  self.skip_trivia()
  match self.peek_kind() {
    k if k == let_kw() => self.parse_let_stmt()
    k if k == enum_kw() => self.parse_enum_stmt()
    k if k == type_kw() => self.parse_type_alias_stmt()
    k if k == alias_kw() => self.parse_alias_stmt()
    k if k == import_kw() => self.parse_import_stmt()
    k if k == test_kw() => self.parse_test_stmt()
    k if k == flake_kw() => self.parse_flake_stmt()
    k if k == name() =>
      if self.peek_non_trivia_kind(self.pos + 1) == eq() {
        self.parse_assign_stmt()
      } else {
        let start = self.pos
        let expr = self.parse_expr()
        let _ = self.eat(semicolon())
        let span = self.span_from(start)
        @core.Stmt::Expr(expr~, span~)
      }
    _ => {
      let start = self.pos
      let expr = self.parse_expr()
      let _ = self.eat(semicolon())
      let span = self.span_from(start)
      @core.Stmt::Expr(expr~, span~)
    }
  }
}

///|
fn AstParser::parse_let_stmt(self : AstParser) -> @core.Stmt raise ParseError {
  let start = self.pos
  let _ = self.expect(let_kw(), "let")
  self.skip_trivia()
  let mut rec_flag = false
  let mut mut_flag = false
  if self.peek_kind() == rec_kw() {
    let _ = self.bump()
    rec_flag = true
  }
  if self.peek_kind() == mut_kw() {
    let _ = self.bump()
    mut_flag = true
  }
  self.skip_trivia()
  if not(rec_flag) &&
    not(mut_flag) &&
    (self.peek_kind() == lparen() || self.peek_kind() == record_kw()) {
    let pat = self.parse_pattern()
    let _ = self.expect(eq(), "=")
    let expr = self.parse_expr()
    let _ = self.eat(semicolon())
    let span = self.span_from(start)
    return @core.Stmt::LetPat(pat~, expr~, span~)
  }
  let name_tok = self.expect(name(), "name")
  let _ = self.expect(eq(), "=")
  let expr = self.parse_expr()
  let _ = self.eat(semicolon())
  let span = self.span_from(start)
  if mut_flag {
    @core.Stmt::LetMut(name=name_tok.text(), expr~, span~)
  } else {
    @core.Stmt::Let(rec=rec_flag, name=name_tok.text(), expr~, span~)
  }
}

///|
fn AstParser::parse_assign_stmt(
  self : AstParser,
) -> @core.Stmt raise ParseError {
  let start = self.pos
  let name_tok = self.expect(name(), "name")
  let _ = self.expect(eq(), "=")
  let expr = self.parse_expr()
  let _ = self.eat(semicolon())
  let span = self.span_from(start)
  @core.Stmt::Assign(name=name_tok.text(), expr~, span~)
}

///|
fn AstParser::parse_enum_stmt(self : AstParser) -> @core.Stmt raise ParseError {
  let start = self.pos
  let _ = self.expect(enum_kw(), "enum")
  self.skip_trivia()
  let name_tok = self.expect(name(), "enum name")
  let params = self.parse_type_params()
  let param_set = param_set_from_params(params)
  self.skip_trivia()
  let _ = self.expect(lbrace(), "{")
  let ctors : Array[@core.TypeCtor] = []
  while {
          self.skip_trivia()
          self.peek_kind() != rbrace()
        } {
    if self.peek_kind() == eof() {
      raise ParseError::UnexpectedEof(span=self.token_span())
    }
    ctors.push(self.parse_type_ctor(param_set))
    let _ = self.eat(comma())
    let _ = self.eat(semicolon())

  }
  let _ = self.expect(rbrace(), "}")
  let _ = self.eat(semicolon())
  let span = self.span_from(start)
  @core.Stmt::EnumDef(name=name_tok.text(), params~, ctors~, span~)
}

///|
fn AstParser::parse_type_alias_stmt(
  self : AstParser,
) -> @core.Stmt raise ParseError {
  let start = self.pos
  let _ = self.expect(type_kw(), "type")
  self.skip_trivia()
  let name_tok = self.expect(name(), "type name")
  let params = self.parse_type_params()
  let param_set = param_set_from_params(params)
  let _ = self.expect(eq(), "=")
  let target = self.parse_type_with_params(param_set)
  let _ = self.eat(semicolon())
  let span = self.span_from(start)
  @core.Stmt::TypeAlias(name=name_tok.text(), params~, target~, span~)
}

///|
fn AstParser::parse_type_ctor(
  self : AstParser,
  params : Map[String, Bool],
) -> @core.TypeCtor raise ParseError {
  let start = self.pos
  let name_tok = self.expect(name(), "ctor")
  if not(@core.is_ctor_name(name_tok.text())) {
    raise ParseError::UnexpectedToken(
      expected="ctor",
      got=name_tok.text(),
      span=self.token_span(),
    )
  }
  let args : Array[@core.Type] = []
  self.skip_trivia()
  if self.peek_kind() == lparen() {
    let _ = self.bump()
    self.skip_trivia()
    if self.peek_kind() != rparen() {
      args.push(self.parse_type_with_params(params))
      while {
              self.skip_trivia()
              self.peek_kind() == comma()
            } {
        let _ = self.bump()
        self.skip_trivia()
        if self.peek_kind() == rparen() {
          break
        }
        args.push(self.parse_type_with_params(params))
      }
    }
    let _ = self.expect(rparen(), ")")

  }
  let span = self.span_from(start)
  @core.TypeCtor::{ name: name_tok.text(), args, span }
}

///|
fn AstParser::parse_type_params(
  self : AstParser,
) -> Array[String] raise ParseError {
  let params : Array[String] = []
  self.skip_trivia()
  if self.peek_kind() == lbracket() {
    let _ = self.bump()
    self.skip_trivia()
    if self.peek_kind() != rbracket() {
      let first = self.expect(name(), "type param")
      params.push(first.text())
      while {
              self.skip_trivia()
              self.peek_kind() == comma()
            } {
        let _ = self.bump()
        self.skip_trivia()
        if self.peek_kind() == rbracket() {
          break
        }
        let tok = self.expect(name(), "type param")
        params.push(tok.text())
      }
    }
    let _ = self.expect(rbracket(), "]")

  }
  params
}

///|
fn param_set_from_params(params : Array[String]) -> Map[String, Bool] {
  let set : Map[String, Bool] = {}
  for p in params {
    set[p] = true
  }
  set
}

///|
fn AstParser::parse_flake_stmt(self : AstParser) -> @core.Stmt raise ParseError {
  let start = self.pos
  let _ = self.expect(flake_kw(), "flake")
  let _ = self.expect(lbrace(), "{")
  let buf = StringBuilder::new()
  let mut depth = 1
  while depth > 0 {
    let tok = self.peek()
    if tok.kind() == eof() {
      raise ParseError::UnexpectedEof(span=self.token_span())
    }
    self.pos += 1
    if tok.kind() == lbrace() {
      depth += 1
    } else if tok.kind() == rbrace() {
      depth -= 1
      if depth == 0 {
        break
      }
    }
    buf.write_string(tok.text())
  }
  let span = self.span_from(start)
  @core.Stmt::Flake(raw=buf.to_string(), span~)
}

///|
fn AstParser::parse_test_stmt(self : AstParser) -> @core.Stmt raise ParseError {
  let start = self.pos
  let _ = self.expect(test_kw(), "test")
  self.skip_trivia()
  let mut name : String? = None
  if self.peek_kind() == string_lit() {
    let name_tok = self.bump()
    name = Some(name_tok.text())
    self.skip_trivia()
  }
  let body = self.parse_block()
  let span = self.span_from(start)
  @core.Stmt::Test(name~, body~, span~)
}

///|
fn AstParser::parse_block(self : AstParser) -> @core.Module raise ParseError {
  let _ = self.expect(lbrace(), "{")
  let stmts : Array[@core.Stmt] = []
  while {
          self.skip_trivia()
          self.peek_kind() != rbrace()
        } {
    if self.peek_kind() == eof() {
      raise ParseError::UnexpectedEof(span=self.token_span())
    }
    stmts.push(self.parse_stmt())
  }
  let _ = self.expect(rbrace(), "}")
  @core.Module::{ stmts, }
}

///|

///|
fn split_hash_optional(
  name : String,
  span : @core.Span,
) -> @core.Ref? raise ParseError {
  let chars : Array[Char] = []
  for c in name {
    chars.push(c)
  }
  let mut hash_pos = -1
  let mut hash_count = 0
  for i in 0..<chars.length() {
    if chars[i] == '#' {
      hash_count += 1
      if hash_count == 1 {
        hash_pos = i
      }
    }
  }
  if hash_count == 0 {
    return None
  }
  if hash_count > 1 || hash_pos <= 0 || hash_pos >= chars.length() - 1 {
    raise ParseError::InvalidHashSuffix(value=name, span~)
  }
  let left = StringBuilder::new()
  for i in 0..<hash_pos {
    left.write_char(chars[i])
  }
  let right = StringBuilder::new()
  for i in (hash_pos + 1)..<chars.length() {
    right.write_char(chars[i])
  }
  Some(@core.Ref::{
    name: left.to_string(),
    hash_prefix: Some(right.to_string()),
  })
}

///|
fn AstParser::parse_alias_stmt(self : AstParser) -> @core.Stmt raise ParseError {
  let start = self.pos
  let _ = self.expect(alias_kw(), "alias")
  let name_start = self.pos
  let name_tok = self.expect(name(), "name")
  let name_span = self.span_from(name_start)
  let _ = self.expect(eq(), "=")
  let target_start = self.pos
  let target_tok = self.expect(name(), "name#hash")
  let target_span = self.span_from(target_start)
  let _ = self.eat(semicolon())
  let target = match split_hash_optional(target_tok.text(), target_span) {
    Some(r) => {
      if r.name.is_empty() || r.hash_prefix is None {
        raise ParseError::InvalidHashSuffix(
          value=target_tok.text(),
          span=target_span,
        )
      }
      @core.AliasTarget::Module(r)
    }
    None => @core.AliasTarget::Name(target_tok.text())
  }
  let name_ref = split_hash_optional(name_tok.text(), name_span)
  match name_ref {
    Some(_) =>
      raise ParseError::InvalidHashSuffix(value=name_tok.text(), span=name_span)
    None => ()
  }
  let span = self.span_from(start)
  @core.Stmt::Alias(name=name_tok.text(), target~, span~)
}

///|
fn AstParser::parse_import_stmt(
  self : AstParser,
) -> @core.Stmt raise ParseError {
  let start = self.pos
  let _ = self.expect(import_kw(), "import")
  self.skip_trivia()
  let tok = self.peek()
  if tok.kind() != name() && tok.kind() != string_lit() {
    raise ParseError::UnexpectedToken(
      expected="path",
      got=tok.text(),
      span=self.token_span(),
    )
  }
  let _ = self.bump()
  let _ = self.eat(semicolon())
  let span = self.span_from(start)
  @core.Stmt::Import(path=tok.text(), span~)
}

///|
fn AstParser::parse_expr(self : AstParser) -> @core.Expr raise ParseError {
  self.skip_trivia()
  if self.peek_kind() == if_kw() {
    self.parse_if_expr()
  } else if self.peek_kind() == while_kw() {
    self.parse_while_expr()
  } else if self.peek_kind() == match_kw() {
    self.parse_match_expr()
  } else if self.peek_kind() == do_kw() {
    self.parse_do_expr()
  } else if self.peek_kind() == try_kw() {
    self.parse_try_expr()
  } else if self.peek_kind() == record_kw() {
    self.parse_record_expr()
  } else if self.peek_kind() == map_kw() {
    self.parse_map_expr()
  } else if self.peek_kind() == lparen() {
    self.parse_paren_expr()
  } else if self.peek_kind() == lbracket() {
    self.parse_array_expr()
  } else if self.peek_kind() == lbrace() {
    let start = self.pos
    let body = self.parse_block()
    let span = self.span_from(start)
    @core.Expr::Block(body~, span~)
  } else {
    self.parse_or_expr()
  }
}

///|
fn AstParser::parse_pipe_expr(self : AstParser) -> @core.Expr raise ParseError {
  let mut left = self.parse_cmp_expr()
  while {
          self.skip_trivia()
          self.peek_kind() == pipe() &&
          self.peek_non_trivia_kind(self.pos + 1) == gt()
        } {
    let _ = self.bump()
    self.skip_trivia()
    let _ = self.expect(gt(), ">")
    let right = self.parse_cmp_expr()
    left = pipe_apply(left, right)
  }
  left
}

///|
fn AstParser::parse_or_expr(self : AstParser) -> @core.Expr raise ParseError {
  let mut left = self.parse_and_expr()
  while {
          self.skip_trivia()
          self.peek_kind() == or_or()
        } {
    let _ = self.bump()
    let right = self.parse_and_expr()
    let left_span = left.span()
    let right_span = right.span()
    let span = @core.Span::merge(left_span, right_span)
    let then_expr = @core.Expr::Bool(value=true, span~)
    let then_body = @core.Module::{
      stmts: [@core.Stmt::Expr(expr=then_expr, span~)],
    }
    let else_body = @core.Module::{
      stmts: [@core.Stmt::Expr(expr=right, span=right_span)],
    }
    left = @core.Expr::If(cond=left, then_body~, else_body~, span~)
  }
  left
}

///|
fn AstParser::parse_and_expr(self : AstParser) -> @core.Expr raise ParseError {
  let mut left = self.parse_pipe_expr()
  while {
          self.skip_trivia()
          self.peek_kind() == and_and()
        } {
    let _ = self.bump()
    let right = self.parse_pipe_expr()
    let left_span = left.span()
    let right_span = right.span()
    let span = @core.Span::merge(left_span, right_span)
    let else_expr = @core.Expr::Bool(value=false, span~)
    let then_body = @core.Module::{
      stmts: [@core.Stmt::Expr(expr=right, span=right_span)],
    }
    let else_body = @core.Module::{
      stmts: [@core.Stmt::Expr(expr=else_expr, span~)],
    }
    left = @core.Expr::If(cond=left, then_body~, else_body~, span~)
  }
  left
}

///|
fn AstParser::parse_cmp_expr(self : AstParser) -> @core.Expr raise ParseError {
  let mut left = self.parse_add_expr()
  while {
          self.skip_trivia()
          self.peek_kind() == eqeq() ||
          self.peek_kind() == neq() ||
          self.peek_kind() == lt() ||
          self.peek_kind() == lte() ||
          self.peek_kind() == gt() ||
          self.peek_kind() == gte()
        } {
    let op = self.peek_kind()
    let _ = self.bump()
    let right = self.parse_add_expr()
    left = cmp_expr_from_op(op, left, right)
  }
  left
}

///|
fn cmp_expr_from_op(
  op : @cst.SyntaxKind,
  left : @core.Expr,
  right : @core.Expr,
) -> @core.Expr {
  match op {
    k if k == eqeq() => call2("__eq", left, right)
    k if k == neq() => call1("not", call2("__eq", left, right))
    k if k == lt() => call2("__lt", left, right)
    k if k == gt() => call2("__lt", right, left)
    k if k == lte() =>
      call2("or", call2("__lt", left, right), call2("__eq", left, right))
    _ => call2("or", call2("__lt", right, left), call2("__eq", left, right))
  }
}

///|
fn call1(name : String, value : @core.Expr) -> @core.Expr {
  let span = value.span()
  @core.Expr::Call(
    name~,
    args=[@core.CallArg::{ label: None, expr: value, span }],
    span~,
  )
}

///|
fn call2(name : String, left : @core.Expr, right : @core.Expr) -> @core.Expr {
  let left_span = left.span()
  let right_span = right.span()
  let span = @core.Span::merge(left_span, right_span)
  @core.Expr::Call(
    name~,
    args=[
      @core.CallArg::{ label: None, expr: left, span: left_span },
      @core.CallArg::{ label: None, expr: right, span: right_span },
    ],
    span~,
  )
}

///|
fn pipe_apply(
  left : @core.Expr,
  right : @core.Expr,
) -> @core.Expr raise ParseError {
  match right {
    @core.Expr::Ident(name~, span~) => {
      let left_span = left.span()
      let call_span = @core.Span::merge(left_span, span)
      @core.Expr::Call(
        name~,
        args=[@core.CallArg::{ label: None, expr: left, span: left_span }],
        span=call_span,
      )
    }
    @core.Expr::Call(name~, args~, span~) => {
      let left_span = left.span()
      let call_span = @core.Span::merge(left_span, span)
      let out : Array[@core.CallArg] = []
      out.push(@core.CallArg::{ label: None, expr: left, span: left_span })
      for arg in args {
        out.push(arg)
      }
      @core.Expr::Call(name~, args=out, span=call_span)
    }
    _ =>
      raise ParseError::UnexpectedToken(
        expected="call",
        got=right.to_string(),
        span=right.span(),
      )
  }
}

///|
fn AstParser::parse_add_expr(self : AstParser) -> @core.Expr raise ParseError {
  let mut left = self.parse_mul_expr()
  while {
          self.skip_trivia()
          self.peek_kind() == plus() || self.peek_kind() == minus()
        } {
    let op = self.peek_kind()
    let _ = self.bump()
    let right = self.parse_mul_expr()
    let name = if op == plus() { "__add" } else { "__sub" }
    left = call2(name, left, right)
  }
  left
}

///|
fn AstParser::parse_mul_expr(self : AstParser) -> @core.Expr raise ParseError {
  let mut left = self.parse_unary_expr()
  while {
          self.skip_trivia()
          self.peek_kind() == star() || self.peek_kind() == slash()
        } {
    let op = self.peek_kind()
    let _ = self.bump()
    let right = self.parse_unary_expr()
    let name = if op == star() { "__mul" } else { "__div" }
    left = call2(name, left, right)
  }
  left
}

///|
fn AstParser::parse_unary_expr(self : AstParser) -> @core.Expr raise ParseError {
  self.skip_trivia()
  match self.peek_kind() {
    k if k == minus() => {
      let _ = self.bump()
      let value = self.parse_unary_expr()
      call1("__neg", value)
    }
    k if k == bang() => {
      let _ = self.bump()
      let value = self.parse_unary_expr()
      call1("not", value)
    }
    _ => self.parse_call_or_primary()
  }
}

///|
fn AstParser::parse_if_expr(self : AstParser) -> @core.Expr raise ParseError {
  let start = self.pos
  let _ = self.expect(if_kw(), "if")
  let cond = self.parse_expr()
  let then_body = self.parse_block()
  let _ = self.expect(else_kw(), "else")
  let else_body = if self.peek_kind() == lbrace() {
    self.parse_block()
  } else {
    let expr = self.parse_expr()
    let expr_span = expr.span()
    @core.Module::{ stmts: [@core.Stmt::Expr(expr~, span=expr_span)] }
  }
  let span = self.span_from(start)
  @core.Expr::If(cond~, then_body~, else_body~, span~)
}

///|
fn AstParser::parse_while_expr(self : AstParser) -> @core.Expr raise ParseError {
  let start = self.pos
  let _ = self.expect(while_kw(), "while")
  let cond = self.parse_expr()
  let body = self.parse_block()
  let span = self.span_from(start)
  @core.Expr::While(cond~, body~, span~)
}

///|
fn AstParser::parse_match_expr(self : AstParser) -> @core.Expr raise ParseError {
  let start = self.pos
  let _ = self.expect(match_kw(), "match")
  let scrutinee = self.parse_expr()
  let _ = self.expect(lbrace(), "{")
  let arms : Array[@core.MatchArm] = []
  while {
          self.skip_trivia()
          self.peek_kind() != rbrace()
        } {
    if self.peek_kind() == eof() {
      raise ParseError::UnexpectedEof(span=self.token_span())
    }
    let pat = self.parse_pattern()
    self.skip_trivia()
    let mut cond : @core.Expr? = None
    if self.peek_kind() == if_kw() {
      let _ = self.bump()
      cond = Some(self.parse_expr())
    }
    let _ = self.expect(arrow(), "=>")
    let expr = self.parse_expr()
    let mut arm_span = @core.Span::merge(pat.span(), expr.span())
    match cond {
      Some(c) => arm_span = @core.Span::merge(arm_span, c.span())
      None => ()
    }
    arms.push(@core.MatchArm::{ pat, cond, expr, span: arm_span })
    let _ = self.eat(comma())
    let _ = self.eat(semicolon())

  }
  let _ = self.expect(rbrace(), "}")
  let span = self.span_from(start)
  @core.Expr::Match(scrutinee~, arms~, span~)
}

///|
fn AstParser::parse_do_expr(self : AstParser) -> @core.Expr raise ParseError {
  let start = self.pos
  let _ = self.expect(do_kw(), "do")
  let body = self.parse_block()
  let span = self.span_from(start)
  @core.Expr::Do(body~, span~)
}

///|
fn AstParser::parse_try_expr(self : AstParser) -> @core.Expr raise ParseError {
  let start = self.pos
  let _ = self.expect(try_kw(), "try")
  let try_body = self.parse_block()
  self.skip_trivia()
  let _ = self.expect(catch_kw(), "catch")
  let catch_body = self.parse_block()
  let span = self.span_from(start)
  @core.Expr::Try(try_body~, catch_body~, span~)
}

///|
fn AstParser::parse_record_expr(
  self : AstParser,
) -> @core.Expr raise ParseError {
  let start = self.pos
  let _ = self.expect(record_kw(), "record")
  let _ = self.expect(lbrace(), "{")
  let fields : Array[@core.RecordFieldExpr] = []
  while {
          self.skip_trivia()
          self.peek_kind() != rbrace()
        } {
    if self.peek_kind() == eof() {
      raise ParseError::UnexpectedEof(span=self.token_span())
    }
    let field_start = self.pos
    let name_tok = self.expect(name(), "field")
    let _ = self.expect(colon(), ":")
    let expr = self.parse_expr()
    let field_span = self.span_from(field_start)
    fields.push(@core.RecordFieldExpr::{
      name: name_tok.text(),
      expr,
      span: field_span,
    })
    let _ = self.eat(comma())
    let _ = self.eat(semicolon())

  }
  let _ = self.expect(rbrace(), "}")
  let span = self.span_from(start)
  @core.Expr::Record(fields~, span~)
}

///|
fn AstParser::parse_map_expr(self : AstParser) -> @core.Expr raise ParseError {
  let start = self.pos
  let _ = self.expect(map_kw(), "map")
  let _ = self.expect(lbrace(), "{")
  let fields : Array[@core.MapFieldExpr] = []
  while {
          self.skip_trivia()
          self.peek_kind() != rbrace()
        } {
    if self.peek_kind() == eof() {
      raise ParseError::UnexpectedEof(span=self.token_span())
    }
    let field_start = self.pos
    let key_tok = self.peek()
    if key_tok.kind() != name() && key_tok.kind() != string_lit() {
      raise ParseError::UnexpectedToken(
        expected="map key",
        got=key_tok.text(),
        span=self.token_span(),
      )
    }
    let _ = self.bump()
    let _ = self.expect(colon(), ":")
    let expr = self.parse_expr()
    let field_span = self.span_from(field_start)
    fields.push(@core.MapFieldExpr::{
      key: key_tok.text(),
      expr,
      span: field_span,
    })
    let _ = self.eat(comma())
    let _ = self.eat(semicolon())

  }
  let _ = self.expect(rbrace(), "}")
  let span = self.span_from(start)
  @core.Expr::Map(fields~, span~)
}

///|
fn AstParser::parse_array_expr(self : AstParser) -> @core.Expr raise ParseError {
  let start = self.pos
  let _ = self.expect(lbracket(), "[")
  let items : Array[@core.Expr] = []
  while {
          self.skip_trivia()
          self.peek_kind() != rbracket()
        } {
    if self.peek_kind() == eof() {
      raise ParseError::UnexpectedEof(span=self.token_span())
    }
    items.push(self.parse_expr())
    let _ = self.eat(comma())
    let _ = self.eat(semicolon())

  }
  let _ = self.expect(rbracket(), "]")
  let span = self.span_from(start)
  @core.Expr::Array(items~, span~)
}

///|
fn AstParser::parse_effect_list(
  self : AstParser,
) -> Array[@core.EffectAtom] raise ParseError {
  let effects : Array[@core.EffectAtom] = []
  self.skip_trivia()
  if self.peek_kind() == name() && self.peek().text() == "with" {
    let _ = self.bump()
    self.skip_trivia()
    let _ = self.expect(lbrace(), "{")
    self.skip_trivia()
    if self.peek_kind() != rbrace() {
      let name_tok = self.expect(name(), "effect")
      effects.push(effect_atom_from_name(name_tok.text()))
      while {
              self.skip_trivia()
              self.peek_kind() == comma()
            } {
        let _ = self.bump()
        self.skip_trivia()
        if self.peek_kind() == rbrace() {
          break
        }
        let tok = self.expect(name(), "effect")
        effects.push(effect_atom_from_name(tok.text()))
      }
    }
    let _ = self.expect(rbrace(), "}")

  }
  effects
}

///|
fn AstParser::parse_param_list(
  self : AstParser,
  params : Map[String, Bool],
) -> Array[@core.FuncParam] raise ParseError {
  let _ = self.expect(lparen(), "(")
  let out : Array[@core.FuncParam] = []
  self.skip_trivia()
  if self.peek_kind() != rparen() {
    out.push(self.parse_param(params))
    while {
            self.skip_trivia()
            self.peek_kind() == comma()
          } {
      let _ = self.bump()
      self.skip_trivia()
      if self.peek_kind() == rparen() {
        break
      }
      out.push(self.parse_param(params))
    }
  }
  let _ = self.expect(rparen(), ")")
  out
}

///|
fn AstParser::parse_param(
  self : AstParser,
  params : Map[String, Bool],
) -> @core.FuncParam raise ParseError {
  let name_start = self.pos
  let name_tok = self.expect(name(), "param")
  let name_span = self.span_from(name_start)
  let (base, label) = split_param_label(name_tok.text(), name_span)
  self.skip_trivia()
  let _ = self.expect(colon(), ":")
  let ty = self.parse_type_with_params(params)
  @core.FuncParam::{ name: base, label, ty }
}

///|
fn split_param_label(
  name : String,
  span : @core.Span,
) -> (String, @core.ParamLabel) raise ParseError {
  let chars : Array[Char] = []
  for c in name {
    chars.push(c)
  }
  if chars.is_empty() {
    raise ParseError::UnexpectedToken(expected="param", got=name, span~)
  }
  let last = chars[chars.length() - 1]
  if last == '~' || last == '?' {
    if chars.length() == 1 {
      raise ParseError::UnexpectedToken(expected="param", got=name, span~)
    }
    let buf = StringBuilder::new()
    for i in 0..<(chars.length() - 1) {
      buf.write_char(chars[i])
    }
    let label = if last == '~' {
      @core.ParamLabel::Required
    } else {
      @core.ParamLabel::Optional
    }
    (buf.to_string(), label)
  } else {
    (name, @core.ParamLabel::Positional)
  }
}

///|
fn AstParser::parse_type(self : AstParser) -> @core.Type raise ParseError {
  self.parse_type_with_params({})
}

///|
fn AstParser::parse_type_with_params(
  self : AstParser,
  params : Map[String, Bool],
) -> @core.Type raise ParseError {
  self.skip_trivia()
  let tok = self.peek()
  match tok.kind() {
    k if k == name() => {
      let name_start = self.pos
      let _ = self.bump()
      let name_span = self.span_from(name_start)
      let name = tok.text()
      let args = self.parse_type_args(params)
      match name {
        "Int" =>
          if args.is_empty() {
            @core.Type::Int
          } else {
            raise ParseError::UnexpectedToken(
              expected="type",
              got=name,
              span=name_span,
            )
          }
        "Float" =>
          if args.is_empty() {
            @core.Type::Float
          } else {
            raise ParseError::UnexpectedToken(
              expected="type",
              got=name,
              span=name_span,
            )
          }
        "Double" =>
          if args.is_empty() {
            @core.Type::Double
          } else {
            raise ParseError::UnexpectedToken(
              expected="type",
              got=name,
              span=name_span,
            )
          }
        "Bool" =>
          if args.is_empty() {
            @core.Type::Bool
          } else {
            raise ParseError::UnexpectedToken(
              expected="type",
              got=name,
              span=name_span,
            )
          }
        "String" =>
          if args.is_empty() {
            @core.Type::String
          } else {
            raise ParseError::UnexpectedToken(
              expected="type",
              got=name,
              span=name_span,
            )
          }
        "@core.Path" =>
          if args.is_empty() {
            @core.Type::Path
          } else {
            raise ParseError::UnexpectedToken(
              expected="type",
              got=name,
              span=name_span,
            )
          }
        "Unit" =>
          if args.is_empty() {
            @core.Type::Unit
          } else {
            raise ParseError::UnexpectedToken(
              expected="type",
              got=name,
              span=name_span,
            )
          }
        "Array" =>
          if args.length() == 1 {
            @core.Type::Array(args[0])
          } else {
            raise ParseError::UnexpectedToken(
              expected="Array[T]",
              got=name,
              span=name_span,
            )
          }
        "Map" =>
          if args.length() == 1 {
            @core.Type::Map(args[0])
          } else {
            raise ParseError::UnexpectedToken(
              expected="Map[T]",
              got=name,
              span=name_span,
            )
          }
        "ArrayBuilder" =>
          if args.length() == 1 {
            @core.Type::ArrayBuilder(args[0])
          } else {
            raise ParseError::UnexpectedToken(
              expected="ArrayBuilder[T]",
              got=name,
              span=name_span,
            )
          }
        "MapBuilder" =>
          if args.length() == 1 {
            @core.Type::MapBuilder(args[0])
          } else {
            raise ParseError::UnexpectedToken(
              expected="MapBuilder[T]",
              got=name,
              span=name_span,
            )
          }
        _ =>
          if params.contains(name) {
            if not(args.is_empty()) {
              raise ParseError::UnexpectedToken(
                expected="type param",
                got=name,
                span=name_span,
              )
            }
            @core.Type::Param(name)
          } else {
            @core.Type::Named(name~, args~)
          }
      }
    }
    k if k == lparen() =>
      match self.try_parse_fn_type(params) {
        Some(t) => t
        None => self.parse_tuple_type(params)
      }
    _ =>
      raise ParseError::UnexpectedToken(
        expected="type",
        got=tok.text(),
        span=self.token_span(),
      )
  }
}

///|
fn effect_atom_from_name(name : String) -> @core.EffectAtom {
  if name.length() == 0 {
    @core.EffectAtom::Const(name)
  } else {
    let chars = name.to_array()
    let c = chars[0]
    if c >= 'a' && c <= 'z' {
      @core.EffectAtom::Var(name)
    } else {
      @core.EffectAtom::Const(name)
    }
  }
}

///|
fn AstParser::try_parse_fn_type(
  self : AstParser,
  params : Map[String, Bool],
) -> @core.Type? {
  let saved = self.pos
  let result : @core.Type? = try {
    let params_list = self.parse_param_list(params)
    self.skip_trivia()
    if self.peek_kind() != thin_arrow() {
      raise ParseError::UnexpectedToken(
        expected="->",
        got=self.peek().text(),
        span=self.span_from(saved),
      )
    }
    let _ = self.bump()
    let ret = self.parse_type_with_params(params)
    let effects = self.parse_effect_list()
    Some(@core.Type::Func(params=params_list, ret~, effects~))
  } catch {
    _ => None
  }
  match result {
    Some(_) => result
    None => {
      self.pos = saved
      None
    }
  }
}

///|
fn AstParser::parse_tuple_type(
  self : AstParser,
  params : Map[String, Bool],
) -> @core.Type raise ParseError {
  let _ = self.expect(lparen(), "(")
  let first = self.parse_type_with_params(params)
  self.skip_trivia()
  if self.peek_kind() == comma() {
    let items : Array[@core.Type] = []
    items.push(first)
    while {
            self.skip_trivia()
            self.peek_kind() == comma()
          } {
      let _ = self.bump()
      self.skip_trivia()
      if self.peek_kind() == rparen() {
        break
      }
      items.push(self.parse_type_with_params(params))
    }
    let _ = self.expect(rparen(), ")")
    @core.Type::Tuple(items)
  } else {
    let _ = self.expect(rparen(), ")")
    first
  }
}

///|
fn AstParser::parse_type_args(
  self : AstParser,
  params : Map[String, Bool],
) -> Array[@core.Type] raise ParseError {
  let args : Array[@core.Type] = []
  self.skip_trivia()
  if self.peek_kind() == lbracket() {
    let _ = self.bump()
    self.skip_trivia()
    if self.peek_kind() != rbracket() {
      args.push(self.parse_type_with_params(params))
      while {
              self.skip_trivia()
              self.peek_kind() == comma()
            } {
        let _ = self.bump()
        self.skip_trivia()
        if self.peek_kind() == rbracket() {
          break
        }
        args.push(self.parse_type_with_params(params))
      }
    }
    let _ = self.expect(rbracket(), "]")

  }
  args
}

///|
fn AstParser::try_parse_arrow_fn(self : AstParser) -> @core.Expr? {
  let saved = self.pos
  let result : @core.Expr? = try {
    let params = self.parse_param_list({})
    self.skip_trivia()
    if self.peek_kind() != thin_arrow() && self.peek_kind() != lbrace() {
      raise ParseError::UnexpectedToken(
        expected="-> or {",
        got=self.peek().text(),
        span=self.span_from(saved),
      )
    }
    let mut ret : @core.Type? = None
    let mut effects : Array[@core.EffectAtom] = []
    if self.peek_kind() == thin_arrow() {
      let _ = self.bump()
      ret = Some(self.parse_type())
      effects = self.parse_effect_list()
    }
    let body = self.parse_block()
    let span = self.span_from(saved)
    Some(@core.Expr::Fn(params~, ret~, effects~, body~, span~))
  } catch {
    _ => None
  }
  match result {
    Some(_) => result
    None => {
      self.pos = saved
      None
    }
  }
}

///|
fn AstParser::parse_paren_expr(self : AstParser) -> @core.Expr raise ParseError {
  match self.try_parse_arrow_fn() {
    Some(expr) => expr
    None => {
      let start = self.pos
      let _ = self.expect(lparen(), "(")
      let first = self.parse_expr()
      self.skip_trivia()
      if self.peek_kind() == comma() {
        let items : Array[@core.Expr] = []
        items.push(first)
        while {
                self.skip_trivia()
                self.peek_kind() == comma()
              } {
          let _ = self.bump()
          self.skip_trivia()
          if self.peek_kind() == rparen() {
            break
          }
          items.push(self.parse_expr())
        }
        let _ = self.expect(rparen(), ")")
        let span = self.span_from(start)
        @core.Expr::Tuple(items~, span~)
      } else {
        let _ = self.expect(rparen(), ")")
        first
      }
    }
  }
}

///|
fn AstParser::parse_pattern(self : AstParser) -> @core.Pat raise ParseError {
  self.skip_trivia()
  let start = self.pos
  let tok = self.peek()
  match tok.kind() {
    k if k == lparen() => self.parse_tuple_pattern()
    k if k == record_kw() => self.parse_record_pattern()
    k if k == int_lit() => {
      let _ = self.bump()
      let parsed : Result[Int, @strconv.StrConvError] = try? @strconv.parse_int(
        tok.text(),
      )
      match parsed {
        Ok(v) => {
          let span = self.span_from(start)
          @core.Pat::Int(value=v, span~)
        }
        Err(_) =>
          raise ParseError::UnexpectedToken(
            expected="int",
            got=tok.text(),
            span=self.token_span(),
          )
      }
    }
    k if k == float_lit() => {
      let _ = self.bump()
      let text = tok.text()
      let len = text.length()
      let mut is_float = false
      let mut raw = text
      if len > 0 {
        let last = text[len - 1]
        if last == 'f' || last == 'F' {
          is_float = true
          raw = (try! text[0:len - 1]).to_string()
        }
      }
      let parsed : Result[Double, @strconv.StrConvError] = try? @strconv.parse_double(
        raw,
      )
      match parsed {
        Ok(v) => {
          let span = self.span_from(start)
          if is_float {
            @core.Pat::Float(value=Float::from_double(v), span~)
          } else {
            @core.Pat::Double(value=v, span~)
          }
        }
        Err(_) =>
          raise ParseError::UnexpectedToken(
            expected="float",
            got=tok.text(),
            span=self.token_span(),
          )
      }
    }
    k if k == bool_lit() => {
      let _ = self.bump()
      if tok.text() == "true" {
        let span = self.span_from(start)
        @core.Pat::Bool(value=true, span~)
      } else if tok.text() == "false" {
        let span = self.span_from(start)
        @core.Pat::Bool(value=false, span~)
      } else {
        raise ParseError::UnexpectedToken(
          expected="bool",
          got=tok.text(),
          span=self.token_span(),
        )
      }
    }
    k if k == string_lit() => {
      let _ = self.bump()
      let span = self.span_from(start)
      @core.Pat::String(value=tok.text(), span~)
    }
    k if k == name() => {
      let _ = self.bump()
      if tok.text() == "_" {
        let span = self.span_from(start)
        @core.Pat::Wildcard(span~)
      } else if @core.is_ctor_name(tok.text()) {
        let args : Array[@core.Pat] = []
        if self.peek_kind() == lparen() {
          let _ = self.bump()
          self.skip_trivia()
          if self.peek_kind() != rparen() {
            args.push(self.parse_pattern())
            while {
                    self.skip_trivia()
                    self.peek_kind() == comma()
                  } {
              let _ = self.bump()
              args.push(self.parse_pattern())
            }
          }
          let _ = self.expect(rparen(), ")")

        }
        let span = self.span_from(start)
        @core.Pat::Ctor(name=tok.text(), args~, span~)
      } else {
        let span = self.span_from(start)
        @core.Pat::Bind(name=tok.text(), span~)
      }
    }
    _ =>
      raise ParseError::UnexpectedToken(
        expected="pattern",
        got=tok.text(),
        span=self.token_span(),
      )
  }
}

///|
fn AstParser::parse_tuple_pattern(
  self : AstParser,
) -> @core.Pat raise ParseError {
  let start = self.pos
  let _ = self.expect(lparen(), "(")
  let first = self.parse_pattern()
  self.skip_trivia()
  if self.peek_kind() == comma() {
    let items : Array[@core.Pat] = []
    items.push(first)
    while {
            self.skip_trivia()
            self.peek_kind() == comma()
          } {
      let _ = self.bump()
      self.skip_trivia()
      if self.peek_kind() == rparen() {
        break
      }
      items.push(self.parse_pattern())
    }
    let _ = self.expect(rparen(), ")")
    let span = self.span_from(start)
    @core.Pat::Tuple(items~, span~)
  } else {
    let _ = self.expect(rparen(), ")")
    first
  }
}

///|
fn AstParser::parse_record_pattern(
  self : AstParser,
) -> @core.Pat raise ParseError {
  let start = self.pos
  let _ = self.expect(record_kw(), "record")
  let _ = self.expect(lbrace(), "{")
  let fields : Array[@core.RecordFieldPat] = []
  while {
          self.skip_trivia()
          self.peek_kind() != rbrace()
        } {
    if self.peek_kind() == eof() {
      raise ParseError::UnexpectedEof(span=self.token_span())
    }
    let field_start = self.pos
    let name_tok = self.expect(name(), "field")
    let _ = self.expect(colon(), ":")
    let pat = self.parse_pattern()
    let field_span = self.span_from(field_start)
    fields.push(@core.RecordFieldPat::{
      name: name_tok.text(),
      pat,
      span: field_span,
    })
    let _ = self.eat(comma())
    let _ = self.eat(semicolon())

  }
  let _ = self.expect(rbrace(), "}")
  let span = self.span_from(start)
  @core.Pat::Record(fields~, span~)
}

///|
fn AstParser::parse_call_or_primary(
  self : AstParser,
) -> @core.Expr raise ParseError {
  self.skip_trivia()
  let tok = self.peek()
  if tok.kind() == name() {
    let start = self.pos
    let name_tok = self.bump()
    self.skip_trivia()
    if self.peek_kind() == lparen() {
      let _ = self.bump()
      let args = self.parse_args()
      let _ = self.expect(rparen(), ")")
      let span = self.span_from(start)
      @core.Expr::Call(name=name_tok.text(), args~, span~)
    } else {
      let span = self.span_from(start)
      @core.Expr::Ident(name=name_tok.text(), span~)
    }
  } else {
    self.parse_primary()
  }
}

///|
fn AstParser::parse_args(
  self : AstParser,
) -> Array[@core.CallArg] raise ParseError {
  let args : Array[@core.CallArg] = []
  self.skip_trivia()
  if self.peek_kind() != rparen() {
    args.push(self.parse_arg())
    while {
            self.skip_trivia()
            self.peek_kind() == comma()
          } {
      let _ = self.bump()
      args.push(self.parse_arg())
    }
  }
  args
}

///|
fn AstParser::parse_arg(self : AstParser) -> @core.CallArg raise ParseError {
  self.skip_trivia()
  let start = self.pos
  if self.peek_kind() == name() &&
    self.peek_non_trivia_kind(self.pos + 1) == eq() {
    let label_tok = self.expect(name(), "label")
    if label_tok.text().has_suffix("?") || label_tok.text().has_suffix("~") {
      raise ParseError::UnexpectedToken(
        expected="label",
        got=label_tok.text(),
        span=self.token_span(),
      )
    }
    let _ = self.expect(eq(), "=")
    let expr = self.parse_expr()
    let span = self.span_from(start)
    @core.CallArg::{ label: Some(label_tok.text()), expr, span }
  } else {
    let expr = self.parse_expr()
    let span = self.span_from(start)
    @core.CallArg::{ label: None, expr, span }
  }
}

///|
fn AstParser::parse_primary(self : AstParser) -> @core.Expr raise ParseError {
  self.skip_trivia()
  let start = self.pos
  let tok = self.peek()
  match tok.kind() {
    k if k == int_lit() => {
      let _ = self.bump()
      let parsed : Result[Int, @strconv.StrConvError] = try? @strconv.parse_int(
        tok.text(),
      )
      match parsed {
        Ok(v) => {
          let span = self.span_from(start)
          @core.Expr::Int(value=v, span~)
        }
        Err(_) =>
          raise ParseError::UnexpectedToken(
            expected="int",
            got=tok.text(),
            span=self.token_span(),
          )
      }
    }
    k if k == float_lit() => {
      let _ = self.bump()
      let text = tok.text()
      let len = text.length()
      let mut is_float = false
      let mut raw = text
      if len > 0 {
        let last = text[len - 1]
        if last == 'f' || last == 'F' {
          is_float = true
          raw = (try! text[0:len - 1]).to_string()
        }
      }
      let parsed : Result[Double, @strconv.StrConvError] = try? @strconv.parse_double(
        raw,
      )
      match parsed {
        Ok(v) => {
          let span = self.span_from(start)
          if is_float {
            @core.Expr::Float(value=Float::from_double(v), span~)
          } else {
            @core.Expr::Double(value=v, span~)
          }
        }
        Err(_) =>
          raise ParseError::UnexpectedToken(
            expected="float",
            got=tok.text(),
            span=self.token_span(),
          )
      }
    }
    k if k == bool_lit() => {
      let _ = self.bump()
      if tok.text() == "true" {
        let span = self.span_from(start)
        @core.Expr::Bool(value=true, span~)
      } else if tok.text() == "false" {
        let span = self.span_from(start)
        @core.Expr::Bool(value=false, span~)
      } else {
        raise ParseError::UnexpectedToken(
          expected="bool",
          got=tok.text(),
          span=self.token_span(),
        )
      }
    }
    k if k == string_lit() => {
      let _ = self.bump()
      let span = self.span_from(start)
      @core.Expr::String(value=tok.text(), span~)
    }
    k if k == string_interp_lit() => {
      let _ = self.bump()
      let span = self.span_from(start)
      desugar_string_interp(tok.text(), span)
    }
    k if k == char_lit() => {
      let _ = self.bump()
      let chars = tok.text().to_array()
      if chars.length() == 1 {
        let span = self.span_from(start)
        @core.Expr::Int(value=chars[0].to_int(), span~)
      } else {
        raise ParseError::UnexpectedToken(
          expected="char",
          got=tok.text(),
          span=self.token_span(),
        )
      }
    }
    k if k == name() => {
      let _ = self.bump()
      let span = self.span_from(start)
      @core.Expr::Ident(name=tok.text(), span~)
    }
    _ =>
      raise ParseError::UnexpectedToken(
        expected="expr",
        got=tok.text(),
        span=self.token_span(),
      )
  }
}

///|
fn desugar_string_interp(
  raw : String,
  span : @core.Span,
) -> @core.Expr raise ParseError {
  let parts : Array[@core.Expr] = []
  let chars = raw.to_array()
  let len = chars.length()
  let mut i = 0
  let buf = StringBuilder::new()
  while i < len {
    if i + 1 < len && chars[i] == '\\' && chars[i + 1] == '(' {
      if buf.to_string().length() > 0 {
        parts.push(@core.Expr::String(value=buf.to_string(), span~))
        buf.reset()
      }
      i += 2
      let expr_buf = StringBuilder::new()
      let mut depth = 1
      while i < len && depth > 0 {
        if chars[i] == '(' {
          depth += 1
          expr_buf.write_char(chars[i])
        } else if chars[i] == ')' {
          depth -= 1
          if depth > 0 {
            expr_buf.write_char(chars[i])
          }
        } else {
          expr_buf.write_char(chars[i])
        }
        i += 1
      }
      let expr_text = expr_buf.to_string()
      let expr_ast = parse_ast(expr_text) catch { e => raise e }
      let inner = if expr_ast.stmts.length() == 1 {
        match expr_ast.stmts[0] {
          @core.Stmt::Expr(expr~, span~) => {
            let _ = span
            expr
          }
          _ =>
            raise ParseError::UnexpectedToken(
              expected="expr in interpolation",
              got=expr_text,
              span~,
            )
        }
      } else {
        raise ParseError::UnexpectedToken(
          expected="single expr in interpolation",
          got=expr_text,
          span~,
        )
      }
      parts.push(
        @core.Expr::Call(
          name="__to_string",
          args=[@core.CallArg::{ label: None, expr: inner, span }],
          span~,
        ),
      )
    } else if chars[i] == '\\' && i + 1 < len {
      match chars[i + 1] {
        'n' => buf.write_char('\n')
        't' => buf.write_char('\t')
        '"' => buf.write_char('"')
        '\\' => buf.write_char('\\')
        c => buf.write_char(c)
      }
      i += 2
    } else {
      buf.write_char(chars[i])
      i += 1
    }
  }
  if buf.to_string().length() > 0 {
    parts.push(@core.Expr::String(value=buf.to_string(), span~))
  }
  if parts.length() == 0 {
    @core.Expr::String(value="", span~)
  } else if parts.length() == 1 {
    parts[0]
  } else {
    let mut result = parts[0]
    for j in 1..<parts.length() {
      result = @core.Expr::Call(
        name="string_concat",
        args=[
          @core.CallArg::{ label: None, expr: result, span },
          @core.CallArg::{ label: None, expr: parts[j], span },
        ],
        span~,
      )
    }
    result
  }
}

///|
/// Parse input into AST
pub fn parse_ast(input : String) -> @core.Module raise ParseError {
  let tokens = tokenize(input)
  let parser = AstParser::new(tokens)
  parser.parse()
}
