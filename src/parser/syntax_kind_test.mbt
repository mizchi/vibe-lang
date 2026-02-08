///|
test "syntax kind keyword/operator ids are distinct" {
  if await_kw() == percent() {
    fail("await_kw and percent must have different SyntaxKind ids")
  }
  if yield_kw() == plus_eq() {
    fail("yield_kw and plus_eq must have different SyntaxKind ids")
  }
  if break_kw() == minus() {
    fail("break_kw and minus must have different SyntaxKind ids")
  }
  if continue_kw() == slash() {
    fail("continue_kw and slash must have different SyntaxKind ids")
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
  let break_tokens = tokenize("break -")
  if break_tokens[0].kind() != break_kw() {
    fail("break must lex as break_kw")
  }
  if break_tokens[2].kind() != minus() {
    fail("- must lex as minus")
  }
  if break_tokens[0].kind() == break_tokens[2].kind() {
    fail("break and - must not share SyntaxKind")
  }
  let continue_tokens = tokenize("continue /")
  if continue_tokens[0].kind() != continue_kw() {
    fail("continue must lex as continue_kw")
  }
  if continue_tokens[2].kind() != slash() {
    fail("/ must lex as slash")
  }
  if continue_tokens[0].kind() == continue_tokens[2].kind() {
    fail("continue and / must not share SyntaxKind")
  }
}
