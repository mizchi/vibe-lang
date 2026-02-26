///|
test "parse rejects method-call sugar expr.method(args)" {
  let input = "obj.method(1)"
  let parsed : Result[@core.Module, ParseError] = try? parse_ast(input)
  match parsed {
    Ok(_) => fail("[parse] expected method-call sugar to be rejected")
    Err(err) => assert_true(err.to_string().contains("method-call sugar"))
  }
}

///|
test "parse rejects ambiguous mix: infix on left of pipe" {
  let input = "1 + 1 |> double"
  let parsed : Result[@core.Module, ParseError] = try? parse_ast(input)
  match parsed {
    Ok(_) => fail("[parse] expected ambiguous infix+pipe mix to be rejected")
    Err(err) => assert_true(err.to_string().contains("parenthes"))
  }
}

///|
test "parse rejects ambiguous mix: infix on right of pipe" {
  let input = "x |> f + g"
  let parsed : Result[@core.Module, ParseError] = try? parse_ast(input)
  match parsed {
    Ok(_) => fail("[parse] expected ambiguous infix+pipe mix to be rejected")
    Err(err) => assert_true(err.to_string().contains("parenthes"))
  }
}

///|
test "parse allows parenthesized infix around pipe" {
  let input = "(1 + 1) |> double"
  let parsed : Result[@core.Module, ParseError] = try? parse_ast(input)
  match parsed {
    Ok(_) => ()
    Err(err) =>
      fail("[parse] expected parenthesized pipe to parse: \{err.to_string()}")
  }
}
