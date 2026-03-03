///|
pub enum InputMode {
  Binary
  Wac
} derive(Eq, Show)

///|
pub struct CmdOptions {
  mode : InputMode
  input_path : String
  output_path : String
  opt_level : String?
} derive(Eq, Show)

///|
fn args_tail(args : Array[String], start : Int) -> Array[String] {
  let out : Array[String] = []
  for i in start..<args.length() {
    out.push(args[i])
  }
  out
}

///|
pub fn normalize_opt_level(level : String) -> Result[String, String] {
  match level {
    "-O0" | "-O1" | "-O2" | "-O3" | "-O4" | "-Os" | "-Oz" => Ok(level)
    _ =>
      Err(
        "wite-opt: unsupported wite optimize level " +
        level +
        " (expected: -O0|-O1|-O2|-O3|-O4|-Os|-Oz)",
      )
  }
}

///|
pub fn parse_cmd_args(args : Array[String]) -> Result[CmdOptions, String] {
  let mut mode = InputMode::Binary
  let mut input_path : String? = None
  let mut output_path : String? = None
  let mut opt_level : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if arg == "--wac" {
      mode = InputMode::Wac
      i += 1
      continue
    }
    if arg == "--input" {
      i += 1
      if i >= args.length() {
        return Err("wite-opt: missing path after --input")
      }
      input_path = Some(args[i])
      i += 1
      continue
    }
    if arg == "-o" || arg == "--output" {
      i += 1
      if i >= args.length() {
        return Err("wite-opt: missing path after " + arg)
      }
      output_path = Some(args[i])
      i += 1
      continue
    }
    if arg == "--wite" {
      opt_level = Some("-Oz")
      i += 1
      continue
    }
    if arg == "-h" || arg == "--help" {
      return Err("help")
    }
    if arg.has_prefix("-O") {
      match normalize_opt_level(arg) {
        Ok(level) => opt_level = Some(level)
        Err(msg) => return Err(msg)
      }
      i += 1
      continue
    }
    if arg.has_prefix("-") {
      return Err("wite-opt: unknown option: " + arg)
    }
    if input_path is Some(_) {
      return Err("wite-opt: multiple input paths are not supported")
    }
    input_path = Some(arg)
    i += 1
  }
  let input_path = match input_path {
    Some(path) => path
    None => return Err("wite-opt: missing input path")
  }
  let output_path = match output_path {
    Some(path) => path
    None => return Err("wite-opt: missing required -o/--output")
  }
  Ok({ mode, input_path, output_path, opt_level })
}

///|
fn usage() -> Unit {
  println(
    "vibe_wite_optimize_wasi [--wac] [--wite|-O{0,1,2,3,4,s,z}] [--input <path> | <path>] -o <out>",
  )
}

///|
fn is_gc_unsupported_optimize_error(msg : String) -> Bool {
  msg.contains("unsupported type form") ||
  msg.contains("unsupported gc type form")
}

///|
fn gc_compat_optimize_config(level : String) -> @wite_optimize.OptimizeConfig {
  let (strip_debug, strip_dwarf, strip_target_features) = match level {
    "-O1" => (true, true, true)
    _ => (false, false, false)
  }
  @wite_optimize.make_optimize_config(
    strip_all_custom=false,
    strip_name_section=false,
    strip_producers_section=false,
    strip_debug_sections=strip_debug,
    strip_dwarf_sections=strip_dwarf,
    strip_target_features_section=strip_target_features,
    keep_custom_sections=[],
    pass_rounds=1U,
    enable_peephole=false,
    peephole_remove_nop=false,
    peephole_remove_const_drop=false,
    enable_vacuum=false,
    enable_merge_blocks=false,
    enable_remove_unused_brs=false,
    enable_dce=false,
    enable_dfe=false,
    enable_merge_similar_functions=false,
    enable_remove_unused_module_elements=false,
    closed_world=false,
    closed_world_root_exports=[],
    safe_mode=true,
  )
}

///|
fn optimize_bytes_with_opt_level(
  bytes : Bytes,
  opt_level : String?,
) -> Result[Bytes, String] {
  match opt_level {
    None => Ok(bytes)
    Some(level) => {
      let config = match @wite_optimize.optimize_config_from_opt_level(level) {
        Some(cfg) => cfg
        None =>
          return Err(
            "wite-opt: unsupported wite optimize level " +
            level +
            " (expected: -O0|-O1|-O2|-O3|-O4|-Os|-Oz)",
          )
      }
      match @wite_optimize.optimize_binary_for_size(bytes, config~) {
        Ok(result) => Ok(result.bytes)
        Err(msg) =>
          if is_gc_unsupported_optimize_error(msg) {
            let fallback = gc_compat_optimize_config(level)
            match
              @wite_optimize.optimize_binary_for_size(bytes, config=fallback) {
              Ok(result) => Ok(result.bytes)
              Err(fallback_err) =>
                Err(
                  "wite-opt: optimize failed: " +
                  msg +
                  " (gc fallback failed: " +
                  fallback_err +
                  ")",
                )
            }
          } else {
            Err("wite-opt: optimize failed: " + msg)
          }
      }
    }
  }
}

///|
fn load_input_bytes(
  opts : CmdOptions,
  fs : &@io.FileSystemAdapter,
) -> Result[Bytes, String] {
  match opts.mode {
    InputMode::Binary =>
      match @io.read_bytes_with(fs, opts.input_path) {
        Ok(bytes) => Ok(bytes)
        Err(err) => Err("wite-opt: failed to read input: " + err)
      }
    InputMode::Wac =>
      match @wite_bundle.compose_wac_file(opts.input_path, dce=true) {
        Ok(component) => Ok(component)
        Err(msg) => Err("wite-opt: wac compose failed: " + msg)
      }
  }
}

///|
fn run_cmd(
  opts : CmdOptions,
  fs : &@io.FileSystemAdapter,
) -> Result[Unit, String] {
  let input = match load_input_bytes(opts, fs) {
    Ok(bytes) => bytes
    Err(msg) => return Err(msg)
  }
  let optimized = match optimize_bytes_with_opt_level(input, opts.opt_level) {
    Ok(bytes) => bytes
    Err(msg) => return Err(msg)
  }
  match @io.write_bytes_with(fs, opts.output_path, optimized) {
    Ok(_) => Ok(())
    Err(err) => Err("wite-opt: failed to write output: " + err)
  }
}

///|
fn main {
  let args = args_tail(@sys.get_cli_args(), 1)
  let opts = match parse_cmd_args(args) {
    Ok(parsed) => parsed
    Err("help") => {
      usage()
      return
    }
    Err(msg) => {
      println(msg)
      return
    }
  }
  let fs = @io.default_fs_adapter()
  match run_cmd(opts, fs) {
    Ok(_) => ()
    Err(msg) => println(msg)
  }
}
