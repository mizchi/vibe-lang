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
