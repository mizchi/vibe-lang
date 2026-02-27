///|
test "normalize_format: railway notes summarize handle/throw/unwrap boundaries" {
  let source =
    #|let run = () -> Int with { Error } {
    #|  handle {
    #|    let value = Ok(1) |> unwrap
    #|    value
    #|  } {
    #|    Error(_) => throw("boom")
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
