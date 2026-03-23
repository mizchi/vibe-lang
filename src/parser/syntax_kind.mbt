///| SyntaxKind constants for vibe

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
pub fn comment() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(4)
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
pub fn char_lit() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(14)
}

///|
pub fn float_lit() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(15)
}

///|
pub fn string_interp_lit() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(16)
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
pub fn use_kw() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(93)
}

///|
pub fn declare_kw() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(94)
}

///|
pub fn for_kw() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(95)
}

///|
pub fn in_kw() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(96)
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
pub fn record_kw() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(29)
}

///|
pub fn fn_kw() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(34)
}

///|
pub fn rec_kw() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(36)
}

///|
pub fn type_kw() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(39)
}

///|
pub fn enum_kw() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(60)
}

///|
pub fn map_kw() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(57)
}

///|
pub fn while_kw() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(63)
}

///|
pub fn mut_kw() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(64)
}

///|
pub fn raise_kw() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(65)
}

///|
pub fn yield_kw() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(88)
}

///|
pub fn break_kw() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(89)
}

///|
pub fn continue_kw() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(90)
}

///|
pub fn loop_kw() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(91)
}

///|
pub fn bench_kw() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(92)
}

///|
pub fn while_expr() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(124)
}

///|
pub fn raise_expr() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(125)
}

///|
pub fn yield_expr() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(127)
}

///|
pub fn break_expr() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(130)
}

///|
pub fn continue_expr() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(131)
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
pub fn thin_arrow() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(35)
}

///|
pub fn colon() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(33)
}

///|
pub fn plus() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(37)
}

///|
pub fn star() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(38)
}

///|
pub fn minus() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(45)
}

///|
pub fn slash() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(46)
}

///|
pub fn percent() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(66)
}

///|
pub fn plus_eq() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(67)
}

///|
pub fn minus_eq() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(68)
}

///|
pub fn star_eq() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(69)
}

///|
pub fn slash_eq() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(70)
}

///|
pub fn percent_eq() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(71)
}

///|
pub fn dot() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(72)
}

///|
pub fn pipe() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(47)
}

///|
pub fn bang() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(48)
}

///|
pub fn question() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(135)
}

///|
pub fn eqeq() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(49)
}

///|
pub fn neq() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(50)
}

///|
pub fn lt() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(51)
}

///|
pub fn lte() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(52)
}

///|
pub fn gt() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(53)
}

///|
pub fn gte() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(54)
}

///|
pub fn and_and() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(55)
}

///|
pub fn or_or() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(56)
}

///|
pub fn lbracket() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(58)
}

///|
pub fn rbracket() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(59)
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
pub fn bench_block() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(132)
}

///|
pub fn module_stmt() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(133)
}

///|
pub fn type_def() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(118)
}

///|
pub fn enum_def() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(121)
}

///|
pub fn type_alias() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(122)
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
pub fn paren_expr() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(115)
}

///|
pub fn record_expr() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(116)
}

///|
pub fn fn_expr() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(117)
}

///|
pub fn array_expr() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(119)
}

///|
pub fn map_expr() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(120)
}

///|
pub fn export_kw() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(73)
}

///|
pub fn from_kw() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(74)
}

///|
pub fn as_kw() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(75)
}

///|
pub fn hash_ref() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(76)
}

///|
pub fn bit_and() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(77)
}

///|
pub fn bit_or() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(78)
}

///|
pub fn bit_xor() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(79)
}

///|
pub fn lshift() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(80)
}

///|
pub fn rshift() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(81)
}

///|
pub fn pipe_gt() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(82)
}

///|
pub fn export_stmt() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(128)
}

///|
pub fn struct_kw() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(83)
}

///|
pub fn trait_kw() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(85)
}

///|
pub fn impl_kw() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(86)
}

///|
pub fn handle_kw() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(97)
}

///|
pub fn handle_expr() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(134)
}

///|
pub fn struct_def() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(129)
}

///|
pub fn double_colon() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(84)
}

///|
pub fn dotdot() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(98)
}

///|
pub fn dotdotdot() -> @cst.SyntaxKind {
  @cst.SyntaxKind::new(87)
}

///|
/// Check if a SyntaxKind is a token (not a node)
pub fn is_token(kind : @cst.SyntaxKind) -> Bool {
  kind.raw() < 100 || kind == question()
}

///|
/// Check if a SyntaxKind is trivia (whitespace/newline)
pub fn is_trivia(kind : @cst.SyntaxKind) -> Bool {
  kind == whitespace() || kind == newline() || kind == comment()
}
