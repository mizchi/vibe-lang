///|
test "normalize_format: railway notes summarize handle/throw/unwrap boundaries" {
  let source =
    #|let run = () -> Int with { Error } {
    #|  handle {
    #|    let value = Ok(1) |> unwrap
    #|    value
    #|  } with Error {
    #|    Throw(_) => throw("boom")
    #|  }
    #|}
  let notes = railway_boundary_notes_for_source(source)
  assert_eq(notes.length(), 2)
  assert_eq(notes[0], "railway boundaries: handle=1 throw=1 unwrap=1")
  assert_true(notes[1].contains("unwrap is a terminal boundary"))
}

///|
test "normalize_format: railway notes warn throw without local handle" {
  let source =
    #|let fail = () -> Int with { Error } {
    #|  throw("boom")
    #|}
  let notes = railway_boundary_notes_for_source(source)
  assert_eq(notes.length(), 2)
  assert_eq(notes[0], "railway boundaries: handle=0 throw=1 unwrap=0")
  assert_true(notes[1].contains("throw appears without local handle"))
}

///|
test "normalize_format: railway notes are empty for pure source" {
  let source =
    #|let add = (a: Int, b: Int) -> Int { a + b }
  let notes = railway_boundary_notes_for_source(source)
  assert_eq(notes.length(), 0)
}

///|
test "strip_redundant_blocks: top-level let" {
  let source = "let x = { 42 }"
  let result = strip_redundant_blocks_source(source)
  assert_false(result.contains("{"))
  assert_true(result.contains("42"))
}

///|
test "strip_redundant_blocks: inside fn body" {
  let source =
    #|let f = (a: Int) -> Int {
    #|  { a + 1 }
    #|}
  let result = strip_redundant_blocks_source(source)
  assert_false(result.contains("{ a"))
  assert_true(result.contains("a + 1"))
}

///|
test "normalize_format: strip block inside fn body" {
  let source =
    #|let f = (a: Int) -> Int {
    #|  { a + 1 }
    #|}
  let result = match normalize_format_source_text(source) {
    Ok(v) => v
    Err(err) => fail("normalize failed: " + err)
  }
  assert_false(result.contains("{ a"))
  assert_true(result.contains("a + 1"))
}

///|
test "strip_redundant_blocks: else branch single expr keeps braces" {
  let source =
    #|let exp = 10
    #|let signed = if true {
    #|  0 - exp
    #|} else {
    #|  exp
    #|}
    #|(signed, 1)
  let result = strip_redundant_blocks_source(source)
  // The else { exp } braces must be preserved to avoid
  // exp(...) call ambiguity with the following tuple expression.
  assert_true(result.contains("} else {"))
}

///|
test "normalize_format: else branch single expr preserves braces" {
  let source =
    #|let exp = 10
    #|let signed = if true {
    #|  0 - exp
    #|} else {
    #|  exp
    #|}
  let result = strip_redundant_blocks_source(source)
  assert_true(result.contains("} else {"))
}

///|
test "normalize_format: else branch single expr keeps braces (full pipeline)" {
  let source =
    #|let exp = 10
    #|let signed = if true {
    #|  0 - exp
    #|} else {
    #|  exp
    #|}
    #|(signed, 1)
  let result = match normalize_format_source_text(source) {
    Ok(v) => v
    Err(err) => fail("normalize failed: " + err)
  }
  // The else { exp } braces must be preserved to avoid
  // exp(...) call ambiguity with the following tuple expression.
  assert_true(result.contains("} else {"))
}

///|
test "normalize_format: self-import (import .{ ... }) round-trips" {
  let source =
    #|import .{ encode, decode }
    #|
    #|test "t" { assert(true) }
  let result = match normalize_format_source_text(source) {
    Ok(v) => v
    Err(err) => fail("normalize failed: " + err)
  }
  assert_true(result.contains("import ."))
}

///|
test "normalize_format: export effect definition round-trips" {
  let source =
    #|import ./token.vibe { Token }
    #|
    #|export effect ParseRecur {
    #|  Call(Array[Token], Int, Int) -> (Expr, Int)
    #|}
  let result = match normalize_format_source_text(source) {
    Ok(v) => v
    Err(err) => fail("normalize failed: " + err)
  }
  assert_true(result.contains("export effect ParseRecur {"))
  assert_true(result.contains("Call(Array[Token], Int, Int) -> (Expr, Int)"))
}
