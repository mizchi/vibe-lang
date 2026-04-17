///|
/// Line-based shell I/O mode.
/// `Tty` is a capability marker for future raw-mode/backspace/arrow handling.
pub enum LineReplIoMode {
  Plain
  Tty
}

///|
pub struct LineReplOptions {
  prompt : String
  prompt_enabled : Bool
  io_mode : LineReplIoMode
  restore_namespace : Bool
}

///|
fn line_repl_usage(cmd_name : String) -> String {
  "usage: " + cmd_name + " [--no-prompt] [--tty|--no-tty] [--restore]"
}

///|
pub fn parse_line_repl_options(
  args : Array[String],
  cmd_name : String,
  prompt : String,
) -> Result[LineReplOptions, String] {
  let mut prompt_enabled = true
  let mut io_mode = LineReplIoMode::Plain
  let mut restore_namespace = false
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--help" | "-h" => return Err(line_repl_usage(cmd_name))
      "--no-prompt" => {
        prompt_enabled = false
        i += 1
      }
      "--tty" => {
        io_mode = LineReplIoMode::Tty
        i += 1
      }
      "--no-tty" => {
        io_mode = LineReplIoMode::Plain
        i += 1
      }
      "--restore" => {
        restore_namespace = true
        i += 1
      }
      _ => return Err(cmd_name + ": unknown arg " + arg)
    }
  }
  Ok({ prompt, prompt_enabled, io_mode, restore_namespace })
}

///|
pub fn extract_let_name_line(line : String) -> String? {
  let t = line.trim()
  if not(t.has_prefix("let ")) {
    return None
  }
  let mut rest = t[4:].trim().to_string()
  if rest.has_prefix("rec ") {
    rest = rest[4:].trim().to_string()
  }
  let out = StringBuilder::new()
  for _, c in rest {
    if c == ' ' || c == '=' || c == ':' || c == '(' {
      break
    }
    out.write_char(c)
  }
  let name = out.to_string().trim().to_string()
  if name.length() == 0 {
    None
  } else {
    Some(name)
  }
}
