///|
test "import list syntax parses and formats" {
  let input =
    #|import ./math { add, mul as m }
    #|let x = m(2, 3)
    #|x
  let ast = parse_ast(input) catch {
    e => fail("[parse] import list syntax failed: \{e.to_string()}")
  }
  let formatted = format_script(input)
  let reparsed = parse_ast(formatted) catch {
    e =>
      fail(
        "[reparse] import list syntax format result failed: \{e.to_string()}\n---\n\{formatted}",
      )
  }
  assert_eq(@core.normalize_module(reparsed), @core.normalize_module(ast))
  if not(formatted.contains("import ./math")) {
    fail(
      "formatted import script did not contain canonical source form:\n\{formatted}",
    )
  }
}

///|
test "export source list syntax parses and formats" {
  let input =
    #|export ./math { add, mul as m }
    #|export { add, m }
  let ast = parse_ast(input) catch {
    e => fail("[parse] export source list syntax failed: \{e.to_string()}")
  }
  let formatted = format_script(input)
  let reparsed = parse_ast(formatted) catch {
    e =>
      fail(
        "[reparse] export source list syntax format result failed: \{e.to_string()}\n---\n\{formatted}",
      )
  }
  assert_eq(@core.normalize_module(reparsed), @core.normalize_module(ast))
  if not(formatted.contains("export ./math")) {
    fail(
      "formatted export script did not contain canonical source form:\n\{formatted}",
    )
  }
}

///|
test "parse rejects use keyword" {
  let input = "use ./math { add }\nadd(1, 2)"
  let parsed : Result[@core.Module, ParseError] = try? parse_ast(input)
  match parsed {
    Ok(_) => fail("[parse] expected `use` to be rejected")
    Err(err) => assert_true(err.to_string().contains("import"))
  }
}

///|
test "parse rejects declare keyword" {
  let input = "declare export let run: () -> Int\nexport { run }"
  let parsed : Result[@core.Module, ParseError] = try? parse_ast(input)
  match parsed {
    Ok(_) => fail("[parse] expected `declare` to be rejected")
    Err(err) => assert_true(err.to_string().contains("declare"))
  }
}

///|
test "internal export for value parses" {
  let input =
    #|internal export let helper = () -> Int { 1 }
    #|let x = helper()
    #|x
  let ast = parse_ast(input) catch {
    e => fail("[parse] internal export let failed: \{e.to_string()}")
  }
  let formatted = format_script(input)
  let reparsed = parse_ast(formatted) catch {
    e =>
      fail(
        "[reparse] internal export let format result failed: \{e.to_string()}\n---\n\{formatted}",
      )
  }
  assert_eq(@core.normalize_module(reparsed), @core.normalize_module(ast))
}

///|
test "internal export let is not treated as public export let" {
  let ast = parse_ast("internal export let helper = () -> Int { 1 }") catch {
    e => fail("[parse] internal export let failed: \{e.to_string()}")
  }
  match ast.stmts[0] {
    @core.Stmt::ExportLet(..) =>
      fail("internal export let must not be lowered to ExportLet")
    _ => ()
  }
}

///|
test "internal export type is not treated as public export type" {
  let ast = parse_ast("internal export type Id = Int") catch {
    e => fail("[parse] internal export type failed: \{e.to_string()}")
  }
  match ast.stmts[0] {
    @core.Stmt::ExportTypeAlias(..) =>
      fail("internal export type must not be lowered to ExportTypeAlias")
    _ => ()
  }
}

///|
test "internal export enum is not treated as public export enum" {
  let ast = parse_ast("internal export enum State { A }") catch {
    e => fail("[parse] internal export enum failed: \{e.to_string()}")
  }
  match ast.stmts[0] {
    @core.Stmt::ExportEnumDef(..) =>
      fail("internal export enum must not be lowered to ExportEnumDef")
    _ => ()
  }
}

///|
test "internal export trait is not treated as public export trait" {
  let ast = parse_ast("internal export trait Eq") catch {
    e => fail("[parse] internal export trait failed: \{e.to_string()}")
  }
  match ast.stmts[0] {
    @core.Stmt::TraitDef(exported~, ..) =>
      if exported {
        fail("internal export trait must not be exported=true")
      }
    _ => ()
  }
}

///|
test "extern let with percent-prefixed symbol parses" {
  let input = "extern let %add: (Int, Int) -> Int"
  let ast = parse_ast(input) catch {
    e => fail("[parse] extern let with percent symbol failed: \{e.to_string()}")
  }
  let formatted = format_script(input)
  let reparsed = parse_ast(formatted) catch {
    e =>
      fail(
        "[reparse] extern let with percent symbol format result failed: \{e.to_string()}\n---\n\{formatted}",
      )
  }
  assert_eq(@core.normalize_module(reparsed), @core.normalize_module(ast))
}
