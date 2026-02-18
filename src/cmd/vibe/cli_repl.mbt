///|
fn repl_cmd(
  args : Array[String],
  syntax_mode : @runtime.ParserMode,
  features : @runtime.RuntimeFeatureFlags,
  enable_llm~ : Bool,
) -> Unit {
  if args.length() != 0 {
    abort("shell: no args supported")
  }
  let rt = new_cli_runtime(features, enable_llm~)
  let (namespace_name, scratch_db_path) = match resolve_scratch_db_path() {
    Ok(v) => v
    Err(err) => abort("shell: " + err)
  }
  let restored_source = match load_eval_db_source(scratch_db_path) {
    Ok(v) => v
    Err(err) => abort("shell: " + err)
  }
  let mut restore_error : String = ""
  if restored_source.trim().length() > 0 {
    try rt.eval_script_with_mode(restored_source, syntax_mode) |> ignore catch {
      e => restore_error = e.to_string()
    }
  }
  let (initial_cols, initial_rows) = @tui.get_terminal_size()
  let (app, cleanup) = @tui.init_vnode_terminal(
    initial_cols, initial_rows, @tui.print_raw,
  )
  let width = Ref::new(initial_cols)
  let height = Ref::new(initial_rows)
  let outputs : Array[String] = []
  let history : Array[String] = []
  let vibe_names : Array[String] = @checker.prelude_names()
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
  let scratch_source_ref = Ref::new(restored_source)
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
  let vibe_builtins = ["sh", "path", "addr", "exit"]
  let vibe_keywords = [
    "let", "rec", "if", "match", "do", "record", "test", "import", "true", "false",
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
    let result = rt.eval_script_with_mode(trimmed, syntax_mode) catch {
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
      match effect {
        @runtime.Effect::PosixDesugar(message) =>
          push_output_line("note: " + message)
        _ => push_output_line("effect: " + effect.to_string())
      }
    }
    scratch_source_ref.val = append_eval_db_source(
      scratch_source_ref.val,
      trimmed,
    )
    match write_eval_db_source(scratch_db_path, scratch_source_ref.val) {
      Ok(_) => ()
      Err(err) => {
        push_output_line("error: failed to persist namespace db: " + err)
        return true
      }
    }
    match extract_let_name(trimmed) {
      Some(name) => {
        push_unique(vibe_names, name)
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
    let method_info = detect_method_completion(req.line_text, req.col)
    let pipe_info = detect_pipe_completion(req.line_text, req.col)
    let prefix = match method_info {
      Some(info) => info.prefix
      None =>
        match pipe_info {
          Some(info) => info.prefix
          None => req.prefix
        }
    }
    let receiver_name = match method_info {
      Some(info) => Some(info.receiver)
      None =>
        match pipe_info {
          Some(info) => Some(info.receiver)
          None => None
        }
    }
    let env = rt.type_env()
    let receiver_ty = match receiver_name {
      Some(name) => env.get(name)
      None => None
    }
    fn accepts_receiver(name : String) -> Bool {
      match receiver_ty {
        None => true
        Some(rty) =>
          match env.get(name) {
            Some(@vibe_core.Type::Func(params~, ..)) => {
              let mut found = false
              let mut ok = false
              for param in params {
                if @vibe_core.ParamLabel::is_positional(param.label) {
                  found = true
                  ok = @checker.completion_param_matches(env, rty, param.ty)
                  break
                }
              }
              found && ok
            }
            _ => false
          }
      }
    }

    let method_like = method_info is Some(_) || pipe_info is Some(_)
    if prefix.length() == 0 && not(method_like) {
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
          if entry.has_prefix(prefix) {
            push_unique(items, entry)
          }
          idx -= 1
        }
        for item in shell_commands {
          if item.has_prefix(prefix) {
            push_unique(items, item)
          }
        }
      }
      CompletionContext::XshLetName =>
        for name in vibe_names {
          if name.has_prefix(prefix) {
            push_unique(items, name)
          }
        }
      CompletionContext::XshLetExpr | CompletionContext::XshExpr => {
        if not(method_like) {
          for item in vibe_keywords {
            if item.has_prefix(prefix) {
              push_unique(items, item)
            }
          }
        }
        for item in vibe_builtins {
          if item.has_prefix(prefix) && accepts_receiver(item) {
            push_unique(items, item)
          }
        }
        for name in vibe_names {
          if name.has_prefix(prefix) && accepts_receiver(name) {
            push_unique(items, name)
          }
        }
      }
    }
    let response : @editor.CompletionResponse = {
      id: req.id,
      items: items.map(fn(item) {
        let insert_text = match method_info {
          Some(info) =>
            if req.prefix.contains(".") {
              info.receiver + "." + item
            } else {
              item
            }
          None => item
        }
        @editor.CompletionItem::{
          label: item,
          insert_text,
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
  push_output_line("namespace: " + namespace_name + " db=" + scratch_db_path)
  if restore_error.length() > 0 {
    push_output_line("warn: failed to restore db: " + restore_error)
  }
  do_render()
  @tui.start_keypress_listener(handle_key)
  cleanup_once()
}

///|
fn repl_stdin_cmd(
  args : Array[String],
  syntax_mode : @runtime.ParserMode,
  features : @runtime.RuntimeFeatureFlags,
  enable_llm~ : Bool,
) -> Unit {
  run_eval_line_repl_with_prompt(
    args,
    "shell-stdin",
    "vibe> ",
    syntax_mode,
    features,
    enable_llm~,
  )
}

///|
fn repl_wasi_cmd(
  args : Array[String],
  syntax_mode : @runtime.ParserMode,
  features : @runtime.RuntimeFeatureFlags,
  enable_llm~ : Bool,
) -> Unit {
  run_eval_line_repl_with_prompt(
    args,
    "shell-wasi",
    "wasi> ",
    syntax_mode,
    features,
    enable_llm~,
  )
}

///|
fn print_line_repl_tty_mode(mode : LineReplIoMode) -> Unit {
  match mode {
    LineReplIoMode::Tty =>
      println(
        "note: --tty mode is enabled (line backend; PTY is not enabled yet)",
      )
    LineReplIoMode::Plain => ()
  }
}

///|
fn run_eval_line_repl_with_prompt(
  args : Array[String],
  cmd_name : String,
  prompt : String,
  syntax_mode : @runtime.ParserMode,
  features : @runtime.RuntimeFeatureFlags,
  enable_llm~ : Bool,
) -> Unit {
  let options = match parse_line_repl_options(args, cmd_name, prompt) {
    Ok(opts) => opts
    Err(msg) => abort(msg)
  }
  let (namespace_name, scratch_db_path) = match resolve_scratch_db_path() {
    Ok(v) => v
    Err(err) => abort(cmd_name + ": " + err)
  }
  async fn repl_loop() {
    let rt = new_cli_runtime(features, enable_llm~)
    let mut scratch_source = match load_eval_db_source(scratch_db_path) {
      Ok(v) => v
      Err(err) => {
        println("error: " + err)
        return
      }
    }
    if scratch_source.trim().length() > 0 {
      try
        rt.eval_script_with_mode(scratch_source, syntax_mode) |> ignore
      catch {
        e => println("warn: failed to restore db: " + e.to_string())
      }
    }
    let input = @stdio.stdin
    print_line_repl_tty_mode(options.io_mode)
    println("namespace: " + namespace_name + " db=" + scratch_db_path)
    if options.prompt_enabled {
      @stdio.stdout.write(options.prompt)
    }
    while input.read_until("\n") is Some(line) {
      let trimmed = line.trim()
      if trimmed.is_empty() {
        if options.prompt_enabled {
          @stdio.stdout.write(options.prompt)
        }
        continue
      }
      let line_str = trimmed.to_string()
      match line_str {
        ":q" | ":quit" | ":exit" | "exit" => break
        _ => {
          let result = rt.eval_script_with_mode(line_str, syntax_mode) catch {
            e => {
              println("error: " + e.to_string())
              if options.prompt_enabled {
                @stdio.stdout.write(options.prompt)
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
          scratch_source = append_eval_db_source(scratch_source, line_str)
          match write_eval_db_source(scratch_db_path, scratch_source) {
            Ok(_) => ()
            Err(err) => println("error: failed to persist namespace db: " + err)
          }
        }
      }
      if options.prompt_enabled {
        @stdio.stdout.write(options.prompt)
      }
    }
  }

  @async.run_async_main(repl_loop)
}

///|
/// WASM REPL: compile each expression to WASM and output to file
fn wasm_repl_stdin_cmd(args : Array[String]) -> Unit {
  let mut prompt_enabled = true
  let mut out_dir = "/tmp"
  let mut counter = 0
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--no-prompt" => {
        prompt_enabled = false
        i += 1
      }
      "-o" | "--out-dir" => {
        if i + 1 >= args.length() {
          abort("wasm-shell-stdin: missing output directory after " + arg)
        }
        out_dir = args[i + 1]
        i += 2
      }
      _ => abort("wasm-shell-stdin: unknown arg " + arg)
    }
  }
  // Ensure output directory exists
  if not(@os_fs.path_exists(out_dir)) {
    @os_fs.create_dir(out_dir) catch {
      e =>
        abort("wasm-shell-stdin: failed to create output dir: " + e.to_string())
    }
  }
  async fn repl_loop() {
    let prompt = "wasm> "
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
          // Create a temporary source for compilation
          let db = @runtime.VibeDb::new()
          let tmp_path = "/tmp/wasm_repl_" + counter.to_string() + ".vibe"
          db.set_source(tmp_path, line_str)
          // Compile to WASM
          let wasm_bytes = @runtime_compile.compile_module_wasm(db, tmp_path) catch {
            e => {
              println("error: " + e.to_string())
              if prompt_enabled {
                @stdio.stdout.write(prompt)
              }
              continue
            }
          }
          // Write WASM to file
          let out_path = out_dir + "/expr_" + counter.to_string() + ".wasm"
          @os_fs.write_bytes_to_file(out_path, wasm_bytes) catch {
            e => {
              println("error writing file: " + e.to_string())
              if prompt_enabled {
                @stdio.stdout.write(prompt)
              }
              continue
            }
          }
          println(
            "wrote " +
            out_path +
            " (" +
            wasm_bytes.length().to_string() +
            " bytes)",
          )
          counter += 1
        }
      }
      if prompt_enabled {
        @stdio.stdout.write(prompt)
      }
    }
  }

  @async.run_async_main(repl_loop)
}
