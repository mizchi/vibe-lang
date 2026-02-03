///| Parser for xsh (CST + AST)

suberror ParseError {
  UnexpectedToken(expected~ : String, got~ : String)
  UnexpectedEof
  InvalidHashSuffix(String)
} derive(Show, Eq)

///| CST parser state
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
fn Parser::parse_flake_block(self : Parser) -> Unit {
  self.builder.start_node(flake_block())
  self.bump() // flake
  self.skip_trivia()
  self.expect(lbrace())
  let mut depth = 1
  while depth > 0 && not(self.at(eof())) {
    match self.peek_kind() {
      k if k == lbrace() => { self.bump(); depth += 1 }
      k if k == rbrace() => { self.bump(); depth -= 1 }
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
      k if k == lbrace() => { self.bump(); depth += 1 }
      k if k == rbrace() => { self.bump(); depth -= 1 }
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
  } else if self.at(match_kw()) {
    self.parse_match_expr()
  } else if self.at(do_kw()) {
    self.parse_do_expr()
  } else if self.at(record_kw()) {
    self.parse_record_expr()
  } else if self.at(lparen()) {
    self.parse_paren_expr()
  } else if self.at(lbrace()) {
    self.parse_block_expr()
  } else {
    self.parse_call_or_primary()
  }
}

fn Parser::parse_do_expr(self : Parser) -> Unit {
  self.builder.start_node(do_expr())
  self.bump() // do
  self.skip_trivia()
  self.parse_brace_block_tokens()
  self.builder.finish_node()
}

fn Parser::parse_block_expr(self : Parser) -> Unit {
  self.builder.start_node(block_expr())
  self.parse_brace_block_tokens()
  self.builder.finish_node()
}

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
    self.parse_brace_block_tokens()
  } else {
    self.builder.token(error_kind(), "")
  }
  self.builder.finish_node()
}

fn Parser::parse_match_expr(self : Parser) -> Unit {
  self.builder.start_node(match_expr())
  self.bump() // match
  self.skip_trivia()
  self.parse_expr()
  self.skip_trivia()
  self.parse_brace_block_tokens()
  self.builder.finish_node()
}

fn Parser::parse_record_expr(self : Parser) -> Unit {
  self.builder.start_node(record_expr())
  self.bump() // record
  self.skip_trivia()
  self.parse_brace_block_tokens()
  self.builder.finish_node()
}

fn Parser::parse_paren_expr(self : Parser) -> Unit {
  self.builder.start_node(paren_expr())
  self.expect(lparen())
  let mut depth = 1
  while depth > 0 && not(self.at(eof())) {
    match self.peek_kind() {
      k if k == lparen() => { self.bump(); depth += 1 }
      k if k == rparen() => { self.bump(); depth -= 1 }
      _ => self.bump()
    }
  }
  self.builder.finish_node()
}

fn Parser::parse_brace_block_tokens(self : Parser) -> Unit {
  self.expect(lbrace())
  let mut depth = 1
  while depth > 0 && not(self.at(eof())) {
    match self.peek_kind() {
      k if k == lbrace() => { self.bump(); depth += 1 }
      k if k == rbrace() => { self.bump(); depth -= 1 }
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
    self.parse_expr()
    while {
      self.skip_trivia()
      self.at(comma())
    } {
      self.bump()
      self.skip_trivia()
      self.parse_expr()
    }
  }
  self.builder.finish_node()
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
    k if k == int_lit() || k == string_lit() || k == bool_lit() => {
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

///| Parse input into CST (red tree root)
pub fn parse_cst(input : String) -> @cst.SyntaxNode {
  let tokens = tokenize(input)
  let parser = Parser::new(tokens)
  let green = parser.parse()
  @cst.SyntaxNode::new_root(green)
}

///| AST parser state
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
fn AstParser::expect(self : AstParser, kind : @cst.SyntaxKind, label : String) -> Token raise ParseError {
  self.skip_trivia()
  let tok = self.peek()
  if tok.kind() == kind {
    self.pos += 1
    tok
  } else if tok.kind() == eof() {
    raise ParseError::UnexpectedEof
  } else {
    raise ParseError::UnexpectedToken(expected=label, got=tok.text())
  }
}

///|
pub fn AstParser::parse(self : AstParser) -> Module raise ParseError {
  let stmts : Array[Stmt] = []
  while {
    self.skip_trivia()
    self.peek_kind() != eof()
  } {
    stmts.push(self.parse_stmt())
  }
  Module::{ stmts }
}

///|
fn AstParser::parse_stmt(self : AstParser) -> Stmt raise ParseError {
  self.skip_trivia()
  match self.peek_kind() {
    k if k == let_kw() => self.parse_let_stmt()
    k if k == alias_kw() => self.parse_alias_stmt()
    k if k == import_kw() => self.parse_import_stmt()
    k if k == test_kw() => self.parse_test_stmt()
    k if k == flake_kw() => self.parse_flake_stmt()
    _ => {
      let expr = self.parse_expr()
      let _ = self.eat(semicolon())
      Stmt::Expr(expr=expr)
    }
  }
}

///|
fn AstParser::parse_let_stmt(self : AstParser) -> Stmt raise ParseError {
  let _ = self.expect(let_kw(), "let")
  let name_tok = self.expect(name(), "name")
  let _ = self.expect(eq(), "=")
  let expr = self.parse_expr()
  let _ = self.eat(semicolon())
  Stmt::Let(name=name_tok.text(), expr=expr)
}

///|
fn AstParser::parse_flake_stmt(self : AstParser) -> Stmt raise ParseError {
  let _ = self.expect(flake_kw(), "flake")
  let _ = self.expect(lbrace(), "{")
  let buf = StringBuilder::new()
  let mut depth = 1
  while depth > 0 {
    let tok = self.peek()
    if tok.kind() == eof() {
      raise ParseError::UnexpectedEof
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
  Stmt::Flake(raw=buf.to_string())
}

///|
fn AstParser::parse_test_stmt(self : AstParser) -> Stmt raise ParseError {
  let _ = self.expect(test_kw(), "test")
  self.skip_trivia()
  let mut name : String? = None
  if self.peek_kind() == string_lit() {
    let name_tok = self.bump()
    name = Some(name_tok.text())
    self.skip_trivia()
  }
  let body = self.parse_block()
  Stmt::Test(name=name, body=body)
}

///|
fn AstParser::parse_block(self : AstParser) -> Module raise ParseError {
  let _ = self.expect(lbrace(), "{")
  let stmts : Array[Stmt] = []
  while {
    self.skip_trivia()
    self.peek_kind() != rbrace()
  } {
    if self.peek_kind() == eof() {
      raise ParseError::UnexpectedEof
    }
    stmts.push(self.parse_stmt())
  }
  let _ = self.expect(rbrace(), "}")
  Module::{ stmts }
}

///|
fn split_hash(name : String) -> Ref raise ParseError {
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
    return Ref::{ name, hash_prefix: None }
  }
  if hash_count > 1 || hash_pos <= 0 || hash_pos >= chars.length() - 1 {
    raise ParseError::InvalidHashSuffix(name)
  }
  let left = StringBuilder::new()
  for i in 0..<hash_pos {
    left.write_char(chars[i])
  }
  let right = StringBuilder::new()
  for i in (hash_pos + 1)..<chars.length() {
    right.write_char(chars[i])
  }
  Ref::{ name: left.to_string(), hash_prefix: Some(right.to_string()) }
}

///|
fn AstParser::parse_alias_stmt(self : AstParser) -> Stmt raise ParseError {
  let _ = self.expect(alias_kw(), "alias")
  let name_tok = self.expect(name(), "name")
  let _ = self.expect(eq(), "=")
  let target_tok = self.expect(name(), "name#hash")
  let _ = self.eat(semicolon())
  let target = split_hash(target_tok.text())
  if target.name.is_empty() || target.hash_prefix is None {
    raise ParseError::InvalidHashSuffix(target_tok.text())
  }
  let name_ref = split_hash(name_tok.text())
  if name_ref.hash_prefix is Some(_) {
    raise ParseError::InvalidHashSuffix(name_tok.text())
  }
  Stmt::Alias(name=name_tok.text(), target=target)
}

///|
fn AstParser::parse_import_stmt(self : AstParser) -> Stmt raise ParseError {
  let _ = self.expect(import_kw(), "import")
  self.skip_trivia()
  let tok = self.peek()
  if tok.kind() != name() && tok.kind() != string_lit() {
    raise ParseError::UnexpectedToken(expected="path", got=tok.text())
  }
  let _ = self.bump()
  let _ = self.eat(semicolon())
  Stmt::Import(path=tok.text())
}

///|
fn AstParser::parse_expr(self : AstParser) -> Expr raise ParseError {
  self.skip_trivia()
  if self.peek_kind() == if_kw() {
    self.parse_if_expr()
  } else if self.peek_kind() == match_kw() {
    self.parse_match_expr()
  } else if self.peek_kind() == do_kw() {
    self.parse_do_expr()
  } else if self.peek_kind() == record_kw() {
    self.parse_record_expr()
  } else if self.peek_kind() == lparen() {
    self.parse_paren_expr()
  } else if self.peek_kind() == lbrace() {
    Expr::Block(body=self.parse_block())
  } else {
    self.parse_call_or_primary()
  }
}

fn AstParser::parse_if_expr(self : AstParser) -> Expr raise ParseError {
  let _ = self.expect(if_kw(), "if")
  let cond = self.parse_expr()
  let then_body = self.parse_block()
  let _ = self.expect(else_kw(), "else")
  let else_body = self.parse_block()
  Expr::If(cond=cond, then_body=then_body, else_body=else_body)
}

fn AstParser::parse_match_expr(self : AstParser) -> Expr raise ParseError {
  let _ = self.expect(match_kw(), "match")
  let scrutinee = self.parse_expr()
  let _ = self.expect(lbrace(), "{")
  let arms : Array[MatchArm] = []
  while {
    self.skip_trivia()
    self.peek_kind() != rbrace()
  } {
    if self.peek_kind() == eof() {
      raise ParseError::UnexpectedEof
    }
    let pat = self.parse_pattern()
    self.skip_trivia()
    let mut cond : Expr? = None
    if self.peek_kind() == if_kw() {
      let _ = self.bump()
      cond = Some(self.parse_expr())
    }
    let _ = self.expect(arrow(), "=>")
    let expr = self.parse_expr()
    arms.push(MatchArm::{ pat, cond, expr })
    let _ = self.eat(comma())
    let _ = self.eat(semicolon())
  }
  let _ = self.expect(rbrace(), "}")
  Expr::Match(scrutinee=scrutinee, arms=arms)
}

fn AstParser::parse_do_expr(self : AstParser) -> Expr raise ParseError {
  let _ = self.expect(do_kw(), "do")
  let body = self.parse_block()
  Expr::Do(body=body)
}

fn AstParser::parse_record_expr(self : AstParser) -> Expr raise ParseError {
  let _ = self.expect(record_kw(), "record")
  let _ = self.expect(lbrace(), "{")
  let fields : Array[RecordFieldExpr] = []
  while {
    self.skip_trivia()
    self.peek_kind() != rbrace()
  } {
    if self.peek_kind() == eof() {
      raise ParseError::UnexpectedEof
    }
    let name_tok = self.expect(name(), "field")
    let _ = self.expect(colon(), ":")
    let expr = self.parse_expr()
    fields.push(RecordFieldExpr::{ name: name_tok.text(), expr })
    let _ = self.eat(comma())
    let _ = self.eat(semicolon())
  }
  let _ = self.expect(rbrace(), "}")
  Expr::Record(fields)
}

fn AstParser::parse_paren_expr(self : AstParser) -> Expr raise ParseError {
  let _ = self.expect(lparen(), "(")
  let first = self.parse_expr()
  self.skip_trivia()
  if self.peek_kind() == comma() {
    let items : Array[Expr] = []
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
    Expr::Tuple(items)
  } else {
    let _ = self.expect(rparen(), ")")
    first
  }
}

fn AstParser::parse_pattern(self : AstParser) -> Pat raise ParseError {
  self.skip_trivia()
  let tok = self.peek()
  match tok.kind() {
    k if k == lparen() => self.parse_tuple_pattern()
    k if k == record_kw() => self.parse_record_pattern()
    k if k == int_lit() => {
      let _ = self.bump()
      let parsed : Result[Int, @strconv.StrConvError] = try? @strconv.parse_int(tok.text())
      match parsed {
        Ok(v) => Pat::Int(v)
        Err(_) => raise ParseError::UnexpectedToken(expected="int", got=tok.text())
      }
    }
    k if k == bool_lit() => {
      let _ = self.bump()
      if tok.text() == "true" {
        Pat::Bool(true)
      } else if tok.text() == "false" {
        Pat::Bool(false)
      } else {
        raise ParseError::UnexpectedToken(expected="bool", got=tok.text())
      }
    }
    k if k == string_lit() => {
      let _ = self.bump()
      Pat::String(tok.text())
    }
    k if k == name() => {
      let _ = self.bump()
      if tok.text() == "_" {
        Pat::Wildcard
      } else {
        Pat::Bind(tok.text())
      }
    }
    _ => raise ParseError::UnexpectedToken(expected="pattern", got=tok.text())
  }
}

fn AstParser::parse_tuple_pattern(self : AstParser) -> Pat raise ParseError {
  let _ = self.expect(lparen(), "(")
  let first = self.parse_pattern()
  self.skip_trivia()
  if self.peek_kind() == comma() {
    let items : Array[Pat] = []
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
    Pat::Tuple(items)
  } else {
    let _ = self.expect(rparen(), ")")
    first
  }
}

fn AstParser::parse_record_pattern(self : AstParser) -> Pat raise ParseError {
  let _ = self.expect(record_kw(), "record")
  let _ = self.expect(lbrace(), "{")
  let fields : Array[RecordFieldPat] = []
  while {
    self.skip_trivia()
    self.peek_kind() != rbrace()
  } {
    if self.peek_kind() == eof() {
      raise ParseError::UnexpectedEof
    }
    let name_tok = self.expect(name(), "field")
    let _ = self.expect(colon(), ":")
    let pat = self.parse_pattern()
    fields.push(RecordFieldPat::{ name: name_tok.text(), pat })
    let _ = self.eat(comma())
    let _ = self.eat(semicolon())
  }
  let _ = self.expect(rbrace(), "}")
  Pat::Record(fields)
}

///|
fn AstParser::parse_call_or_primary(self : AstParser) -> Expr raise ParseError {
  self.skip_trivia()
  let tok = self.peek()
  if tok.kind() == name() {
    let name_tok = self.bump()
    self.skip_trivia()
    if self.peek_kind() == lparen() {
      let _ = self.bump()
      let args = self.parse_args()
      let _ = self.expect(rparen(), ")")
      Expr::Call(name=name_tok.text(), args=args)
    } else {
      Expr::Ident(name_tok.text())
    }
  } else {
    self.parse_primary()
  }
}

///|
fn AstParser::parse_args(self : AstParser) -> Array[Expr] raise ParseError {
  let args : Array[Expr] = []
  self.skip_trivia()
  if self.peek_kind() != rparen() {
    args.push(self.parse_expr())
    while {
      self.skip_trivia()
      self.peek_kind() == comma()
    } {
      let _ = self.bump()
      args.push(self.parse_expr())
    }
  }
  args
}

///|
fn AstParser::parse_primary(self : AstParser) -> Expr raise ParseError {
  self.skip_trivia()
  let tok = self.peek()
  match tok.kind() {
    k if k == int_lit() => {
      let _ = self.bump()
      let parsed : Result[Int, @strconv.StrConvError] = try? @strconv.parse_int(tok.text())
      match parsed {
        Ok(v) => Expr::Int(v)
        Err(_) => raise ParseError::UnexpectedToken(expected="int", got=tok.text())
      }
    }
    k if k == bool_lit() => {
      let _ = self.bump()
      if tok.text() == "true" {
        Expr::Bool(true)
      } else if tok.text() == "false" {
        Expr::Bool(false)
      } else {
        raise ParseError::UnexpectedToken(expected="bool", got=tok.text())
      }
    }
    k if k == string_lit() => {
      let _ = self.bump()
      Expr::String(tok.text())
    }
    k if k == name() => {
      let _ = self.bump()
      Expr::Ident(tok.text())
    }
    _ => raise ParseError::UnexpectedToken(expected="expr", got=tok.text())
  }
}

///| Parse input into AST
pub fn parse_ast(input : String) -> Module raise ParseError {
  let tokens = tokenize(input)
  let parser = AstParser::new(tokens)
  parser.parse()
}
