///|
fn clamp_module_source_offset(source : String, offset : Int) -> Int {
  if offset < 0 {
    0
  } else if offset > source.length() {
    source.length()
  } else {
    offset
  }
}

///|
fn module_source_slice_by_span(
  source : String,
  start : Int,
  end : Int,
) -> String {
  let s = clamp_module_source_offset(source, start)
  let e = clamp_module_source_offset(source, end)
  let stop = if e < s { s } else { e }
  if stop <= s {
    return ""
  }
  source[s:stop].to_string()
}

///|
fn module_source_stmt_upper_bound(
  source : String,
  original_stmts : Array[@vibe_core.Stmt],
  stmt : @vibe_core.Stmt,
) -> Int {
  let span = stmt.span()
  let fallback_end = clamp_module_source_offset(source, span.end)
  let limit = fallback_end
  let target_start = span.start
  let mut i = 0
  while i < original_stmts.length() {
    let current = original_stmts[i]
    let current_span = current.span()
    if current_span.start == target_start {
      if i + 1 < original_stmts.length() {
        let next_start = clamp_module_source_offset(
          source,
          original_stmts[i + 1].span().start,
        )
        return if next_start < limit { next_start } else { limit }
      }
      return limit
    }
    i = i + 1
  }
  limit
}

///|
fn module_source_from_selected_stmt_spans(
  source : String,
  original_stmts : Array[@vibe_core.Stmt],
  stmts : Array[@vibe_core.Stmt],
) -> String {
  let out = StringBuilder::new()
  for stmt in stmts {
    let span = stmt.span()
    let end = module_source_stmt_upper_bound(source, original_stmts, stmt)
    let snippet = module_source_slice_by_span(source, span.start, end)
    if snippet.length() == 0 {
      continue
    }
    out.write_string(snippet)
    if not(snippet.has_suffix("\n")) {
      out.write_char('\n')
    }
  }
  out.to_string()
}

///|
pub fn build_module_source_from_source(
  source : String,
  entry_name : String,
) -> Result[String, String] {
  let ast = @parser.parse_ast(source) catch {
    e => return Err("parse error: " + e.to_string())
  }
  let pruned = @frontend.dce_module_with_entry_names(ast, [entry_name])
  Ok(module_source_from_selected_stmt_spans(source, ast.stmts, pruned.stmts))
}

///|
pub fn emit_module_source_file(
  input_path : String,
  output_path : String,
  entry_name : String,
  fs : &@io.FileSystemAdapter,
) -> Result[Unit, String] {
  let source = match @io.read_string_with(fs, input_path) {
    Ok(v) => v
    Err(err) => return Err("read failed: " + err)
  }
  let module_source = match
    build_module_source_from_source(source, entry_name) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  match @io.write_string_with(fs, output_path, module_source) {
    Ok(_) => Ok(())
    Err(err) => Err("write failed: " + err)
  }
}
