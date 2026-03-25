///|
struct FmtCmdOptions {
  dry_run : Bool
  files : Array[String]
} derive(Show, Eq)

///|
pub fn parse_fmt_cmd_options(
  args : Array[String],
) -> Result[FmtCmdOptions, String] {
  if args.length() == 0 {
    return Err("fmt: expected [--dry-run] <file...>")
  }
  let mut dry_run = false
  let files : Array[String] = []
  for arg in args {
    match arg {
      "--dry-run" => dry_run = true
      "--write" | "-w" => ()
      _ => {
        if arg.has_prefix("--") {
          return Err("fmt: unknown option " + arg)
        }
        files.push(arg)
      }
    }
  }
  if files.length() == 0 {
    return Err("fmt: expected [--dry-run] <file...>")
  }
  Ok({ dry_run, files })
}

///|
fn source_to_diff_lines(source : String) -> Array[String] {
  let lines : Array[String] = []
  if source.length() == 0 {
    return lines
  }
  for line_view in source.split("\n") {
    lines.push(line_view.to_string())
  }
  if source.has_suffix("\n") && lines.length() > 0 {
    let _ = lines.pop()
  } else {
    lines.push("\\ No newline at end of file")
  }
  lines
}

///|
pub fn render_fmt_dry_run_diff(
  path : String,
  before : String,
  after : String,
) -> String {
  if before == after {
    return ""
  }
  let before_lines = source_to_diff_lines(before)
  let after_lines = source_to_diff_lines(after)
  let buf = StringBuilder::new()
  buf.write_string("--- " + path + "\n")
  buf.write_string("+++ " + path + "\n")
  let mut before_i = 0
  let mut after_i = 0
  while before_i < before_lines.length() || after_i < after_lines.length() {
    if before_i < before_lines.length() &&
      after_i < after_lines.length() &&
      before_lines[before_i] == after_lines[after_i] {
      before_i += 1
      after_i += 1
      continue
    }
    if before_i < before_lines.length() {
      let remove_line = if after_i >= after_lines.length() {
        true
      } else if before_i + 1 < before_lines.length() {
        before_lines[before_i + 1] == after_lines[after_i]
      } else {
        false
      }
      if remove_line {
        buf.write_char('-')
        buf.write_string(before_lines[before_i])
        buf.write_char('\n')
        before_i += 1
        continue
      }
    }
    if after_i < after_lines.length() {
      let add_line = if before_i >= before_lines.length() {
        true
      } else if after_i + 1 < after_lines.length() {
        before_lines[before_i] == after_lines[after_i + 1]
      } else {
        false
      }
      if add_line {
        buf.write_char('+')
        buf.write_string(after_lines[after_i])
        buf.write_char('\n')
        after_i += 1
        continue
      }
    }
    if before_i < before_lines.length() {
      buf.write_char('-')
      buf.write_string(before_lines[before_i])
      buf.write_char('\n')
      before_i += 1
    }
    if after_i < after_lines.length() {
      buf.write_char('+')
      buf.write_string(after_lines[after_i])
      buf.write_char('\n')
      after_i += 1
    }
  }
  buf.to_string()
}
