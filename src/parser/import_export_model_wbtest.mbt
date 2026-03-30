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
  if !formatted.contains("import ./math") {
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
  if !formatted.contains("export ./math") {
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
test "alias declaration: import path @alias parses to AliasDecl" {
  let input = "import ../types @types"
  let ast = parse_ast(input) catch {
    e => fail("[parse] alias decl failed: \{e.to_string()}")
  }
  match ast.stmts[0] {
    @core.Stmt::AliasDecl(alias_name~, source~, ..) => {
      assert_eq(alias_name, "types")
      match source {
        @core.ModuleRef::Path(path~) => assert_eq(path, "../types")
        _ => fail("expected Path source, got: \{source}")
      }
    }
    _ => fail("expected AliasDecl, got: \{ast.stmts[0]}")
  }
}

///|
test "alias import: import @alias { sym } parses to Import with Alias source" {
  let input = "import @types { Expr }"
  let ast = parse_ast(input) catch {
    e => fail("[parse] alias import failed: \{e.to_string()}")
  }
  match ast.stmts[0] {
    @core.Stmt::Import(spec~, source~, ..) => {
      match source {
        @core.ModuleRef::Alias(name~) => assert_eq(name, "types")
        _ => fail("expected Alias source, got: \{source}")
      }
      assert_eq(spec.items.length(), 1)
      assert_eq(spec.items[0].name, "Expr")
    }
    _ => fail("expected Import, got: \{ast.stmts[0]}")
  }
}

///|
test "alias declaration roundtrips through format" {
  let input = "import ../types @types"
  let formatted = format_script(input)
  let reparsed = parse_ast(formatted) catch {
    e =>
      fail(
        "[reparse] alias decl format result failed: \{e.to_string()}\n---\n\{formatted}",
      )
  }
  match reparsed.stmts[0] {
    @core.Stmt::AliasDecl(alias_name~, ..) => assert_eq(alias_name, "types")
    _ => fail("expected AliasDecl after roundtrip, got: \{reparsed.stmts[0]}")
  }
}

///|
test "alias declaration with hash source" {
  let input = "import #abc123 @cached"
  let ast = parse_ast(input) catch {
    e => fail("[parse] hash alias decl failed: \{e.to_string()}")
  }
  match ast.stmts[0] {
    @core.Stmt::AliasDecl(alias_name~, source~, ..) => {
      assert_eq(alias_name, "cached")
      match source {
        @core.ModuleRef::Hash(hash~) => assert_eq(hash, "abc123")
        _ => fail("expected Hash source, got: \{source}")
      }
    }
    _ => fail("expected AliasDecl, got: \{ast.stmts[0]}")
  }
}

///|
test "alias declaration with version source" {
  let input = "import version@main @v"
  let ast = parse_ast(input) catch {
    e => fail("[parse] version alias decl failed: \{e.to_string()}")
  }
  match ast.stmts[0] {
    @core.Stmt::AliasDecl(alias_name~, source~, ..) => {
      assert_eq(alias_name, "v")
      match source {
        @core.ModuleRef::Version(name~) => assert_eq(name, "main")
        _ => fail("expected Version source, got: \{source}")
      }
    }
    _ => fail("expected AliasDecl, got: \{ast.stmts[0]}")
  }
}

///|
test "alias import rejects alias-to-alias" {
  let input = "import @foo @bar"
  let parsed : Result[@core.Module, ParseError] = try? parse_ast(input)
  match parsed {
    Ok(_) => fail("[parse] expected alias-to-alias to be rejected")
    Err(_) => ()
  }
}

///|
test "import struct/effect/suberror kinds parse correctly" {
  let input =
    #|import ./foo { struct MyStruct, effect MyEffect, suberror MyError }
  let ast = parse_ast(input) catch {
    e => fail("[parse] import kinds failed: \{e.to_string()}")
  }
  match ast.stmts[0] {
    @core.Stmt::Import(spec~, ..) => {
      assert_eq(spec.items.length(), 3)
      assert_eq(spec.items[0].kind, @core.ImportKind::Struct)
      assert_eq(spec.items[0].name, "MyStruct")
      assert_eq(spec.items[1].kind, @core.ImportKind::Effect)
      assert_eq(spec.items[1].name, "MyEffect")
      assert_eq(spec.items[2].kind, @core.ImportKind::Suberror)
      assert_eq(spec.items[2].name, "MyError")
    }
    _ => fail("expected Import")
  }
}

///|
test "pinned path: import ./types#abc123 { Expr } parses to PinnedPath" {
  let input = "import ./types#abc123 { Expr }"
  let ast = parse_ast(input) catch {
    e => fail("[parse] pinned path import failed: \{e.to_string()}")
  }
  match ast.stmts[0] {
    @core.Stmt::Import(source~, spec~, ..) => {
      match source {
        @core.ModuleRef::PinnedPath(path~, hash~) => {
          assert_eq(path, "./types")
          assert_eq(hash, "abc123")
        }
        _ => fail("expected PinnedPath, got: \{source}")
      }
      assert_eq(spec.items[0].name, "Expr")
    }
    _ => fail("expected Import")
  }
}

///|
test "pinned path alias: import ./types#abc123 @types parses to AliasDecl with PinnedPath" {
  let input = "import ./types#abc123 @types"
  let ast = parse_ast(input) catch {
    e => fail("[parse] pinned path alias failed: \{e.to_string()}")
  }
  match ast.stmts[0] {
    @core.Stmt::AliasDecl(alias_name~, source~, ..) => {
      assert_eq(alias_name, "types")
      match source {
        @core.ModuleRef::PinnedPath(path~, hash~) => {
          assert_eq(path, "./types")
          assert_eq(hash, "abc123")
        }
        _ => fail("expected PinnedPath source, got: \{source}")
      }
    }
    _ => fail("expected AliasDecl")
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
