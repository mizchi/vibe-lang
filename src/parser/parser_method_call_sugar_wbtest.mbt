///|
test "parse UFCS: expr.method(args) desugars to method(expr, args)" {
  let input = "obj.method(1)"
  let parsed : Result[@core.Module, ParseError] = try? parse_ast(input)
  match parsed {
    Ok(m) =>
      match m.stmts[0] {
        @core.Stmt::Expr(expr~, ..) =>
          match expr {
            @core.Expr::Call(name="method", args~, ..) =>
              assert_eq(args.length(), 2) // obj + 1
            _ => fail("[parse] expected Call node, got: \{expr}")
          }
        _ => fail("[parse] expected Expr stmt")
      }
    Err(err) => fail("[parse] UFCS should parse: \{err.to_string()}")
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
