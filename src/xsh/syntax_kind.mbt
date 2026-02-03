///| SyntaxKind constants for xsh

// Token kinds (0-99)
///|
pub fn eof() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(0)
}

///|
pub fn error_kind() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(1)
}

///|
pub fn whitespace() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(2)
}

///|
pub fn newline() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(3)
}

///|
pub fn name() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(10)
}

///|
pub fn int_lit() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(11)
}

///|
pub fn string_lit() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(12)
}

///|
pub fn bool_lit() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(13)
}

///|
pub fn let_kw() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(20)
}

///|
pub fn flake_kw() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(21)
}

///|
pub fn alias_kw() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(22)
}

///|
pub fn import_kw() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(23)
}

///|
pub fn test_kw() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(24)
}

///|
pub fn if_kw() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(25)
}

///|
pub fn else_kw() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(26)
}

///|
pub fn match_kw() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(27)
}

///|
pub fn do_kw() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(28)
}

///|
pub fn record_kw() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(29)
}

///|
pub fn eq() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(30)
}

///|
pub fn semicolon() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(31)
}

///|
pub fn arrow() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(32)
}

///|
pub fn colon() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(33)
}

///|
pub fn lbrace() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(40)
}

///|
pub fn rbrace() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(41)
}

///|
pub fn lparen() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(42)
}

///|
pub fn rparen() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(43)
}

///|
pub fn comma() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(44)
}

// Node kinds (100+)
///|
pub fn source_file() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(100)
}

///|
pub fn let_stmt() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(101)
}

///|
pub fn expr_stmt() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(102)
}

///|
pub fn flake_block() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(103)
}

///|
pub fn alias_stmt() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(104)
}

///|
pub fn import_stmt() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(105)
}

///|
pub fn test_block() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(106)
}

///|
pub fn call_expr() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(107)
}

///|
pub fn arg_list() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(108)
}

///|
pub fn name_ref() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(109)
}

///|
pub fn literal() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(110)
}

///|
pub fn if_expr() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(111)
}

///|
pub fn block_expr() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(112)
}

///|
pub fn match_expr() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(113)
}

///|
pub fn do_expr() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(114)
}

///|
pub fn paren_expr() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(115)
}

///|
pub fn record_expr() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(116)
}

///| Check if a SyntaxKind is a token (not a node)
pub fn is_token(kind : @cst.SyntaxKind) -> Bool {
  kind.raw() < 100
}

///| Check if a SyntaxKind is trivia (whitespace/newline)
pub fn is_trivia(kind : @cst.SyntaxKind) -> Bool {
  kind == whitespace() || kind == newline()
}
