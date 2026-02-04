///|
/// Parser for xsh (CST + AST)
suberror ParseError {
  UnexpectedToken(expected~ : String, got~ : String)
  UnexpectedEof
  InvalidHashSuffix(String)
} derive(Show, Eq)

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
  } else if self.at(match_kw()) {
    self.parse_match_expr()
  } else if self.at(do_kw()) {
    self.parse_do_expr()
  } else if self.at(record_kw()) {
    self.parse_record_expr()
  } else if self.at(map_kw()) {
    self.parse_map_expr()
  } else if self.at(fn_kw()) {
    self.parse_fn_expr()
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
  self.parse_cmp_expr()
  while {
          self.skip_trivia()
          self.at(and_and())
        } {
    self.bump()
    self.parse_cmp_expr()
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
fn Parser::parse_fn_expr(self : Parser) -> Unit {
  self.builder.start_node(fn_expr())
  self.bump() // fn
  self.skip_trivia()
  self.parse_paren_tokens()
  self.skip_trivia()
  if self.at(thin_arrow()) {
    self.bump()
    self.skip_trivia()
    self.parse_type_tokens()
  }
  self.skip_trivia()
  self.parse_brace_block_tokens()
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
fn Parser::parse_paren_tokens(self : Parser) -> Unit {
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
  Module::{ stmts, }
}

///|
fn AstParser::parse_stmt(self : AstParser) -> Stmt raise ParseError {
  self.skip_trivia()
  match self.peek_kind() {
    k if k == let_kw() => self.parse_let_stmt()
    k if k == enum_kw() => self.parse_enum_stmt()
    k if k == type_kw() => self.parse_type_alias_stmt()
    k if k == alias_kw() => self.parse_alias_stmt()
    k if k == import_kw() => self.parse_import_stmt()
    k if k == test_kw() => self.parse_test_stmt()
    k if k == flake_kw() => self.parse_flake_stmt()
    _ => {
      let expr = self.parse_expr()
      let _ = self.eat(semicolon())
      Stmt::Expr(expr~)
    }
  }
}

///|
fn AstParser::parse_let_stmt(self : AstParser) -> Stmt raise ParseError {
  let _ = self.expect(let_kw(), "let")
  self.skip_trivia()
  let mut rec_flag = false
  if self.peek_kind() == rec_kw() {
    let _ = self.bump()
    rec_flag = true
  }
  let name_tok = self.expect(name(), "name")
  let _ = self.expect(eq(), "=")
  let expr = self.parse_expr()
  let _ = self.eat(semicolon())
  Stmt::Let(rec=rec_flag, name=name_tok.text(), expr~)
}

///|
fn AstParser::parse_enum_stmt(self : AstParser) -> Stmt raise ParseError {
  let _ = self.expect(enum_kw(), "enum")
  self.skip_trivia()
  let name_tok = self.expect(name(), "enum name")
  let params = self.parse_type_params()
  let param_set = param_set_from_params(params)
  self.skip_trivia()
  let _ = self.expect(lbrace(), "{")
  let ctors : Array[TypeCtor] = []
  while {
          self.skip_trivia()
          self.peek_kind() != rbrace()
        } {
    if self.peek_kind() == eof() {
      raise ParseError::UnexpectedEof
    }
    ctors.push(self.parse_type_ctor(param_set))
    let _ = self.eat(comma())
    let _ = self.eat(semicolon())

  }
  let _ = self.expect(rbrace(), "}")
  let _ = self.eat(semicolon())
  Stmt::EnumDef(name=name_tok.text(), params~, ctors~)
}

///|
fn AstParser::parse_type_alias_stmt(self : AstParser) -> Stmt raise ParseError {
  let _ = self.expect(type_kw(), "type")
  self.skip_trivia()
  let name_tok = self.expect(name(), "type name")
  let params = self.parse_type_params()
  let param_set = param_set_from_params(params)
  let _ = self.expect(eq(), "=")
  let target = self.parse_type_with_params(param_set)
  let _ = self.eat(semicolon())
  Stmt::TypeAlias(name=name_tok.text(), params~, target~)
}

///|
fn AstParser::parse_type_ctor(
  self : AstParser,
  params : Map[String, Bool],
) -> TypeCtor raise ParseError {
  let name_tok = self.expect(name(), "ctor")
  if not(is_ctor_name(name_tok.text())) {
    raise ParseError::UnexpectedToken(expected="ctor", got=name_tok.text())
  }
  let args : Array[Type] = []
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
  TypeCtor::{ name: name_tok.text(), args }
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
  Stmt::Test(name~, body~)
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
  Module::{ stmts, }
}

///|

///|
fn split_hash_optional(name : String) -> Ref? raise ParseError {
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
  Some(Ref::{ name: left.to_string(), hash_prefix: Some(right.to_string()) })
}

///|
fn AstParser::parse_alias_stmt(self : AstParser) -> Stmt raise ParseError {
  let _ = self.expect(alias_kw(), "alias")
  let name_tok = self.expect(name(), "name")
  let _ = self.expect(eq(), "=")
  let target_tok = self.expect(name(), "name#hash")
  let _ = self.eat(semicolon())
  let target = match split_hash_optional(target_tok.text()) {
    Some(r) => {
      if r.name.is_empty() || r.hash_prefix is None {
        raise ParseError::InvalidHashSuffix(target_tok.text())
      }
      AliasTarget::Module(r)
    }
    None => AliasTarget::Name(target_tok.text())
  }
  let name_ref = split_hash_optional(name_tok.text())
  match name_ref {
    Some(_) => raise ParseError::InvalidHashSuffix(name_tok.text())
    None => ()
  }
  Stmt::Alias(name=name_tok.text(), target~)
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
  } else if self.peek_kind() == map_kw() {
    self.parse_map_expr()
  } else if self.peek_kind() == fn_kw() {
    self.parse_fn_expr()
  } else if self.peek_kind() == lparen() {
    self.parse_paren_expr()
  } else if self.peek_kind() == lbracket() {
    self.parse_array_expr()
  } else if self.peek_kind() == lbrace() {
    Expr::Block(body=self.parse_block())
  } else {
    self.parse_or_expr()
  }
}

///|
fn AstParser::parse_or_expr(self : AstParser) -> Expr raise ParseError {
  let mut left = self.parse_and_expr()
  while {
          self.skip_trivia()
          self.peek_kind() == or_or()
        } {
    let _ = self.bump()
    let right = self.parse_and_expr()
    left = Expr::If(
      cond=left,
      then_body=Module::{ stmts: [Stmt::Expr(expr=Expr::Bool(true))] },
      else_body=Module::{ stmts: [Stmt::Expr(expr=right)] },
    )
  }
  left
}

///|
fn AstParser::parse_and_expr(self : AstParser) -> Expr raise ParseError {
  let mut left = self.parse_cmp_expr()
  while {
          self.skip_trivia()
          self.peek_kind() == and_and()
        } {
    let _ = self.bump()
    let right = self.parse_cmp_expr()
    left = Expr::If(
      cond=left,
      then_body=Module::{ stmts: [Stmt::Expr(expr=right)] },
      else_body=Module::{ stmts: [Stmt::Expr(expr=Expr::Bool(false))] },
    )
  }
  left
}

///|
fn AstParser::parse_cmp_expr(self : AstParser) -> Expr raise ParseError {
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
fn cmp_expr_from_op(op : @cst.SyntaxKind, left : Expr, right : Expr) -> Expr {
  match op {
    k if k == eqeq() => call2("eq", left, right)
    k if k == neq() => call1("not", call2("eq", left, right))
    k if k == lt() => call2("lt", left, right)
    k if k == gt() => call2("lt", right, left)
    k if k == lte() =>
      call2("or", call2("lt", left, right), call2("eq", left, right))
    _ => call2("or", call2("lt", right, left), call2("eq", left, right))
  }
}

///|
fn call1(name : String, value : Expr) -> Expr {
  Expr::Call(name~, args=[CallArg::{ label: None, expr: value }])
}

///|
fn call2(name : String, left : Expr, right : Expr) -> Expr {
  Expr::Call(name~, args=[
    CallArg::{ label: None, expr: left },
    CallArg::{ label: None, expr: right },
  ])
}

///|
fn AstParser::parse_add_expr(self : AstParser) -> Expr raise ParseError {
  let mut left = self.parse_mul_expr()
  while {
          self.skip_trivia()
          self.peek_kind() == plus() || self.peek_kind() == minus()
        } {
    let op = self.peek_kind()
    let _ = self.bump()
    let right = self.parse_mul_expr()
    let name = if op == plus() { "add" } else { "sub" }
    left = call2(name, left, right)
  }
  left
}

///|
fn AstParser::parse_mul_expr(self : AstParser) -> Expr raise ParseError {
  let mut left = self.parse_unary_expr()
  while {
          self.skip_trivia()
          self.peek_kind() == star() || self.peek_kind() == slash()
        } {
    let op = self.peek_kind()
    let _ = self.bump()
    let right = self.parse_unary_expr()
    let name = if op == star() { "mul" } else { "div" }
    left = call2(name, left, right)
  }
  left
}

///|
fn AstParser::parse_unary_expr(self : AstParser) -> Expr raise ParseError {
  self.skip_trivia()
  match self.peek_kind() {
    k if k == minus() => {
      let _ = self.bump()
      let value = self.parse_unary_expr()
      call2("sub", Expr::Int(0), value)
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
fn AstParser::parse_if_expr(self : AstParser) -> Expr raise ParseError {
  let _ = self.expect(if_kw(), "if")
  let cond = self.parse_expr()
  let then_body = self.parse_block()
  let _ = self.expect(else_kw(), "else")
  let else_body = if self.peek_kind() == lbrace() {
    self.parse_block()
  } else {
    let expr = self.parse_expr()
    Module::{ stmts: [Stmt::Expr(expr~)] }
  }
  Expr::If(cond~, then_body~, else_body~)
}

///|
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
  Expr::Match(scrutinee~, arms~)
}

///|
fn AstParser::parse_do_expr(self : AstParser) -> Expr raise ParseError {
  let _ = self.expect(do_kw(), "do")
  let body = self.parse_block()
  Expr::Do(body~)
}

///|
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

///|
fn AstParser::parse_map_expr(self : AstParser) -> Expr raise ParseError {
  let _ = self.expect(map_kw(), "map")
  let _ = self.expect(lbrace(), "{")
  let fields : Array[MapFieldExpr] = []
  while {
          self.skip_trivia()
          self.peek_kind() != rbrace()
        } {
    if self.peek_kind() == eof() {
      raise ParseError::UnexpectedEof
    }
    let key_tok = self.peek()
    if key_tok.kind() != name() && key_tok.kind() != string_lit() {
      raise ParseError::UnexpectedToken(expected="map key", got=key_tok.text())
    }
    let _ = self.bump()
    let _ = self.expect(colon(), ":")
    let expr = self.parse_expr()
    fields.push(MapFieldExpr::{ key: key_tok.text(), expr })
    let _ = self.eat(comma())
    let _ = self.eat(semicolon())

  }
  let _ = self.expect(rbrace(), "}")
  Expr::Map(fields)
}

///|
fn AstParser::parse_array_expr(self : AstParser) -> Expr raise ParseError {
  let _ = self.expect(lbracket(), "[")
  let items : Array[Expr] = []
  while {
          self.skip_trivia()
          self.peek_kind() != rbracket()
        } {
    if self.peek_kind() == eof() {
      raise ParseError::UnexpectedEof
    }
    items.push(self.parse_expr())
    let _ = self.eat(comma())
    let _ = self.eat(semicolon())

  }
  let _ = self.expect(rbracket(), "]")
  Expr::Array(items)
}

///|
fn AstParser::parse_fn_expr(self : AstParser) -> Expr raise ParseError {
  let _ = self.expect(fn_kw(), "fn")
  let params = self.parse_param_list()
  self.skip_trivia()
  let mut ret : Type? = None
  if self.peek_kind() == thin_arrow() {
    let _ = self.bump()
    ret = Some(self.parse_type())
  }
  let body = self.parse_block()
  Expr::Fn(params~, ret~, body~)
}

///|
fn AstParser::parse_param_list(
  self : AstParser,
) -> Array[FuncParam] raise ParseError {
  let _ = self.expect(lparen(), "(")
  let params : Array[FuncParam] = []
  self.skip_trivia()
  if self.peek_kind() != rparen() {
    params.push(self.parse_param())
    while {
            self.skip_trivia()
            self.peek_kind() == comma()
          } {
      let _ = self.bump()
      self.skip_trivia()
      if self.peek_kind() == rparen() {
        break
      }
      params.push(self.parse_param())
    }
  }
  let _ = self.expect(rparen(), ")")
  params
}

///|
fn AstParser::parse_param(self : AstParser) -> FuncParam raise ParseError {
  let name_tok = self.expect(name(), "param")
  let (base, label) = split_param_label(name_tok.text())
  self.skip_trivia()
  let _ = self.expect(colon(), ":")
  let ty = self.parse_type_with_params({})
  FuncParam::{ name: base, label, ty }
}

///|
fn split_param_label(name : String) -> (String, ParamLabel) raise ParseError {
  let chars : Array[Char] = []
  for c in name {
    chars.push(c)
  }
  if chars.is_empty() {
    raise ParseError::UnexpectedToken(expected="param", got=name)
  }
  let last = chars[chars.length() - 1]
  if last == '~' || last == '?' {
    if chars.length() == 1 {
      raise ParseError::UnexpectedToken(expected="param", got=name)
    }
    let buf = StringBuilder::new()
    for i in 0..<(chars.length() - 1) {
      buf.write_char(chars[i])
    }
    let label = if last == '~' {
      ParamLabel::Required
    } else {
      ParamLabel::Optional
    }
    (buf.to_string(), label)
  } else {
    (name, ParamLabel::Positional)
  }
}

///|
fn AstParser::parse_type(self : AstParser) -> Type raise ParseError {
  self.parse_type_with_params({})
}

///|
fn AstParser::parse_type_with_params(
  self : AstParser,
  params : Map[String, Bool],
) -> Type raise ParseError {
  self.skip_trivia()
  let tok = self.peek()
  match tok.kind() {
    k if k == name() => {
      let _ = self.bump()
      let name = tok.text()
      let args = self.parse_type_args(params)
      match name {
        "Int" =>
          if args.is_empty() {
            Type::Int
          } else {
            raise ParseError::UnexpectedToken(expected="type", got=name)
          }
        "Bool" =>
          if args.is_empty() {
            Type::Bool
          } else {
            raise ParseError::UnexpectedToken(expected="type", got=name)
          }
        "String" =>
          if args.is_empty() {
            Type::String
          } else {
            raise ParseError::UnexpectedToken(expected="type", got=name)
          }
        "Path" =>
          if args.is_empty() {
            Type::Path
          } else {
            raise ParseError::UnexpectedToken(expected="type", got=name)
          }
        "Unit" =>
          if args.is_empty() {
            Type::Unit
          } else {
            raise ParseError::UnexpectedToken(expected="type", got=name)
          }
        "Array" =>
          if args.length() == 1 {
            Type::Array(args[0])
          } else {
            raise ParseError::UnexpectedToken(expected="Array[T]", got=name)
          }
        "Map" =>
          if args.length() == 1 {
            Type::Map(args[0])
          } else {
            raise ParseError::UnexpectedToken(expected="Map[T]", got=name)
          }
        "ArrayBuilder" =>
          if args.length() == 1 {
            Type::ArrayBuilder(args[0])
          } else {
            raise ParseError::UnexpectedToken(
              expected="ArrayBuilder[T]",
              got=name,
            )
          }
        "MapBuilder" =>
          if args.length() == 1 {
            Type::MapBuilder(args[0])
          } else {
            raise ParseError::UnexpectedToken(
              expected="MapBuilder[T]",
              got=name,
            )
          }
        _ =>
          if params.contains(name) {
            if not(args.is_empty()) {
              raise ParseError::UnexpectedToken(expected="type param", got=name)
            }
            Type::Param(name)
          } else {
            Type::Named(name~, args~)
          }
      }
    }
    k if k == lparen() => self.parse_tuple_type(params)
    _ => raise ParseError::UnexpectedToken(expected="type", got=tok.text())
  }
}

///|
fn AstParser::parse_tuple_type(
  self : AstParser,
  params : Map[String, Bool],
) -> Type raise ParseError {
  let _ = self.expect(lparen(), "(")
  let first = self.parse_type_with_params(params)
  self.skip_trivia()
  if self.peek_kind() == comma() {
    let items : Array[Type] = []
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
    Type::Tuple(items)
  } else {
    let _ = self.expect(rparen(), ")")
    first
  }
}

///|
fn AstParser::parse_type_args(
  self : AstParser,
  params : Map[String, Bool],
) -> Array[Type] raise ParseError {
  let args : Array[Type] = []
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

///|
fn AstParser::parse_pattern(self : AstParser) -> Pat raise ParseError {
  self.skip_trivia()
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
        Ok(v) => Pat::Int(v)
        Err(_) =>
          raise ParseError::UnexpectedToken(expected="int", got=tok.text())
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
      } else if is_ctor_name(tok.text()) {
        let args : Array[Pat] = []
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
        Pat::Ctor(name=tok.text(), args~)
      } else {
        Pat::Bind(tok.text())
      }
    }
    _ => raise ParseError::UnexpectedToken(expected="pattern", got=tok.text())
  }
}

///|
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

///|
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
      Expr::Call(name=name_tok.text(), args~)
    } else {
      Expr::Ident(name_tok.text())
    }
  } else {
    self.parse_primary()
  }
}

///|
fn AstParser::parse_args(self : AstParser) -> Array[CallArg] raise ParseError {
  let args : Array[CallArg] = []
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
fn AstParser::parse_arg(self : AstParser) -> CallArg raise ParseError {
  self.skip_trivia()
  if self.peek_kind() == name() &&
    self.peek_non_trivia_kind(self.pos + 1) == eq() {
    let label_tok = self.expect(name(), "label")
    if label_tok.text().has_suffix("?") || label_tok.text().has_suffix("~") {
      raise ParseError::UnexpectedToken(expected="label", got=label_tok.text())
    }
    let _ = self.expect(eq(), "=")
    let expr = self.parse_expr()
    CallArg::{ label: Some(label_tok.text()), expr }
  } else {
    let expr = self.parse_expr()
    CallArg::{ label: None, expr }
  }
}

///|
fn AstParser::parse_primary(self : AstParser) -> Expr raise ParseError {
  self.skip_trivia()
  let tok = self.peek()
  match tok.kind() {
    k if k == int_lit() => {
      let _ = self.bump()
      let parsed : Result[Int, @strconv.StrConvError] = try? @strconv.parse_int(
        tok.text(),
      )
      match parsed {
        Ok(v) => Expr::Int(v)
        Err(_) =>
          raise ParseError::UnexpectedToken(expected="int", got=tok.text())
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

///|
/// Parse input into AST
pub fn parse_ast(input : String) -> Module raise ParseError {
  let tokens = tokenize(input)
  let parser = AstParser::new(tokens)
  parser.parse()
}
