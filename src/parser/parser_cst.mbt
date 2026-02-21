///|
/// Parser for vibe (CST + AST)
suberror ParseError {
  UnexpectedToken(expected~ : String, got~ : String, span~ : @core.Span)
  UnexpectedEof(span~ : @core.Span)
  IntLiteralOverflow(literal~ : String, span~ : @core.Span)
  IntMinLiteralBoundary(span~ : @core.Span)
  MutableEnumFieldUnsupported(span~ : @core.Span)
} derive(Show, Eq)

///|
fn parse_error_separator_name(expected : String) -> String? {
  let prefix = "; ("
  if not(expected.has_prefix(prefix)) || not(expected.has_suffix(")")) {
    return None
  }
  if expected.length() <= prefix.length() + 1 {
    return None
  }
  Some(
    expected.unsafe_substring(start=prefix.length(), end=expected.length() - 1),
  )
}

///|
fn parse_error_trim_label_suffix(label : String) -> String? {
  let chars = label.to_array()
  if chars.length() <= 1 {
    return None
  }
  let last = chars[chars.length() - 1]
  if last != '~' && last != '?' {
    return None
  }
  let out = StringBuilder::new()
  for i in 0..<(chars.length() - 1) {
    out.write_char(chars[i])
  }
  let base = out.to_string()
  if base.is_empty() {
    None
  } else {
    Some(base)
  }
}

///|
fn parse_error_unexpected_token_hint(
  expected : String,
  got : String,
) -> String? {
  let got_trimmed = got.trim().to_string()
  if got_trimmed == "," {
    match parse_error_separator_name(expected) {
      Some(separator_name) =>
        return Some(
          "replace `,` with `;` for " +
          separator_name +
          " (formatter can apply this rewrite automatically)",
        )
      None => ()
    }
  }
  if expected == "label" {
    match parse_error_trim_label_suffix(got_trimmed) {
      Some(base) =>
        return Some(
          "call-site labels use `" +
          base +
          " = ...`; keep suffix forms (`" +
          got_trimmed +
          "`) for function parameter declarations only",
        )
      None => ()
    }
  }
  None
}

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
        hint: parse_error_unexpected_token_hint(expected, got),
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
        message: "int literal overflow: `" +
        literal +
        "` exceeds tagged Int range (max 2305843009213693951)",
        span: Some(span),
        hint: Some(
          "use a smaller literal or rewrite as `0 - 2305843009213693951 - 1`",
        ),
        note: None,
      }
    ParseError::IntMinLiteralBoundary(span~) =>
      @core.Diagnostic::{
        stage: "parse",
        message: "`-2305843009213693952` is rejected: unary `-` does not extend Int literal range",
        span: Some(span),
        hint: Some("rewrite as `0 - 2305843009213693951 - 1`"),
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
    k if k == declare_kw() => self.parse_declare_stmt()
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
    k if k == import_kw() => self.parse_import_stmt()
    k if k == export_kw() => self.parse_export_stmt()
    k if k == test_kw() => self.parse_test_block()
    k if k == bench_kw() => self.parse_bench_block()
    _ => self.parse_expr_stmt()
  }
}

///|
fn Parser::parse_declare_stmt(self : Parser) -> Unit {
  self.builder.start_node(let_stmt())
  self.bump() // declare
  self.skip_trivia()
  self.expect(export_kw())
  self.skip_trivia()
  self.expect(let_kw())
  self.skip_trivia()
  self.expect(name())
  self.skip_trivia()
  if self.at(double_colon()) {
    self.bump()
    self.skip_trivia()
    self.expect(name())
    self.skip_trivia()
  }
  self.expect(colon())
  self.skip_trivia()
  self.parse_binding_type_until_stmt_end()
  self.skip_trivia()
  if self.at(semicolon()) {
    self.bump()
  }
  self.builder.finish_node()
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
  self.bump() // import | use
  self.skip_trivia()
  // import <source> [as alias] / use <source> { ... } / use <source>
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
  } else if self.at(use_kw()) {
    // export use <module-ref> { items }
    self.parse_import_stmt()
  } else if self.at(lbrace()) {
    // export { name1, name2, Type::method, ... }
    self.bump()
    while not(self.at(rbrace())) && not(self.at(eof())) {
      self.skip_trivia()
      if self.at(name()) {
        self.bump()
        // Handle qualified names like Type::method
        self.skip_trivia()
        if self.at(double_colon()) {
          self.bump()
          self.skip_trivia()
          if self.at(name()) {
            self.bump()
          }
        }
      } else {
        // Skip unknown token to avoid infinite loop
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
  } else if self.at(name()) && self.peek().text() == "for" {
    self.parse_for_in_expr()
  } else if self.at(while_kw()) {
    self.parse_while_expr()
  } else if self.at(loop_kw()) {
    self.parse_loop_expr()
  } else if self.at(name()) &&
    self.peek().text() == "loop" &&
    self.peek_non_trivia_ahead(1) == lparen() &&
    self.peek_non_trivia_ahead(2) == name() &&
    self.peek_non_trivia_ahead(3) == eq() {
    self.parse_loop_expr()
  } else if self.at(match_kw()) {
    self.parse_match_expr()
  } else if self.at(do_kw()) {
    self.parse_do_expr()
  } else if self.at(break_kw()) {
    self.parse_break_expr()
  } else if self.at(continue_kw()) {
    self.parse_continue_expr()
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
fn Parser::parse_for_in_expr(self : Parser) -> Unit {
  // Reuse while_expr node kind since for-in desugars to while
  self.builder.start_node(while_expr())
  self.bump() // for
  self.skip_trivia()
  // Parse binding name(s)
  self.expect(name())
  self.skip_trivia()
  if self.at(comma()) {
    self.bump() // ,
    self.skip_trivia()
    self.expect(name())
    self.skip_trivia()
  }
  self.expect(name()) // contextual keyword "in"
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
  // Check for parameterized loop: loop (name = expr, ...) { body }
  if self.at(lparen()) {
    self.bump() // (
    self.skip_trivia()
    if not(self.at(rparen())) {
      // Parse name = expr
      self.expect(name())
      self.expect(eq())
      self.skip_trivia()
      self.parse_expr()
      while ({
              self.skip_trivia()
              self.at(comma())
            }) {
        self.bump() // ,
        self.skip_trivia()
        if self.at(rparen()) {
          break
        }
        self.expect(name())
        self.expect(eq())
        self.skip_trivia()
        self.parse_expr()
      }
    }
    self.expect(rparen())
    self.skip_trivia()
  }
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
fn Parser::parse_break_expr(self : Parser) -> Unit {
  self.builder.start_node(break_expr())
  self.bump() // break
  self.skip_trivia()
  // Parse optional break value (not } or ; or EOF)
  if not(self.at(rbrace())) && not(self.at(semicolon())) && not(self.at(eof())) {
    self.parse_expr()
  }
  self.builder.finish_node()
}

///|
fn Parser::parse_continue_expr(self : Parser) -> Unit {
  self.builder.start_node(continue_expr())
  self.bump() // continue
  self.skip_trivia()
  // Parse optional continue arguments: continue(expr, expr, ...)
  if self.at(lparen()) {
    self.bump() // (
    self.skip_trivia()
    if not(self.at(rparen())) {
      self.parse_expr()
      while ({
              self.skip_trivia()
              self.at(comma())
            }) {
        self.bump() // ,
        self.skip_trivia()
        if self.at(rparen()) {
          break
        }
        self.parse_expr()
      }
    }
    self.expect(rparen())
  }
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
fn Parser::parse_binding_type_until_stmt_end(self : Parser) -> Unit {
  let mut paren_depth = 0
  let mut bracket_depth = 0
  let mut brace_depth = 0
  while not(self.at(eof())) {
    let kind = self.peek_kind()
    if paren_depth == 0 &&
      bracket_depth == 0 &&
      brace_depth == 0 &&
      (kind == semicolon() || kind == newline()) {
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
      k if k == rbrace() =>
        if brace_depth > 0 {
          brace_depth -= 1
          self.bump()
        } else {
          break
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
