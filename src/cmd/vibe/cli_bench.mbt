///|
enum BenchBackend {
  Wasm
} derive(Debug, Eq)

///|
struct BenchSourceCase {
  name : String?
  body_source : String
} derive(Debug, Eq)

///|
struct BenchSourcePlan {
  import_source : String
  shared_prelude_source : String
  local_prelude_source : String
  setup_source : String
  cases : Array[BenchSourceCase]
} derive(Debug, Eq)

///|
struct BenchWasmRunner {
  wasmtime_bin : String
  wasm_flags : Array[String]
  wasi_flags : Array[String]
} derive(Debug, Eq)

///|
struct BenchCmdOptions {
  runs : Int
  warmup : Int
  legacy_n : Int?
  paths : Array[String]
  case_filters : Array[String]
  backend : BenchBackend
  output_json : Bool
  json_out_path : String?
} derive(Debug, Eq)

///|
struct WasmBenchFailure {
  name : String?
  error : String
} derive(Debug, Eq)

///|
struct WasmBenchResult {
  name : String?
  iterations : Int
  warmup : Int
  elapsed_ms : Double
  per_us : Double
  wasm_bytes : Int
} derive(Debug, Eq)

///|
struct WasmBenchReport {
  total : Int
  passed : Int
  failed : Int
  results : Array[WasmBenchResult]
  failures : Array[WasmBenchFailure]
} derive(Debug, Eq)

///|
struct WasmBenchSummaryReport {
  total : Int
  passed : Int
  failed : Int
  results : Array[@runtime.BenchSummary]
  failures : Array[WasmBenchFailure]
} derive(Debug, Eq)

///|
fn is_wasm_unsupported_compile_error(message : String) -> Bool {
  let lower = message.to_lower()
  (lower.contains("backend '") && lower.contains("' does not support:")) ||
  lower.contains("unsupported:") ||
  lower.contains("handle kind mismatch")
}

///|
fn parse_bench_backend(value : String) -> BenchBackend? {
  match value.trim().to_owned().to_lower() {
    "wasm" | "compiled" => Some(BenchBackend::Wasm)
    _ => None
  }
}

///|
fn parse_bench_backend_or_abort(value : String) -> BenchBackend {
  match parse_bench_backend(value) {
    Some(v) => v
    None =>
      abort("bench: invalid --backend: " + value + " (expected compiled|wasm)")
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
      "-n"
      | "--n"
      | "--warmup"
      | "-e"
      | "--expr"
      | "--case"
      | "--cases"
      | "--runs"
      | "--json"
      | "--json-out" =>
        if i + 1 < args.length() {
          i += if arg == "--json" { 1 } else { 2 }
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
      "-n"
      | "--n"
      | "--warmup"
      | "-b"
      | "--backend"
      | "--case"
      | "--cases"
      | "--runs"
      | "--json"
      | "--json-out" =>
        if i + 1 < args.length() {
          i += if arg == "--json" { 1 } else { 2 }
        } else {
          i += 1
        }
      _ => {
        if !arg.has_prefix("-") {
          saw_path = true
        }
        i += 1
      }
    }
  }
  !saw_path
}

///|
fn parse_bench_cmd_args(
  args : Array[String],
) -> Result[BenchCmdOptions, String] {
  let mut runs = 10
  let mut warmup = 3
  let mut legacy_n : Int? = None
  let paths : Array[String] = []
  let case_filters : Array[String] = []
  let mut backend = BenchBackend::Wasm
  let mut output_json = false
  let mut json_out_path : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--runs" => {
        if i + 1 >= args.length() {
          return Err("bench: missing value for --runs")
        }
        runs = @string.parse_int(args[i + 1]) catch {
          e => return Err("bench: invalid --runs: " + e.to_string())
        }
        i += 2
      }
      "-n" | "--n" => {
        if i + 1 >= args.length() {
          return Err("bench: missing value for --n")
        }
        legacy_n = Some(
          @string.parse_int(args[i + 1]) catch {
            e => return Err("bench: invalid --n: " + e.to_string())
          },
        )
        i += 2
      }
      "--warmup" => {
        if i + 1 >= args.length() {
          return Err("bench: missing value for --warmup")
        }
        warmup = @string.parse_int(args[i + 1]) catch {
          e => return Err("bench: invalid --warmup: " + e.to_string())
        }
        i += 2
      }
      "--case" => {
        if i + 1 >= args.length() {
          return Err("bench: missing value for --case")
        }
        case_filters.push(args[i + 1])
        i += 2
      }
      "-b" | "--backend" => {
        if i + 1 >= args.length() {
          return Err("bench: missing value for --backend")
        }
        backend = parse_bench_backend_or_abort(args[i + 1])
        i += 2
      }
      "--json" => {
        output_json = true
        i += 1
      }
      "--json-out" => {
        if i + 1 >= args.length() {
          return Err("bench: missing value for --json-out")
        }
        output_json = true
        json_out_path = Some(args[i + 1])
        i += 2
      }
      _ =>
        if arg.has_prefix("-") {
          return Err("bench: unknown arg " + arg)
        } else {
          paths.push(arg)
          i += 1
        }
    }
  }
  if runs <= 0 {
    return Err("bench: --runs must be > 0")
  }
  if warmup < 0 {
    return Err("bench: --warmup must be >= 0")
  }
  if paths.length() == 0 {
    return Err("bench: expected <file|dir...>")
  }
  Ok({
    runs,
    warmup,
    legacy_n,
    paths,
    case_filters,
    backend,
    output_json,
    json_out_path,
  })
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
  let options = match parse_bench_cmd_args(args) {
    Ok(v) => v
    Err(err) => abort(err)
  }
  let entry_paths = resolve_bench_entry_paths(options.paths)
  if entry_paths.length() == 0 {
    abort("bench: no bench files found")
  }
  // Legacy mode: if --n is specified without --runs, use old fixed-iteration behavior
  let use_legacy = match options.legacy_n {
    Some(_) => true
    None => false
  }
  let mut failed = false
  let mut total = 0
  let mut passed = 0
  let mut failed_count = 0
  let file_count = entry_paths.length()
  let mut files_failed = 0
  let file_reports : Array[Json] = []
  let mode = if use_legacy { "legacy" } else { "statistical" }
  for entry_path in entry_paths {
    let resolved_entry_path = @loader.resolve_entry_path(entry_path)
    if use_legacy {
      let count = match options.legacy_n {
        Some(n) => n
        None => 1000
      }
      match
        run_bench_blocks_wasm_entry_with_cases(
          resolved_entry_path,
          count,
          options.warmup,
          options.case_filters,
        ) {
        Err(err) => {
          if options.output_json {
            file_reports.push(make_wasm_bench_error_json(entry_path, mode, err))
          } else {
            println("[\{entry_path}] \{err}")
          }
          failed = true
          files_failed += 1
        }
        Ok(report) => {
          let ok = if options.output_json {
            file_reports.push(make_wasm_bench_report_json(entry_path, report))
            report.failed == 0
          } else {
            print_wasm_bench_report(entry_path, report)
          }
          if !ok {
            failed = true
            files_failed += 1
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
          resolved_entry_path,
          options.runs,
          options.warmup,
          options.case_filters,
        ) {
        Err(err) => {
          if options.output_json {
            file_reports.push(make_wasm_bench_error_json(entry_path, mode, err))
          } else {
            println("[\{entry_path}] \{err}")
          }
          failed = true
          files_failed += 1
        }
        Ok(report) => {
          let ok = if options.output_json {
            file_reports.push(
              make_wasm_bench_summary_report_json(entry_path, report),
            )
            report.failed == 0
          } else {
            print_wasm_bench_summary_report(entry_path, report)
          }
          if !ok {
            failed = true
            files_failed += 1
          }
          total += report.total
          passed += report.passed
          failed_count += report.failed
        }
      }
    }
  }
  if options.output_json {
    let root_json = make_cli_bench_report_json(
      mode,
      file_count,
      files_failed,
      total,
      passed,
      failed_count,
      !failed,
      file_reports,
    )
    let json_text = root_json.stringify()
    match write_cli_bench_report_json(options.json_out_path, json_text) {
      Ok(_) => ()
      Err(err) => abort(err)
    }
    println(json_text)
  } else {
    println(
      "summary: files=\{file_count} backend=compiled total=\{total} passed=\{passed} failed=\{failed_count}",
    )
  }
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
    shared_prelude_source: plan.shared_prelude_source,
    local_prelude_source: plan.local_prelude_source,
    setup_source: plan.setup_source,
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
    if !snippet.has_suffix("\n") {
      out.write_char('\n')
    }
  }
  out.to_string()
}

///|
fn is_bench_setup_stmt(stmt : @vibe_core.Stmt) -> Bool {
  match stmt {
    @vibe_core.Stmt::Let(name~, ..)
    | @vibe_core.Stmt::ExportLet(name~, ..)
    | @vibe_core.Stmt::InternalExportLet(name~, ..) => name == "bench_setup"
    _ => false
  }
}

///|
fn can_hoist_bench_prelude_stmt(stmt : @vibe_core.Stmt) -> Bool {
  match stmt {
    @vibe_core.Stmt::Let(..)
    | @vibe_core.Stmt::EnumDef(..)
    | @vibe_core.Stmt::TypeAlias(..)
    | @vibe_core.Stmt::TraitDef(..)
    | @vibe_core.Stmt::TraitImpl(..)
    | @vibe_core.Stmt::ExternLet(..) => true
    _ => false
  }
}

///|
fn extract_bench_source_plan(
  source : String,
) -> Result[BenchSourcePlan, String] {
  let ast = @parser.parse_ast(source) catch {
    e => return Err("parse error: " + e.to_string())
  }
  let import_stmts : Array[@vibe_core.Stmt] = []
  let shared_prelude_stmts : Array[@vibe_core.Stmt] = []
  let local_prelude_stmts : Array[@vibe_core.Stmt] = []
  let setup_stmts : Array[@vibe_core.Stmt] = []
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
      _ =>
        if is_bench_setup_stmt(stmt) {
          setup_stmts.push(stmt)
        } else if can_hoist_bench_prelude_stmt(stmt) {
          shared_prelude_stmts.push(stmt)
        } else {
          local_prelude_stmts.push(stmt)
        }
    }
  }
  let import_source = module_source_from_stmt_spans(source, import_stmts)
  let shared_prelude_source = module_source_from_stmt_spans(
    source, shared_prelude_stmts,
  )
  let local_prelude_source = module_source_from_stmt_spans(
    source, local_prelude_stmts,
  )
  let setup_source = module_source_from_stmt_spans(source, setup_stmts)
  Ok(BenchSourcePlan::{
    import_source,
    shared_prelude_source,
    local_prelude_source,
    setup_source,
    cases,
  })
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
  shared_prelude_source : String,
  local_prelude_source : String,
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
  if shared_prelude_source.length() > 0 {
    out.write_string(shared_prelude_source)
    if !shared_prelude_source.has_suffix("\n") {
      out.write_char('\n')
    }
  }
  out.write_string(
    "export let _start = () -> Int with { Error, Fs, Env, Net, Process, Stdout, Stdin, Time, Random } {\n",
  )
  // Wrap non-import setup in a block so that prelude `let mut` bindings are
  // not at the top level (top-level `let mut` is rejected by the type checker).
  out.write_string("{\n")
  if local_prelude_source.length() > 0 {
    out.write_string(local_prelude_source)
    if !local_prelude_source.has_suffix("\n") {
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
    if !body_source.has_suffix("\n") {
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
fn build_bench_case_setup_script(
  import_source : String,
  shared_prelude_source : String,
  setup_source : String,
  body_source : String,
) -> String {
  let out = StringBuilder::new()
  if import_source.length() > 0 {
    out.write_string(import_source)
    if !import_source.has_suffix("\n") {
      out.write_char('\n')
    }
  }
  if shared_prelude_source.length() > 0 {
    out.write_string(shared_prelude_source)
    if !shared_prelude_source.has_suffix("\n") {
      out.write_char('\n')
    }
  }
  if setup_source.length() > 0 {
    out.write_string(setup_source)
    if !setup_source.has_suffix("\n") {
      out.write_char('\n')
    }
  }
  out.write_string("let __bench_setup_done = [false]\n")
  out.write_string(
    "export let _start = () -> Int with { Error, Fs, Env, Net, Process, Stdout, Stdin, Time, Random } {\n",
  )
  out.write_string("0\n")
  out.write_string("}\n")
  out.write_string(
    "export let _bench_run = () -> Int with { Error, Fs, Env, Net, Process, Stdout, Stdin, Time, Random } {\n",
  )
  out.write_string("{\n")
  out.write_string("if !__bench_setup_done[0] {\n")
  out.write_string("  let _ = bench_setup()\n")
  out.write_string("  __bench_setup_done[0] = true\n")
  out.write_string("}\n")
  if body_source.length() > 0 {
    out.write_string(body_source)
    if !body_source.has_suffix("\n") {
      out.write_char('\n')
    }
  }
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
  if !@os_fs.path_exists(path) {
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
    let token = part_view.trim().to_owned()
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
    let token = flag.trim().to_owned().to_lower()
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
  if !has_wasm_feature_flag(out, "exceptions") {
    out.push("exceptions=y")
  }
  // Enable wasm-gc by default so the same runner can execute either the
  // linear-memory or the GC backend output. wasmtime ignores the flag
  // when the module doesn't use GC types.
  if !has_wasm_feature_flag(out, "gc") {
    out.push("gc=y")
  }
  out
}

///|
fn find_command_in_path(name : String) -> String? {
  match @sys.get_env_var("PATH") {
    None => None
    Some(path_value) => {
      for dir_view in path_value.split(":") {
        let dir = dir_view.trim().to_owned()
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
      let trimmed = value.trim().to_owned()
      if trimmed.length() > 0 {
        return Ok(trimmed)
      }
    }
    None => ()
  }
  let local_release = project_root + "/deps/wasmtime/target/release/wasmtime"
  let local_debug = project_root + "/deps/wasmtime/target/debug/wasmtime"
  let use_submodule = match @sys.get_env_var("VIBE_USE_WASMTIME_SUBMODULE") {
    Some(value) => value.trim().to_owned() == "1"
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
///|
/// Resolve the wasmtime `--invoke` export name for the bench runner.
/// Linear backend emits the CLI-tagged `_vibe_run_tagged` wrapper;
/// wasm-gc backend doesn't (it only emits the user-declared exports +
/// the synthesized `_start`). VIBE_BENCH_BACKEND=gc switches the bench
/// pipeline over, including this entrypoint selection.
fn bench_default_invoke_name() -> String {
  match @sys.get_env_var("VIBE_BENCH_BACKEND") {
    Some("gc") | Some("wasm-gc") => "_start"
    _ => cli_tagged_run_export_name
  }
}

///|
fn run_bench_module(
  runner : BenchWasmRunner,
  entry_path : String,
  wasm_path : String,
  use_node_runner : Bool,
  // Per-mode entry export name. Defaults to `bench_default_invoke_name()`
  // which respects the VIBE_BENCH_BACKEND env var.
  invoke_name? : String = bench_default_invoke_name(),
) -> Result[Unit, String] {
  let tmp_prefix = wasm_path + ".bench_exec"
  let exec_out = if use_node_runner {
    let host_runner = match resolve_http_host_runner(entry_path) {
      Ok(v) => v
      Err(err) => return Err(err)
    }
    // Bench scripts export `_start` (and optional `_bench_run` for setup mode),
    // not the CLI tagged runner entrypoint.
    run_http_host_invoke_run_capture_with_invokes(
      host_runner,
      wasm_path,
      tmp_prefix,
      ["_start"],
    )
  } else {
    run_wasmtime_invoke_named_capture(
      runner, wasm_path, tmp_prefix, invoke_name,
    )
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
fn compile_and_run_bench_file_once(
  runner : BenchWasmRunner,
  db : @runtime.VibeDb,
  entry : String,
  wasm_path : String,
  use_node_runner : Bool,
) -> Result[Int, String] {
  let wasm_bytes = compile_module_wasm_for_exec(
    db,
    entry,
    http_host_imports=use_node_runner,
    fs_host_imports=use_node_runner,
  ) catch {
    e => return Err("compile wasm error: " + e.user_message())
  }
  @os_fs.write_bytes_to_file(wasm_path, wasm_bytes) catch {
    e => return Err("write wasm failed: " + e.to_string())
  }
  match run_bench_module(runner, entry, wasm_path, use_node_runner) {
    Ok(_) => Ok(wasm_bytes.length())
    Err(err) => Err(err)
  }
}

///|
fn build_http_host_bench_command(
  runner : HttpHostRunner,
  wasm_path : String,
  invoke_name : String,
  count : Int,
  warmup : Int,
  setup_invoke : String?,
) -> String {
  let cmd = StringBuilder::new()
  cmd.write_string(shell_quote_command_arg(runner.node_bin))
  for flag in runner.node_flags {
    cmd.write_string(" ")
    cmd.write_string(shell_quote_command_arg(flag))
  }
  cmd.write_string(" ")
  cmd.write_string(shell_quote_command_arg(runner.runner_script))
  cmd.write_string(" --invoke ")
  cmd.write_string(shell_quote_command_arg(invoke_name))
  cmd.write_string(" --bench-count ")
  cmd.write_string(shell_quote_command_arg(count.to_string()))
  cmd.write_string(" --bench-warmup ")
  cmd.write_string(shell_quote_command_arg(warmup.to_string()))
  match setup_invoke {
    Some(name) => {
      cmd.write_string(" --bench-setup ")
      cmd.write_string(shell_quote_command_arg(name))
    }
    None => ()
  }
  cmd.write_string(" ")
  cmd.write_string(shell_quote_command_arg(wasm_path))
  cmd.to_string()
}

///|
fn parse_http_host_bench_elapsed_us(stdout : String) -> Result[Double, String] {
  let text = stdout.trim().to_owned()
  let parsed : Result[Double, Error] = try? @string.parse_double(text)
  match parsed {
    Ok(value) => Ok(value)
    Err(_) => Err("invalid node host bench output: " + text)
  }
}

///|
fn run_http_host_bench_measure(
  runner : HttpHostRunner,
  wasm_path : String,
  tmp_prefix : String,
  invoke_name : String,
  count : Int,
  warmup : Int,
  setup_invoke : String?,
) -> Result[Double, String] {
  let out_path = tmp_prefix + ".out"
  let err_path = tmp_prefix + ".err"
  let cmd = build_http_host_bench_command(
      runner, wasm_path, invoke_name, count, warmup, setup_invoke,
    ) +
    " >" +
    shell_quote_command_arg(out_path) +
    " 2>" +
    shell_quote_command_arg(err_path)
  let status = c_system(system_command_bytes(cmd))
  let stdout = @os_fs.read_file_to_string(out_path) catch { _ => "" }
  let stderr = @os_fs.read_file_to_string(err_path) catch { _ => "" }
  remove_file_if_exists(out_path)
  remove_file_if_exists(err_path)
  if status != 0 {
    return Err(
      "node host runner command failed: status=" +
      status.to_string() +
      " detail=" +
      wasmtime_failure_detail(stdout, stderr),
    )
  }
  parse_http_host_bench_elapsed_us(stdout)
}

///|
/// Resolve a binaryen wasm-opt binary to shell out to. Prefer the
/// moon-bundled `~/.moon/bin/moon-wasm-opt` (always compatible with
/// moon-emitted wasm); fall back to PATH `wasm-opt` IF its version
/// parses as >= 118 (Ubuntu's apt v108 and `cargo install wasm-opt`'s
/// v116 cannot parse moonbit wasm — see
/// `bench/selfhost_perf/README.md`).
/// Returns None when no usable binary is on the system.
fn resolve_wasm_opt_bin_for_bench() -> String? {
  let moon_home = match @sys.get_env_var("MOON_HOME") {
    Some(v) => v
    None =>
      match @sys.get_env_var("HOME") {
        Some(h) => h + "/.moon"
        None => "/root/.moon"
      }
  }
  let bundled = moon_home + "/bin/moon-wasm-opt"
  if @os_fs.path_exists(bundled) {
    return Some(bundled)
  }
  // Probe PATH `wasm-opt`. Run `wasm-opt --version` and require >= 118.
  // exec_command_lines returns a Result (does not raise) — pattern-match
  // instead of using catch.
  let probe = match
    @backend.exec_command_lines("command -v wasm-opt 2>/dev/null") {
    Ok(lines) => lines
    Err(_) => return None
  }
  if probe.length() == 0 || probe[0].trim().to_owned() == "" {
    return None
  }
  let version_lines = match
    @backend.exec_command_lines("wasm-opt --version 2>&1 | head -n 1") {
    Ok(lines) => lines
    Err(_) => return None
  }
  if version_lines.length() == 0 {
    return None
  }
  // Match e.g. "wasm-opt version 122 (version_122)" — pick the first
  // bare integer in the line.
  let line = version_lines[0]
  let mut digits = ""
  let mut in_digits = false
  for ch in line {
    if ch >= '0' && ch <= '9' {
      digits = digits + ch.to_string()
      in_digits = true
    } else if in_digits {
      break
    }
  }
  if digits.length() == 0 {
    return None
  }
  let version = @string.parse_int(digits) catch { _ => return None }
  if version < 118 {
    return None
  }
  Some("wasm-opt")
}

///|
/// Pipe `bytes` through binaryen `wasm-opt $opt_level` via popen; on
/// any error or missing binary return None so callers can fall back to
/// the in-process @wite optimizer.
fn try_wasm_opt_shell_out(
  bytes : Bytes,
  opt_level : String,
  scratch_path : String,
) -> Bytes? {
  let bin = match resolve_wasm_opt_bin_for_bench() {
    Some(v) => v
    None => return None
  }
  let tmp_in = scratch_path + ".wopt-in.wasm"
  let tmp_out = scratch_path + ".wopt-out.wasm"
  @os_fs.write_bytes_to_file(tmp_in, bytes) catch {
    _ => return None
  }
  // Same feature flag set as scripts/build_selfhost_wasi_opt.sh — these
  // are the moonbit wasm features the binary can use.
  let cmd = bin +
    " " +
    opt_level +
    " --enable-gc --enable-reference-types --enable-bulk-memory" +
    " --enable-multivalue --enable-tail-call --enable-exception-handling" +
    " --enable-nontrapping-float-to-int --enable-sign-ext" +
    " --enable-mutable-globals " +
    tmp_in +
    " -o " +
    tmp_out +
    " 2>/dev/null"
  match @backend.exec_command_lines(cmd) {
    Ok(_) => ()
    Err(_) => return None
  }
  let out_bytes = @os_fs.read_file_to_bytes(tmp_out) catch { _ => return None }
  // Best-effort cleanup; ignore failures.
  ignore(@os_fs.remove_file(tmp_in) catch { _ => () })
  ignore(@os_fs.remove_file(tmp_out) catch { _ => () })
  Some(out_bytes)
}

///|
fn compile_bench_script_to_wasm(
  entry_path : String,
  script_kind : String,
  source : String,
) -> Result[(String, Int, Bool), String] {
  compile_bench_script_to_wasm_with_runner(
    entry_path, script_kind, source, false,
  )
}

///|
fn compile_bench_script_to_wasm_with_runner(
  entry_path : String,
  script_kind : String,
  source : String,
  force_node_runner : Bool,
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
  let use_node_runner = force_node_runner ||
    use_http_host_runner ||
    use_fs_host_runner
  // Resolve backend selection early so it can feed into both the cache
  // mode tag and the compile path below.
  let bench_backend_gc_requested = match
    @sys.get_env_var("VIBE_BENCH_BACKEND") {
    Some("gc") | Some("wasm-gc") => true
    _ => false
  }
  let bench_backend_gc = bench_backend_gc_requested && !use_node_runner
  let cached_hash_path = wasm_path + ".hashes"
  let cached_mode_path = wasm_path + ".mode"
  let current_hashes = collect_source_hash_cache(db, entry, true)
  // Include the backend selection in the mode tag so the cache doesn't
  // serve a linear-backend wasm to a gc-backend bench (or vice versa).
  let backend_suffix = if bench_backend_gc { ":gc" } else { "" }
  let current_mode = (if use_node_runner { "host" } else { "plain" }) +
    backend_suffix
  let has_cached_hashes = @os_fs.path_exists(cached_hash_path)
  let cached_mode_matches = if @os_fs.path_exists(cached_mode_path) {
    let saved_mode = @os_fs.read_file_to_string(cached_mode_path) catch {
      _ => ""
    }
    saved_mode.trim().to_owned() == current_mode
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
  // Default keeps no_dce=true (bench bodies may reach for things DCE
  // would prune); VIBE_BENCH_NO_DCE=0 opts into DCE so heavy probe
  // imports (entire selfhost compiler tree) compile in reasonable
  // time. See `bench/selfhost_perf/README.md` postmortem.
  let bench_no_dce = match @sys.get_env_var("VIBE_BENCH_NO_DCE") {
    Some(v) => !(v == "0" || v.to_lower() == "false" || v.to_lower() == "off")
    None => true
  }
  // debug_errors=true keeps throw string literals in the output, but the
  // codegen path that does this scales pathologically on throw-heavy
  // imports (selfhost compiler imports through loader_hotspot_probe.vibe
  // hung > 3 min before timeout in our investigation). Default stays
  // true to match `vibe run` behaviour; VIBE_BENCH_DEBUG_ERRORS=0
  // opts out for selfhost benches at the cost of less helpful failure
  // messages from `throw` inside the bench body.
  let bench_debug_errors = match @sys.get_env_var("VIBE_BENCH_DEBUG_ERRORS") {
    Some(v) => !(v == "0" || v.to_lower() == "false" || v.to_lower() == "off")
    None => true
  }
  // `vibe compile -Oz` runs the in-process `@wite.optimize_binary_for_size`
  // pass (NOT the binaryen wasm-opt CLI). That MoonBit-implemented size
  // optimizer is pathological on no-DCE 4-5 MB selfhost wasm — a single
  // -Oz pass on a selfhost-import bench file hangs 4+ minutes vs ~5
  // seconds for the equivalent binaryen `wasm-opt -Oz`. So we shell out
  // to binaryen here when a usable binary is on the system: prefer
  // `~/.moon/bin/moon-wasm-opt` (always compatible with moon-emitted
  // wasm), fall back to PATH `wasm-opt` only if it's binaryen >= 118.
  // If neither is available, fall back to in-process @wite (current
  // pathological behavior, but preserved for compat).
  // VIBE_BENCH_OPT_LEVEL=none skips optimization entirely (raw wasm).
  let bench_opt_level = match @sys.get_env_var("VIBE_BENCH_OPT_LEVEL") {
    Some("none") | Some("None") | Some("") => None
    Some(level) => Some(level)
    None => Some("-Oz")
  }
  // Backend selection (`bench_backend_gc`) was resolved earlier so the
  // cache-mode tag could include it.
  // Step 1: produce the raw wasm with no in-process optimization.
  let raw_bytes = if bench_backend_gc {
    @runtime_compile.compile_module_wasm_gc(db, entry) catch {
      e => return Err("compile wasm-gc error: " + e.user_message())
    }
  } else if use_node_runner {
    @runtime_compile.compile_module_wasm_with_opt_level(
      db,
      entry,
      no_dce=bench_no_dce,
      opt_level=None,
      // Preserve thrown string payloads for host-runner parity with `run`.
      debug_errors=bench_debug_errors,
      http_host_imports=true,
      fs_host_imports=true,
    ) catch {
      e => return Err("compile wasm error: " + e.user_message())
    }
  } else {
    @runtime_compile.compile_module_wasm_with_opt_level(
      db,
      entry,
      no_dce=bench_no_dce,
      opt_level=None,
    ) catch {
      e => return Err("compile wasm error: " + e.user_message())
    }
  }
  // Step 2: optionally optimize. Try shell-out first; on failure fall
  // back to in-process @wite (which is what `vibe compile -Oz` does).
  // wasm-gc output is intentionally NOT optimized — moon-bundled
  // `moon-wasm-opt` mishandles gc types (it dropped the entire bench
  // body down to `i64.const 15` in early experiments), and the
  // in-process @wite optimizer has no gc code path either. Keep the
  // raw bytes; user-visible perf is the codegen quality of the gc
  // backend itself, which is what we want to measure.
  let wasm_bytes = if bench_backend_gc {
    raw_bytes
  } else {
    match bench_opt_level {
    None => raw_bytes
    Some(level) =>
      match try_wasm_opt_shell_out(raw_bytes, level, wasm_path) {
        Some(opt) => opt
        None =>
          if use_node_runner {
            @runtime_compile.compile_module_wasm_with_opt_level(
              db,
              entry,
              no_dce=bench_no_dce,
              opt_level=Some(level),
              debug_errors=bench_debug_errors,
              http_host_imports=true,
              fs_host_imports=true,
            ) catch {
              _ => raw_bytes
            }
          } else {
            @runtime_compile.compile_module_wasm_with_opt_level(
              db,
              entry,
              no_dce=bench_no_dce,
              opt_level=Some(level),
            ) catch {
              _ => raw_bytes
            }
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
  shared_prelude_source : String,
  local_prelude_source : String,
  setup_source : String,
  case_body_source : String,
  count : Int,
  warmup : Int,
) -> Result[WasmBenchResult, WasmBenchFailure] {
  let has_setup = setup_source.length() > 0
  let measured = if has_setup {
    if local_prelude_source.length() > 0 {
      Err(
        "bench setup requires hoistable top-level prelude only; found local prelude statements",
      )
    } else {
      let run_source = build_bench_case_setup_script(
        import_source, shared_prelude_source, setup_source, case_body_source,
      )
      match
        compile_bench_script_to_wasm_with_runner(
          entry_path,
          "setup_run_" + case_index.to_string(),
          run_source,
          true,
        ) {
        Ok((run_wasm_path, wasm_bytes, use_node_runner)) =>
          if !use_node_runner {
            Err("bench setup requires node host runner")
          } else {
            let host_runner = match resolve_http_host_runner(entry_path) {
              Ok(v) => v
              Err(err) =>
                return Err(WasmBenchFailure::{ name: case_name, error: err })
            }
            match
              run_http_host_bench_measure(
                host_runner,
                run_wasm_path,
                run_wasm_path + ".bench_setup",
                "_bench_run",
                count,
                warmup + 1,
                None,
              ) {
              Ok(elapsed_us) =>
                Ok(
                  (
                    elapsed_us / 1000.0,
                    elapsed_us / count.to_double(),
                    wasm_bytes,
                  ),
                )
              Err(err) => Err(err)
            }
          }
        Err(err) => Err("compile failed: " + err)
      }
    }
  } else {
    let warm_source = build_bench_case_loop_script(
      import_source, shared_prelude_source, local_prelude_source, case_body_source,
      warmup,
    )
    let run_source = build_bench_case_loop_script(
      import_source, shared_prelude_source, local_prelude_source, case_body_source,
      count,
    )
    if warmup > 0 {
      match
        compile_bench_script_to_wasm(
          entry_path,
          "warm_" + case_index.to_string() + "_" + warmup.to_string(),
          warm_source,
        ) {
        Ok((warm_wasm_path, _, use_node_runner)) =>
          match
            run_bench_module(
              runner, entry_path, warm_wasm_path, use_node_runner,
            ) {
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
        plan.shared_prelude_source,
        plan.local_prelude_source,
        plan.setup_source,
        case_body_source,
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
    let has_setup = plan.setup_source.length() > 0
    // Auto-calibrate: try increasing batch sizes until ~100ms
    let threshold_us = 100000.0
    let mut batch_size = 1
    let mut calibration_ok = true
    let samples : Array[Double] = []
    let (run_wasm_path, wasm_bytes, use_node_runner) = if has_setup {
      if plan.local_prelude_source.length() > 0 {
        failures.push(WasmBenchFailure::{
          name: case_name,
          error: "bench setup requires hoistable top-level prelude only; found local prelude statements",
        })
        continue
      }
      let run_source = build_bench_case_setup_script(
        plan.import_source,
        plan.shared_prelude_source,
        plan.setup_source,
        case_body_source,
      )
      match
        compile_bench_script_to_wasm_with_runner(
          entry_path,
          "stat_setup_" + case_index.to_string(),
          run_source,
          true,
        ) {
        Ok(v) => v
        Err(err) => {
          failures.push(WasmBenchFailure::{
            name: case_name,
            error: "compile failed: " + err,
          })
          continue
        }
      }
    } else {
      let mut trial = 1
      while true {
        let cal_source = build_bench_case_loop_script(
          plan.import_source,
          plan.shared_prelude_source,
          plan.local_prelude_source,
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
          run_bench_module(
            runner, entry_path, cal_wasm_path, cal_use_node_runner,
          ) {
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
      if !calibration_ok {
        continue
      }
      let run_source = build_bench_case_loop_script(
        plan.import_source,
        plan.shared_prelude_source,
        plan.local_prelude_source,
        case_body_source,
        batch_size,
      )
      let run_script_kind = "stat_run_" +
        case_index.to_string() +
        "_" +
        batch_size.to_string()
      match
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
    }
    if has_setup {
      if !use_node_runner {
        failures.push(WasmBenchFailure::{
          name: case_name,
          error: "bench setup requires node host runner",
        })
        continue
      }
      let host_runner = match resolve_http_host_runner(entry_path) {
        Ok(v) => v
        Err(err) => {
          failures.push(WasmBenchFailure::{ name: case_name, error: err })
          continue
        }
      }
      let mut trial = 1
      while true {
        let elapsed_us = match
          run_http_host_bench_measure(
            host_runner,
            run_wasm_path,
            run_wasm_path + ".stat_cal",
            "_bench_run",
            trial,
            1,
            None,
          ) {
          Ok(v) => v
          Err(err) => {
            failures.push(WasmBenchFailure::{
              name: case_name,
              error: "calibration run failed: " + err,
            })
            calibration_ok = false
            break
          }
        }
        let single_us = elapsed_us / trial.to_double()
        if trial.to_double() * single_us > threshold_us {
          let target = threshold_us /
            (if single_us < 1.0 { 1.0 } else { single_us })
          batch_size = if target < 1.0 { 1 } else { target.ceil().to_int() }
          break
        }
        trial = trial * 2
      }
      if !calibration_ok {
        continue
      }
      let mut sample_ok = true
      for _ in 0..<runs {
        let elapsed_us = match
          run_http_host_bench_measure(
            host_runner,
            run_wasm_path,
            run_wasm_path + ".stat_run",
            "_bench_run",
            batch_size,
            warmup + 1,
            None,
          ) {
          Ok(v) => v
          Err(err) => {
            failures.push(WasmBenchFailure::{
              name: case_name,
              error: "measurement run failed: " + err,
            })
            sample_ok = false
            break
          }
        }
        samples.push(elapsed_us / batch_size.to_double())
      }
      if !sample_ok {
        continue
      }
    } else {
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
      if !warmup_ok {
        continue
      }
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
      if !sample_ok {
        continue
      }
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
fn bench_case_name_or_anon(name : String?) -> String {
  match name {
    Some(v) => v
    None => "<anon>"
  }
}

///|
fn make_wasm_bench_failure_json(failure : WasmBenchFailure) -> Json {
  let obj : Map[String, Json] = {}
  obj["name"] = Json::string(bench_case_name_or_anon(failure.name))
  obj["error"] = Json::string(failure.error)
  Json::object(obj)
}

///|
fn make_wasm_bench_result_json(result : WasmBenchResult) -> Json {
  let obj : Map[String, Json] = {}
  obj["name"] = Json::string(bench_case_name_or_anon(result.name))
  obj["iterations"] = Json::number(result.iterations.to_double())
  obj["warmup"] = Json::number(result.warmup.to_double())
  obj["elapsed_ms"] = Json::number(result.elapsed_ms)
  obj["per_us"] = Json::number(result.per_us)
  obj["wasm_bytes"] = Json::number(result.wasm_bytes.to_double())
  Json::object(obj)
}

///|
fn make_wasm_bench_summary_json(result : @runtime.BenchSummary) -> Json {
  let (q1, q2, q3) = result.quartiles
  let quartiles : Array[Json] = [
    Json::number(q1),
    Json::number(q2),
    Json::number(q3),
  ]
  let obj : Map[String, Json] = {}
  obj["name"] = Json::string(bench_case_name_or_anon(result.name))
  obj["runs"] = Json::number(result.runs.to_double())
  obj["batch_size"] = Json::number(result.batch_size.to_double())
  obj["min"] = Json::number(result.min)
  obj["max"] = Json::number(result.max)
  obj["mean"] = Json::number(result.mean)
  obj["median"] = Json::number(result.median)
  obj["std_dev"] = Json::number(result.std_dev)
  obj["std_dev_pct"] = Json::number(result.std_dev_pct)
  obj["median_abs_dev"] = Json::number(result.median_abs_dev)
  obj["median_abs_dev_pct"] = Json::number(result.median_abs_dev_pct)
  obj["quartiles"] = Json::array(quartiles)
  obj["iqr"] = Json::number(result.iqr)
  obj["wasm_bytes"] = Json::number(result.wasm_bytes.to_double())
  Json::object(obj)
}

///|
fn make_wasm_bench_report_json(path : String, report : WasmBenchReport) -> Json {
  let results : Array[Json] = []
  let failures : Array[Json] = []
  for result in report.results {
    results.push(make_wasm_bench_result_json(result))
  }
  for failure in report.failures {
    failures.push(make_wasm_bench_failure_json(failure))
  }
  let obj : Map[String, Json] = {}
  obj["file"] = Json::string(path)
  obj["mode"] = Json::string("legacy")
  obj["ok"] = Json::boolean(report.failed == 0)
  obj["total"] = Json::number(report.total.to_double())
  obj["passed"] = Json::number(report.passed.to_double())
  obj["failed"] = Json::number(report.failed.to_double())
  obj["results"] = Json::array(results)
  obj["failures"] = Json::array(failures)
  Json::object(obj)
}

///|
fn make_wasm_bench_summary_report_json(
  path : String,
  report : WasmBenchSummaryReport,
) -> Json {
  let results : Array[Json] = []
  let failures : Array[Json] = []
  for result in report.results {
    results.push(make_wasm_bench_summary_json(result))
  }
  for failure in report.failures {
    failures.push(make_wasm_bench_failure_json(failure))
  }
  let obj : Map[String, Json] = {}
  obj["file"] = Json::string(path)
  obj["mode"] = Json::string("statistical")
  obj["ok"] = Json::boolean(report.failed == 0)
  obj["total"] = Json::number(report.total.to_double())
  obj["passed"] = Json::number(report.passed.to_double())
  obj["failed"] = Json::number(report.failed.to_double())
  obj["results"] = Json::array(results)
  obj["failures"] = Json::array(failures)
  Json::object(obj)
}

///|
fn make_wasm_bench_error_json(
  path : String,
  mode : String,
  error : String,
) -> Json {
  let obj : Map[String, Json] = {}
  obj["file"] = Json::string(path)
  obj["mode"] = Json::string(mode)
  obj["ok"] = Json::boolean(false)
  obj["total"] = Json::number(0.0)
  obj["passed"] = Json::number(0.0)
  obj["failed"] = Json::number(1.0)
  obj["results"] = Json::array([])
  obj["failures"] = Json::array([
    Json::object({
      "name": Json::string("<file>"),
      "error": Json::string(error),
    }),
  ])
  Json::object(obj)
}

///|
fn make_cli_bench_report_json(
  mode : String,
  file_count : Int,
  files_failed : Int,
  total : Int,
  passed : Int,
  failed : Int,
  ok : Bool,
  files : Array[Json],
) -> Json {
  let obj : Map[String, Json] = {}
  obj["cmd"] = Json::string("bench")
  obj["backend"] = Json::string("compiled")
  obj["mode"] = Json::string(mode)
  obj["ok"] = Json::boolean(ok)
  obj["file_count"] = Json::number(file_count.to_double())
  obj["files_passed"] = Json::number((file_count - files_failed).to_double())
  obj["files_failed"] = Json::number(files_failed.to_double())
  obj["total"] = Json::number(total.to_double())
  obj["passed"] = Json::number(passed.to_double())
  obj["failed"] = Json::number(failed.to_double())
  obj["files"] = Json::array(files)
  Json::object(obj)
}

///|
fn write_cli_bench_report_json(
  json_out_path : String?,
  json_text : String,
) -> Result[Unit, String] {
  match json_out_path {
    None => Ok(())
    Some(path) => {
      match ensure_parent_dir_for_file(path, "bench json") {
        Ok(_) => ()
        Err(err) => return Err("bench: json output dir failed: " + err)
      }
      @os_fs.write_string_to_file(path, json_text) catch {
        e => return Err("bench: write --json-out failed: " + e.to_string())
      }
      Ok(())
    }
  }
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
  _features : @runtime.RuntimeFeatureFlags,
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
        count = @string.parse_int(args[i + 1]) catch {
          e => abort("bench-file: invalid --n: " + e.to_string())
        }
        i += 2
      }
      "--warmup" => {
        if i + 1 >= args.length() {
          abort("bench-file: missing value for --warmup")
        }
        warmup = @string.parse_int(args[i + 1]) catch {
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
      let runner = match resolve_bench_wasm_runner(path) {
        Ok(v) => v
        Err(err) => abort("bench-file: " + err)
      }
      let (db, entry) = match load_entry_db(path) {
        Err(err) => abort("bench-file: " + err)
        Ok(v) => v
      }
      let (use_http_host_runner, use_fs_host_runner) = detect_exec_host_runner_requirements(
        db, entry,
      )
      let use_node_runner = use_http_host_runner || use_fs_host_runner
      let wasm_path = @vibe_fs.parent_path(entry) + "/.vibe_bench_file.wasm"
      defer remove_file_if_exists(wasm_path)
      let mut wasm_bytes = 0
      for _ in 0..<warmup {
        let compiled_bytes = match
          compile_and_run_bench_file_once(
            runner, db, entry, wasm_path, use_node_runner,
          ) {
          Ok(v) => v
          Err(err) => abort("bench-file: " + err)
        }
        wasm_bytes = compiled_bytes
      }
      let start = @bench.monotonic_clock_start()
      for _ in 0..<count {
        let compiled_bytes = match
          compile_and_run_bench_file_once(
            runner, db, entry, wasm_path, use_node_runner,
          ) {
          Ok(v) => v
          Err(err) => abort("bench-file: " + err)
        }
        wasm_bytes = compiled_bytes
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
        per_us.to_string() +
        " wasm_bytes=" +
        wasm_bytes.to_string(),
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
