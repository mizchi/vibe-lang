///|
/// CLI entry logic for vibe
pub fn run(args : Array[String]) -> Unit {
  let internal_parent_pid = internal_parent_pid_env()
  match internal_parent_pid {
    Some(parent_pid) => {
      vibe_worker_process_group_init()
      vibe_worker_parent_watchdog_start(parent_pid)
    }
    None => ()
  }
  defer vibe_worker_parent_watchdog_stop()
  let parsed = match parse_cli_dispatch_args(args) {
    Ok(v) => v
    Err(_) => {
      print_usage()
      return
    }
  }
  let cmd = parsed.cmd
  let cmd_args = parsed.cmd_args
  let syntax_mode = parsed.syntax_mode
  let runtime_features = @runtime.RuntimeFeatureFlags::new(
    parsed.unstable_async,
    parsed.unstable_threads,
  )
  let enable_llm = parsed.enable_llm
  @runtime_compile.init_hooks()
  match cmd {
    "run" => run_cmd(cmd_args, syntax_mode, runtime_features, enable_llm~)
    "eval" => eval_cmd(cmd_args, runtime_features, enable_llm~)
    "test" => test_cmd(cmd_args, runtime_features)
    "check" => check_cmd(cmd_args)
    "session-http" => session_http_cmd(cmd_args, runtime_features)
    "session-json" => session_json_cmd(cmd_args, runtime_features)
    "finalize" => finalize_cmd(cmd_args)
    "apply" => apply_cmd(cmd_args)
    "symbols" => symbols_cmd(cmd_args)
    "init" => init_cmd(cmd_args)
    "new" => new_cmd(cmd_args)
    "history" => history_cmd(cmd_args)
    "write-file" | "write_file" => write_file_cmd(cmd_args)
    "fmt" => fmt_cmd(cmd_args)
    "normalize" => normalize_cmd(cmd_args)
    "compile" => compile_cmd(cmd_args)
    "build" => build_cmd(cmd_args)
    "clean" => clean_cmd(cmd_args)
    "emit-module-source" => emit_module_source_cmd(cmd_args)
    "emit-closure-payload" => emit_closure_payload_cmd(cmd_args)
    "compile-closure-payload" => compile_closure_payload_cmd(cmd_args)
    "compile-lite" => compile_lite_cmd(cmd_args)
    "precompile" => precompile_cmd(cmd_args)
    "bench" => bench_cmd(cmd_args, syntax_mode, runtime_features)
    "bench-file" => bench_file_cmd(cmd_args, runtime_features)
    "shell" => repl_cmd(cmd_args, syntax_mode, runtime_features, enable_llm~)
    "shell-stdin" =>
      repl_stdin_cmd(
        cmd_args,
        @runtime.ParserMode::PosixMode,
        runtime_features,
        enable_llm~,
      )
    "wasm-shell-stdin" => wasm_repl_stdin_cmd(cmd_args)
    "hash" => hash_cmd(cmd_args)
    "save" => save_cmd(cmd_args)
    "fetch" => fetch_cmd(cmd_args)
    "update-lock" => fetch_cmd(cmd_args)
    "explain-import" => explain_import_cmd(cmd_args)
    "expand" => expand_cmd(cmd_args)
    "ide" => ide_cmd(cmd_args)
    "lsif" => lsif_cmd(cmd_args)
    "index" => index_cmd(cmd_args)
    "bundle" =>
      abort(
        "bundle: command was removed. Use 'vibe compile' to compile modules, or 'vibe precompile' for precompilation.",
      )
    "serve" =>
      println(
        "serve: use 'just serve <handler.vibe>' or 'bash scripts/vibe_serve.sh <handler.vibe>'",
      )
    "lsp" => lsp_cmd(cmd_args)
    "help" =>
      if cmd_args.length() > 0 {
        print_subcommand_help(cmd_args[0])
      } else {
        print_usage()
      }
    _ => {
      println("unknown command: " + cmd)
      print_usage()
    }
  }
}

///|
extern "C" fn vibe_parallel_cleanup_install_signal_handlers() = "vibe_parallel_cleanup_install_signal_handlers"

///|
extern "C" fn vibe_parallel_cleanup_clear() = "vibe_parallel_cleanup_clear"

///|
extern "C" fn vibe_parallel_cleanup_register_child_pid(pid : Int) = "vibe_parallel_cleanup_register_child_pid"

///|
extern "C" fn vibe_parallel_cleanup_unregister_child_pid(pid : Int) = "vibe_parallel_cleanup_unregister_child_pid"

///|
extern "C" fn vibe_parallel_cleanup_assign_child_process_group(pid : Int) = "vibe_parallel_cleanup_assign_child_process_group"

///|
extern "C" fn vibe_worker_process_group_init() = "vibe_worker_process_group_init"

///|
extern "C" fn vibe_worker_parent_watchdog_start(parent_pid : Int) = "vibe_worker_parent_watchdog_start"

///|
extern "C" fn vibe_worker_parent_watchdog_stop() = "vibe_worker_parent_watchdog_stop"

///|
fn print_usage() -> Unit {
  println("Usage: vibe <command> [options]")
  println("")
  println("Build & Run:")
  println(
    "  run <file>                  Execute a script (final top-level pure expression)",
  )
  println("  test <file|dir...>          Run test blocks (parallel for dirs)")
  println("  compile <file> [-o <out>]   Compile to WASM or other targets")
  println("  build <file>                Full pipeline build")
  println("  bench <file|dir...>         Run benchmark blocks")
  println("  serve <file>                Serve HTTP handler (WASI P3)")
  println("")
  println("Development:")
  println("  shell                       Interactive TUI shell")
  println("  fmt <file...>               Format scripts")
  println("  check <file...>             Type check scripts")
  println("  normalize <file...>         Normalize declaration order")
  println("")
  println("IDE & Tooling:")
  println("  lsp                         Start language server")
  println(
    "  ide <subcommand> <file>     IDE queries (outline, peek-def, search)",
  )
  println("  symbols <file>              List symbols")
  println("")
  println("Project:")
  println("  init [dir]                  Initialize project")
  println("  new <dir>                   Scaffold new project")
  println("  fetch <file>                Resolve imports and sync lock")
  println("")
  println("Flags:")
  println("  --syntax vibe               Parser mode")
  println("  --unstable-async            Enable async runtime")
  println("  --unstable-threads          Enable threads runtime")
  println(
    "  --llm                       Enable LLM capabilities (requires VIBE_LLM_PROVIDER)",
  )
  println("")
  println("Run 'vibe <command> --help' for command-specific options.")
}

///|
fn print_subcommand_help(cmd : String) -> Unit {
  match cmd {
    "compile" => print_compile_help()
    "test" => print_test_help()
    "run" => print_run_help()
    "check" => print_check_help()
    "fmt" => print_fmt_help()
    "bench" => print_bench_help()
    "build" => print_build_help()
    "normalize" => print_normalize_help()
    _ => {
      println("No detailed help for '" + cmd + "'.")
      println("")
      print_usage()
    }
  }
}

///|
fn has_help_flag(args : Array[String]) -> Bool {
  for arg in args {
    if arg == "--help" || arg == "-h" {
      return true
    }
  }
  false
}

///|
fn print_compile_help() -> Unit {
  println("Usage: vibe compile [options] <file>")
  println("")
  println("Compile a vibe source file. Output defaults to dist/.")
  println("")
  println("Target format (pick one):")
  println("  --wasm              Core WASM (default)")
  println("  --wasm-js-string    Core WASM with JS string builtins")
  println("  --wasm-gc           WASM GC")
  println("  --component         Component Model WASM")
  println("  --wac               WAC composition")
  println("  --wit               Emit WIT interface")
  println("  --wit-component     WIT + Component")
  println("")
  println("Options:")
  println("  -o <path>           Output path (default: dist/)")
  println("  -O{0,1,2,3,4,s,z}  Optimization level")
  println("  --no-dce            Disable dead code elimination")
  println("  --debug-errors      Keep throw string literals in output")
  println(
    "  --coverage          Enable coverage (test only, set VIBE_TEST_COVERAGE=1)",
  )
  println("  --coverage-run-tests  Run test blocks in coverage mode")
  println("  --http-host-imports Wire HTTP builtins to host imports")
  println("  --library           Library mode")
}

///|
fn print_test_help() -> Unit {
  println("Usage: vibe test [options] <file|dir...>")
  println("")
  println("Run test blocks. Directories are tested in parallel.")
  println("")
  println("Options:")
  println(
    "  --jobs <N>          Parallel jobs (default: VIBE_TEST_JOBS or 1, max 16)",
  )
  println("  --report-json       Output results as JSON")
  println("  --no-cache          Disable test result caching")
}

///|
fn print_run_help() -> Unit {
  println("Usage: vibe run <file>")
  println("")
  println("Execute a vibe script. The final top-level expression must be pure.")
  println("")
  println("Environment:")
  println(
    "  VIBE_RUN_BACKEND=release|monolithic  Disable linked debug fast path",
  )
  println("  VIBE_USE_SESSION_HTTP=0              Disable session worker")
}

///|
fn print_check_help() -> Unit {
  println("Usage: vibe check [options] <file...>")
  println("")
  println("Parse and type check vibe scripts.")
  println("")
  println("Options:")
  println("  --profile-tsv <path>   Write profiling data to TSV file")
  println("  --builtin-contract <error|warn|ignore>  Builtin contract mode")
}

///|
fn print_fmt_help() -> Unit {
  println("Usage: vibe fmt [options] <file...>")
  println("")
  println("Normalize and format vibe scripts.")
  println("")
  println("Options:")
  println("  --dry-run           Show diff without writing changes")
  println("  --write, -w         Write changes (default behavior)")
}

///|
fn print_bench_help() -> Unit {
  println("Usage: vibe bench [options] <file|dir...>")
  println("")
  println("Run `bench {}` blocks.")
  println("")
  println("Options:")
  println("  --backend compiled  Use compiled backend")
  println("  --runs <N>          Number of benchmark runs")
  println("  --warmup <N>        Number of warmup iterations")
  println("  --n <N>             Iterations per run")
}

///|
fn print_build_help() -> Unit {
  println("Usage: vibe build [options] <file>")
  println("")
  println("Full pipeline build (compile + optimize).")
  println("")
  println("Options:")
  println("  -o <path>           Output path")
  println("  --release           Release build")
  println("  --debug             Debug build (default)")
}

///|
fn print_normalize_help() -> Unit {
  println("Usage: vibe normalize [options] <file...>")
  println("")
  println("Normalize declaration order and apply DCE + formatting.")
  println("")
  println("Options:")
  println("  --write             Write changes to files (default)")
  println("  --check             Check only, exit 1 if changes needed")
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
fn new_runtime_with_features(
  features : @runtime.RuntimeFeatureFlags,
) -> @runtime.Runtime {
  @runtime.Runtime::new_with_features(
    @capability.CapabilitySet::developer(),
    features,
  )
}

///|
fn new_runtime_with_llm(
  features : @runtime.RuntimeFeatureFlags,
) -> @runtime.Runtime {
  let caps = @capability.CapabilitySet::developer()
    .add(@capability.Capability::llm_call(["*"]))
    .add(@capability.Capability::net_connect("*", None))
  @runtime.Runtime::new_with_features(caps, features)
}

///|
fn new_cli_runtime(
  features : @runtime.RuntimeFeatureFlags,
  enable_llm~ : Bool,
) -> @runtime.Runtime {
  if enable_llm {
    new_runtime_with_llm(features)
  } else {
    new_runtime_with_features(features)
  }
}

///|
fn short_hash(hash : String) -> String {
  if hash.length() <= 7 {
    hash
  } else {
    hash[0:7].to_string()
  }
}

///|
enum CompletionAnchor {
  Above
  Below
}

///|
fn pick_completion_anchor(
  current : CompletionAnchor?,
  available_above : Int,
  available_below : Int,
) -> CompletionAnchor? {
  let can_above = available_above >= 1
  let can_below = available_below >= 1
  match current {
    Some(anchor) =>
      match anchor {
        CompletionAnchor::Above => if can_above { return Some(anchor) }
        CompletionAnchor::Below => if can_below { return Some(anchor) }
      }
    None => ()
  }
  if can_below {
    Some(CompletionAnchor::Below)
  } else if can_above {
    Some(CompletionAnchor::Above)
  } else {
    None
  }
}

///|
/// Get basename from a file path (without extension)
fn get_basename(path : String) -> String {
  // Find last slash
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
  // Remove extension
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
/// WIT identifier sanitizer for component-facing package/world names.
/// - lowercase
/// - `_` and invalid chars become `-`
/// - leading non-letter gets `x-` prefix
fn sanitize_wit_ident(raw : String) -> String {
  let out = StringBuilder::new()
  let mut last_dash = false
  for _, c in raw {
    let mut ch = c
    if Char::is_ascii_uppercase(ch) {
      ch = Char::to_ascii_lowercase(ch)
    }
    if Char::is_ascii_lowercase(ch) || Char::is_ascii_digit(ch) || ch == '-' {
      out.write_char(ch)
      last_dash = ch == '-'
    } else if ch == '_' || ch == '.' || ch == ' ' {
      if not(last_dash) {
        out.write_char('-')
        last_dash = true
      }
    } else if not(last_dash) {
      out.write_char('-')
      last_dash = true
    }
  }
  let normalized = out.to_string().trim().to_string()
  let candidate = if normalized.length() == 0 { "main" } else { normalized }
  let mut first = 'a'
  for _, c in candidate {
    first = c
    break
  }
  if first >= 'a' && first <= 'z' {
    candidate
  } else {
    "x-" + candidate
  }
}

///|
/// Ensure dist directory exists
fn ensure_dist_dir_with(fs : &@io.FileSystemAdapter) -> Unit {
  if not(@io.path_exists_with(fs, "dist")) {
    match @io.create_dir_with(fs, "dist") {
      Ok(_) => ()
      Err(err) => abort("compile: failed to create dist/: " + err)
    }
  }
}

///|
fn ensure_dist_dir() -> Unit {
  ensure_dist_dir_with(@io.default_fs_adapter())
}

///|
/// Get default output path for a given mode and input file
fn default_output_path(input_path : String, mode : CompileMode) -> String {
  let basename = get_basename(input_path)
  match mode {
    CompileMode::Ir => "dist/" + basename + ".ir"
    CompileMode::Wasm => "dist/" + basename + ".wasm"
    CompileMode::WasmJsString => "dist/" + basename + ".wasm"
    CompileMode::WasmGc => "dist/" + basename + ".wasm"
    CompileMode::Component => "dist/" + basename + ".component.wasm"
    CompileMode::ComponentStringLift => "dist/" + basename + ".component.wasm"
    CompileMode::ComposeP3 => "dist/" + basename + ".p3.component.wasm"
    CompileMode::Wac => "dist/" + basename + ".component.wasm"
    CompileMode::Wit => "dist/" + basename + ".wit"
    CompileMode::WitComponent => "dist/" + basename + ".component.wit"
  }
}

///|
fn coverage_point_kind_name(
  kind : @runtime_compile.WasmCoveragePointKind,
) -> String {
  match kind {
    @runtime_compile.WasmCoveragePointKind::Line => "line"
    @runtime_compile.WasmCoveragePointKind::BranchIfThen => "branch_if_then"
    @runtime_compile.WasmCoveragePointKind::BranchIfElse => "branch_if_else"
    @runtime_compile.WasmCoveragePointKind::BranchMatchArm => "branch_match_arm"
  }
}

///|
fn coverage_point_json(
  source : String,
  point : @runtime_compile.WasmCoveragePoint,
) -> Json {
  let obj : Map[String, Json] = {}
  let span_obj : Map[String, Json] = {}
  span_obj["start"] = Json::number(point.span.start.to_double())
  span_obj["end"] = Json::number(point.span.end.to_double())
  obj["id"] = Json::number(point.id.to_double())
  obj["kind"] = Json::string(coverage_point_kind_name(point.kind))
  obj["span"] = Json::object(span_obj)
  obj["range"] = @lsp.range_to_json(@lsp.span_to_range(source, point.span))
  Json::object(obj)
}

///|
fn write_wasm_coverage_sidecar_with(
  fs : &@io.FileSystemAdapter,
  out_path : String,
  entry_path : String,
  source : String,
  coverage : @runtime_compile.WasmCoverageArtifact,
) -> Unit {
  let points : Array[Json] = []
  for point in coverage.points {
    points.push(coverage_point_json(source, point))
  }
  let obj : Map[String, Json] = {}
  obj["format"] = Json::string("vibe-wasm-coverage-v1")
  obj["entry_path"] = Json::string(entry_path)
  obj["counter_base"] = Json::number(coverage.counter_base.to_double())
  obj["counter_count"] = Json::number(coverage.counter_count.to_double())
  obj["points"] = Json::array(points)
  let sidecar_path = out_path + ".cov.json"
  match
    @io.write_string_with(
      fs,
      sidecar_path,
      Json::object(obj).stringify() + "\n",
    ) {
    Ok(_) => println("wrote " + sidecar_path)
    Err(err) => abort("compile: " + err)
  }
}

///|
fn parse_bool_flag(value : String) -> Bool {
  let normalized = value.trim().to_string().to_lower()
  match normalized {
    "1" | "true" | "yes" | "on" => true
    "0" | "false" | "no" | "off" => false
    _ =>
      abort(
        "invalid boolean value: '" +
        value +
        "'. Expected: true/false, yes/no, on/off, 1/0",
      )
  }
}

///|
fn check_debug_enabled() -> Bool {
  match @sys.get_env_var("VIBE_CHECK_DEBUG") {
    Some(raw) => parse_bool_flag(raw)
    None => true
  }
}

///|
fn compile_coverage_test_mode_enabled() -> Bool {
  match @sys.get_env_var("VIBE_TEST_COVERAGE") {
    Some(raw) => parse_bool_flag(raw)
    None => false
  }
}

///|
fn ensure_compile_coverage_allowed(
  coverage : Bool,
  test_mode_enabled : Bool,
) -> Result[Unit, String] {
  if not(coverage) || test_mode_enabled {
    Ok(())
  } else {
    Err("compile: --coverage is test-only (set VIBE_TEST_COVERAGE=1)")
  }
}

///|
fn optimize_wasm_bytes_with_opt_level_for_cli(
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
fn default_wac_config_path(wac_path : String) -> String {
  @vibe_fs.parent_path(wac_path) + "/wite.config.jsonc"
}

///|
fn sync_wac_dependencies_if_configured(
  wac_path : String,
  fs : &@io.FileSystemAdapter,
) -> Result[UInt, String] {
  let config_path = default_wac_config_path(wac_path)
  if not(@io.path_exists_with(fs, config_path)) {
    return Ok(0U)
  }
  @wite_deps.materialize_wac_dependencies_from_config(
    config_path, wac_path, false,
  )
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
  if opts.coverage || opts.coverage_run_tests {
    return Err(
      "compile-lite: --coverage/--coverage-run-tests are not supported",
    )
  }
  if opts.debug_errors {
    return Err("compile-lite: --debug-errors is not supported")
  }
  if opts.http_host_imports {
    return Err("compile-lite: --http-host-imports is not supported")
  }
  if opts.force_cabi_realloc {
    return Err("compile-lite: --force-cabi-realloc is not supported")
  }
  if opts.is_async {
    return Err("compile-lite: --async is not supported")
  }
  if opts.adapter_path is Some(_) {
    return Err("compile-lite: --adapter is not supported")
  }
  if not(in_memory) && opts.out_path is None {
    return Err("compile-lite: -o/--out is required")
  }
  Ok(())
}

///|
fn split_compile_lite_args(
  args : Array[String],
) -> Result[(Array[String], String?, String?, Bool), String] {
  let filtered : Array[String] = []
  let mut profile_tsv : String? = None
  let mut profile_callstack : String? = None
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
    } else if arg == "--profile-callstack" {
      i += 1
      if i >= args.length() {
        return Err("compile-lite: missing path after --profile-callstack")
      }
      profile_callstack = Some(args[i])
    } else if arg == "--in-memory" {
      in_memory = true
    } else {
      filtered.push(arg)
    }
    i += 1
  }
  Ok((filtered, profile_tsv, profile_callstack, in_memory))
}

///|
fn remove_file_if_exists(path : String) -> Unit {
  if not(@os_fs.path_exists(path)) {
    return
  }
  let is_file = @os_fs.is_file(path) catch { _ => false }
  if is_file {
    ignore(@os_fs.remove_file(path) catch { _ => () })
  }
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
fn elapsed_ms_from_us(elapsed_us : Int) -> Int {
  let elapsed_ms = elapsed_us / 1000
  if elapsed_ms <= 0 {
    1
  } else {
    elapsed_ms
  }
}
