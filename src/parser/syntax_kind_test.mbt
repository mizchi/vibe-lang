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
  if loop_kw() == star_eq() {
    fail("loop_kw and star_eq must have different SyntaxKind ids")
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
  let loop_kw_tokens = tokenize("loop { break }")
  if loop_kw_tokens[0].kind() != loop_kw() {
    fail("loop before { must lex as loop_kw")
  }
  let loop_ident_tokens = tokenize("let loop = 1\nloop(1)")
  if loop_ident_tokens[2].kind() != name() {
    fail("loop binding must lex as name")
  }
  if loop_ident_tokens[8].kind() != name() {
    fail("loop before ( must lex as name")
  }
}

///|
test "lexer treats map as contextual keyword" {
  let map_lit_tokens = tokenize("map { a: 1 }")
  if map_lit_tokens[0].kind() != map_kw() {
    fail("map before { must lex as map_kw")
  }
  let map_ident_tokens = tokenize("let map = 1\nmap(1)")
  if map_ident_tokens[2].kind() != name() {
    fail("map binding must lex as name")
  }
  let map_call_tokens = tokenize("map(1)")
  if map_call_tokens[0].kind() != name() {
    fail("map before ( must lex as name")
  }
}

///|
test "lexer treats bench as keyword" {
  let bench_tokens = tokenize("bench \"sum\" { let x = 1 }")
  if bench_tokens[0].kind() != bench_kw() {
    fail("bench must lex as bench_kw")
  }
  let bench_ident_tokens = tokenize("let bench = 1\nbench(1)")
  if bench_ident_tokens[2].kind() != bench_kw() {
    fail("bench is reserved and must lex as bench_kw")
  }
  if bench_ident_tokens[8].kind() != bench_kw() {
    fail("bench before ( must lex as bench_kw")
  }
}

///|
test "lexer treats use as keyword and keeps slash namespace tokens" {
  let use_tokens = tokenize("use /xsh/std/string")
  if use_tokens[0].kind() != use_kw() {
    fail("use must lex as use_kw")
  }
  let ns_tokens = tokenize("std/string::from_char_code(1)")
  if ns_tokens[0].kind() != name() {
    fail("namespace head must lex as name")
  }
  if ns_tokens[1].kind() != slash() {
    fail("namespace separator must lex as slash")
  }
  if ns_tokens[2].kind() != name() {
    fail("namespace tail must lex as name")
  }
  if ns_tokens[3].kind() != double_colon() {
    fail("member access must lex as double_colon")
  }
}
