///|
fn main {
  touch_cli_helpers()
  let _ = @sys.get_cli_args()
  print_js_usage()
}

///|
/// Keep repl helpers referenced in JS builds to avoid unused warnings.
fn touch_cli_helpers() -> Unit {
  let _ = detect_completion_context("let x = 1", 5)
  let _ = is_in_fn_param_context("fn(", 2)
  let _ = extract_let_name("let x = 1")
  match detect_method_completion("t.foo", 5) {
    Some(info) => {
      let _ = info.receiver
      let _ = info.prefix

    }
    None => ()
  }
  match detect_pipe_completion("x |> inc", 9) {
    Some(info) => {
      let _ = info.receiver
      let _ = info.prefix

    }
    None => ()
  }
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

///|
pub fn print_js_usage() -> Unit {
  println("xsh command is native-only for interactive I/O right now.")
  println(
    "reason: moonbit async stdio lacks stdin/stdout values on js/wasm targets.",
  )
  println("use: --target native + `repl-stdin` / `repl-wasi`")
  println(
    "for wasm stdio repl build: `moon build --target wasm src/cmd/xsh_wasi`",
  )
}
