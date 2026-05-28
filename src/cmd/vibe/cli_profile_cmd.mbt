///|
/// `vibe profile <file.vibe>` — compile to wasm and run under wasmtime
/// with the built-in `--profile=guest` strategy, producing a Firefox
/// Profiler JSON that can be loaded directly at
/// https://profiler.firefox.com/ (or converted to pprof out of band).
///
/// Inspired by mizchi/pprof-mbt's wasmtime-guest-pprof crate, but
/// shells out to the wasmtime CLI's built-in `--profile=guest` instead
/// of linking wasmtime as a Rust library. The output JSON is exactly
/// what wasmtime's GuestProfiler::finish() writes — same schema the
/// pprof-mbt `firefox-to-pprof` converter consumes — so a pprof
/// follow-up only needs a converter binary, not new instrumentation
/// here.

///|
/// Profile backend — narrower than `BenchBackend` because `vibe profile`
/// supports wasm-gc, whereas the bench harness today only targets the
/// linear backend.
enum ProfileBackend {
  Wasm
  WasmGc
} derive(Debug, Eq)

///|
fn parse_profile_backend(value : String) -> ProfileBackend? {
  match value.trim().to_owned().to_lower() {
    "wasm" | "linear" => Some(ProfileBackend::Wasm)
    "wasm-gc" | "gc" => Some(ProfileBackend::WasmGc)
    _ => None
  }
}

///|
struct ProfileCmdOptions {
  entry_path : String
  backend : ProfileBackend
  out_path : String
  interval_us : Int
  invoke_name : String
  iterations : Int
  keep_wasm : Bool
} derive(Debug, Eq)

///|
fn default_profile_interval_us() -> Int {
  match @sys.get_env_var("VIBE_PROFILE_INTERVAL_US") {
    Some(raw) =>
      @string.parse_int(raw.trim().to_owned()) catch {
        _ => 1000 // fallback when the env var is malformed
      }
    None => 1000
  }
}

///|
fn default_profile_iterations() -> Int {
  match @sys.get_env_var("VIBE_PROFILE_ITERATIONS") {
    Some(raw) => @string.parse_int(raw.trim().to_owned()) catch { _ => 1 }
    None => 1
  }
}

///|
fn parse_profile_cmd_args(
  args : Array[String],
) -> Result[ProfileCmdOptions, String] {
  let paths : Array[String] = []
  let mut backend : ProfileBackend = ProfileBackend::WasmGc
  let mut out_path : String? = None
  let mut interval_us = default_profile_interval_us()
  let mut iterations = default_profile_iterations()
  let mut invoke_name = "_start"
  let mut keep_wasm = false
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-b" | "--backend" => {
        if i + 1 >= args.length() {
          return Err("profile: missing value for --backend")
        }
        match parse_profile_backend(args[i + 1]) {
          Some(b) => backend = b
          None =>
            return Err(
              "profile: invalid --backend: " +
              args[i + 1] +
              " (expected: wasm | wasm-gc)",
            )
        }
        i += 2
      }
      "--out" => {
        if i + 1 >= args.length() {
          return Err("profile: missing value for --out")
        }
        out_path = Some(args[i + 1])
        i += 2
      }
      "--interval-us" => {
        if i + 1 >= args.length() {
          return Err("profile: missing value for --interval-us")
        }
        interval_us = @string.parse_int(args[i + 1]) catch {
          e => return Err("profile: invalid --interval-us: " + e.to_string())
        }
        i += 2
      }
      "--iterations" => {
        if i + 1 >= args.length() {
          return Err("profile: missing value for --iterations")
        }
        iterations = @string.parse_int(args[i + 1]) catch {
          e => return Err("profile: invalid --iterations: " + e.to_string())
        }
        i += 2
      }
      "--invoke" => {
        if i + 1 >= args.length() {
          return Err("profile: missing value for --invoke")
        }
        invoke_name = args[i + 1]
        i += 2
      }
      "--keep-wasm" => {
        keep_wasm = true
        i += 1
      }
      _ =>
        if arg.has_prefix("-") {
          return Err("profile: unknown arg " + arg)
        } else {
          paths.push(arg)
          i += 1
        }
    }
  }
  if interval_us <= 0 {
    return Err("profile: --interval-us must be > 0")
  }
  if iterations <= 0 {
    return Err("profile: --iterations must be > 0")
  }
  if paths.length() != 1 {
    return Err(
      "profile: expected exactly one <file>, got " + paths.length().to_string(),
    )
  }
  let entry_path = paths[0]
  let resolved_out = match out_path {
    Some(p) => p
    None => default_profile_out_path(entry_path)
  }
  Ok({
    entry_path,
    backend,
    out_path: resolved_out,
    interval_us,
    invoke_name,
    iterations,
    keep_wasm,
  })
}

///|
fn default_profile_out_path(entry_path : String) -> String {
  let base = entry_path
  // strip trailing `.vibe` if present, then append .profile.json
  if base.has_suffix(".vibe") {
    base.substring(start=0, end=base.length() - 5) + ".profile.json"
  } else {
    base + ".profile.json"
  }
}

///|
fn print_profile_help() -> Unit {
  println(
    "Usage: vibe profile <file.vibe> [options]\n" +
    "\n" +
    "Compile a vibe program and run it under wasmtime's GuestProfiler.\n" +
    "Inspired by mizchi/pprof-mbt; uses wasmtime's built-in --profile=guest\n" +
    "strategy, which emits Firefox Profiler JSON. Load the output at\n" +
    "https://profiler.firefox.com/ or convert to pprof out of band.\n" +
    "\n" +
    "Options:\n" +
    "  -b, --backend <wasm|wasm-gc>  codegen backend (default: wasm-gc)\n" +
    "      --out <path>              Firefox Profiler JSON output path\n" +
    "                                 (default: <entry>.profile.json)\n" +
    "      --interval-us <us>        sampling interval in microseconds\n" +
    "                                 (default: 1000, env: VIBE_PROFILE_INTERVAL_US)\n" +
    "      --iterations <n>          invoke entry N times (default: 1,\n" +
    "                                 env: VIBE_PROFILE_ITERATIONS)\n" +
    "      --invoke <name>           wasmtime --invoke target (default: _start)\n" +
    "      --keep-wasm               keep the compiled .wasm artifact\n" +
    "  -h, --help                    show this help",
  )
}

///|
/// Build the wasmtime invocation. Returns the shell-ready command
/// string, identical in shape to `build_wasmtime_invoke_command` from
/// cli_bench.mbt except for the extra `--profile=guest,...` argument.
fn build_wasmtime_profile_command(
  runner : BenchWasmRunner,
  wasm_path : String,
  invoke_name : String,
  profile_out : String,
  interval_us : Int,
) -> String {
  let cmd = StringBuilder::new()
  cmd.write_string(shell_quote_command_arg(runner.wasmtime_bin))
  for flag in runner.wasm_flags {
    cmd.write_string(" -W ")
    cmd.write_string(shell_quote_command_arg(flag))
  }
  for flag in runner.wasi_flags {
    cmd.write_string(" -S ")
    cmd.write_string(shell_quote_command_arg(flag))
  }
  // wasmtime's --profile=guest accepts `path,interval`. The interval is
  // a humantime-parsed duration; emit microseconds as `<n>us` so we
  // don't rely on millisecond rounding for small intervals.
  let profile_arg = "guest," +
    profile_out +
    "," +
    interval_us.to_string() +
    "us"
  cmd.write_string(" --profile=")
  cmd.write_string(shell_quote_command_arg(profile_arg))
  cmd.write_string(" --invoke ")
  cmd.write_string(shell_quote_command_arg(invoke_name))
  cmd.write_string(" ")
  cmd.write_string(shell_quote_command_arg(wasm_path))
  cmd.to_string()
}

///|
fn compile_for_profile(
  entry_path : String,
  backend : ProfileBackend,
) -> Result[String, String] {
  let fs = @io.default_fs_adapter()
  match @loader.load_db_with_fs(entry_path, fs) {
    Err(err) => Err("profile: " + err)
    Ok((db, entry)) => {
      let wasm_bytes = match backend {
        ProfileBackend::WasmGc =>
          @runtime_compile.compile_module_wasm_gc(db, entry) catch {
            e => return Err("profile: " + e.user_message())
          }
        ProfileBackend::Wasm =>
          @runtime_compile.compile_module_wasm(db, entry) catch {
            e => return Err("profile: " + e.user_message())
          }
      }
      ensure_dist_dir_with(fs)
      let out_path = default_output_path(entry_path, CompileMode::Wasm)
      // default_output_path uses .wasm regardless of backend; that's fine
      // for the profile use-case.
      match @io.write_bytes_with(fs, out_path, wasm_bytes) {
        Ok(_) => Ok(out_path)
        Err(err) => Err("profile: write wasm: " + err)
      }
    }
  }
}

///|
fn profile_cmd(args : Array[String]) -> Unit {
  if has_help_flag(args) {
    print_profile_help()
    return
  }
  let opts = match parse_profile_cmd_args(args) {
    Ok(v) => v
    Err(msg) => abort(msg)
  }
  let wasm_path = match compile_for_profile(opts.entry_path, opts.backend) {
    Ok(p) => p
    Err(err) => abort(err)
  }
  let runner = match resolve_bench_wasm_runner(opts.entry_path) {
    Ok(r) => r
    Err(err) => abort("profile: " + err)
  }
  // wasmtime's --invoke can only be passed once per run, and
  // --profile=guest,<path> overwrites the file on each run. If the user
  // wants longer profile traces, they should call their entry point
  // multiple times from inside the vibe source (or bump --interval-us
  // down). We honour --iterations by running wasmtime N times and
  // writing each profile to a numbered sibling path so none of them
  // are clobbered.
  let mut last_status = 0
  let final_paths : Array[String] = []
  for i in 0..<opts.iterations {
    let iter_out = if opts.iterations == 1 {
      opts.out_path
    } else {
      let base = opts.out_path
      let suffix = "." + (i + 1).to_string() + ".json"
      if base.has_suffix(".json") {
        base.substring(start=0, end=base.length() - 5) + suffix
      } else {
        base + suffix
      }
    }
    let cmd = build_wasmtime_profile_command(
      runner,
      wasm_path,
      opts.invoke_name,
      iter_out,
      opts.interval_us,
    )
    let status = c_system(system_command_bytes(cmd))
    last_status = status
    if status != 0 {
      break
    }
    final_paths.push(iter_out)
  }
  if !opts.keep_wasm {
    remove_file_if_exists(wasm_path)
  }
  if last_status != 0 {
    abort(
      "profile: wasmtime exited with status " +
      last_status.to_string() +
      " (see stderr above)",
    )
  }
  for p in final_paths {
    println(
      "[profile] " + opts.interval_us.to_string() + "us interval → " + p,
    )
  }
  println(
    "[profile] view at https://profiler.firefox.com/ (drop the JSON onto the page)",
  )
}
