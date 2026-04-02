///|
fn[A] fail_contract(label : String, msg : String) -> A {
  abort("parser-contract [" + label + "]: " + msg)
}

///|
fn assert_contract(label : String, cond : Bool, msg : String) -> Unit {
  if !cond {
    fail_contract(label, msg)
  }
}

///|
fn parse_or_fail(label : String, input : String) -> @core.Module {
  let parsed = try? @parser.parse_ast(input)
  match parsed {
    Ok(module_) => module_
    Err(err) => fail_contract(label, "parse failed: " + err.to_string())
  }
}

///|
fn format_roundtrip(
  label : String,
  input : String,
  extra_check : (String, @core.Module, @core.Module) -> Unit,
) -> Unit {
  let before = parse_or_fail(label + "/before", input)
  let formatted = @parser.format_script(input)
  let after = parse_or_fail(label + "/after", formatted)
  if @core.normalize_module(after) != @core.normalize_module(before) {
    fail_contract(label, "normalized AST changed after format roundtrip")
  }
  extra_check(formatted, before, after)
}

///|
fn assert_eq_string(label : String, actual : String, expected : String) -> Unit {
  if actual != expected {
    fail_contract(label, "expected `" + expected + "`, got `" + actual + "`")
  }
}

///|
fn assert_eq_int(label : String, actual : Int, expected : Int) -> Unit {
  if actual != expected {
    fail_contract(
      label,
      "expected " + expected.to_string() + ", got " + actual.to_string(),
    )
  }
}

///|
fn assert_eq_syntax_kind(
  label : String,
  actual : @cst.SyntaxKind,
  expected : @cst.SyntaxKind,
) -> Unit {
  if actual != expected {
    fail_contract(label, "unexpected syntax kind")
  }
}

///|
fn check_format_trait_impl_import() -> Unit {
  let input =
    #|import ./mod.vibe { type Option, trait Eq, eq }
    #|trait Eq
    #|impl Eq for Int
    #|test "quoted case" {
    #|  let msg = "hello world"
    #|  let escaped = "\"ok\""
    #|  let ch = 'z'
    #|  assert_true(msg == "hello world")
    #|}
  format_roundtrip("format-trait-impl-import", input, fn(formatted, _, _) {
    assert_contract(
      "format-trait-impl-import",
      formatted.contains("trait Eq"),
      "missing `trait Eq` in formatted output",
    )
    assert_contract(
      "format-trait-impl-import",
      formatted.contains("impl Eq for Int"),
      "missing `impl Eq for Int` in formatted output",
    )
    assert_contract(
      "format-trait-impl-import",
      !formatted.contains("traitEq"),
      "found joined `traitEq` token",
    )
  })
}

///|
fn check_format_import_export_models() -> Unit {
  let import_input =
    #|import ./math { add, mul as m }
    #|let x = m(2, 3)
    #|x
  format_roundtrip("format-import-list", import_input, fn(formatted, _, _) {
    assert_contract(
      "format-import-list",
      formatted.contains("import ./math"),
      "formatted import script lost canonical source form",
    )
  })
  let export_input =
    #|export ./math { add, mul as m }
    #|export { add, m }
  format_roundtrip("format-export-list", export_input, fn(formatted, _, _) {
    assert_contract(
      "format-export-list",
      formatted.contains("export ./math"),
      "formatted export script lost canonical source form",
    )
  })
}

///|
fn check_syntax_kind_lexer_contract() -> Unit {
  assert_contract(
    "syntax-kind",
    @parser.yield_kw() != @parser.plus_eq(),
    "yield_kw and plus_eq must differ",
  )
  let yield_tokens = @parser.tokenize("yield +=")
  assert_eq_syntax_kind(
    "yield-token",
    yield_tokens[0].kind(),
    @parser.yield_kw(),
  )
  assert_eq_syntax_kind(
    "plus-eq-token",
    yield_tokens[2].kind(),
    @parser.plus_eq(),
  )

  let map_lit_tokens = @parser.tokenize("map { a: 1 }")
  assert_eq_syntax_kind(
    "map-literal",
    map_lit_tokens[0].kind(),
    @parser.map_kw(),
  )
  let map_call_tokens = @parser.tokenize("map(1)")
  assert_eq_syntax_kind("map-call", map_call_tokens[0].kind(), @parser.name())
  let map_end_tokens = @parser.tokenize("map")
  assert_eq_syntax_kind("map-end", map_end_tokens[0].kind(), @parser.name())

  let raw_ident_tokens = @parser.tokenize("let r#bench = 1\nr#bench")
  assert_eq_syntax_kind(
    "raw-ident-kind",
    raw_ident_tokens[2].kind(),
    @parser.name(),
  )
  assert_eq_string("raw-ident-text", raw_ident_tokens[2].text(), "bench")

  let ns_tokens = @parser.tokenize("std/string::from_char_code(1)")
  assert_eq_syntax_kind("namespace-head", ns_tokens[0].kind(), @parser.name())
  assert_eq_syntax_kind("namespace-sep", ns_tokens[1].kind(), @parser.slash())
  assert_eq_syntax_kind(
    "namespace-member",
    ns_tokens[3].kind(),
    @parser.double_colon(),
  )
}

///|
fn check_parse_for_in() -> Unit {
  let ast = parse_or_fail("for-in", "for i, x in [10, 20, 30] { i + x }")
  match ast.stmts[0] {
    @core.Stmt::Expr(expr=@core.Expr::ForIn(value_name~, index_name~, ..), ..) => {
      assert_eq_string("for-in-value", value_name, "x")
      if index_name != Some("i") {
        fail_contract("for-in-index", "expected index binding `i`")
      }
    }
    _ => fail_contract("for-in", "expected ForIn expression with index")
  }
}

///|
fn check_parse_method_call_sugar() -> Unit {
  let parsed = try? @parser.parse_ast("obj.method(1)")
  match parsed {
    Ok(module_) =>
      match module_.stmts[0] {
        @core.Stmt::Expr(expr~, ..) =>
          match expr {
            @core.Expr::Call(name="method", args~, ..) =>
              assert_eq_int("ufcs-arg-count", args.length(), 2)
            _ => fail_contract("ufcs", "expected desugared method call")
          }
        _ => fail_contract("ufcs", "expected expr stmt")
      }
    Err(err) => fail_contract("ufcs", err.to_string())
  }

  let bad_mix = try? @parser.parse_ast("1 + 1 |> double")
  match bad_mix {
    Ok(_) => fail_contract("pipe-mix", "expected ambiguous infix+pipe to fail")
    Err(err) =>
      assert_contract(
        "pipe-mix",
        err.to_string().contains("parenthes"),
        "missing parenthesize guidance",
      )
  }
}

///|
fn check_parse_slice_and_raw_string() -> Unit {
  let module_ = parse_or_fail("slice-range", "let x = s[1:3]")
  match module_.stmts[0] {
    @core.Stmt::Let(
      name="x",
      expr=@core.Expr::Call(name="__slice", args~, ..),
      ..
    ) => assert_eq_int("slice-range-args", args.length(), 3)
    _ => fail_contract("slice-range", "expected __slice call")
  }

  let full_slice = parse_or_fail("slice-full", "let x = s[:]")
  match full_slice.stmts[0] {
    @core.Stmt::Let(name="x", expr=@core.Expr::Block(body~, ..), ..) =>
      match body.stmts[1] {
        @core.Stmt::Expr(expr=@core.Expr::Call(name="__slice", args~, ..), ..) =>
          match args[2].expr {
            @core.Expr::Call(name="__len", ..) => ()
            _ => fail_contract("slice-full", "expected __len end bound")
          }
        _ => fail_contract("slice-full", "expected __slice expr")
      }
    _ => fail_contract("slice-full", "expected block expr")
  }

  let raw_string = @parser.Lexer::new("r\"hello\\nworld\"").next_token()
  assert_eq_syntax_kind(
    "raw-string-kind",
    raw_string.kind(),
    @parser.string_lit(),
  )
  assert_eq_string("raw-string-text", raw_string.text(), "hello\\nworld")
}

///|
fn check_import_alias_and_pinned_path() -> Unit {
  let alias_decl = parse_or_fail("alias-decl", "import ../types @types")
  match alias_decl.stmts[0] {
    @core.Stmt::AliasDecl(alias_name~, source~, ..) => {
      assert_eq_string("alias-decl-name", alias_name, "types")
      match source {
        @core.ModuleRef::Path(path~) =>
          assert_eq_string("alias-decl-path", path, "../types")
        _ => fail_contract("alias-decl", "expected path source")
      }
    }
    _ => fail_contract("alias-decl", "expected AliasDecl")
  }

  let pinned_import = parse_or_fail(
    "pinned-import", "import ./types#abc123 { Expr }",
  )
  match pinned_import.stmts[0] {
    @core.Stmt::Import(source~, spec~, ..) => {
      match source {
        @core.ModuleRef::PinnedPath(path~, hash~) => {
          assert_eq_string("pinned-import-path", path, "./types")
          assert_eq_string("pinned-import-hash", hash, "abc123")
        }
        _ => fail_contract("pinned-import", "expected pinned path source")
      }
      assert_eq_string("pinned-import-item", spec.items[0].name, "Expr")
    }
    _ => fail_contract("pinned-import", "expected Import stmt")
  }
}

///|
fn run_case(label : String, f : () -> Unit) -> Unit {
  println("parser contract case: " + label)
  f()
}

///|
fn main {
  run_case("format-trait-impl-import", check_format_trait_impl_import)
  run_case("format-import-export-models", check_format_import_export_models)
  run_case("syntax-kind-lexer", check_syntax_kind_lexer_contract)
  run_case("for-in", check_parse_for_in)
  run_case("method-call-sugar", check_parse_method_call_sugar)
  run_case("slice-and-raw-string", check_parse_slice_and_raw_string)
  run_case("import-alias-pinned-path", check_import_alias_and_pinned_path)
  println("parser contract: ok")
}
