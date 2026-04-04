///|
test "line_info returns line, column and line bounds" {
  let source = "alpha\nbeta\ncharlie"
  let (pos, line_start, line_end) = line_info(source, 8)
  assert_eq(pos.line, 2)
  assert_eq(pos.column, 3)
  assert_eq(line_start, 6)
  assert_eq(line_end, 10)
}

///|
test "render_snippet draws caret for span" {
  let snippet = render_snippet("alpha\nbeta", Span::new(6, 8))
  assert_eq(snippet, "beta\n^~")
}

///|
test "Diagnostic::render includes path, stage, snippet and note" {
  let diag = Diagnostic::{
    stage: "type",
    message: "bad expr",
    span: Some(Span::new(6, 8)),
    hint: Some("rewrite it"),
    note: Some("from test"),
    severity: None,
    code: None,
  }
  let rendered = diag.render("main.vibe", "alpha\nbeta")
  assert_eq(
    rendered, "main.vibe:2:1: type: bad expr\nbeta\n^~\nhelp: rewrite it\nnote: from test",
  )
}
