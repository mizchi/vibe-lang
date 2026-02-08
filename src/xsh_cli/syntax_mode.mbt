///|
fn parse_cli_syntax_mode(
  value : String,
  cmd_name : String,
) -> Result[@xsh_lib.ParserMode, String] {
  match value {
    "xsh" => Ok(@xsh_lib.ParserMode::XshMode)
    "posix" => Ok(@xsh_lib.ParserMode::PosixMode)
    _ =>
      Err(
        cmd_name + ": unsupported syntax `" + value + "` (expected: xsh|posix)",
      )
  }
}

///|
pub fn parse_cli_syntax_args(
  args : Array[String],
  cmd_name : String,
) -> Result[(@xsh_lib.ParserMode, Array[String]), String] {
  let mut mode = @xsh_lib.ParserMode::XshMode
  let rest : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if arg == "--syntax" {
      if i + 1 >= args.length() {
        return Err(
          cmd_name + ": missing value for --syntax (expected: xsh|posix)",
        )
      }
      match parse_cli_syntax_mode(args[i + 1], cmd_name) {
        Ok(next) => mode = next
        Err(err) => return Err(err)
      }
      i += 2
      continue
    }
    if arg.has_prefix("--syntax=") {
      let value = arg.unsafe_substring(start=9, end=arg.length())
      match parse_cli_syntax_mode(value, cmd_name) {
        Ok(next) => mode = next
        Err(err) => return Err(err)
      }
      i += 1
      continue
    }
    rest.push(arg)
    i += 1
  }
  Ok((mode, rest))
}

///|
pub fn ensure_cli_parser_mode_supported(
  mode : @xsh_lib.ParserMode,
  cmd_name : String,
) -> Result[Unit, String] {
  match mode {
    @xsh_lib.ParserMode::XshMode => Ok(())
    @xsh_lib.ParserMode::PosixMode =>
      Err(cmd_name + ": --syntax posix is not implemented yet")
  }
}
