///|
/// CLI entry logic for xsh
pub fn run(args : Array[String]) -> Unit {
  if args.length() <= 1 {
    print_usage()
    return
  }
  let cmd = args[1]
  let cmd_args = args_tail(args, 2)
  match cmd {
    "run" => run_cmd(cmd_args)
    "test" => test_cmd(cmd_args)
    "compile" => compile_cmd(cmd_args)
    "bench" => bench_cmd(cmd_args)
    "bench-file" => bench_file_cmd(cmd_args)
    "repl" => repl_cmd(cmd_args)
    "repl-stdin" => repl_stdin_cmd(cmd_args)
    "help" => print_usage()
    _ => {
      println("unknown command: " + cmd)
      print_usage()
    }
  }
}

///|
fn print_usage() -> Unit {
  println("xsh <command> [args]")
  println("")
  println("commands:")
  println("  run <file>                 parse/type/eval a script")
  println("  test <file...>             run test blocks in scripts")
  println("  compile [--wasm] [-o out] <file>  emit IR (default) or wasm bytes")
  println("  bench [--n N] [--warmup N] [--expr EXPR]")
  println("  bench-file [--n N] [--warmup N] <file>")
  println("  repl                        interactive TUI shell")
  println("  repl-stdin [--no-prompt]    read-eval-print loop (stdin)")
}

///|
fn args_tail(args : Array[String], start : Int) -> Array[String] {
  let out : Array[String] = []
  for i in start..<args.length() {
    out.push(args[i])
  }
  out
}

///|
fn short_hash(hash : String) -> String {
  if hash.length() <= 7 {
    hash
  } else {
    (try! hash[0:7]).to_string()
  }
}

///|
enum CompileMode {
  Ir
  Wasm
}

///|
enum CompletionAnchor {
  Above
  Below
}

///|
fn pick_completion_anchor(
  current : CompletionAnchor?,
  available_above : Int,
  available_below : Int,
) -> CompletionAnchor? {
  let can_above = available_above >= 1
  let can_below = available_below >= 1
  match current {
    Some(anchor) =>
      match anchor {
        CompletionAnchor::Above => if can_above { return Some(anchor) }
        CompletionAnchor::Below => if can_below { return Some(anchor) }
      }
    None => ()
  }
  if can_below {
    Some(CompletionAnchor::Below)
  } else if can_above {
    Some(CompletionAnchor::Above)
  } else {
    None
  }
}

///|
fn compile_cmd(args : Array[String]) -> Unit {
  let mut mode = CompileMode::Ir
  let mut out_path : String? = None
  let mut entry_path : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--wasm" => {
        mode = CompileMode::Wasm
        i += 1
      }
      "-o" | "--out" => {
        if i + 1 >= args.length() {
          abort("compile: missing output path after " + arg)
        }
        out_path = Some(args[i + 1])
        i += 2
      }
      _ => {
        if entry_path is None {
          entry_path = Some(arg)
        } else {
          abort("compile: too many input files")
        }
        i += 1
      }
    }
  }
  match entry_path {
    None => abort("compile: missing <file>")
    Some(path) =>
      match load_db(path) {
        Err(err) => abort("compile: " + err)
        Ok((db, entry)) =>
          match mode {
            CompileMode::Ir => {
              let compiled = @xsh_lib.compile_module(db, entry) catch {
                e => abort("compile: " + e.to_string())
              }
              match out_path {
                Some(out) =>
                  @os_fs.write_string_to_file(out, compiled.ir) catch {
                    e => abort("compile: " + e.to_string())
                  }
                None => println(compiled.ir)
              }
            }
            CompileMode::Wasm => {
              if out_path is None {
                abort("compile: --wasm requires -o <file>")
              }
              let wasm_bytes = @xsh_lib.compile_module_wasm(db, entry) catch {
                e => abort("compile: " + e.to_string())
              }
              match out_path {
                Some(out) =>
                  @os_fs.write_bytes_to_file(out, wasm_bytes) catch {
                    e => abort("compile: " + e.to_string())
                  }
                None => ()
              }
            }
          }
      }
  }
}

///|
fn run_cmd(args : Array[String]) -> Unit {
  if args.length() != 1 {
    abort("run: expected <file>")
  }
  let entry_path = args[0]
  match compile_entry(entry_path) {
    Err(err) => abort("run: " + err)
    Ok(compiled) => {
      let rt = @xsh_lib.Runtime::new(@capability.CapabilitySet::developer())
      let result = rt.run_compiled(compiled) catch {
        e => abort("run: " + e.to_string())
      }
      print_eval_result(result)
    }
  }
}

///|
fn test_cmd(args : Array[String]) -> Unit {
  if args.length() == 0 {
    abort("test: expected <file...>")
  }
  let mut failed = false
  for entry_path in args {
    match compile_entry(entry_path) {
      Err(err) => {
        println("[\{entry_path}] compile error: \{err}")
        failed = true
      }
      Ok(compiled) => {
        let rt = @xsh_lib.Runtime::new(@capability.CapabilitySet::developer())
        for name, target in compiled.aliases {
          rt.set_alias(name, target)
        }
        let report = rt.run_tests(compiled.ast) catch {
          e => abort("[\{entry_path}] eval error: \{e.to_string()}")
        }
        if !print_test_report(entry_path, report) {
          failed = true
        }
      }
    }
  }
  if failed {
    abort("test: failures detected")
  }
}

///|
fn bench_cmd(args : Array[String]) -> Unit {
  let mut count = 20000
  let mut warmup = 1000
  let mut expr = "add(1,2)"
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-n" | "--n" => {
        if i + 1 >= args.length() {
          abort("bench: missing value for --n")
        }
        count = @strconv.parse_int(args[i + 1]) catch {
          e => abort("bench: invalid --n: " + e.to_string())
        }
        i += 2
      }
      "--warmup" => {
        if i + 1 >= args.length() {
          abort("bench: missing value for --warmup")
        }
        warmup = @strconv.parse_int(args[i + 1]) catch {
          e => abort("bench: invalid --warmup: " + e.to_string())
        }
        i += 2
      }
      "-e" | "--expr" => {
        if i + 1 >= args.length() {
          abort("bench: missing value for --expr")
        }
        expr = args[i + 1]
        i += 2
      }
      _ => abort("bench: unknown arg " + arg)
    }
  }
  if count <= 0 {
    abort("bench: --n must be > 0")
  }
  if warmup < 0 {
    abort("bench: --warmup must be >= 0")
  }
  let rt = @xsh_lib.Runtime::new(@capability.CapabilitySet::developer())
  for _ in 0..<warmup {
    let _ = rt.eval_script(expr) catch { e => abort("bench: " + e.to_string()) }

  }
  let start = @env.now()
  for _ in 0..<count {
    let _ = rt.eval_script(expr) catch { e => abort("bench: " + e.to_string()) }

  }
  let end = @env.now()
  let elapsed_ms = (end - start).to_double()
  let per_us = elapsed_ms * 1000.0 / count.to_double()
  if elapsed_ms <= 0.0 {
    println("bench: elapsed_ms=0; increase --n for measurable time")
  }
  println(
    "bench: expr=\"" +
    expr +
    "\" count=" +
    count.to_string() +
    " total_ms=" +
    elapsed_ms.to_string() +
    " per_us=" +
    per_us.to_string(),
  )
}

///|
fn bench_file_cmd(args : Array[String]) -> Unit {
  let mut count = 1000
  let mut warmup = 10
  let mut entry_path : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-n" | "--n" => {
        if i + 1 >= args.length() {
          abort("bench-file: missing value for --n")
        }
        count = @strconv.parse_int(args[i + 1]) catch {
          e => abort("bench-file: invalid --n: " + e.to_string())
        }
        i += 2
      }
      "--warmup" => {
        if i + 1 >= args.length() {
          abort("bench-file: missing value for --warmup")
        }
        warmup = @strconv.parse_int(args[i + 1]) catch {
          e => abort("bench-file: invalid --warmup: " + e.to_string())
        }
        i += 2
      }
      "--file" => {
        if i + 1 >= args.length() {
          abort("bench-file: missing value for --file")
        }
        entry_path = Some(args[i + 1])
        i += 2
      }
      _ =>
        if entry_path is None {
          entry_path = Some(arg)
          i += 1
        } else {
          abort("bench-file: too many input files")
        }
    }
  }
  if count <= 0 {
    abort("bench-file: --n must be > 0")
  }
  if warmup < 0 {
    abort("bench-file: --warmup must be >= 0")
  }
  match entry_path {
    None => abort("bench-file: missing <file>")
    Some(path) => {
      let rt = @xsh_lib.Runtime::new(@capability.CapabilitySet::developer())
      for _ in 0..<warmup {
        let compiled = match compile_entry(path) {
          Err(err) => abort("bench-file: " + err)
          Ok(v) => v
        }
        let _ = rt.run_compiled(compiled) catch {
          e => abort("bench-file: " + e.to_string())
        }

      }
      let start = @env.now()
      for _ in 0..<count {
        let compiled = match compile_entry(path) {
          Err(err) => abort("bench-file: " + err)
          Ok(v) => v
        }
        let _ = rt.run_compiled(compiled) catch {
          e => abort("bench-file: " + e.to_string())
        }

      }
      let end = @env.now()
      let elapsed_ms = (end - start).to_double()
      let per_us = elapsed_ms * 1000.0 / count.to_double()
      if elapsed_ms <= 0.0 {
        println("bench-file: elapsed_ms=0; increase --n for measurable time")
      }
      println(
        "bench-file: file=\"" +
        path +
        "\" count=" +
        count.to_string() +
        " total_ms=" +
        elapsed_ms.to_string() +
        " per_us=" +
        per_us.to_string(),
      )
    }
  }
}

///|
struct OverlayRect {
  row : Int
  col : Int
  width : Int
  height : Int
}

///|
fn OverlayRect::eq(self : OverlayRect, other : OverlayRect) -> Bool {
  self.row == other.row &&
  self.col == other.col &&
  self.width == other.width &&
  self.height == other.height
}

///|
fn repl_cmd(args : Array[String]) -> Unit {
  if args.length() != 0 {
    abort("repl: no args supported")
  }
  let rt = @xsh_lib.Runtime::new(@capability.CapabilitySet::developer())
  let (initial_cols, initial_rows) = @tui.get_terminal_size()
  let (app, cleanup) = @tui.init_vnode_terminal(
    initial_cols, initial_rows, @tui.print_raw,
  )
  let width = Ref::new(initial_cols)
  let height = Ref::new(initial_rows)
  let outputs : Array[String] = []
  let history : Array[String] = []
  let xsh_names : Array[String] = @xsh_lib.prelude_names()
  let history_idx = Ref::new(-1)
  let history_draft = Ref::new("")
  let completion_session = @editor.CompletionSession::new()
  let completion_request_id : Ref[Int] = Ref::new(0)
  let last_popup_rect : Ref[OverlayRect?] = Ref::new(None)
  let completion_anchor : Ref[CompletionAnchor?] = Ref::new(None)
  let cleaned = Ref::new(false)
  fn cleanup_once() -> Unit {
    if cleaned.val {
      return
    }
    cleaned.val = true
    cleanup()
  }

  let input_rows = Ref::new(repl_input_rows_for_height(initial_rows))
  let input_editor = @editor.EditorState::new_with_kind(
    "",
    input_rows.val,
    @editor.HighlightKind::Plain,
  )
  fn set_input_text(text : String) -> Unit {
    input_editor.set_text("")
    if text.length() > 0 {
      input_editor.replace_selection(text)
    }
  }

  fn push_unique(list : Array[String], value : String) -> Unit {
    for existing in list {
      if existing == value {
        return
      }
    }
    list.push(value)
  }

  fn collect_shell_commands() -> Array[String] {
    let out : Array[String] = []
    match @sys.get_env_var("PATH") {
      None => ()
      Some(path) =>
        for dir_view in path.split(":") {
          let dir = dir_view.to_string()
          let entries = @os_fs.read_dir(dir) catch { _ => [] }
          for name in entries {
            let full_path = dir + "/" + name
            let is_file = @os_fs.is_file(full_path) catch { _ => false }
            if is_file {
              push_unique(out, name)
            }
          }
        }
    }
    out
  }

  let shell_commands = collect_shell_commands()
  let xsh_builtins = ["sh", "path", "addr", "exit"]
  let xsh_keywords = [
    "let", "rec", "if", "match", "do", "record", "test", "import", "alias", "flake",
    "true", "false",
  ]
  fn completion_visible() -> Bool {
    completion_session.is_visible() &&
    completion_session.get_items().length() > 0
  }

  fn current_view_state() -> ReplViewState {
    {
      width: width.val,
      height: height.val,
      input_rows: input_rows.val,
      outputs,
      history_len: history.length(),
    }
  }

  fn clear_rect(rect : OverlayRect) -> Unit {
    if rect.width <= 0 || rect.height <= 0 {
      return
    }
    let blank = " ".repeat(rect.width)
    for i = 0; i < rect.height; i = i + 1 {
      @tui.print_raw(@render.ansi_move_to(rect.row + i, rect.col) + blank)
    }
  }

  fn pad_to_width(text : String, width : Int) -> String {
    if width <= 0 {
      ""
    } else {
      let w = @core.string_display_width(text)
      if w >= width {
        text
      } else {
        text + " ".repeat(width - w)
      }
    }
  }

  fn completion_overlay(
    view : ReplViewState,
  ) -> (String?, OverlayRect?, CompletionAnchor?) {
    if not(completion_visible()) {
      return (None, None, None)
    }
    let items = completion_session.get_items()
    if items.length() == 0 {
      return (None, None, None)
    }
    let view_width = if view.width > 1 { view.width } else { 1 }
    let content_start = editor_content_start_col(input_editor)
    let screen_col = if content_start < view_width { content_start } else { 0 }
    let content_width = view_width - screen_col
    if content_width <= 1 {
      return (None, None, None)
    }
    let max_rows = 8
    let selected = completion_session.get_selected_index()
    let mut max_label_width = 0
    for item in items {
      let w = @core.string_display_width(item.label)
      if w > max_label_width {
        max_label_width = w
      }
    }
    let base_width = max_label_width + 1
    let cell_width = if base_width > content_width {
      content_width
    } else {
      base_width
    }
    if cell_width <= 0 {
      return (None, None, None)
    }
    let col_gap = 2
    let total_cell = cell_width + col_gap
    let cols = if total_cell <= content_width {
      let count = (content_width + col_gap) / total_cell
      if count > 0 {
        count
      } else {
        1
      }
    } else {
      1
    }
    let total_rows = (items.length() + cols - 1) / cols
    let preferred_rows = if total_rows > max_rows {
      max_rows
    } else {
      total_rows
    }
    if preferred_rows <= 0 {
      return (None, None, None)
    }
    let input_origin = repl_input_origin_row(view)
    let anchor_row = input_origin + view.input_rows - 1
    let available_below = view.height - footer_rows() - (anchor_row + 1)
    let available_above = anchor_row - header_rows()
    let anchor = pick_completion_anchor(
      completion_anchor.val,
      available_above,
      available_below,
    )
    let mut screen_row = 0
    let mut visible_rows = 0
    let mut chosen_anchor : CompletionAnchor? = None
    match anchor {
      Some(CompletionAnchor::Below) => {
        let v = if preferred_rows > available_below {
          available_below
        } else {
          preferred_rows
        }
        screen_row = anchor_row + 1
        visible_rows = v
        chosen_anchor = Some(CompletionAnchor::Below)
      }
      Some(CompletionAnchor::Above) => {
        let v = if preferred_rows > available_above {
          available_above
        } else {
          preferred_rows
        }
        screen_row = anchor_row - v
        visible_rows = v
        chosen_anchor = Some(CompletionAnchor::Above)
      }
      None => return (None, None, None)
    }
    if visible_rows <= 0 {
      return (None, None, None)
    }
    let selected_row = if selected >= 0 { selected / cols } else { 0 }
    let start_row = if total_rows <= visible_rows {
      0
    } else {
      let half = visible_rows / 2
      let s = selected_row - half
      if s < 0 {
        0
      } else if s + visible_rows > total_rows {
        total_rows - visible_rows
      } else {
        s
      }
    }
    let row_nodes : Array[@tui.TuiNode] = []
    let mut r = 0
    while r < visible_rows {
      let row_idx = start_row + r
      let cells : Array[@tui.TuiNode] = []
      let mut c = 0
      while c < cols {
        let idx = row_idx * cols + c
        let is_selected = idx == selected
        if idx < items.length() {
          let prefix = if is_selected { ">" } else { " " }
          let cell_text = pad_to_width(
            truncate_text(prefix + items[idx].label, cell_width),
            cell_width,
          )
          let fg = if is_selected { "white" } else { "rgb(170,170,170)" }
          cells.push(@tui.text(cell_text, fg~, bold=is_selected))
        } else {
          cells.push(@tui.text(" ".repeat(cell_width)))
        }
        if c < cols - 1 {
          cells.push(@tui.text(" ".repeat(col_gap), fg="rgb(90,90,90)"))
        }
        c += 1
      }
      row_nodes.push(@tui.row(cells))
      r += 1
    }
    let node = @tui.column(row_nodes)
    let overlay = @vnode.render_overlay_at(screen_col, screen_row, node)
    let rect : OverlayRect = {
      row: screen_row,
      col: screen_col,
      width: content_width,
      height: visible_rows,
    }
    (Some(overlay), Some(rect), chosen_anchor)
  }

  fn do_render() -> Unit {
    let view = current_view_state()
    let (overlay, next_rect, next_anchor) = completion_overlay(view)
    let mut need_clear = false
    match (last_popup_rect.val, next_rect) {
      (Some(prev), Some(next)) =>
        if not(prev.eq(next)) {
          clear_rect(prev)
          need_clear = true
        }
      (Some(prev), None) => {
        clear_rect(prev)
        need_clear = true
      }
      _ => ()
    }
    if need_clear {
      app.clear_prev_buffer()
    }
    @tui.print_raw(app.render_frame(render_repl_view(view, input_editor)))
    match overlay {
      Some(overlay_text) => @tui.print_raw(overlay_text)
      None => ()
    }
    last_popup_rect.val = next_rect
    completion_anchor.val = next_anchor
    let (cursor_row, cursor_col) = repl_cursor_pos(view, input_editor)
    @tui.print_raw(
      @render.ansi_move_to(cursor_row, cursor_col) + @render.ansi_show_cursor(),
    )
  }

  fn push_output_line(line : String) -> Unit {
    outputs.push(line)
  }

  fn run_command(cmd : String) -> Bool {
    let trimmed = cmd.trim().to_string()
    if trimmed.length() == 0 {
      return true
    }
    match trimmed {
      ":q" | ":quit" | ":exit" | "exit" => return false
      _ => ()
    }
    push_output_line("> " + trimmed)
    let result = rt.eval_script(trimmed) catch {
      e => {
        push_output_line("error: " + e.to_string())
        return true
      }
    }
    match result.last {
      Some(value) => push_output_line("last: " + value.to_string())
      None => ()
    }
    for effect in result.effects {
      push_output_line("effect: " + effect.to_string())
    }
    match extract_let_name(trimmed) {
      Some(name) => {
        push_unique(xsh_names, name)
        match rt.get_addr(name) {
          Some(addr) =>
            push_output_line("addr: " + name + "#" + short_hash(addr))
          None => ()
        }
      }
      None => ()
    }
    true
  }

  fn update_completion() -> Unit {
    let next_id = completion_request_id.val + 1
    completion_request_id.val = next_id
    let req = input_editor.completion_request(next_id)
    if is_in_fn_param_context(req.line_text, req.col) {
      completion_session.clear()
      return
    }
    let context = detect_completion_context(req.line_text, req.col)
    if req.prefix.length() == 0 {
      completion_session.clear()
      return
    }
    completion_session.set_request(req)
    let items : Array[String] = []
    match context {
      CompletionContext::Shell => {
        let mut idx = history.length() - 1
        while idx >= 0 {
          let entry = history[idx]
          if entry.has_prefix(req.prefix) {
            push_unique(items, entry)
          }
          idx -= 1
        }
        for item in shell_commands {
          if item.has_prefix(req.prefix) {
            push_unique(items, item)
          }
        }
      }
      CompletionContext::XshLetName =>
        for name in xsh_names {
          if name.has_prefix(req.prefix) {
            push_unique(items, name)
          }
        }
      CompletionContext::XshLetExpr | CompletionContext::XshExpr => {
        for item in xsh_keywords {
          if item.has_prefix(req.prefix) {
            push_unique(items, item)
          }
        }
        for item in xsh_builtins {
          if item.has_prefix(req.prefix) {
            push_unique(items, item)
          }
        }
        for name in xsh_names {
          if name.has_prefix(req.prefix) {
            push_unique(items, name)
          }
        }
      }
    }
    let response : @editor.CompletionResponse = {
      id: req.id,
      items: items.map(fn(item) {
        @editor.CompletionItem::{
          label: item,
          insert_text: item,
          detail: None,
          documentation: None,
        }
      }),
      is_incomplete: false,
    }
    let _ = completion_session.apply_response(response)
    if items.length() == 1 && items[0] == req.prefix {
      completion_session.hide()
    }
  }

  fn apply_completion() -> Bool {
    match completion_session.get_selected_item() {
      Some(item) => {
        input_editor.replace_current_word(item.insert_text)
        update_completion()
        true
      }
      None => false
    }
  }

  fn set_history_entry(idx : Int) -> Unit {
    let pos = history.length() - 1 - idx
    let value = history[pos]
    set_input_text(value)
  }

  fn history_prev() -> Unit {
    if history.length() == 0 {
      return
    }
    if history_idx.val == -1 {
      history_draft.val = input_editor.get_text()
    }
    if history_idx.val + 1 < history.length() {
      history_idx.val = history_idx.val + 1
      set_history_entry(history_idx.val)
    }
  }

  fn history_next() -> Unit {
    if history_idx.val <= 0 {
      if history_idx.val == 0 {
        history_idx.val = -1
        set_input_text(history_draft.val)
      }
      return
    }
    history_idx.val = history_idx.val - 1
    set_history_entry(history_idx.val)
  }

  fn handle_resize(new_width : Int, new_height : Int) -> Unit {
    width.val = new_width
    height.val = new_height
    app.resize(new_width, new_height)
    let next_rows = repl_input_rows_for_height(new_height)
    if next_rows != input_rows.val {
      input_rows.val = next_rows
      input_editor.set_height(next_rows)
    }
    do_render()
  }

  fn handle_key(input : String) -> Unit {
    if input.length() == 0 {
      return
    }
    if input.length() > 1 &&
      input[0].to_int() != 0x1b &&
      @tui.is_printable_string(input) {
      input_editor.replace_selection(input)
      history_idx.val = -1
      update_completion()
      do_render()
      return
    }
    let event = @tui.parse_input(input)
    if event.is_ctrl_c() {
      cleanup_once()
      return
    }
    match event {
      @tui.InputEvent::Resize(new_width, new_height) => {
        handle_resize(new_width, new_height)
        return
      }
      @tui.InputEvent::Key(key_event) => {
        let mut should_update_completion = false
        match key_event {
          @tui.KeyEvent::Special(@tui.SpecialKey::Up, _) =>
            if completion_visible() {
              completion_session.select_prev()
              do_render()
              return
            } else {
              history_prev()
              update_completion()
              do_render()
              return
            }
          @tui.KeyEvent::Special(@tui.SpecialKey::Down, _) =>
            if completion_visible() {
              completion_session.select_next()
              do_render()
              return
            } else {
              history_next()
              update_completion()
              do_render()
              return
            }
          @tui.KeyEvent::Special(@tui.SpecialKey::Tab, _) => {
            if completion_visible() {
              if apply_completion() {
                do_render()
                return
              }
            } else {
              update_completion()
            }
            do_render()
            return
          }
          @tui.KeyEvent::Special(@tui.SpecialKey::BackTab, _) => {
            if completion_visible() {
              completion_session.select_prev()
            }
            do_render()
            return
          }
          @tui.KeyEvent::Special(@tui.SpecialKey::Enter, _) => {
            if completion_visible() && apply_completion() {
              do_render()
              return
            }
            let ok = run_command(input_editor.get_text())
            if !ok {
              cleanup_once()
              return
            }
            let input_value = input_editor.get_text().trim().to_string()
            if input_value.length() > 0 {
              history.push(input_value)
            }
            set_input_text("")
            history_idx.val = -1
            update_completion()
            do_render()
            return
          }
          @tui.KeyEvent::Special(@tui.SpecialKey::Escape, _) => {
            completion_session.hide()
            do_render()
            return
          }
          @tui.KeyEvent::Special(@tui.SpecialKey::Backspace, _) =>
            should_update_completion = true
          @tui.KeyEvent::Char(_, @tui.KeyModifier::None)
          | @tui.KeyEvent::Char(_, @tui.KeyModifier::Shift) =>
            should_update_completion = true
          _ => ()
        }
        @editor.handle_key_event(input_editor, key_event)
        if should_update_completion {
          update_completion()
        }
        history_idx.val = -1
        do_render()
      }
      _ => ()
    }
  }

  do_render()
  @tui.start_keypress_listener(handle_key)
  cleanup_once()
}

///|
fn repl_stdin_cmd(args : Array[String]) -> Unit {
  let mut prompt_enabled = true
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--no-prompt" => {
        prompt_enabled = false
        i += 1
      }
      _ => abort("repl-stdin: unknown arg " + arg)
    }
  }
  async fn repl_loop() {
    let prompt = "xsh> "
    let rt = @xsh_lib.Runtime::new(@capability.CapabilitySet::developer())
    let input = @stdio.stdin
    if prompt_enabled {
      @stdio.stdout.write(prompt)
    }
    while input.read_until("\n") is Some(line) {
      let trimmed = line.trim()
      if trimmed.is_empty() {
        if prompt_enabled {
          @stdio.stdout.write(prompt)
        }
        continue
      }
      let line_str = trimmed.to_string()
      match line_str {
        ":q" | ":quit" | ":exit" | "exit" => break
        _ => {
          let result = rt.eval_script(line_str) catch {
            e => {
              println("error: " + e.to_string())
              if prompt_enabled {
                @stdio.stdout.write(prompt)
              }
              continue
            }
          }
          print_eval_result(result)
          match extract_let_name(line_str) {
            Some(name) =>
              match rt.get_addr(name) {
                Some(addr) => println("addr: " + name + "#" + short_hash(addr))
                None => ()
              }
            None => ()
          }
        }
      }
      if prompt_enabled {
        @stdio.stdout.write(prompt)
      }
    }
  }

  @async.run_async_main(repl_loop)
}

///|
fn print_eval_result(result : @xsh_lib.EvalResult) -> Unit {
  match result.last {
    Some(value) => println("last: " + value.to_string())
    None => ()
  }
  for effect in result.effects {
    println("effect: " + effect.to_string())
  }
}

///|
fn print_test_report(path : String, report : @xsh_lib.TestReport) -> Bool {
  let status = if report.failed == 0 { "ok" } else { "fail" }
  println("\{path}: \{status} (\{report.passed}/\{report.total})")
  if report.failed > 0 {
    for failure in report.failures {
      let name = match failure.name {
        Some(n) => n
        None => "<unnamed>"
      }
      println("  - " + name + ": " + failure.error)
    }
  }
  println("report: " + report.to_string())
  report.failed == 0
}

///|
fn compile_entry(
  entry_path : String,
) -> Result[@xsh_lib.CompiledModule, String] {
  match load_db(entry_path) {
    Err(err) => Err(err)
    Ok((db, entry)) => {
      let compiled = @xsh_lib.compile_module(db, entry) catch {
        e => return Err(e.to_string())
      }
      Ok(compiled)
    }
  }
}

///|
fn load_db(entry_path : String) -> Result[(@xsh_lib.XshDb, String), String] {
  let db = @xsh_lib.XshDb::new()
  let visited : Map[String, Bool] = {}
  let entry = resolve_entry_path(entry_path)
  match load_sources_recursive(db, entry, visited) {
    Ok(_) => Ok((db, entry))
    Err(err) => Err(err)
  }
}

///|
fn resolve_entry_path(path : String) -> String {
  if path.has_prefix("/") {
    @xsh_fs.normalize_path(path)
  } else {
    let cwd = match @env.current_dir() {
      Some(dir) => dir
      None => "/"
    }
    @xsh_fs.normalize_path(cwd + "/" + path)
  }
}

///|
fn load_sources_recursive(
  db : @xsh_lib.XshDb,
  path : String,
  visited : Map[String, Bool],
) -> Result[Unit, String] {
  let norm = @xsh_fs.normalize_path(path)
  if visited.contains(norm) {
    return Ok(())
  }
  visited.set(norm, true)
  let source = @os_fs.read_file_to_string(norm) catch {
    e => return Err("io: " + e.to_string())
  }
  db.set_source(norm, source)
  let ast = @xsh_lib.parse_ast(source) catch {
    e => return Err("parse: " + e.to_string())
  }
  let base = @xsh_fs.parent_path(norm)
  for stmt in ast.stmts {
    match stmt {
      @xsh_lib.Stmt::Import(path~) => {
        let resolved = resolve_import_path(base, path)
        match load_sources_recursive(db, resolved, visited) {
          Ok(_) => ()
          Err(err) => return Err(err)
        }
      }
      _ => ()
    }
  }
  Ok(())
}

///|
fn resolve_import_path(base : String, import_path : String) -> String {
  if import_path.has_prefix("/") {
    @xsh_fs.normalize_path(import_path)
  } else {
    @xsh_fs.normalize_path(base + "/" + import_path)
  }
}
