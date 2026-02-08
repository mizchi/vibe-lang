///|
test "syntax kind keyword/operator ids are distinct" {
  if await_kw() == percent() {
    fail("await_kw and percent must have different SyntaxKind ids")
  }
  if yield_kw() == plus_eq() {
    fail("yield_kw and plus_eq must have different SyntaxKind ids")
  }
}

///|
test "lexer distinguishes await/yield from operators" {
  let await_tokens = tokenize("await %")
  if await_tokens[0].kind() != await_kw() {
    fail("await must lex as await_kw")
  }
  if await_tokens[2].kind() != percent() {
    fail("% must lex as percent")
  }
  if await_tokens[0].kind() == await_tokens[2].kind() {
    fail("await and % must not share SyntaxKind")
  }

  let yield_tokens = tokenize("yield +=")
  if yield_tokens[0].kind() != yield_kw() {
    fail("yield must lex as yield_kw")
  }
  if yield_tokens[2].kind() != plus_eq() {
    fail("+= must lex as plus_eq")
  }
  if yield_tokens[0].kind() == yield_tokens[2].kind() {
    fail("yield and += must not share SyntaxKind")
  }
}
