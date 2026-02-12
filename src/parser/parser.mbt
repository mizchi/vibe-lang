///|
/// Parser for xsh (CST + AST)
suberror ParseError {
  UnexpectedToken(expected~ : String, got~ : String, span~ : @core.Span)
  UnexpectedEof(span~ : @core.Span)
  IntLiteralOverflow(literal~ : String, span~ : @core.Span)
  IntMinLiteralBoundary(span~ : @core.Span)
  MutableEnumFieldUnsupported(span~ : @core.Span)
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
    ParseError::IntLiteralOverflow(literal~, span~) =>
      @core.Diagnostic::{
        stage: "parse",
        message: "int literal overflow: `" + literal + "` is out of Int range",
        span: Some(span),
        hint: Some("use a smaller literal or rewrite as `0 - 2147483647 - 1`"),
        note: None,
      }
    ParseError::IntMinLiteralBoundary(span~) =>
      @core.Diagnostic::{
        stage: "parse",
        message: "`-2147483648` is rejected: unary `-` does not extend Int literal range",
        span: Some(span),
        hint: Some("rewrite as `0 - 2147483647 - 1`"),
        note: Some(
          "parser treats `-` as unary operator applied after literal parsing",
        ),
      }
    ParseError::MutableEnumFieldUnsupported(span~) =>
      @core.Diagnostic::{
        stage: "parse",
        message: "enum payload fields cannot be marked `mut` yet",
        span: Some(span),
        hint: Some(
          "remove `mut` from enum payload type, or wrap mutability in a struct payload",
        ),
        note: Some(
          "mutable enum field syntax is tracked separately and not implemented in current grammar",
        ),
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
fn Parser::peek_non_trivia_ahead(self : Parser, nth : Int) -> @cst.SyntaxKind {
  let mut i = self.pos + 1
  let mut seen = 0
  while i < self.tokens.length() {
    if not(is_trivia(self.tokens[i].kind())) {
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
/// Skip tokens until braces {} are balanced (assumes opening brace was already consumed)
fn Parser::skip_balanced_braces(self : Parser) -> Unit {
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
/// Skip tokens until brackets [] are balanced (assumes opening bracket was already consumed)
fn Parser::skip_balanced_brackets(self : Parser) -> Unit {
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
/// Skip tokens until parens () are balanced (assumes opening paren was already consumed)
fn Parser::skip_balanced_parens(self : Parser) -> Unit {
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
    k if k == name() &&
      self.peek().text() == "module" &&
      self.peek_non_trivia_ahead(1) == name() &&
      self.peek_non_trivia_ahead(2) == lbrace() => self.parse_module_stmt()
    k if k == name() && self.peek().text() == "suberror" =>
      self.parse_suberror_stmt()
    k if k == struct_kw() => self.parse_struct_stmt()
    k if k == type_kw() => self.parse_type_alias_stmt()
    k if k == use_kw() => self.parse_import_stmt()
    k if k == import_kw() => {
      self.builder.start_node(error_kind())
      self.bump()
      self.builder.finish_node()
    }
    k if k == export_kw() => self.parse_export_stmt()
    k if k == test_kw() => self.parse_test_block()
    k if k == bench_kw() => self.parse_bench_block()
    _ => self.parse_expr_stmt()
  }
}

///|
fn Parser::parse_module_stmt(self : Parser) -> Unit {
  self.builder.start_node(module_stmt())
  self.bump() // module
  self.skip_trivia()
  self.expect(name())
  self.skip_trivia()
  self.expect(lbrace())
  self.skip_balanced_braces()
  self.skip_trivia()
  if self.at(semicolon()) {
    self.bump()
  }
  self.builder.finish_node()
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
  if self.at(colon()) {
    self.bump()
    self.parse_binding_type_until_eq()
    self.skip_trivia()
  }
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
  self.skip_balanced_braces()
  self.parse_optional_derive_clause()
  self.skip_trivia()
  if self.at(semicolon()) {
    self.bump()
  }
  self.builder.finish_node()
}

///|
fn Parser::parse_suberror_stmt(self : Parser) -> Unit {
  self.builder.start_node(enum_def())
  self.bump() // suberror
  self.skip_trivia()
  self.expect(name())
  self.skip_trivia()
  if self.at(lbracket()) {
    self.parse_bracket_tokens()
  }
  self.skip_trivia()
  if self.at(lparen()) {
    self.skip_balanced_parens()
  } else if self.at(lbrace()) {
    self.skip_balanced_braces()
  } else {
    self.builder.token(error_kind(), "")
  }
  self.parse_optional_derive_clause()
  self.skip_trivia()
  if self.at(semicolon()) {
    self.bump()
  }
  self.builder.finish_node()
}

///|
fn Parser::parse_struct_stmt(self : Parser) -> Unit {
  self.builder.start_node(struct_def())
  self.bump() // struct
  self.skip_trivia()
  self.expect(name())
  self.skip_trivia()
  if self.at(lbracket()) {
    self.parse_bracket_tokens()
  }
  self.skip_trivia()
  self.expect(lbrace())
  self.skip_balanced_braces()
  self.parse_optional_derive_clause()
  self.skip_trivia()
  if self.at(semicolon()) {
    self.bump()
  }
  self.builder.finish_node()
}

///|
fn Parser::parse_optional_derive_clause(self : Parser) -> Unit {
  self.skip_trivia()
  if self.at(name()) && self.peek().text() == "derive" {
    self.bump()
    self.skip_trivia()
    if self.at(lparen()) {
      self.skip_balanced_parens()
    } else {
      self.builder.token(error_kind(), "")
    }
  }
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
fn Parser::parse_test_block(self : Parser) -> Unit {
  self.builder.start_node(test_block())
  self.bump() // test
  self.skip_trivia()
  if self.at(string_lit()) || self.at(name()) {
    self.bump()
    self.skip_trivia()
  }
  self.expect(lbrace())
  self.skip_balanced_braces()
  self.builder.finish_node()
}

///|
fn Parser::parse_bench_block(self : Parser) -> Unit {
  self.builder.start_node(bench_block())
  self.bump() // bench
  self.skip_trivia()
  if self.at(string_lit()) || self.at(name()) {
    self.bump()
    self.skip_trivia()
  }
  self.expect(lbrace())
  self.skip_balanced_braces()
  self.builder.finish_node()
}

///|
fn Parser::parse_import_stmt(self : Parser) -> Unit {
  self.builder.start_node(import_stmt())
  let head = self.peek_kind()
  self.bump() // import | use
  self.skip_trivia()
  if head == import_kw() {
    if self.at(lbrace()) {
      self.parse_brace_block_tokens()
      self.skip_trivia()
      self.expect(from_kw())
      self.skip_trivia()
      while not(self.at(eof())) &&
            not(self.at(semicolon())) &&
            not(self.at(newline())) {
        self.bump()
      }
    } else if self.at(name()) || self.at(string_lit()) {
      self.bump()
    } else {
      self.builder.token(error_kind(), "")
    }
  } else {
    // use <source> { ... } / use <source>
    while not(self.at(eof())) &&
          not(self.at(semicolon())) &&
          not(self.at(newline())) &&
          not(self.at(lbrace())) {
      self.bump()
    }
    self.skip_trivia()
    if self.at(lbrace()) {
      self.parse_brace_block_tokens()
    }
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
  } else if self.at(name()) && self.peek().text() == "suberror" {
    // export suberror Name(...)
    self.parse_suberror_stmt()
  } else if self.at(struct_kw()) {
    // export struct Name { ... }
    self.parse_struct_stmt()
  } else if self.at(type_kw()) {
    // export type Name = ...
    self.parse_type_alias_stmt()
  } else if self.at(let_kw()) {
    // export let name = ...
    self.parse_let_stmt()
  } else if self.at(name()) &&
    self.peek().text() == "module" &&
    self.peek_non_trivia_ahead(1) == name() &&
    self.peek_non_trivia_ahead(2) == lbrace() {
    // export module foo { ... }
    self.parse_module_stmt()
  } else if self.at(trait_kw()) {
    // export trait Name
    self.parse_stmt()
  } else if self.at(name()) && self.peek().text() == "open" {
    // export open trait Name
    self.bump() // open
    self.skip_trivia()
    if self.at(trait_kw()) {
      self.parse_stmt()
    } else {
      self.builder.token(error_kind(), "")
    }
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
  } else if self.at(loop_kw()) {
    self.parse_loop_expr()
  } else if self.at(match_kw()) {
    self.parse_match_expr()
  } else if self.at(do_kw()) {
    self.parse_do_expr()
  } else if self.at(try_kw()) {
    self.parse_try_expr()
  } else if self.at(break_kw()) {
    self.parse_break_expr()
  } else if self.at(continue_kw()) {
    self.parse_continue_expr()
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
fn Parser::parse_loop_expr(self : Parser) -> Unit {
  self.builder.start_node(while_expr())
  self.bump() // loop
  self.skip_trivia()
  self.parse_brace_block_tokens()
  self.builder.finish_node()
}

///|
fn Parser::parse_pipe_expr(self : Parser) -> Unit {
  self.parse_bit_or_expr()
  while ({
          self.skip_trivia()
          self.at(pipe_gt())
        }) {
    self.bump()
    self.parse_bit_or_expr()
  }
}

///|
fn Parser::parse_bit_or_expr(self : Parser) -> Unit {
  self.parse_bit_xor_expr()
  while ({
          self.skip_trivia()
          self.at(bit_or())
        }) {
    self.bump()
    self.parse_bit_xor_expr()
  }
}

///|
fn Parser::parse_bit_xor_expr(self : Parser) -> Unit {
  self.parse_bit_and_expr()
  while ({
          self.skip_trivia()
          self.at(bit_xor())
        }) {
    self.bump()
    self.parse_bit_and_expr()
  }
}

///|
fn Parser::parse_bit_and_expr(self : Parser) -> Unit {
  self.parse_cmp_expr()
  while ({
          self.skip_trivia()
          self.at(bit_and())
        }) {
    self.bump()
    self.parse_cmp_expr()
  }
}

///|
fn Parser::parse_or_expr(self : Parser) -> Unit {
  self.parse_and_expr()
  while ({
          self.skip_trivia()
          self.at(or_or())
        }) {
    self.bump()
    self.parse_and_expr()
  }
}

///|
fn Parser::parse_and_expr(self : Parser) -> Unit {
  self.parse_pipe_expr()
  while ({
          self.skip_trivia()
          self.at(and_and())
        }) {
    self.bump()
    self.parse_pipe_expr()
  }
}

///|
fn Parser::parse_cmp_expr(self : Parser) -> Unit {
  self.parse_shift_expr()
  while ({
          self.skip_trivia()
          self.at(eqeq()) ||
          self.at(neq()) ||
          self.at(lt()) ||
          self.at(lte()) ||
          self.at(gt()) ||
          self.at(gte())
        }) {
    self.bump()
    self.parse_shift_expr()
  }
}

///|
fn Parser::parse_shift_expr(self : Parser) -> Unit {
  self.parse_add_expr()
  while ({
          self.skip_trivia()
          self.at(lshift()) || self.at(rshift())
        }) {
    self.bump()
    self.parse_add_expr()
  }
}

///|
fn Parser::parse_add_expr(self : Parser) -> Unit {
  self.parse_mul_expr()
  while ({
          self.skip_trivia()
          self.at(plus()) || self.at(minus())
        }) {
    self.bump()
    self.parse_mul_expr()
  }
}

///|
fn Parser::parse_mul_expr(self : Parser) -> Unit {
  self.parse_unary_expr()
  while ({
          self.skip_trivia()
          self.at(star()) || self.at(slash()) || self.at(percent())
        }) {
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
fn Parser::parse_break_expr(self : Parser) -> Unit {
  self.builder.start_node(break_expr())
  self.bump() // break
  self.builder.finish_node()
}

///|
fn Parser::parse_continue_expr(self : Parser) -> Unit {
  self.builder.start_node(continue_expr())
  self.bump() // continue
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
  self.skip_balanced_brackets()
  self.builder.finish_node()
}

///|
fn Parser::parse_paren_expr(self : Parser) -> Unit {
  self.builder.start_node(paren_expr())
  self.expect(lparen())
  self.skip_balanced_parens()
  self.builder.finish_node()
}

///|
fn Parser::parse_bracket_tokens(self : Parser) -> Unit {
  self.expect(lbracket())
  self.skip_balanced_brackets()
}

///|
fn Parser::parse_brace_block_tokens(self : Parser) -> Unit {
  self.expect(lbrace())
  self.skip_balanced_braces()
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
fn Parser::parse_binding_type_until_eq(self : Parser) -> Unit {
  let mut paren_depth = 0
  let mut bracket_depth = 0
  let mut brace_depth = 0
  while not(self.at(eof())) {
    let kind = self.peek_kind()
    if paren_depth == 0 &&
      bracket_depth == 0 &&
      brace_depth == 0 &&
      kind == eq() {
      break
    }
    match kind {
      k if k == lparen() => {
        paren_depth += 1
        self.bump()
      }
      k if k == rparen() => {
        if paren_depth > 0 {
          paren_depth -= 1
        }
        self.bump()
      }
      k if k == lbracket() => {
        bracket_depth += 1
        self.bump()
      }
      k if k == rbracket() => {
        if bracket_depth > 0 {
          bracket_depth -= 1
        }
        self.bump()
      }
      k if k == lbrace() => {
        brace_depth += 1
        self.bump()
      }
      k if k == rbrace() => {
        if brace_depth > 0 {
          brace_depth -= 1
        }
        self.bump()
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
    while ({
            self.skip_trivia()
            self.at(comma())
          }) {
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
    k if k == lparen() => self.parse_paren_expr()
    k if k == name() => {
      self.builder.start_node(name_ref())
      self.bump()
      self.builder.finish_node()
    }
    k if k == int_lit() ||
      k == float_lit() ||
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
  mut pending_stmts : Array[@core.Stmt]
}

///|
pub fn AstParser::new(tokens : Array[Token]) -> AstParser {
  AstParser::{ tokens, pos: 0, pending_stmts: [] }
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
    if not(is_trivia(self.tokens[i].kind())) {
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
  let mut i = 0
  let mut offset = 0
  let limit = if pos > self.tokens.length() {
    self.tokens.length()
  } else {
    pos
  }
  while i < limit {
    offset += self.tokens[i].width()
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
    stmts.push(self.parse_stmt())
    for pending in self.pending_stmts {
      stmts.push(pending)
    }
    self.pending_stmts = []
  }
  @core.Module::{ stmts, }
}

///|
fn AstParser::parse_stmt(self : AstParser) -> @core.Stmt raise ParseError {
  self.skip_trivia()
  match self.peek_kind() {
    k if k == let_kw() => self.parse_let_stmt()
    k if k == enum_kw() => self.parse_enum_stmt()
    k if k == struct_kw() => self.parse_struct_stmt()
    k if k == type_kw() => self.parse_type_alias_stmt()
    k if k == trait_kw() => self.parse_trait_stmt()
    k if k == impl_kw() => self.parse_impl_stmt()
    k if k == use_kw() => self.parse_import_stmt()
    k if k == import_kw() => {
      let tok = self.bump()
      raise ParseError::UnexpectedToken(
        expected="`use <module-ref> { ... }`",
        got=tok.text(),
        span=self.token_span(),
      )
    }
    k if k == export_kw() => self.parse_export_stmt()
    k if k == test_kw() => self.parse_test_stmt()
    k if k == bench_kw() => self.parse_bench_stmt()
    k if k == name() => {
      let tok = self.peek()
      let next = self.peek_non_trivia_ahead(1)
      let next2 = self.peek_non_trivia_ahead(2)
      if tok.text() == "module" && next == name() && next2 == lbrace() {
        self.parse_module_stmt(false)
      } else if tok.text() == "suberror" {
        self.parse_suberror_stmt()
      } else {
        if tok.text() == "open" && next == trait_kw() {
          raise ParseError::UnexpectedToken(
            expected="`open trait` is only allowed as `export open trait`",
            got=tok.text(),
            span=self.token_span(),
          )
        }
        if tok.text() == "alias" && next == name() && next2 == eq() {
          raise ParseError::UnexpectedToken(
            expected="`alias` statement is removed; use `type` for type aliases",
            got=tok.text(),
            span=self.token_span(),
          )
        }
        if tok.text() == "flake" && next == lbrace() {
          raise ParseError::UnexpectedToken(
            expected="`flake` block is removed",
            got=tok.text(),
            span=self.token_span(),
          )
        }
        let assign_next = self.peek_non_trivia_kind(self.pos + 1)
        if assign_next == eq() || is_compound_assign(assign_next) {
          self.parse_assign_stmt()
        } else {
          self.parse_expr_or_index_assign_stmt()
        }
      }
    }
    _ => self.parse_expr_or_index_assign_stmt()
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
    let next_kind = self.peek_non_trivia_kind(self.pos + 1)
    let next2_kind = self.peek_non_trivia_kind(self.pos + 2)
    let is_pattern = self.peek_kind() == lparen() ||
      self.peek_kind() == record_kw() ||
      self.peek_kind() == lbracket() ||
      (
        self.peek_kind() == name() &&
        next_kind != colon() &&
        @core.is_ctor_name(self.peek().text()) &&
        (
          next_kind != double_colon() ||
          (next_kind == double_colon() && next2_kind == lbrace())
        )
      )
    if is_pattern {
      let pat = self.parse_pattern()
      let _ = self.expect(eq(), "=")
      let expr = self.parse_expr()
      let _ = self.eat(semicolon())
      let span = self.span_from(start)
      return @core.Stmt::LetPat(pat~, expr~, span~)
    }
  }
  let binding_name = self.parse_type_member_name("name")
  let ann_ty : @core.Type? = if self.peek_kind() == colon() {
    let _ = self.bump()
    self.skip_trivia()
    Some(self.parse_type())
  } else {
    None
  }
  let _ = self.expect(eq(), "=")
  let raw_expr = self.parse_expr()
  let _ = self.eat(semicolon())
  let span = self.span_from(start)
  let expr = match ann_ty {
    Some(ty) =>
      if rec_flag {
        raw_expr
      } else {
        wrap_local_let_with_annotation(ty, raw_expr, span)
      }
    None => raw_expr
  }
  if mut_flag {
    @core.Stmt::LetMut(name=binding_name, expr~, span~)
  } else {
    @core.Stmt::Let(rec=rec_flag, name=binding_name, expr~, span~)
  }
}

///|
fn wrap_local_let_with_annotation(
  ann_ty : @core.Type,
  raw_expr : @core.Expr,
  span : @core.Span,
) -> @core.Expr {
  let helper_name = "__xsh_local_type_assert_" + span.start.to_string()
  let helper_param_name = "__xsh_local_type_assert_value"
  let helper_param = @core.FuncParam::{
    name: helper_param_name,
    label: @core.ParamLabel::Positional,
    ty: ann_ty,
    bounds: [],
  }
  let helper_body_expr = @core.Expr::Ident(name=helper_param_name, span~)
  let helper_body = @core.Module::{
    stmts: [@core.Stmt::Expr(expr=helper_body_expr, span~)],
  }
  let helper_expr = @core.Expr::Fn(
    type_params=[],
    type_bounds={},
    params=[helper_param],
    ret=Some(ann_ty),
    effects=[],
    body=helper_body,
    span~,
  )
  let helper_stmt = @core.Stmt::Let(
    rec=false,
    name=helper_name,
    expr=helper_expr,
    span~,
  )
  let call_arg_span = raw_expr.span()
  let call_expr = @core.Expr::Call(
    name=helper_name,
    type_args=[],
    args=[@core.CallArg::{ label: None, expr: raw_expr, span: call_arg_span }],
    span~,
  )
  @core.Expr::Block(
    body=@core.Module::{
      stmts: [helper_stmt, @core.Stmt::Expr(expr=call_expr, span~)],
    },
    span~,
  )
}

///|
fn AstParser::parse_type_member_name(
  self : AstParser,
  label : String,
) -> String raise ParseError {
  let base_tok = self.expect(name(), label)
  let mut out = base_tok.text()
  self.skip_trivia()
  if self.peek_kind() == double_colon() {
    let _ = self.bump()
    self.skip_trivia()
    let member_tok = self.expect(name(), label + " member")
    out = out + "::" + member_tok.text()
  }
  out
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
fn AstParser::expect_decl_separator(
  self : AstParser,
  separator_name : String,
) -> Unit raise ParseError {
  self.skip_trivia()
  match self.peek_kind() {
    k if k == semicolon() => {
      let _ = self.bump()
    }
    k if k == comma() =>
      raise ParseError::UnexpectedToken(
        expected="; (" + separator_name + ")",
        got=self.peek().text(),
        span=self.token_span(),
      )
    k if k == rbrace() => ()
    k if k == eof() => raise ParseError::UnexpectedEof(span=self.token_span())
    _ =>
      raise ParseError::UnexpectedToken(
        expected="; (" + separator_name + ")",
        got=self.peek().text(),
        span=self.token_span(),
      )
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
  while ({
          self.skip_trivia()
          self.peek_kind() != rbrace()
        }) {
    if self.peek_kind() == eof() {
      raise ParseError::UnexpectedEof(span=self.token_span())
    }
    ctors.push(self.parse_type_ctor(param_set))
    self.expect_decl_separator("enum variant separator")
  }
  let _ = self.expect(rbrace(), "}")
  let derives = self.parse_derive_clause()
  let _ = self.eat(semicolon())
  let span = self.span_from(start)
  self.queue_derive_impls(name_tok.text(), params, derives, span)
  @core.Stmt::EnumDef(name=name_tok.text(), params~, ctors~, span~)
}

///|
fn AstParser::parse_suberror_stmt(
  self : AstParser,
) -> @core.Stmt raise ParseError {
  let start = self.pos
  let _ = self.expect(name(), "suberror")
  self.skip_trivia()
  let name_tok = self.expect(name(), "suberror name")
  let params = self.parse_type_params()
  let param_set = param_set_from_params(params)
  self.skip_trivia()
  let ctors : Array[@core.TypeCtor] = []
  if self.peek_kind() == lparen() {
    let ctor_start = self.pos
    let _ = self.bump()
    self.skip_trivia()
    let args : Array[@core.Type] = []
    if self.peek_kind() != rparen() {
      args.push(self.parse_type_with_params(param_set))
      while ({
              self.skip_trivia()
              self.peek_kind() == comma()
            }) {
        let _ = self.bump()
        self.skip_trivia()
        if self.peek_kind() == rparen() {
          break
        }
        args.push(self.parse_type_with_params(param_set))
      }
    }
    let _ = self.expect(rparen(), ")")
    ctors.push(@core.TypeCtor::{
      name: name_tok.text(),
      args,
      span: self.span_from(ctor_start),
    })
  } else if self.peek_kind() == lbrace() {
    let _ = self.bump()
    while ({
            self.skip_trivia()
            self.peek_kind() != rbrace()
          }) {
      if self.peek_kind() == eof() {
        raise ParseError::UnexpectedEof(span=self.token_span())
      }
      ctors.push(self.parse_type_ctor(param_set))
      self.expect_decl_separator("suberror variant separator")
    }
    let _ = self.expect(rbrace(), "}")
  } else {
    raise ParseError::UnexpectedToken(
      expected="suberror payload",
      got=self.peek().text(),
      span=self.token_span(),
    )
  }
  let derives = self.parse_derive_clause()
  let _ = self.eat(semicolon())
  let span = self.span_from(start)
  self.queue_derive_impls(name_tok.text(), params, derives, span)
  self.queue_suberror_impl(name_tok.text(), params, span)
  @core.Stmt::EnumDef(name=name_tok.text(), params~, ctors~, span~)
}

///|
fn AstParser::parse_struct_stmt(
  self : AstParser,
) -> @core.Stmt raise ParseError {
  let start = self.pos
  let _ = self.expect(struct_kw(), "struct")
  self.skip_trivia()
  let name_tok = self.expect(name(), "struct name")
  let params = self.parse_type_params()
  let param_set = param_set_from_params(params)
  self.skip_trivia()
  let _ = self.expect(lbrace(), "{")
  let fields : Array[@core.StructField] = []
  while ({
          self.skip_trivia()
          self.peek_kind() != rbrace()
        }) {
    if self.peek_kind() == eof() {
      raise ParseError::UnexpectedEof(span=self.token_span())
    }
    let field_start = self.pos
    let field_name = self.expect(name(), "field name")
    self.skip_trivia()
    let _ = self.expect(colon(), ":")
    let field_ty = self.parse_type_with_params(param_set)
    fields.push(@core.StructField::{
      name: field_name.text(),
      ty: field_ty,
      span: self.span_from(field_start),
    })
    self.expect_decl_separator("struct field separator")
  }
  let _ = self.expect(rbrace(), "}")
  let derives = self.parse_derive_clause()
  let _ = self.eat(semicolon())
  let span = self.span_from(start)
  self.queue_derive_impls(name_tok.text(), params, derives, span)
  @core.Stmt::StructDef(name=name_tok.text(), params~, fields~, span~)
}

///|
fn AstParser::parse_derive_clause(
  self : AstParser,
) -> Array[String] raise ParseError {
  self.skip_trivia()
  if self.peek_kind() != name() || self.peek().text() != "derive" {
    return []
  }
  let _ = self.bump()
  self.skip_trivia()
  let _ = self.expect(lparen(), "(")
  let traits : Array[String] = []
  self.skip_trivia()
  if self.peek_kind() != rparen() {
    let first = self.expect(name(), "trait name")
    traits.push(first.text())
    while ({
            self.skip_trivia()
            self.peek_kind() == comma()
          }) {
      let _ = self.bump()
      self.skip_trivia()
      if self.peek_kind() == rparen() {
        break
      }
      let next = self.expect(name(), "trait name")
      traits.push(next.text())
    }
  }
  let _ = self.expect(rparen(), ")")
  traits
}

///|
fn AstParser::queue_derive_impls(
  self : AstParser,
  type_name : String,
  type_params : Array[String],
  derives : Array[String],
  span : @core.Span,
) -> Unit {
  let target_args : Array[@core.Type] = []
  for type_param in type_params {
    target_args.push(@core.Type::Param(type_param))
  }
  let target = @core.Type::Named(name=type_name, args=target_args)
  let seen : Map[String, Bool] = {}
  for trait_name in derives {
    if seen.contains(trait_name) {
      continue
    }
    seen[trait_name] = true
    let type_bounds : Map[String, Array[String]] = {}
    for type_param in type_params {
      type_bounds[type_param] = [trait_name]
    }
    self.pending_stmts.push(
      @core.Stmt::TraitImpl(
        type_params=type_params.copy(),
        type_bounds~,
        trait_name~,
        target~,
        span~,
      ),
    )
  }
}

///|
fn AstParser::queue_suberror_impl(
  self : AstParser,
  type_name : String,
  type_params : Array[String],
  span : @core.Span,
) -> Unit {
  let target_args : Array[@core.Type] = []
  for type_param in type_params {
    target_args.push(@core.Type::Param(type_param))
  }
  let target = @core.Type::Named(name=type_name, args=target_args)
  self.pending_stmts.push(
    @core.Stmt::TraitImpl(
      type_params=type_params.copy(),
      type_bounds={},
      trait_name="Error",
      target~,
      span~,
    ),
  )
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
fn AstParser::parse_trait_stmt(self : AstParser) -> @core.Stmt raise ParseError {
  let start = self.pos
  let _ = self.expect(trait_kw(), "trait")
  self.skip_trivia()
  let name_tok = self.expect(name(), "trait name")
  self.skip_trivia()
  let supertraits = if self.peek_kind() == colon() {
    let _ = self.bump()
    self.skip_trivia()
    self.parse_trait_bounds()
  } else {
    []
  }
  let _ = self.eat(semicolon())
  let span = self.span_from(start)
  @core.Stmt::TraitDef(
    name=name_tok.text(),
    supertraits~,
    open_impl=false,
    exported=false,
    span~,
  )
}

///|
fn AstParser::parse_impl_stmt(self : AstParser) -> @core.Stmt raise ParseError {
  let start = self.pos
  let _ = self.expect(impl_kw(), "impl")
  let parsed = self.parse_fn_type_params()
  let type_params = parsed.names
  let type_bounds = parsed.bounds
  self.skip_trivia()
  let trait_tok = self.expect(name(), "trait name")
  self.skip_trivia()
  let for_tok = self.expect(name(), "for")
  if for_tok.text() != "for" {
    raise ParseError::UnexpectedToken(
      expected="for",
      got=for_tok.text(),
      span=self.token_span(),
    )
  }
  let target = self.parse_type_with_params(param_set_from_params(type_params))
  let _ = self.eat(semicolon())
  let span = self.span_from(start)
  @core.Stmt::TraitImpl(
    type_params~,
    type_bounds~,
    trait_name=trait_tok.text(),
    target~,
    span~,
  )
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
      if self.peek_kind() == mut_kw() {
        raise ParseError::MutableEnumFieldUnsupported(span=self.token_span())
      }
      args.push(self.parse_type_with_params(params))
      while ({
              self.skip_trivia()
              self.peek_kind() == comma()
            }) {
        let _ = self.bump()
        self.skip_trivia()
        if self.peek_kind() == rparen() {
          break
        }
        if self.peek_kind() == mut_kw() {
          raise ParseError::MutableEnumFieldUnsupported(span=self.token_span())
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
      while ({
              self.skip_trivia()
              self.peek_kind() == comma()
            }) {
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
fn AstParser::parse_test_stmt(self : AstParser) -> @core.Stmt raise ParseError {
  let start = self.pos
  let _ = self.expect(test_kw(), "test")
  self.skip_trivia()
  let mut test_name : String? = None
  if self.peek_kind() == string_lit() || self.peek_kind() == name() {
    let name_tok = self.bump()
    test_name = Some(name_tok.text())
    self.skip_trivia()
  }
  let body = self.parse_block()
  let span = self.span_from(start)
  @core.Stmt::Test(name=test_name, body~, span~)
}

///|
fn AstParser::parse_bench_stmt(self : AstParser) -> @core.Stmt raise ParseError {
  let start = self.pos
  let _ = self.expect(bench_kw(), "bench")
  self.skip_trivia()
  let mut bench_name : String? = None
  if self.peek_kind() == string_lit() || self.peek_kind() == name() {
    let name_tok = self.bump()
    bench_name = Some(name_tok.text())
    self.skip_trivia()
  }
  let body = self.parse_block()
  let span = self.span_from(start)
  @core.Stmt::Bench(name=bench_name, body~, span~)
}

///|
fn module_qualified_name(module_name : String, member_name : String) -> String {
  if member_name.contains("::") {
    member_name
  } else {
    module_name + "::" + member_name
  }
}

///|
fn collect_module_decl_names(stmts : Array[@core.Stmt]) -> Map[String, String] {
  let out : Map[String, String] = {}
  for stmt in stmts {
    match stmt {
      @core.Stmt::Let(name~, ..)
      | @core.Stmt::ExportLet(name~, ..)
      | @core.Stmt::LetMut(name~, ..) =>
        if not(name.contains("::")) {
          out[name] = name
        }
      _ => ()
    }
  }
  out
}

///|
fn local_module_name(
  module_name : String,
  name : String,
  locals : Map[String, String],
) -> String {
  match locals.get(name) {
    Some(_) => module_qualified_name(module_name, name)
    None => name
  }
}

///|
fn module_locals_without(
  locals : Map[String, String],
  names : Array[String],
) -> Map[String, String] {
  let out : Map[String, String] = {}
  for key, value in locals {
    let mut shadowed = false
    for name in names {
      if key == name {
        shadowed = true
        break
      }
    }
    if not(shadowed) {
      out[key] = value
    }
  }
  out
}

///|
fn collect_pat_bindings_for_module(
  pat : @core.Pat,
  out : Array[String],
) -> Unit {
  match pat {
    @core.Pat::Bind(name~, ..) => if name != "_" { out.push(name) }
    @core.Pat::Ctor(args~, ..) =>
      for arg in args {
        collect_pat_bindings_for_module(arg, out)
      }
    @core.Pat::Tuple(items~, ..) =>
      for item in items {
        collect_pat_bindings_for_module(item, out)
      }
    @core.Pat::Record(fields~, ..) =>
      for field in fields {
        collect_pat_bindings_for_module(field.pat, out)
      }
    @core.Pat::Struct(fields~, ..) =>
      for field in fields {
        collect_pat_bindings_for_module(field.pat, out)
      }
    @core.Pat::Or(pats~, ..) =>
      for p in pats {
        collect_pat_bindings_for_module(p, out)
      }
    _ => ()
  }
}

///|
fn rewrite_module_expr(
  module_name : String,
  expr : @core.Expr,
  locals : Map[String, String],
) -> @core.Expr {
  match expr {
    @core.Expr::Ident(name~, span~) =>
      @core.Expr::Ident(
        name=local_module_name(module_name, name, locals),
        span~,
      )
    @core.Expr::Call(name~, type_args~, args~, span~) => {
      let next_args : Array[@core.CallArg] = []
      for arg in args {
        next_args.push(@core.CallArg::{
          label: arg.label,
          expr: rewrite_module_expr(module_name, arg.expr, locals),
          span: arg.span,
        })
      }
      @core.Expr::Call(
        name=local_module_name(module_name, name, locals),
        type_args~,
        args=next_args,
        span~,
      )
    }
    @core.Expr::Tuple(items~, span~) => {
      let next_items : Array[@core.Expr] = []
      for item in items {
        next_items.push(rewrite_module_expr(module_name, item, locals))
      }
      @core.Expr::Tuple(items=next_items, span~)
    }
    @core.Expr::TupleIndex(expr~, index~, span~) =>
      @core.Expr::TupleIndex(
        expr=rewrite_module_expr(module_name, expr, locals),
        index~,
        span~,
      )
    @core.Expr::Record(fields~, span~) => {
      let next_fields : Array[@core.RecordFieldExpr] = []
      for field in fields {
        next_fields.push(@core.RecordFieldExpr::{
          name: field.name,
          expr: rewrite_module_expr(module_name, field.expr, locals),
          span: field.span,
        })
      }
      @core.Expr::Record(fields=next_fields, span~)
    }
    @core.Expr::Array(items~, span~) => {
      let next_items : Array[@core.Expr] = []
      for item in items {
        next_items.push(rewrite_module_expr(module_name, item, locals))
      }
      @core.Expr::Array(items=next_items, span~)
    }
    @core.Expr::Map(fields~, span~) => {
      let next_fields : Array[@core.MapFieldExpr] = []
      for field in fields {
        next_fields.push(@core.MapFieldExpr::{
          key: field.key,
          expr: rewrite_module_expr(module_name, field.expr, locals),
          span: field.span,
        })
      }
      @core.Expr::Map(fields=next_fields, span~)
    }
    @core.Expr::If(cond~, then_body~, else_body~, span~) =>
      @core.Expr::If(
        cond=rewrite_module_expr(module_name, cond, locals),
        then_body=rewrite_module_block(module_name, then_body, locals),
        else_body=rewrite_module_block(module_name, else_body, locals),
        span~,
      )
    @core.Expr::Block(body~, span~) =>
      @core.Expr::Block(
        body=rewrite_module_block(module_name, body, locals),
        span~,
      )
    @core.Expr::Match(scrutinee~, arms~, span~) => {
      let next_arms : Array[@core.MatchArm] = []
      for arm in arms {
        let pat_bindings : Array[String] = []
        collect_pat_bindings_for_module(arm.pat, pat_bindings)
        let arm_locals = module_locals_without(locals, pat_bindings)
        let next_cond = match arm.cond {
          Some(cond) => Some(rewrite_module_expr(module_name, cond, arm_locals))
          None => None
        }
        next_arms.push(@core.MatchArm::{
          pat: arm.pat,
          cond: next_cond,
          expr: rewrite_module_expr(module_name, arm.expr, arm_locals),
          span: arm.span,
        })
      }
      @core.Expr::Match(
        scrutinee=rewrite_module_expr(module_name, scrutinee, locals),
        arms=next_arms,
        span~,
      )
    }
    @core.Expr::Do(body~, span~) =>
      @core.Expr::Do(
        body=rewrite_module_block(module_name, body, locals),
        span~,
      )
    @core.Expr::Try(try_body~, catch_body~, span~) =>
      @core.Expr::Try(
        try_body=rewrite_module_block(module_name, try_body, locals),
        catch_body=rewrite_module_block(module_name, catch_body, locals),
        span~,
      )
    @core.Expr::Fn(
      type_params~,
      type_bounds~,
      params~,
      ret~,
      effects~,
      body~,
      span~
    ) => {
      let shadow : Array[String] = []
      for param in params {
        shadow.push(param.name)
      }
      let inner_locals = module_locals_without(locals, shadow)
      @core.Expr::Fn(
        type_params~,
        type_bounds~,
        params~,
        ret~,
        effects~,
        body=rewrite_module_block(module_name, body, inner_locals),
        span~,
      )
    }
    @core.Expr::While(cond~, body~, span~) =>
      @core.Expr::While(
        cond=rewrite_module_expr(module_name, cond, locals),
        body=rewrite_module_block(module_name, body, locals),
        span~,
      )
    @core.Expr::Raise(value~, span~) =>
      @core.Expr::Raise(
        value=rewrite_module_expr(module_name, value, locals),
        span~,
      )
    @core.Expr::Await(expr~, span~) =>
      @core.Expr::Await(
        expr=rewrite_module_expr(module_name, expr, locals),
        span~,
      )
    @core.Expr::Yield(expr~, span~) =>
      @core.Expr::Yield(
        expr=rewrite_module_expr(module_name, expr, locals),
        span~,
      )
    @core.Expr::StructLit(name~, type_args~, fields~, span~) => {
      let next_fields : Array[@core.RecordFieldExpr] = []
      for field in fields {
        next_fields.push(@core.RecordFieldExpr::{
          name: field.name,
          expr: rewrite_module_expr(module_name, field.expr, locals),
          span: field.span,
        })
      }
      @core.Expr::StructLit(name~, type_args~, fields=next_fields, span~)
    }
    _ => expr
  }
}

///|
fn rewrite_module_stmt(
  module_name : String,
  stmt : @core.Stmt,
  locals : Map[String, String],
  exported_module : Bool,
) -> @core.Stmt raise ParseError {
  match stmt {
    @core.Stmt::Let(rec~, name~, expr~, span~) =>
      @core.Stmt::Let(
        rec~,
        name=module_qualified_name(module_name, name),
        expr=rewrite_module_expr(module_name, expr, locals),
        span~,
      )
    @core.Stmt::ExportLet(rec~, name~, expr~, span~) => {
      let next_expr = rewrite_module_expr(module_name, expr, locals)
      let qualified_name = module_qualified_name(module_name, name)
      if exported_module {
        @core.Stmt::ExportLet(rec~, name=qualified_name, expr=next_expr, span~)
      } else {
        @core.Stmt::Let(rec~, name=qualified_name, expr=next_expr, span~)
      }
    }
    @core.Stmt::LetMut(name~, expr~, span~) =>
      @core.Stmt::LetMut(
        name=module_qualified_name(module_name, name),
        expr=rewrite_module_expr(module_name, expr, locals),
        span~,
      )
    @core.Stmt::Assign(name~, expr~, span~) =>
      @core.Stmt::Assign(
        name=local_module_name(module_name, name, locals),
        expr=rewrite_module_expr(module_name, expr, locals),
        span~,
      )
    @core.Stmt::IndexAssign(target~, index~, value~, span~) =>
      @core.Stmt::IndexAssign(
        target=rewrite_module_expr(module_name, target, locals),
        index=rewrite_module_expr(module_name, index, locals),
        value=rewrite_module_expr(module_name, value, locals),
        span~,
      )
    @core.Stmt::Expr(expr~, span~) =>
      @core.Stmt::Expr(
        expr=rewrite_module_expr(module_name, expr, locals),
        span~,
      )
    @core.Stmt::Import(..) => stmt
    @core.Stmt::Export(names~, span~) =>
      if not(exported_module) {
        @core.Stmt::Export(names=[], span~)
      } else {
        let qualified_names : Array[String] = []
        for name in names {
          qualified_names.push(module_qualified_name(module_name, name))
        }
        @core.Stmt::Export(names=qualified_names, span~)
      }
    @core.Stmt::Test(name~, body~, span~) =>
      @core.Stmt::Test(
        name~,
        body=rewrite_module_block(module_name, body, locals),
        span~,
      )
    @core.Stmt::Bench(name~, body~, span~) =>
      @core.Stmt::Bench(
        name~,
        body=rewrite_module_block(module_name, body, locals),
        span~,
      )
    _ =>
      raise ParseError::UnexpectedToken(
        expected="module body statement (let/export let/let mut/assign/expr/import/test/bench)",
        got="unsupported statement",
        span=stmt.span(),
      )
  }
}

///|
fn rewrite_module_block(
  module_name : String,
  body : @core.Module,
  locals : Map[String, String],
) -> @core.Module {
  let next_stmts : Array[@core.Stmt] = []
  let mut active_locals = locals
  for stmt in body.stmts {
    let rewritten = rewrite_module_stmt(module_name, stmt, active_locals, false) catch {
      _ => stmt
    }
    next_stmts.push(rewritten)
    match stmt {
      @core.Stmt::Let(name~, ..) | @core.Stmt::LetMut(name~, ..) => {
        let shadow = [name]
        active_locals = module_locals_without(active_locals, shadow)
      }
      @core.Stmt::LetPat(pat~, ..) => {
        let shadow : Array[String] = []
        collect_pat_bindings_for_module(pat, shadow)
        active_locals = module_locals_without(active_locals, shadow)
      }
      @core.Stmt::Import(spec~, ..) =>
        for item in spec.items {
          let local_name = match item.rename {
            Some(rename) => rename
            None => item.name
          }
          let shadow = [local_name]
          active_locals = module_locals_without(active_locals, shadow)
        }
      _ => ()
    }
  }
  @core.Module::{ stmts: next_stmts }
}

///|
fn AstParser::parse_module_stmt(
  self : AstParser,
  exported : Bool,
) -> @core.Stmt raise ParseError {
  let start = self.pos
  let module_tok = self.expect(name(), "module")
  if module_tok.text() != "module" {
    raise ParseError::UnexpectedToken(
      expected="module",
      got=module_tok.text(),
      span=self.token_span(),
    )
  }
  self.skip_trivia()
  let name_tok = self.expect(name(), "module name")
  let module_name = name_tok.text()
  self.skip_trivia()
  let body = self.parse_block()
  let span = self.span_from(start)
  let locals = collect_module_decl_names(body.stmts)
  let lowered : Array[@core.Stmt] = []
  for stmt in body.stmts {
    lowered.push(rewrite_module_stmt(module_name, stmt, locals, exported))
  }
  if lowered.length() == 0 {
    raise ParseError::UnexpectedToken(
      expected="non-empty module body",
      got="}",
      span~,
    )
  }
  let first = lowered[0]
  let mut i = 1
  while i < lowered.length() {
    self.pending_stmts.push(lowered[i])
    i += 1
  }
  first
}

///|
fn AstParser::parse_block(self : AstParser) -> @core.Module raise ParseError {
  let _ = self.expect(lbrace(), "{")
  let stmts : Array[@core.Stmt] = []
  while ({
          self.skip_trivia()
          self.peek_kind() != rbrace()
        }) {
    if self.peek_kind() == eof() {
      raise ParseError::UnexpectedEof(span=self.token_span())
    }
    stmts.push(self.parse_stmt())
    for pending in self.pending_stmts {
      stmts.push(pending)
    }
    self.pending_stmts = []
  }
  let _ = self.expect(rbrace(), "}")
  @core.Module::{ stmts, }
}

///|
fn AstParser::parse_import_stmt(
  self : AstParser,
) -> @core.Stmt raise ParseError {
  let start = self.pos
  let _ = self.expect(use_kw(), "use")
  self.skip_trivia()
  let source = self.parse_module_ref()
  self.skip_trivia()
  let items = if self.peek_kind() == lbrace() {
    self.parse_import_items("use name")
  } else {
    let rename : String? = if self.peek_kind() == as_kw() {
      let _ = self.bump()
      self.skip_trivia()
      let alias_tok = self.expect(name(), "alias name")
      Some(alias_tok.text())
    } else {
      None
    }
    [
      @core.ImportItem::{
        kind: @core.ImportKind::Module,
        name: use_namespace_name_from_source(source),
        rename,
      },
    ]
  }
  let spec = @core.ImportSpec::{ items, }
  let _ = self.eat(semicolon())
  let span = self.span_from(start)
  @core.Stmt::Import(spec~, source~, span~)
}

///|
fn strip_module_path_suffix(path : String) -> String {
  if path.has_suffix(".vibe") && path.length() > 5 {
    (try! path[0:path.length() - 5]).to_string()
  } else if path.has_suffix(".xm") && path.length() > 3 {
    (try! path[0:path.length() - 3]).to_string()
  } else {
    path
  }
}

///|
fn use_namespace_name_from_path(path : String) -> String {
  if path.has_prefix("/vibe/") && path.length() > 6 {
    let inner = (try! path[6:path.length()]).to_string()
    let trimmed = strip_module_path_suffix(inner)
    if trimmed.length() > 0 {
      trimmed
    } else {
      @core.import_alias_name(path)
    }
  } else {
    @core.import_alias_name(path)
  }
}

///|
fn hash_prefix8(hash : String) -> String {
  if hash.length() > 8 {
    hash.unsafe_substring(start=0, end=8)
  } else {
    hash
  }
}

///|
fn use_namespace_name_from_source(source : @core.ModuleRef) -> String {
  match source {
    @core.ModuleRef::Path(path~) => use_namespace_name_from_path(path)
    @core.ModuleRef::Hash(hash~) => "hash_" + hash_prefix8(hash)
    @core.ModuleRef::Version(name~) => "version_" + name
    @core.ModuleRef::Symbol(name~) => name
  }
}

///|
fn AstParser::parse_module_item_name(
  self : AstParser,
  label : String,
) -> String raise ParseError {
  let base_tok = self.expect(name(), label)
  let mut out = base_tok.text()
  self.skip_trivia()
  while self.peek_kind() == slash() {
    let _ = self.bump()
    self.skip_trivia()
    let seg_tok = self.expect(name(), label + " segment")
    out = out + "/" + seg_tok.text()
    self.skip_trivia()
  }
  out
}

///|
fn AstParser::parse_import_items(
  self : AstParser,
  item_label : String,
) -> Array[@core.ImportItem] raise ParseError {
  let _ = self.expect(lbrace(), "{")
  let items : Array[@core.ImportItem] = []
  while true {
    self.skip_trivia()
    if self.peek_kind() == rbrace() {
      break
    }
    if self.peek_kind() == comma() {
      raise ParseError::UnexpectedToken(
        expected=item_label + " after `,`",
        got=self.peek().text(),
        span=self.token_span(),
      )
    }
    let kind = self.parse_import_item_kind()
    self.skip_trivia()
    let import_name = if kind == @core.ImportKind::Module {
      self.parse_module_item_name("module name")
    } else {
      self.parse_type_member_name(item_label)
    }
    if kind == @core.ImportKind::Module && self.peek_kind() == double_colon() {
      raise ParseError::UnexpectedToken(
        expected="`use <module-ref> { module foo }` (module namespace only)",
        got=self.peek().text(),
        span=self.token_span(),
      )
    }
    self.skip_trivia()
    let rename : String? = if self.peek_kind() == as_kw() {
      let _ = self.bump()
      self.skip_trivia()
      let alias_tok = self.expect(name(), "alias name")
      Some(alias_tok.text())
    } else {
      None
    }
    items.push(@core.ImportItem::{ kind, name: import_name, rename })
    self.skip_trivia()
    if self.peek_kind() == comma() {
      let _ = self.bump()
      self.skip_trivia()
      if self.peek_kind() == rbrace() {
        break
      }
    } else if self.peek_kind() != rbrace() {
      raise ParseError::UnexpectedToken(
        expected="`,` or `}` in import list",
        got=self.peek().text(),
        span=self.token_span(),
      )
    }
  }
  let _ = self.expect(rbrace(), "}")
  items
}

///|
fn AstParser::parse_import_item_kind(self : AstParser) -> @core.ImportKind {
  if self.peek_kind() == type_kw() {
    let _ = self.bump()
    @core.ImportKind::Type
  } else if self.peek_kind() == trait_kw() {
    let _ = self.bump()
    @core.ImportKind::Trait
  } else if self.peek_kind() == name() && self.peek().text() == "module" {
    let _ = self.bump()
    @core.ImportKind::Module
  } else {
    @core.ImportKind::Value
  }
}

///|
/// Parse a module reference: path, hash, version ref, or symbol ref.
fn AstParser::parse_module_ref(
  self : AstParser,
) -> @core.ModuleRef raise ParseError {
  if self.peek_kind() == string_lit() {
    let tok = self.peek()
    raise ParseError::UnexpectedToken(
      expected="module path without quotes (e.g. ./vibe/std/string.vibe)",
      got=tok.text(),
      span=self.token_span(),
    )
  }
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
  } else if self.peek_kind() == slash() {
    let buf = StringBuilder::new()
    self.skip_trivia()
    while self.peek_kind() == slash() {
      let _ = self.bump()
      buf.write_char('/')
      self.skip_trivia()
    }
    if self.peek_kind() == name() {
      let seg = self.bump()
      buf.write_string(seg.text())
      self.skip_trivia()
    }
    while true {
      self.skip_trivia()
      if self.peek_kind() != dot() && self.peek_kind() != slash() {
        break
      }
      if self.peek_kind() == dot() {
        let _ = self.bump()
        buf.write_char('.')
      } else {
        let _ = self.bump()
        buf.write_char('/')
      }
      self.skip_trivia()
      if self.peek_kind() == name() {
        let seg = self.bump()
        buf.write_string(seg.text())
        self.skip_trivia()
      }
    }
    @core.ModuleRef::Path(path=buf.to_string())
  } else if self.peek_kind() == name() {
    let tok = self.peek()
    let text = tok.text()
    if text.has_prefix("version@") && text.length() > 8 {
      let _ = self.bump()
      let name = text.unsafe_substring(start=8, end=text.length())
      @core.ModuleRef::Version(name~)
    } else if text.has_prefix("symbol@") && text.length() > 7 {
      let _ = self.bump()
      let name = text.unsafe_substring(start=7, end=text.length())
      @core.ModuleRef::Symbol(name~)
    } else if text.has_prefix("version:") && text.length() > 8 {
      let _ = self.bump()
      let name = text.unsafe_substring(start=8, end=text.length())
      @core.ModuleRef::Version(name~)
    } else if text.has_prefix("symbol:") && text.length() > 7 {
      let _ = self.bump()
      let name = text.unsafe_substring(start=7, end=text.length())
      @core.ModuleRef::Symbol(name~)
    } else {
      // Path: ./foo/bar.vibe or foo.vibe
      let buf = StringBuilder::new()
      // Handle leading ./ or ../
      self.skip_trivia()
      while self.peek_kind() == dot() {
        let _ = self.bump()
        buf.write_char('.')
        self.skip_trivia()
        if self.peek_kind() == dot() {
          let _ = self.bump()
          buf.write_char('.')
          self.skip_trivia()
        }
        if self.peek_kind() == slash() {
          let _ = self.bump()
          buf.write_char('/')
          self.skip_trivia()
        }
      }
      // Path segments
      self.skip_trivia()
      if self.peek_kind() == name() {
        let seg = self.bump()
        buf.write_string(seg.text())
        self.skip_trivia()
      }
      while true {
        self.skip_trivia()
        if self.peek_kind() != dot() && self.peek_kind() != slash() {
          break
        }
        if self.peek_kind() == dot() {
          let _ = self.bump()
          buf.write_char('.')
        } else {
          let _ = self.bump()
          buf.write_char('/')
        }
        self.skip_trivia()
        if self.peek_kind() == name() {
          let seg = self.bump()
          buf.write_string(seg.text())
          self.skip_trivia()
        }
      }
      @core.ModuleRef::Path(path=buf.to_string())
    }
  } else {
    let tok = self.peek()
    if tok.kind() == dot() {
      let buf = StringBuilder::new()
      self.skip_trivia()
      while self.peek_kind() == dot() {
        let _ = self.bump()
        buf.write_char('.')
        self.skip_trivia()
        if self.peek_kind() == dot() {
          let _ = self.bump()
          buf.write_char('.')
          self.skip_trivia()
        }
        if self.peek_kind() == slash() {
          let _ = self.bump()
          buf.write_char('/')
          self.skip_trivia()
        }
      }
      self.skip_trivia()
      if self.peek_kind() == name() {
        let seg = self.bump()
        buf.write_string(seg.text())
        self.skip_trivia()
      }
      while true {
        self.skip_trivia()
        if self.peek_kind() != dot() && self.peek_kind() != slash() {
          break
        }
        if self.peek_kind() == dot() {
          let _ = self.bump()
          buf.write_char('.')
        } else {
          let _ = self.bump()
          buf.write_char('/')
        }
        self.skip_trivia()
        if self.peek_kind() == name() {
          let seg = self.bump()
          buf.write_string(seg.text())
          self.skip_trivia()
        }
      }
      @core.ModuleRef::Path(path=buf.to_string())
    } else {
      raise ParseError::UnexpectedToken(
        expected="path, hash, version ref, or symbol ref",
        got=tok.text(),
        span=self.token_span(),
      )
    }
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
  } else if self.peek_kind() == name() && self.peek().text() == "suberror" {
    // export suberror Name(...)
    let suberror_stmt = self.parse_suberror_stmt()
    match suberror_stmt {
      @core.Stmt::EnumDef(name~, params~, ctors~, ..) => {
        let span = self.span_from(start)
        @core.Stmt::ExportEnumDef(name~, params~, ctors~, span~)
      }
      _ => {
        let span = self.span_from(start)
        raise ParseError::UnexpectedToken(
          expected="suberror definition",
          got="other statement",
          span~,
        )
      }
    }
  } else if self.peek_kind() == struct_kw() {
    // export struct Name { ... }
    let struct_stmt = self.parse_struct_stmt()
    match struct_stmt {
      @core.Stmt::StructDef(name~, params~, fields~, ..) => {
        let span = self.span_from(start)
        @core.Stmt::ExportStructDef(name~, params~, fields~, span~)
      }
      _ => {
        let span = self.span_from(start)
        raise ParseError::UnexpectedToken(
          expected="struct definition",
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
  } else if self.peek_kind() == name() &&
    self.peek().text() == "module" &&
    self.peek_non_trivia_ahead(1) == name() &&
    self.peek_non_trivia_ahead(2) == lbrace() {
    self.parse_module_stmt(true)
  } else if self.peek_kind() == trait_kw() || self.peek_kind() == name() {
    let mut open_impl = false
    if self.peek_kind() == name() && self.peek().text() == "open" {
      let _ = self.bump()
      self.skip_trivia()
      open_impl = true
    }
    if self.peek_kind() != trait_kw() {
      let span = self.span_from(start)
      raise ParseError::UnexpectedToken(
        expected="trait definition",
        got=self.peek().text(),
        span~,
      )
    }
    let trait_stmt = self.parse_trait_stmt()
    match trait_stmt {
      @core.Stmt::TraitDef(name~, supertraits~, ..) => {
        let span = self.span_from(start)
        @core.Stmt::TraitDef(
          name~,
          supertraits~,
          open_impl~,
          exported=true,
          span~,
        )
      }
      _ => {
        let span = self.span_from(start)
        raise ParseError::UnexpectedToken(
          expected="trait definition",
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
      names.push(self.parse_type_member_name("export name"))
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
  } else if self.peek_kind() == loop_kw() {
    self.parse_loop_expr()
  } else if self.peek_kind() == match_kw() {
    self.parse_match_expr()
  } else if self.peek_kind() == do_kw() {
    self.parse_do_expr()
  } else if self.peek_kind() == try_kw() {
    self.parse_try_expr()
  } else if self.peek_kind() == break_kw() {
    self.parse_break_expr()
  } else if self.peek_kind() == continue_kw() {
    self.parse_continue_expr()
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
  while ({
          self.skip_trivia()
          self.peek_kind() == pipe_gt()
        }) {
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
  while ({
          self.skip_trivia()
          self.peek_kind() == bit_or()
        }) {
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
  while ({
          self.skip_trivia()
          self.peek_kind() == bit_xor()
        }) {
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
  while ({
          self.skip_trivia()
          self.peek_kind() == bit_and()
        }) {
    let _ = self.bump()
    let right = self.parse_cmp_expr()
    left = call2("__bit_and", left, right)
  }
  left
}

///|
fn AstParser::parse_or_expr(self : AstParser) -> @core.Expr raise ParseError {
  let mut left = self.parse_and_expr()
  while ({
          self.skip_trivia()
          self.peek_kind() == or_or()
        }) {
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
  while ({
          self.skip_trivia()
          self.peek_kind() == and_and()
        }) {
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
  while ({
          self.skip_trivia()
          self.peek_kind() == eqeq() ||
          self.peek_kind() == neq() ||
          self.peek_kind() == lt() ||
          self.peek_kind() == lte() ||
          self.peek_kind() == gt() ||
          self.peek_kind() == gte()
        }) {
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
  while ({
          self.skip_trivia()
          self.peek_kind() == lshift() || self.peek_kind() == rshift()
        }) {
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
  while ({
          self.skip_trivia()
          self.peek_kind() == plus() || self.peek_kind() == minus()
        }) {
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
  while ({
          self.skip_trivia()
          self.peek_kind() == star() ||
          self.peek_kind() == slash() ||
          self.peek_kind() == percent()
        }) {
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
      let start_pos = self.pos
      let _ = self.bump()
      self.skip_trivia()
      if self.peek_kind() == int_lit() {
        let lit = self.peek()
        if lit.text() == "2147483648" {
          let span = @core.Span::new(
            self.offset_at(start_pos),
            self.offset_at(self.pos) + lit.text().length(),
          )
          raise ParseError::IntMinLiteralBoundary(span~)
        }
      }
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
fn AstParser::parse_loop_expr(self : AstParser) -> @core.Expr raise ParseError {
  let start = self.pos
  let loop_tok = self.expect(loop_kw(), "loop")
  let body = self.parse_block()
  let span = self.span_from(start)
  let cond_span = @core.Span::new(
    span.start,
    span.start + loop_tok.text().length(),
  )
  let cond = @core.Expr::Bool(value=true, span=cond_span)
  @core.Expr::While(cond~, body~, span~)
}

///|
fn AstParser::parse_match_expr(self : AstParser) -> @core.Expr raise ParseError {
  let start = self.pos
  let _ = self.expect(match_kw(), "match")
  let scrutinee = self.parse_expr()
  let _ = self.expect(lbrace(), "{")
  let arms : Array[@core.MatchArm] = []
  while ({
          self.skip_trivia()
          self.peek_kind() != rbrace()
        }) {
    if self.peek_kind() == eof() {
      raise ParseError::UnexpectedEof(span=self.token_span())
    }
    let first_pat = self.parse_pattern()
    self.skip_trivia()
    // Check for or-pattern: A | B | C => ...
    let pat = if self.peek_kind() == bit_or() {
      let pats : Array[@core.Pat] = [first_pat]
      while ({
              self.skip_trivia()
              self.peek_kind() == bit_or()
            }) {
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
fn AstParser::parse_break_expr(self : AstParser) -> @core.Expr raise ParseError {
  let start = self.pos
  let _ = self.expect(break_kw(), "break")
  let span = self.span_from(start)
  @core.Expr::Break(span~)
}

///|
fn AstParser::parse_continue_expr(
  self : AstParser,
) -> @core.Expr raise ParseError {
  let start = self.pos
  let _ = self.expect(continue_kw(), "continue")
  let span = self.span_from(start)
  @core.Expr::Continue(span~)
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
  while ({
          self.skip_trivia()
          self.peek_kind() != rbrace()
        }) {
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
fn AstParser::parse_struct_lit_fields(
  self : AstParser,
) -> Array[@core.RecordFieldExpr] raise ParseError {
  let fields : Array[@core.RecordFieldExpr] = []
  while ({
          self.skip_trivia()
          self.peek_kind() != rbrace()
        }) {
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
  fields
}

///|
fn AstParser::parse_map_expr(self : AstParser) -> @core.Expr raise ParseError {
  let start = self.pos
  let _ = self.expect(map_kw(), "map")
  let _ = self.expect(lbrace(), "{")
  let fields : Array[@core.MapFieldExpr] = []
  while ({
          self.skip_trivia()
          self.peek_kind() != rbrace()
        }) {
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
  while ({
          self.skip_trivia()
          self.peek_kind() != rbracket()
        }) {
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
      while ({
              self.skip_trivia()
              self.peek_kind() == comma()
            }) {
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
    while ({
            self.skip_trivia()
            self.peek_kind() == comma()
          }) {
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
    while ({
            self.skip_trivia()
            self.peek_kind() == comma()
          }) {
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
            bounds: [],
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
  self.skip_trivia()
  let bounds : Array[String] = if self.peek_kind() == colon() {
    let _ = self.bump()
    self.skip_trivia()
    self.parse_trait_bounds()
  } else {
    []
  }
  @core.FuncParam::{ name: base, label, ty, bounds }
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
        "i32" =>
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
        "f32" =>
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
        "f64" =>
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
    while ({
            self.skip_trivia()
            self.peek_kind() == comma()
          }) {
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
      while ({
              self.skip_trivia()
              self.peek_kind() == comma()
            }) {
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
/// Supports optional trait bounds: [T: Eq, U: Show]
priv struct ParsedTypeParams {
  names : Array[String]
  bounds : Map[String, Array[String]]
}

///|
fn AstParser::parse_trait_bounds(
  self : AstParser,
) -> Array[String] raise ParseError {
  let bounds : Array[String] = []
  let first = self.expect(name(), "trait")
  bounds.push(first.text())
  while ({
          self.skip_trivia()
          self.peek_kind() == plus()
        }) {
    let _ = self.bump()
    self.skip_trivia()
    let next = self.expect(name(), "trait")
    bounds.push(next.text())
  }
  bounds
}

///|
fn AstParser::parse_fn_type_params(
  self : AstParser,
) -> ParsedTypeParams raise ParseError {
  let type_params : Array[String] = []
  let type_bounds : Map[String, Array[String]] = {}
  self.skip_trivia()
  if self.peek_kind() == lbracket() {
    let _ = self.bump()
    self.skip_trivia()
    if self.peek_kind() != rbracket() {
      let name_tok = self.expect(name(), "type parameter name")
      type_params.push(name_tok.text())
      self.skip_trivia()
      if self.peek_kind() == colon() {
        let _ = self.bump()
        self.skip_trivia()
        type_bounds[name_tok.text()] = self.parse_trait_bounds()
      }
      while ({
              self.skip_trivia()
              self.peek_kind() == comma()
            }) {
        let _ = self.bump()
        self.skip_trivia()
        if self.peek_kind() == rbracket() {
          break
        }
        let name_tok = self.expect(name(), "type parameter name")
        type_params.push(name_tok.text())
        self.skip_trivia()
        if self.peek_kind() == colon() {
          let _ = self.bump()
          self.skip_trivia()
          type_bounds[name_tok.text()] = self.parse_trait_bounds()
        }
      }
    }
    let _ = self.expect(rbracket(), "]")
  }
  ParsedTypeParams::{ names: type_params, bounds: type_bounds }
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
      while ({
              self.skip_trivia()
              self.peek_kind() == comma()
            }) {
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
    // Try to parse type parameters: [T, U] / [T: Trait]
    let parsed = self.parse_fn_type_params()
    let type_params = parsed.names
    let type_bounds = parsed.bounds
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
            @core.Expr::Fn(
              type_params~,
              type_bounds~,
              params~,
              ret~,
              effects~,
              body~,
              span~,
            ),
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
    Some(
      @core.Expr::Fn(
        type_params~,
        type_bounds~,
        params~,
        ret~,
        effects~,
        body~,
        span~,
      ),
    )
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
        while ({
                self.skip_trivia()
                self.peek_kind() == comma()
              }) {
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
fn parse_int_literal_token(
  tok : Token,
  span : @core.Span,
) -> Int raise ParseError {
  let parsed : Result[Int, @strconv.StrConvError] = try? @strconv.parse_int(
    tok.text(),
  )
  match parsed {
    Ok(v) => v
    Err(_) => raise ParseError::IntLiteralOverflow(literal=tok.text(), span~)
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
      let span = self.span_from(start)
      let value = parse_int_literal_token(tok, span)
      @core.Pat::Int(value~, span~)
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
        self.skip_trivia()
        // Check for struct pattern: Name::{ x, y }
        if self.peek_kind() == double_colon() {
          let _ = self.bump() // consume ::
          self.skip_trivia()
          let _ = self.expect(lbrace(), "{")
          let fields = self.parse_struct_pat_fields()
          let _ = self.expect(rbrace(), "}")
          let span = self.span_from(start)
          @core.Pat::Struct(name=tok.text(), fields~, span~)
        } else {
          // Enum constructor pattern: Name(args)
          let args : Array[@core.Pat] = []
          if self.peek_kind() == lparen() {
            let _ = self.bump()
            self.skip_trivia()
            if self.peek_kind() != rparen() {
              args.push(self.parse_pattern())
              while ({
                      self.skip_trivia()
                      self.peek_kind() == comma()
                    }) {
                let _ = self.bump()
                args.push(self.parse_pattern())
              }
            }
            let _ = self.expect(rparen(), ")")
          }
          let span = self.span_from(start)
          @core.Pat::Ctor(name=tok.text(), args~, span~)
        }
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
    while ({
            self.skip_trivia()
            self.peek_kind() == comma()
          }) {
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
  while ({
          self.skip_trivia()
          self.peek_kind() != rbrace()
        }) {
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
fn AstParser::parse_struct_pat_fields(
  self : AstParser,
) -> Array[@core.RecordFieldPat] raise ParseError {
  let fields : Array[@core.RecordFieldPat] = []
  while ({
          self.skip_trivia()
          self.peek_kind() != rbrace()
        }) {
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
  fields
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
    let base_name = name_tok.text()
    let mut qualified_name = base_name
    self.skip_trivia()
    if self.can_parse_slash_qualified_name() {
      while true {
        self.skip_trivia()
        if self.peek_kind() != slash() {
          break
        }
        let _ = self.bump()
        self.skip_trivia()
        let seg = self.expect(name(), "namespace segment")
        qualified_name = qualified_name + "/" + seg.text()
      }
      self.skip_trivia()
    }
    // Check for single-parameter lambda: x -> expr
    if self.peek_kind() == thin_arrow() {
      let _ = self.bump() // consume ->
      self.skip_trivia()
      let param = @core.FuncParam::{
        name: base_name,
        label: @core.ParamLabel::Positional,
        ty: @core.Type::Unit, // Placeholder for inference
        bounds: [],
      }
      // Check if block body or expression body
      if self.peek_kind() == lbrace() {
        // Block body: x -> { ... }
        let body = self.parse_block()
        let span = self.span_from(start)
        @core.Expr::Fn(
          type_params=[],
          type_bounds={},
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
          type_bounds={},
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
      if self.peek_kind() == double_colon() && @core.is_ctor_name(base_name) {
        // StructName[T]::{ field: value }
        let _ = self.bump() // consume ::
        self.skip_trivia()
        let _ = self.expect(lbrace(), "{")
        let fields = self.parse_struct_lit_fields()
        let _ = self.expect(rbrace(), "}")
        let span = self.span_from(start)
        @core.Expr::StructLit(name=base_name, type_args~, fields~, span~)
      } else if self.peek_kind() == lparen() {
        // name[Type](args) - generic function call
        let _ = self.bump()
        let args = self.parse_args()
        let _ = self.expect(rparen(), ")")
        let span = self.span_from(start)
        @core.Expr::Call(name=qualified_name, type_args~, args~, span~)
      } else {
        // name[Type] without parens - might be generic function reference
        let span = self.span_from(start)
        @core.Expr::Call(name=qualified_name, type_args~, args=[], span~)
      }
    } else if self.peek_kind() == double_colon() &&
      @core.is_ctor_name(base_name) &&
      self.peek_non_trivia_kind(self.pos + 1) == lbrace() {
      // StructName::{ field: value } or StructName[T]::{ field: value }
      let type_args : Array[@core.Type] = []
      let _ = self.bump() // consume ::
      self.skip_trivia()
      let _ = self.expect(lbrace(), "{")
      let fields = self.parse_struct_lit_fields()
      let _ = self.expect(rbrace(), "}")
      let span = self.span_from(start)
      @core.Expr::StructLit(name=base_name, type_args~, fields~, span~)
    } else if self.peek_kind() == double_colon() &&
      self.peek_non_trivia_kind(self.pos + 1) == name() {
      // Type-qualified symbol: Type::member
      let _ = self.bump()
      self.skip_trivia()
      let member_tok = self.expect(name(), "member name")
      qualified_name = qualified_name + "::" + member_tok.text()
      self.skip_trivia()
      if self.peek_kind() == lparen() {
        let _ = self.bump()
        let args = self.parse_args()
        let _ = self.expect(rparen(), ")")
        let span = self.span_from(start)
        @core.Expr::Call(name=qualified_name, type_args=[], args~, span~)
      } else {
        let span = self.span_from(start)
        @core.Expr::Ident(name=qualified_name, span~)
      }
    } else if self.peek_kind() == lparen() {
      let _ = self.bump()
      let args = self.parse_args()
      let _ = self.expect(rparen(), ")")
      let span = self.span_from(start)
      @core.Expr::Call(name=qualified_name, type_args=[], args~, span~)
    } else if base_name == "_" {
      // Placeholder for lambda shorthand: _ * 2 → x -> x * 2
      let span = self.span_from(start)
      @core.Expr::Placeholder(index=0, span~)
    } else {
      let span = self.span_from(start)
      @core.Expr::Ident(name=qualified_name, span~)
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
fn AstParser::can_parse_slash_qualified_name(self : AstParser) -> Bool {
  let mut i = self.pos
  let mut saw_segment = false
  while true {
    while i < self.tokens.length() && is_trivia(self.tokens[i].kind()) {
      i += 1
    }
    if i >= self.tokens.length() || self.tokens[i].kind() != slash() {
      break
    }
    saw_segment = true
    i += 1
    while i < self.tokens.length() && is_trivia(self.tokens[i].kind()) {
      i += 1
    }
    if i >= self.tokens.length() || self.tokens[i].kind() != name() {
      return false
    }
    i += 1
  }
  if not(saw_segment) {
    return false
  }
  while i < self.tokens.length() && is_trivia(self.tokens[i].kind()) {
    i += 1
  }
  if i >= self.tokens.length() || self.tokens[i].kind() != double_colon() {
    return false
  }
  i += 1
  while i < self.tokens.length() && is_trivia(self.tokens[i].kind()) {
    i += 1
  }
  i < self.tokens.length() && self.tokens[i].kind() == name()
}

///|
fn AstParser::parse_args(
  self : AstParser,
) -> Array[@core.CallArg] raise ParseError {
  let args : Array[@core.CallArg] = []
  self.skip_trivia()
  if self.peek_kind() != rparen() {
    args.push(self.parse_arg())
    while ({
            self.skip_trivia()
            self.peek_kind() == comma()
          }) {
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
      let span = self.span_from(start)
      let value = parse_int_literal_token(tok, span)
      @core.Expr::Int(value~, span~)
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
      bounds: [],
    })
  }
  let body = @core.Module::{
    stmts: [@core.Stmt::Expr(expr=body_expr, span=body_expr.span())],
  }
  @core.Expr::Fn(
    type_params=[],
    type_bounds={},
    params~,
    ret=None,
    effects=[],
    body~,
    span~,
  )
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
    @core.Stmt::Bench(name~, body~, span~) =>
      @core.Stmt::Bench(name~, body=desugar_module(body), span~)
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
    | @core.Stmt::TraitDef(..)
    | @core.Stmt::TraitImpl(..)
    | @core.Stmt::Import(..)
    | @core.Stmt::Export(..)
    | @core.Stmt::ExportEnumDef(..)
    | @core.Stmt::ExportTypeAlias(..)
    | @core.Stmt::ReExport(..)
    | @core.Stmt::StructDef(..)
    | @core.Stmt::ExportStructDef(..) => stmt
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
    @core.Expr::Fn(
      type_params~,
      type_bounds~,
      params~,
      ret~,
      effects~,
      body~,
      span~
    ) =>
      @core.Expr::Fn(
        type_params~,
        type_bounds~,
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
