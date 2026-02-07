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
    k if k == export_kw() => self.parse_export_stmt()
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
    // consume dot-separated path segments (e.g. foo.xsh)
    while self.at(dot()) {
      self.bump()
      if self.at(name()) {
        self.bump()
      }
    }
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
fn Parser::parse_export_stmt(self : Parser) -> Unit {
  self.builder.start_node(export_stmt())
  self.bump() // export
  self.skip_trivia()
  // Check what follows export
  if self.at(enum_kw()) {
    // export enum Name { ... }
    self.parse_enum_stmt()
  } else if self.at(type_kw()) {
    // export type Name = ...
    self.parse_type_alias_stmt()
  } else if self.at(let_kw()) {
    // export let name = ...
    self.parse_let_stmt()
  } else if self.at(lbrace()) {
    // export { name1, name2, ... }
    self.bump()
    while not(self.at(rbrace())) && not(self.at(eof())) {
      self.skip_trivia()
      if self.at(name()) {
        self.bump()
      }
      self.skip_trivia()
      if self.at(comma()) {
        self.bump()
      }
    }
    if self.at(rbrace()) {
      self.bump()
    }
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
  } else if self.at(raise_kw()) {
    self.parse_raise_expr()
  } else if self.at(await_kw()) {
    self.parse_await_expr()
  } else if self.at(yield_kw()) {
    self.parse_yield_expr()
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
  self.parse_bit_or_expr()
  while {
          self.skip_trivia()
          self.at(pipe_gt())
        } {
    self.bump()
    self.parse_bit_or_expr()
  }
}

///|
fn Parser::parse_bit_or_expr(self : Parser) -> Unit {
  self.parse_bit_xor_expr()
  while {
          self.skip_trivia()
          self.at(bit_or())
        } {
    self.bump()
    self.parse_bit_xor_expr()
  }
}

///|
fn Parser::parse_bit_xor_expr(self : Parser) -> Unit {
  self.parse_bit_and_expr()
  while {
          self.skip_trivia()
          self.at(bit_xor())
        } {
    self.bump()
    self.parse_bit_and_expr()
  }
}

///|
fn Parser::parse_bit_and_expr(self : Parser) -> Unit {
  self.parse_cmp_expr()
  while {
          self.skip_trivia()
          self.at(bit_and())
        } {
    self.bump()
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
  self.parse_shift_expr()
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
    self.parse_shift_expr()
  }
}

///|
fn Parser::parse_shift_expr(self : Parser) -> Unit {
  self.parse_add_expr()
  while {
          self.skip_trivia()
          self.at(lshift()) || self.at(rshift())
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
          self.at(star()) || self.at(slash()) || self.at(percent())
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
fn Parser::parse_raise_expr(self : Parser) -> Unit {
  self.builder.start_node(raise_expr())
  self.bump() // raise
  self.skip_trivia()
  self.parse_expr()
  self.builder.finish_node()
}

///|
fn Parser::parse_await_expr(self : Parser) -> Unit {
  self.builder.start_node(await_expr())
  self.bump() // await
  self.skip_trivia()
  self.parse_expr()
  self.builder.finish_node()
}

///|
fn Parser::parse_yield_expr(self : Parser) -> Unit {
  self.builder.start_node(yield_expr())
  self.bump() // yield
  self.skip_trivia()
  self.parse_expr()
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
  // Postfix: .method(args), .prop, [index]
  while true {
    self.skip_trivia()
    if self.at(dot()) {
      self.bump()
      self.skip_trivia()
      if self.at(name()) {
        self.bump()
      }
      self.skip_trivia()
      if self.at(lparen()) {
        self.bump()
        self.parse_args()
        self.expect(rparen())
      }
    } else if self.at(lbracket()) {
      self.bump()
      self.parse_expr()
      self.expect(rbracket())
    } else {
      break
    }
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
    k if k == export_kw() => self.parse_export_stmt()
    k if k == test_kw() => self.parse_test_stmt()
    k if k == flake_kw() => self.parse_flake_stmt()
    k if k == name() => {
      let next = self.peek_non_trivia_kind(self.pos + 1)
      if next == eq() || is_compound_assign(next) {
        self.parse_assign_stmt()
      } else {
        self.parse_expr_or_index_assign_stmt()
      }
    }
    _ => {
      self.parse_expr_or_index_assign_stmt()
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
  if not(rec_flag) && not(mut_flag) {
    // Check if this is a pattern: tuple, record, or ctor
    let is_pattern = self.peek_kind() == lparen() ||
      self.peek_kind() == record_kw() ||
      self.peek_kind() == lbracket() ||
      (self.peek_kind() == name() && @core.is_ctor_name(self.peek().text()))
    if is_pattern {
      let pat = self.parse_pattern()
      let _ = self.expect(eq(), "=")
      let expr = self.parse_expr()
      let _ = self.eat(semicolon())
      let span = self.span_from(start)
      return @core.Stmt::LetPat(pat~, expr~, span~)
    }
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
fn is_compound_assign(kind : @cst.SyntaxKind) -> Bool {
  kind == plus_eq() ||
  kind == minus_eq() ||
  kind == star_eq() ||
  kind == slash_eq() ||
  kind == percent_eq()
}

///|
fn compound_to_op(kind : @cst.SyntaxKind) -> String {
  if kind == plus_eq() {
    "__add"
  } else if kind == minus_eq() {
    "__sub"
  } else if kind == star_eq() {
    "__mul"
  } else if kind == slash_eq() {
    "__div"
  } else {
    "__mod"
  }
}

///|
fn AstParser::parse_assign_stmt(
  self : AstParser,
) -> @core.Stmt raise ParseError {
  let start = self.pos
  let name_tok = self.expect(name(), "name")
  self.skip_trivia()
  let op_kind = self.peek_kind()
  if op_kind == eq() {
    let _ = self.bump()
    let expr = self.parse_expr()
    let _ = self.eat(semicolon())
    let span = self.span_from(start)
    @core.Stmt::Assign(name=name_tok.text(), expr~, span~)
  } else {
    let _ = self.bump() // compound assign token
    let op_name = compound_to_op(op_kind)
    let rhs = self.parse_expr()
    let name_span = self.span_from(start)
    let ident : @core.Expr = @core.Expr::Ident(
      name=name_tok.text(),
      span=name_span,
    )
    let desugared = call2(op_name, ident, rhs)
    let _ = self.eat(semicolon())
    let span = self.span_from(start)
    @core.Stmt::Assign(name=name_tok.text(), expr=desugared, span~)
  }
}

///|
/// Parse an expression statement, or an indexed assignment if `=` follows.
fn AstParser::parse_expr_or_index_assign_stmt(
  self : AstParser,
) -> @core.Stmt raise ParseError {
  let start = self.pos
  let expr = self.parse_expr()
  self.skip_trivia()
  // Check if this is an indexed assignment: expr[index] = value
  if self.peek_kind() == eq() {
    match expr {
      @core.Expr::Call(name="__index", args~, ..) =>
        if args.length() == 2 {
          let _ = self.bump() // consume =
          let value = self.parse_expr()
          let _ = self.eat(semicolon())
          let span = self.span_from(start)
          @core.Stmt::IndexAssign(
            target=args[0].expr,
            index=args[1].expr,
            value~,
            span~,
          )
        } else {
          raise ParseError::UnexpectedToken(
            expected="indexed expression",
            got="=",
            span=self.token_span(),
          )
        }
      _ =>
        raise ParseError::UnexpectedToken(
          expected="assignment target",
          got="=",
          span=self.token_span(),
        )
    }
  } else {
    let _ = self.eat(semicolon())
    let span = self.span_from(start)
    @core.Stmt::Expr(expr~, span~)
  }
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
  // Parse import spec: { foo, bar as b }
  let _ = self.expect(lbrace(), "{")
  let items : Array[@core.ImportItem] = []
  while self.peek_kind() != rbrace() {
    self.skip_trivia()
    let name_tok = self.expect(name(), "import name")
    self.skip_trivia()
    let rename : String? = if self.peek_kind() == as_kw() {
      let _ = self.bump()
      self.skip_trivia()
      let alias_tok = self.expect(name(), "alias name")
      Some(alias_tok.text())
    } else {
      None
    }
    items.push(@core.ImportItem::{ name: name_tok.text(), rename })
    self.skip_trivia()
    if self.peek_kind() == comma() {
      let _ = self.bump()

    }
  }
  let _ = self.expect(rbrace(), "}")
  let spec = @core.ImportSpec::{ items, }
  // Expect 'from'
  self.skip_trivia()
  let _ = self.expect(from_kw(), "from")
  self.skip_trivia()
  // Parse module reference: path or hash
  let source = self.parse_module_ref()
  let _ = self.eat(semicolon())
  let span = self.span_from(start)
  @core.Stmt::Import(spec~, source~, span~)
}

///|
/// Parse a module reference: path or hash
fn AstParser::parse_module_ref(
  self : AstParser,
) -> @core.ModuleRef raise ParseError {
  if self.peek_kind() == hash_ref() {
    let hash_tok = self.bump()
    // Remove leading '#' from hash
    let hash_text = hash_tok.text()
    let hash = if hash_text.length() > 1 {
      hash_text.unsafe_substring(start=1, end=hash_text.length())
    } else {
      ""
    }
    @core.ModuleRef::Hash(hash~)
  } else {
    // Path: ./foo/bar.xsh or foo.xsh
    let tok = self.peek()
    if tok.kind() != name() && tok.kind() != string_lit() && tok.kind() != dot() {
      raise ParseError::UnexpectedToken(
        expected="path or hash",
        got=tok.text(),
        span=self.token_span(),
      )
    }
    let buf = StringBuilder::new()
    // Handle leading ./ or ../
    while self.peek_kind() == dot() {
      let _ = self.bump()
      buf.write_char('.')
      if self.peek_kind() == dot() {
        let _ = self.bump()
        buf.write_char('.')
      }
      if self.peek_kind() == slash() {
        let _ = self.bump()
        buf.write_char('/')
      }
    }
    // Path segments
    if self.peek_kind() == name() || self.peek_kind() == string_lit() {
      let seg = self.bump()
      buf.write_string(seg.text())
    }
    while self.peek_kind() == dot() || self.peek_kind() == slash() {
      if self.peek_kind() == dot() {
        let _ = self.bump()
        buf.write_char('.')
      } else {
        let _ = self.bump()
        buf.write_char('/')
      }
      if self.peek_kind() == name() {
        let seg = self.bump()
        buf.write_string(seg.text())
      }
    }
    @core.ModuleRef::Path(path=buf.to_string())
  }
}

///|
fn AstParser::parse_export_stmt(
  self : AstParser,
) -> @core.Stmt raise ParseError {
  let start = self.pos
  let _ = self.expect(export_kw(), "export")
  self.skip_trivia()
  // Check what follows export
  if self.peek_kind() == enum_kw() {
    // export enum Name { ... }
    let enum_stmt = self.parse_enum_stmt()
    match enum_stmt {
      @core.Stmt::EnumDef(name~, params~, ctors~, ..) => {
        let span = self.span_from(start)
        @core.Stmt::ExportEnumDef(name~, params~, ctors~, span~)
      }
      _ => {
        let span = self.span_from(start)
        raise ParseError::UnexpectedToken(
          expected="enum definition",
          got="other statement",
          span~,
        )
      }
    }
  } else if self.peek_kind() == type_kw() {
    // export type Name = ...
    let type_stmt = self.parse_type_alias_stmt()
    match type_stmt {
      @core.Stmt::TypeAlias(name~, params~, target~, ..) => {
        let span = self.span_from(start)
        @core.Stmt::ExportTypeAlias(name~, params~, target~, span~)
      }
      _ => {
        let span = self.span_from(start)
        raise ParseError::UnexpectedToken(
          expected="type alias",
          got="other statement",
          span~,
        )
      }
    }
  } else if self.peek_kind() == let_kw() {
    // export let name = ...
    let let_stmt = self.parse_let_stmt()
    match let_stmt {
      @core.Stmt::Let(rec~, name~, expr~, ..) => {
        let span = self.span_from(start)
        @core.Stmt::ExportLet(rec~, name~, expr~, span~)
      }
      _ => {
        let span = self.span_from(start)
        raise ParseError::UnexpectedToken(
          expected="let statement",
          got="other statement",
          span~,
        )
      }
    }
  } else {
    // export { name1, name2, ... } or export { name1, name2 } from source
    let _ = self.expect(lbrace(), "{")
    let names : Array[String] = []
    while self.peek_kind() != rbrace() {
      self.skip_trivia()
      let name_tok = self.expect(name(), "export name")
      names.push(name_tok.text())
      self.skip_trivia()
      if self.peek_kind() == comma() {
        let _ = self.bump()

      }
    }
    let _ = self.expect(rbrace(), "}")
    self.skip_trivia()
    // Check for re-export: export { ... } from ./path
    if self.peek_kind() == from_kw() {
      let _ = self.bump() // consume 'from'
      self.skip_trivia()
      let source = self.parse_module_ref()
      let _ = self.eat(semicolon())
      let span = self.span_from(start)
      @core.Stmt::ReExport(names~, source~, span~)
    } else {
      let _ = self.eat(semicolon())
      let span = self.span_from(start)
      @core.Stmt::Export(names~, span~)
    }
  }
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
  } else if self.peek_kind() == raise_kw() {
    self.parse_raise_expr()
  } else if self.peek_kind() == await_kw() {
    self.parse_await_expr()
  } else if self.peek_kind() == yield_kw() {
    self.parse_yield_expr()
  } else if self.peek_kind() == record_kw() {
    self.parse_record_expr()
  } else if self.peek_kind() == map_kw() {
    self.parse_map_expr()
  } else if self.peek_kind() == lparen() {
    self.parse_paren_expr()
  } else if self.peek_kind() == lbracket() {
    // Could be array literal or generic function: [T](x: T) -> T { x }
    match self.try_parse_arrow_fn() {
      Some(fn_expr) => fn_expr
      None => self.parse_array_expr()
    }
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
  let mut left = self.parse_bit_or_expr()
  while {
          self.skip_trivia()
          self.peek_kind() == pipe_gt()
        } {
    let _ = self.bump()
    let right = self.parse_bit_or_expr()
    left = pipe_apply(left, right)
  }
  left
}

///|
fn AstParser::parse_bit_or_expr(
  self : AstParser,
) -> @core.Expr raise ParseError {
  let mut left = self.parse_bit_xor_expr()
  while {
          self.skip_trivia()
          self.peek_kind() == bit_or()
        } {
    let _ = self.bump()
    let right = self.parse_bit_xor_expr()
    left = call2("__bit_or", left, right)
  }
  left
}

///|
fn AstParser::parse_bit_xor_expr(
  self : AstParser,
) -> @core.Expr raise ParseError {
  let mut left = self.parse_bit_and_expr()
  while {
          self.skip_trivia()
          self.peek_kind() == bit_xor()
        } {
    let _ = self.bump()
    let right = self.parse_bit_and_expr()
    left = call2("__bit_xor", left, right)
  }
  left
}

///|
fn AstParser::parse_bit_and_expr(
  self : AstParser,
) -> @core.Expr raise ParseError {
  let mut left = self.parse_cmp_expr()
  while {
          self.skip_trivia()
          self.peek_kind() == bit_and()
        } {
    let _ = self.bump()
    let right = self.parse_cmp_expr()
    left = call2("__bit_and", left, right)
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
  let mut left = self.parse_shift_expr()
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
    let right = self.parse_shift_expr()
    left = cmp_expr_from_op(op, left, right)
  }
  left
}

///|
fn AstParser::parse_shift_expr(self : AstParser) -> @core.Expr raise ParseError {
  let mut left = self.parse_add_expr()
  while {
          self.skip_trivia()
          self.peek_kind() == lshift() || self.peek_kind() == rshift()
        } {
    let op = self.peek_kind()
    let _ = self.bump()
    let right = self.parse_add_expr()
    let name = if op == lshift() { "__lshift" } else { "__rshift" }
    left = call2(name, left, right)
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
    type_args=[],
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
    type_args=[],
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
        type_args=[],
        args=[@core.CallArg::{ label: None, expr: left, span: left_span }],
        span=call_span,
      )
    }
    @core.Expr::Call(name~, type_args~, args~, span~) => {
      let left_span = left.span()
      let call_span = @core.Span::merge(left_span, span)
      let out : Array[@core.CallArg] = []
      out.push(@core.CallArg::{ label: None, expr: left, span: left_span })
      for arg in args {
        out.push(arg)
      }
      @core.Expr::Call(name~, type_args~, args=out, span=call_span)
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
          self.peek_kind() == star() ||
          self.peek_kind() == slash() ||
          self.peek_kind() == percent()
        } {
    let op = self.peek_kind()
    let _ = self.bump()
    let right = self.parse_unary_expr()
    let name = if op == star() {
      "__mul"
    } else if op == slash() {
      "__div"
    } else {
      "__mod"
    }
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
    let first_pat = self.parse_pattern()
    self.skip_trivia()
    // Check for or-pattern: A | B | C => ...
    let pat = if self.peek_kind() == bit_or() {
      let pats : Array[@core.Pat] = [first_pat]
      while {
              self.skip_trivia()
              self.peek_kind() == bit_or()
            } {
        let _ = self.bump() // consume |
        pats.push(self.parse_pattern())
      }
      let span = @core.Span::merge(
        pats[0].span(),
        pats[pats.length() - 1].span(),
      )
      @core.Pat::Or(pats~, span~)
    } else {
      first_pat
    }
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
fn AstParser::parse_raise_expr(self : AstParser) -> @core.Expr raise ParseError {
  let start = self.pos
  let _ = self.expect(raise_kw(), "raise")
  let value = self.parse_expr()
  let span = self.span_from(start)
  @core.Expr::Raise(value~, span~)
}

///|
fn AstParser::parse_await_expr(self : AstParser) -> @core.Expr raise ParseError {
  let start = self.pos
  let _ = self.expect(await_kw(), "await")
  let expr = self.parse_expr()
  let span = self.span_from(start)
  @core.Expr::Await(expr~, span~)
}

///|
fn AstParser::parse_yield_expr(self : AstParser) -> @core.Expr raise ParseError {
  let start = self.pos
  let _ = self.expect(yield_kw(), "yield")
  let expr = self.parse_expr()
  let span = self.span_from(start)
  @core.Expr::Yield(expr~, span~)
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
    self.skip_trivia()
    let expr = if self.peek_kind() == colon() {
      let _ = self.bump()
      self.parse_expr()
    } else {
      let ident_span = self.span_from(field_start)
      @core.Expr::Ident(name=name_tok.text(), span=ident_span)
    }
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
/// Parse parameter list for function type signatures.
/// Supports both `(x: T)` and `(T)` syntax where uppercase names are treated as types.
fn AstParser::parse_fn_type_param_list(
  self : AstParser,
  params : Map[String, Bool],
) -> Array[@core.FuncParam] raise ParseError {
  let _ = self.expect(lparen(), "(")
  let out : Array[@core.FuncParam] = []
  let mut idx = 0
  self.skip_trivia()
  if self.peek_kind() != rparen() {
    out.push(self.parse_fn_type_param(params, idx))
    idx += 1
    while {
            self.skip_trivia()
            self.peek_kind() == comma()
          } {
      let _ = self.bump()
      self.skip_trivia()
      if self.peek_kind() == rparen() {
        break
      }
      out.push(self.parse_fn_type_param(params, idx))
      idx += 1
    }
  }
  let _ = self.expect(rparen(), ")")
  out
}

///|
/// Parse a single parameter for function type signatures.
/// If the token is an uppercase name without `:`, treat it as a type-only parameter.
fn AstParser::parse_fn_type_param(
  self : AstParser,
  params : Map[String, Bool],
  idx : Int,
) -> @core.FuncParam raise ParseError {
  let saved = self.pos
  let tok = self.peek()
  if tok.kind() == name() {
    let text = tok.text()
    let chars : Array[Char] = []
    for c in text {
      chars.push(c)
    }
    if chars.length() > 0 {
      let first = chars[0]
      // Check if it's an uppercase name (type) without `:`
      if first >= 'A' && first <= 'Z' {
        // Look ahead for colon
        let _ = self.bump()
        self.skip_trivia()
        if self.peek_kind() != colon() {
          // This is a type-only parameter like `(Int)` or `(A)`
          self.pos = saved
          let ty = self.parse_type_with_params(params)
          let param_name = "_" + idx.to_string()
          return @core.FuncParam::{
            name: param_name,
            label: @core.ParamLabel::Positional,
            ty,
          }
        }
        // Has colon, restore and use normal parsing
        self.pos = saved
      }
    }
  }
  // Fall back to normal param parsing
  self.parse_param(params)
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
  // Type annotation is optional - use Unit as placeholder for inference
  let ty = if self.peek_kind() == colon() {
    let _ = self.bump()
    self.parse_type_with_params(params)
  } else {
    @core.Type::Unit // Placeholder for type inference
  }
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
    let params_list = self.parse_fn_type_param_list(params)
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
/// Parse type parameters for generic functions: [T, U]
/// Returns array of type parameter names
fn AstParser::parse_fn_type_params(
  self : AstParser,
) -> Array[String] raise ParseError {
  let type_params : Array[String] = []
  self.skip_trivia()
  if self.peek_kind() == lbracket() {
    let _ = self.bump()
    self.skip_trivia()
    if self.peek_kind() != rbracket() {
      let name_tok = self.expect(name(), "type parameter name")
      type_params.push(name_tok.text())
      while {
              self.skip_trivia()
              self.peek_kind() == comma()
            } {
        let _ = self.bump()
        self.skip_trivia()
        if self.peek_kind() == rbracket() {
          break
        }
        let name_tok = self.expect(name(), "type parameter name")
        type_params.push(name_tok.text())
      }
    }
    let _ = self.expect(rbracket(), "]")

  }
  type_params
}

///|
/// Parse type arguments for function calls: [Int, String]
/// Returns array of types
fn AstParser::parse_call_type_args(
  self : AstParser,
) -> Array[@core.Type] raise ParseError {
  let type_args : Array[@core.Type] = []
  self.skip_trivia()
  if self.peek_kind() == lbracket() {
    let _ = self.bump()
    self.skip_trivia()
    if self.peek_kind() != rbracket() {
      type_args.push(self.parse_type())
      while {
              self.skip_trivia()
              self.peek_kind() == comma()
            } {
        let _ = self.bump()
        self.skip_trivia()
        if self.peek_kind() == rbracket() {
          break
        }
        type_args.push(self.parse_type())
      }
    }
    let _ = self.expect(rbracket(), "]")

  }
  type_args
}

///|
/// Check if the next tokens after [ look like type arguments (e.g., [Int])
/// rather than an index expression (e.g., [0] or ["hello"])
/// Type arguments start with uppercase letter (Int, String, etc.)
fn AstParser::is_type_arg_context(self : AstParser) -> Bool {
  let saved = self.pos
  let _ = self.bump() // consume [
  self.skip_trivia()
  let result = if self.peek_kind() == name() {
    let text = self.peek().text()
    if text.length() > 0 {
      let first = text.to_array()[0]
      first >= 'A' && first <= 'Z'
    } else {
      false
    }
  } else {
    false
  }
  self.pos = saved
  result
}

///|
fn AstParser::try_parse_arrow_fn(self : AstParser) -> @core.Expr? {
  let saved = self.pos
  let result : @core.Expr? = try {
    // Try to parse type parameters: [T, U]
    let type_params = self.parse_fn_type_params()
    let params = self.parse_param_list(param_set_from_params(type_params))
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
      self.skip_trivia()
      // Check if this is expression body: (x) -> expr (no block)
      // or type annotation: (x) -> Int { ... }
      if self.peek_kind() != lbrace() {
        // Could be expression body OR type annotation
        // Try to determine: if next token is a type keyword or name followed by {, it's a type
        let is_expr_body = self.is_arrow_expr_body()
        if is_expr_body {
          // Expression body: (x) -> x + 1
          let expr = self.parse_expr()
          let span = self.span_from(saved)
          let body = @core.Module::{
            stmts: [@core.Stmt::Expr(expr~, span=expr.span())],
          }
          return Some(
            @core.Expr::Fn(type_params~, params~, ret~, effects~, body~, span~),
          )
        }
      }
      // Type annotation followed by block: (x) -> Int { ... }
      if self.peek_kind() != lbrace() {
        ret = Some(
          self.parse_type_with_params(param_set_from_params(type_params)),
        )
        effects = self.parse_effect_list()
      }
    }
    let body = self.parse_block()
    let span = self.span_from(saved)
    Some(@core.Expr::Fn(type_params~, params~, ret~, effects~, body~, span~))
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
/// Determine if after -> we have expression body or type annotation
/// Expression body: any expression that doesn't start with a type-like token followed by {
fn AstParser::is_arrow_expr_body(self : AstParser) -> Bool {
  // Look at current token
  let tok = self.peek()
  let saved = self.pos

  // If it starts with (, could be tuple type or expression
  // Check if after matching ) there's "with" or "{" for type annotation
  if tok.kind() == lparen() {
    // Skip the entire parenthesized part
    let _ = self.bump() // consume (
    let mut depth = 1
    while depth > 0 && self.peek_kind() != eof() {
      let k = self.peek_kind()
      if k == lparen() {
        depth = depth + 1
      } else if k == rparen() {
        depth = depth - 1
      }
      let _ = self.bump()

    }
    self.skip_trivia()
    let after_kind = self.peek_kind()
    let after_text = self.peek().text()
    self.pos = saved // restore position
    // If after () there's "with", "{", or "->", it's a type annotation
    if after_kind == lbrace() {
      return false // type annotation: (Int, String) { ... }
    } else if after_kind == name() && after_text == "with" {
      return false // type annotation: (Int, String) with {Error} { ... }
    } else if after_kind == thin_arrow() {
      return false // function type: (A) -> C { ... }
    } else {
      return true // expression: (a, b).foo() or (x + 1)
    }
  }

  // If it's not a name, it's definitely an expression
  if tok.kind() != name() {
    return true
  }
  // Check if this looks like a type annotation (name followed by { or [ for generic or "with")
  // Save position to peek ahead
  let _ = self.bump() // consume the name
  self.skip_trivia()
  let next_kind = self.peek_kind()
  let next_text = self.peek().text()
  self.pos = saved // restore position
  // If name is followed by { or [ (for generic type), it's likely a type annotation
  // If name is followed by "with" (for effects), it's also a type annotation
  // Otherwise it's an expression
  if next_kind == lbrace() || next_kind == lbracket() {
    false // type annotation: Int { ... } or Array[Int] { ... }
  } else if next_kind == name() && next_text == "with" {
    false // type annotation with effects: Int with {Error} { ... }
  } else {
    true // expression: x + 1, foo(bar), etc.
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
    self.skip_trivia()
    let pat = if self.peek_kind() == colon() {
      let _ = self.bump()
      self.parse_pattern()
    } else {
      let bind_span = self.span_from(field_start)
      @core.Pat::Bind(name=name_tok.text(), span=bind_span)
    }
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
  let start = self.pos
  let tok = self.peek()
  let mut expr : @core.Expr = if tok.kind() == name() {
    let name_tok = self.bump()
    self.skip_trivia()
    // Check for single-parameter lambda: x -> expr
    if self.peek_kind() == thin_arrow() {
      let _ = self.bump() // consume ->
      self.skip_trivia()
      let param = @core.FuncParam::{
        name: name_tok.text(),
        label: @core.ParamLabel::Positional,
        ty: @core.Type::Unit, // Placeholder for inference
      }
      // Check if block body or expression body
      if self.peek_kind() == lbrace() {
        // Block body: x -> { ... }
        let body = self.parse_block()
        let span = self.span_from(start)
        @core.Expr::Fn(
          type_params=[],
          params=[param],
          ret=None,
          effects=[],
          body~,
          span~,
        )
      } else {
        // Expression body: x -> x + 1
        let body_expr = self.parse_expr()
        let span = self.span_from(start)
        let body = @core.Module::{
          stmts: [@core.Stmt::Expr(expr=body_expr, span=body_expr.span())],
        }
        @core.Expr::Fn(
          type_params=[],
          params=[param],
          ret=None,
          effects=[],
          body~,
          span~,
        )
      }
    } else if self.peek_kind() == lbracket() && self.is_type_arg_context() {
      // name[Type, ...] - explicit type arguments (only if next token looks like a type)
      let type_args = self.parse_call_type_args()
      self.skip_trivia()
      if self.peek_kind() == lparen() {
        // name[Type](args) - generic function call
        let _ = self.bump()
        let args = self.parse_args()
        let _ = self.expect(rparen(), ")")
        let span = self.span_from(start)
        @core.Expr::Call(name=name_tok.text(), type_args~, args~, span~)
      } else {
        // name[Type] without parens - might be generic function reference
        let span = self.span_from(start)
        @core.Expr::Call(name=name_tok.text(), type_args~, args=[], span~)
      }
    } else if self.peek_kind() == lparen() {
      let _ = self.bump()
      let args = self.parse_args()
      let _ = self.expect(rparen(), ")")
      let span = self.span_from(start)
      @core.Expr::Call(name=name_tok.text(), type_args=[], args~, span~)
    } else if name_tok.text() == "_" {
      // Placeholder for lambda shorthand: _ * 2 → x -> x * 2
      let span = self.span_from(start)
      @core.Expr::Placeholder(index=0, span~)
    } else {
      let span = self.span_from(start)
      @core.Expr::Ident(name=name_tok.text(), span~)
    }
  } else if tok.kind() == lparen() {
    // Parenthesized expression or tuple
    self.parse_paren_expr()
  } else {
    self.parse_primary()
  }
  // Postfix chain: .method(args), .prop, [index]
  while true {
    self.skip_trivia()
    if self.peek_kind() == dot() {
      let _ = self.bump()
      self.skip_trivia()
      // Check for tuple index access: expr.0, expr.1, etc.
      if self.peek_kind() == int_lit() {
        let index_tok = self.bump()
        let index = @strconv.parse_int(index_tok.text()) catch {
          // This shouldn't happen for valid int literals
          _ => 0
        }
        let span = self.span_from(start)
        expr = @core.Expr::TupleIndex(expr~, index~, span~)
        continue
      }
      let method_tok = self.expect(name(), "method name")
      self.skip_trivia()
      if self.peek_kind() == lparen() {
        let _ = self.bump()
        let args = self.parse_args()
        let _ = self.expect(rparen(), ")")
        let span = self.span_from(start)
        // desugar: expr.method(a, b) → method(expr, a, b)
        let merged : Array[@core.CallArg] = []
        let expr_span = expr.span()
        merged.push(@core.CallArg::{ label: None, expr, span: expr_span })
        for arg in args {
          merged.push(arg)
        }
        expr = @core.Expr::Call(
          name=method_tok.text(),
          type_args=[],
          args=merged,
          span~,
        )
      } else {
        // expr.prop → prop(expr) — zero-arg method call
        let span = self.span_from(start)
        let expr_span = expr.span()
        expr = @core.Expr::Call(
          name=method_tok.text(),
          type_args=[],
          args=[@core.CallArg::{ label: None, expr, span: expr_span }],
          span~,
        )
      }
    } else if self.peek_kind() == lbracket() {
      let _ = self.bump()
      let index = self.parse_expr()
      let _ = self.expect(rbracket(), "]")
      expr = call2("__index", expr, index)
    } else {
      break
    }
  }
  expr
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
          type_args=[],
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
        type_args=[],
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
  let parsed = parser.parse()
  // Desugar placeholders in Call args after parsing
  desugar_module(parsed)
}

// ============================================================
// Placeholder desugar: _ * 2 → x -> x * 2
// ============================================================

///|
/// Check if an expression contains any placeholder (_)
fn contains_placeholder(expr : @core.Expr) -> Bool {
  match expr {
    @core.Expr::Placeholder(..) => true
    @core.Expr::Call(args~, ..) => {
      for arg in args {
        if contains_placeholder(arg.expr) {
          return true
        }
      }
      false
    }
    @core.Expr::Tuple(items~, ..) => {
      for item in items {
        if contains_placeholder(item) {
          return true
        }
      }
      false
    }
    @core.Expr::Array(items~, ..) => {
      for item in items {
        if contains_placeholder(item) {
          return true
        }
      }
      false
    }
    @core.Expr::Record(fields~, ..) => {
      for field in fields {
        if contains_placeholder(field.expr) {
          return true
        }
      }
      false
    }
    @core.Expr::Map(fields~, ..) => {
      for field in fields {
        if contains_placeholder(field.expr) {
          return true
        }
      }
      false
    }
    @core.Expr::If(cond~, ..) => contains_placeholder(cond)
    @core.Expr::Block(..)
    | @core.Expr::Match(..)
    | @core.Expr::Do(..)
    | @core.Expr::Try(..)
    | @core.Expr::Fn(..)
    | @core.Expr::While(..) => false // Don't look inside blocks/lambdas
    @core.Expr::Raise(value~, ..) => contains_placeholder(value)
    @core.Expr::Await(expr~, ..) => contains_placeholder(expr)
    @core.Expr::Yield(expr~, ..) => contains_placeholder(expr)
    _ => false
  }
}

///|
/// Count placeholders in an expression and reindex them
fn reindex_placeholders(expr : @core.Expr, counter : Ref[Int]) -> @core.Expr {
  match expr {
    @core.Expr::Placeholder(span~, ..) => {
      let idx = counter.val
      counter.val += 1
      @core.Expr::Placeholder(index=idx, span~)
    }
    @core.Expr::Call(name~, type_args~, args~, span~) => {
      let new_args : Array[@core.CallArg] = []
      for arg in args {
        new_args.push(@core.CallArg::{
          label: arg.label,
          expr: reindex_placeholders(arg.expr, counter),
          span: arg.span,
        })
      }
      @core.Expr::Call(name~, type_args~, args=new_args, span~)
    }
    @core.Expr::Tuple(items~, span~) => {
      let new_items : Array[@core.Expr] = []
      for item in items {
        new_items.push(reindex_placeholders(item, counter))
      }
      @core.Expr::Tuple(items=new_items, span~)
    }
    @core.Expr::Array(items~, span~) => {
      let new_items : Array[@core.Expr] = []
      for item in items {
        new_items.push(reindex_placeholders(item, counter))
      }
      @core.Expr::Array(items=new_items, span~)
    }
    @core.Expr::Record(fields~, span~) => {
      let new_fields : Array[@core.RecordFieldExpr] = []
      for field in fields {
        new_fields.push(@core.RecordFieldExpr::{
          name: field.name,
          expr: reindex_placeholders(field.expr, counter),
          span: field.span,
        })
      }
      @core.Expr::Record(fields=new_fields, span~)
    }
    @core.Expr::Map(fields~, span~) => {
      let new_fields : Array[@core.MapFieldExpr] = []
      for field in fields {
        new_fields.push(@core.MapFieldExpr::{
          key: field.key,
          expr: reindex_placeholders(field.expr, counter),
          span: field.span,
        })
      }
      @core.Expr::Map(fields=new_fields, span~)
    }
    @core.Expr::If(cond~, then_body~, else_body~, span~) =>
      @core.Expr::If(
        cond=reindex_placeholders(cond, counter),
        then_body~,
        else_body~,
        span~,
      )
    @core.Expr::Raise(value~, span~) =>
      @core.Expr::Raise(value=reindex_placeholders(value, counter), span~)
    @core.Expr::Await(expr~, span~) =>
      @core.Expr::Await(expr=reindex_placeholders(expr, counter), span~)
    @core.Expr::Yield(expr~, span~) =>
      @core.Expr::Yield(expr=reindex_placeholders(expr, counter), span~)
    _ => expr
  }
}

///|
/// Replace placeholders with identifiers
fn replace_placeholders(expr : @core.Expr) -> @core.Expr {
  match expr {
    @core.Expr::Placeholder(index~, span~) => {
      let name = "__p" + index.to_string()
      @core.Expr::Ident(name~, span~)
    }
    @core.Expr::Call(name~, type_args~, args~, span~) => {
      let new_args : Array[@core.CallArg] = []
      for arg in args {
        new_args.push(@core.CallArg::{
          label: arg.label,
          expr: replace_placeholders(arg.expr),
          span: arg.span,
        })
      }
      @core.Expr::Call(name~, type_args~, args=new_args, span~)
    }
    @core.Expr::Tuple(items~, span~) => {
      let new_items : Array[@core.Expr] = []
      for item in items {
        new_items.push(replace_placeholders(item))
      }
      @core.Expr::Tuple(items=new_items, span~)
    }
    @core.Expr::Array(items~, span~) => {
      let new_items : Array[@core.Expr] = []
      for item in items {
        new_items.push(replace_placeholders(item))
      }
      @core.Expr::Array(items=new_items, span~)
    }
    @core.Expr::Record(fields~, span~) => {
      let new_fields : Array[@core.RecordFieldExpr] = []
      for field in fields {
        new_fields.push(@core.RecordFieldExpr::{
          name: field.name,
          expr: replace_placeholders(field.expr),
          span: field.span,
        })
      }
      @core.Expr::Record(fields=new_fields, span~)
    }
    @core.Expr::Map(fields~, span~) => {
      let new_fields : Array[@core.MapFieldExpr] = []
      for field in fields {
        new_fields.push(@core.MapFieldExpr::{
          key: field.key,
          expr: replace_placeholders(field.expr),
          span: field.span,
        })
      }
      @core.Expr::Map(fields=new_fields, span~)
    }
    @core.Expr::If(cond~, then_body~, else_body~, span~) =>
      @core.Expr::If(
        cond=replace_placeholders(cond),
        then_body~,
        else_body~,
        span~,
      )
    @core.Expr::Raise(value~, span~) =>
      @core.Expr::Raise(value=replace_placeholders(value), span~)
    @core.Expr::Await(expr~, span~) =>
      @core.Expr::Await(expr=replace_placeholders(expr), span~)
    @core.Expr::Yield(expr~, span~) =>
      @core.Expr::Yield(expr=replace_placeholders(expr), span~)
    _ => expr
  }
}

///|
/// Desugar placeholder expression to lambda: _ * 2 → (__p0) -> __p0 * 2
pub fn desugar_placeholder_expr(expr : @core.Expr) -> @core.Expr {
  if not(contains_placeholder(expr)) {
    return expr
  }
  let counter : Ref[Int] = @ref.new(0)
  let reindexed = reindex_placeholders(expr, counter)
  let num_params = counter.val
  let body_expr = replace_placeholders(reindexed)
  let span = expr.span()
  // Build params: __p0, __p1, ...
  let params : Array[@core.FuncParam] = []
  for i in 0..<num_params {
    params.push(@core.FuncParam::{
      name: "__p" + i.to_string(),
      label: @core.ParamLabel::Positional,
      ty: @core.Type::Unit, // Placeholder for type inference
    })
  }
  let body = @core.Module::{
    stmts: [@core.Stmt::Expr(expr=body_expr, span=body_expr.span())],
  }
  @core.Expr::Fn(type_params=[], params~, ret=None, effects=[], body~, span~)
}

// ============================================================
// Module-level desugar pass: desugar placeholders in Call args
// ============================================================

///|
/// Desugar placeholders in module
fn desugar_module(m : @core.Module) -> @core.Module {
  let new_stmts : Array[@core.Stmt] = []
  for stmt in m.stmts {
    new_stmts.push(desugar_stmt(stmt))
  }
  @core.Module::{ stmts: new_stmts }
}

///|
fn desugar_stmt(stmt : @core.Stmt) -> @core.Stmt {
  match stmt {
    @core.Stmt::Let(rec~, name~, expr~, span~) =>
      @core.Stmt::Let(rec~, name~, expr=desugar_expr_deep(expr), span~)
    @core.Stmt::ExportLet(rec~, name~, expr~, span~) =>
      @core.Stmt::ExportLet(rec~, name~, expr=desugar_expr_deep(expr), span~)
    @core.Stmt::Test(name~, body~, span~) =>
      @core.Stmt::Test(name~, body=desugar_module(body), span~)
    @core.Stmt::Expr(expr~, span~) =>
      @core.Stmt::Expr(expr=desugar_expr_deep(expr), span~)
    @core.Stmt::LetMut(name~, expr~, span~) =>
      @core.Stmt::LetMut(name~, expr=desugar_expr_deep(expr), span~)
    @core.Stmt::Assign(name~, expr~, span~) =>
      @core.Stmt::Assign(name~, expr=desugar_expr_deep(expr), span~)
    @core.Stmt::IndexAssign(target~, index~, value~, span~) =>
      @core.Stmt::IndexAssign(
        target=desugar_expr_deep(target),
        index=desugar_expr_deep(index),
        value=desugar_expr_deep(value),
        span~,
      )
    @core.Stmt::LetPat(pat~, expr~, span~) =>
      @core.Stmt::LetPat(pat~, expr=desugar_expr_deep(expr), span~)
    // Non-expression statements pass through
    @core.Stmt::EnumDef(..)
    | @core.Stmt::TypeAlias(..)
    | @core.Stmt::Flake(..)
    | @core.Stmt::Alias(..)
    | @core.Stmt::Import(..)
    | @core.Stmt::Export(..)
    | @core.Stmt::ExportEnumDef(..)
    | @core.Stmt::ExportTypeAlias(..)
    | @core.Stmt::ReExport(..) => stmt
  }
}

///|
/// Desugar expression deeply, applying placeholder desugar to Call args
fn desugar_expr_deep(expr : @core.Expr) -> @core.Expr {
  match expr {
    @core.Expr::Call(name~, type_args~, args~, span~) => {
      // Desugar each argument (top-level of Call args)
      let new_args : Array[@core.CallArg] = []
      for arg in args {
        let desugared = desugar_placeholder_expr(arg.expr)
        let deep = desugar_expr_deep(desugared)
        new_args.push(@core.CallArg::{
          label: arg.label,
          expr: deep,
          span: arg.span,
        })
      }
      @core.Expr::Call(name~, type_args~, args=new_args, span~)
    }
    @core.Expr::Tuple(items~, span~) => {
      let new_items : Array[@core.Expr] = []
      for item in items {
        new_items.push(desugar_expr_deep(item))
      }
      @core.Expr::Tuple(items=new_items, span~)
    }
    @core.Expr::Array(items~, span~) => {
      let new_items : Array[@core.Expr] = []
      for item in items {
        new_items.push(desugar_expr_deep(item))
      }
      @core.Expr::Array(items=new_items, span~)
    }
    @core.Expr::Record(fields~, span~) => {
      let new_fields : Array[@core.RecordFieldExpr] = []
      for field in fields {
        new_fields.push(@core.RecordFieldExpr::{
          name: field.name,
          expr: desugar_expr_deep(field.expr),
          span: field.span,
        })
      }
      @core.Expr::Record(fields=new_fields, span~)
    }
    @core.Expr::Map(fields~, span~) => {
      let new_fields : Array[@core.MapFieldExpr] = []
      for field in fields {
        new_fields.push(@core.MapFieldExpr::{
          key: field.key,
          expr: desugar_expr_deep(field.expr),
          span: field.span,
        })
      }
      @core.Expr::Map(fields=new_fields, span~)
    }
    @core.Expr::If(cond~, then_body~, else_body~, span~) =>
      @core.Expr::If(
        cond=desugar_expr_deep(cond),
        then_body=desugar_module(then_body),
        else_body=desugar_module(else_body),
        span~,
      )
    @core.Expr::Block(body~, span~) =>
      @core.Expr::Block(body=desugar_module(body), span~)
    @core.Expr::Match(scrutinee~, arms~, span~) => {
      let new_arms : Array[@core.MatchArm] = []
      for arm in arms {
        let new_cond : @core.Expr? = match arm.cond {
          Some(c) => Some(desugar_expr_deep(c))
          None => None
        }
        new_arms.push(@core.MatchArm::{
          pat: arm.pat,
          cond: new_cond,
          expr: desugar_expr_deep(arm.expr),
          span: arm.span,
        })
      }
      @core.Expr::Match(
        scrutinee=desugar_expr_deep(scrutinee),
        arms=new_arms,
        span~,
      )
    }
    @core.Expr::Do(body~, span~) =>
      @core.Expr::Do(body=desugar_module(body), span~)
    @core.Expr::Try(try_body~, catch_body~, span~) =>
      @core.Expr::Try(
        try_body=desugar_module(try_body),
        catch_body=desugar_module(catch_body),
        span~,
      )
    @core.Expr::Fn(type_params~, params~, ret~, effects~, body~, span~) =>
      @core.Expr::Fn(
        type_params~,
        params~,
        ret~,
        effects~,
        body=desugar_module(body),
        span~,
      )
    @core.Expr::While(cond~, body~, span~) =>
      @core.Expr::While(
        cond=desugar_expr_deep(cond),
        body=desugar_module(body),
        span~,
      )
    @core.Expr::Raise(value~, span~) =>
      @core.Expr::Raise(value=desugar_expr_deep(value), span~)
    @core.Expr::Await(expr=e, span~) =>
      @core.Expr::Await(expr=desugar_expr_deep(e), span~)
    @core.Expr::Yield(expr=e, span~) =>
      @core.Expr::Yield(expr=desugar_expr_deep(e), span~)
    _ => expr
  }
}
