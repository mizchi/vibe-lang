///|
fn wbtest_parse_diag_span() -> @core.Span {
  { start: 0, end: 1 }
}

///|
test "parse diagnostic suggests semicolon separator quickfix" {
  let diag = ParseError::UnexpectedToken(
    expected="; (struct field separator)",
    got=",",
    span=wbtest_parse_diag_span(),
  ).diagnostic()
  match diag.hint {
    Some(hint) => {
      assert_true(hint.contains("replace `,` with `;`"))
      assert_true(hint.contains("struct field separator"))
    }
    None => fail("expected separator quickfix hint")
  }
}

///|
test "parse diagnostic suggests labeled-arg quickfix" {
  let diag = ParseError::UnexpectedToken(
    expected="label",
    got="x~",
    span=wbtest_parse_diag_span(),
  ).diagnostic()
  match diag.hint {
    Some(hint) => {
      assert_true(hint.contains("x ="))
      assert_true(hint.contains("x~"))
    }
    None => fail("expected labeled arg quickfix hint")
  }
}

///|
test "parse diagnostic suggests parenthesize hint for infix+pipe mix" {
  let diag = ParseError::UnexpectedToken(
    expected="parenthesize infix expression when mixing with `|>`",
    got="|>",
    span=wbtest_parse_diag_span(),
  ).diagnostic()
  match diag.hint {
    Some(hint) => {
      assert_true(hint.contains("(1 + 1) |> double"))
      assert_true(hint.contains("x |> (f + g)"))
    }
    None => fail("expected infix+pipe parenthesize quickfix hint")
  }
}
