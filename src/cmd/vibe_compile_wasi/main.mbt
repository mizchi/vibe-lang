///|
pub enum CompileMode {
  Ir
  Wasm
  WasmJsString
  WasmGc
  Component
  Wac
  Wit
  WitComponent
} derive(Eq, Show)

///|
pub struct CompileCmdOptions {
  mode : CompileMode
  no_dce : Bool
  debug_errors : Bool
  http_host_imports : Bool
  out_path : String?
  entry_path : String
  opt_level : String?
}

///|
fn args_tail(args : Array[String], start : Int) -> Array[String] {
  let out : Array[String] = []
  for i in start..<args.length() {
    out.push(args[i])
  }
  out
}

///|
fn compile_mode_supports_no_dce(mode : CompileMode) -> Bool {
  match mode {
    CompileMode::Wasm | CompileMode::WasmJsString | CompileMode::WasmGc => true
    _ => false
  }
}

///|
fn compile_mode_supports_wite_opt(mode : CompileMode) -> Bool {
  match mode {
    CompileMode::Wasm
    | CompileMode::WasmJsString
    | CompileMode::WasmGc
    | CompileMode::Component
    | CompileMode::Wac => true
    _ => false
  }
}

///|
fn compile_mode_supports_debug_errors(mode : CompileMode) -> Bool {
  match mode {
    CompileMode::Wasm | CompileMode::WasmJsString => true
    _ => false
  }
}

///|
fn compile_mode_supports_http_host_imports(mode : CompileMode) -> Bool {
  match mode {
    CompileMode::Wasm | CompileMode::Component => true
    _ => false
  }
}

///|
fn is_opt_level_flag(arg : String) -> Bool {
  match arg {
    "-O0" | "-O1" | "-O" | "-O2" | "-O3" | "-O4" | "-Os" | "-Oz" => true
    _ => false
  }
}

///|
fn parse_compile_cmd_args(
  args : Array[String],
) -> Result[CompileCmdOptions, String] {
  let mut mode = CompileMode::Ir
  let mut no_dce = false
  let mut debug_errors = false
  let mut http_host_imports = false
  let mut out_path : String? = None
  let mut entry_path : String? = None
  let mut opt_level : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--wasm" => {
        mode = CompileMode::Wasm
        i += 1
      }
      "--wasm-linear" => {
        mode = CompileMode::Wasm
        i += 1
      }
      "--wasm-mvp" => {
        mode = CompileMode::Wasm
        i += 1
      }
      "--wasm-js-string" => {
        mode = CompileMode::WasmJsString
        i += 1
      }
      "--wasm-gc" => {
        mode = CompileMode::WasmGc
        i += 1
      }
      "--component" => {
        mode = CompileMode::Component
        i += 1
      }
      "--wac" => {
        mode = CompileMode::Wac
        i += 1
      }
      "--wit" => {
        mode = CompileMode::Wit
        i += 1
      }
      "--wit-component" => {
        mode = CompileMode::WitComponent
        i += 1
      }
      "--no-dce" => {
        no_dce = true
        i += 1
      }
      "--debug-errors" => {
        debug_errors = true
        i += 1
      }
      "--http-host-imports" => {
        http_host_imports = true
        i += 1
      }
      "--wite" => {
        if opt_level is None {
          opt_level = Some("-Oz")
        }
        i += 1
      }
      "-o" | "--out" => {
        if i + 1 >= args.length() {
          return Err("compile: missing output path after " + arg)
        }
        out_path = Some(args[i + 1])
        i += 2
      }
      "-h" | "--help" => return Err("help")
      _ if is_opt_level_flag(arg) => {
        opt_level = Some(arg)
        i += 1
      }
      _ => {
        if entry_path is None {
          entry_path = Some(arg)
        } else {
          return Err("compile: too many input files")
        }
        i += 1
      }
    }
  }
  match entry_path {
    None => Err("compile: missing <file>")
    Some(path) => {
      if no_dce && not(compile_mode_supports_no_dce(mode)) {
        return Err(
          "compile: --no-dce is only supported with --wasm/--wasm-mvp, --wasm-js-string, or --wasm-gc",
        )
      }
      if opt_level is Some(_) && not(compile_mode_supports_wite_opt(mode)) {
        return Err(
          "compile: --wite/-O* is only supported with --wasm, --wasm-js-string, --wasm-gc, --component, or --wac",
        )
      }
      if debug_errors && not(compile_mode_supports_debug_errors(mode)) {
        return Err(
          "compile: --debug-errors is only supported with --wasm or --wasm-js-string",
        )
      }
      if http_host_imports && not(compile_mode_supports_http_host_imports(mode)) {
        return Err(
          "compile: --http-host-imports is only supported with --wasm or --component",
        )
      }
      Ok({
        mode,
        no_dce,
        debug_errors,
        http_host_imports,
        out_path,
        entry_path: path,
        opt_level,
      })
    }
  }
}

///|
fn print_usage() -> Unit {
  println(
    "vibe_compile_wasi [compile] [--wasm|--wasm-mvp|--wasm-js-string|--wasm-gc|--component|--wac|--wit|--wit-component] [--no-dce] [--debug-errors] [--http-host-imports] [--wite|-O{0,1,2,3,4,s,z}] [-o out] <file>",
  )
  println(
    "vibe_compile_wasi compile-lite [--wasm | --wasm-linear | --wasm-gc] [--no-dce] [--in-memory] [--profile-tsv path] [-O{0,1,2,3,4,s,z}] [-o out] <file>",
  )
}

///|
fn get_basename(path : String) -> String {
  let mut last_slash = -1
  for i, c in path {
    if c == '/' {
      last_slash = i
    }
  }
  let filename = if last_slash >= 0 {
    let buf = StringBuilder::new()
    for i, c in path {
      if i > last_slash {
        buf.write_char(c)
      }
    }
    buf.to_string()
  } else {
    path
  }
  let mut last_dot = -1
  for i, c in filename {
    if c == '.' {
      last_dot = i
    }
  }
  if last_dot > 0 {
    let buf = StringBuilder::new()
    for i, c in filename {
      if i < last_dot {
        buf.write_char(c)
      }
    }
    buf.to_string()
  } else {
    filename
  }
}

///|
fn default_output_path(input_path : String, mode : CompileMode) -> String {
  let basename = get_basename(input_path)
  match mode {
    CompileMode::Ir => "dist/" + basename + ".ir"
    CompileMode::Wasm => "dist/" + basename + ".wasm"
    CompileMode::WasmJsString => "dist/" + basename + ".wasm"
    CompileMode::WasmGc => "dist/" + basename + ".wasm"
    CompileMode::Component => "dist/" + basename + ".component.wasm"
    CompileMode::Wac => "dist/" + basename + ".component.wasm"
    CompileMode::Wit => "dist/" + basename + ".wit"
    CompileMode::WitComponent => "dist/" + basename + ".component.wit"
  }
}

///|
fn ensure_dist_dir(fs : &@io.FileSystemAdapter) -> Result[Unit, String] {
  if @io.path_exists_with(fs, "dist") {
    return Ok(())
  }
  @io.create_dir_with(fs, "dist")
}

///|
fn optimize_wasm_bytes_with_opt_level(
  bytes : Bytes,
  opt_level : String?,
) -> Result[Bytes, String] {
  match opt_level {
    None => Ok(bytes)
    Some(level) => {
      let config = match @wite.optimize_config_from_opt_level(level) {
        Some(v) => v
        None =>
          return Err(
            "compile: unsupported wite optimize level " +
            level +
            " (expected: -O0|-O1|-O2|-O3|-O4|-Os|-Oz)",
          )
      }
      match @wite.optimize_binary_for_size(bytes, config~) {
        Ok(result) => Ok(result.bytes)
        Err(msg) => Err("compile: wite optimize failed: " + msg)
      }
    }
  }
}

///|
fn compile_cmd(
  args : Array[String],
  fs : &@io.FileSystemAdapter,
) -> Result[String, String] {
  let opts = match parse_compile_cmd_args(args) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let resolved_out = match opts.out_path {
    Some(path) => path
    None => {
      match ensure_dist_dir(fs) {
        Ok(_) => ()
        Err(err) => return Err("compile: failed to create dist/: " + err)
      }
      default_output_path(opts.entry_path, opts.mode)
    }
  }
  if opts.mode == CompileMode::Wac {
    let component = match
      @wite_bundle.compose_wac_file(opts.entry_path, dce=true) {
      Ok(bytes) => bytes
      Err(msg) => return Err("compile: wac compose failed: " + msg)
    }
    let optimized = match
      optimize_wasm_bytes_with_opt_level(component, opts.opt_level) {
      Ok(bytes) => bytes
      Err(err) => return Err(err)
    }
    match @io.write_bytes_with(fs, resolved_out, optimized) {
      Ok(_) => ()
      Err(err) => return Err("compile: " + err)
    }
    return Ok(resolved_out)
  }
  let loaded = match @loader.load_db_with_fs(opts.entry_path, fs) {
    Ok(v) => v
    Err(err) => return Err("compile: " + err)
  }
  let (db, entry) = loaded
  match opts.mode {
    CompileMode::Ir => {
      let compiled = @runtime_compile.compile_module(db, entry) catch {
        e => return Err("compile: " + e.to_string())
      }
      match @io.write_string_with(fs, resolved_out, compiled.ir) {
        Ok(_) => ()
        Err(err) => return Err("compile: " + err)
      }
    }
    CompileMode::Wasm => {
      let wasm_bytes = @runtime_compile.compile_module_wasm_with_opt_level(
        db,
        entry,
        no_dce=opts.no_dce,
        opt_level=opts.opt_level,
        debug_errors=opts.debug_errors,
        http_host_imports=opts.http_host_imports,
      ) catch {
        e => return Err("compile: " + e.to_string())
      }
      match @io.write_bytes_with(fs, resolved_out, wasm_bytes) {
        Ok(_) => ()
        Err(err) => return Err("compile: " + err)
      }
    }
    CompileMode::WasmJsString => {
      let wasm_bytes = @runtime_compile.compile_module_wasm_js_string_with_opt_level(
        db,
        entry,
        no_dce=opts.no_dce,
        opt_level=opts.opt_level,
        debug_errors=opts.debug_errors,
      ) catch {
        e => return Err("compile: " + e.to_string())
      }
      match @io.write_bytes_with(fs, resolved_out, wasm_bytes) {
        Ok(_) => ()
        Err(err) => return Err("compile: " + err)
      }
    }
    CompileMode::WasmGc => {
      let wasm_bytes = @runtime_compile.compile_module_wasm_gc_with_opt_level(
        db,
        entry,
        no_dce=opts.no_dce,
        opt_level=opts.opt_level,
      ) catch {
        e => return Err("compile: " + e.to_string())
      }
      match @io.write_bytes_with(fs, resolved_out, wasm_bytes) {
        Ok(_) => ()
        Err(err) => return Err("compile: " + err)
      }
    }
    CompileMode::Component => {
      let wasm_bytes = @runtime_compile.compile_module_component_with_opt_level(
        db,
        entry,
        opt_level=opts.opt_level,
        http_host_imports=opts.http_host_imports,
      ) catch {
        e => return Err("compile: " + e.to_string())
      }
      match @io.write_bytes_with(fs, resolved_out, wasm_bytes) {
        Ok(_) => ()
        Err(err) => return Err("compile: " + err)
      }
    }
    CompileMode::Wac =>
      return Err(
        "compile: internal error: --wac should bypass vibe source compilation",
      )
    CompileMode::Wit => {
      let basename = get_basename(entry)
      let package_name = "local:" + basename
      let world_name = basename
      let wit_str = @runtime_compile.generate_module_wit(
        db, entry, package_name, world_name,
      ) catch {
        e => return Err("compile: " + e.to_string())
      }
      match @io.write_string_with(fs, resolved_out, wit_str) {
        Ok(_) => ()
        Err(err) => return Err("compile: " + err)
      }
    }
    CompileMode::WitComponent => {
      let basename = get_basename(entry)
      let package_name = "local:" + basename
      let world_name = basename
      let wit_str = @runtime_compile.generate_module_component_wit(
        db, entry, package_name, world_name,
      ) catch {
        e => return Err("compile: " + e.to_string())
      }
      match @io.write_string_with(fs, resolved_out, wit_str) {
        Ok(_) => ()
        Err(err) => return Err("compile: " + err)
      }
    }
  }
  Ok(resolved_out)
}

///|
fn compile_lite_validate_opts(
  opts : CompileCmdOptions,
  in_memory : Bool,
) -> Result[Unit, String] {
  if opts.mode != CompileMode::Wasm && opts.mode != CompileMode::WasmGc {
    return Err(
      "compile-lite: only --wasm/--wasm-linear/--wasm-gc mode is supported",
    )
  }
  if opts.debug_errors {
    return Err("compile-lite: --debug-errors is not supported")
  }
  if opts.http_host_imports {
    return Err("compile-lite: --http-host-imports is not supported")
  }
  if not(in_memory) && opts.out_path is None {
    return Err("compile-lite: -o/--out is required")
  }
  Ok(())
}

///|
fn split_compile_lite_args(
  args : Array[String],
) -> Result[(Array[String], String?, Bool), String] {
  let filtered : Array[String] = []
  let mut profile_tsv : String? = None
  let mut in_memory = false
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if arg == "--profile-tsv" {
      i += 1
      if i >= args.length() {
        return Err("compile-lite: missing path after --profile-tsv")
      }
      profile_tsv = Some(args[i])
    } else if arg == "--in-memory" {
      in_memory = true
    } else {
      filtered.push(arg)
    }
    i += 1
  }
  Ok((filtered, profile_tsv, in_memory))
}

///|
fn elapsed_us_from(start : @bench.Timestamp) -> Int {
  let elapsed_us = @bench.monotonic_clock_end(start)
  let elapsed = elapsed_us.to_int()
  if elapsed <= 0 {
    1
  } else {
    elapsed
  }
}

///|
fn compile_lite_cmd(
  args : Array[String],
  fs : &@io.FileSystemAdapter,
) -> Result[String, String] {
  let (compile_args, profile_tsv, in_memory) = match
    split_compile_lite_args(args) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let opts = match parse_compile_cmd_args(compile_args) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  match compile_lite_validate_opts(opts, in_memory) {
    Ok(_) => ()
    Err(err) => return Err(err)
  }
  let out_path = match opts.out_path {
    Some(path) => path
    None => ""
  }
  @runtime_compile.init_hooks()
  let start_total = @bench.monotonic_clock_start()
  let start_load = @bench.monotonic_clock_start()
  let loaded = match @loader.load_db_with_fs(opts.entry_path, fs) {
    Ok(v) => v
    Err(err) => return Err("compile-lite: " + err)
  }
  let load_us = elapsed_us_from(start_load)
  let (db, entry) = loaded
  let start_type = @bench.monotonic_clock_start()
  let _ = db.types(entry)
  let type_us = elapsed_us_from(start_type)
  let (wasm_bytes, compile_profile) = if opts.mode == CompileMode::WasmGc {
    @runtime_compile.compile_module_wasm_gc_with_opt_level_profiled(
      db,
      entry,
      no_dce=opts.no_dce,
      opt_level=opts.opt_level,
    ) catch {
      e => return Err("compile-lite: " + e.to_string())
    }
  } else {
    @runtime_compile.compile_module_wasm_with_opt_level_profiled(
      db,
      entry,
      no_dce=opts.no_dce,
      opt_level=opts.opt_level,
      debug_errors=false,
      http_host_imports=false,
    ) catch {
      e => return Err("compile-lite: " + e.to_string())
    }
  }
  let mut write_us = 0
  if not(in_memory) {
    let start_write = @bench.monotonic_clock_start()
    match @io.write_bytes_with(fs, out_path, wasm_bytes) {
      Ok(_) => ()
      Err(err) => return Err("compile-lite: " + err)
    }
    write_us = elapsed_us_from(start_write)
  }
  let total_us = elapsed_us_from(start_total)
  match profile_tsv {
    Some(path) => {
      let content = @runtime_compile.wasm_compile_profile_tsv(
        load_us, type_us, compile_profile, write_us, total_us,
      )
      match @io.write_string_with(fs, path, content) {
        Ok(_) => ()
        Err(err) =>
          return Err("compile-lite: failed to write profile tsv: " + err)
      }
    }
    None => ()
  }
  Ok(out_path)
}

///|
fn main {
  let raw_args = @sys.get_cli_args()
  let args = args_tail(raw_args, 1)
  let is_lite = args.length() > 0 && args[0] == "compile-lite"
  let compile_args = if args.length() > 0 && args[0] == "compile" {
    args_tail(args, 1)
  } else if is_lite {
    args_tail(args, 1)
  } else {
    args
  }
  if compile_args.length() == 0 {
    print_usage()
    return
  }
  let fs = @io.default_fs_adapter()
  let result = if is_lite {
    compile_lite_cmd(compile_args, fs)
  } else {
    compile_cmd(compile_args, fs)
  }
  match result {
    Ok(path) => println("wrote " + path)
    Err("help") => print_usage()
    Err(err) => {
      println(err)
      abort("compile failed")
    }
  }
}
