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
pub struct CliRuntimeArgs {
  syntax_mode : @xsh_lib.ParserMode
  cmd_args : Array[String]
  unstable_async : Bool
  unstable_threads : Bool
} derive(Show, Eq)

///|
pub struct CliDispatchArgs {
  cmd : String
  syntax_mode : @xsh_lib.ParserMode
  cmd_args : Array[String]
  unstable_async : Bool
  unstable_threads : Bool
} derive(Show, Eq)

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
pub fn parse_cli_runtime_args(
  args : Array[String],
  cmd_name : String,
) -> Result[CliRuntimeArgs, String] {
  let filtered : Array[String] = []
  let mut unstable_async = false
  let mut unstable_threads = false
  for arg in args {
    match arg {
      "--unstable-async" => unstable_async = true
      "--unstable-threads" => unstable_threads = true
      _ => filtered.push(arg)
    }
  }
  match parse_cli_syntax_args(filtered, cmd_name) {
    Ok((syntax_mode, cmd_args)) =>
      Ok({ syntax_mode, cmd_args, unstable_async, unstable_threads })
    Err(err) => Err(err)
  }
}

///|
fn cli_args_tail(args : Array[String], start : Int) -> Array[String] {
  let out : Array[String] = []
  for i in start..<args.length() {
    out.push(args[i])
  }
  out
}

///|
pub fn parse_cli_dispatch_args(args : Array[String]) -> Result[CliDispatchArgs, String] {
  if args.length() <= 1 {
    return Err("missing command")
  }
  let mut global_unstable_async = false
  let mut global_unstable_threads = false
  let mut cmd_index = 1
  while cmd_index < args.length() {
    match args[cmd_index] {
      "--unstable-async" => {
        global_unstable_async = true
        cmd_index += 1
      }
      "--unstable-threads" => {
        global_unstable_threads = true
        cmd_index += 1
      }
      _ => break
    }
  }
  if cmd_index >= args.length() {
    return Err("missing command")
  }
  let cmd = args[cmd_index]
  let raw_cmd_args = cli_args_tail(args, cmd_index + 1)
  match parse_cli_runtime_args(raw_cmd_args, cmd) {
    Ok(cli_args) =>
      Ok({
        cmd,
        syntax_mode: cli_args.syntax_mode,
        cmd_args: cli_args.cmd_args,
        unstable_async: cli_args.unstable_async || global_unstable_async,
        unstable_threads: cli_args.unstable_threads || global_unstable_threads,
      })
    Err(err) => Err(err)
  }
}

///|
pub fn ensure_cli_parser_mode_supported(
  mode : @xsh_lib.ParserMode,
  cmd_name : String,
) -> Result[Unit, String] {
  match mode {
    @xsh_lib.ParserMode::XshMode => Ok(())
    @xsh_lib.ParserMode::PosixMode =>
      match cmd_name {
        "run" | "repl" | "repl-stdin" | "repl-wasi" | "bench" => Ok(())
        _ =>
          Err(
            cmd_name +
            ": --syntax posix is supported only for run/repl/repl-stdin/repl-wasi/bench",
          )
      }
  }
}
