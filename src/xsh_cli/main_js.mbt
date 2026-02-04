///|
fn main {
  touch_cli_helpers()
  println("xsh_cli is native-only; use --target native or the installed binary")
}

///|
/// Keep repl helpers referenced in JS builds to avoid unused warnings.
fn touch_cli_helpers() -> Unit {
  let _ = detect_completion_context("let x = 1", 5)
  let _ = is_in_fn_param_context("fn(", 2)
  let _ = extract_let_name("let x = 1")
  let editor = @editor.EditorState::new_with_kind(
    "",
    1,
    @editor.HighlightKind::Plain,
  )
  let _ = editor_content_start_col(editor)
  let _ = repl_input_rows_for_height(10)
  let view : ReplViewState = {
    width: 20,
    height: 6,
    input_rows: 1,
    outputs: [],
    history_len: 0,
  }
  let node = render_repl_view(view, editor)
  let _ = repl_cursor_pos(view, editor)
  let _ = node

}
