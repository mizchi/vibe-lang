///|
fn parse_cli_syntax_mode(
  value : String,
  cmd_name : String,
) -> Result[@runtime.ParserMode, String] {
  match value {
    "vibe" => Ok(@runtime.ParserMode::VibeMode)
    _ => Err(cmd_name + ": unsupported syntax `" + value + "` (expected: vibe)")
  }
}

///|
struct CliRuntimeArgs {
  syntax_mode : @runtime.ParserMode
  cmd_args : Array[String]
  unstable_async : Bool
  unstable_threads : Bool
  thread_backend_id : String
  thread_backend_explicit : Bool
  enable_llm : Bool
  permissions : @capability.CapabilitySet?
}

///|
struct CliDispatchArgs {
  cmd : String
  syntax_mode : @runtime.ParserMode
  cmd_args : Array[String]
  unstable_async : Bool
  unstable_threads : Bool
  thread_backend_id : String
  enable_llm : Bool
  permissions : @capability.CapabilitySet?
}

///|
fn parse_cli_syntax_args(
  args : Array[String],
  cmd_name : String,
) -> Result[(@runtime.ParserMode, Array[String]), String] {
  let mut mode = @runtime.ParserMode::VibeMode
  let rest : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if arg == "--syntax" {
      if i + 1 >= args.length() {
        return Err(cmd_name + ": missing value for --syntax (expected: vibe)")
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
fn parse_cli_runtime_args(
  args : Array[String],
  cmd_name : String,
) -> Result[CliRuntimeArgs, String] {
  let filtered : Array[String] = []
  let mut unstable_async = false
  let mut unstable_threads = false
  let mut thread_backend_id = @runtime.RuntimeFeatureFlags::default_thread_backend_id()
  let mut thread_backend_explicit = false
  let mut enable_llm = false
  let allow_flags : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--unstable-async" => unstable_async = true
      "--unstable-threads" => unstable_threads = true
      "--thread-backend" => {
        i += 1
        if i >= args.length() {
          return Err(cmd_name + ": missing value for --thread-backend")
        }
        match parse_thread_backend_id(args[i], cmd_name) {
          Ok(id) => {
            thread_backend_id = id
            thread_backend_explicit = true
            unstable_threads = true
          }
          Err(err) => return Err(err)
        }
      }
      "--llm" => enable_llm = true
      _ => {
        match extract_flag_value(arg, "--thread-backend=") {
          Some(value) => {
            match parse_thread_backend_id(value, cmd_name) {
              Ok(id) => {
                thread_backend_id = id
                thread_backend_explicit = true
                unstable_threads = true
              }
              Err(err) => return Err(err)
            }
            i += 1
            continue
          }
          None => ()
        }
        if arg == "--allow-all" ||
          arg == "--allow-fs" ||
          arg == "--allow-net" ||
          arg == "--allow-env" ||
          arg == "--allow-run" ||
          arg.has_prefix("--allow-fs=") ||
          arg.has_prefix("--allow-net=") ||
          arg.has_prefix("--allow-env=") ||
          arg.has_prefix("--allow-run=") {
          allow_flags.push(arg)
        } else {
          filtered.push(arg)
        }
      }
    }
    i += 1
  }
  let permissions = if allow_flags.length() > 0 {
    Some(parse_allow_flags_to_caps(allow_flags))
  } else {
    None
  }
  match parse_cli_syntax_args(filtered, cmd_name) {
    Ok((syntax_mode, cmd_args)) =>
      Ok({
        syntax_mode,
        cmd_args,
        unstable_async,
        unstable_threads,
        thread_backend_id,
        thread_backend_explicit,
        enable_llm,
        permissions,
      })
    Err(err) => Err(err)
  }
}

///|
fn split_comma_values(value : String) -> Array[String] {
  let result : Array[String] = []
  let buf = StringBuilder::new()
  for ch in value {
    if ch == ',' {
      let s = buf.to_string().trim().to_owned()
      if s.length() > 0 {
        result.push(s)
      }
      buf.reset()
    } else {
      buf.write_char(ch)
    }
  }
  let s = buf.to_string().trim().to_owned()
  if s.length() > 0 {
    result.push(s)
  }
  result
}

///|
fn extract_flag_value(arg : String, prefix : String) -> String? {
  if arg.has_prefix(prefix) {
    let value = arg[prefix.length():].to_owned()
    if value.length() > 0 {
      Some(value)
    } else {
      None
    }
  } else {
    None
  }
}

///|
fn parse_thread_backend_id(
  value : String,
  cmd_name : String,
) -> Result[String, String] {
  match value {
    "linear-local"
    | "serial"
    | "wasi-threads"
    | "component-cooperative"
    | "component-unsafe-os-threads"
    | "component-shared" => Ok(value)
    _ => Err(cmd_name + ": unknown thread backend `" + value + "`")
  }
}

///|
fn parse_allow_flags_to_caps(
  flags : Array[String],
) -> @capability.CapabilitySet {
  let caps : Array[@capability.Capability] = []
  let mut has_allow_all = false
  for flag in flags {
    if flag == "--allow-all" {
      has_allow_all = true
    }
  }
  if has_allow_all {
    return @capability.CapabilitySet::unrestricted()
  }
  for flag in flags {
    if flag == "--allow-fs" {
      caps.push(@capability.Capability::fs_read("/**"))
      caps.push(@capability.Capability::fs_write("/**"))
    } else if flag == "--allow-net" {
      caps.push(@capability.Capability::net_connect("*", None))
      caps.push(@capability.Capability::net_listen(0))
    } else if flag == "--allow-env" {
      caps.push(@capability.Capability::env_read(["*"]))
    } else if flag == "--allow-run" {
      caps.push(@capability.Capability::process_spawn(["*"]))
    } else {
      match extract_flag_value(flag, "--allow-fs=") {
        Some(value) =>
          if value == "read" {
            caps.push(@capability.Capability::fs_read("/**"))
          } else {
            // Treat value as comma-separated path list
            let paths = split_comma_values(value)
            for path in paths {
              caps.push(@capability.Capability::fs_read(path + "/**"))
              caps.push(@capability.Capability::fs_write(path + "/**"))
            }
          }
        None => ()
      }
      match extract_flag_value(flag, "--allow-net=") {
        Some(value) => {
          let hosts = split_comma_values(value)
          for host in hosts {
            caps.push(@capability.Capability::net_connect(host, None))
          }
        }
        None => ()
      }
      match extract_flag_value(flag, "--allow-env=") {
        Some(value) => {
          let vars = split_comma_values(value)
          caps.push(@capability.Capability::env_read(vars))
        }
        None => ()
      }
      match extract_flag_value(flag, "--allow-run=") {
        Some(value) => {
          let cmds = split_comma_values(value)
          caps.push(@capability.Capability::process_spawn(cmds))
        }
        None => ()
      }
    }
  }
  // Always grant clock and random for basic usability
  caps.push(@capability.Capability::clock_read())
  caps.push(@capability.Capability::random_read())
  @capability.CapabilitySet::from_array(caps)
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
pub fn parse_cli_dispatch_args(
  args : Array[String],
) -> Result[CliDispatchArgs, String] {
  if args.length() <= 1 {
    return Err("missing command")
  }
  let mut global_unstable_async = false
  let mut global_unstable_threads = false
  let mut global_thread_backend_id = @runtime.RuntimeFeatureFlags::default_thread_backend_id()
  let mut global_thread_backend_explicit = false
  let mut global_enable_llm = false
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
      "--thread-backend" => {
        cmd_index += 1
        if cmd_index >= args.length() {
          return Err("missing value for --thread-backend")
        }
        match parse_thread_backend_id(args[cmd_index], "vibe") {
          Ok(id) => {
            global_thread_backend_id = id
            global_thread_backend_explicit = true
            global_unstable_threads = true
          }
          Err(err) => return Err(err)
        }
        cmd_index += 1
      }
      "--llm" => {
        global_enable_llm = true
        cmd_index += 1
      }
      _ => {
        match extract_flag_value(args[cmd_index], "--thread-backend=") {
          Some(value) => {
            match parse_thread_backend_id(value, "vibe") {
              Ok(id) => {
                global_thread_backend_id = id
                global_thread_backend_explicit = true
                global_unstable_threads = true
              }
              Err(err) => return Err(err)
            }
            cmd_index += 1
            continue
          }
          None => ()
        }
        break
      }
    }
  }
  if cmd_index >= args.length() {
    return Err("missing command")
  }
  let cmd = args[cmd_index]
  let raw_cmd_args = cli_args_tail(args, cmd_index + 1)
  match parse_cli_runtime_args(raw_cmd_args, cmd) {
    Ok(cli_args) => {
      let thread_backend_id = if cli_args.thread_backend_explicit {
        cli_args.thread_backend_id
      } else if global_thread_backend_explicit {
        global_thread_backend_id
      } else {
        @runtime.RuntimeFeatureFlags::default_thread_backend_id()
      }
      Ok({
        cmd,
        syntax_mode: cli_args.syntax_mode,
        cmd_args: cli_args.cmd_args,
        unstable_async: cli_args.unstable_async || global_unstable_async,
        unstable_threads: cli_args.unstable_threads || global_unstable_threads,
        thread_backend_id,
        enable_llm: cli_args.enable_llm || global_enable_llm,
        permissions: cli_args.permissions,
      })
    }
    Err(err) => Err(err)
  }
}

///|
