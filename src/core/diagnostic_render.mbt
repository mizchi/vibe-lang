///|
pub(all) struct LineCol {
  line : Int
  column : Int
} derive(Show, Eq)

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
  let (pos, line_start, line_end) = line_info(source, span.start)
  let line_text = source[line_start:line_end].to_string()
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
  let buf = StringBuilder::new()
  match self.span {
    Some(span) => {
      let (pos, _, _) = line_info(source, span.start)
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
      let snippet = render_snippet(source, span)
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
