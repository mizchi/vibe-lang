///|
test "repl view renders header and output" {
  let editor = @editor.EditorState::new_with_kind(
    "add(1,2)",
    3,
    @editor.HighlightKind::Plain,
  )
  let view : ReplViewState = {
    width: 40,
    height: 12,
    input_rows: 3,
    outputs: ["last: Int(3)"],
    history_len: 1,
  }
  let node = render_repl_view(view, editor)
  let output = @tui.render_vnode_once(view.width, view.height, node)
  let (row, col) = repl_cursor_pos(view, editor)
  assert_true(row >= 0)
  assert_true(col >= 0)
  assert_true(output.contains("xsh repl"))
  assert_true(output.contains("last: Int(3)"))
}
