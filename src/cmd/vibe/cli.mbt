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
  if command_requires_parser(cmd) {
    match ensure_cli_parser_mode_supported(syntax_mode, cmd) {
      Ok(_) => ()
      Err(msg) => abort(msg)
    }
  }
  match cmd {
    "run" => run_cmd(cmd_args, syntax_mode, runtime_features, enable_llm~)
    "eval" =>
      abort(
        "eval: command was removed from public CLI; use shell/shell-stdin for interactive evaluation or compile/run workflows",
      )
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
    "write_file" => write_file_cmd(cmd_args)
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
      repl_stdin_cmd(cmd_args, syntax_mode, runtime_features, enable_llm~)
    "shell-wasi" => abort("shell-wasi: command was removed from public CLI")
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
    "bundle" => abort("bundle commands have been removed")
    "lsp" => lsp_cmd(cmd_args)
    "help" => print_usage()
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
  println("vibe <command> [args]")
  println("")
  println("commands:")
  println("  run <file>                 run a script (requires `let main`)")
  println("    demo: vibe run vibe/x/args/demo.vibe")
  println(
    "  test [--jobs N] <file|dir...>  run test blocks (parallel for dirs; default jobs=VIBE_TEST_JOBS or 1, max 16)",
  )
  println("  check [--profile-tsv path] <file...>  parse/type check scripts")
  println(
    "  session-http --port N        internal: persistent localhost JSON session for run/check/test",
  )
  println(
    "  session-json                internal: persistent stdin/stdout JSON session for run/check/test",
  )
  println(
    "  emit-module-source <in> <out> <entry>  internal: extract entry-pruned module source",
  )
  println(
    "  emit-closure-payload <in> <out>  internal: materialize transitive closure payload",
  )
  println(
    "  compile-closure-payload <in> <out> [mvp|no-dce]  internal: compile closure payload to wasm",
  )
  println(
    "  finalize [--db file] [--export file] [--library] [--print] [--dry-run]  refactor scratch/db source",
  )
  println(
    "  apply <file>               resolve lock+graph head and apply artifacts",
  )
  println(
    "  symbols [--json] <file>    list symbols and index inclusion status",
  )
  println(
    "  init [dir]                 create index.vibe/index.lock/.vibe in target root",
  )
  println(
    "  new <dir>                  scaffold a new project root (init + main.vibe)",
  )
  println("  history reset              reset scratch namespace history/db")
  println(
    "  write_file [--entry file] [--no-deps] [--dry-run] [--json] <selector> <out-file>  materialize selector",
  )
  println("  fmt [--dry-run] <file...>  normalize + format scripts")
  println(
    "  normalize [--write|--check] <file...>  normalize declaration order + DCE (+fmt)",
  )
  println(
    "  compile [--wasm | --wasm-js-string | --wasm-gc | --component | --wac | --wit | --wit-component] [--no-dce] [--coverage] [--coverage-run-tests] [--debug-errors] [--http-host-imports] [--wite|-O{0,1,2,3,4,s,z}] [-o out] <file>",
  )
  println(
    "                                     emit to dist/ (or -o path). Formats: IR, Core WASM, Component WASM",
  )
  println(
    "                                     --coverage is test-only (set VIBE_TEST_COVERAGE=1)",
  )
  println(
    "                                     --coverage-run-tests executes top-level test blocks in coverage mode",
  )
  println(
    "                                     --debug-errors keeps throw string literals in wasm (debug builds)",
  )
  println(
    "                                     --http-host-imports wires HTTP builtins to host imports (--wasm: vibe:http/*, --component: wasi:http/* shim)",
  )
  println(
    "  compile-lite --wasm [--no-dce] [--in-memory] [--profile-tsv path] [-O{0,1,2,3,4,s,z}] [-o out] <file>",
  )
  println(
    "                                     minimal compile path for strict perf comparison (no coverage/debug/http/component)",
  )
  println(
    "  precompile [--out-dir dir] [--wasm|--wasm-js-string] [-O<level>] <dir...>",
  )
  println(
    "                                     precompile .vibe modules to .wasm",
  )
  println(
    "  bench [--backend compiled] [--runs N] [--warmup N] [--n N] <file|dir...>  run `bench {}` blocks",
  )
  println("  bench-file [--n N] [--warmup N] <file>")
  println("  shell                       interactive TUI shell")
  println(
    "  shell-stdin [--no-prompt] [--tty|--no-tty]  read-eval-print loop (stdin)",
  )
  println(
    "  wasm-shell-stdin [--no-prompt] [-o dir]  compile each expr to WASM",
  )
  println("  hash <file>                 compute normalized AST hash")
  println(
    "  save <file>                 save module to content-addressed store",
  )
  println(
    "  fetch <file>                resolve imports and sync lock payload (index.lock)",
  )
  println("  update-lock <file>          alias for fetch")
  println(
    "  explain-import <file>       visualize import ref normalization and lock lookup",
  )
  println(
    "  ide <outline|peek-def|search> ... [--semantic-rows rows.json]  symbol/type index queries",
  )
  println(
    "  lsif [-o out.lsif] [--semantic-rows rows.json] <file>   emit LSIF via shared symbol index",
  )
  println(
    "  index <build|query|verify|wal|ref> ...  advanced graph index (POC)",
  )
  println(
    "    ref: push|pull|push-delta|pull-delta <scope> <file>  git/bit distributed refs",
  )
  println("")
  println("  lsp                         start LSP server (stdin/stdout)")
  println(
    "  parser commands: --syntax vibe (public CLI); posix-ext/posix-strict are internal-only",
  )
  println("  runtime flags: --unstable-async --unstable-threads")
  println(
    "  exec backend env: VIBE_RUN_BACKEND=compiled|auto (default: compiled), VIBE_TEST_BACKEND=compiled|auto (default: compiled)",
  )
  println(
    "                    run/check/test use a persistent localhost session worker by default; set VIBE_USE_SESSION_HTTP=0 to disable",
  )
  println(
    "  llm flags: --llm  enable LLM/RLM capabilities (requires VIBE_LLM_PROVIDER)",
  )
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
fn restore_cli_env_var(name : String, prev : String?) -> Unit {
  match prev {
    Some(value) => @sys.set_env_var(name, value)
    None => @sys.unset_env_var(name)
  }
}

///|
fn resolve_test_loop_fuel_env_value() -> String {
  match @sys.get_env_var("VIBE_TEST_LOOP_FUEL") {
    Some(raw) => raw
    None => "10000000"
  }
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
fn command_requires_parser(cmd : String) -> Bool {
  match cmd {
    "run"
    | "test"
    | "check"
    | "apply"
    | "symbols"
    | "normalize"
    | "compile"
    | "bench"
    | "bench-file"
    | "shell"
    | "shell-stdin"
    | "wasm-shell-stdin"
    | "hash"
    | "save"
    | "fetch"
    | "update-lock" => true
    _ => false
  }
}

///|
fn short_hash(hash : String) -> String {
  if hash.length() <= 7 {
    hash
  } else {
    (try! hash[0:7]).to_string()
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
    _ => false
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
  if opts.mode != CompileMode::Wasm {
    return Err("compile-lite: only --wasm mode is supported")
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

///|
fn compile_lite_cmd(args : Array[String]) -> Unit {
  let (compile_args, profile_tsv, profile_callstack, in_memory) = match
    split_compile_lite_args(args) {
    Ok(v) => v
    Err(msg) => abort(msg)
  }
  let opts = match parse_compile_cmd_args(compile_args) {
    Ok(v) => v
    Err(msg) => abort(msg)
  }
  match compile_lite_validate_opts(opts, in_memory) {
    Ok(_) => ()
    Err(msg) => abort(msg)
  }
  if profile_callstack is Some(_) {
    @profiler.profiler_set_enabled(true)
    @profiler.profiler_reset()
  }
  let fs = @io.default_fs_adapter()
  let out_path = match opts.out_path {
    Some(path) => path
    None => ""
  }
  let start_total = @bench.monotonic_clock_start()
  @profiler.profiler_enter("load")
  let start_load = @bench.monotonic_clock_start()
  match @loader.load_db_with_fs(opts.entry_path, fs) {
    Err(err) => abort("compile-lite: " + err)
    Ok((db, entry)) => {
      let load_us = elapsed_us_from(start_load)
      @profiler.profiler_leave()
      @profiler.profiler_enter("type")
      let start_type = @bench.monotonic_clock_start()
      let _ = db.types(entry)
      let type_us = elapsed_us_from(start_type)
      @profiler.profiler_leave()
      let (wasm_bytes, compile_profile) = @runtime_compile.compile_module_wasm_with_opt_level_profiled(
        db,
        entry,
        no_dce=opts.no_dce,
        opt_level=opts.opt_level,
        debug_errors=false,
        http_host_imports=false,
        force_cabi_realloc=false,
      ) catch {
        e => abort("compile-lite: " + e.user_message())
      }
      let mut write_us = 0
      if not(in_memory) {
        @profiler.profiler_enter("write")
        let start_write = @bench.monotonic_clock_start()
        match @io.write_bytes_with(fs, out_path, wasm_bytes) {
          Ok(_) => ()
          Err(err) => abort("compile-lite: " + err)
        }
        write_us = elapsed_us_from(start_write)
        @profiler.profiler_leave()
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
              abort("compile-lite: failed to write profile tsv: " + err)
          }
        }
        None => ()
      }
      match profile_callstack {
        Some(path) => {
          let content = @profiler.profiler_report_tsv()
          match @io.write_string_with(fs, path, content) {
            Ok(_) => ()
            Err(err) =>
              abort("compile-lite: failed to write callstack profile: " + err)
          }
        }
        None => ()
      }
    }
  }
}

///|
fn compile_cmd(args : Array[String]) -> Unit {
  let opts = match parse_compile_cmd_args(args) {
    Ok(v) => v
    Err(msg) => abort(msg)
  }
  match
    ensure_compile_coverage_allowed(
      opts.coverage,
      compile_coverage_test_mode_enabled(),
    ) {
    Ok(_) => ()
    Err(msg) => abort(msg)
  }
  let fs = @io.default_fs_adapter()
  if opts.mode == CompileMode::Wac {
    let resolved_out = match opts.out_path {
      Some(path) => path
      None => {
        ensure_dist_dir_with(fs)
        default_output_path(opts.entry_path, opts.mode)
      }
    }
    let synced_count = match
      sync_wac_dependencies_if_configured(opts.entry_path, fs) {
      Ok(v) => v
      Err(msg) => abort("compile: wac deps sync failed: " + msg)
    }
    if synced_count > 0U {
      println("materialized wac deps: " + synced_count.to_string())
    }
    let component = match
      @wite_bundle.compose_wac_file(opts.entry_path, dce=true) {
      Ok(bytes) => bytes
      Err(msg) => abort("compile: wac compose failed: " + msg)
    }
    let optimized = match
      optimize_wasm_bytes_with_opt_level_for_cli(component, opts.opt_level) {
      Ok(bytes) => bytes
      Err(msg) => abort(msg)
    }
    match @io.write_bytes_with(fs, resolved_out, optimized) {
      Ok(_) => ()
      Err(err) => abort("compile: " + err)
    }
    println("wrote " + resolved_out)
    return
  }
  match @loader.load_db_with_fs(opts.entry_path, fs) {
    Err(err) => abort("compile: " + err)
    Ok((db, entry)) => {
      // Resolve output path with default to dist/
      let resolved_out = match opts.out_path {
        Some(path) => path
        None => {
          ensure_dist_dir_with(fs)
          default_output_path(opts.entry_path, opts.mode)
        }
      }
      match opts.mode {
        CompileMode::Ir => {
          let compiled = @runtime_compile.compile_module(db, entry) catch {
            e => abort("compile: " + e.to_string())
          }
          match @io.write_string_with(fs, resolved_out, compiled.ir) {
            Ok(_) => ()
            Err(err) => abort("compile: " + err)
          }
          println("wrote " + resolved_out)
        }
        CompileMode::Wasm =>
          if opts.coverage {
            let coverage = @runtime_compile.compile_module_wasm_with_coverage(
              db,
              entry,
              no_dce=opts.no_dce,
              opt_level=opts.opt_level,
              run_tests=opts.coverage_run_tests,
              debug_errors=opts.debug_errors,
              http_host_imports=opts.http_host_imports,
            ) catch {
              e => abort("compile: " + e.user_message())
            }
            match @io.write_bytes_with(fs, resolved_out, coverage.bytes) {
              Ok(_) => ()
              Err(err) => abort("compile: " + err)
            }
            println("wrote " + resolved_out)
            let source = match db.get_source(entry) {
              Some(s) => s
              None => ""
            }
            write_wasm_coverage_sidecar_with(
              fs,
              resolved_out,
              opts.entry_path,
              source,
              coverage,
            )
          } else {
            let wasm_bytes = @runtime_compile.compile_module_wasm_with_opt_level(
              db,
              entry,
              no_dce=opts.no_dce,
              opt_level=opts.opt_level,
              debug_errors=opts.debug_errors,
              http_host_imports=opts.http_host_imports,
              force_cabi_realloc=opts.force_cabi_realloc,
              library_mode=opts.library_mode,
            ) catch {
              e => abort("compile: " + e.user_message())
            }
            match @io.write_bytes_with(fs, resolved_out, wasm_bytes) {
              Ok(_) => ()
              Err(err) => abort("compile: " + err)
            }
            println("wrote " + resolved_out)
          }
        CompileMode::WasmJsString =>
          if opts.coverage {
            let coverage = @runtime_compile.compile_module_wasm_js_string_with_coverage(
              db,
              entry,
              no_dce=opts.no_dce,
              opt_level=opts.opt_level,
              run_tests=opts.coverage_run_tests,
              debug_errors=opts.debug_errors,
            ) catch {
              e => abort("compile: " + e.user_message())
            }
            match @io.write_bytes_with(fs, resolved_out, coverage.bytes) {
              Ok(_) => ()
              Err(err) => abort("compile: " + err)
            }
            println("wrote " + resolved_out)
            let source = match db.get_source(entry) {
              Some(s) => s
              None => ""
            }
            write_wasm_coverage_sidecar_with(
              fs,
              resolved_out,
              opts.entry_path,
              source,
              coverage,
            )
          } else {
            let wasm_bytes = @runtime_compile.compile_module_wasm_js_string_with_opt_level(
              db,
              entry,
              no_dce=opts.no_dce,
              opt_level=opts.opt_level,
              debug_errors=opts.debug_errors,
            ) catch {
              e => abort("compile: " + e.user_message())
            }
            match @io.write_bytes_with(fs, resolved_out, wasm_bytes) {
              Ok(_) => ()
              Err(err) => abort("compile: " + err)
            }
            println("wrote " + resolved_out)
          }
        CompileMode::WasmGc => {
          let wasm_bytes = @runtime_compile.compile_module_wasm_gc_with_opt_level(
            db,
            entry,
            no_dce=opts.no_dce,
            opt_level=opts.opt_level,
          ) catch {
            e => abort("compile: " + e.user_message())
          }
          match @io.write_bytes_with(fs, resolved_out, wasm_bytes) {
            Ok(_) => ()
            Err(err) => abort("compile: " + err)
          }
          println("wrote " + resolved_out)
        }
        CompileMode::Component => {
          let wasm_bytes = @runtime_compile.compile_module_component_with_opt_level(
            db,
            entry,
            opt_level=opts.opt_level,
            http_host_imports=opts.http_host_imports,
          ) catch {
            e => abort("compile: " + e.user_message())
          }
          match @io.write_bytes_with(fs, resolved_out, wasm_bytes) {
            Ok(_) => ()
            Err(err) => abort("compile: " + err)
          }
          println("wrote " + resolved_out)
        }
        CompileMode::ComponentStringLift => {
          let wasm_bytes = @runtime_compile.compile_module_component_string_lift_auto(
            db,
            entry,
            opt_level=opts.opt_level,
            is_async=opts.is_async,
          ) catch {
            e => abort("compile: " + e.user_message())
          }
          match @io.write_bytes_with(fs, resolved_out, wasm_bytes) {
            Ok(_) => ()
            Err(err) => abort("compile: " + err)
          }
          println("wrote " + resolved_out)
        }
        CompileMode::ComposeP3 => {
          let adapter_path = match opts.adapter_path {
            Some(p) => p
            None => abort("compile: --compose-p3 requires --adapter")
          }
          // Step 1: Compile vibe → sync component (adapter handles async wrapping)
          let app_bytes = @runtime_compile.compile_module_component_string_lift_auto(
            db,
            entry,
            opt_level=opts.opt_level,
            is_async=false,
          ) catch {
            e => abort("compile: " + e.user_message())
          }
          // Step 2: Read adapter and compose with mwac plug
          let adapter_bytes = match @io.read_bytes_with(fs, adapter_path) {
            Ok(b) => b
            Err(err) => abort("compile: failed to read adapter: " + err)
          }
          // adapter = socket (imports handler), app = plug (exports handler)
          let composed = @runtime_compile.compose_p3_component(
            app_bytes, adapter_bytes,
          ) catch {
            e => abort("compile: " + e.user_message())
          }
          match @io.write_bytes_with(fs, resolved_out, composed) {
            Ok(_) => ()
            Err(err) => abort("compile: " + err)
          }
          println("wrote " + resolved_out)
        }
        CompileMode::Wac =>
          abort(
            "compile: internal error: --wac should bypass vibe source compilation",
          )
        CompileMode::Wit => {
          // Generate WIT with default package/world names derived from filename
          let basename = get_basename(entry)
          let package_name = "local:" + basename
          let world_name = basename
          let wit_str = @runtime_compile.generate_module_wit(
            db, entry, package_name, world_name,
          ) catch {
            e => abort("compile: " + e.user_message())
          }
          match @io.write_string_with(fs, resolved_out, wit_str) {
            Ok(_) => ()
            Err(err) => abort("compile: " + err)
          }
          println("wrote " + resolved_out)
        }
        CompileMode::WitComponent => {
          let basename = get_basename(entry)
          let wit_ident = sanitize_wit_ident(basename)
          let package_name = "local:" + wit_ident
          let world_name = wit_ident
          let wit_str = @runtime_compile.generate_module_component_wit(
            db, entry, package_name, world_name,
          ) catch {
            e => abort("compile: " + e.user_message())
          }
          match @io.write_string_with(fs, resolved_out, wit_str) {
            Ok(_) => ()
            Err(err) => abort("compile: " + err)
          }
          println("wrote " + resolved_out)
        }
      }
    }
  }
}

///|
fn[T] die(msg : String) -> T {
  println(msg)
  c_exit(1)
  abort("")
}

///|
enum CliExecBackendPref {
  Auto
  Compiled
} derive(Eq, Show)

///|
fn parse_cli_exec_backend_pref(raw : String) -> CliExecBackendPref {
  let value = raw.trim().to_string().to_lower()
  match value {
    "compiled" | "compile" | "wasm" => CliExecBackendPref::Compiled
    _ => CliExecBackendPref::Auto
  }
}

///|
fn resolve_cli_exec_backend_pref(env_name : String) -> CliExecBackendPref {
  match @sys.get_env_var(env_name) {
    Some(raw) => parse_cli_exec_backend_pref(raw)
    None => CliExecBackendPref::Auto
  }
}

///|
fn normalize_cli_entry_path(path : String) -> String {
  path.replace(old="\\", new="/")
}

///|
fn entry_prefers_compiled_backend(entry_path : String) -> Bool {
  let normalized = normalize_cli_entry_path(entry_path)
  let matched_normalized = normalized == "vibe/compiler" ||
    normalized.has_prefix("vibe/compiler/") ||
    normalized.has_suffix("/vibe/compiler") ||
    normalized.contains("/vibe/compiler/")
  if matched_normalized {
    return true
  }
  entry_path == "vibe\\compiler" ||
  entry_path.has_prefix("vibe\\compiler\\") ||
  entry_path.has_suffix("\\vibe\\compiler") ||
  entry_path.contains("\\vibe\\compiler\\")
}

///|
fn resolve_cli_exec_backend_pref_for_entry(
  env_name : String,
  entry_path : String,
) -> CliExecBackendPref {
  let pref = resolve_cli_exec_backend_pref(env_name)
  if pref == CliExecBackendPref::Auto {
    if entry_prefers_compiled_backend(entry_path) {
      return CliExecBackendPref::Compiled
    }
  }
  pref
}

///|
fn resolve_run_backend_pref(entry_path : String) -> CliExecBackendPref {
  match @sys.get_env_var("VIBE_RUN_BACKEND") {
    Some(_) =>
      resolve_cli_exec_backend_pref_for_entry("VIBE_RUN_BACKEND", entry_path)
    None => CliExecBackendPref::Compiled
  }
}

///|
fn cli_use_session_http_with(raw : String?, has_self_bin : Bool) -> Bool {
  match raw {
    Some(value) => parse_bool_flag(value)
    None => has_self_bin
  }
}

///|
fn cli_use_session_http() -> Bool {
  cli_use_session_http_with(
    @sys.get_env_var("VIBE_USE_SESSION_HTTP"),
    current_cli_binary_path() is Some(_),
  )
}

///|
fn first_non_empty_line(text : String) -> String {
  for line_view in text.split("\n") {
    let line = line_view.trim().to_string()
    if line.length() > 0 {
      return line
    }
  }
  ""
}

///|
fn last_non_empty_line(text : String) -> String {
  let mut out = ""
  for line_view in text.split("\n") {
    let line = line_view.trim().to_string()
    if line.length() > 0 {
      out = line
    }
  }
  out
}

///|
fn parse_numeric_line_int64(line : String) -> Int64? {
  let trimmed = line.trim().to_string()
  if trimmed.length() == 0 {
    return None
  }
  let mut has_digit = false
  for i, c in trimmed {
    if i == 0 && c == '-' {
      continue
    }
    if c < '0' || c > '9' {
      return None
    }
    has_digit = true
  }
  if not(has_digit) {
    return None
  }
  let value = @strconv.parse_int(trimmed) catch { _ => return None }
  Some(value.to_int64())
}

///|
fn parse_last_numeric_line_int64(text : String) -> Int64? {
  let mut out : Int64? = None
  for line_view in text.split("\n") {
    let line = line_view.to_string()
    match parse_numeric_line_int64(line) {
      Some(value) => out = Some(value)
      None => ()
    }
  }
  out
}

///|
struct WasmtimeInvokeOutput {
  status : Int
  stdout : String
  stderr : String
} derive(Show, Eq)

///|
struct HttpHostRunner {
  node_bin : String
  runner_script : String
} derive(Show, Eq)

///|
enum WasmRunValue {
  Int(Int64)
  Bool(Bool)
} derive(Show, Eq)

///|
fn run_wasmtime_invoke_run_capture(
  runner : BenchWasmRunner,
  wasm_path : String,
  tmp_prefix : String,
) -> WasmtimeInvokeOutput {
  run_wasmtime_invoke_named_capture(runner, wasm_path, tmp_prefix, "_start")
}

///|
fn run_wasmtime_invoke_named_capture(
  runner : BenchWasmRunner,
  wasm_path : String,
  tmp_prefix : String,
  invoke_name : String,
) -> WasmtimeInvokeOutput {
  let out_path = tmp_prefix + ".out"
  let err_path = tmp_prefix + ".err"
  let cmd = build_wasmtime_invoke_command(runner, wasm_path, invoke_name) +
    " >" +
    shell_quote_command_arg(out_path) +
    " 2>" +
    shell_quote_command_arg(err_path)
  let status = c_system(system_command_bytes(cmd))
  let stdout = @os_fs.read_file_to_string(out_path) catch { _ => "" }
  let stderr = @os_fs.read_file_to_string(err_path) catch { _ => "" }
  remove_file_if_exists(out_path)
  remove_file_if_exists(err_path)
  { status, stdout, stderr }
}

///|
fn resolve_http_host_runner(
  entry_path : String,
) -> Result[HttpHostRunner, String] {
  let node_bin = match @sys.get_env_var("NODE_BIN") {
    Some(raw) => {
      let value = raw.trim().to_string()
      if value.length() > 0 {
        value
      } else {
        match find_command_in_path("node") {
          Some(path) => path
          None =>
            return Err(
              "node not found in PATH (required for HTTP compiled backend)",
            )
        }
      }
    }
    None =>
      match find_command_in_path("node") {
        Some(path) => path
        None =>
          return Err(
            "node not found in PATH (required for HTTP compiled backend)",
          )
      }
  }
  let root_candidates : Array[String] = []
  let add_root = fn(root : String) -> Unit {
    if root.length() == 0 {
      return
    }
    for existing in root_candidates {
      if existing == root {
        return
      }
    }
    root_candidates.push(root)
  }
  add_root(project_root_for_path(entry_path))
  let argv = @env.args()
  if argv.length() > 0 {
    add_root(project_root_for_path(argv[0]))
  }
  add_root(project_root_for_path(@io.current_dir_or_root()))
  for project_root in root_candidates {
    let runner_script = project_root + "/scripts/wasm_http_host_runner.js"
    if is_existing_file(runner_script) {
      return Ok({ node_bin, runner_script })
    }
  }
  Err(
    "http host runner script not found under project roots: " +
    root_candidates.join(", "),
  )
}

///|
fn build_http_host_run_command(
  runner : HttpHostRunner,
  wasm_path : String,
) -> String {
  shell_quote_command_arg(runner.node_bin) +
  " " +
  shell_quote_command_arg(runner.runner_script) +
  " --invoke _start " +
  shell_quote_command_arg(wasm_path)
}

///|
fn run_http_host_invoke_run_capture(
  runner : HttpHostRunner,
  wasm_path : String,
  tmp_prefix : String,
) -> WasmtimeInvokeOutput {
  let out_path = tmp_prefix + ".out"
  let err_path = tmp_prefix + ".err"
  let cmd = build_http_host_run_command(runner, wasm_path) +
    " >" +
    shell_quote_command_arg(out_path) +
    " 2>" +
    shell_quote_command_arg(err_path)
  let status = c_system(system_command_bytes(cmd))
  let stdout = @os_fs.read_file_to_string(out_path) catch { _ => "" }
  let stderr = @os_fs.read_file_to_string(err_path) catch { _ => "" }
  remove_file_if_exists(out_path)
  remove_file_if_exists(err_path)
  { status, stdout, stderr }
}

///|
fn decode_tagged_wasm_run_value(tagged : Int64) -> WasmRunValue? {
  let tag = tagged & 3L
  if tag == 0L {
    return Some(WasmRunValue::Int(tagged >> 2))
  }
  if tag == 3L {
    return Some(WasmRunValue::Bool(tagged >> 2 != 0L))
  }
  None
}

///|
fn is_http_builtin_name(name : String) -> Bool {
  match name {
    "Http::request"
    | "Http::response_status"
    | "Http::response_header"
    | "Http::response_body"
    | "Http::close"
    | "Http::listen"
    | "Http::accept"
    | "Http::request_method"
    | "Http::request_url"
    | "Http::request_header"
    | "Http::request_body"
    | "Http::respond" => true
    _ => false
  }
}

///|
fn is_wasm_runtime_fallback_builtin_name(name : String) -> Bool {
  match name {
    "Json::parse"
    | "Json::stringify"
    | "Json::parse_lines"
    | "Json::stringify_lines"
    | "Lines::parse"
    | "Lines::stringify"
    | "Json::type_of"
    | "Json::string"
    | "Json::get"
    | "Json::index"
    | "Json::number"
    | "Json::bool"
    | "Json::is_null"
    | "Json::length"
    | "Json::keys"
    | "Fs::chdir"
    | "Fs::copy"
    | "Fs::readdir"
    | "Fs::is_dir"
    | "Fs::is_file"
    | "Fs::mkdir"
    | "Fs::mkdir_p"
    | "Fs::getcwd"
    | "Fs::remove"
    | "Fs::rename"
    | "Fs::append"
    | "Llm::complete"
    | "Rlm::run"
    | "Rlm::finalize"
    | "PromptText::new"
    | "PromptText::to_string"
    | "select"
    | "sh_lines"
    | "__perform"
    | "__resume" => true
    _ => false
  }
}

///|
fn expr_uses_wasm_runtime_fallback_builtins(expr : @vibe_core.Expr) -> Bool {
  match expr {
    @vibe_core.Expr::Call(name~, args~, ..) => {
      if is_wasm_runtime_fallback_builtin_name(name) {
        return true
      }
      for arg in args {
        if expr_uses_wasm_runtime_fallback_builtins(arg.expr) {
          return true
        }
      }
      false
    }
    @vibe_core.Expr::Tuple(items~, ..) => {
      for item in items {
        if expr_uses_wasm_runtime_fallback_builtins(item) {
          return true
        }
      }
      false
    }
    @vibe_core.Expr::TupleIndex(expr~, ..) =>
      expr_uses_wasm_runtime_fallback_builtins(expr)
    @vibe_core.Expr::Record(fields~, ..)
    | @vibe_core.Expr::StructLit(fields~, ..) => {
      for field in fields {
        if expr_uses_wasm_runtime_fallback_builtins(field.expr) {
          return true
        }
      }
      false
    }
    @vibe_core.Expr::Array(items~, ..) => {
      for item in items {
        if expr_uses_wasm_runtime_fallback_builtins(item) {
          return true
        }
      }
      false
    }
    @vibe_core.Expr::Map(fields~, ..) => {
      for field in fields {
        if expr_uses_wasm_runtime_fallback_builtins(field.expr) {
          return true
        }
      }
      false
    }
    @vibe_core.Expr::If(cond~, then_body~, else_body~, ..) =>
      expr_uses_wasm_runtime_fallback_builtins(cond) ||
      module_uses_wasm_runtime_fallback_builtins(then_body) ||
      module_uses_wasm_runtime_fallback_builtins(else_body)
    @vibe_core.Expr::Block(body~, ..) =>
      module_uses_wasm_runtime_fallback_builtins(body)
    @vibe_core.Expr::Match(scrutinee~, arms~, ..) => {
      if expr_uses_wasm_runtime_fallback_builtins(scrutinee) {
        return true
      }
      for arm in arms {
        if expr_uses_wasm_runtime_fallback_builtins(arm.expr) {
          return true
        }
        match arm.cond {
          Some(cond) =>
            if expr_uses_wasm_runtime_fallback_builtins(cond) {
              return true
            }
          None => ()
        }
      }
      false
    }
    @vibe_core.Expr::ForIn(iterable~, body~, ..) =>
      expr_uses_wasm_runtime_fallback_builtins(iterable) ||
      module_uses_wasm_runtime_fallback_builtins(body)
    @vibe_core.Expr::Fn(body~, ..) =>
      module_uses_wasm_runtime_fallback_builtins(body)
    @vibe_core.Expr::While(cond~, body~, ..) =>
      expr_uses_wasm_runtime_fallback_builtins(cond) ||
      module_uses_wasm_runtime_fallback_builtins(body)
    @vibe_core.Expr::Loop(params~, body~, ..) => {
      for param in params {
        if expr_uses_wasm_runtime_fallback_builtins(param.init) {
          return true
        }
      }
      module_uses_wasm_runtime_fallback_builtins(body)
    }
    @vibe_core.Expr::Break(value~, ..) =>
      match value {
        Some(v) => expr_uses_wasm_runtime_fallback_builtins(v)
        None => false
      }
    @vibe_core.Expr::Continue(args~, ..) => {
      for arg in args {
        if expr_uses_wasm_runtime_fallback_builtins(arg) {
          return true
        }
      }
      false
    }
    @vibe_core.Expr::Yield(expr~, ..) =>
      expr_uses_wasm_runtime_fallback_builtins(expr)
    @vibe_core.Expr::Handle(body~, arms~, ..) => {
      if module_uses_wasm_runtime_fallback_builtins(body) {
        return true
      }
      for arm in arms {
        if expr_uses_wasm_runtime_fallback_builtins(arm.expr) {
          return true
        }
        match arm.cond {
          Some(cond) =>
            if expr_uses_wasm_runtime_fallback_builtins(cond) {
              return true
            }
          None => ()
        }
      }
      false
    }
    _ => false
  }
}

///|
fn stmt_uses_wasm_runtime_fallback_builtins(stmt : @vibe_core.Stmt) -> Bool {
  match stmt {
    @vibe_core.Stmt::Let(expr~, ..)
    | @vibe_core.Stmt::LetMut(expr~, ..)
    | @vibe_core.Stmt::Assign(expr~, ..)
    | @vibe_core.Stmt::LetPat(expr~, ..)
    | @vibe_core.Stmt::Expr(expr~, ..)
    | @vibe_core.Stmt::ExportLet(expr~, ..)
    | @vibe_core.Stmt::InternalExportLet(expr~, ..) =>
      expr_uses_wasm_runtime_fallback_builtins(expr)
    @vibe_core.Stmt::IndexAssign(target~, index~, value~, ..) =>
      expr_uses_wasm_runtime_fallback_builtins(target) ||
      expr_uses_wasm_runtime_fallback_builtins(index) ||
      expr_uses_wasm_runtime_fallback_builtins(value)
    @vibe_core.Stmt::LetPatElse(expr~, else_body~, ..) =>
      expr_uses_wasm_runtime_fallback_builtins(expr) ||
      module_uses_wasm_runtime_fallback_builtins(else_body)
    @vibe_core.Stmt::Test(body~, ..) | @vibe_core.Stmt::Bench(body~, ..) =>
      module_uses_wasm_runtime_fallback_builtins(body)
    _ => false
  }
}

///|
fn module_uses_wasm_runtime_fallback_builtins(ast : @vibe_core.Module) -> Bool {
  for stmt in ast.stmts {
    if stmt_uses_wasm_runtime_fallback_builtins(stmt) {
      return true
    }
  }
  false
}

///|
fn expr_uses_http_builtins(expr : @vibe_core.Expr) -> Bool {
  match expr {
    @vibe_core.Expr::Call(name~, args~, ..) => {
      if is_http_builtin_name(name) {
        return true
      }
      for arg in args {
        if expr_uses_http_builtins(arg.expr) {
          return true
        }
      }
      false
    }
    @vibe_core.Expr::Tuple(items~, ..) => {
      for item in items {
        if expr_uses_http_builtins(item) {
          return true
        }
      }
      false
    }
    @vibe_core.Expr::TupleIndex(expr~, ..) => expr_uses_http_builtins(expr)
    @vibe_core.Expr::Record(fields~, ..)
    | @vibe_core.Expr::StructLit(fields~, ..) => {
      for field in fields {
        if expr_uses_http_builtins(field.expr) {
          return true
        }
      }
      false
    }
    @vibe_core.Expr::Array(items~, ..) => {
      for item in items {
        if expr_uses_http_builtins(item) {
          return true
        }
      }
      false
    }
    @vibe_core.Expr::Map(fields~, ..) => {
      for field in fields {
        if expr_uses_http_builtins(field.expr) {
          return true
        }
      }
      false
    }
    @vibe_core.Expr::If(cond~, then_body~, else_body~, ..) =>
      expr_uses_http_builtins(cond) ||
      module_uses_http_builtins(then_body) ||
      module_uses_http_builtins(else_body)
    @vibe_core.Expr::Block(body~, ..) => module_uses_http_builtins(body)
    @vibe_core.Expr::Match(scrutinee~, arms~, ..) => {
      if expr_uses_http_builtins(scrutinee) {
        return true
      }
      for arm in arms {
        if expr_uses_http_builtins(arm.expr) {
          return true
        }
        match arm.cond {
          Some(cond) => if expr_uses_http_builtins(cond) { return true }
          None => ()
        }
      }
      false
    }
    @vibe_core.Expr::ForIn(iterable~, body~, ..) =>
      expr_uses_http_builtins(iterable) || module_uses_http_builtins(body)
    @vibe_core.Expr::Fn(body~, ..) => module_uses_http_builtins(body)
    @vibe_core.Expr::While(cond~, body~, ..) =>
      expr_uses_http_builtins(cond) || module_uses_http_builtins(body)
    @vibe_core.Expr::Loop(params~, body~, ..) => {
      for param in params {
        if expr_uses_http_builtins(param.init) {
          return true
        }
      }
      module_uses_http_builtins(body)
    }
    @vibe_core.Expr::Break(value~, ..) =>
      match value {
        Some(v) => expr_uses_http_builtins(v)
        None => false
      }
    @vibe_core.Expr::Continue(args~, ..) => {
      for arg in args {
        if expr_uses_http_builtins(arg) {
          return true
        }
      }
      false
    }
    @vibe_core.Expr::Yield(expr~, ..) => expr_uses_http_builtins(expr)
    @vibe_core.Expr::Handle(body~, arms~, ..) => {
      if module_uses_http_builtins(body) {
        return true
      }
      for arm in arms {
        if expr_uses_http_builtins(arm.expr) {
          return true
        }
        match arm.cond {
          Some(cond) => if expr_uses_http_builtins(cond) { return true }
          None => ()
        }
      }
      false
    }
    _ => false
  }
}

///|
fn stmt_uses_http_builtins(stmt : @vibe_core.Stmt) -> Bool {
  match stmt {
    @vibe_core.Stmt::Let(expr~, ..)
    | @vibe_core.Stmt::LetMut(expr~, ..)
    | @vibe_core.Stmt::Assign(expr~, ..)
    | @vibe_core.Stmt::LetPat(expr~, ..)
    | @vibe_core.Stmt::Expr(expr~, ..)
    | @vibe_core.Stmt::ExportLet(expr~, ..)
    | @vibe_core.Stmt::InternalExportLet(expr~, ..) =>
      expr_uses_http_builtins(expr)
    @vibe_core.Stmt::IndexAssign(target~, index~, value~, ..) =>
      expr_uses_http_builtins(target) ||
      expr_uses_http_builtins(index) ||
      expr_uses_http_builtins(value)
    @vibe_core.Stmt::LetPatElse(expr~, else_body~, ..) =>
      expr_uses_http_builtins(expr) || module_uses_http_builtins(else_body)
    @vibe_core.Stmt::Test(body~, ..) | @vibe_core.Stmt::Bench(body~, ..) =>
      module_uses_http_builtins(body)
    _ => false
  }
}

///|
fn module_uses_http_builtins(ast : @vibe_core.Module) -> Bool {
  for stmt in ast.stmts {
    if stmt_uses_http_builtins(stmt) {
      return true
    }
  }
  false
}

///|
fn compile_module_wasm_for_exec(
  db : @runtime.VibeDb,
  entry : String,
  http_host_imports? : Bool = false,
) -> Bytes raise @runtime_compile.WasmCompileError {
  @runtime_compile.compile_module_wasm_with_opt_level(
    db,
    entry,
    no_dce=false,
    opt_level=None,
    // Preserve thrown string payloads for `handle { ... } { Error(msg) => ... }`
    // parity with interpreter on compiled execution paths.
    debug_errors=true,
    http_host_imports~,
  )
}

///|
fn compile_module_wasm_for_exec_with_coverage(
  db : @runtime.VibeDb,
  entry : String,
  http_host_imports? : Bool = false,
  run_tests? : Bool = false,
) -> @runtime_compile.WasmCoverageArtifact raise @runtime_compile.WasmCompileError {
  @runtime_compile.compile_module_wasm_with_coverage(
    db,
    entry,
    no_dce=false,
    run_tests~,
    debug_errors=true,
    http_host_imports~,
  )
}

///|
fn emit_module_source_cmd(args : Array[String]) -> Unit {
  if args.length() != 3 {
    abort("emit-module-source: expected <in> <out> <entry>")
  }
  let fs = @io.default_fs_adapter()
  match emit_module_source_file(args[0], args[1], args[2], fs) {
    Ok(_) => ()
    Err(msg) => abort("emit-module-source: " + msg)
  }
}

///|
fn emit_closure_payload_cmd(args : Array[String]) -> Unit {
  if args.length() != 2 {
    abort("emit-closure-payload: expected <in> <out>")
  }
  let fs = @io.default_fs_adapter()
  match emit_closure_payload_file(args[0], args[1], fs) {
    Ok(_) => ()
    Err(msg) => abort("emit-closure-payload: " + msg)
  }
}

///|
fn compile_closure_payload_cmd(args : Array[String]) -> Unit {
  if args.length() < 2 || args.length() > 3 {
    abort("compile-closure-payload: expected <in> <out> [mvp|no-dce]")
  }
  let mode = if args.length() == 3 { args[2] } else { "mvp" }
  let fs = @io.default_fs_adapter()
  match compile_closure_payload_file(args[0], args[1], mode, fs) {
    Ok(_) => ()
    Err(msg) => abort("compile-closure-payload: " + msg)
  }
}

///|
/// Fast linked run: reuse cached library .wasm, compile only user code.
fn run_cmd_wasm_linked(
  entry_path : String,
  resolved : String,
  parent : String,
  cache_dir : String,
) -> Result[WasmRunValue, String] {
  let _ = entry_path
  // Read cached linked imports
  let imports_cache = cache_dir + "/linked_imports.txt"
  let cached_text = @os_fs.read_file_to_string(imports_cache) catch {
    _ => return Err("read cache failed")
  }
  let cached_imports = parse_linked_imports_cache(cached_text)
  if cached_imports.length() == 0 {
    return Err("empty linked imports")
  }
  // Check source hashes
  let hash_cache = cache_dir + "/source_hashes.txt"
  if @os_fs.path_exists(hash_cache) {
    let hash_text = @os_fs.read_file_to_string(hash_cache) catch { _ => "" }
    let saved = parse_source_hash_cache(hash_text)
    for path, saved_hash in saved {
      let src = @os_fs.read_file_to_string(path) catch { _ => "" }
      if src.length() > 0 {
        let h = @vibe_core.content_address_hash_string(src)
        if h != saved_hash {
          return Err("source changed")
        }
      }
    }
  }
  // Verify all library .wasm exist
  let module_names : Map[String, Bool] = {}
  for li in cached_imports {
    if not(module_names.contains(li.module_name)) {
      module_names[li.module_name] = true
      let lib_path = cache_dir + "/" + li.module_name + ".wasm"
      if not(@os_fs.path_exists(lib_path)) {
        return Err("missing library")
      }
    }
  }
  // Compile user code only
  let source = @os_fs.read_file_to_string(resolved) catch {
    e => return Err(e.to_string())
  }
  let raw_ast = @parser.parse_ast(source) catch {
    e => return Err(e.to_string())
  }
  let desugared = @frontend.desugar_method_calls(raw_ast, {})
  let ast = @frontend.rewrite_effect_handles(desugared)
  let codegen_linked : Array[(String, String, Int, Int)] = []
  for li in cached_imports {
    codegen_linked.push(
      (li.module_name, li.func_name, li.param_count, li.return_count),
    )
  }
  let (bundled, _) = @runtime.bundle_for_wasm_linked_with_imports(
    ast, cached_imports,
  )
  let wasm_bytes = @runtime_compile.emit_wasm_with_linked_imports(
    bundled, codegen_linked,
  ) catch {
    e => return Err(e.to_string())
  }
  // Write user wasm
  let stamp = @env.now().to_string() + "_" + vibe_getpid().to_string()
  let wasm_path = parent + "/.vibe_run_linked_" + stamp + ".wasm"
  @os_fs.write_bytes_to_file(wasm_path, wasm_bytes) catch {
    e => return Err(e.to_string())
  }
  // Build preload args and run
  let runner = match resolve_bench_wasm_runner(resolved) {
    Ok(v) => v
    Err(err) => {
      remove_file_if_exists(wasm_path)
      return Err(err)
    }
  }
  let mut cmd = build_wasmtime_invoke_command(runner, wasm_path, "_start")
  let seen : Map[String, Bool] = {}
  for li in cached_imports {
    if not(seen.contains(li.module_name)) {
      seen[li.module_name] = true
      let lib_path = cache_dir + "/" + li.module_name + ".wasm"
      cmd = shell_quote_command_arg(runner.wasmtime_bin)
      for flag in runner.wasm_flags {
        cmd = cmd + " -W " + shell_quote_command_arg(flag)
      }
      for flag in runner.wasi_flags {
        cmd = cmd + " -S " + shell_quote_command_arg(flag)
      }
      cmd = cmd +
        " --preload " +
        shell_quote_command_arg(li.module_name) +
        "=" +
        shell_quote_command_arg(lib_path)
      cmd = cmd + " --invoke _start " + shell_quote_command_arg(wasm_path)
    }
  }
  let out_path = wasm_path + ".out"
  let err_path = wasm_path + ".err"
  let full_cmd = cmd +
    " >" +
    shell_quote_command_arg(out_path) +
    " 2>" +
    shell_quote_command_arg(err_path)
  let status = c_system(system_command_bytes(full_cmd))
  let stdout = @os_fs.read_file_to_string(out_path) catch { _ => "" }
  let stderr = @os_fs.read_file_to_string(err_path) catch { _ => "" }
  remove_file_if_exists(out_path)
  remove_file_if_exists(err_path)
  remove_file_if_exists(wasm_path)
  if status != 0 {
    let detail = wasmtime_failure_detail(stdout, stderr)
    return Err("linked run failed: " + detail)
  }
  let tagged = match parse_last_numeric_line_int64(stdout) {
    Some(v) => v
    None => return Err("linked run: missing numeric result")
  }
  match decode_tagged_wasm_run_value(tagged) {
    Some(result) => Ok(result)
    None => Err("linked run: unsupported tag: " + tagged.to_string())
  }
}

///|
fn run_cmd_wasm_backend_with_cache(
  cache : CliEntryDbCache,
  entry_path : String,
) -> Result[WasmRunValue, String] {
  // Default: linked build (debug mode). Use VIBE_RUN_BACKEND=release for monolithic.
  let force_release = match @sys.get_env_var("VIBE_RUN_BACKEND") {
    Some("release") | Some("monolithic") => true
    _ => false
  }
  if not(force_release) {
    let resolved = @loader.resolve_entry_path(entry_path)
    let parent = @vibe_fs.parent_path(resolved)
    let (vibe_root, cache_key) = find_vibe_cache_root(resolved)
    let cache_dir = vibe_root + "/debug/" + cache_key
    let imports_cache = cache_dir + "/linked_imports.txt"
    // If cache exists, try linked fast path
    if @os_fs.path_exists(imports_cache) {
      match run_cmd_wasm_linked(entry_path, resolved, parent, cache_dir) {
        Ok(v) => return Ok(v)
        Err(_) => () // fall through
      }
    }
    // No cache yet: fall through to monolithic run.
    // After execution, spawn background cache creation for next run.
  }
  // Monolithic fallback
  let (db, entry) = match load_db_for_run_with_cache(cache, entry_path) {
    Err(err) => return Err("load error: " + err)
    Ok(v) => v
  }
  let use_http_host_runner = module_uses_http_builtins(db.ast(entry))
  let http_runner = match use_http_host_runner {
    true =>
      match resolve_http_host_runner(entry) {
        Ok(v) => Some(v)
        Err(err) => return Err(err)
      }
    false => None
  }
  let runner = match resolve_bench_wasm_runner(entry) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let parent = @vibe_fs.parent_path(entry)
  let stamp = @env.now().to_string() + "_" + vibe_getpid().to_string()
  let (run_cache_dir, cached_wasm_path, cached_hash_path) = run_monolithic_cache_paths(
    entry, use_http_host_runner,
  )
  let current_hashes = collect_source_hash_cache(db, entry, true)
  let has_cached_wasm = @os_fs.path_exists(cached_wasm_path)
  let has_cached_hashes = @os_fs.path_exists(cached_hash_path)
  let use_cached_wasm = if has_cached_wasm && has_cached_hashes {
    let saved_hashes = parse_source_hash_cache(
      @os_fs.read_file_to_string(cached_hash_path) catch {
        _ => ""
      },
    )
    source_hash_cache_matches(saved_hashes, current_hashes)
  } else {
    false
  }
  let wasm_path = if use_cached_wasm {
    cached_wasm_path
  } else {
    parent + "/.vibe_run_wasm_" + stamp + ".wasm"
  }
  if not(use_cached_wasm) {
    let wasm_bytes = compile_module_wasm_for_exec(
      db,
      entry,
      http_host_imports=use_http_host_runner,
    ) catch {
      e => return Err("compile wasm error: " + e.user_message())
    }
    @os_fs.write_bytes_to_file(wasm_path, wasm_bytes) catch {
      e => return Err("write wasm failed: " + e.to_string())
    }
    match ensure_parent_dir_for_file(cached_wasm_path, "run cache") {
      Ok(_) => {
        @os_fs.write_bytes_to_file(cached_wasm_path, wasm_bytes) catch {
          _ => ()
        }
        @os_fs.write_string_to_file(
          cached_hash_path,
          serialize_source_hash_cache(current_hashes),
        ) catch {
          _ => ()
        }
        let _ = run_cache_dir
      }
      Err(_) => ()
    }
  }
  defer (if not(use_cached_wasm) { remove_file_if_exists(wasm_path) })
  let exec_out = match http_runner {
    Some(host_runner) =>
      run_http_host_invoke_run_capture(
        host_runner,
        wasm_path,
        parent + "/.vibe_run_http_host_" + stamp,
      )
    None =>
      run_wasmtime_invoke_run_capture(
        runner,
        wasm_path,
        parent + "/.vibe_run_wasmtime_" + stamp,
      )
  }
  if exec_out.status != 0 {
    let detail = first_non_empty_line(exec_out.stderr)
    let runner_name = if use_http_host_runner {
      "http host runner"
    } else {
      "wasmtime"
    }
    if detail.length() > 0 {
      return Err(
        runner_name +
        " command failed: status=" +
        exec_out.status.to_string() +
        " detail=" +
        detail,
      )
    }
    return Err(
      runner_name + " command failed: status=" + exec_out.status.to_string(),
    )
  }
  let tagged = match parse_last_numeric_line_int64(exec_out.stdout) {
    Some(v) => v
    None =>
      return Err(
        (if use_http_host_runner { "http host runner" } else { "wasmtime" }) +
        " output missing numeric result: " +
        first_non_empty_line(exec_out.stdout),
      )
  }
  match decode_tagged_wasm_run_value(tagged) {
    Some(result) => Ok(result)
    None => Err("unsupported wasm return tag: " + tagged.to_string())
  }
}

///|
fn run_cmd_wasm_backend(entry_path : String) -> Result[WasmRunValue, String] {
  run_cmd_wasm_backend_with_cache(CliEntryDbCache::new(), entry_path)
}

///|
fn print_wasm_run_value(value : WasmRunValue) -> Unit {
  match value {
    WasmRunValue::Int(n) => println("last: " + n.to_string())
    WasmRunValue::Bool(b) => println("last: " + b.to_string())
  }
}

///|
fn run_cmd(
  args : Array[String],
  syntax_mode : @runtime.ParserMode,
  _features : @runtime.RuntimeFeatureFlags,
  enable_llm~ : Bool,
) -> Unit {
  let _ = enable_llm
  if args.length() != 1 {
    abort("run: expected <file>")
  }
  let entry_path = args[0]
  match syntax_mode {
    @runtime.ParserMode::VibeMode => ()
    _ => abort("run: --syntax vibe only")
  }
  let use_session_http = cli_use_session_http()
  if use_session_http {
    match run_entry_via_session(entry_path, _features) {
      Ok(result) => {
        print_wasm_run_value(result)
        return
      }
      Err(_) => ()
    }
  }
  match run_cmd_wasm_backend(entry_path) {
    Ok(result) => {
      print_wasm_run_value(result)
      maybe_create_linked_cache_background(entry_path)
    }
    Err(err) => die("error: run wasm backend: " + err)
  }
}

///|
/// Load all imported modules into runtime's module cache
fn load_imports_into_runtime(
  rt : @runtime.Runtime,
  db : @runtime.VibeDb,
  path : String,
  path_to_hash : Map[String, String],
) -> Unit {
  let imports = db.imports(path)
  for imp in imports {
    match imp.hash {
      Some(hash) => {
        // Record the path-to-hash mapping
        path_to_hash[imp.path] = hash
        // Get the AST for this imported module
        let ast = db.ast_with_hash_imports(imp.path)
        rt.register_module(hash, ast)
        // Recursively load imports of the imported module
        load_imports_into_runtime(rt, db, imp.path, path_to_hash)
      }
      None => ()
    }
  }
}

///|
struct CliEntryDbCache {
  by_root : Map[String, @runtime.VibeDb]
}

///|
fn CliEntryDbCache::new() -> CliEntryDbCache {
  { by_root: {} }
}

///|
fn CliEntryDbCache::db_for_resolved_entry(
  self : CliEntryDbCache,
  resolved_entry : String,
) -> @runtime.VibeDb {
  let root = @codebase.resolve_index_root(resolved_entry)
  match self.by_root.get(root) {
    Some(db) => db
    None => {
      let db = @runtime.VibeDb::new()
      self.by_root[root] = db
      db
    }
  }
}

///|
fn load_db_for_test_with_cache(
  cache : CliEntryDbCache,
  entry_path : String,
) -> Result[(@runtime.VibeDb, String), String] {
  let resolved = @loader.resolve_entry_path(entry_path)
  let db = cache.db_for_resolved_entry(resolved)
  @loader.load_db_for_test_into(db, resolved)
}

///|
fn load_db_for_run_with_cache(
  cache : CliEntryDbCache,
  entry_path : String,
) -> Result[(@runtime.VibeDb, String), String] {
  let resolved = @loader.resolve_entry_path(entry_path)
  let db = cache.db_for_resolved_entry(resolved)
  match @loader.load_db_with_paths_into(db, resolved) {
    Ok((loaded_db, entry, _paths)) => Ok((loaded_db, entry))
    Err(err) => Err(err)
  }
}

///|
fn resolve_entry_artifacts_with_cache(
  cache : CliEntryDbCache,
  entry_path : String,
  skip_types? : Bool = false,
) -> Result[
  (
    @runtime.VibeDb,
    String,
    @codebase.LockData,
    @x_exp.AdvancedGraphIndex,
    String,
  ),
  String,
] {
  let resolved = @loader.resolve_entry_path(entry_path)
  let lock = match @codebase.update_lock_path_refs(resolved) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let synced_lock = sync_prelude_to_codebase(resolved, lock)
  let db = cache.db_for_resolved_entry(resolved)
  let (loaded_db, entry, paths) = match
    @loader.load_db_with_paths_into(db, resolved) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let (index, graph_head) = match
    sync_graph_head_for_loaded_db(loaded_db, entry, paths, "", skip_types~) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  Ok((loaded_db, entry, synced_lock, index, graph_head))
}

///|
struct CliCheckReport {
  file : String
  resolved_entry : String
  graph_head : String?
  error_count : Int
  warning_count : Int
  load_us : Int
  type_us : Int
  total_us : Int
  messages : Array[String]
}

///|
enum CliSessionRequestKind {
  Ping
  Run
  Check
  Test
  Shutdown
} derive(Eq, Show)

///|
struct CliSessionRequest {
  kind : CliSessionRequestKind
  path : String?
} derive(Eq, Show)

///|
fn run_check_entry_with_cache(
  cache : CliEntryDbCache,
  entry_path : String,
  check_debug : Bool,
) -> CliCheckReport {
  let messages : Array[String] = []
  let start_total = @bench.monotonic_clock_start()
  let start_load = @bench.monotonic_clock_start()
  if check_debug {
    println("[check_debug] resolving: \{entry_path}")
  }
  match resolve_entry_artifacts_with_cache(cache, entry_path, skip_types=true) {
    Err(err) => {
      let load_us = elapsed_us_from(start_load)
      let total_us = elapsed_us_from(start_total)
      messages.push("check: \{entry_path}: \{err}")
      CliCheckReport::{
        file: entry_path,
        resolved_entry: entry_path,
        graph_head: None,
        error_count: 1,
        warning_count: 0,
        load_us,
        type_us: 0,
        total_us,
        messages,
      }
    }
    Ok((db, entry, _lock, _index, graph_head)) => {
      if check_debug {
        println("[check_debug] resolved: \{entry}")
      }
      let source = match db.get_source(entry) {
        Some(v) => v
        None =>
          @os_fs.read_file_to_string(entry) catch {
            e => {
              let load_us = elapsed_us_from(start_load)
              let total_us = elapsed_us_from(start_total)
              messages.push("check: \{entry_path}: \{e}")
              return CliCheckReport::{
                file: entry_path,
                resolved_entry: entry,
                graph_head: Some(graph_head),
                error_count: 1,
                warning_count: 0,
                load_us,
                type_us: 0,
                total_us,
                messages,
              }
            }
          }
      }
      let load_us = elapsed_us_from(start_load)
      let start_type = @bench.monotonic_clock_start()
      if check_debug {
        println("[check_debug] starting db.types: \{entry}")
      }
      let _env = db.types(entry)
      let type_us = elapsed_us_from(start_type)
      if check_debug {
        println("[check_debug] finished db.types: \{entry}")
      }
      let dep_imports = db.imports(entry)
      for imp in dep_imports {
        let dep_diags = db.diagnostics(imp.path)
        if dep_diags.length() > 0 {
          let dep_source = match db.get_source(imp.path) {
            Some(v) => v
            None => ""
          }
          for dep_diag in dep_diags {
            messages.push(dep_diag.render(imp.path, dep_source))
          }
        }
      }
      let diags = db.diagnostics(entry)
      for diag in diags {
        messages.push(diag.render(entry_path, source))
      }
      let warnings = db.warnings(entry)
      for warning in warnings {
        messages.push(warning.render(entry_path, source))
      }
      let layering_violations = std_layering_violations_for_source(
        entry, source,
      )
      for violation in layering_violations {
        messages.push("check: \{entry_path}: \{violation}")
      }
      if diags.length() == 0 && warnings.length() == 0 {
        messages.push(
          "\{entry_path}: ok (graph_head=\{short_hash(graph_head)})",
        )
      }
      let total_us = elapsed_us_from(start_total)
      CliCheckReport::{
        file: entry_path,
        resolved_entry: entry,
        graph_head: Some(graph_head),
        error_count: diags.length() + layering_violations.length(),
        warning_count: warnings.length(),
        load_us,
        type_us,
        total_us,
        messages,
      }
    }
  }
}

///|
fn print_cli_check_report(report : CliCheckReport) -> Unit {
  for message in report.messages {
    println(message)
  }
}

///|
fn check_cmd(args : Array[String]) -> Unit {
  let (check_args, profile_tsv) = match split_check_cmd_args(args) {
    Ok(v) => v
    Err(msg) => abort(msg)
  }
  if check_args.length() == 0 {
    abort("check: expected <file...>")
  }
  let check_debug = check_debug_enabled()
  let mut total_errors = 0
  let mut load_ms_total = 0
  let mut type_ms_total = 0
  let mut total_ms_total = 0
  let mut load_us_total = 0
  let mut type_us_total = 0
  let mut total_us_total = 0
  let cache = CliEntryDbCache::new()
  let use_session_http = cli_use_session_http()
  for entry_path in check_args {
    let report = if use_session_http {
      match run_check_entry_via_session(entry_path) {
        Ok(v) => v
        Err(_) => run_check_entry_with_cache(cache, entry_path, check_debug)
      }
    } else {
      run_check_entry_with_cache(cache, entry_path, check_debug)
    }
    print_cli_check_report(report)
    total_errors += report.error_count
    load_us_total += report.load_us
    type_us_total += report.type_us
    total_us_total += report.total_us
    load_ms_total += elapsed_ms_from_us(report.load_us)
    type_ms_total += elapsed_ms_from_us(report.type_us)
    total_ms_total += elapsed_ms_from_us(report.total_us)
  }
  match profile_tsv {
    Some(path) => {
      let fs = @io.default_fs_adapter()
      let content = "stage\telapsed_ms\telapsed_us\n" +
        "load\t" +
        load_ms_total.to_string() +
        "\t" +
        load_us_total.to_string() +
        "\n" +
        "type\t" +
        type_ms_total.to_string() +
        "\t" +
        type_us_total.to_string() +
        "\n" +
        "total\t" +
        total_ms_total.to_string() +
        "\t" +
        total_us_total.to_string() +
        "\n"
      match @io.write_string_with(fs, path, content) {
        Ok(_) => ()
        Err(err) => abort("check: failed to write profile tsv: " + err)
      }
    }
    None => ()
  }
  if total_errors > 0 {
    abort("check: \{total_errors} error(s) found")
  }
}

///|
fn split_check_cmd_args(
  args : Array[String],
) -> Result[(Array[String], String?), String] {
  let filtered : Array[String] = []
  let mut profile_tsv : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if arg == "--profile-tsv" {
      i += 1
      if i >= args.length() {
        return Err("check: missing path after --profile-tsv")
      }
      profile_tsv = Some(args[i])
    } else {
      filtered.push(arg)
    }
    i += 1
  }
  Ok((filtered, profile_tsv))
}

///|
fn finalize_collect_export_names(ast : @vibe_core.Module) -> Array[String] {
  let entries : Map[String, Bool] = {}
  for stmt in ast.stmts {
    match stmt {
      @vibe_core.Stmt::ExportLet(name~, ..)
      | @vibe_core.Stmt::ExportEnumDef(name~, ..)
      | @vibe_core.Stmt::ExportTypeAlias(name~, ..)
      | @vibe_core.Stmt::ExportStructDef(name~, ..) => entries[name] = true
      @vibe_core.Stmt::TraitDef(name~, exported~, ..) =>
        if exported {
          entries[name] = true
        }
      @vibe_core.Stmt::Export(names~, ..) =>
        for name in names {
          entries[name] = true
        }
      @vibe_core.Stmt::ReExport(spec~, ..) =>
        for item in spec.items {
          entries[@vibe_core.import_item_local_name(item)] = true
        }
      _ => ()
    }
  }
  let out : Array[String] = []
  for name, _ in entries {
    out.push(name)
  }
  out.sort()
  out
}

///|
fn finalize_stmt_is_library_side_effect(stmt : @vibe_core.Stmt) -> Bool {
  match stmt {
    @vibe_core.Stmt::Expr(..)
    | @vibe_core.Stmt::Assign(..)
    | @vibe_core.Stmt::IndexAssign(..)
    | @vibe_core.Stmt::LetPat(..)
    | @vibe_core.Stmt::LetPatElse(..) => true
    _ => false
  }
}

///|
fn finalize_render_name_list(names : Array[String]) -> String {
  let out = StringBuilder::new()
  for i, name in names {
    if i > 0 {
      out.write_string(", ")
    }
    out.write_string(name)
  }
  out.to_string()
}

///|
fn finalize_render_module_ref(source : @vibe_core.ModuleRef) -> String {
  match source {
    @vibe_core.ModuleRef::Path(path~) => path
    @vibe_core.ModuleRef::Hash(hash~) => "#" + hash
    @vibe_core.ModuleRef::Version(name~) => "version@" + name
    @vibe_core.ModuleRef::Symbol(name~) => "symbol@" + name
    @vibe_core.ModuleRef::Alias(name~) => "@" + name
    @vibe_core.ModuleRef::PinnedPath(path~, hash~) => path + "#" + hash
  }
}

///|
fn finalize_render_import_item(item : @vibe_core.ImportItem) -> String {
  let out = StringBuilder::new()
  match item.kind {
    @vibe_core.ImportKind::Value => ()
    @vibe_core.ImportKind::Type => out.write_string("type ")
    @vibe_core.ImportKind::Trait => out.write_string("trait ")
    @vibe_core.ImportKind::Module => out.write_string("module ")
    @vibe_core.ImportKind::Struct => out.write_string("struct ")
    @vibe_core.ImportKind::Effect => out.write_string("effect ")
    @vibe_core.ImportKind::Suberror => out.write_string("suberror ")
  }
  out.write_string(item.name)
  match item.rename {
    Some(rename_name) =>
      if rename_name != item.name {
        out.write_string(" as ")
        out.write_string(rename_name)
      }
    None => ()
  }
  out.to_string()
}

///|
fn finalize_render_import_spec(spec : @vibe_core.ImportSpec) -> String {
  let rendered_items : Array[String] = []
  for item in spec.items {
    rendered_items.push(finalize_render_import_item(item))
  }
  rendered_items.join(", ")
}

///|
fn finalize_render_stmt_fallback(stmt : @vibe_core.Stmt) -> String? {
  match stmt {
    @vibe_core.Stmt::Export(names~, ..) =>
      Some("export { " + finalize_render_name_list(names) + " }")
    @vibe_core.Stmt::ReExport(spec~, source~, ..) =>
      Some(
        "export " +
        finalize_render_module_ref(source) +
        " { " +
        finalize_render_import_spec(spec) +
        " }",
      )
    _ => None
  }
}

///|
fn finalize_render_source(
  source : String,
  stmts : Array[@vibe_core.Stmt],
) -> Result[String, String] {
  let out = StringBuilder::new()
  for stmt in stmts {
    match finalize_render_stmt_fallback(stmt) {
      Some(rendered) => {
        out.write_string(rendered)
        if not(rendered.has_suffix("\n")) {
          out.write_char('\n')
        }
      }
      None => {
        let span = stmt.span()
        let snippet = source_slice_by_span(source, span.start, span.end)
        if snippet.trim().to_string().length() == 0 {
          continue
        }
        out.write_string(snippet)
        if not(snippet.has_suffix("\n")) {
          out.write_char('\n')
        }
      }
    }
  }
  let result = out.to_string()
  if result.trim().to_string().length() == 0 {
    Err("finalize: no statements kept")
  } else {
    let _ = @parser.parse_ast(result) catch {
      e =>
        return Err("finalize: rendered source parse failed: " + e.to_string())
    }
    Ok(result)
  }
}

///|
fn finalize_prefilter_stmts(
  stmts : Array[@vibe_core.Stmt],
  library_mode : Bool,
) -> Array[@vibe_core.Stmt] {
  let out : Array[@vibe_core.Stmt] = []
  for stmt in stmts {
    match stmt {
      @vibe_core.Stmt::Test(..) | @vibe_core.Stmt::Bench(..) => ()
      _ =>
        if library_mode && finalize_stmt_is_library_side_effect(stmt) {
          ()
        } else {
          out.push(stmt)
        }
    }
  }
  out
}

///|
fn finalize_select_stmts(
  ast : @vibe_core.Module,
  library_mode : Bool,
) -> Array[@vibe_core.Stmt] {
  let extra_entries = finalize_collect_export_names(ast)
  let prefiltered = finalize_prefilter_stmts(ast.stmts, library_mode)
  let dced = @frontend.dce_module_with_entry_names(
    @vibe_core.Module::{ stmts: prefiltered },
    extra_entries,
  )
  dced.stmts
}

///|
fn finalize_cmd(args : Array[String]) -> Unit {
  let options = match parse_finalize_cmd_args(args) {
    Ok(v) => v
    Err(err) => abort(err)
  }
  let (namespace_name, db_path) = match options.db_path {
    Some(path) => ("explicit", @loader.resolve_entry_path(path))
    None =>
      match resolve_scratch_db_path() {
        Ok(v) => v
        Err(err) => abort("finalize: " + err)
      }
  }
  let source = match load_eval_db_source(db_path) {
    Ok(v) => v
    Err(err) => abort("finalize: " + err)
  }
  if source.trim().to_string().length() == 0 {
    abort("finalize: source is empty: " + db_path)
  }
  let ast = @parser.parse_ast(source) catch {
    e => abort("finalize: parse failed: " + e.to_string())
  }
  let kept_stmts = finalize_select_stmts(ast, options.library_mode)
  let rendered_source = match finalize_render_source(source, kept_stmts) {
    Ok(v) => v
    Err(err) => abort(err)
  }
  let finalized_source = match normalize_format_source_text(rendered_source) {
    Ok(v) => v
    Err(err) => abort("finalize: normalize failed: " + err)
  }
  if options.print_source {
    println(finalized_source)
  }
  if not(options.dry_run) {
    match write_eval_db_source(db_path, finalized_source) {
      Ok(_) => ()
      Err(err) => abort("finalize: " + err)
    }
    match options.export_path {
      Some(path) =>
        match write_eval_export(path, finalized_source) {
          Ok(_) => println("exported: " + path)
          Err(err) => abort("finalize: " + err)
        }
      None => ()
    }
  }
  let action = if options.dry_run { "dry-run" } else { "applied" }
  let mode = if options.library_mode { "library" } else { "safe" }
  println(
    "finalize: " +
    action +
    " mode=" +
    mode +
    " db=" +
    db_path +
    " stmts=" +
    ast.stmts.length().to_string() +
    "->" +
    kept_stmts.length().to_string(),
  )
  if namespace_name != "explicit" {
    println("namespace: " + namespace_name + " db=" + db_path)
  }
}

///|
struct CompiledTestCase {
  name : String?
  body : @vibe_core.Module
} derive(Show, Eq)

///|
struct CliTestFailure {
  name : String?
  error : String
} derive(Show, Eq)

///|
struct CliTestReport {
  total : Int
  passed : Int
  failed : Int
  failures : Array[CliTestFailure]
} derive(Show, Eq)

///|
enum CompiledTestAttempt {
  Success(CliTestReport)
  Unsupported(String)
  Error(String)
}

///|
enum CompiledTestCaseExec {
  Passed
  Failed(String)
  Unsupported(String)
  Error(String)
}

///|
fn collect_compiled_test_cases(
  ast : @vibe_core.Module,
) -> Array[CompiledTestCase] {
  let out : Array[CompiledTestCase] = []
  for stmt in ast.stmts {
    match stmt {
      @vibe_core.Stmt::Test(name~, body~, ..) =>
        out.push(CompiledTestCase::{ name, body })
      _ => ()
    }
  }
  out
}

///|
fn render_stmt_snippets(
  source : String,
  stmts : Array[@vibe_core.Stmt],
) -> String {
  let out = StringBuilder::new()
  for stmt in stmts {
    let span = stmt.span()
    let snippet = source_slice_by_span(source, span.start, span.end)
    if snippet.trim().to_string().length() == 0 {
      continue
    }
    out.write_string(snippet)
    if not(snippet.has_suffix("\n")) {
      out.write_char('\n')
    }
  }
  out.to_string()
}

///|
fn compiled_test_wrapper_conflict_name(name : String) -> Bool {
  name == "main" || name == "run" || name == "__vibe_compiled_test_case"
}

///|
fn should_omit_compiled_test_prelude_stmt(stmt : @vibe_core.Stmt) -> Bool {
  match stmt {
    @vibe_core.Stmt::Let(name~, ..)
    | @vibe_core.Stmt::ExportLet(name~, ..)
    | @vibe_core.Stmt::InternalExportLet(name~, ..) =>
      compiled_test_wrapper_conflict_name(name)
    @vibe_core.Stmt::Export(names~, ..) => {
      for name in names {
        if compiled_test_wrapper_conflict_name(name) {
          return true
        }
      }
      false
    }
    _ => false
  }
}

///|
fn compiled_test_prelude_stmt_runs_in_wrapper(stmt : @vibe_core.Stmt) -> Bool {
  match stmt {
    @vibe_core.Stmt::Let(..)
    | @vibe_core.Stmt::LetMut(..)
    | @vibe_core.Stmt::LetPat(..)
    | @vibe_core.Stmt::LetPatElse(..) => true
    _ => false
  }
}

///|
fn compiled_test_prelude_pattern_bound_names(
  pat : @vibe_core.Pat,
) -> Array[String] {
  let names : Map[String, Bool] = {}
  @vibe_core.bind_pattern_names_walker(names, pat)
  let out : Array[String] = []
  for name, _ in names {
    out.push(name)
  }
  out
}

///|
fn compiled_test_prelude_stmt_defined_names(
  stmt : @vibe_core.Stmt,
) -> Array[String] {
  match stmt {
    @vibe_core.Stmt::Let(name~, ..)
    | @vibe_core.Stmt::ExportLet(name~, ..)
    | @vibe_core.Stmt::InternalExportLet(name~, ..)
    | @vibe_core.Stmt::LetMut(name~, ..) => [name]
    @vibe_core.Stmt::LetPat(pat~, ..) | @vibe_core.Stmt::LetPatElse(pat~, ..) =>
      compiled_test_prelude_pattern_bound_names(pat)
    _ => []
  }
}

///|
fn compiled_test_prelude_collect_ref_name(
  name : String,
  scope : @vibe_core.WalkerScope,
  refs : Map[String, Bool],
) -> Unit {
  if not(scope.contains(name)) {
    refs[name] = true
  }
}

///|
fn compiled_test_prelude_stmt_refs(stmt : @vibe_core.Stmt) -> Map[String, Bool] {
  let refs : Map[String, Bool] = {}
  @vibe_core.walk_stmt_refs(
    stmt,
    @vibe_core.WalkerScope::new(),
    refs,
    compiled_test_prelude_collect_ref_name,
  )
  refs
}

///|
fn compiled_test_prelude_stmt_must_stay_top_level(
  stmt : @vibe_core.Stmt,
  required_names : Map[String, Bool],
) -> Bool {
  for name in compiled_test_prelude_stmt_defined_names(stmt) {
    if required_names.contains(name) {
      return true
    }
  }
  false
}

///|
fn compiled_test_prelude_absorb_stmt_refs(
  stmt : @vibe_core.Stmt,
  required_names : Map[String, Bool],
) -> Unit {
  let refs = compiled_test_prelude_stmt_refs(stmt)
  for name, _ in refs {
    required_names[name] = true
  }
}

///|
fn partition_compiled_test_prelude_stmts(
  stmts : Array[@vibe_core.Stmt],
) -> (Array[@vibe_core.Stmt], Array[@vibe_core.Stmt]) {
  let required_names : Map[String, Bool] = {}
  for stmt in stmts {
    if not(compiled_test_prelude_stmt_runs_in_wrapper(stmt)) {
      compiled_test_prelude_absorb_stmt_refs(stmt, required_names)
    }
  }
  for _ in 0..<stmts.length() {
    for stmt in stmts {
      if compiled_test_prelude_stmt_runs_in_wrapper(stmt) &&
        compiled_test_prelude_stmt_must_stay_top_level(stmt, required_names) {
        compiled_test_prelude_absorb_stmt_refs(stmt, required_names)
      }
    }
  }
  let top_level_stmts : Array[@vibe_core.Stmt] = []
  let wrapper_prelude_stmts : Array[@vibe_core.Stmt] = []
  for stmt in stmts {
    if compiled_test_prelude_stmt_runs_in_wrapper(stmt) &&
      not(compiled_test_prelude_stmt_must_stay_top_level(stmt, required_names)) {
      wrapper_prelude_stmts.push(stmt)
    } else {
      top_level_stmts.push(stmt)
    }
  }
  (top_level_stmts, wrapper_prelude_stmts)
}

///|
fn build_compiled_test_case_source(
  top_level_source : String,
  wrapper_prelude_source : String,
  body_source : String,
) -> String {
  let out = StringBuilder::new()
  if top_level_source.trim().to_string().length() > 0 {
    out.write_string(top_level_source)
    if not(top_level_source.has_suffix("\n")) {
      out.write_char('\n')
    }
  }
  out.write_string(
    "let __vibe_compiled_test_case = () -> Int with { Error, Fs, Process, Env, Stdout, Stdin, Net, Async, Threads, Llm } {\n",
  )
  if wrapper_prelude_source.trim().to_string().length() > 0 {
    out.write_string(wrapper_prelude_source)
    if not(wrapper_prelude_source.has_suffix("\n")) {
      out.write_char('\n')
    }
  }
  if body_source.trim().to_string().length() > 0 {
    out.write_string(body_source)
    if not(body_source.has_suffix("\n")) {
      out.write_char('\n')
    }
  }
  // Compiled test case body is statement-oriented and may end in Unit.
  // Keep `run: Int` contract by returning 0 explicitly.
  out.write_string("0\n")
  out.write_string("}\n")
  out.write_string("__vibe_compiled_test_case()\n")
  out.to_string()
}

///|
/// Build a batched source that contains all test cases in a single _start
/// function. Each test is wrapped in a try/catch: on error, print "FAIL:N"
/// and continue. On success, print "PASS:N". The exit code is the number
/// of failures (0 = all passed).
fn build_compiled_test_batch_source(
  top_level_source : String,
  wrapper_prelude_source : String,
  body_sources : Array[String],
) -> String {
  let out = StringBuilder::new()
  if top_level_source.trim().to_string().length() > 0 {
    out.write_string(top_level_source)
    if not(top_level_source.has_suffix("\n")) {
      out.write_char('\n')
    }
  }
  // Each test is a function that runs the body and returns 0 on success
  for i, body_source in body_sources {
    out.write_string(
      "let __test_" +
      i.to_string() +
      " = () -> Int with { Error, Fs, Process, Env, Stdout, Stdin, Net, Async, Threads, Llm } {\n",
    )
    if wrapper_prelude_source.trim().to_string().length() > 0 {
      out.write_string(wrapper_prelude_source)
      if not(wrapper_prelude_source.has_suffix("\n")) {
        out.write_char('\n')
      }
    }
    if body_source.trim().to_string().length() > 0 {
      out.write_string(body_source)
      if not(body_source.has_suffix("\n")) {
        out.write_char('\n')
      }
    }
    out.write_string("0\n")
    out.write_string("}\n")
  }
  // _start runs all tests sequentially, printing results
  out.write_string("let mut __test_failures = 0\n")
  for i = 0; i < body_sources.length(); i = i + 1 {
    let i_str = i.to_string()
    out.write_string(
      "let __test_result_" +
      i_str +
      " = handle { __test_" +
      i_str +
      "() } { Error(_e) => 1 }\n",
    )
    out.write_string(
      "if __test_result_" +
      i_str +
      " != 0 { __test_failures = __test_failures + 1 }\n",
    )
  }
  out.write_string("__test_failures\n")
  out.to_string()
}

///|
fn compiled_test_generated_source_path(
  parent : String,
  kind : String,
  source : String,
) -> String {
  let hash = @vibe_core.content_address_hash_string(kind + "\n" + source)
  parent + "/.vibe_test_" + kind + "_" + hash + ".vibe"
}

///|
fn load_compiled_test_case_db_with_cache(
  cache : CliEntryDbCache,
  source_path : String,
  source : String,
) -> Result[(@runtime.VibeDb, String), String] {
  @os_fs.write_string_to_file(source_path, source) catch {
    e => return Err("write temp source failed: " + e.to_string())
  }
  load_db_for_test_with_cache(cache, source_path)
}

///|
fn wasmtime_failure_detail(stdout : String, stderr : String) -> String {
  let err_line = first_non_empty_line(stderr)
  if err_line.length() > 0 {
    let tail = last_non_empty_line(stderr)
    if tail.length() > 0 && tail != err_line {
      return err_line + " / " + tail
    }
    return err_line
  }
  let out_line = first_non_empty_line(stdout)
  if out_line.length() > 0 {
    return out_line
  }
  "wasmtime invoke failed"
}

///|
fn run_compiled_test_case(
  cache : CliEntryDbCache,
  runner : BenchWasmRunner,
  http_runner : HttpHostRunner?,
  use_http_host_runner : Bool,
  source_path : String,
  wasm_path : String,
  source : String,
) -> CompiledTestCaseExec {
  let (db, entry) = match
    load_compiled_test_case_db_with_cache(cache, source_path, source) {
    Err(err) => return CompiledTestCaseExec::Error("load error: " + err)
    Ok(v) => v
  }
  let wasm_bytes = compile_module_wasm_for_exec(
    db,
    entry,
    http_host_imports=use_http_host_runner,
  ) catch {
    e => {
      let msg = e.user_message()
      if is_wasm_unsupported_compile_error(msg) {
        return CompiledTestCaseExec::Unsupported(msg)
      }
      return CompiledTestCaseExec::Error("compile wasm error: " + msg)
    }
  }
  @os_fs.write_bytes_to_file(wasm_path, wasm_bytes) catch {
    e =>
      return CompiledTestCaseExec::Error("write wasm failed: " + e.to_string())
  }
  let run_out = match http_runner {
    Some(v) =>
      run_http_host_invoke_run_capture(v, wasm_path, wasm_path + ".http_host")
    None => run_wasmtime_invoke_run_capture(runner, wasm_path, wasm_path)
  }
  if run_out.status == 0 {
    CompiledTestCaseExec::Passed
  } else {
    CompiledTestCaseExec::Failed(
      wasmtime_failure_detail(run_out.stdout, run_out.stderr),
    )
  }
}

///|
fn load_compiled_test_case_db(
  source_path : String,
) -> Result[(@runtime.VibeDb, String), String] {
  @loader.load_db_for_test(source_path)
}

///|
fn run_test_file_compiled_with_cache(
  cache : CliEntryDbCache,
  entry_path : String,
  stop_on_first_failure : Bool,
) -> CompiledTestAttempt {
  let (db, entry) = match load_db_for_test_with_cache(cache, entry_path) {
    Err(err) => return CompiledTestAttempt::Error("load error: " + err)
    Ok(v) => v
  }
  let ast = db.ast(entry)
  let detect_ast = @runtime.bundle_for_wasm_no_dce(db, entry, ast)
  let use_http_host_runner = module_uses_http_builtins(detect_ast)
  if module_uses_wasm_runtime_fallback_builtins(detect_ast) {
    return CompiledTestAttempt::Unsupported(
      "wasm runtime fallback builtins in test module",
    )
  }
  for stmt in ast.stmts {
    match stmt {
      @vibe_core.Stmt::Test(..) | @vibe_core.Stmt::Bench(..) => ()
      _ =>
        if finalize_stmt_is_library_side_effect(stmt) {
          return CompiledTestAttempt::Unsupported(
            "top-level side effects in test module",
          )
        }
    }
  }
  let cases = collect_compiled_test_cases(ast)
  if cases.length() == 0 {
    return CompiledTestAttempt::Success({
      total: 0,
      passed: 0,
      failed: 0,
      failures: [],
    })
  }
  let runner = match resolve_bench_wasm_runner(entry) {
    Ok(v) => v
    Err(err) => return CompiledTestAttempt::Unsupported(err)
  }
  let (test_cache_dir, cached_batch_wasm_path, cached_batch_hash_path) = compiled_test_batch_cache_paths(
    entry, use_http_host_runner,
  )
  let current_hashes = collect_source_hash_cache(db, entry, true)
  let use_cached_batch_wasm = if @os_fs.path_exists(cached_batch_wasm_path) &&
    @os_fs.path_exists(cached_batch_hash_path) {
    let saved_hashes = parse_source_hash_cache(
      @os_fs.read_file_to_string(cached_batch_hash_path) catch {
        _ => ""
      },
    )
    source_hash_cache_matches(saved_hashes, current_hashes)
  } else {
    false
  }
  let http_runner = match use_http_host_runner {
    true =>
      match resolve_http_host_runner(entry) {
        Ok(v) => Some(v)
        Err(err) => return CompiledTestAttempt::Unsupported(err)
      }
    false => None
  }
  let source = match db.get_source(entry) {
    Some(v) => v
    None =>
      @os_fs.read_file_to_string(entry) catch {
        e => return CompiledTestAttempt::Error("read error: " + e.to_string())
      }
  }
  let prelude_stmts : Array[@vibe_core.Stmt] = []
  for stmt in ast.stmts {
    match stmt {
      @vibe_core.Stmt::Test(..) | @vibe_core.Stmt::Bench(..) => ()
      _ =>
        if not(should_omit_compiled_test_prelude_stmt(stmt)) {
          prelude_stmts.push(stmt)
        }
    }
  }
  let (top_level_stmts, wrapper_prelude_stmts) = partition_compiled_test_prelude_stmts(
    prelude_stmts,
  )
  let top_level_source = render_stmt_snippets(source, top_level_stmts)
  let wrapper_prelude_source = render_stmt_snippets(
    source, wrapper_prelude_stmts,
  )
  let parent = @vibe_fs.parent_path(entry)
  let stamp = @env.now().to_string() + "_" + vibe_getpid().to_string()
  let batch_wasm_path = if use_cached_batch_wasm {
    cached_batch_wasm_path
  } else {
    parent + "/.vibe_test_batch_" + stamp + ".wasm"
  }
  if not(use_cached_batch_wasm) {
    // Build batched source: all tests compiled + run in a single WASM
    let body_sources : Array[String] = []
    for case in cases {
      body_sources.push(render_stmt_snippets(source, case.body.stmts))
    }
    let batch_source = build_compiled_test_batch_source(
      top_level_source, wrapper_prelude_source, body_sources,
    )
    let batch_source_path = compiled_test_generated_source_path(
      parent, "batch", batch_source,
    )
    let (batch_db, batch_entry) = match
      load_compiled_test_case_db_with_cache(
        cache, batch_source_path, batch_source,
      ) {
      Err(_err) => {
        remove_file_if_exists(batch_source_path)
        // Fallback to per-case execution on batch compile failure
        return run_test_file_compiled_per_case(
          cache, cases, source, top_level_source, wrapper_prelude_source, parent,
          stamp, runner, http_runner, use_http_host_runner, stop_on_first_failure,
        )
      }
      Ok(v) => v
    }
    let batch_wasm_bytes = compile_module_wasm_for_exec(
      batch_db,
      batch_entry,
      http_host_imports=use_http_host_runner,
    ) catch {
      e => {
        remove_file_if_exists(batch_source_path)
        let msg = e.user_message()
        if is_wasm_unsupported_compile_error(msg) {
          return CompiledTestAttempt::Unsupported(msg)
        }
        // Fallback to per-case execution on batch compile failure
        return run_test_file_compiled_per_case(
          cache, cases, source, top_level_source, wrapper_prelude_source, parent,
          stamp, runner, http_runner, use_http_host_runner, stop_on_first_failure,
        )
      }
    }
    @os_fs.write_bytes_to_file(batch_wasm_path, batch_wasm_bytes) catch {
      e => {
        remove_file_if_exists(batch_source_path)
        return CompiledTestAttempt::Error(
          "write batch wasm failed: " + e.to_string(),
        )
      }
    }
    remove_file_if_exists(batch_source_path)
    match ensure_parent_dir_for_file(cached_batch_wasm_path, "test cache") {
      Ok(_) => {
        @os_fs.write_bytes_to_file(cached_batch_wasm_path, batch_wasm_bytes) catch {
          _ => ()
        }
        @os_fs.write_string_to_file(
          cached_batch_hash_path,
          serialize_source_hash_cache(current_hashes),
        ) catch {
          _ => ()
        }
        let _ = test_cache_dir
      }
      Err(_) => ()
    }
  }
  // Run all tests in one wasmtime invocation; exit code = number of failures
  let run_out = match http_runner {
    Some(v) =>
      run_http_host_invoke_run_capture(v, batch_wasm_path, batch_wasm_path)
    None =>
      run_wasmtime_invoke_run_capture(runner, batch_wasm_path, batch_wasm_path)
  }
  remove_file_if_exists(batch_wasm_path)
  // _start returns failure count as exit code (wasmtime maps it)
  // stdout contains "last: N" where N is the failure count
  let fail_count = if run_out.status != 0 {
    // Parse failure count from stdout "last: N"
    let stdout = run_out.stdout.trim().to_string()
    if stdout.has_prefix("last: ") {
      let num_str = stdout.unsafe_substring(start=6, end=stdout.length())
      let parsed : Result[Int, _] = try? @strconv.parse_int(num_str)
      match parsed {
        Ok(n) => n
        Err(_) => cases.length()
      }
    } else {
      cases.length()
    }
  } else {
    0
  }
  if fail_count > 0 {
    // Any batch failure falls back to per-case execution so failure details do
    // not depend on the legacy interpreter path.
    run_test_file_compiled_per_case(
      cache, cases, source, top_level_source, wrapper_prelude_source, parent, stamp,
      runner, http_runner, use_http_host_runner, stop_on_first_failure,
    )
  } else {
    CompiledTestAttempt::Success({
      total: cases.length(),
      passed: cases.length(),
      failed: 0,
      failures: [],
    })
  }
}

///|
/// Fallback: run each test case individually (used when batch fails or
/// to identify specific failures after a batch failure).
fn run_test_file_compiled_per_case(
  cache : CliEntryDbCache,
  cases : Array[CompiledTestCase],
  source : String,
  top_level_source : String,
  wrapper_prelude_source : String,
  parent : String,
  stamp : String,
  runner : BenchWasmRunner,
  http_runner : HttpHostRunner?,
  use_http_host_runner : Bool,
  stop_on_first_failure : Bool,
) -> CompiledTestAttempt {
  let failures : Array[CliTestFailure] = []
  let mut passed = 0
  for i, case in cases {
    let case_body_source = render_stmt_snippets(source, case.body.stmts)
    let case_source = build_compiled_test_case_source(
      top_level_source, wrapper_prelude_source, case_body_source,
    )
    let source_path = compiled_test_generated_source_path(
      parent,
      "case_" + i.to_string(),
      case_source,
    )
    let wasm_path = parent +
      "/.vibe_test_wasm_" +
      stamp +
      "_" +
      i.to_string() +
      ".wasm"
    let outcome = run_compiled_test_case(
      cache, runner, http_runner, use_http_host_runner, source_path, wasm_path, case_source,
    )
    remove_file_if_exists(source_path)
    remove_file_if_exists(wasm_path)
    match outcome {
      CompiledTestCaseExec::Passed => passed += 1
      CompiledTestCaseExec::Failed(err) =>
        if stop_on_first_failure {
          return CompiledTestAttempt::Unsupported("runtime failure: " + err)
        } else {
          failures.push(CliTestFailure::{ name: case.name, error: err })
        }
      CompiledTestCaseExec::Unsupported(err) =>
        return CompiledTestAttempt::Unsupported(err)
      CompiledTestCaseExec::Error(err) =>
        failures.push(CliTestFailure::{ name: case.name, error: err })
    }
  }
  CompiledTestAttempt::Success({
    total: cases.length(),
    passed,
    failed: failures.length(),
    failures,
  })
}

///|
fn run_test_file_compiled(
  entry_path : String,
  stop_on_first_failure : Bool,
) -> CompiledTestAttempt {
  run_test_file_compiled_with_cache(
    CliEntryDbCache::new(),
    entry_path,
    stop_on_first_failure,
  )
}

///|
fn run_test_file_with_backend_with_cache(
  cache : CliEntryDbCache,
  entry_path : String,
  features : @runtime.RuntimeFeatureFlags,
) -> Result[CliTestReport, String] {
  ignore(features)
  // Runtime import failures are detected from compiled failure reports, so
  // ordinary failing tests keep the compiled per-case reporting path.
  let stop_on_first_failure = false
  match
    run_test_file_compiled_with_cache(cache, entry_path, stop_on_first_failure) {
    CompiledTestAttempt::Success(report) => {
      if report.failed > 0 &&
        compiled_report_has_runtime_import_failures(report) {
        return Err(
          "compiled test backend unsupported: runtime imports are not available in compiled mode",
        )
      }
      Ok(report)
    }
    CompiledTestAttempt::Unsupported(err) =>
      Err("compiled test backend unsupported: " + err)
    CompiledTestAttempt::Error(err) => Err(err)
  }
}

///|
fn run_test_file_with_backend(
  entry_path : String,
  features : @runtime.RuntimeFeatureFlags,
) -> Result[CliTestReport, String] {
  run_test_file_with_backend_with_cache(
    CliEntryDbCache::new(),
    entry_path,
    features,
  )
}

///|
fn compiled_report_has_runtime_import_failures(report : CliTestReport) -> Bool {
  for failure in report.failures {
    if failure.error.contains("unknown import:") ||
      failure.error.contains("has not been defined") {
      return true
    }
  }
  false
}

///|
fn resolve_test_backend_pref(entry_path : String) -> CliExecBackendPref {
  let pref = resolve_cli_exec_backend_pref_for_entry(
    "VIBE_TEST_BACKEND", entry_path,
  )
  if pref == CliExecBackendPref::Auto {
    // `vibe test` defaults to compiled backend.
    CliExecBackendPref::Compiled
  } else {
    pref
  }
}

///|
fn test_cmd(
  args : Array[String],
  features : @runtime.RuntimeFeatureFlags,
) -> Unit {
  if args.length() == 0 {
    abort("test: expected <file|dir...>")
  }
  // Parse --jobs and --report-json flags
  let mut jobs = 0
  let mut report_json = false
  let path_args : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if arg == "--jobs" {
      i += 1
      if i < args.length() {
        jobs = @strconv.parse_int(args[i]) catch { _ => 0 }
      }
    } else if arg == "--report-json" {
      report_json = true
    } else {
      path_args.push(arg)
    }
    i += 1
  }
  let entry_paths = resolve_test_entry_paths(path_args)
  if entry_paths.length() == 0 {
    abort("test: no test files found")
  }
  let normalized_jobs = normalize_test_jobs(jobs)
  if report_json {
    test_cmd_report_json(entry_paths, features)
    return
  }
  if entry_paths.length() > 1 {
    test_cmd_parallel(entry_paths, features, normalized_jobs)
    return
  }
  test_cmd_sequential(entry_paths, features)
}

///|
fn normalize_test_jobs(jobs : Int) -> Int {
  let normalized = if jobs <= 0 { default_test_jobs() } else { jobs }
  if normalized <= 0 {
    1
  } else if normalized > 16 {
    // Hard cap: avoid accidental process fan-out from huge --jobs.
    16
  } else {
    normalized
  }
}

///|
fn default_test_jobs() -> Int {
  // Safe default with env override for local tuning.
  match @sys.get_env_var("VIBE_TEST_JOBS") {
    Some(raw) => {
      let parsed = @strconv.parse_int(raw) catch { _ => 0 }
      if parsed > 0 {
        parsed
      } else {
        1
      }
    }
    None => 1
  }
}

///|
fn test_cmd_sequential(
  entry_paths : Array[String],
  features : @runtime.RuntimeFeatureFlags,
) -> Unit {
  let mut failed = false
  let mut total = 0
  let mut passed = 0
  let mut failed_count = 0
  let file_count = entry_paths.length()
  let cache = CliEntryDbCache::new()
  let use_session_http = cli_use_session_http()
  for entry_path in entry_paths {
    let report = if use_session_http {
      match run_test_file_via_session(entry_path, features) {
        Ok(v) => Ok(v)
        Err(_) =>
          run_test_file_with_backend_with_cache(cache, entry_path, features)
      }
    } else {
      run_test_file_with_backend_with_cache(cache, entry_path, features)
    }
    match report {
      Ok(report) => {
        if !print_cli_test_report(entry_path, report) {
          failed = true
        }
        total += report.total
        passed += report.passed
        failed_count += report.failed
      }
      Err(err) => {
        println("[\{entry_path}] \{err}")
        failed = true
      }
    }
  }
  println(
    "summary: files=\{file_count} total=\{total} passed=\{passed} failed=\{failed_count}",
  )
  if failed {
    abort("test: failures detected")
  }
}

///|
fn make_cli_test_report_json(
  path : String,
  report : CliTestReport,
  elapsed_ms : Int,
) -> Json {
  let failures_arr : Array[Json] = []
  for failure in report.failures {
    let f : Map[String, Json] = {}
    f["name"] = Json::string(
      match failure.name {
        Some(n) => n
        None => "<unnamed>"
      },
    )
    f["error"] = Json::string(failure.error)
    failures_arr.push(Json::object(f))
  }
  let obj : Map[String, Json] = {}
  obj["file"] = Json::string(path)
  obj["total"] = Json::number(report.total.to_double())
  obj["passed"] = Json::number(report.passed.to_double())
  obj["failed"] = Json::number(report.failed.to_double())
  obj["elapsed_ms"] = Json::number(elapsed_ms.to_double())
  obj["failures"] = Json::array(failures_arr)
  Json::object(obj)
}

///|
fn make_cli_check_report_json(report : CliCheckReport) -> Json {
  let messages_arr : Array[Json] = []
  for message in report.messages {
    messages_arr.push(Json::string(message))
  }
  let obj : Map[String, Json] = {}
  obj["cmd"] = Json::string("check")
  obj["file"] = Json::string(report.file)
  obj["resolved_entry"] = Json::string(report.resolved_entry)
  obj["ok"] = Json::boolean(report.error_count == 0)
  obj["errors"] = Json::number(report.error_count.to_double())
  obj["warnings"] = Json::number(report.warning_count.to_double())
  obj["load_ms"] = Json::number(elapsed_ms_from_us(report.load_us).to_double())
  obj["type_ms"] = Json::number(elapsed_ms_from_us(report.type_us).to_double())
  obj["total_ms"] = Json::number(
    elapsed_ms_from_us(report.total_us).to_double(),
  )
  obj["messages"] = Json::array(messages_arr)
  match report.graph_head {
    Some(hash) => {
      obj["graph_head"] = Json::string(hash)
      obj["short_graph_head"] = Json::string(short_hash(hash))
    }
    None => {
      obj["graph_head"] = Json::null()
      obj["short_graph_head"] = Json::null()
    }
  }
  Json::object(obj)
}

///|
fn make_error_report_json(
  entry_path : String,
  phase : String,
  error : String,
  elapsed_ms : Int,
) -> Json {
  let f : Map[String, Json] = {}
  f["name"] = Json::string(phase)
  f["error"] = Json::string(error)
  let obj : Map[String, Json] = {}
  obj["file"] = Json::string(entry_path)
  obj["total"] = Json::number(0.0)
  obj["passed"] = Json::number(0.0)
  obj["failed"] = Json::number(1.0)
  obj["elapsed_ms"] = Json::number(elapsed_ms.to_double())
  obj["failures"] = Json::array([Json::object(f)])
  Json::object(obj)
}

///|
fn make_cli_session_test_report_json(
  path : String,
  report : CliTestReport,
  elapsed_ms : Int,
) -> Json {
  let base = make_cli_test_report_json(path, report, elapsed_ms)
  match base {
    Json::Object(obj) => {
      obj["cmd"] = Json::string("test")
      Json::object(obj)
    }
    _ => base
  }
}

///|
fn make_cli_session_run_result_json(
  path : String,
  value : WasmRunValue,
) -> Json {
  let obj : Map[String, Json] = {}
  obj["cmd"] = Json::string("run")
  obj["file"] = Json::string(path)
  obj["ok"] = Json::boolean(true)
  match value {
    WasmRunValue::Int(n) => {
      obj["value_kind"] = Json::string("int")
      obj["value"] = Json::string(n.to_string())
    }
    WasmRunValue::Bool(b) => {
      obj["value_kind"] = Json::string("bool")
      obj["value"] = Json::boolean(b)
    }
  }
  Json::object(obj)
}

///|
fn make_cli_session_error_json(
  cmd : String,
  entry_path : String,
  phase : String,
  error : String,
  elapsed_ms : Int,
) -> Json {
  let base = make_error_report_json(entry_path, phase, error, elapsed_ms)
  match base {
    Json::Object(obj) => {
      obj["cmd"] = Json::string(cmd)
      Json::object(obj)
    }
    _ => base
  }
}

///|
fn session_http_port_for_entry_with_features(
  entry_path : String,
  features : @runtime.RuntimeFeatureFlags,
) -> Int {
  let resolved = @loader.resolve_entry_path(entry_path)
  let (vibe_root, _cache_key) = find_vibe_cache_root(resolved)
  let mut acc = 0
  for _, ch in vibe_root {
    acc = (acc * 131 + Char::to_int(ch)) % 20000
  }
  if features.is_unstable_async_enabled() {
    acc = (acc * 131 + 17) % 20000
  }
  if features.is_unstable_threads_enabled() {
    acc = (acc * 131 + 31) % 20000
  }
  36000 + acc
}

///|
fn current_cli_binary_path() -> String? {
  let resolve_bin = fn(raw : String) -> String {
    if raw.has_prefix("/") || not(raw.contains("/")) {
      raw
    } else {
      @io.current_dir_or_root() + "/" + raw
    }
  }
  let argv = @env.args()
  if argv.length() > 0 {
    let argv0 = argv[0]
    if argv0.has_suffix("vibe.exe") || argv0.has_suffix("vibe") {
      return Some(resolve_bin(argv0))
    }
  }
  match @sys.get_env_var("_") {
    Some(bin) if bin.has_suffix("vibe.exe") || bin.has_suffix("vibe") =>
      Some(resolve_bin(bin))
    _ => None
  }
}

///|
fn session_http_request_json(
  port : Int,
  request : Json,
) -> Result[Json, String] {
  let out : Ref[Result[Json, String]] = @ref.new(
    Err("session-http: request did not complete"),
  )
  let url = "http://127.0.0.1:" + port.to_string() + "/"
  @async.run_async_main(async fn() {
    let (_response, data) = @http.post(url, request.stringify(), headers={
      "content-type": "application/json",
    }) catch {
      err => {
        out.val = Err(err.to_string())
        return
      }
    }
    let response_body = data.text() catch {
      err => {
        out.val = Err(err.to_string())
        return
      }
    }
    if response_body.length() == 0 {
      out.val = Err("empty session http response")
      return
    }
    let parsed : Json = @json.parse(response_body) catch {
      _ => {
        out.val = Err("invalid session http response json")
        return
      }
    }
    out.val = Ok(parsed)
  })
  out.val
}

///|
fn session_http_ping(port : Int) -> Bool {
  let req : Map[String, Json] = {}
  req["cmd"] = Json::string("ping")
  match session_http_request_json(port, Json::object(req)) {
    Ok(Json::Object(obj)) =>
      match obj.get("ok") {
        Some(Json::True) => true
        _ => false
      }
    _ => false
  }
}

///|
fn ensure_session_http_worker(
  entry_path : String,
  features : @runtime.RuntimeFeatureFlags,
) -> Result[Int, String] {
  let port = session_http_port_for_entry_with_features(entry_path, features)
  if session_http_ping(port) {
    return Ok(port)
  }
  let self_bin = match current_cli_binary_path() {
    Some(v) => v
    None =>
      return Err("session-http: failed to resolve current vibe binary path")
  }
  let cmd = "nohup " +
    shell_quote_command_arg(self_bin) +
    (if features.is_unstable_async_enabled() {
      " --unstable-async"
    } else {
      ""
    }) +
    (if features.is_unstable_threads_enabled() {
      " --unstable-threads"
    } else {
      ""
    }) +
    " session-http --port " +
    port.to_string() +
    " >/dev/null 2>&1 &"
  let status = c_system(system_command_bytes(cmd))
  if status != 0 {
    return Err("session-http: failed to spawn worker")
  }
  for _ in 0..<25 {
    @io.sleep_ms(20L)
    if session_http_ping(port) {
      return Ok(port)
    }
  }
  Err("session-http: worker did not become ready")
}

///|
fn parse_cli_check_report_json(json : Json) -> Result[CliCheckReport, String] {
  match json {
    Json::Object(obj) => {
      let file = parse_report_json_string(json, "file")
      let resolved_entry = parse_report_json_string(json, "resolved_entry")
      let error_count = parse_report_json_int(json, "errors")
      let warning_count = parse_report_json_int(json, "warnings")
      let load_ms = parse_report_json_int(json, "load_ms")
      let type_ms = parse_report_json_int(json, "type_ms")
      let total_ms = parse_report_json_int(json, "total_ms")
      let graph_head = match obj.get("graph_head") {
        Some(Json::String(value)) => Some(value)
        _ => None
      }
      let messages : Array[String] = []
      match obj.get("messages") {
        Some(Json::Array(arr)) =>
          for item in arr {
            match item {
              Json::String(value) => messages.push(value)
              _ => ()
            }
          }
        _ => ()
      }
      Ok(CliCheckReport::{
        file,
        resolved_entry,
        graph_head,
        error_count,
        warning_count,
        load_us: load_ms * 1000,
        type_us: type_ms * 1000,
        total_us: total_ms * 1000,
        messages,
      })
    }
    _ => Err("session-http: invalid check response")
  }
}

///|
fn run_check_entry_via_session(
  entry_path : String,
) -> Result[CliCheckReport, String] {
  let port = match
    ensure_session_http_worker(
      entry_path,
      @runtime.RuntimeFeatureFlags::new(false, false),
    ) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let req : Map[String, Json] = {}
  req["cmd"] = Json::string("check")
  req["path"] = Json::string(entry_path)
  let json = match session_http_request_json(port, Json::object(req)) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  parse_cli_check_report_json(json)
}

///|
fn parse_cli_run_value_json(json : Json) -> Result[WasmRunValue, String] {
  match json {
    Json::Object(obj) => {
      let kind = parse_report_json_string(json, "value_kind")
      match kind {
        "int" =>
          match obj.get("value") {
            Some(Json::String(value)) => {
              let parsed = @strconv.parse_int(value) catch {
                _ => return Err("session-http: invalid run int result")
              }
              Ok(WasmRunValue::Int(parsed.to_int64()))
            }
            _ => Err("session-http: invalid run int result")
          }
        "bool" =>
          match obj.get("value") {
            Some(Json::True) => Ok(WasmRunValue::Bool(true))
            Some(Json::False) => Ok(WasmRunValue::Bool(false))
            _ => Err("session-http: invalid run bool result")
          }
        _ => Err("session-http: invalid run response")
      }
    }
    _ => Err("session-http: invalid run response")
  }
}

///|
fn run_entry_via_session(
  entry_path : String,
  features : @runtime.RuntimeFeatureFlags,
) -> Result[WasmRunValue, String] {
  let port = match ensure_session_http_worker(entry_path, features) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let req : Map[String, Json] = {}
  req["cmd"] = Json::string("run")
  req["path"] = Json::string(entry_path)
  let json = match session_http_request_json(port, Json::object(req)) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  parse_cli_run_value_json(json)
}

///|
fn parse_cli_test_report_json(json : Json) -> Result[CliTestReport, String] {
  match json {
    Json::Object(obj) => {
      let failures : Array[CliTestFailure] = []
      match obj.get("failures") {
        Some(Json::Array(items)) =>
          for item in items {
            match item {
              Json::Object(failure_obj) => {
                let name = match failure_obj.get("name") {
                  Some(Json::String(value)) => Some(value)
                  _ => None
                }
                let error = match failure_obj.get("error") {
                  Some(Json::String(value)) => value
                  _ => ""
                }
                failures.push(CliTestFailure::{ name, error })
              }
              _ => ()
            }
          }
        _ => ()
      }
      Ok({
        total: parse_report_json_int(json, "total"),
        passed: parse_report_json_int(json, "passed"),
        failed: parse_report_json_int(json, "failed"),
        failures,
      })
    }
    _ => Err("session-http: invalid test response")
  }
}

///|
fn run_test_file_via_session(
  entry_path : String,
  features : @runtime.RuntimeFeatureFlags,
) -> Result[CliTestReport, String] {
  let port = match ensure_session_http_worker(entry_path, features) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let req : Map[String, Json] = {}
  req["cmd"] = Json::string("test")
  req["path"] = Json::string(entry_path)
  let json = match session_http_request_json(port, Json::object(req)) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  parse_cli_test_report_json(json)
}

///|
fn elapsed_us_to_ms_int(elapsed_us : Double) -> Int {
  let elapsed_ms = (elapsed_us / 1000.0).to_int()
  if elapsed_ms <= 0 {
    1
  } else {
    elapsed_ms
  }
}

///|
fn test_cmd_report_json(
  entry_paths : Array[String],
  features : @runtime.RuntimeFeatureFlags,
) -> Unit {
  vibe_worker_process_group_init()
  let worker_parent_pid = test_worker_parent_pid()
  match worker_parent_pid {
    Some(parent_pid) => vibe_worker_parent_watchdog_start(parent_pid)
    None => ()
  }
  defer vibe_worker_parent_watchdog_stop()
  let mut any_failed = false
  let cache = CliEntryDbCache::new()
  let use_session_http = cli_use_session_http()
  for entry_path in entry_paths {
    if should_exit_report_json_worker(worker_parent_pid) {
      c_exit(130)
    }
    let start = @bench.monotonic_clock_start()
    let mut elapsed_ms = 1
    let report = if use_session_http {
      match run_test_file_via_session(entry_path, features) {
        Ok(v) => Ok(v)
        Err(_) =>
          run_test_file_with_backend_with_cache(cache, entry_path, features)
      }
    } else {
      run_test_file_with_backend_with_cache(cache, entry_path, features)
    }
    match report {
      Ok(report) => {
        let elapsed_us = @bench.monotonic_clock_end(start)
        elapsed_ms = elapsed_us_to_ms_int(elapsed_us)
        println(
          make_cli_test_report_json(entry_path, report, elapsed_ms).stringify(),
        )
        if report.failed > 0 {
          any_failed = true
        }
      }
      Err(err) => {
        let elapsed_us = @bench.monotonic_clock_end(start)
        elapsed_ms = elapsed_us_to_ms_int(elapsed_us)
        println(
          make_error_report_json(entry_path, "test", err, elapsed_ms).stringify(),
        )
        any_failed = true
      }
    }
  }
  if any_failed {
    abort("test: failures detected")
  }
}

///|
fn parse_cli_session_request(
  line : String,
) -> Result[CliSessionRequest, String] {
  let json : Json = @json.parse(line) catch {
    _ => return Err("session-json: invalid json")
  }
  match json {
    Json::Object(obj) => {
      let cmd = match obj.get("cmd") {
        Some(Json::String(value)) => value.trim().to_string().to_lower()
        _ => return Err("session-json: missing cmd")
      }
      match cmd {
        "ping" =>
          Ok(CliSessionRequest::{
            kind: CliSessionRequestKind::Ping,
            path: None,
          })
        "run" =>
          match obj.get("path") {
            Some(Json::String(value)) => {
              let path = value.trim().to_string()
              if path.length() == 0 {
                Err("session-json: missing path")
              } else {
                Ok(CliSessionRequest::{
                  kind: CliSessionRequestKind::Run,
                  path: Some(path),
                })
              }
            }
            _ => Err("session-json: missing path")
          }
        "check" =>
          match obj.get("path") {
            Some(Json::String(value)) => {
              let path = value.trim().to_string()
              if path.length() == 0 {
                Err("session-json: missing path")
              } else {
                Ok(CliSessionRequest::{
                  kind: CliSessionRequestKind::Check,
                  path: Some(path),
                })
              }
            }
            _ => Err("session-json: missing path")
          }
        "test" =>
          match obj.get("path") {
            Some(Json::String(value)) => {
              let path = value.trim().to_string()
              if path.length() == 0 {
                Err("session-json: missing path")
              } else {
                Ok(CliSessionRequest::{
                  kind: CliSessionRequestKind::Test,
                  path: Some(path),
                })
              }
            }
            _ => Err("session-json: missing path")
          }
        "shutdown" | "quit" =>
          Ok(CliSessionRequest::{
            kind: CliSessionRequestKind::Shutdown,
            path: None,
          })
        _ => Err("session-json: unsupported cmd: " + cmd)
      }
    }
    _ => Err("session-json: request must be object")
  }
}

///|
fn handle_cli_session_request(
  cache : CliEntryDbCache,
  req : CliSessionRequest,
  features : @runtime.RuntimeFeatureFlags,
) -> (Json, Bool) {
  match req.kind {
    CliSessionRequestKind::Ping => {
      let obj : Map[String, Json] = {}
      obj["cmd"] = Json::string("ping")
      obj["ok"] = Json::boolean(true)
      (Json::object(obj), false)
    }
    CliSessionRequestKind::Shutdown => {
      let obj : Map[String, Json] = {}
      obj["cmd"] = Json::string("shutdown")
      obj["ok"] = Json::boolean(true)
      (Json::object(obj), true)
    }
    CliSessionRequestKind::Run =>
      match req.path {
        Some(path) =>
          match run_cmd_wasm_backend_with_cache(cache, path) {
            Ok(result) => {
              maybe_create_linked_cache_background(path)
              (make_cli_session_run_result_json(path, result), false)
            }
            Err(err) =>
              (make_cli_session_error_json("run", path, "run", err, 1), false)
          }
        None =>
          (
            make_cli_session_error_json(
              "run", "", "parse", "session-json: missing path", 1,
            ),
            false,
          )
      }
    CliSessionRequestKind::Check =>
      match req.path {
        Some(path) => {
          let report = run_check_entry_with_cache(cache, path, false)
          (make_cli_check_report_json(report), false)
        }
        None =>
          (
            make_cli_session_error_json(
              "check", "", "parse", "session-json: missing path", 1,
            ),
            false,
          )
      }
    CliSessionRequestKind::Test =>
      match req.path {
        Some(path) => {
          let start = @bench.monotonic_clock_start()
          match run_test_file_with_backend_with_cache(cache, path, features) {
            Ok(report) => {
              let elapsed_us = @bench.monotonic_clock_end(start)
              let elapsed_ms = elapsed_us_to_ms_int(elapsed_us)
              (
                make_cli_session_test_report_json(path, report, elapsed_ms),
                false,
              )
            }
            Err(err) => {
              let elapsed_us = @bench.monotonic_clock_end(start)
              let elapsed_ms = elapsed_us_to_ms_int(elapsed_us)
              (
                make_cli_session_error_json(
                  "test", path, "test", err, elapsed_ms,
                ),
                false,
              )
            }
          }
        }
        None =>
          (
            make_cli_session_error_json(
              "test", "", "parse", "session-json: missing path", 1,
            ),
            false,
          )
      }
  }
}

///|
fn session_json_cmd(
  args : Array[String],
  features : @runtime.RuntimeFeatureFlags,
) -> Unit {
  if args.length() > 0 {
    abort("session-json: unexpected args")
  }
  async fn session_loop() {
    let input = @stdio.stdin
    let cache = CliEntryDbCache::new()
    while input.read_until("\n") is Some(line) {
      let trimmed = line.trim().to_string()
      if trimmed.length() == 0 {
        continue
      }
      match parse_cli_session_request(trimmed) {
        Err(err) =>
          println(
            make_cli_session_error_json("session", "", "parse", err, 1).stringify(),
          )
        Ok(req) => {
          let (response, should_shutdown) = handle_cli_session_request(
            cache, req, features,
          )
          println(response.stringify())
          if should_shutdown {
            break
          }
        }
      }
    }
  }
  @async.run_async_main(session_loop)
}

///|
fn split_session_http_cmd_args(args : Array[String]) -> Result[Int, String] {
  let mut port : Int? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if arg == "--port" {
      i += 1
      if i >= args.length() {
        return Err("session-http: missing value after --port")
      }
      let parsed = @strconv.parse_int(args[i]) catch {
        e => return Err("session-http: invalid --port: " + e.to_string())
      }
      port = Some(parsed)
    } else {
      return Err("session-http: unknown arg " + arg)
    }
    i += 1
  }
  match port {
    Some(v) if v > 0 => Ok(v)
    _ => Err("session-http: --port is required")
  }
}

///|
fn session_http_cmd(
  args : Array[String],
  features : @runtime.RuntimeFeatureFlags,
) -> Unit {
  let port = match split_session_http_cmd_args(args) {
    Ok(v) => v
    Err(err) => abort(err)
  }
  let cache = CliEntryDbCache::new()
  async fn session_http_loop() {
    let addr = @socket.Addr::parse("127.0.0.1:\{port}") catch {
      err => abort("session-http: invalid listen addr: " + err.to_string())
    }
    let server = @http.Server::new(addr) catch {
      err => abort("session-http: listen failed: " + err.to_string())
    }
    server.run_forever(
      (_request, body, conn) => {
        let request_buf = StringBuilder::new()
        try {
          while body.read_some() is Some(chunk) {
            request_buf.write_string(@utf8.decode(chunk))
          }
        } catch {
          _ => ()
        }
        let request_body = request_buf.to_string()
        let (response, should_shutdown) = match
          parse_cli_session_request(request_body) {
          Ok(req) => handle_cli_session_request(cache, req, features)
          Err(err) =>
            (make_cli_session_error_json("session", "", "parse", err, 1), false)
        }
        conn.send_response(200, "OK", extra_headers={
          "content-type": "application/json",
        })
        conn..write(response.stringify()).end_response()
        if should_shutdown {
          server.close()
          c_exit(0)
        }
      },
      allow_failure=true,
      max_connections=1,
    )
  }
  @async.run_async_main(session_http_loop)
}

///|
fn parse_report_json_int(json : Json, key : String) -> Int {
  match json {
    Json::Object(obj) =>
      match obj.get(key) {
        Some(Json::Number(n, ..)) => n.to_int()
        _ => 0
      }
    _ => 0
  }
}

///|
fn parse_internal_parent_pid_env(env_name : String) -> Int? {
  match @sys.get_env_var(env_name) {
    Some(raw) => {
      let pid = @strconv.parse_int(raw) catch { _ => 0 }
      if pid > 1 {
        Some(pid)
      } else {
        None
      }
    }
    None => None
  }
}

///|
fn internal_parent_pid_env() -> Int? {
  match parse_internal_parent_pid_env("VIBE_INTERNAL_PARENT_PID") {
    Some(pid) => Some(pid)
    None => parse_internal_parent_pid_env("VIBE_INTERNAL_TEST_PARENT_PID")
  }
}

///|
fn test_worker_parent_pid() -> Int? {
  internal_parent_pid_env()
}

///|
fn should_exit_report_json_worker(parent_pid : Int?) -> Bool {
  match parent_pid {
    Some(pid) => vibe_process_exists(pid) == 0
    None => false
  }
}

///|
fn parse_report_json_string(json : Json, key : String) -> String {
  match json {
    Json::Object(obj) =>
      match obj.get(key) {
        Some(Json::String(s)) => s
        _ => ""
      }
    _ => ""
  }
}

///|
fn find_json_lines(text : String) -> Array[String] {
  let lines = text.split("\n")
  let out : Array[String] = []
  for line in lines {
    let trimmed = line.to_string().trim().to_string()
    if trimmed.length() > 0 && trimmed.has_prefix("{") {
      out.push(trimmed)
    }
  }
  out
}

///|
fn decode_process_output_lossy(bytes : Bytes) -> String {
  @utf8.decode_lossy(bytes[:])
}

///|
fn test_batch_weight_cache_path() -> String? {
  match @sys.get_env_var("VIBE_TEST_BATCH_WEIGHT_CACHE") {
    Some(raw) => {
      let trimmed = raw.trim().to_string()
      if trimmed.length() == 0 {
        None
      } else {
        Some(trimmed)
      }
    }
    None => None
  }
}

///|
fn strip_leading_slashes(path : String) -> String {
  let mut start = 0
  for _, c in path {
    if c == '/' {
      start += 1
    } else {
      break
    }
  }
  if start > 0 {
    target_substring(path, start, path.length())
  } else {
    path
  }
}

///|
fn test_batch_weight_cache_key(path : String) -> String {
  if not(path.has_prefix("/")) {
    return strip_leading_slashes(@vibe_fs.normalize_path(path))
  }
  let normalized = @vibe_fs.normalize_path(path)
  if not(normalized.has_prefix("/")) {
    return normalized
  }
  let cwd = @vibe_fs.normalize_path(@io.current_dir_or_root())
  if cwd == "/" {
    return strip_leading_slashes(normalized)
  }
  let cwd_prefix = cwd + "/"
  if normalized.has_prefix(cwd_prefix) {
    target_substring(normalized, cwd_prefix.length(), normalized.length())
  } else {
    normalized
  }
}

///|
fn load_test_batch_weight_cache(cache_path : String) -> Map[String, Int] {
  if not(@os_fs.path_exists(cache_path)) {
    return {}
  }
  let text = @os_fs.read_file_to_string(cache_path) catch { _ => return {} }
  let json : Json = @json.parse(text) catch { _ => return {} }
  let out : Map[String, Int] = {}
  match json {
    Json::Object(obj) =>
      for key, value in obj {
        match value {
          Json::Number(n, ..) => {
            let weight = n.to_int()
            if weight > 0 {
              out[test_batch_weight_cache_key(key)] = weight
            }
          }
          _ => ()
        }
      }
    _ => ()
  }
  out
}

///|
fn ensure_dir_recursive_best_effort(path : String) -> Unit {
  if path.length() == 0 || path == "." {
    return
  }
  if @os_fs.path_exists(path) {
    return
  }
  let parent = @vibe_fs.parent_path(path)
  if parent != path && parent.length() > 0 {
    ensure_dir_recursive_best_effort(parent)
  }
  @os_fs.create_dir(path) catch {
    _ => ()
  }
}

///|
fn save_test_batch_weight_cache(
  cache_path : String,
  weights : Map[String, Int],
) -> Unit {
  let parent = @vibe_fs.parent_path(cache_path)
  if parent != cache_path && parent.length() > 0 {
    ensure_dir_recursive_best_effort(parent)
  }
  let obj : Map[String, Json] = {}
  for path, weight in weights {
    if weight > 0 {
      obj[test_batch_weight_cache_key(path)] = Json::number(weight.to_double())
    }
  }
  @os_fs.write_string_to_file(cache_path, Json::object(obj).stringify()) catch {
    _ => ()
  }
}

///|
fn test_entry_batch_parent(path : String) -> String {
  @vibe_fs.parent_path(path)
}

///|
fn test_entry_batch_root(path : String) -> String {
  let resolved = @loader.resolve_entry_path(path)
  @codebase.resolve_index_root(resolved)
}

///|
struct TestEntryBatchUnit {
  root : String
  parent : String
  paths : Array[String]
  weight : Int
}

///|
fn sort_strings_for_batching(values : Array[String]) -> Unit {
  let n = values.length()
  if n < 2 {
    return
  }
  for i in 0..<(n - 1) {
    let mut min_index = i
    for j in (i + 1)..<n {
      if values[j].compare(values[min_index]) < 0 {
        min_index = j
      }
    }
    if min_index != i {
      let tmp = values[i]
      values[i] = values[min_index]
      values[min_index] = tmp
    }
  }
}

///|
fn compare_test_entry_batch_path(a : String, b : String) -> Int {
  let a_parent = test_entry_batch_parent(a)
  let b_parent = test_entry_batch_parent(b)
  let parent_cmp = a_parent.compare(b_parent)
  if parent_cmp != 0 {
    parent_cmp
  } else {
    a.compare(b)
  }
}

///|
fn sort_test_entry_paths_for_batching(paths : Array[String]) -> Unit {
  let n = paths.length()
  if n < 2 {
    return
  }
  for i in 0..<(n - 1) {
    let mut min_index = i
    for j in (i + 1)..<n {
      if compare_test_entry_batch_path(paths[j], paths[min_index]) < 0 {
        min_index = j
      }
    }
    if min_index != i {
      let tmp = paths[i]
      paths[i] = paths[min_index]
      paths[min_index] = tmp
    }
  }
}

///|
fn compare_test_entry_batch_unit(
  a : TestEntryBatchUnit,
  b : TestEntryBatchUnit,
) -> Int {
  if a.weight > b.weight {
    return -1
  }
  if a.weight < b.weight {
    return 1
  }
  let a_len = a.paths.length()
  let b_len = b.paths.length()
  if a_len > b_len {
    -1
  } else if a_len < b_len {
    1
  } else {
    let root_cmp = a.root.compare(b.root)
    if root_cmp != 0 {
      root_cmp
    } else {
      a.parent.compare(b.parent)
    }
  }
}

///|
fn sort_test_entry_batch_units(units : Array[TestEntryBatchUnit]) -> Unit {
  let n = units.length()
  if n < 2 {
    return
  }
  for i in 0..<(n - 1) {
    let mut min_index = i
    for j in (i + 1)..<n {
      if compare_test_entry_batch_unit(units[j], units[min_index]) < 0 {
        min_index = j
      }
    }
    if min_index != i {
      let tmp = units[i]
      units[i] = units[min_index]
      units[min_index] = tmp
    }
  }
}

///|
fn test_entry_batch_min_load_index(loads : Array[Int]) -> Int {
  let mut min_index = 0
  let mut min_value = loads[0]
  for i in 1..<loads.length() {
    if loads[i] < min_value {
      min_value = loads[i]
      min_index = i
    }
  }
  min_index
}

///|
fn test_entry_batch_min_same_root_index(
  loads : Array[Int],
  batch_roots : Array[Map[String, Bool]],
  unit_root : String,
) -> Int? {
  let mut best_index : Int? = None
  let mut best_load = 0
  for i in 0..<loads.length() {
    let load = loads[i]
    if batch_roots[i].contains(unit_root) {
      match best_index {
        Some(_) =>
          if load < best_load {
            best_index = Some(i)
            best_load = load
          }
        None => {
          best_index = Some(i)
          best_load = load
        }
      }
    }
  }
  best_index
}

///|
fn test_entry_batch_min_empty_index(
  loads : Array[Int],
  batch_roots : Array[Map[String, Bool]],
) -> Int? {
  let mut best_index : Int? = None
  let mut best_load = 0
  for i in 0..<loads.length() {
    if batch_roots[i].length() == 0 {
      let load = loads[i]
      match best_index {
        Some(_) =>
          if load < best_load {
            best_index = Some(i)
            best_load = load
          }
        None => {
          best_index = Some(i)
          best_load = load
        }
      }
    }
  }
  best_index
}

///|
fn test_entry_batch_has_unassigned_other_root_after(
  units : Array[TestEntryBatchUnit],
  start_index : Int,
  batch_roots : Array[Map[String, Bool]],
  current_root : String,
) -> Bool {
  for i in start_index..<units.length() {
    let root = units[i].root
    if root != current_root {
      let mut already_assigned = false
      for roots in batch_roots {
        if roots.contains(root) {
          already_assigned = true
        }
      }
      if not(already_assigned) {
        return true
      }
    }
  }
  false
}

///|
fn test_entry_batch_path_weight(
  path : String,
  weights : Map[String, Int],
) -> Int {
  let key = test_batch_weight_cache_key(path)
  match weights.get(key) {
    Some(weight) => if weight > 0 { weight } else { 1 }
    None => 1
  }
}

///|
fn test_entry_batch_paths_weight(
  paths : Array[String],
  weights : Map[String, Int],
) -> Int {
  let mut total = 0
  for path in paths {
    total += test_entry_batch_path_weight(path, weights)
  }
  total
}

///|
let test_entry_batch_max_chunk_size = 4

///|
fn test_entry_batch_env_chunk_size() -> Int? {
  match @sys.get_env_var("VIBE_TEST_BATCH_CHUNK_SIZE") {
    Some(raw) => {
      let parsed = @strconv.parse_int(raw.trim().to_string()) catch { _ => 0 }
      if parsed > 0 {
        Some(parsed)
      } else {
        None
      }
    }
    None => None
  }
}

///|
fn test_entry_batch_target_chunk_size(
  entry_count : Int,
  worker_count : Int,
  use_fine_grained_chunking : Bool,
) -> Int {
  let configured = test_entry_batch_env_chunk_size()
  if configured is Some(chunk_size) {
    if chunk_size > test_entry_batch_max_chunk_size {
      return test_entry_batch_max_chunk_size
    } else {
      return chunk_size
    }
  }
  if use_fine_grained_chunking {
    return 1
  }
  let base = (entry_count + worker_count - 1) / worker_count
  if base < 1 {
    1
  } else if base > test_entry_batch_max_chunk_size {
    test_entry_batch_max_chunk_size
  } else {
    base
  }
}

///|
fn test_entry_batch_target_weight_limit(
  entry_paths : Array[String],
  worker_count : Int,
  weights : Map[String, Int],
) -> Int {
  if weights.length() == 0 {
    return 0
  }
  let total_weight = test_entry_batch_paths_weight(entry_paths, weights)
  if total_weight <= 0 {
    return 0
  }
  let safe_workers = if worker_count <= 0 { 1 } else { worker_count }
  let limit = (total_weight + safe_workers - 1) / safe_workers
  if limit <= 0 {
    1
  } else {
    limit
  }
}

///|
fn test_entry_batch_display_name(path : String) -> String {
  get_basename(path)
}

///|
fn collect_test_entry_batch_units(
  entry_paths : Array[String],
  jobs : Int,
  weights : Map[String, Int],
) -> Array[TestEntryBatchUnit] {
  let mut worker_count = jobs
  if worker_count <= 0 {
    worker_count = 1
  }
  if worker_count > entry_paths.length() {
    worker_count = entry_paths.length()
  }
  let grouped : Map[String, Array[String]] = {}
  for path in entry_paths {
    let parent = test_entry_batch_parent(path)
    match grouped.get(parent) {
      Some(paths) => paths.push(path)
      None => grouped[parent] = [path]
    }
  }
  let parent_keys : Array[String] = []
  for key, _ in grouped {
    parent_keys.push(key)
  }
  sort_strings_for_batching(parent_keys)
  let use_fine_grained_chunking = weights.length() > 0

  let target_chunk_size = test_entry_batch_target_chunk_size(
    entry_paths.length(),
    worker_count,
    use_fine_grained_chunking,
  )
  let target_chunk_weight = test_entry_batch_target_weight_limit(
    entry_paths, worker_count, weights,
  )
  let units : Array[TestEntryBatchUnit] = []
  for parent in parent_keys {
    let parent_paths = match grouped.get(parent) {
      Some(paths) => paths
      None => continue
    }
    let root = test_entry_batch_root(parent_paths[0])
    sort_test_entry_paths_for_batching(parent_paths)
    let mut offset = 0
    while offset < parent_paths.length() {
      let chunk : Array[String] = []
      let mut chunk_count = 0
      let mut chunk_weight = 0
      while offset < parent_paths.length() && chunk_count < target_chunk_size {
        let next_path = parent_paths[offset]
        let next_weight = test_entry_batch_path_weight(next_path, weights)
        if target_chunk_weight > 0 &&
          chunk_count > 0 &&
          chunk_weight + next_weight > target_chunk_weight {
          offset = offset
          chunk_count = target_chunk_size
        } else {
          chunk.push(next_path)
          chunk_weight += next_weight
          offset += 1
          chunk_count += 1
        }
      }
      units.push(TestEntryBatchUnit::{
        root,
        parent,
        weight: chunk_weight,
        paths: chunk,
      })
    }
  }
  sort_test_entry_batch_units(units)
  units
}

///|
fn summarize_test_entry_batch_paths(paths : Array[String]) -> String {
  let parts : Array[String] = []
  let preview_count = if paths.length() < 3 { paths.length() } else { 3 }
  for i in 0..<preview_count {
    parts.push(test_entry_batch_display_name(paths[i]))
  }
  let summary = parts.join(", ")
  if paths.length() > preview_count {
    summary + ", +" + (paths.length() - preview_count).to_string() + " more"
  } else {
    summary
  }
}

///|
fn split_test_entry_task_batches_with_weights(
  entry_paths : Array[String],
  jobs : Int,
  weights : Map[String, Int],
) -> Array[Array[String]] {
  let mut worker_count = jobs
  if worker_count <= 0 {
    worker_count = 1
  }
  if worker_count > entry_paths.length() {
    worker_count = entry_paths.length()
  }
  let batches : Array[Array[String]] = []
  let loads : Array[Int] = []
  let batch_roots : Array[Map[String, Bool]] = []
  for _ in 0..<worker_count {
    batches.push([])
    loads.push(0)
    batch_roots.push({})
  }
  let units = collect_test_entry_batch_units(entry_paths, worker_count, weights)
  for i, unit in units {
    let same_root_index = test_entry_batch_min_same_root_index(
      loads,
      batch_roots,
      unit.root,
    )
    let empty_index = test_entry_batch_min_empty_index(loads, batch_roots)
    let batch_index = match same_root_index {
      Some(index) =>
        if test_entry_batch_has_unassigned_other_root_after(
            units,
            i + 1,
            batch_roots,
            unit.root,
          ) {
          index
        } else {
          match empty_index {
            Some(empty) => empty
            None => index
          }
        }
      None =>
        match empty_index {
          Some(index) => index
          None => test_entry_batch_min_load_index(loads)
        }
    }
    for path in unit.paths {
      batches[batch_index].push(path)
    }
    loads[batch_index] += unit.weight
    batch_roots[batch_index][unit.root] = true
  }
  let compacted : Array[Array[String]] = []
  for batch in batches {
    if batch.length() > 0 {
      compacted.push(batch)
    }
  }
  compacted
}

///|
fn split_test_entry_path_batches_with_weights(
  entry_paths : Array[String],
  jobs : Int,
  weights : Map[String, Int],
) -> Array[Array[String]] {
  let mut worker_count = jobs
  if worker_count <= 0 {
    worker_count = 1
  }
  if worker_count > entry_paths.length() {
    worker_count = entry_paths.length()
  }
  let batches : Array[Array[String]] = []
  for _ in 0..<worker_count {
    batches.push([])
  }
  let units = collect_test_entry_batch_units(entry_paths, worker_count, weights)

  let loads : Array[Int] = []
  let batch_roots : Array[Map[String, Bool]] = []
  for _ in 0..<worker_count {
    loads.push(0)
    batch_roots.push({})
  }
  for i, unit in units {
    let same_root_index = test_entry_batch_min_same_root_index(
      loads,
      batch_roots,
      unit.root,
    )
    let empty_index = test_entry_batch_min_empty_index(loads, batch_roots)
    let batch_index = match same_root_index {
      Some(index) =>
        if test_entry_batch_has_unassigned_other_root_after(
            units,
            i + 1,
            batch_roots,
            unit.root,
          ) {
          index
        } else {
          match empty_index {
            Some(empty) => empty
            None => index
          }
        }
      None =>
        match empty_index {
          Some(index) => index
          None => test_entry_batch_min_load_index(loads)
        }
    }
    for path in unit.paths {
      batches[batch_index].push(path)
    }
    loads[batch_index] += unit.weight
    batch_roots[batch_index][unit.root] = true
  }
  batches
}

///|
fn split_test_entry_path_batches(
  entry_paths : Array[String],
  jobs : Int,
) -> Array[Array[String]] {
  split_test_entry_path_batches_with_weights(entry_paths, jobs, {})
}

///|
fn test_cmd_parallel(
  entry_paths : Array[String],
  features : @runtime.RuntimeFeatureFlags,
  jobs : Int,
) -> Unit {
  let exe = @env.args()[0]
  let parent_pid_env_value = vibe_getpid().to_string()
  let batch_weight_cache_path = test_batch_weight_cache_path()
  let use_batch_weight_cache = match batch_weight_cache_path {
    Some(_) => true
    None => false
  }
  let cached_batch_weights = match batch_weight_cache_path {
    Some(cache_path) => load_test_batch_weight_cache(cache_path)
    None => {}
  }
  let batches = if jobs == 1 {
    let singleton_batches : Array[Array[String]] = []
    for path in entry_paths {
      singleton_batches.push([path])
    }
    singleton_batches
  } else if use_batch_weight_cache {
    split_test_entry_task_batches_with_weights(
      entry_paths, jobs, cached_batch_weights,
    )
  } else {
    split_test_entry_path_batches(entry_paths, jobs)
  }
  let max_concurrent = if jobs == 1 {
    1
  } else if batches.length() < jobs {
    batches.length()
  } else {
    jobs
  }
  vibe_parallel_cleanup_install_signal_handlers()
  vibe_parallel_cleanup_clear()
  defer vibe_parallel_cleanup_clear()
  let tasks : Array[async () -> (Array[String], Int, String, String)] = []
  let should_print_batch_progress = batches.length() > 1
  for i, batch in batches {
    let sub_args : Array[String] = ["test", "--report-json", "--jobs", "1"]
    let extra_env : Map[String, String] = {}
    extra_env["VIBE_INTERNAL_TEST_PARENT_PID"] = parent_pid_env_value
    for path in batch {
      sub_args.push(path)
    }
    if features.is_unstable_async_enabled() {
      sub_args.push("--unstable-async")
    }
    if features.is_unstable_threads_enabled() {
      sub_args.push("--unstable-threads")
    }
    let captured_batch = batch
    let captured_args = sub_args
    let captured_extra_env = extra_env
    let batch_index = i + 1
    let batch_total = batches.length()
    let batch_summary = summarize_test_entry_batch_paths(batch)
    let batch_count = batch.length()
    tasks.push(async fn() {
      if should_print_batch_progress {
        println(
          "test batch " +
          batch_index.to_string() +
          "/" +
          batch_total.to_string() +
          " start (" +
          batch_count.to_string() +
          " files): " +
          batch_summary,
        )
      }
      @async.with_task_group(group => {
        let (r_out, w_out) = @async_process.read_from_process()
        let (r_err, w_err) = @async_process.read_from_process()
        let child = @async_process.spawn(
          group,
          exe[:],
          captured_args[:],
          extra_env=captured_extra_env,
          stdout=w_out,
          stderr=w_err,
          cancel_handler=@async_process.hard_cancel(),
        )
        vibe_parallel_cleanup_assign_child_process_group(child.pid)
        vibe_parallel_cleanup_register_child_pid(child.pid)
        defer vibe_parallel_cleanup_unregister_child_pid(child.pid)
        let stdout_task = group.spawn(() => {
          defer r_out.close()
          r_out.read_all()
        })
        let stderr_task = group.spawn(() => {
          defer r_err.close()
          r_err.read_all()
        })
        let code = child.wait()
        let out = decode_process_output_lossy(stdout_task.wait().binary())
        let err = decode_process_output_lossy(stderr_task.wait().binary())
        (captured_batch, code, out, err)
      })
    })
  }
  @async.run_async_main(async fn() {
    let results = @async.all(tasks[:], max_concurrent~)
    let merged_batch_weights : Map[String, Int] = {}
    for path, weight in cached_batch_weights {
      if weight > 0 {
        merged_batch_weights[test_batch_weight_cache_key(path)] = weight
      }
    }
    let mut total = 0
    let mut passed = 0
    let mut failed_count = 0
    let mut any_failed = false
    let file_count = entry_paths.length()
    for result in results {
      let (batch_paths, code, stdout_text, stderr_text) = result
      let report_lines = find_json_lines(stdout_text)
      let report_by_path : Map[String, Json] = {}
      let mut report_count = 0
      for line in report_lines {
        let json : Json = @json.parse(line) catch { _ => continue }
        let report_path = parse_report_json_string(json, "file")
        if report_path.length() == 0 {
          continue
        }
        report_by_path[report_path] = json
        report_count += 1
      }
      if report_count == 0 {
        for path in batch_paths {
          println("\{path}: fail (invalid JSON report)")
          if code != 0 {
            println("  process exited with code \{code}")
          }
          if stdout_text.trim().to_string().length() > 0 {
            println("  stdout: \{stdout_text.trim().to_string()}")
          }
          if stderr_text.trim().to_string().length() > 0 {
            println("  stderr: \{stderr_text.trim().to_string()}")
          }
          any_failed = true
          failed_count += 1
          total += 1
        }
        continue
      }
      for path in batch_paths {
        match report_by_path.get(path) {
          Some(json) => {
            let file_total = parse_report_json_int(json, "total")
            let file_passed = parse_report_json_int(json, "passed")
            let file_failed = parse_report_json_int(json, "failed")
            let file_elapsed_ms = parse_report_json_int(json, "elapsed_ms")
            total += file_total
            passed += file_passed
            failed_count += file_failed
            if file_elapsed_ms > 0 {
              merged_batch_weights[test_batch_weight_cache_key(path)] = file_elapsed_ms
            }
            let status = if file_failed == 0 { "ok" } else { "fail" }
            println("\{path}: \{status} (\{file_passed}/\{file_total})")
            if file_failed > 0 {
              any_failed = true
              match json {
                Json::Object(obj) =>
                  match obj.get("failures") {
                    Some(Json::Array(failures)) => {
                      println("  failures:")
                      for f in failures {
                        let name = parse_report_json_string(f, "name")
                        let error = parse_report_json_string(f, "error")
                        println("  - \{name}: \{error}")
                      }
                    }
                    _ => ()
                  }
                _ => ()
              }
            }
          }
          None => {
            println("\{path}: fail (missing JSON report)")
            if code != 0 {
              println("  process exited with code \{code}")
              if stderr_text.trim().to_string().length() > 0 {
                println("  stderr: \{stderr_text.trim().to_string()}")
              }
            }
            any_failed = true
            failed_count += 1
            total += 1
          }
        }
      }
      if code != 0 {
        let mut has_failure_in_batch = false
        for path in batch_paths {
          match report_by_path.get(path) {
            Some(json) =>
              if parse_report_json_int(json, "failed") > 0 {
                has_failure_in_batch = true
              }
            None => has_failure_in_batch = true
          }
        }
        if not(has_failure_in_batch) {
          for path in batch_paths {
            println("\{path}: fail (process exited with code \{code})")
          }
          if stderr_text.trim().to_string().length() > 0 {
            println("  stderr: \{stderr_text.trim().to_string()}")
          }
          any_failed = true
          failed_count += batch_paths.length()
          total += batch_paths.length()
        }
      }
    }
    match batch_weight_cache_path {
      Some(cache_path) =>
        save_test_batch_weight_cache(cache_path, merged_batch_weights)
      None => ()
    }
    println(
      "summary: files=\{file_count} total=\{total} passed=\{passed} failed=\{failed_count}",
    )
    if any_failed {
      abort("test: failures detected")
    }
  })
}

///|
fn normalize_collect_decl_or_conflict(
  seen : Map[String, String],
  kind : String,
  name : String,
  source_path : String,
) -> Result[Unit, String] {
  let key = kind + ":" + name
  match seen.get(key) {
    Some(prev_path) =>
      if prev_path == source_path {
        Ok(())
      } else {
        Err(
          "normalize: duplicate " +
          kind +
          " `" +
          name +
          "` across files: " +
          prev_path +
          " and " +
          source_path,
        )
      }
    None => {
      seen[key] = source_path
      Ok(())
    }
  }
}

///|
fn normalize_collect_top_level_decls(
  seen : Map[String, String],
  source_path : String,
  source : String,
) -> Result[Unit, String] {
  let ast = @parser.parse_ast(source) catch {
    e =>
      return Err(
        "normalize: parse failed for `" + source_path + "`: " + e.to_string(),
      )
  }
  for stmt in ast.stmts {
    match stmt {
      @vibe_core.Stmt::Let(name~, ..)
      | @vibe_core.Stmt::ExportLet(name~, ..)
      | @vibe_core.Stmt::LetMut(name~, ..) =>
        match
          normalize_collect_decl_or_conflict(seen, "value", name, source_path) {
          Ok(_) => ()
          Err(err) => return Err(err)
        }
      @vibe_core.Stmt::EnumDef(name~, ..)
      | @vibe_core.Stmt::ExportEnumDef(name~, ..)
      | @vibe_core.Stmt::TypeAlias(name~, ..)
      | @vibe_core.Stmt::ExportTypeAlias(name~, ..)
      | @vibe_core.Stmt::StructDef(name~, ..)
      | @vibe_core.Stmt::ExportStructDef(name~, ..) =>
        match
          normalize_collect_decl_or_conflict(seen, "type", name, source_path) {
          Ok(_) => ()
          Err(err) => return Err(err)
        }
      @vibe_core.Stmt::TraitDef(name~, ..) =>
        match
          normalize_collect_decl_or_conflict(seen, "trait", name, source_path) {
          Ok(_) => ()
          Err(err) => return Err(err)
        }
      _ => ()
    }
  }
  Ok(())
}

///|
fn normalize_is_simple_semver(text : String) -> Bool {
  let parts : Array[String] = []
  for part in text.split(".") {
    let normalized = part.to_string()
    if normalized.length() == 0 {
      return false
    }
    for c in normalized {
      if c < '0' || c > '9' {
        return false
      }
    }
    parts.push(normalized)
  }
  parts.length() == 3
}

///|
fn normalize_parse_digits(text : String) -> Int? {
  if text.length() == 0 {
    return None
  }
  let mut value = 0
  for _, c in text {
    if c < '0' || c > '9' {
      return None
    }
    value = value * 10 + c.to_int() - '0'.to_int()
  }
  Some(value)
}

///|
fn normalize_parse_semver(text : String) -> (Int, Int, Int)? {
  let parts : Array[String] = []
  for part in text.split(".") {
    parts.push(part.to_string())
  }
  if parts.length() != 3 {
    return None
  }
  let major = match normalize_parse_digits(parts[0]) {
    Some(v) => v
    None => return None
  }
  let minor = match normalize_parse_digits(parts[1]) {
    Some(v) => v
    None => return None
  }
  let patch = match normalize_parse_digits(parts[2]) {
    Some(v) => v
    None => return None
  }
  Some((major, minor, patch))
}

///|
fn normalize_compare_semver(a : (Int, Int, Int), b : (Int, Int, Int)) -> Int {
  let (a_major, a_minor, a_patch) = a
  let (b_major, b_minor, b_patch) = b
  if a_major < b_major {
    -1
  } else if a_major > b_major {
    1
  } else if a_minor < b_minor {
    -1
  } else if a_minor > b_minor {
    1
  } else if a_patch < b_patch {
    -1
  } else if a_patch > b_patch {
    1
  } else {
    0
  }
}

///|
fn normalize_scope_parent_and_name(scope : String) -> (String, String) {
  let mut last_slash : Int? = None
  for i, c in scope {
    if c == '/' {
      last_slash = Some(i)
    }
  }
  match last_slash {
    Some(i) =>
      (
        scope.unsafe_substring(start=0, end=i),
        scope.unsafe_substring(start=i + 1, end=scope.length()),
      )
    None => ("", scope)
  }
}

///|
fn normalize_resolve_latest_scope_version(
  lib_root : String,
  scope : String,
) -> String? {
  let (parent, leaf) = normalize_scope_parent_and_name(scope)
  if leaf.length() == 0 {
    return None
  }
  let dir = if parent.length() == 0 {
    @vibe_fs.normalize_path(lib_root)
  } else {
    @vibe_fs.normalize_path(lib_root + "/" + parent)
  }
  let entries = @os_fs.read_dir(dir) catch { _ => return None }
  let prefix = leaf + "@"
  let suffix = ".lock"
  let mut best_version : String? = None
  let mut best_semver : (Int, Int, Int)? = None
  for entry in entries {
    if not(entry.has_prefix(prefix)) || not(entry.has_suffix(suffix)) {
      continue
    }
    let ver_start = prefix.length()
    let ver_end = entry.length() - suffix.length()
    if ver_end <= ver_start {
      continue
    }
    let version = entry.unsafe_substring(start=ver_start, end=ver_end)
    match normalize_parse_semver(version) {
      Some(semver) =>
        match best_semver {
          Some(prev) =>
            if normalize_compare_semver(semver, prev) > 0 {
              best_semver = Some(semver)
              best_version = Some(version)
            }
          None => {
            best_semver = Some(semver)
            best_version = Some(version)
          }
        }
      None => ()
    }
  }
  best_version
}

///|
fn normalize_line_leading_ws_len(line : String) -> Int {
  let mut i = 0
  while i < line.length() {
    let c = line[i].to_int().unsafe_to_char()
    if c == ' ' || c == '\t' {
      i += 1
      continue
    }
    break
  }
  i
}

///|
fn normalize_split_ws_tokens(text : String) -> Array[String] {
  let out : Array[String] = []
  let mut i = 0
  while i < text.length() {
    while i < text.length() {
      let c = text[i].to_int().unsafe_to_char()
      if c == ' ' || c == '\t' {
        i += 1
        continue
      }
      break
    }
    let start = i
    while i < text.length() {
      let c = text[i].to_int().unsafe_to_char()
      if c == ' ' || c == '\t' {
        break
      }
      i += 1
    }
    if i > start {
      out.push(text.unsafe_substring(start~, end=i))
    }
  }
  out
}

///|
fn normalize_is_unversioned_scope_import_target(scope : String) -> Bool {
  if scope.contains("@") ||
    scope.has_prefix("./") ||
    scope.has_prefix("../") ||
    scope.has_prefix("/") ||
    scope.has_suffix(".vibe") ||
    scope.has_suffix(".xm") ||
    scope.has_suffix(".wasm") ||
    not(scope.contains("/")) {
    false
  } else {
    true
  }
}

///|
fn normalize_resolve_index_import_line(
  line : String,
  lib_root : String,
) -> Result[String, String] {
  let trimmed = line.trim().to_string()
  let head = if trimmed.has_prefix("import ") {
    "import "
  } else {
    return Ok(line)
  }
  let leading_ws = normalize_line_leading_ws_len(line)
  let import_head_end = leading_ws + head.length()
  if import_head_end >= line.length() {
    return Ok(line)
  }
  let rest = line.unsafe_substring(start=import_head_end, end=line.length())
  let prefix = if leading_ws == 0 {
    ""
  } else {
    line.unsafe_substring(start=0, end=leading_ws)
  }
  // Resolve `import <scope> { ... }` declarations.
  match rest.find("{") {
    Some(brace_pos) => {
      let scope_head = rest
        .unsafe_substring(start=0, end=brace_pos)
        .trim()
        .to_string()
      let scope_tokens = normalize_split_ws_tokens(scope_head)
      let scope_buf = StringBuilder::new()
      for token in scope_tokens {
        scope_buf.write_string(token)
      }
      let scope = scope_buf.to_string()
      if scope.length() == 0 ||
        not(normalize_is_unversioned_scope_import_target(scope)) {
        return Ok(line)
      }
      let version = match
        normalize_resolve_latest_scope_version(lib_root, scope) {
        Some(v) => v
        None =>
          return Err(
            "normalize: import `" +
            scope +
            "` missing version; no local alias found under " +
            lib_root,
          )
      }
      let suffix = rest
        .unsafe_substring(start=brace_pos, end=rest.length())
        .trim()
        .to_string()
      let out = StringBuilder::new()
      out.write_string(prefix)
      out.write_string(head)
      out.write_string(scope)
      out.write_char('@')
      out.write_string(version)
      out.write_char(' ')
      out.write_string(suffix)
      return Ok(out.to_string())
    }
    None => ()
  }
  // Resolve legacy bare `import <scope>` declarations.
  let mut rest_trimmed = rest.trim().to_string()
  let has_semicolon = rest_trimmed.has_suffix(";")
  if has_semicolon && rest_trimmed.length() > 0 {
    rest_trimmed = rest_trimmed
      .unsafe_substring(start=0, end=rest_trimmed.length() - 1)
      .trim()
      .to_string()
  }
  let tokens = normalize_split_ws_tokens(rest_trimmed)
  if tokens.length() == 0 {
    return Ok(line)
  }
  let scope_buf = StringBuilder::new()
  let mut alias_name : String? = None
  let mut i = 0
  while i < tokens.length() {
    let token = tokens[i]
    if token == "as" {
      if i + 1 < tokens.length() {
        alias_name = Some(tokens[i + 1])
      }
      break
    }
    scope_buf.write_string(token)
    i += 1
  }
  let scope = scope_buf.to_string()
  if scope.length() == 0 {
    return Ok(line)
  }
  if not(normalize_is_unversioned_scope_import_target(scope)) {
    return Ok(line)
  }
  let version = match normalize_resolve_latest_scope_version(lib_root, scope) {
    Some(v) => v
    None =>
      return Err(
        "normalize: import `" +
        scope +
        "` missing version; no local alias found under " +
        lib_root,
      )
  }
  let out = StringBuilder::new()
  out.write_string(prefix)
  out.write_string(head)
  out.write_string(scope)
  out.write_char('@')
  out.write_string(version)
  match alias_name {
    Some(alias_name2) => {
      out.write_string(" as ")
      out.write_string(alias_name2)
    }
    None => ()
  }
  if has_semicolon {
    out.write_char(';')
  }
  Ok(out.to_string())
}

///|
fn normalize_resolve_index_import_versions(
  source : String,
  lib_root : String,
) -> Result[String, String] {
  let lines : Array[String] = []
  for part in source.split("\n") {
    lines.push(part.to_string())
  }
  let out = StringBuilder::new()
  for i, line in lines {
    let resolved = match normalize_resolve_index_import_line(line, lib_root) {
      Ok(v) => v
      Err(err) => return Err(err)
    }
    if i > 0 {
      out.write_char('\n')
    }
    out.write_string(resolved)
  }
  Ok(out.to_string())
}

///|
fn normalize_ensure_index_version_export(
  source : String,
) -> Result[String, String] {
  let ast = @parser.parse_ast(source) catch {
    e => return Err("normalize: merged parse failed: " + e.to_string())
  }
  for stmt in ast.stmts {
    match stmt {
      @vibe_core.Stmt::ExportLet(name~, expr~, ..) =>
        if name == "version" {
          match expr {
            @vibe_core.Expr::String(value~, ..) =>
              if normalize_is_simple_semver(value) {
                return Ok(source)
              } else {
                return Err(
                  "normalize: index.vibe `export let version` must be semver like \"0.1.0\"",
                )
              }
            _ =>
              return Err(
                "normalize: index.vibe `export let version` must be a string literal",
              )
          }
        }
      _ => ()
    }
  }
  if source.trim().to_string().length() == 0 {
    Ok("export let version = \"0.1.0\"\n")
  } else {
    Ok("export let version = \"0.1.0\"\n\n" + source)
  }
}

///|
fn normalize_directory_vibe_files(
  dir : String,
) -> Result[Array[String], String] {
  let files : Array[String] = []
  let entries = @os_fs.read_dir(dir) catch {
    e =>
      return Err(
        "normalize: read dir failed: " + dir + " (" + e.to_string() + ")",
      )
  }
  for name in entries {
    if name == "." || name == ".." {
      continue
    }
    if not(name.has_suffix(".vibe")) {
      continue
    }
    let path = @vibe_fs.normalize_path(dir + "/" + name)
    let is_file = @os_fs.is_file(path) catch { _ => false }
    if is_file {
      files.push(path)
    }
  }
  files.sort()
  Ok(files)
}

///|
fn normalize_directory_to_index_source(
  dir : String,
  library_mode : Bool,
) -> Result[(String, String), String] {
  let files = match normalize_directory_vibe_files(dir) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let index_path = @vibe_fs.normalize_path(dir + "/index.vibe")
  let source_paths : Array[String] = []
  for path in files {
    source_paths.push(path)
  }
  if source_paths.length() == 0 {
    return Err("normalize: no .vibe files found in directory: " + dir)
  }
  let seen : Map[String, String] = {}
  let normalized_sources : Array[String] = []
  for path in source_paths {
    let source = @os_fs.read_file_to_string(path) catch {
      e => return Err("normalize: " + e.to_string())
    }
    let layering_violations = std_layering_violations_for_source(path, source)
    if layering_violations.length() > 0 {
      for violation in layering_violations {
        println("normalize: \{path}: \{violation}")
      }
      return Err("normalize: std layering violation(s) found")
    }
    let railway_notes = railway_boundary_notes_for_source(source)
    for note in railway_notes {
      println("normalize: \{path}: \{note}")
    }
    match normalize_collect_top_level_decls(seen, path, source) {
      Ok(_) => ()
      Err(err) => return Err(err)
    }
    let normalized = match normalize_format_file_source(path) {
      Ok(v) => v
      Err(err) => return Err("normalize: " + err)
    }
    normalized_sources.push(normalized)
  }
  let merged = match normalize_merge_sources(normalized_sources, library_mode) {
    Ok(v) => v
    Err(err) => return Err("normalize: " + err)
  }
  let lib_root = resolve_vibe_lib_dir(@io.current_dir_or_root())
  let resolved_imports = match
    normalize_resolve_index_import_versions(merged, lib_root) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let with_version = match
    normalize_ensure_index_version_export(resolved_imports) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  Ok((with_version, index_path))
}

///|
fn normalize_cmd(args : Array[String]) -> Unit {
  let options = match parse_normalize_cmd_options(args) {
    Ok(v) => v
    Err(msg) => abort(msg)
  }
  if options.merge {
    normalize_merge_cmd(
      options.files,
      options.library_mode,
      options.output_path,
    )
    return
  }
  let write = options.write
  let check = options.check
  let skip_unchanged = options.skip_unchanged
  let files = options.files
  let mut skipped = 0
  let mut written = 0
  let mut changed = 0
  for path in files {
    let absolute_input = if path.has_prefix("/") {
      @vibe_fs.normalize_path(path)
    } else {
      @vibe_fs.normalize_path(@io.current_dir_or_root() + "/" + path)
    }
    let is_dir_input = @os_fs.is_dir(absolute_input) catch { _ => false }
    if is_dir_input {
      let (normalized_dir, index_path) = match
        normalize_directory_to_index_source(
          absolute_input,
          options.library_mode,
        ) {
        Ok(v) => v
        Err(err) => abort(err)
      }
      let existing = if @os_fs.path_exists(index_path) {
        @os_fs.read_file_to_string(index_path) catch {
          _ => ""
        }
      } else {
        ""
      }
      let output = if write || check {
        apply_lock_annotations_for_format(index_path, normalized_dir)
      } else {
        normalized_dir
      }
      if check {
        if output != existing {
          changed += 1
          println("normalize: not normalized: \{index_path}")
        }
        continue
      }
      if write {
        if skip_unchanged && output == existing {
          skipped += 1
          continue
        }
        @os_fs.write_string_to_file(index_path, output) catch {
          e => abort("normalize: " + e.to_string())
        }
        written += 1
      } else {
        println(output)
      }
      continue
    }
    let resolved = @loader.resolve_entry_path(path)
    let source = @os_fs.read_file_to_string(resolved) catch {
      e => abort("normalize: " + e.to_string())
    }
    let layering_violations = std_layering_violations_for_source(
      resolved, source,
    )
    if layering_violations.length() > 0 {
      for violation in layering_violations {
        println("normalize: \{path}: \{violation}")
      }
      abort("normalize: std layering violation(s) found")
    }
    let railway_notes = railway_boundary_notes_for_source(source)
    for note in railway_notes {
      println("normalize: \{path}: \{note}")
    }
    let normalized = match normalize_format_file_source(resolved) {
      Ok(v) => v
      Err(err) => abort("normalize: " + err)
    }
    let output = if write || check {
      apply_lock_annotations_for_format(resolved, normalized)
    } else {
      normalized
    }
    if check {
      if output != source {
        changed += 1
        println("normalize: not normalized: \{path}")
      }
      continue
    }
    if write {
      if skip_unchanged && output == source {
        skipped += 1
        continue
      }
      @os_fs.write_string_to_file(resolved, output) catch {
        e => abort("normalize: " + e.to_string())
      }
      written += 1
    } else {
      println(output)
    }
  }
  if check {
    if changed > 0 {
      abort("normalize: \{changed} file(s) are not normalized")
    }
    println("normalize: \{files.length()} files already normalized")
    return
  }
  if skip_unchanged && write {
    println("normalize: \{written} written, \{skipped} skipped (unchanged)")
  }
}

///|
struct NormalizeCmdOptions {
  write : Bool
  check : Bool
  skip_unchanged : Bool
  merge : Bool
  library_mode : Bool
  output_path : String?
  files : Array[String]
}

///|
fn parse_normalize_cmd_options(
  args : Array[String],
) -> Result[NormalizeCmdOptions, String] {
  if args.length() == 0 {
    return Err("normalize: expected <file...>")
  }
  let mut write = false
  let mut check = false
  let mut skip_unchanged = false
  let mut merge = false
  let mut library_mode = false
  let mut output_path : String? = None
  let mut positional_only = false
  let files : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if positional_only {
      files.push(arg)
      i += 1
      continue
    }
    if arg == "--" {
      positional_only = true
      i += 1
      continue
    }
    match arg {
      "--write" | "-w" => {
        write = true
        i += 1
        continue
      }
      "--check" => {
        check = true
        i += 1
        continue
      }
      "--skip-unchanged" => {
        skip_unchanged = true
        i += 1
        continue
      }
      "--merge" => {
        merge = true
        i += 1
        continue
      }
      "--library" => {
        library_mode = true
        i += 1
        continue
      }
      "-o" => {
        i += 1
        if i >= args.length() {
          return Err("normalize: -o requires a path argument")
        }
        output_path = Some(args[i])
        i += 1
        continue
      }
      _ => {
        if arg.has_prefix("-") {
          return Err("normalize: unknown option " + arg)
        }
        files.push(arg)
        i += 1
        continue
      }
    }
  }
  if files.length() == 0 {
    return Err("normalize: expected <file...>")
  }
  if output_path is Some(_) && not(merge) {
    return Err("normalize: -o is only valid with --merge")
  }
  if check && write {
    return Err("normalize: --check cannot be combined with --write")
  }
  if check && skip_unchanged {
    return Err("normalize: --check cannot be combined with --skip-unchanged")
  }
  if check && merge {
    return Err("normalize: --check cannot be combined with --merge")
  }
  if not(write) && not(check) && files.length() > 1 && not(merge) {
    return Err("normalize: use --write or --check for multiple files")
  }
  Ok({ write, check, skip_unchanged, merge, library_mode, output_path, files })
}

///|
fn normalize_merge_cmd(
  files : Array[String],
  library_mode : Bool,
  output_path : String?,
) -> Unit {
  let sources : Array[String] = []
  for path in files {
    let resolved = @loader.resolve_entry_path(path)
    let source = @os_fs.read_file_to_string(resolved) catch {
      e => abort("normalize --merge: " + e.to_string())
    }
    sources.push(source)
  }
  let result = match normalize_merge_sources(sources, library_mode) {
    Ok(v) => v
    Err(err) => abort("normalize --merge: " + err)
  }
  match output_path {
    Some(path) => {
      @os_fs.write_string_to_file(path, result) catch {
        e => abort("normalize --merge: " + e.to_string())
      }
      println("normalize --merge: written to \{path}")
    }
    None => println(result)
  }
}

///|
fn fmt_cmd(args : Array[String]) -> Unit {
  let options = match parse_fmt_cmd_options(args) {
    Ok(v) => v
    Err(msg) => abort(msg)
  }
  for path in options.files {
    let resolved = @loader.resolve_entry_path(path)
    let source = @os_fs.read_file_to_string(resolved) catch {
      e => abort("fmt: " + e.to_string())
    }
    let formatted = match normalize_format_file_source(resolved) {
      Ok(v) => v
      Err(err) => abort("fmt: " + err)
    }
    let output = apply_lock_annotations_for_format(resolved, formatted)
    if options.dry_run {
      let diff = render_fmt_dry_run_diff(path, source, output)
      if diff.length() > 0 {
        println(diff)
      }
    } else {
      @os_fs.write_string_to_file(resolved, output) catch {
        e => abort("fmt: " + e.to_string())
      }
    }
  }
}

///|
fn apply_lock_annotations_for_format(path : String, source : String) -> String {
  let lock_path = @codebase.lock_file_path(path)
  let lock = match @codebase.load_lock_data(lock_path) {
    Ok(v) => v
    Err(err) => abort("fmt: " + err)
  }
  match @codebase.apply_annotations_to_source(path, source, lock.annotations) {
    Ok(v) => v
    Err(err) => abort("fmt: " + err)
  }
}

///|
extern "c" fn c_exit(code : Int) -> Unit = "exit"

///|
extern "c" fn vibe_getpid() -> Int = "getpid"

///|
extern "C" fn vibe_process_exists(pid : Int) -> Int = "vibe_process_exists"

///|
#borrow(cmd)
extern "c" fn c_system(cmd : Bytes) -> Int = "system"

///|
fn system_command_bytes(cmd : String) -> Bytes {
  let encoded = @utf8.encode(cmd[:])
  let n = encoded.length()
  Bytes::makei(n + 1, fn(i) { if i == n { b'\x00' } else { encoded[i] } })
}

///|
fn print_test_report(path : String, report : @runtime.TestReport) -> Bool {
  let status = if report.failed == 0 { "ok" } else { "fail" }
  println("\{path}: \{status} (\{report.passed}/\{report.total})")
  if report.failed > 0 {
    println("  failures:")
    for failure in report.failures {
      let name = match failure.name {
        Some(n) => n
        None => "<unnamed>"
      }
      println("  - " + name + ": " + failure.error)
    }
  }
  report.failed == 0
}

///|
fn print_cli_test_report(path : String, report : CliTestReport) -> Bool {
  let status = if report.failed == 0 { "ok" } else { "fail" }
  println("\{path}: \{status} (\{report.passed}/\{report.total})")
  if report.failed > 0 {
    println("  failures:")
    for failure in report.failures {
      let name = match failure.name {
        Some(n) => n
        None => "<unnamed>"
      }
      println("  - " + name + ": " + failure.error)
    }
  }
  report.failed == 0
}

///|
fn load_entry_db(
  entry_path : String,
) -> Result[(@runtime.VibeDb, String), String] {
  @loader.load_db(entry_path)
}

///|
fn compile_entry_with_db(
  db : @runtime.VibeDb,
  entry : String,
) -> Result[@runtime_compile.CompiledModule, String] {
  let compiled = @runtime_compile.compile_module(db, entry) catch {
    e => return Err(e.to_string())
  }
  Ok(compiled)
}

///|
fn clone_string_map(src : Map[String, String]) -> Map[String, String] {
  let out : Map[String, String] = {}
  for key, value in src {
    out[key] = value
  }
  out
}

///|
fn normalized_prelude_object() -> (String, String) {
  let prelude_ast = @checker.prelude_ast()
  let bundle = @vibe_core.normalize_with_imports(prelude_ast, fn(_import_path) {
    None
  })
  let prelude_hash = bundle.main_hash
  let prelude_module = match bundle.modules.get(prelude_hash) {
    Some(m) => m
    None => @vibe_core.normalize_module(prelude_ast)
  }
  let prelude_json = @vibe_core.serialize_module(prelude_module)
  (prelude_hash, prelude_json)
}

///|
fn sync_prelude_to_codebase(
  entry : String,
  lock : @codebase.LockData,
) -> @codebase.LockData {
  let (prelude_hash, prelude_json) = normalized_prelude_object()
  let vibe_dir = find_vibe_dir(entry)
  let codebase = @codebase.Codebase::new(vibe_dir)
  let _ = codebase.write_object(prelude_hash, prelude_json) catch {
    e => abort("fetch: sync prelude object: " + e.to_string())
  }
  let path_refs = clone_string_map(lock.path_refs)
  let version_refs = clone_string_map(lock.version_refs)
  version_refs["prelude"] = prelude_hash
  let symbol_refs = clone_string_map(lock.symbol_refs)
  symbol_refs["std/prelude"] = prelude_hash
  let module_refs = clone_string_map(lock.module_refs)
  let annotations = clone_string_map(lock.annotations)
  let next_lock = @codebase.LockData::new_with_meta(
    path_refs, version_refs, symbol_refs, module_refs, annotations,
  )
  let lock_path = @codebase.lock_file_path(entry)
  match @codebase.write_lock_data(lock_path, next_lock) {
    Ok(_) => ()
    Err(err) => abort("fetch: sync prelude lock: " + err)
  }
  next_lock
}

///|
fn fetch_cmd(args : Array[String]) -> Unit {
  if args.length() != 1 {
    abort("fetch: expected <file>")
  }
  let entry = @loader.resolve_entry_path(args[0])
  let lock_path = @codebase.lock_file_path(entry)
  let path_locked = match @codebase.update_lock_path_refs(entry) {
    Ok(lock) => lock
    Err(err) => abort("fetch: " + err)
  }
  let updated_lock = sync_prelude_to_codebase(entry, path_locked)
  println(
    "updated lock refs: " +
    lock_path +
    " (" +
    updated_lock.path_refs.length().to_string() +
    " path refs)",
  )
}

///|
fn apply_cmd(args : Array[String]) -> Unit {
  if args.length() != 1 {
    abort("apply: expected <file>")
  }
  match resolve_entry_artifacts(args[0]) {
    Err(err) => abort("apply: " + err)
    Ok((_, entry, lock, index, graph_head)) => {
      let lock_path = @codebase.lock_file_path(entry)
      let index_root = @codebase.resolve_index_root(entry)
      println(
        "applied: " +
        entry +
        " lock=" +
        lock_path +
        " path_refs=" +
        lock.path_refs.length().to_string() +
        " graph_head=" +
        short_hash(graph_head) +
        " defs=" +
        index.defs.length().to_string() +
        " cache=" +
        index_root +
        "/.vibe/cache.json",
      )
    }
  }
}

///|
struct SymbolsCmdOptions {
  entry_path : String
  output_json : Bool
} derive(Show, Eq)

///|
struct SymbolsRow {
  status : String
  origin : String
  kind : String
  name : String
  path : String
  def_id : String
  signature : String
  module_hash : String
} derive(Show, Eq)

///|
fn parse_symbols_cmd_args(
  args : Array[String],
) -> Result[SymbolsCmdOptions, String] {
  let mut output_json = false
  let positional : Array[String] = []
  for arg in args {
    if arg == "--json" {
      output_json = true
      continue
    }
    if arg.has_prefix("--") {
      return Err("symbols: unknown option " + arg)
    }
    positional.push(arg)
  }
  if positional.length() != 1 {
    return Err("symbols: expected [--json] <file>")
  }
  Ok({ entry_path: positional[0], output_json })
}

///|
fn symbols_row_to_json(row : SymbolsRow) -> Json {
  let obj : Map[String, Json] = {}
  obj["status"] = Json::string(row.status)
  obj["origin"] = Json::string(row.origin)
  obj["kind"] = Json::string(row.kind)
  obj["name"] = Json::string(row.name)
  obj["path"] = Json::string(row.path)
  obj["hash"] = Json::string(row.def_id)
  obj["short_hash"] = Json::string(short_hash(row.def_id))
  obj["signature"] = Json::string(row.signature)
  obj["module_hash"] = Json::string(row.module_hash)
  Json::object(obj)
}

///|
fn symbols_rows_to_lines(rows : Array[SymbolsRow]) -> Array[String] {
  let lines : Array[String] = []
  for row in rows {
    lines.push(
      row.status +
      "\t" +
      row.origin +
      "\t" +
      row.kind +
      "\t" +
      row.name +
      "\t" +
      row.path +
      "#" +
      short_hash(row.def_id),
    )
  }
  lines.sort()
  lines
}

///|
fn symbols_lock_has_managed_ref(
  module_refs : Map[String, String],
  path : String,
  name : String,
  index_root : String,
  registry_modules : Map[String, String],
  root_version : String,
) -> Bool {
  let canonical_symbol_with_context = @codebase.lock_module_ref_canonical_symbol_with_context(
    path, name, index_root, registry_modules, root_version,
  )
  if module_refs.contains(canonical_symbol_with_context) {
    return true
  }
  let context_prefix = canonical_symbol_with_context + "#"
  for key, _ in module_refs {
    if key.has_prefix(context_prefix) {
      return true
    }
  }
  false
}

///|
fn collect_symbols_rows(
  entry_path : String,
) -> Result[Array[SymbolsRow], String] {
  let resolved = @loader.resolve_entry_path(entry_path)
  let (_db, _entry, lock, index, _graph_head) = match
    resolve_entry_artifacts(resolved) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let index_root = @codebase.resolve_index_root(resolved)
  let registry_modules = match @codebase.load_registry_modules(index_root) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let root_version = match @codebase.load_registry_root_version(index_root) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let scratch_candidates = match
    load_scratch_write_file_candidates(index_root) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let index_defs : Array[WriteFileDef] = []
  for _, def in index.defs {
    index_defs.push(write_file_def_from_index_def(def))
  }
  let scratch_names : Map[String, Bool] = {}
  for candidate in scratch_candidates {
    scratch_names[candidate.def.name] = true
  }
  let index_names : Map[String, Bool] = {}
  for def in index_defs {
    index_names[def.name] = true
  }
  let rows : Array[SymbolsRow] = []
  for def in index_defs {
    let managed = symbols_lock_has_managed_ref(
      lock.module_refs,
      def.path,
      def.name,
      index_root,
      registry_modules,
      root_version,
    )
    let mut has_conflicting_scratch = false
    if scratch_names.contains(def.name) {
      for candidate in scratch_candidates {
        if candidate.def.name != def.name {
          continue
        }
        if not(symbols_defs_equivalent(def, candidate.def)) {
          has_conflicting_scratch = true
          break
        }
      }
    }
    let status = if has_conflicting_scratch {
      "shadowed"
    } else if managed {
      "managed"
    } else {
      "scratch-only"
    }
    rows.push({
      status,
      origin: "index",
      kind: def.kind,
      name: def.name,
      path: def.path,
      def_id: def.def_id,
      signature: def.signature,
      module_hash: def.module_hash,
    })
  }
  for candidate in scratch_candidates {
    let mut has_equivalent_index = false
    if index_names.contains(candidate.def.name) {
      for def in index_defs {
        if def.name != candidate.def.name {
          continue
        }
        if symbols_defs_equivalent(def, candidate.def) {
          has_equivalent_index = true
          break
        }
      }
    }
    if has_equivalent_index {
      continue
    }
    let status = if index_names.contains(candidate.def.name) {
      "shadowed"
    } else {
      "scratch-only"
    }
    rows.push({
      status,
      origin: candidate.origin,
      kind: candidate.def.kind,
      name: candidate.def.name,
      path: candidate.def.path,
      def_id: candidate.def.def_id,
      signature: candidate.def.signature,
      module_hash: candidate.def.module_hash,
    })
  }
  Ok(rows)
}

///|
fn symbols_defs_equivalent(a : WriteFileDef, b : WriteFileDef) -> Bool {
  a.name == b.name &&
  a.kind == b.kind &&
  a.signature == b.signature &&
  a.module_hash == b.module_hash
}

///|
fn symbols_cmd(args : Array[String]) -> Unit {
  let options = match parse_symbols_cmd_args(args) {
    Ok(v) => v
    Err(err) => abort(err)
  }
  let rows = match collect_symbols_rows(options.entry_path) {
    Ok(v) => v
    Err(err) => abort("symbols: " + err)
  }
  if options.output_json {
    let arr : Array[Json] = []
    for row in rows {
      arr.push(symbols_row_to_json(row))
    }
    println(Json::array(arr).stringify())
    return
  }
  let lines = symbols_rows_to_lines(rows)
  for line in lines {
    println(line)
  }
  println("symbols: " + rows.length().to_string() + " entries")
}

///|
fn resolve_project_root_path(path : String) -> String {
  if path.has_prefix("/") {
    @vibe_fs.normalize_path(path)
  } else {
    @vibe_fs.normalize_path(@io.current_dir_or_root() + "/" + path)
  }
}

///|
fn is_scaffold_seed_vibe_root(vibe_root : String) -> Bool {
  let prelude_dir = @vibe_fs.normalize_path(vibe_root + "/prelude")
  let json_dir = @vibe_fs.normalize_path(vibe_root + "/json")
  let base64_dir = @vibe_fs.normalize_path(vibe_root + "/base64")
  let sha1_dir = @vibe_fs.normalize_path(vibe_root + "/sha1")
  let has_prelude = @os_fs.path_exists(prelude_dir)
  let string_mod = @vibe_fs.normalize_path(prelude_dir + "/string.vibe")
  let json_mod = @vibe_fs.normalize_path(json_dir + "/json.vibe")
  let base64_mod = @vibe_fs.normalize_path(base64_dir + "/base64.vibe")
  let sha1_mod = @vibe_fs.normalize_path(sha1_dir + "/sha1.vibe")
  if not(has_prelude) {
    return false
  }
  let prelude_is_dir = @os_fs.is_dir(prelude_dir) catch { _ => false }
  if not(prelude_is_dir) {
    return false
  }
  let json_is_dir = @os_fs.is_dir(json_dir) catch { _ => false }
  let base64_is_dir = @os_fs.is_dir(base64_dir) catch { _ => false }
  let sha1_is_dir = @os_fs.is_dir(sha1_dir) catch { _ => false }
  if not(json_is_dir) || not(base64_is_dir) || not(sha1_is_dir) {
    return false
  }
  @os_fs.path_exists(string_mod) &&
  @os_fs.path_exists(json_mod) &&
  @os_fs.path_exists(base64_mod) &&
  @os_fs.path_exists(sha1_mod)
}

///|
fn resolve_scaffold_seed_vibe_root_from(start : String) -> String? {
  let mut current = resolve_project_root_path(start)
  while true {
    let candidate = @vibe_fs.normalize_path(current + "/vibe")
    if is_scaffold_seed_vibe_root(candidate) {
      return Some(candidate)
    }
    let parent = @vibe_fs.parent_path(current)
    if parent == current || parent.length() == 0 {
      return None
    }
    current = parent
  }
  None
}

///|
fn resolve_scaffold_seed_vibe_root() -> String? {
  resolve_scaffold_seed_vibe_root_from(@io.current_dir_or_root())
}

///|
fn ensure_dir_recursive(path : String) -> Unit {
  if @os_fs.path_exists(path) {
    let is_dir = @os_fs.is_dir(path) catch { _ => false }
    if not(is_dir) {
      abort("init: path exists and is not directory: " + path)
    }
    return
  }
  let parent = @vibe_fs.parent_path(path)
  if parent != path && parent.length() > 0 {
    ensure_dir_recursive(parent)
  }
  @os_fs.create_dir(path) catch {
    e =>
      if not(@os_fs.path_exists(path)) {
        abort("init: mkdir failed: " + path + " (" + e.to_string() + ")")
      }
  }
}

///|
fn write_file_if_missing(path : String, content : String) -> Bool {
  if @os_fs.path_exists(path) {
    return false
  }
  @os_fs.write_string_to_file(path, content) catch {
    e => abort("init: write failed: " + path + " (" + e.to_string() + ")")
  }
  true
}

///|
fn copy_seed_tree_if_missing(src_dir : String, dest_dir : String) -> Bool {
  let src_norm = @vibe_fs.normalize_path(src_dir)
  let dest_norm = @vibe_fs.normalize_path(dest_dir)
  if src_norm == dest_norm {
    return false
  }
  if not(@os_fs.path_exists(src_norm)) {
    return false
  }
  let src_is_dir = @os_fs.is_dir(src_norm) catch { _ => false }
  if not(src_is_dir) {
    return false
  }
  let mut changed = false
  if @os_fs.path_exists(dest_norm) {
    let dest_is_dir = @os_fs.is_dir(dest_norm) catch { _ => false }
    if not(dest_is_dir) {
      abort("init: seed target exists and is not directory: " + dest_norm)
    }
  } else {
    ensure_dir_recursive(dest_norm)
    changed = true
  }
  let entries = @os_fs.read_dir(src_norm) catch {
    e =>
      abort("init: read dir failed: " + src_norm + " (" + e.to_string() + ")")
  }
  for entry in entries {
    if entry == "." || entry == ".." {
      continue
    }
    let src_path = @vibe_fs.normalize_path(src_norm + "/" + entry)
    let dest_path = @vibe_fs.normalize_path(dest_norm + "/" + entry)
    let child_is_dir = @os_fs.is_dir(src_path) catch { _ => false }
    if child_is_dir {
      if copy_seed_tree_if_missing(src_path, dest_path) {
        changed = true
      }
    } else if not(@os_fs.path_exists(dest_path)) {
      let content = match @io.read_string(src_path) {
        Ok(v) => v
        Err(err) => abort("init: read failed: " + src_path + " (" + err + ")")
      }
      @os_fs.write_string_to_file(dest_path, content) catch {
        e =>
          abort("init: write failed: " + dest_path + " (" + e.to_string() + ")")
      }
      changed = true
    }
  }
  changed
}

///|
fn scaffold_project_root_with_seed(
  root : String,
  with_main : Bool,
  seed_vibe_root : String?,
) -> Array[String] {
  ensure_dir_recursive(root)
  let created : Array[String] = []
  let index_source = "export let version = \"0.1.0\"\n"
  let lock_source = "{\"path\":{},\"version\":{},\"symbol\":{},\"module\":{},\"annotation\":{}}\n"
  if write_file_if_missing(root + "/index.vibe", index_source) {
    created.push("index.vibe")
  }
  if write_file_if_missing(root + "/index.lock", lock_source) {
    created.push("index.lock")
  }
  let vibe_dir = root + "/.vibe"
  if not(@os_fs.path_exists(vibe_dir)) {
    ensure_dir_recursive(vibe_dir)
    created.push(".vibe/")
  }
  match seed_vibe_root {
    Some(seed_root) => {
      let seed_norm = @vibe_fs.normalize_path(seed_root)
      if is_scaffold_seed_vibe_root(seed_norm) {
        if copy_seed_tree_if_missing(
            seed_norm + "/prelude",
            root + "/vibe/prelude",
          ) {
          created.push("vibe/prelude/")
        }
        if copy_seed_tree_if_missing(seed_norm + "/json", root + "/vibe/json") {
          created.push("vibe/json/")
        }
        if copy_seed_tree_if_missing(
            seed_norm + "/base64",
            root + "/vibe/base64",
          ) {
          created.push("vibe/base64/")
        }
        if copy_seed_tree_if_missing(seed_norm + "/sha1", root + "/vibe/sha1") {
          created.push("vibe/sha1/")
        }
      }
    }
    None => ()
  }
  if with_main {
    let main_source = "let main = 1\nexport { main }\n"
    if write_file_if_missing(root + "/main.vibe", main_source) {
      created.push("main.vibe")
    }
  }
  created
}

///|
fn scaffold_project_root(root : String, with_main : Bool) -> Array[String] {
  scaffold_project_root_with_seed(
    root,
    with_main,
    resolve_scaffold_seed_vibe_root(),
  )
}

///|
fn init_cmd(args : Array[String]) -> Unit {
  if args.length() > 1 {
    abort("init: expected [dir]")
  }
  let target = if args.length() == 0 {
    @io.current_dir_or_root()
  } else {
    args[0]
  }
  let root = resolve_project_root_path(target)
  let created = scaffold_project_root(root, false)
  println("initialized: " + root + " created=" + created.to_string())
}

///|
fn new_cmd(args : Array[String]) -> Unit {
  if args.length() != 1 {
    abort("new: expected <dir>")
  }
  let root = resolve_project_root_path(args[0])
  if @os_fs.path_exists(root) {
    abort("new: target already exists: " + root)
  }
  let created = scaffold_project_root(root, true)
  println("created: " + root + " files=" + created.to_string())
}

///|
fn history_cmd(args : Array[String]) -> Unit {
  if args.length() == 0 {
    abort("history: expected subcommand (reset)")
  }
  let sub = args[0]
  match sub {
    "reset" => {
      let mut hard = false
      let mut i = 1
      while i < args.length() {
        let arg = args[i]
        match arg {
          "--hard" => hard = true
          _ => abort("history reset: unknown arg " + arg)
        }
        i += 1
      }
      let (namespace_name, scratch_db_path) = match resolve_scratch_db_path() {
        Ok(v) => v
        Err(err) => abort("history reset: " + err)
      }
      let mut removed = false
      if @os_fs.path_exists(scratch_db_path) {
        @os_fs.remove_file(scratch_db_path) catch {
          e =>
            abort("history reset: remove scratch db failed: " + e.to_string())
        }
        removed = true
      }
      if hard {
        let index_root = current_workspace_index_root()
        let cache = load_vibe_cache_object(index_root)
        let next_cache = clone_json_map(cache)
        let namespaces = match cache.get("namespaces") {
          Some(Json::Object(current)) => clone_json_map(current)
          _ => {}
        }
        let ns_obj = match namespaces.get(namespace_name) {
          Some(Json::Object(current)) => clone_json_map(current)
          _ => {}
        }
        ns_obj["head"] = Json::string("")
        ns_obj["history_head"] = Json::string("")
        ns_obj["updated_at"] = Json::string(@env.now().to_string())
        namespaces[namespace_name] = Json::object(ns_obj)
        next_cache["active_namespace"] = Json::string(namespace_name)
        next_cache["namespaces"] = Json::object(namespaces)
        match write_vibe_cache_object(index_root, next_cache) {
          Ok(_) => ()
          Err(err) => abort("history reset: " + err)
        }
      }
      println(
        "history reset: namespace=" +
        namespace_name +
        " db=" +
        scratch_db_path +
        " removed=" +
        removed.to_string() +
        " hard=" +
        hard.to_string(),
      )
    }
    _ => abort("history: unknown subcommand: " + sub)
  }
}

///|
fn clamp_source_offset(source : String, offset : Int) -> Int {
  if offset < 0 {
    0
  } else if offset > source.length() {
    source.length()
  } else {
    offset
  }
}

///|
fn source_slice_by_span(source : String, start : Int, end : Int) -> String {
  let s = clamp_source_offset(source, start)
  let e = clamp_source_offset(source, end)
  let stop = if e < s { s } else { e }
  if stop <= s {
    return ""
  }
  try source[s:stop] catch {
    _ => ""
  } noraise {
    value => value.to_string()
  }
}

///|
fn hash_cmd(args : Array[String]) -> Unit {
  if args.length() != 1 {
    abort("hash: expected <file>")
  }
  let path = @loader.resolve_entry_path(args[0])
  let source = @os_fs.read_file_to_string(path) catch {
    e => abort("hash: " + e.to_string())
  }
  let ast = @parser.parse_ast(source) catch {
    e => abort("hash: " + e.diagnostic().render(args[0], source))
  }
  let hash = @vibe_core.hash_module(ast)
  println(hash)
}

///|
fn save_cmd(args : Array[String]) -> Unit {
  let mut use_git = false
  let files : Array[String] = []
  for arg in args {
    match arg {
      "--git" => use_git = true
      _ => files.push(arg)
    }
  }
  if files.length() != 1 {
    abort("save: expected <file>")
  }
  let file_arg = files[0]
  let path = @loader.resolve_entry_path(file_arg)
  let base_dir = @vibe_fs.parent_path(path)
  let source = @os_fs.read_file_to_string(path) catch {
    e => abort("save: " + e.to_string())
  }
  let ast = @parser.parse_ast(source) catch {
    e => abort("save: " + e.diagnostic().render(file_arg, source))
  }
  // Build import resolver
  let resolve_import = fn(import_path : String) -> @vibe_core.Module? {
    let resolved = if import_path.has_prefix("/") {
      import_path
    } else {
      @vibe_fs.normalize_path(base_dir + "/" + import_path)
    }
    let import_source = @os_fs.read_file_to_string(resolved) catch {
      _ => return None
    }
    let parsed = @parser.parse_ast(import_source) catch { _ => return None }
    Some(parsed)
  }
  // Normalize with all imports resolved to hashes
  let bundle = @vibe_core.normalize_with_imports(ast, resolve_import)
  // Save all modules in the bundle
  let mut saved_count = 0
  for hash, normalized in bundle.modules {
    let json = @vibe_core.serialize_module(normalized)
    if use_git {
      save_module_to_git(json, hash)
    } else {
      save_module_to_vibe(path, json, hash)
    }
    saved_count += 1
  }
  // Update paths.json for the main module
  if not(use_git) {
    let base_dir = find_vibe_dir(path)
    let codebase = @codebase.Codebase::new(base_dir)
    let _ = codebase.upsert_path_mapping(file_arg, bundle.main_hash) catch {
      e => abort("save: update paths: " + e.to_string())
    }
  }
  // Print result
  let main_short = @vibe_core.short_hash(bundle.main_hash)
  println("saved: \{file_arg} -> \{main_short} (\{saved_count} module(s))")
}

///|
fn save_module_to_vibe(
  base_path : String,
  json : String,
  hash : String,
) -> Unit {
  let base_dir = find_vibe_dir(base_path)
  let codebase = @codebase.Codebase::new(base_dir)
  let _ = codebase.write_object(hash, json) catch {
    e => abort("save: " + e.to_string())
  }
}

///|
fn save_module_to_git(json : String, hash : String) -> Unit {
  let git_dir = find_git_dir()
  let fs = @osfs.OsFs::new()
  let (blob_id, blob_compressed) = @bit.create_blob_string(json)
  let _ = blob_id // The hash is computed from normalized content
  let obj_id = @bit.ObjectId::from_hex(hash) catch {
    e => abort("save: invalid hash: " + e.to_string())
  }
  @gitlib.write_object_bytes(fs, git_dir, obj_id, blob_compressed) catch {
    e => abort("save: git write: " + e.to_string())
  }
}

///|
fn find_git_dir() -> String {
  // Walk up from current directory to find .git
  let mut dir = "."
  for _ in 0..<20 {
    let git_path = dir + "/.git"
    if @os_fs.path_exists(git_path) {
      return git_path
    }
    dir = dir + "/.."
  }
  abort("save --git: .git directory not found")
}

///|
fn find_vibe_dir(path : String) -> String {
  // Resolve storage root from lock/index hierarchy and keep .vibe aggregated there.
  let normalized = if path.has_prefix("/") {
    @vibe_fs.normalize_path(path)
  } else {
    @vibe_fs.normalize_path(@io.current_dir_or_root() + "/" + path)
  }
  let vibe_dir = @codebase.vibe_dir_path(normalized)
  if @os_fs.path_exists(vibe_dir) {
    return vibe_dir
  }
  // Create .vibe directory at the resolved root.
  @os_fs.create_dir(vibe_dir) catch {
    e =>
      abort(
        "save: cannot create .vibe directory at " +
        vibe_dir +
        ": " +
        e.to_string(),
      )
  }
  vibe_dir
}

///|
/// expand <hash|path> [--depth N] [--json] [--source]
/// Expand a module from storage with its dependencies
fn expand_cmd(args : Array[String]) -> Unit {
  if args.length() == 0 {
    println("usage: vibe expand <hash|path> [--depth N] [--json] [--source]")
    return
  }
  let mut target = ""
  let mut depth : Int? = None
  let mut output_json = false
  let mut output_source = false
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if arg == "--depth" || arg == "-d" {
      i += 1
      if i < args.length() {
        depth = Some(@strconv.parse_int(args[i]) catch { _ => 0 })
      }
    } else if arg == "--json" {
      output_json = true
    } else if arg == "--source" {
      output_source = true
    } else if target == "" {
      target = arg
    }
    i += 1
  }
  if target == "" {
    abort("expand: no target specified")
  }
  // Default to source output if nothing specified
  if not(output_json) && not(output_source) {
    output_source = true
  }
  // Find .vibe directory from target path
  let base_dir = if is_hash_like(target) {
    "."
  } else {
    // Get parent directory of target file
    let last_slash = find_last_slash(target)
    if last_slash > 0 {
      target_substring(target, 0, last_slash)
    } else {
      "."
    }
  }
  let vibe_dir = find_vibe_dir_from(base_dir)
  let codebase = @codebase.Codebase::new(vibe_dir)
  // Resolve target to hash
  let main_hash = resolve_target_to_hash(target, codebase)
  let load_module = fn(hash : String) -> @vibe_core.Module? {
    let json = match codebase.read_object(hash) {
      Some(v) => v
      None => return None
    }
    let m = @vibe_core.deserialize_module(json) catch { _ => return None }
    Some(m)
  }
  // Expand the module
  let bundle = @vibe_core.expand_module(main_hash, load_module, depth)
  // Output results
  if output_json {
    println("{")
    println("  \"main_hash\": \"" + bundle.main_hash + "\",")
    println("  \"order\": [")
    for i, hash in bundle.order {
      let comma = if i < bundle.order.length() - 1 { "," } else { "" }
      println("    \"" + hash + "\"" + comma)
    }
    println("  ],")
    println("  \"modules\": {")
    let mut count = 0
    let total = bundle.modules.length()
    for hash, m in bundle.modules {
      count += 1
      let comma = if count < total { "," } else { "" }
      println("    \"" + hash + "\": " + @vibe_core.serialize_module(m) + comma)
    }
    println("  }")
    println("}")
  }
  if output_source {
    println("// Expanded from: " + main_hash)
    let depth_str = match depth {
      None => "unlimited"
      Some(d) => d.to_string()
    }
    println("// Depth: " + depth_str)
    println("// Modules: " + bundle.modules.length().to_string())
    println("")
    // Print modules in topological order (dependencies first)
    for hash in bundle.order {
      match bundle.modules.get(hash) {
        None => ()
        Some(m) => {
          let short = @vibe_core.short_hash(hash)
          println("// --- Module: " + short + " ---")
          // Use JSON format for now since format_ast is not available
          let json = @vibe_core.serialize_module(m)
          println(json)
          println("")
        }
      }
    }
  }
}

///|
fn resolve_scratch_db_path() -> Result[(String, String), String] {
  resolve_scratch_db_path_for_index_root(current_workspace_index_root())
}

///|
fn resolve_target_to_hash(
  target : String,
  codebase : @codebase.Codebase,
) -> String {
  // If it looks like a hash (40 hex chars or prefix), use it directly
  if is_hash_like(target) {
    return resolve_hash_prefix(target, codebase.root())
  }
  // Otherwise, try to look up as a path in paths.json
  match codebase.resolve_path_mapping(target) {
    Some(hash) => hash
    None => abort("expand: cannot resolve target: " + target)
  }
}

///|
fn is_hash_like(s : String) -> Bool {
  if s.length() < 4 || s.length() > 40 {
    return false
  }
  for c in s {
    if not((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
      return false
    }
  }
  true
}

///|
fn resolve_hash_prefix(prefix : String, vibe_dir : String) -> String {
  if prefix.length() == 40 {
    return prefix
  }
  // Search for matching hash in objects directory
  let objects_dir = vibe_dir + "/objects"
  if prefix.length() >= 2 {
    let prefix_head = prefix_first_two(prefix)
    let subdir = objects_dir + "/" + prefix_head
    if @os_fs.path_exists(subdir) {
      let entries = @os_fs.read_dir(subdir) catch { _ => return prefix }
      for entry in entries {
        let full_hash = prefix_head + entry
        if full_hash.has_prefix(prefix) {
          return full_hash
        }
      }
    }
  }
  prefix
}

///|
fn prefix_first_two(s : String) -> String {
  let buf = StringBuilder::new()
  for i, c in s {
    if i >= 2 {
      break
    }
    buf.write_char(c)
  }
  buf.to_string()
}

///|
fn find_last_slash(s : String) -> Int {
  let mut last = -1
  for i, c in s {
    if c == '/' {
      last = i
    }
  }
  last
}

///|
fn target_substring(s : String, start : Int, end : Int) -> String {
  let buf = StringBuilder::new()
  for i, c in s {
    if i >= start && i < end {
      buf.write_char(c)
    }
  }
  buf.to_string()
}

///|
fn find_vibe_dir_from(start : String) -> String {
  let base = if start == "" { "." } else { start }
  let normalized_base = if base.has_prefix("/") {
    @vibe_fs.normalize_path(base)
  } else {
    @vibe_fs.normalize_path(@io.current_dir_or_root() + "/" + base)
  }
  let probe = @vibe_fs.normalize_path(normalized_base + "/__probe__.vibe")
  let lock_scoped_vibe = @codebase.vibe_dir_path(probe)
  if @os_fs.path_exists(lock_scoped_vibe) {
    return lock_scoped_vibe
  }
  // Backward-compatible fallback: search nearest existing .vibe directory.
  let mut dir = normalized_base
  for _ in 0..<10 {
    let vibe_path = @vibe_fs.normalize_path(dir + "/.vibe")
    if @os_fs.path_exists(vibe_path) {
      return vibe_path
    }
    let parent = @vibe_fs.parent_path(dir)
    if parent == dir || parent.length() == 0 {
      break
    }
    dir = parent
  }
  abort("expand: .vibe directory not found (searched from: " + start + ")")
}

///|
/// `vibe build [--debug|--release] <file.vibe> [-o <out.wasm>]`
///
/// --debug:   linked build (pre-compile imports as library .wasm, cache in .vibe/debug/)
/// --release: monolithic build (default, same as `compile --wasm`)
fn build_cmd(args : Array[String]) -> Unit {
  let mut debug_mode = false
  let mut entry_path : String? = None
  let mut out_path : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--debug" => {
        debug_mode = true
        i += 1
      }
      "--release" => {
        debug_mode = false
        i += 1
      }
      "-o" | "--out" => {
        if i + 1 >= args.length() {
          abort("build: missing output path after " + arg)
        }
        out_path = Some(args[i + 1])
        i += 2
      }
      _ => {
        if entry_path is None {
          entry_path = Some(arg)
        } else {
          abort("build: too many input files")
        }
        i += 1
      }
    }
  }
  let entry = match entry_path {
    Some(p) => p
    None => abort("build: missing <file.vibe>")
  }
  if debug_mode {
    build_cmd_debug(entry, out_path)
  } else {
    build_cmd_release(entry, out_path)
  }
}

///|
fn build_cmd_release(entry : String, out_path : String?) -> Unit {
  let resolved_out = match out_path {
    Some(p) => p
    None => {
      let base = if entry.has_suffix(".vibe") {
        entry.unsafe_substring(start=0, end=entry.length() - 5)
      } else {
        entry
      }
      base + ".wasm"
    }
  }
  let (db, resolved_entry) = match @loader.load_db(entry) {
    Ok(v) => v
    Err(err) => abort("build: " + err)
  }
  // Try -Oz optimization; fall back to unoptimized if wite doesn't support
  // the generated opcodes (e.g., exceptions/try_table).
  let optimized : Result[Bytes, _] = try? @runtime_compile.compile_module_wasm_with_opt_level(
    db,
    resolved_entry,
    opt_level=Some("-Oz"),
  )
  let wasm_bytes = match optimized {
    Ok(bytes) => bytes
    Err(_) =>
      @runtime_compile.compile_module_wasm_with_opt_level(db, resolved_entry) catch {
        e => abort("build: " + e.user_message())
      }
  }
  @os_fs.write_bytes_to_file(resolved_out, wasm_bytes) catch {
    e => abort("build: write failed: " + e.to_string())
  }
  let size = wasm_bytes.length()
  println(
    "build --release: wrote " +
    resolved_out +
    " (" +
    size.to_string() +
    " bytes)",
  )
}

///|
fn build_cmd_debug(entry : String, out_path : String?) -> Unit {
  let resolved_out = match out_path {
    Some(p) => p
    None => {
      let base = if entry.has_suffix(".vibe") {
        entry.unsafe_substring(start=0, end=entry.length() - 5)
      } else {
        entry
      }
      base + ".wasm"
    }
  }
  // In debug linked mode, try fast path: load only user file (skip import I/O).
  let resolved_entry_for_parent = @loader.resolve_entry_path(entry)
  let parent = @vibe_fs.parent_path(resolved_entry_for_parent)
  // Hoist .vibe/debug cache to nearest parent .vibe directory.
  // Cache key = relative path from .vibe root to avoid collisions.
  let (vibe_root, cache_key) = find_vibe_cache_root(resolved_entry_for_parent)
  let cache_dir = vibe_root + "/debug/" + cache_key
  let imports_cache_path = cache_dir + "/linked_imports.txt"
  // Check cache validity: imports cache + library .wasm + source hashes
  let hash_cache_path = cache_dir + "/source_hashes.txt"
  let has_cache = if @os_fs.path_exists(imports_cache_path) {
    let cached_text = @os_fs.read_file_to_string(imports_cache_path) catch {
      _ => ""
    }
    let cached = parse_linked_imports_cache(cached_text)
    let module_names : Map[String, Bool] = {}
    let mut all_valid = cached.length() > 0
    // Check library .wasm files exist
    for li in cached {
      if not(module_names.contains(li.module_name)) {
        module_names[li.module_name] = true
        let lib_path = cache_dir + "/" + li.module_name + ".wasm"
        if not(@os_fs.path_exists(lib_path)) {
          all_valid = false
        }
      }
    }
    // Check source hashes haven't changed
    if all_valid && @os_fs.path_exists(hash_cache_path) {
      let hash_text = @os_fs.read_file_to_string(hash_cache_path) catch {
        _ => ""
      }
      let saved_hashes = parse_source_hash_cache(hash_text)
      for path, saved_hash in saved_hashes {
        let current_source = @os_fs.read_file_to_string(path) catch { _ => "" }
        if current_source.length() > 0 {
          let current_hash = @vibe_core.content_address_hash_string(
            current_source,
          )
          if current_hash != saved_hash {
            all_valid = false
          }
        }
      }
    }
    all_valid
  } else {
    false
  }
  let (wasm_bytes, linked_imports) = if has_cache {
    // Fast path: read cached linked imports, compile user file only
    let resolved = @loader.resolve_entry_path(entry)
    let source = @os_fs.read_file_to_string(resolved) catch {
      e => abort("build: " + e.to_string())
    }
    let db = @runtime.VibeDb::new()
    db.set_source(resolved, source)
    // Parse cached linked imports
    let cached_text = @os_fs.read_file_to_string(imports_cache_path) catch {
      _ => ""
    }
    let cached_imports = parse_linked_imports_cache(cached_text)
    let codegen_linked : Array[(String, String, Int, Int)] = []
    for li in cached_imports {
      codegen_linked.push(
        (li.module_name, li.func_name, li.param_count, li.return_count),
      )
    }
    // Parse + desugar + codegen (no import resolution, no typecheck)
    let raw_ast = @parser.parse_ast(source) catch {
      e => abort("build --debug: parse error: " + e.to_string())
    }
    let desugared = @frontend.desugar_method_calls(raw_ast, {})
    let ast = @frontend.rewrite_effect_handles(desugared)
    // Resolve type definitions from entry's ReExport chains (standalone, no db)
    let extra_type_stmts = collect_reexport_type_stmts_standalone(
      resolved, raw_ast,
    )
    let (bundled, _) = @runtime.bundle_for_wasm_linked_with_imports(
      ast,
      cached_imports,
      extra_type_stmts~,
    )
    let maybe_wasm = Some(
      @runtime_compile.emit_wasm_with_linked_imports(bundled, codegen_linked),
    ) catch {
      _ => None
    }
    match maybe_wasm {
      Some(wasm) => (wasm, cached_imports)
      None => {
        // Some deps are intentionally inlined for linked debug builds
        // (e.g. preload-unsafe WASI users). The cache fast path only stores
        // linked imports, so it cannot always reconstruct those inlined defs.
        // Fall back to the full path instead of failing the cached build.
        let (db, resolved_entry) = match @loader.load_db(entry) {
          Ok(v) => v
          Err(err) => abort("build: " + err)
        }
        let (wasm, imports) = @runtime_compile.compile_module_wasm_linked(
          db,
          resolved_entry,
          debug_errors=true,
        ) catch {
          e => abort("build --debug: " + e.user_message())
        }
        let cache_text = serialize_linked_imports_cache(imports)
        @os_fs.write_string_to_file(imports_cache_path, cache_text) catch {
          _ => ()
        }
        (wasm, imports)
      }
    }
  } else {
    // First time: full load for library compilation
    let (db, resolved_entry) = match @loader.load_db(entry) {
      Ok(v) => v
      Err(err) => abort("build: " + err)
    }
    let (wasm, imports) = @runtime_compile.compile_module_wasm_linked(
      db,
      resolved_entry,
      debug_errors=true,
    ) catch {
      e => abort("build --debug: " + e.user_message())
    }
    // Save linked imports cache
    if not(@os_fs.path_exists(cache_dir)) {
      let _ = c_system(
        system_command_bytes("mkdir -p " + shell_quote_command_arg(cache_dir)),
      )
    }
    let cache_text = serialize_linked_imports_cache(imports)
    @os_fs.write_string_to_file(imports_cache_path, cache_text) catch {
      _ => ()
    }
    // Compile library modules and save source hashes
    save_library_modules(db, resolved_entry, imports, cache_dir)
    save_source_hashes(db, resolved_entry, cache_dir, hash_cache_path)
    (wasm, imports)
  }
  @os_fs.write_bytes_to_file(resolved_out, wasm_bytes) catch {
    e => abort("build: write failed: " + e.to_string())
  }
  // Print preload instructions
  println("build --debug: wrote " + resolved_out)
  let preload_parts : Array[String] = []
  let module_names : Map[String, Bool] = {}
  for li in linked_imports {
    if not(module_names.contains(li.module_name)) {
      module_names[li.module_name] = true
      let lib_path = cache_dir + "/" + li.module_name + ".wasm"
      preload_parts.push("--preload " + li.module_name + "=" + lib_path)
    }
  }
  if preload_parts.length() > 0 {
    let preload_str = preload_parts
      .iter()
      .fold(init="", fn(acc, s) {
        if acc.length() > 0 {
          acc + " " + s
        } else {
          s
        }
      })
    println("  run: wasmtime " + preload_str + " " + resolved_out)
  }
}

///|
fn save_library_modules(
  db : @runtime.VibeDb,
  entry : String,
  imports : Array[@runtime.LinkedImport],
  cache_dir : String,
) -> Unit {
  let module_names : Map[String, Bool] = {}
  for li in imports {
    module_names[li.module_name] = true
  }
  if module_names.contains(@runtime.prelude_core_module_name()) {
    let mod_name = @runtime.prelude_core_module_name()
    let lib_wasm_path = cache_dir + "/" + mod_name + ".wasm"
    let maybe_lib_bytes = Some(
      @runtime_compile.emit_library_module_wasm(
        @runtime.prelude_core_library_module(),
        debug_errors=true,
      ),
    ) catch {
      e => {
        println(
          "build --debug: warning: library compile failed for " +
          mod_name +
          ": " +
          e.user_message(),
        )
        None
      }
    }
    match maybe_lib_bytes {
      Some(lib_bytes) =>
        @os_fs.write_bytes_to_file(lib_wasm_path, lib_bytes) catch {
          e =>
            println(
              "build --debug: warning: write failed for " +
              mod_name +
              ": " +
              e.to_string(),
            )
        }
      None => ()
    }
  }
  let db_imports = db.imports(entry)
  for imp in db_imports {
    let mod_name = @runtime.linked_module_name(imp.path)
    if not(module_names.contains(mod_name)) {
      continue
    }
    let lib_wasm_path = cache_dir + "/" + mod_name + ".wasm"
    let lib_bytes = @runtime_compile.compile_module_wasm_with_opt_level(
      db,
      imp.path,
      no_dce=true,
      library_mode=true,
      debug_errors=true,
    ) catch {
      e => {
        println(
          "build --debug: warning: library compile failed for " +
          mod_name +
          ": " +
          e.user_message(),
        )
        continue
      }
    }
    @os_fs.write_bytes_to_file(lib_wasm_path, lib_bytes) catch {
      e => {
        println(
          "build --debug: warning: write failed for " +
          mod_name +
          ": " +
          e.to_string(),
        )
        continue
      }
    }
  }
}

///|
/// Collect type definitions (enum, type alias, struct) from ReExport chains
/// by reading and parsing source files directly (no VibeDb needed).
fn collect_reexport_type_stmts_standalone(
  entry_path : String,
  ast : @vibe_core.Module,
) -> Array[@vibe_core.Stmt] {
  let result : Array[@vibe_core.Stmt] = []
  let found : Map[String, Bool] = {}
  for stmt in ast.stmts {
    match stmt {
      @vibe_core.Stmt::ReExport(spec~, source~, ..) => {
        let wanted : Map[String, Bool] = {}
        for item in spec.items {
          wanted[item.name] = true
        }
        collect_reexport_types_recursive(
          entry_path, source, wanted, result, found, 0,
        )
      }
      _ => ()
    }
  }
  result
}

///|
fn collect_reexport_types_recursive(
  referrer_path : String,
  source : @vibe_core.ModuleRef,
  wanted : Map[String, Bool],
  result : Array[@vibe_core.Stmt],
  found : Map[String, Bool],
  depth : Int,
) -> Unit {
  if depth > 10 {
    return
  }
  let base_dir = @vibe_fs.parent_path(referrer_path)
  let source_path = match source {
    @vibe_core.ModuleRef::Path(path~) =>
      @loader.resolve_entry_path(
        if path.has_prefix("/") {
          path
        } else {
          base_dir + "/" + path
        },
      )
    @vibe_core.ModuleRef::PinnedPath(path~, ..) =>
      @loader.resolve_entry_path(
        if path.has_prefix("/") {
          path
        } else {
          base_dir + "/" + path
        },
      )
    _ => return
  }
  let source_text = @os_fs.read_file_to_string(source_path) catch {
    _ => return
  }
  let source_ast = @parser.parse_ast(source_text) catch { _ => return }
  for stmt in source_ast.stmts {
    match stmt {
      @vibe_core.Stmt::ExportEnumDef(name~, params~, ctors~, span~) =>
        if wanted.contains(name) && not(found.contains(name)) {
          found[name] = true
          result.push(@vibe_core.Stmt::EnumDef(name~, params~, ctors~, span~))
        }
      @vibe_core.Stmt::ExportTypeAlias(name~, params~, target~, span~) =>
        if wanted.contains(name) && not(found.contains(name)) {
          found[name] = true
          result.push(
            @vibe_core.Stmt::TypeAlias(name~, params~, target~, span~),
          )
        }
      @vibe_core.Stmt::ExportStructDef(name~, params~, fields~, span~) =>
        if wanted.contains(name) && not(found.contains(name)) {
          found[name] = true
          result.push(
            @vibe_core.Stmt::StructDef(name~, params~, fields~, span~),
          )
        }
      @vibe_core.Stmt::ReExport(spec=inner_spec, source=inner_source, ..) => {
        let inner_wanted : Map[String, Bool] = {}
        for item in inner_spec.items {
          if wanted.contains(item.name) && not(found.contains(item.name)) {
            inner_wanted[item.name] = true
          }
        }
        if inner_wanted.size() > 0 {
          collect_reexport_types_recursive(
            source_path,
            inner_source,
            inner_wanted,
            result,
            found,
            depth + 1,
          )
        }
      }
      _ => ()
    }
  }
}

///|
fn serialize_linked_imports_cache(
  imports : Array[@runtime.LinkedImport],
) -> String {
  let buf = StringBuilder::new()
  for li in imports {
    buf.write_string(li.module_name)
    buf.write_char('\t')
    buf.write_string(li.func_name)
    buf.write_char('\t')
    buf.write_string(li.param_count.to_string())
    buf.write_char('\t')
    buf.write_string(li.return_count.to_string())
    buf.write_char('\n')
  }
  buf.to_string()
}

///|

///|
/// Spawn background `vibe build --debug` to create linked cache for next run.
/// Only spawns if no cache exists yet. The background process is fire-and-forget.

///|
/// Find the nearest parent .vibe directory for cache hoisting.
/// Returns (vibe_dir_path, cache_key) where cache_key is the relative path
/// from the .vibe parent to the entry file (slug-ified for directory name).
///
/// Example: entry = "/repo/vibe/wasm/wasm_runtime/foo.vibe"
///   - Found: /repo/vibe/.vibe
///   - vibe_dir = "/repo/vibe/.vibe"
///   - cache_key = "wasm_wasm_runtime_foo"
///
/// If no .vibe found, falls back to entry's parent directory.

///|
/// `vibe clean [path]` — remove debug linked build cache.
/// If path is given, clean cache for that file. Otherwise clean all debug cache.
fn clean_cmd(args : Array[String]) -> Unit {
  if args.length() > 0 {
    // Clean cache for specific file
    let entry = args[0]
    let resolved = @loader.resolve_entry_path(entry)
    let (vibe_root, cache_key) = find_vibe_cache_root(resolved)
    let cache_dir = vibe_root + "/debug/" + cache_key
    if @os_fs.path_exists(cache_dir) {
      let _ = c_system(
        system_command_bytes("rm -rf " + shell_quote_command_arg(cache_dir)),
      )
      println("clean: removed " + cache_dir)
    } else {
      println("clean: no cache for " + entry)
    }
  } else {
    // Clean all debug cache: find nearest .vibe with cache.json
    let cwd = @io.current_dir_or_root()
    let mut dir = cwd
    for _ in 0..<20 {
      let vibe_dir = dir + "/.vibe"
      if @os_fs.path_exists(vibe_dir) &&
        @os_fs.path_exists(vibe_dir + "/cache.json") {
        let debug_dir = vibe_dir + "/debug"
        if @os_fs.path_exists(debug_dir) {
          let _ = c_system(
            system_command_bytes("rm -rf " + shell_quote_command_arg(debug_dir)),
          )
          println("clean: removed " + debug_dir)
        } else {
          println("clean: no debug cache in " + vibe_dir)
        }
        return
      }
      let parent = @vibe_fs.parent_path(dir)
      if parent == dir || parent.length() == 0 {
        break
      }
      dir = parent
    }
    println("clean: no .vibe directory found")
  }
}

///|
fn find_vibe_cache_root(entry_path : String) -> (String, String) {
  let entry_dir = @vibe_fs.parent_path(entry_path)
  // Extract basename without extension
  let mut last_slash = -1
  for i, c in entry_path {
    if c == '/' {
      last_slash = i
    }
  }
  let file_name = if last_slash >= 0 {
    entry_path.unsafe_substring(start=last_slash + 1, end=entry_path.length())
  } else {
    entry_path
  }
  let entry_basename = if file_name.has_suffix(".vibe") {
    file_name.unsafe_substring(start=0, end=file_name.length() - 5)
  } else {
    file_name
  }
  // Walk up to find nearest .vibe directory with cache.json (project root).
  // Sub-module .vibe dirs without cache.json are skipped.
  let mut dir = entry_dir
  for _ in 0..<20 {
    let vibe_dir = dir + "/.vibe"
    if @os_fs.path_exists(vibe_dir) &&
      @os_fs.path_exists(vibe_dir + "/cache.json") {
      // Compute relative path from dir to entry for cache key
      let rel = if entry_dir.length() > dir.length() + 1 {
        entry_dir.unsafe_substring(
          start=dir.length() + 1,
          end=entry_dir.length(),
        )
      } else {
        ""
      }
      // Slugify: replace / with _ and append basename
      let mut key = ""
      for c in rel {
        if c == '/' {
          key = key + "_"
        } else {
          key = key + Char::to_string(c)
        }
      }
      if key.length() > 0 {
        key = key + "_" + entry_basename
      } else {
        key = entry_basename
      }
      return (vibe_dir, key)
    }
    let parent = @vibe_fs.parent_path(dir)
    if parent == dir || parent.length() == 0 {
      break
    }
    dir = parent
  }
  // Fallback: use entry's parent .vibe directory
  (entry_dir + "/.vibe", entry_basename)
}

///|
fn maybe_create_linked_cache_background(entry_path : String) -> Unit {
  let resolved = @loader.resolve_entry_path(entry_path)
  let (vibe_root, cache_key) = find_vibe_cache_root(resolved)
  let cache_dir = vibe_root + "/debug/" + cache_key
  let imports_cache = cache_dir + "/linked_imports.txt"
  if @os_fs.path_exists(imports_cache) {
    return // cache already exists
  }
  // Find our own binary path
  let self_bin = match @sys.get_env_var("_") {
    Some(bin) if bin.has_suffix("vibe.exe") || bin.has_suffix("vibe") => bin
    _ => return // can't find self
  }
  let cmd = "VIBE_INTERNAL_PARENT_PID=" +
    vibe_getpid().to_string() +
    " " +
    shell_quote_command_arg(self_bin) +
    " build --debug " +
    shell_quote_command_arg(entry_path) +
    " -o /dev/null >/dev/null 2>&1 &"
  let _ = c_system(system_command_bytes(cmd))
}

///|
fn save_source_hashes(
  db : @runtime.VibeDb,
  entry : String,
  cache_dir : String,
  hash_cache_path : String,
) -> Unit {
  let _ = cache_dir
  let hashes = collect_source_hash_cache(db, entry, false)
  @os_fs.write_string_to_file(
    hash_cache_path,
    serialize_source_hash_cache(hashes),
  ) catch {
    _ => ()
  }
}

///|
fn collect_source_hash_cache(
  db : @runtime.VibeDb,
  entry : String,
  include_entry : Bool,
) -> Map[String, String] {
  let out : Map[String, String] = {}
  if include_entry {
    match db.get_source(entry) {
      Some(source) if source.length() > 0 =>
        out[entry] = @vibe_core.content_address_hash_string(source)
      _ => ()
    }
  }
  let imports = db.imports(entry)
  for imp in imports {
    match db.get_source(imp.path) {
      Some(source) if source.length() > 0 =>
        out[imp.path] = @vibe_core.content_address_hash_string(source)
      _ => ()
    }
  }
  out
}

///|
fn serialize_source_hash_cache(hashes : Map[String, String]) -> String {
  let keys : Array[String] = []
  for path, _ in hashes {
    keys.push(path)
  }
  keys.sort()
  let buf = StringBuilder::new()
  for path in keys {
    match hashes.get(path) {
      Some(hash) => {
        buf.write_string(path)
        buf.write_char('\t')
        buf.write_string(hash)
        buf.write_char('\n')
      }
      None => ()
    }
  }
  buf.to_string()
}

///|
fn parse_source_hash_cache(text : String) -> Map[String, String] {
  let out : Map[String, String] = {}
  for line_view in text.split("\n") {
    let line = line_view.to_string().trim().to_string()
    if line.length() == 0 {
      continue
    }
    let parts : Array[String] = []
    for part_view in line.split("\t") {
      parts.push(part_view.to_string())
    }
    if parts.length() >= 2 {
      out[parts[0]] = parts[1]
    }
  }
  out
}

///|
fn source_hash_cache_matches(
  saved : Map[String, String],
  current : Map[String, String],
) -> Bool {
  if saved.length() != current.length() {
    return false
  }
  for path, current_hash in current {
    match saved.get(path) {
      Some(saved_hash) => if saved_hash != current_hash { return false }
      None => return false
    }
  }
  true
}

///|
fn run_monolithic_cache_paths(
  entry_path : String,
  use_http_host_runner : Bool,
) -> (String, String, String) {
  let resolved = @loader.resolve_entry_path(entry_path)
  let (vibe_root, cache_key) = find_vibe_cache_root(resolved)
  let cache_dir = vibe_root + "/run/" + cache_key
  let wasm_name = if use_http_host_runner {
    "app_http.wasm"
  } else {
    "app.wasm"
  }
  let hash_name = if use_http_host_runner {
    "source_hashes_http.txt"
  } else {
    "source_hashes.txt"
  }
  (cache_dir, cache_dir + "/" + wasm_name, cache_dir + "/" + hash_name)
}

///|
fn compiled_test_batch_cache_paths(
  entry_path : String,
  use_http_host_runner : Bool,
) -> (String, String, String) {
  let resolved = @loader.resolve_entry_path(entry_path)
  let (vibe_root, cache_key) = find_vibe_cache_root(resolved)
  let cache_dir = vibe_root + "/test/" + cache_key
  let wasm_name = if use_http_host_runner {
    "batch_http.wasm"
  } else {
    "batch.wasm"
  }
  let hash_name = if use_http_host_runner {
    "source_hashes_http.txt"
  } else {
    "source_hashes.txt"
  }
  (cache_dir, cache_dir + "/" + wasm_name, cache_dir + "/" + hash_name)
}

///|
fn parse_linked_imports_cache(text : String) -> Array[@runtime.LinkedImport] {
  let out : Array[@runtime.LinkedImport] = []
  for line_view in text.split("\n") {
    let line = line_view.to_string().trim().to_string()
    if line.length() == 0 {
      continue
    }
    let parts : Array[String] = []
    for part_view in line.split("\t") {
      parts.push(part_view.to_string())
    }
    if parts.length() >= 4 {
      let pc : Result[Int, _] = try? @strconv.parse_int(parts[2])
      let rc : Result[Int, _] = try? @strconv.parse_int(parts[3])
      match (pc, rc) {
        (Ok(param_count), Ok(return_count)) =>
          out.push(@runtime.LinkedImport::{
            module_name: parts[0],
            func_name: parts[1],
            param_count,
            return_count,
          })
        _ => ()
      }
    }
  }
  out
}
