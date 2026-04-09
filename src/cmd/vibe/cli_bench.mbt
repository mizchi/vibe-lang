///|
enum BenchBackend {
  Wasm
} derive(Show, Eq)

///|
struct BenchSourceCase {
  name : String?
  body_source : String
} derive(Show, Eq)

///|
struct BenchSourcePlan {
  import_source : String
  prelude_source : String
  cases : Array[BenchSourceCase]
} derive(Show, Eq)

///|
struct BenchWasmRunner {
  wasmtime_bin : String
  wasm_flags : Array[String]
  wasi_flags : Array[String]
} derive(Show, Eq)

///|
struct WasmBenchFailure {
  name : String?
  error : String
} derive(Show, Eq)

///|
struct WasmBenchResult {
  name : String?
  iterations : Int
  warmup : Int
  elapsed_ms : Double
  per_us : Double
  wasm_bytes : Int
} derive(Show, Eq)

///|
struct WasmBenchReport {
  total : Int
  passed : Int
  failed : Int
  results : Array[WasmBenchResult]
  failures : Array[WasmBenchFailure]
} derive(Show, Eq)

///|
struct WasmBenchSummaryReport {
  total : Int
  passed : Int
  failed : Int
  results : Array[@runtime.BenchSummary]
  failures : Array[WasmBenchFailure]
} derive(Show, Eq)

///|
fn is_wasm_unsupported_compile_error(message : String) -> Bool {
  let lower = message.to_lower()
  (lower.contains("backend '") && lower.contains("' does not support:")) ||
  lower.contains("unsupported:") ||
  lower.contains("handle kind mismatch")
}

///|
fn parse_bench_backend(value : String) -> BenchBackend? {
  match value.trim().to_string().to_lower() {
    "wasm" | "compiled" => Some(BenchBackend::Wasm)
    _ => None
  }
}

///|
fn parse_bench_backend_or_abort(value : String) -> BenchBackend {
  match parse_bench_backend(value) {
    Some(v) => v
    None => abort("bench: invalid --backend: " + value + " (expected compiled)")
  }
}

///|
fn resolve_bench_backend(
  args : Array[String],
  default_backend : BenchBackend,
) -> BenchBackend {
  let mut backend = default_backend
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-b" | "--backend" => {
        if i + 1 >= args.length() {
          abort("bench: missing value for --backend")
        }
        backend = parse_bench_backend_or_abort(args[i + 1])
        i += 2
      }
      "-n" | "--n" | "--warmup" | "-e" | "--expr" | "--case" | "--cases" =>
        if i + 1 < args.length() {
          i += 2
        } else {
          i += 1
        }
      _ => i += 1
    }
  }
  backend
}

///|
fn bench_uses_expr_mode(args : Array[String]) -> Bool {
  if args.length() == 0 {
    return true
  }
  let mut saw_path = false
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-e" | "--expr" => return true
      "-n" | "--n" | "--warmup" | "-b" | "--backend" | "--case" | "--cases" =>
        if i + 1 < args.length() {
          i += 2
        } else {
          i += 1
        }
      _ => {
        if not(arg.has_prefix("-")) {
          saw_path = true
        }
        i += 1
      }
    }
  }
  not(saw_path)
}

///|
fn bench_cmd(
  args : Array[String],
  _syntax_mode : @runtime.ParserMode,
  features : @runtime.RuntimeFeatureFlags,
) -> Unit {
  @runtime_compile.init_hooks()
  ignore(features)
  if has_help_flag(args) {
    print_bench_help()
    return
  }
  let expr_mode = bench_uses_expr_mode(args)
  if expr_mode {
    abort(
      "bench: legacy expr mode was removed; pass <file|dir...> with `bench {}` blocks",
    )
  } else {
    let _ = resolve_bench_backend(args, BenchBackend::Wasm)
    bench_blocks_cmd(args)
  }
}

///|
fn bench_blocks_cmd(args : Array[String]) -> Unit {
  let mut runs = 10
  let mut warmup = 3
  let mut legacy_n : Int? = None
  let paths : Array[String] = []
  let case_filters : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--runs" => {
        if i + 1 >= args.length() {
          abort("bench: missing value for --runs")
        }
        runs = @strconv.parse_int(args[i + 1]) catch {
          e => abort("bench: invalid --runs: " + e.to_string())
        }
        i += 2
      }
      "-n" | "--n" => {
        if i + 1 >= args.length() {
          abort("bench: missing value for --n")
        }
        legacy_n = Some(
          @strconv.parse_int(args[i + 1]) catch {
            e => abort("bench: invalid --n: " + e.to_string())
          },
        )
        i += 2
      }
      "--warmup" => {
        if i + 1 >= args.length() {
          abort("bench: missing value for --warmup")
        }
        warmup = @strconv.parse_int(args[i + 1]) catch {
          e => abort("bench: invalid --warmup: " + e.to_string())
        }
        i += 2
      }
      "--case" => {
        if i + 1 >= args.length() {
          abort("bench: missing value for --case")
        }
        case_filters.push(args[i + 1])
        i += 2
      }
      "-b" | "--backend" => {
        if i + 1 >= args.length() {
          abort("bench: missing value for --backend")
        }
        let _ = parse_bench_backend_or_abort(args[i + 1])
        i += 2
      }
      _ =>
        if arg.has_prefix("-") {
          abort("bench: unknown arg " + arg)
        } else {
          paths.push(arg)
          i += 1
        }
    }
  }
  if runs <= 0 {
    abort("bench: --runs must be > 0")
  }
  if warmup < 0 {
    abort("bench: --warmup must be >= 0")
  }
  if paths.length() == 0 {
    abort("bench: expected <file|dir...>")
  }
  let entry_paths = resolve_bench_entry_paths(paths)
  if entry_paths.length() == 0 {
    abort("bench: no bench files found")
  }
  // Legacy mode: if --n is specified without --runs, use old fixed-iteration behavior
  let use_legacy = match legacy_n {
    Some(_) => true
    None => false
  }
  let mut failed = false
  let mut total = 0
  let mut passed = 0
  let mut failed_count = 0
  let file_count = entry_paths.length()
  for entry_path in entry_paths {
    let resolved_entry_path = @loader.resolve_entry_path(entry_path)
    if use_legacy {
      let count = match legacy_n {
        Some(n) => n
        None => 1000
      }
      match
        run_bench_blocks_wasm_entry_with_cases(
          resolved_entry_path, count, warmup, case_filters,
        ) {
        Err(err) => {
          println("[\{entry_path}] \{err}")
          failed = true
        }
        Ok(report) => {
          if !print_wasm_bench_report(entry_path, report) {
            failed = true
          }
          total += report.total
          passed += report.passed
          failed_count += report.failed
        }
      }
    } else {
      // Statistical mode (default)
      match
        run_bench_blocks_wasm_statistical_entry_with_cases(
          resolved_entry_path, runs, warmup, case_filters,
        ) {
        Err(err) => {
          println("[\{entry_path}] \{err}")
          failed = true
        }
        Ok(report) => {
          if !print_wasm_bench_summary_report(entry_path, report) {
            failed = true
          }
          total += report.total
          passed += report.passed
          failed_count += report.failed
        }
      }
    }
  }
  println(
    "summary: files=\{file_count} backend=compiled total=\{total} passed=\{passed} failed=\{failed_count}",
  )
  if failed {
    abort("bench: failures detected")
  }
}

///|
fn bench_case_matches_filters(
  name : String?,
  case_filters : Array[String],
) -> Bool {
  if case_filters.length() == 0 {
    return true
  }
  match name {
    None => false
    Some(case_name) => {
      for filter_name in case_filters {
        if case_name == filter_name {
          return true
        }
      }
      false
    }
  }
}

///|
fn filter_bench_source_plan_cases(
  plan : BenchSourcePlan,
  case_filters : Array[String],
) -> Result[BenchSourcePlan, String] {
  if case_filters.length() == 0 {
    return Ok(plan)
  }
  let filtered_cases : Array[BenchSourceCase] = []
  for case_item in plan.cases {
    if bench_case_matches_filters(case_item.name, case_filters) {
      filtered_cases.push(case_item)
    }
  }
  if filtered_cases.length() == 0 {
    return Err(
      "bench: no cases matched --case (" + case_filters.join(", ") + ")",
    )
  }
  Ok(BenchSourcePlan::{
    import_source: plan.import_source,
    prelude_source: plan.prelude_source,
    cases: filtered_cases,
  })
}

///|
fn module_source_from_stmt_spans(
  source : String,
  stmts : Array[@vibe_core.Stmt],
) -> String {
  let out = StringBuilder::new()
  for stmt in stmts {
    let span = stmt.span()
    let snippet = source_slice_by_span(source, span.start, span.end)
    if snippet.length() == 0 {
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
fn extract_bench_source_plan(
  source : String,
) -> Result[BenchSourcePlan, String] {
  let ast = @parser.parse_ast(source) catch {
    e => return Err("parse error: " + e.to_string())
  }
  let import_stmts : Array[@vibe_core.Stmt] = []
  let prelude_stmts : Array[@vibe_core.Stmt] = []
  let cases : Array[BenchSourceCase] = []
  for stmt in ast.stmts {
    match stmt {
      @vibe_core.Stmt::Import(..) | @vibe_core.Stmt::ReExport(..) =>
        import_stmts.push(stmt)
      @vibe_core.Stmt::Bench(name~, body~, span~) => {
        let _ = body
        let stmt_source = source_slice_by_span(source, span.start, span.end)
        let body_source = bench_stmt_body_source(stmt_source)
        cases.push({ name, body_source })
      }
      _ => prelude_stmts.push(stmt)
    }
  }
  let import_source = module_source_from_stmt_spans(source, import_stmts)
  let prelude_source = module_source_from_stmt_spans(source, prelude_stmts)
  Ok(BenchSourcePlan::{ import_source, prelude_source, cases })
}

///|
fn bench_stmt_body_source(stmt_source : String) -> String {
  let mut open_index = -1
  let mut close_index = -1
  for i, ch in stmt_source {
    if ch == '{' && open_index < 0 {
      open_index = i
    }
    if ch == '}' {
      close_index = i
    }
  }
  if open_index < 0 || close_index <= open_index {
    return ""
  }
  source_slice_by_span(stmt_source, open_index + 1, close_index)
}

///|
fn build_bench_case_loop_script(
  import_source : String,
  prelude_source : String,
  body_source : String,
  iterations : Int,
) -> String {
  let out = StringBuilder::new()
  let iter_name = "vibe_bench_iter_internal"
  if import_source.length() > 0 {
    out.write_string(import_source)
    if !import_source.has_suffix("\n") {
      out.write_char('\n')
    }
  }
  out.write_string(
    "export let _start = () -> Int with { Error, Fs, Env, Net, Process, Stdout, Stdin, Time, Random } {\n",
  )
  // Wrap non-import setup in a block so that prelude `let mut` bindings are
  // not at the top level (top-level `let mut` is rejected by the type checker).
  out.write_string("{\n")
  if prelude_source.length() > 0 {
    out.write_string(prelude_source)
    if !prelude_source.has_suffix("\n") {
      out.write_char('\n')
    }
  }
  out.write_string("{\n")
  out.write_string("let mut ")
  out.write_string(iter_name)
  out.write_string(" = 0\n")
  out.write_string("while ")
  out.write_string(iter_name)
  out.write_string(" < ")
  out.write_string(iterations.to_string())
  out.write_string(" {\n")
  if body_source.length() > 0 {
    out.write_string(body_source)
    if not(body_source.has_suffix("\n")) {
      out.write_char('\n')
    }
  }
  out.write_string(iter_name)
  out.write_string(" += 1\n")
  out.write_string("}\n")
  out.write_string("}\n")
  out.write_string("}\n")
  out.write_string("0\n")
  out.write_string("}\n")
  out.to_string()
}

///|
fn bench_script_cache_paths(
  entry_path : String,
  script_kind : String,
  source : String,
) -> (String, String, String) {
  let resolved = @loader.resolve_entry_path(entry_path)
  let (vibe_root, cache_key) = find_vibe_cache_root(resolved)
  let hash = @vibe_core.content_address_hash_string(script_kind + "\n" + source)
  let cache_dir = vibe_root + "/bench/" + cache_key
  let entry_dir = @vibe_fs.parent_path(resolved)
  let prefix = cache_dir + "/" + script_kind + "_" + hash
  let source_path = entry_dir +
    "/.vibe_bench_" +
    script_kind +
    "_" +
    hash +
    ".vibe"
  (cache_dir, source_path, prefix + ".wasm")
}

///|
fn is_existing_file(path : String) -> Bool {
  if not(@os_fs.path_exists(path)) {
    return false
  }
  @os_fs.is_file(path) catch {
    _ => false
  }
}

///|
fn split_env_flags(raw : String) -> Array[String] {
  let out : Array[String] = []
  for part_view in raw.split(" ") {
    let token = part_view.trim().to_string()
    if token.length() > 0 {
      out.push(token)
    }
  }
  out
}

///|
fn has_wasm_feature_flag(flags : Array[String], feature : String) -> Bool {
  let prefix = feature.to_lower() + "="
  for flag in flags {
    let token = flag.trim().to_string().to_lower()
    if token == feature || token.has_prefix(prefix) {
      return true
    }
  }
  false
}

///|
fn with_default_bench_wasm_flags(flags : Array[String]) -> Array[String] {
  let out = flags.copy()
  // vibe-generated core wasm currently uses exception tags; enable by default.
  if not(has_wasm_feature_flag(out, "exceptions")) {
    out.push("exceptions=y")
  }
  out
}

///|
fn find_command_in_path(name : String) -> String? {
  match @sys.get_env_var("PATH") {
    None => None
    Some(path_value) => {
      for dir_view in path_value.split(":") {
        let dir = dir_view.trim().to_string()
        if dir.length() == 0 {
          continue
        }
        let candidate = dir + "/" + name
        if is_existing_file(candidate) {
          return Some(candidate)
        }
      }
      None
    }
  }
}

///|
fn project_root_for_path(path : String) -> String {
  let is_dir = @os_fs.is_dir(path) catch { _ => false }
  let mut dir = if is_dir { path } else { @vibe_fs.parent_path(path) }
  for _ in 0..<64 {
    let marker = dir + "/moon.mod.json"
    if is_existing_file(marker) {
      return dir
    }
    let parent = @vibe_fs.parent_path(dir)
    if parent == dir {
      break
    }
    dir = parent
  }
  @io.current_dir_or_root()
}

///|
fn resolve_wasmtime_bin_for_bench(
  project_root : String,
) -> Result[String, String] {
  match @sys.get_env_var("WASMTIME_BIN") {
    Some(value) => {
      let trimmed = value.trim().to_string()
      if trimmed.length() > 0 {
        return Ok(trimmed)
      }
    }
    None => ()
  }
  let local_release = project_root + "/deps/wasmtime/target/release/wasmtime"
  let local_debug = project_root + "/deps/wasmtime/target/debug/wasmtime"
  let use_submodule = match @sys.get_env_var("VIBE_USE_WASMTIME_SUBMODULE") {
    Some(value) => value.trim().to_string() == "1"
    None => false
  }
  if use_submodule {
    if is_existing_file(local_release) {
      return Ok(local_release)
    }
    if is_existing_file(local_debug) {
      return Ok(local_debug)
    }
    return Err(
      "VIBE_USE_WASMTIME_SUBMODULE=1 but deps/wasmtime binary is not built. run: just build-wasmtime-submodule",
    )
  }
  match find_command_in_path("wasmtime") {
    Some(path) => return Ok(path)
    None => ()
  }
  if is_existing_file(local_release) {
    return Ok(local_release)
  }
  if is_existing_file(local_debug) {
    return Ok(local_debug)
  }
  Err(
    "wasmtime not found (PATH and deps/wasmtime build). install wasmtime or run: just build-wasmtime-submodule",
  )
}

///|
fn resolve_bench_wasm_runner(
  entry_path : String,
) -> Result[BenchWasmRunner, String] {
  let project_root = project_root_for_path(entry_path)
  let wasmtime_bin = match resolve_wasmtime_bin_for_bench(project_root) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let wasm_flags = match @sys.get_env_var("VIBE_WASMTIME_WASM_FLAGS") {
    Some(raw) => split_env_flags(raw)
    None => []
  }
  let wasm_flags = with_default_bench_wasm_flags(wasm_flags)
  let wasi_flags = match @sys.get_env_var("VIBE_WASMTIME_WASI_FLAGS") {
    Some(raw) => split_env_flags(raw)
    None => []
  }
  Ok(BenchWasmRunner::{ wasmtime_bin, wasm_flags, wasi_flags })
}

///|
fn shell_quote_command_arg(value : String) -> String {
  let mut escaped = value.replace_all(old="\\", new="\\\\")
  escaped = escaped.replace_all(old="\"", new="\\\"")
  escaped = escaped.replace_all(old="$", new="\\$")
  escaped = escaped.replace_all(old="`", new="\\`")
  "\"" + escaped + "\""
}

///|
fn build_wasmtime_bench_command(
  runner : BenchWasmRunner,
  wasm_path : String,
) -> String {
  build_wasmtime_invoke_command(runner, wasm_path, "_start")
}

///|
fn build_wasmtime_invoke_command(
  runner : BenchWasmRunner,
  wasm_path : String,
  invoke_name : String,
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
  cmd.write_string(" --invoke ")
  cmd.write_string(shell_quote_command_arg(invoke_name))
  cmd.write_string(" ")
  cmd.write_string(shell_quote_command_arg(wasm_path))
  cmd.to_string()
}

///|
fn run_wasmtime_bench_module(
  runner : BenchWasmRunner,
  wasm_path : String,
) -> Result[Unit, String] {
  let cmd = build_wasmtime_bench_command(runner, wasm_path) + " >/dev/null 2>&1"
  let status = c_system(system_command_bytes(cmd))
  if status == 0 {
    Ok(())
  } else {
    Err("wasmtime command failed: status=" + status.to_string() + " cmd=" + cmd)
  }
}

///|
fn run_bench_module(
  runner : BenchWasmRunner,
  entry_path : String,
  wasm_path : String,
  use_node_runner : Bool,
) -> Result[Unit, String] {
  let tmp_prefix = wasm_path + ".bench_exec"
  let exec_out = if use_node_runner {
    let host_runner = match resolve_http_host_runner(entry_path) {
      Ok(v) => v
      Err(err) => return Err(err)
    }
    run_http_host_invoke_run_capture(host_runner, wasm_path, tmp_prefix)
  } else {
    run_wasmtime_invoke_run_capture(runner, wasm_path, tmp_prefix)
  }
  if exec_out.status == 0 {
    Ok(())
  } else {
    let runner_name = if use_node_runner {
      "node host runner"
    } else {
      "wasmtime"
    }
    Err(
      runner_name +
      " command failed: status=" +
      exec_out.status.to_string() +
      " detail=" +
      wasmtime_failure_detail(exec_out.stdout, exec_out.stderr),
    )
  }
}

///|
fn compile_bench_script_to_wasm(
  entry_path : String,
  script_kind : String,
  source : String,
) -> Result[(String, Int, Bool), String] {
  let (cache_dir, source_path, wasm_path) = bench_script_cache_paths(
    entry_path, script_kind, source,
  )
  match ensure_parent_dir_for_file(wasm_path, "bench cache") {
    Ok(_) => ()
    Err(err) => return Err("bench cache dir failed: " + err)
  }
  @os_fs.write_string_to_file(source_path, source) catch {
    e => return Err("write source failed: " + e.to_string())
  }
  let (db, entry) = match @loader.load_db(source_path) {
    Err(err) => return Err("load error: " + err)
    Ok(v) => v
  }
  let (use_http_host_runner, use_fs_host_runner) = detect_exec_host_runner_requirements(
    db, entry,
  )
  let use_node_runner = use_http_host_runner || use_fs_host_runner
  let cached_hash_path = wasm_path + ".hashes"
  let cached_mode_path = wasm_path + ".mode"
  let current_hashes = collect_source_hash_cache(db, entry, true)
  let current_mode = if use_node_runner { "host" } else { "plain" }
  let has_cached_hashes = @os_fs.path_exists(cached_hash_path)
  let cached_mode_matches = if @os_fs.path_exists(cached_mode_path) {
    let saved_mode = @os_fs.read_file_to_string(cached_mode_path) catch {
      _ => ""
    }
    saved_mode.trim().to_string() == current_mode
  } else {
    false
  }
  let use_cached_wasm = if @os_fs.path_exists(wasm_path) &&
    has_cached_hashes &&
    cached_mode_matches {
    let saved_hashes = parse_source_hash_cache(
      @os_fs.read_file_to_string(cached_hash_path) catch {
        _ => ""
      },
    )
    source_hash_cache_matches(saved_hashes, current_hashes)
  } else {
    false
  }
  if use_cached_wasm {
    let cached_bytes = @os_fs.read_file_to_bytes(wasm_path) catch {
      _ => Bytes::new(0)
    }
    if cached_bytes.length() > 0 {
      return Ok((wasm_path, cached_bytes.length(), use_node_runner))
    }
  }
  let wasm_bytes = if use_node_runner {
    compile_module_wasm_for_exec(
      db,
      entry,
      http_host_imports=true,
      fs_host_imports=true,
    ) catch {
      e => return Err("compile wasm error: " + e.user_message())
    }
  } else {
    @runtime_compile.compile_module_wasm_with_opt_level(
      db,
      entry,
      no_dce=true,
      opt_level=Some("-Oz"),
    ) catch {
      e => {
        let primary_err = e.user_message()
        if primary_err.contains("optimize:") {
          @runtime_compile.compile_module_wasm_with_opt_level(
            db,
            entry,
            no_dce=true,
            opt_level=None,
          ) catch {
            e2 =>
              return Err(
                "compile wasm error: " +
                primary_err +
                " (fallback without optimize failed: " +
                e2.user_message() +
                ")",
              )
          }
        } else {
          return Err("compile wasm error: " + primary_err)
        }
      }
    }
  }
  @os_fs.write_bytes_to_file(wasm_path, wasm_bytes) catch {
    e => return Err("write wasm failed: " + e.to_string())
  }
  @os_fs.write_string_to_file(
    cached_hash_path,
    serialize_source_hash_cache(current_hashes),
  ) catch {
    _ => ()
  }
  @os_fs.write_string_to_file(cached_mode_path, current_mode + "\n") catch {
    _ => ()
  }
  let _ = cache_dir
  Ok((wasm_path, wasm_bytes.length(), use_node_runner))
}

///|
fn run_wasm_case_measure(
  runner : BenchWasmRunner,
  entry_path : String,
  script_kind : String,
  source : String,
  count : Int,
) -> Result[(Double, Double, Int), String] {
  let (wasm_path, wasm_bytes, use_node_runner) = match
    compile_bench_script_to_wasm(entry_path, script_kind, source) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let start = @bench.monotonic_clock_start()
  match run_bench_module(runner, entry_path, wasm_path, use_node_runner) {
    Ok(_) => ()
    Err(err) => return Err(err)
  }
  let elapsed_us = @bench.monotonic_clock_end(start)
  let elapsed_ms = elapsed_us / 1000.0
  let per_us = elapsed_us / count.to_double()
  Ok((elapsed_ms, per_us, wasm_bytes))
}

///|
fn run_wasm_bench_case(
  runner : BenchWasmRunner,
  entry_path : String,
  case_index : Int,
  case_name : String?,
  import_source : String,
  case_body_source : String,
  prelude_source : String,
  count : Int,
  warmup : Int,
) -> Result[WasmBenchResult, WasmBenchFailure] {
  let warm_source = build_bench_case_loop_script(
    import_source, prelude_source, case_body_source, warmup,
  )
  let run_source = build_bench_case_loop_script(
    import_source, prelude_source, case_body_source, count,
  )
  let measured = if warmup > 0 {
    match
      compile_bench_script_to_wasm(
        entry_path,
        "warm_" + case_index.to_string() + "_" + warmup.to_string(),
        warm_source,
      ) {
      Ok((warm_wasm_path, _, use_node_runner)) =>
        match
          run_bench_module(runner, entry_path, warm_wasm_path, use_node_runner) {
          Ok(_) =>
            run_wasm_case_measure(
              runner,
              entry_path,
              "run_" + case_index.to_string() + "_" + count.to_string(),
              run_source,
              count,
            )
          Err(err) => Err("warmup run failed: " + err)
        }
      Err(err) => Err("warmup compile failed: " + err)
    }
  } else {
    run_wasm_case_measure(
      runner,
      entry_path,
      "run_" + case_index.to_string() + "_" + count.to_string(),
      run_source,
      count,
    )
  }
  match measured {
    Ok((elapsed_ms, per_us, wasm_bytes)) =>
      Ok(WasmBenchResult::{
        name: case_name,
        iterations: count,
        warmup,
        elapsed_ms,
        per_us,
        wasm_bytes,
      })
    Err(err) => Err(WasmBenchFailure::{ name: case_name, error: err })
  }
}

///|
fn run_bench_blocks_wasm_entry(
  entry_path : String,
  count : Int,
  warmup : Int,
) -> Result[WasmBenchReport, String] {
  run_bench_blocks_wasm_entry_with_cases(entry_path, count, warmup, [])
}

///|
fn run_bench_blocks_wasm_entry_with_cases(
  entry_path : String,
  count : Int,
  warmup : Int,
  case_filters : Array[String],
) -> Result[WasmBenchReport, String] {
  let source = @os_fs.read_file_to_string(entry_path) catch {
    e => return Err("read error: " + e.to_string())
  }
  let raw_plan = match extract_bench_source_plan(source) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let plan = match filter_bench_source_plan_cases(raw_plan, case_filters) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let runner = match resolve_bench_wasm_runner(entry_path) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let results : Array[WasmBenchResult] = []
  let failures : Array[WasmBenchFailure] = []
  let mut passed = 0
  let mut case_index = 0
  for case_item in plan.cases {
    case_index += 1
    let case_name = case_item.name
    let case_body_source = case_item.body_source
    match
      run_wasm_bench_case(
        runner,
        entry_path,
        case_index,
        case_name,
        plan.import_source,
        case_body_source,
        plan.prelude_source,
        count,
        warmup,
      ) {
      Ok(result) => {
        results.push(result)
        passed += 1
      }
      Err(failure) => failures.push(failure)
    }
  }
  Ok(WasmBenchReport::{
    total: plan.cases.length(),
    passed,
    failed: failures.length(),
    results,
    failures,
  })
}

///|
/// WASM statistical bench: auto-calibrate batch_size, collect N samples
fn run_bench_blocks_wasm_statistical_entry(
  entry_path : String,
  runs : Int,
  warmup : Int,
) -> Result[WasmBenchSummaryReport, String] {
  run_bench_blocks_wasm_statistical_entry_with_cases(entry_path, runs, warmup, [])
}

///|
fn run_bench_blocks_wasm_statistical_entry_with_cases(
  entry_path : String,
  runs : Int,
  warmup : Int,
  case_filters : Array[String],
) -> Result[WasmBenchSummaryReport, String] {
  let source = @os_fs.read_file_to_string(entry_path) catch {
    e => return Err("read error: " + e.to_string())
  }
  let raw_plan = match extract_bench_source_plan(source) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let plan = match filter_bench_source_plan_cases(raw_plan, case_filters) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let runner = match resolve_bench_wasm_runner(entry_path) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let results : Array[@runtime.BenchSummary] = []
  let failures : Array[WasmBenchFailure] = []
  let mut passed = 0
  let mut case_index = 0
  for case_item in plan.cases {
    case_index += 1
    let case_name = case_item.name
    let case_body_source = case_item.body_source
    // Auto-calibrate: try increasing batch sizes until ~100ms
    let threshold_us = 100000.0
    let mut batch_size = 1
    let mut calibration_ok = true
    let mut trial = 1
    while true {
      let cal_source = build_bench_case_loop_script(
        plan.import_source,
        plan.prelude_source,
        case_body_source,
        trial,
      )
      let cal_script_kind = "stat_cal_" +
        case_index.to_string() +
        "_" +
        trial.to_string()
      let (cal_wasm_path, cal_use_node_runner) = match
        compile_bench_script_to_wasm(entry_path, cal_script_kind, cal_source) {
        Err(err) => {
          failures.push(WasmBenchFailure::{
            name: case_name,
            error: "calibration compile failed: " + err,
          })
          calibration_ok = false
          break
        }
        Ok((path, _, use_node_runner)) => (path, use_node_runner)
      }
      let start = @bench.monotonic_clock_start()
      match
        run_bench_module(runner, entry_path, cal_wasm_path, cal_use_node_runner) {
        Err(err) => {
          failures.push(WasmBenchFailure::{
            name: case_name,
            error: "calibration run failed: " + err,
          })
          calibration_ok = false
          break
        }
        Ok(_) => ()
      }
      let elapsed_us = @bench.monotonic_clock_end(start)
      let single_us = elapsed_us / trial.to_double()
      if trial.to_double() * single_us > threshold_us {
        let target = threshold_us /
          (if single_us < 1.0 { 1.0 } else { single_us })
        batch_size = if target < 1.0 { 1 } else { target.ceil().to_int() }
        break
      }
      trial = trial * 2
    }
    if not(calibration_ok) {
      continue
    }
    // Compile the measurement script once
    let run_source = build_bench_case_loop_script(
      plan.import_source,
      plan.prelude_source,
      case_body_source,
      batch_size,
    )
    let run_script_kind = "stat_run_" +
      case_index.to_string() +
      "_" +
      batch_size.to_string()
    let (run_wasm_path, wasm_bytes, use_node_runner) = match
      compile_bench_script_to_wasm(entry_path, run_script_kind, run_source) {
      Ok(v) => v
      Err(err) => {
        failures.push(WasmBenchFailure::{
          name: case_name,
          error: "compile failed: " + err,
        })
        continue
      }
    }
    // Warmup
    let mut warmup_ok = true
    for _ in 0..<warmup {
      match
        run_bench_module(runner, entry_path, run_wasm_path, use_node_runner) {
        Ok(_) => ()
        Err(err) => {
          failures.push(WasmBenchFailure::{
            name: case_name,
            error: "warmup failed: " + err,
          })
          warmup_ok = false
          break
        }
      }
    }
    if not(warmup_ok) {
      continue
    }
    // Collect samples
    let samples : Array[Double] = []
    let mut sample_ok = true
    for _ in 0..<runs {
      let start = @bench.monotonic_clock_start()
      match
        run_bench_module(runner, entry_path, run_wasm_path, use_node_runner) {
        Ok(_) => ()
        Err(err) => {
          failures.push(WasmBenchFailure::{
            name: case_name,
            error: "measurement run failed: " + err,
          })
          sample_ok = false
          break
        }
      }
      let elapsed_us = @bench.monotonic_clock_end(start)
      samples.push(elapsed_us / batch_size.to_double())
    }
    if not(sample_ok) {
      continue
    }
    results.push(
      @runtime.compute_bench_summary(case_name, samples, batch_size, wasm_bytes),
    )
    passed += 1
  }
  Ok(WasmBenchSummaryReport::{
    total: plan.cases.length(),
    passed,
    failed: failures.length(),
    results,
    failures,
  })
}

///|
fn format_us(us : Double) -> String {
  if us >= 1000000.0 {
    let s = us / 1000000.0
    // format to 3 decimal places
    let whole = s.floor().to_int()
    let frac = ((s - whole.to_double()) * 1000.0).round().to_int()
    whole.to_string() + "." + pad_left_zero(frac, 3) + "s"
  } else if us >= 1000.0 {
    let ms = us / 1000.0
    let whole = ms.floor().to_int()
    let frac = ((ms - whole.to_double()) * 100.0).round().to_int()
    whole.to_string() + "." + pad_left_zero(frac, 2) + "ms"
  } else if us >= 1.0 {
    let whole = us.floor().to_int()
    let frac = ((us - whole.to_double()) * 100.0).round().to_int()
    whole.to_string() + "." + pad_left_zero(frac, 2) + "us"
  } else {
    let ns = us * 1000.0
    let whole = ns.floor().to_int()
    let frac = ((ns - whole.to_double()) * 100.0).round().to_int()
    whole.to_string() + "." + pad_left_zero(frac, 2) + "ns"
  }
}

///|
fn pad_left_zero(n : Int, width : Int) -> String {
  let s = n.abs().to_string()
  if s.length() >= width {
    return s
  }
  let mut out = ""
  for _ in 0..<(width - s.length()) {
    out += "0"
  }
  out + s
}

///|
fn print_bench_summary_entry(result : @runtime.BenchSummary) -> Unit {
  let name = match result.name {
    Some(v) => v
    None => "<anon>"
  }
  // Machine-parseable line (backward compat: per_us= is median)
  println(
    "  bench: " +
    name +
    " runs=" +
    result.runs.to_string() +
    " batch_size=" +
    result.batch_size.to_string() +
    " per_us=" +
    result.median.to_string() +
    (if result.wasm_bytes > 0 {
      " wasm_bytes=" + result.wasm_bytes.to_string()
    } else {
      ""
    }),
  )
  // Human-readable line (moon bench style):
  //   55.47 ms ±  1.11 ms    54.59 ms …  58.43 ms  in 10 × 2 runs
  println(
    "    " +
    rpad(format_us(result.median), 10) +
    " \u{00B1} " +
    rpad(format_us(result.std_dev), 10) +
    rpad(format_us(result.min), 10) +
    " \u{2026} " +
    rpad(format_us(result.max), 10) +
    "in " +
    result.runs.to_string() +
    " \u{00D7} " +
    rpad(result.batch_size.to_string(), 6) +
    " runs",
  )
}

///|
fn rpad(s : String, width : Int) -> String {
  if s.length() >= width {
    return s
  }
  let buf = StringBuilder::new()
  buf.write_string(s)
  for _ in 0..<(width - s.length()) {
    buf.write_char(' ')
  }
  buf.to_string()
}

///|
fn print_wasm_bench_summary_report(
  path : String,
  report : WasmBenchSummaryReport,
) -> Bool {
  println("[\{path}]")
  let mut success = true
  for result in report.results {
    print_bench_summary_entry(result)
  }
  for failure in report.failures {
    success = false
    let name = match failure.name {
      Some(v) => v
      None => "<anon>"
    }
    println("  bench: " + name + " failed: " + failure.error)
  }
  success
}

///|
fn print_wasm_bench_report(path : String, report : WasmBenchReport) -> Bool {
  println("[\{path}]")
  let mut success = true
  for result in report.results {
    let name = match result.name {
      Some(v) => v
      None => "<anon>"
    }
    println(
      "  bench: " +
      name +
      " count=" +
      result.iterations.to_string() +
      " warmup=" +
      result.warmup.to_string() +
      " total_ms=" +
      result.elapsed_ms.to_string() +
      " per_us=" +
      result.per_us.to_string() +
      " wasm_bytes=" +
      result.wasm_bytes.to_string(),
    )
  }
  for failure in report.failures {
    success = false
    let name = match failure.name {
      Some(v) => v
      None => "<anon>"
    }
    println("  bench: " + name + " failed: " + failure.error)
  }
  success
}

///|
fn bench_file_cmd(
  args : Array[String],
  features : @runtime.RuntimeFeatureFlags,
) -> Unit {
  let mut count = 1000
  let mut warmup = 10
  let mut entry_path : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-n" | "--n" => {
        if i + 1 >= args.length() {
          abort("bench-file: missing value for --n")
        }
        count = @strconv.parse_int(args[i + 1]) catch {
          e => abort("bench-file: invalid --n: " + e.to_string())
        }
        i += 2
      }
      "--warmup" => {
        if i + 1 >= args.length() {
          abort("bench-file: missing value for --warmup")
        }
        warmup = @strconv.parse_int(args[i + 1]) catch {
          e => abort("bench-file: invalid --warmup: " + e.to_string())
        }
        i += 2
      }
      "--file" => {
        if i + 1 >= args.length() {
          abort("bench-file: missing value for --file")
        }
        entry_path = Some(args[i + 1])
        i += 2
      }
      _ =>
        if entry_path is None {
          entry_path = Some(arg)
          i += 1
        } else {
          abort("bench-file: too many input files")
        }
    }
  }
  if count <= 0 {
    abort("bench-file: --n must be > 0")
  }
  if warmup < 0 {
    abort("bench-file: --warmup must be >= 0")
  }
  match entry_path {
    None => abort("bench-file: missing <file>")
    Some(path) => {
      let (db, entry) = match load_entry_db(path) {
        Err(err) => abort("bench-file: " + err)
        Ok(v) => v
      }
      let rt = new_runtime_with_features(features)
      for _ in 0..<warmup {
        let compiled = match compile_entry_with_db(db, entry) {
          Err(err) => abort("bench-file: " + err)
          Ok(v) => v
        }
        let _ = @runtime_compile.run_compiled(rt, compiled) catch {
          e => abort("bench-file: " + e.to_string())
        }
      }
      let start = @bench.monotonic_clock_start()
      for _ in 0..<count {
        let compiled = match compile_entry_with_db(db, entry) {
          Err(err) => abort("bench-file: " + err)
          Ok(v) => v
        }
        let _ = @runtime_compile.run_compiled(rt, compiled) catch {
          e => abort("bench-file: " + e.to_string())
        }
      }
      let elapsed_us = @bench.monotonic_clock_end(start)
      let elapsed_ms = elapsed_us / 1000.0
      let per_us = elapsed_us / count.to_double()
      if elapsed_ms <= 0.0 {
        println("bench-file: elapsed_ms=0; increase --n for measurable time")
      }
      println(
        "bench-file: file=\"" +
        path +
        "\" count=" +
        count.to_string() +
        " total_ms=" +
        elapsed_ms.to_string() +
        " per_us=" +
        per_us.to_string(),
      )
    }
  }
}

///|
struct OverlayRect {
  row : Int
  col : Int
  width : Int
  height : Int
}

///|
fn OverlayRect::eq(self : OverlayRect, other : OverlayRect) -> Bool {
  self.row == other.row &&
  self.col == other.col &&
  self.width == other.width &&
  self.height == other.height
}
