///|
pub(all) struct LineCol {
  line : Int
  column : Int
} derive(Debug, Eq)

///|
fn clamp_offset(source : String, offset : Int) -> Int {
  if offset < 0 {
    0
  } else if offset > source.length() {
    source.length()
  } else {
    offset
  }
}

///|
pub fn line_info(source : String, offset : Int) -> (LineCol, Int, Int) {
  let off = clamp_offset(source, offset)
  let mut i = 0
  let mut line = 1
  let mut col = 1
  let mut line_start = 0
  while i < off && i < source.length() {
    let c = source[i].to_int().unsafe_to_char()
    if c == '\n' {
      line += 1
      col = 1
      line_start = i + 1
    } else {
      col += 1
    }
    i += 1
  }
  let mut line_end = line_start
  while line_end < source.length() {
    let c = source[line_end].to_int().unsafe_to_char()
    if c == '\n' {
      break
    }
    line_end += 1
  }
  (LineCol::{ line, column: col }, line_start, line_end)
}

///|
/// Precomputed line-start offsets for a source string.
///
/// Building the index is a single O(N) scan; subsequent `line_info`
/// lookups are O(log N) via binary search. Callers that need to render
/// many diagnostics against the same source — the warnings loop in
/// `vibe check`, e.g. — should build one `LineIndex` per file and reuse
/// it for every render, avoiding the O(N²) blowup of the standalone
/// `line_info` (which walks `source` from offset 0 on each call).
pub(all) struct LineIndex {
  source : String
  // `line_starts[i]` is the byte offset of the start of line `i+1`
  // (1-based line numbers; `line_starts[0] == 0`).
  line_starts : Array[Int]
}

///|
pub fn LineIndex::build(source : String) -> LineIndex {
  let line_starts : Array[Int] = [0]
  let len = source.length()
  let mut i = 0
  while i < len {
    if source[i].to_int().unsafe_to_char() == '\n' {
      line_starts.push(i + 1)
    }
    i += 1
  }
  { source, line_starts }
}

///|
/// Find the index of the line containing `offset` via binary search on
/// `line_starts`. Returns the 0-based line index.
fn LineIndex::line_index_for_offset(self : LineIndex, offset : Int) -> Int {
  let starts = self.line_starts
  let mut lo = 0
  let mut hi = starts.length() - 1
  while lo < hi {
    let mid = (lo + hi + 1) / 2
    if starts[mid] <= offset {
      lo = mid
    } else {
      hi = mid - 1
    }
  }
  lo
}

///|
pub fn LineIndex::line_info(
  self : LineIndex,
  offset : Int,
) -> (LineCol, Int, Int) {
  let off = clamp_offset(self.source, offset)
  let idx = self.line_index_for_offset(off)
  let line_start = self.line_starts[idx]
  let line_end = if idx + 1 < self.line_starts.length() {
    // -1 to exclude the '\n' that begins the next line.
    self.line_starts[idx + 1] - 1
  } else {
    self.source.length()
  }
  let line = idx + 1
  let column = off - line_start + 1
  (LineCol::{ line, column }, line_start, line_end)
}

///|
fn repeat_char(c : Char, count : Int) -> String {
  let buf = StringBuilder::new()
  let mut i = 0
  while i < count {
    buf.write_char(c)
    i += 1
  }
  buf.to_string()
}

///|
pub fn render_snippet(source : String, span : Span) -> String {
  render_snippet_with_index(LineIndex::build(source), span)
}

///|
/// `render_snippet` variant that reuses a precomputed `LineIndex`.
/// Use this when rendering many diagnostics against the same source —
/// `render_snippet`'s ad-hoc `LineIndex::build` would otherwise rescan
/// the whole source for every call (the original O(N²) culprit in
/// `vibe check` on files with thousands of warnings).
pub fn render_snippet_with_index(index : LineIndex, span : Span) -> String {
  let (pos, line_start, line_end) = index.line_info(span.start)
  let line_text = index.source[line_start:line_end].to_string()
  if line_text.length() == 0 {
    return ""
  }
  let caret_len = {
    let len = span.end - span.start
    if len <= 0 {
      1
    } else {
      len
    }
  }
  let caret_prefix = repeat_char(' ', pos.column - 1)
  let caret_body = repeat_char('~', caret_len - 1)
  let caret_line = caret_prefix + "^" + caret_body
  line_text + "\n" + caret_line
}

///|
pub fn Diagnostic::render(
  self : Diagnostic,
  path : String,
  source : String,
) -> String {
  self.render_with_index(path, LineIndex::build(source))
}

///|
/// `Diagnostic::render` variant that reuses a precomputed `LineIndex`.
///
/// Use this in tight loops that render many diagnostics for the same
/// source — `vibe check`'s warnings/diagnostics loop is the original
/// example: 16k unused-variable warnings × O(N) `line_info` walk gave
/// O(N²) (≈8 s of unaccounted "render" time on a 16 k-decl file). With
/// the index, each render is O(log N).
pub fn Diagnostic::render_with_index(
  self : Diagnostic,
  path : String,
  index : LineIndex,
) -> String {
  let buf = StringBuilder::new()
  match self.span {
    Some(span) => {
      let (pos, _, _) = index.line_info(span.start)
      buf.write_string(
        path +
        ":" +
        pos.line.to_string() +
        ":" +
        pos.column.to_string() +
        ": " +
        self.stage +
        ": " +
        self.message,
      )
      let snippet = render_snippet_with_index(index, span)
      if snippet.length() > 0 {
        buf.write_string("\n" + snippet)
      }
    }
    None => buf.write_string(path + ": " + self.stage + ": " + self.message)
  }
  match self.hint {
    Some(h) => buf.write_string("\nhelp: " + h)
    None => ()
  }
  match self.note {
    Some(n) => buf.write_string("\nnote: " + n)
    None => ()
  }
  buf.to_string()
}
