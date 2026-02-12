///|
struct ReplViewState {
  width : Int
  height : Int
  input_rows : Int
  outputs : Array[String]
  history_len : Int
}

///|
fn editor_line_count(editor : @editor.EditorState) -> Int {
  let text = editor.get_text()
  let mut count = 1
  for ch in text {
    if ch == '\n' {
      count += 1
    }
  }
  count
}

///|
fn editor_content_start_col(editor : @editor.EditorState) -> Int {
  let line_count = editor_line_count(editor)
  let gutter_width = line_count.to_string().length()
  gutter_width + 1
}

///|
fn wrap_text(text : String, max_width : Int) -> Array[String] {
  let lines : Array[String] = []
  let current_line = StringBuilder::new()
  let mut current_width = 0
  let width = if max_width > 0 { max_width } else { 1 }
  for c in text {
    if c == '\n' {
      lines.push(current_line.to_string())
      current_line.reset()
      current_width = 0
    } else {
      let char_width = @core.char_display_width(c)
      if current_width + char_width > width {
        lines.push(current_line.to_string())
        current_line.reset()
        current_width = 0
      }
      current_line.write_char(c)
      current_width = current_width + char_width
    }
  }
  if current_width > 0 {
    lines.push(current_line.to_string())
  }
  if lines.is_empty() {
    lines.push("")
  }
  lines
}

///|
fn truncate_text(text : String, max_width : Int) -> String {
  let buf = StringBuilder::new()
  let mut current_width = 0
  let width = if max_width > 0 { max_width } else { 1 }
  for c in text {
    let char_width = @core.char_display_width(c)
    if current_width + char_width > width {
      break
    }
    buf.write_char(c)
    current_width = current_width + char_width
  }
  buf.to_string()
}

///|
fn chat_width(state : ReplViewState) -> Int {
  if state.width > 1 {
    state.width
  } else {
    1
  }
}

///|
fn max_input_rows(total_rows : Int) -> Int {
  let available = total_rows -
    header_rows() -
    divider_rows() -
    footer_rows() -
    1
  if available > 1 {
    available
  } else {
    1
  }
}

///|
fn repl_input_rows_for_height(total_rows : Int) -> Int {
  let base = if total_rows >= 11 { 6 } else if total_rows >= 8 { 3 } else { 1 }
  let desired = base + 3
  let max_rows = max_input_rows(total_rows)
  if desired > max_rows {
    max_rows
  } else {
    desired
  }
}

///|

///|
fn header_rows() -> Int {
  2
}

///|
fn divider_rows() -> Int {
  1
}

///|
fn footer_rows() -> Int {
  1
}

///|
fn message_area_height(state : ReplViewState) -> Int {
  let h = state.height -
    header_rows() -
    divider_rows() -
    state.input_rows -
    footer_rows()
  if h > 1 {
    h
  } else {
    1
  }
}

///|
fn build_output_lines(state : ReplViewState) -> Array[String] {
  let lines : Array[String] = []
  let w = if chat_width(state) > 2 { chat_width(state) - 2 } else { 1 }
  for line in state.outputs {
    for wrapped in wrap_text(line, w) {
      lines.push(wrapped)
    }
  }
  if lines.is_empty() {
    lines.push("")
  }
  lines
}

///|
fn output_line_color(line : String) -> String {
  if line.has_prefix("error:") {
    "rgb(220,120,120)"
  } else if line.has_prefix("> ") {
    "rgb(180,180,180)"
  } else if line.has_prefix("effect:") {
    "rgb(140,140,140)"
  } else {
    "white"
  }
}

///|
fn render_messages(state : ReplViewState) -> @tui.TuiNode {
  let all_lines = build_output_lines(state)
  let total_lines = all_lines.length()
  let area_height = message_area_height(state)
  let w = chat_width(state)
  let visible_lines : Array[@tui.TuiNode] = []
  let empty_lines_at_top = if total_lines < area_height {
    area_height - total_lines
  } else {
    0
  }
  for i = 0; i < area_height; i = i + 1 {
    if i < empty_lines_at_top {
      visible_lines.push(@tui.row(height=1.0, []))
    } else {
      let line_idx = total_lines - area_height + i
      let idx = if line_idx < 0 { 0 } else { line_idx }
      if idx < total_lines {
        let line = all_lines[idx]
        let display_line = truncate_text(line, w - 1)
        let fg = output_line_color(line)
        visible_lines.push(
          @tui.row(height=1.0, min_width=w.to_double(), [
            @tui.text(display_line, fg~),
          ]),
        )
      } else {
        visible_lines.push(@tui.row(height=1.0, []))
      }
    }
  }
  @tui.column(
    min_width=w.to_double(),
    height=area_height.to_double(),
    visible_lines,
  )
}

///|
fn render_header(state : ReplViewState) -> @tui.TuiNode {
  let w = chat_width(state)
  let title = truncate_text("vibe repl", w - 1)
  let hint = truncate_text(
    "Tab: completion | Up/Down: history | Ctrl+C: quit",
    w - 1,
  )
  @tui.column(height=header_rows().to_double(), min_width=w.to_double(), [
    @tui.text(title, fg="rgb(230,230,230)", bold=true),
    @tui.text(hint, fg="rgb(120,120,120)"),
  ])
}

///|
fn render_divider(state : ReplViewState) -> @tui.TuiNode {
  let w = chat_width(state)
  @tui.row(height=1.0, min_width=w.to_double(), [
    @tui.text("-".repeat(w), fg="rgb(60,60,60)"),
  ])
}

///|
fn render_input(
  state : ReplViewState,
  input_editor : @editor.EditorState,
) -> @tui.TuiNode {
  let w = chat_width(state)
  @tui.column(height=state.input_rows.to_double(), min_width=w.to_double(), [
    @editor.render_editor(
      input_editor,
      w,
      state.input_rows,
      show_header=false,
      show_footer=false,
    ),
  ])
}

///|
fn render_footer(state : ReplViewState) -> @tui.TuiNode {
  let w = chat_width(state)
  let info = "outputs: " +
    state.outputs.length().to_string() +
    " | history: " +
    state.history_len.to_string()
  @tui.row(height=1.0, min_width=w.to_double(), [
    @tui.text(truncate_text(info, w - 1), fg="rgb(90,90,90)"),
  ])
}

///|
fn render_repl_view(
  state : ReplViewState,
  input_editor : @editor.EditorState,
) -> @tui.TuiNode {
  let children : Array[@tui.TuiNode] = []
  children.push(render_header(state))
  children.push(render_messages(state))
  children.push(render_divider(state))
  children.push(render_input(state, input_editor))
  children.push(render_footer(state))
  @tui.column(
    width=chat_width(state).to_double(),
    height=state.height.to_double(),
    gap=0.0,
    children,
  )
}

///|
fn repl_input_origin_row(state : ReplViewState) -> Int {
  header_rows() + message_area_height(state) + divider_rows()
}

///|
fn repl_cursor_pos(
  state : ReplViewState,
  input_editor : @editor.EditorState,
) -> (Int, Int) {
  let (cursor_row, cursor_col) = @editor.editor_cursor_position(
    input_editor,
    chat_width(state),
    state.input_rows,
    show_header=false,
    show_footer=false,
  )
  (repl_input_origin_row(state) + cursor_row, cursor_col)
}
