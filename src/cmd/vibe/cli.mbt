///|
/// CLI entry logic for vibe
pub fn run(args : Array[String]) -> Unit {
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
    "eval" => eval_cmd(cmd_args, syntax_mode, runtime_features, enable_llm~)
    "test" => test_cmd(cmd_args, runtime_features)
    "check" => check_cmd(cmd_args)
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
    "precompile" => precompile_cmd(cmd_args)
    "bench" => bench_cmd(cmd_args, syntax_mode, runtime_features)
    "bench-file" => bench_file_cmd(cmd_args, runtime_features)
    "shell" => repl_cmd(cmd_args, syntax_mode, runtime_features, enable_llm~)
    "shell-stdin" =>
      repl_stdin_cmd(cmd_args, syntax_mode, runtime_features, enable_llm~)
    "shell-wasi" =>
      repl_wasi_cmd(cmd_args, syntax_mode, runtime_features, enable_llm~)
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
    "bundle" => bundle_cmd(cmd_args)
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
    "  eval [--db file] [--include file] [--inspect-scope] [--assert name:sig]... [--test-for name] [--run] [--export file] <expr...>  evaluate expression/script",
  )
  println(
    "       include resolution: relative paths use cwd first, then --db parent",
  )
  println("       --run without --test-for prints detected target candidates")
  println(
    "  test [--jobs N] <file|dir...>  run test blocks (parallel for dirs; default jobs=VIBE_TEST_JOBS or 1, max 16)",
  )
  println("  check <file...>            parse/type check scripts")
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
    "  precompile [--out-dir dir] [--wasm|--wasm-js-string] [-O<level>] <dir...>",
  )
  println(
    "                                     precompile .vibe modules to .wasm",
  )
  println(
    "  bench [--backend wasm|interpreter] [--n N] [--warmup N] <file|dir...>  run `bench {}` blocks",
  )
  println(
    "        (legacy expr mode: --expr EXPR | --case NAME=EXPR | --cases FILE)",
  )
  println("  bench-file [--n N] [--warmup N] <file>")
  println("  shell                       interactive TUI shell")
  println(
    "  shell-stdin [--no-prompt] [--tty|--no-tty]  read-eval-print loop (stdin)",
  )
  println(
    "  shell-wasi [--no-prompt] [--tty|--no-tty]   wasi-friendly line shell",
  )
  println(
    "  wasm-shell-stdin [--no-prompt] [-o dir]  compile each expr to WASM",
  )
  println("  hash <file>                 compute normalized AST hash")
  println(
    "  save <file>                 save module to content-addressed store",
  )
  println(
    "  fetch <file>                resolve imports and sync lock payload (index.lock + index.vbundle)",
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
  println(
    "  bundle <pack|verify|inspect|cat|migrate|sync> ...  vbundle distribution utilities",
  )
  println("  lsp                         start LSP server (stdin/stdout)")
  println(
    "  parser commands: --syntax vibe|posix-ext|posix-strict (default: vibe; posix=posix-ext; posix profiles are shell/shell-stdin/shell-wasi only)",
  )
  println("  runtime flags: --unstable-async --unstable-threads")
  println(
    "  exec backend env: VIBE_RUN_BACKEND/VIBE_TEST_BACKEND=compiled|interpreter|auto (default auto=compiled path)",
  )
  println(
    "                    VIBE_ALLOW_INTERPRETER_FALLBACK=1 enables fallback only when backend=auto",
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
    | "eval"
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
    | "shell-wasi"
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
            app_bytes,
            adapter_bytes,
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
  Interpreter
  Compiled
} derive(Eq, Show)

///|
fn parse_cli_exec_backend_pref(raw : String) -> CliExecBackendPref {
  let value = raw.trim().to_string().to_lower()
  match value {
    "interp" | "interpreter" => CliExecBackendPref::Interpreter
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
fn cli_allow_interpreter_fallback() -> Bool {
  match @sys.get_env_var("VIBE_ALLOW_INTERPRETER_FALLBACK") {
    Some(raw) => parse_bool_flag(raw)
    None => false
  }
}

///|
fn cli_can_fallback_to_interpreter(backend_pref : CliExecBackendPref) -> Bool {
  backend_pref == CliExecBackendPref::Auto && cli_allow_interpreter_fallback()
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
  let out_path = tmp_prefix + ".out"
  let err_path = tmp_prefix + ".err"
  let cmd = build_wasmtime_bench_command(runner, wasm_path) +
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
  " --invoke run " +
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
    "http_request"
    | "http_response_status"
    | "http_response_header"
    | "http_response_body"
    | "http_close"
    | "http_listen"
    | "http_accept"
    | "http_request_method"
    | "http_request_url"
    | "http_request_header"
    | "http_request_body"
    | "http_respond" => true
    _ => false
  }
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
    @vibe_core.Expr::Raise(value~, ..) => expr_uses_http_builtins(value)
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
fn run_cmd_wasm_backend(entry_path : String) -> Result[WasmRunValue, String] {
  let (db, entry) = match @loader.load_db(entry_path) {
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
  let wasm_bytes = compile_module_wasm_for_exec(
    db,
    entry,
    http_host_imports=use_http_host_runner,
  ) catch {
    e => return Err("compile wasm error: " + e.user_message())
  }
  let parent = @vibe_fs.parent_path(entry)
  let stamp = @env.now().to_string() + "_" + vibe_getpid().to_string()
  let wasm_path = parent + "/.vibe_run_wasm_" + stamp + ".wasm"
  @os_fs.write_bytes_to_file(wasm_path, wasm_bytes) catch {
    e => return Err("write wasm failed: " + e.to_string())
  }
  defer remove_file_if_exists(wasm_path)
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
  features : @runtime.RuntimeFeatureFlags,
  enable_llm~ : Bool,
) -> Unit {
  if args.length() != 1 {
    abort("run: expected <file>")
  }
  let entry_path = args[0]
  match syntax_mode {
    @runtime.ParserMode::VibeMode => {
      let backend_pref = resolve_cli_exec_backend_pref_for_entry(
        "VIBE_RUN_BACKEND", entry_path,
      )
      let allow_interpreter_fallback = cli_can_fallback_to_interpreter(
        backend_pref,
      )
      if backend_pref != CliExecBackendPref::Interpreter {
        match run_cmd_wasm_backend(entry_path) {
          Ok(result) => {
            print_wasm_run_value(result)
            return
          }
          Err(err) => {
            if backend_pref == CliExecBackendPref::Compiled ||
              not(allow_interpreter_fallback) {
              die("error: run wasm backend: " + err)
            }
            println(
              "warning: run wasm backend failed; falling back to interpreter (VIBE_ALLOW_INTERPRETER_FALLBACK=1): " +
              err,
            )
          }
        }
      }
      match @loader.load_db(entry_path) {
        Err(err) => die("error: " + err)
        Ok((db, entry)) => {
          let compiled = @runtime_compile.compile_module(db, entry) catch {
            e => die("error: " + e.to_string())
          }
          let rt = new_cli_runtime(features, enable_llm~)
          rt.set_type_env(compiled.type_env)
          // Build path-to-hash mapping and load imported modules into runtime cache
          let path_to_hash : Map[String, String] = {}
          load_imports_into_runtime(rt, db, entry, path_to_hash)
          // Also add mappings for raw paths from the AST
          let base_dir = @vibe_fs.parent_path(entry)
          for stmt in compiled.ast.stmts {
            match stmt {
              @vibe_core.Stmt::Import(source~, ..)
              | @vibe_core.Stmt::ReExport(source~, ..) =>
                match source {
                  @vibe_core.ModuleRef::Path(path=raw_path) => {
                    // Resolve the path to find the hash
                    let resolved = @loader.resolve_import_path(
                      base_dir, raw_path,
                    )
                    match path_to_hash.get(resolved) {
                      Some(hash) => path_to_hash[raw_path] = hash
                      None => ()
                    }
                  }
                  @vibe_core.ModuleRef::Hash(_)
                  | @vibe_core.ModuleRef::Version(_)
                  | @vibe_core.ModuleRef::Symbol(_) => ()
                }
              _ => ()
            }
          }
          // Convert the AST's import paths to hashes
          let converted_ast = @vibe_core.convert_imports_to_hash(compiled.ast, fn(
            path,
          ) {
            path_to_hash.get(path)
          })
          // Set aliases
          for name, target in compiled.aliases {
            rt.set_alias(name, target)
          }
          // Check top-level purity
          @checker.check_toplevel_purity(compiled.type_env, converted_ast.stmts) catch {
            e => die("error: " + e.diagnostic().message)
          }
          // Load top-level definitions into runtime
          let _ = rt.eval_module(converted_ast) catch {
            e => die("error: " + e.user_message())
          }
          // Execute main entry point
          let main_result = rt.call_main() catch {
            e => die("error: " + e.user_message())
          }
          print_eval_result(main_result)
        }
      }
    }
    @runtime.ParserMode::PosixMode | @runtime.ParserMode::PosixStrictMode => {
      let resolved = @loader.resolve_entry_path(entry_path)
      let source = @os_fs.read_file_to_string(resolved) catch {
        e => die("error: " + e.to_string())
      }
      let rt = new_cli_runtime(features, enable_llm~)
      let result = rt.eval_script_with_mode(source, syntax_mode) catch {
        e => die("error: " + e.user_message())
      }
      print_eval_result(result)
    }
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
fn check_cmd(args : Array[String]) -> Unit {
  if args.length() == 0 {
    abort("check: expected <file...>")
  }
  let check_debug = check_debug_enabled()
  let mut total_errors = 0
  for entry_path in args {
    if check_debug {
      println("[check_debug] resolving: \{entry_path}")
    }
    match resolve_entry_artifacts(entry_path, skip_types=true) {
      Err(err) => {
        println("check: \{entry_path}: \{err}")
        total_errors += 1
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
                println("check: \{entry_path}: \{e}")
                total_errors += 1
                continue
              }
            }
        }
        if check_debug {
          println("[check_debug] starting db.types: \{entry}")
        }
        let _env = db.types(entry)
        if check_debug {
          println("[check_debug] finished db.types: \{entry}")
        }
        // Show dependency diagnostics first (root cause priority)
        let dep_imports = db.imports(entry)
        for imp in dep_imports {
          let dep_diags = db.diagnostics(imp.path)
          if dep_diags.length() > 0 {
            let dep_source = match db.get_source(imp.path) {
              Some(v) => v
              None => ""
            }
            for dep_diag in dep_diags {
              println(dep_diag.render(imp.path, dep_source))
            }
          }
        }
        let diags = db.diagnostics(entry)
        for diag in diags {
          println(diag.render(entry_path, source))
        }
        let warnings = db.warnings(entry)
        for warning in warnings {
          println(warning.render(entry_path, source))
        }
        let layering_violations = std_layering_violations_for_source(
          entry, source,
        )
        for violation in layering_violations {
          println("check: \{entry_path}: \{violation}")
        }
        if diags.length() == 0 && warnings.length() == 0 {
          println("\{entry_path}: ok (graph_head=\{short_hash(graph_head)})")
        }
        total_errors += diags.length()
        total_errors += layering_violations.length()
      }
    }
  }
  if total_errors > 0 {
    abort("check: \{total_errors} error(s) found")
  }
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
fn build_compiled_test_case_source(
  prelude_source : String,
  body_source : String,
) -> String {
  let out = StringBuilder::new()
  if prelude_source.trim().to_string().length() > 0 {
    out.write_string(prelude_source)
    if not(prelude_source.has_suffix("\n")) {
      out.write_char('\n')
    }
  }
  out.write_string("let main = () -> Int with { Error } {\n")
  if body_source.trim().to_string().length() > 0 {
    out.write_string(body_source)
    if not(body_source.has_suffix("\n")) {
      out.write_char('\n')
    }
  }
  out.write_string("}\n")
  out.to_string()
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
  runner : BenchWasmRunner,
  http_runner : HttpHostRunner?,
  use_http_host_runner : Bool,
  source_path : String,
  wasm_path : String,
  source : String,
) -> CompiledTestCaseExec {
  @os_fs.write_string_to_file(source_path, source) catch {
    e =>
      return CompiledTestCaseExec::Error(
        "write source failed: " + e.to_string(),
      )
  }
  let (db, entry) = match load_compiled_test_case_db(source_path) {
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
fn run_test_file_compiled(
  entry_path : String,
  stop_on_first_failure : Bool,
) -> CompiledTestAttempt {
  let (db, entry) = match @loader.load_db_for_test(entry_path) {
    Err(err) => return CompiledTestAttempt::Error("load error: " + err)
    Ok(v) => v
  }
  let ast = db.ast(entry)
  let use_http_host_runner = module_uses_http_builtins(ast)
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
      _ => prelude_stmts.push(stmt)
    }
  }
  let prelude_source = render_stmt_snippets(source, prelude_stmts)
  let parent = @vibe_fs.parent_path(entry)
  let stamp = @env.now().to_string() + "_" + vibe_getpid().to_string()
  let failures : Array[CliTestFailure] = []
  let mut passed = 0
  for i, case in cases {
    let case_body_source = render_stmt_snippets(source, case.body.stmts)
    let case_source = build_compiled_test_case_source(
      prelude_source, case_body_source,
    )
    let base = parent + "/.vibe_test_wasm_" + stamp + "_" + i.to_string()
    let source_path = base + ".vibe"
    let wasm_path = base + ".wasm"
    let outcome = run_compiled_test_case(
      runner, http_runner, use_http_host_runner, source_path, wasm_path, case_source,
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
fn run_test_file_interpreter(
  entry_path : String,
  features : @runtime.RuntimeFeatureFlags,
) -> Result[CliTestReport, String] {
  let (db, entry) = match @loader.load_db_for_test(entry_path) {
    Err(err) => return Err("load error: " + err)
    Ok(v) => v
  }
  let compiled = @runtime_compile.compile_module(db, entry) catch {
    e => return Err("compile error: " + e.to_string())
  }
  let rt = new_runtime_with_features(features)
  rt.set_type_env(compiled.type_env)
  let path_to_hash : Map[String, String] = {}
  load_imports_into_runtime(rt, db, entry, path_to_hash)
  let base_dir = @vibe_fs.parent_path(entry)
  for stmt in compiled.ast.stmts {
    match stmt {
      @vibe_core.Stmt::Import(source~, ..)
      | @vibe_core.Stmt::ReExport(source~, ..) =>
        match source {
          @vibe_core.ModuleRef::Path(path=raw_path) => {
            let resolved = @loader.resolve_import_path(base_dir, raw_path)
            match path_to_hash.get(resolved) {
              Some(hash) => path_to_hash[raw_path] = hash
              None => ()
            }
          }
          @vibe_core.ModuleRef::Hash(_)
          | @vibe_core.ModuleRef::Version(_)
          | @vibe_core.ModuleRef::Symbol(_) => ()
        }
      _ => ()
    }
  }
  let converted_ast = @vibe_core.convert_imports_to_hash(compiled.ast, fn(
    path,
  ) {
    path_to_hash.get(path)
  })
  for name, target in compiled.aliases {
    rt.set_alias(name, target)
  }
  let report = rt.run_tests(converted_ast) catch {
    e => return Err("eval error: " + e.to_string())
  }
  let failures : Array[CliTestFailure] = []
  for failure in report.failures {
    failures.push(CliTestFailure::{ name: failure.name, error: failure.error })
  }
  Ok({
    total: report.total,
    passed: report.passed,
    failed: report.failed,
    failures,
  })
}

///|
fn run_test_file_with_backend(
  entry_path : String,
  features : @runtime.RuntimeFeatureFlags,
) -> Result[CliTestReport, String] {
  let backend_pref = resolve_cli_exec_backend_pref_for_entry(
    "VIBE_TEST_BACKEND", entry_path,
  )
  let allow_interpreter_fallback = cli_can_fallback_to_interpreter(backend_pref)
  if backend_pref != CliExecBackendPref::Interpreter {
    let stop_on_first_failure = allow_interpreter_fallback
    match run_test_file_compiled(entry_path, stop_on_first_failure) {
      CompiledTestAttempt::Success(report) => return Ok(report)
      CompiledTestAttempt::Unsupported(err) =>
        if backend_pref == CliExecBackendPref::Compiled ||
          not(allow_interpreter_fallback) {
          return Err("compiled backend unsupported: " + err)
        }
      CompiledTestAttempt::Error(err) => return Err(err)
    }
  }
  run_test_file_interpreter(entry_path, features)
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
  for entry_path in entry_paths {
    match run_test_file_with_backend(entry_path, features) {
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
  let worker_parent_pid = test_worker_parent_pid()
  match worker_parent_pid {
    Some(parent_pid) => vibe_worker_parent_watchdog_start(parent_pid)
    None => ()
  }
  defer vibe_worker_parent_watchdog_stop()
  let mut any_failed = false
  for entry_path in entry_paths {
    if should_exit_report_json_worker(worker_parent_pid) {
      c_exit(130)
    }
    let start = @bench.monotonic_clock_start()
    let mut elapsed_ms = 1
    match run_test_file_with_backend(entry_path, features) {
      Ok(report) => {
        let elapsed_us = @bench.monotonic_clock_end(start)
        elapsed_ms = elapsed_us_to_ms_int(elapsed_us)
        println(make_cli_test_report_json(entry_path, report, elapsed_ms).stringify())
        if report.failed > 0 {
          any_failed = true
        }
      }
      Err(err) => {
        let elapsed_us = @bench.monotonic_clock_end(start)
        elapsed_ms = elapsed_us_to_ms_int(elapsed_us)
        println(make_error_report_json(entry_path, "test", err, elapsed_ms).stringify())
        any_failed = true
      }
    }
  }
  if any_failed {
    abort("test: failures detected")
  }
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
fn test_worker_parent_pid() -> Int? {
  match @sys.get_env_var("VIBE_INTERNAL_TEST_PARENT_PID") {
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
  let text = @os_fs.read_file_to_string(cache_path) catch {
    _ => return {}
  }
  let json : Json = @json.parse(text) catch {
    _ => return {}
  }
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
  @os_fs.create_dir(path) catch { _ => () }
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
struct TestEntryBatchUnit {
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
    a.parent.compare(b.parent)
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

  let target_chunk_size = (entry_paths.length() + worker_count - 1) /
    worker_count
  let units : Array[TestEntryBatchUnit] = []
  for parent in parent_keys {
    let parent_paths = match grouped.get(parent) {
      Some(paths) => paths
      None => continue
    }
    sort_test_entry_paths_for_batching(parent_paths)
    let mut offset = 0
    while offset < parent_paths.length() {
      let chunk : Array[String] = []
      let mut chunk_count = 0
      while offset < parent_paths.length() && chunk_count < target_chunk_size {
        chunk.push(parent_paths[offset])
        offset += 1
        chunk_count += 1
      }
      units.push(TestEntryBatchUnit::{
        parent,
        weight: test_entry_batch_paths_weight(chunk, weights),
        paths: chunk,
      })
    }
  }
  sort_test_entry_batch_units(units)

  let loads : Array[Int] = []
  for _ in 0..<worker_count {
    loads.push(0)
  }
  for unit in units {
    let batch_index = test_entry_batch_min_load_index(loads)
    for path in unit.paths {
      batches[batch_index].push(path)
    }
    loads[batch_index] += unit.weight
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
  } else {
    if use_batch_weight_cache {
      split_test_entry_path_batches_with_weights(
        entry_paths,
        jobs,
        cached_batch_weights,
      )
    } else {
      split_test_entry_path_batches(entry_paths, jobs)
    }
  }
  let max_concurrent = if jobs == 1 { 1 } else { batches.length() }
  vibe_parallel_cleanup_install_signal_handlers()
  vibe_parallel_cleanup_clear()
  defer vibe_parallel_cleanup_clear()
  let tasks : Array[async () -> (Array[String], Int, String, String)] = []
  for batch in batches {
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
    tasks.push(async fn() {
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
        let out = stdout_task.wait().text() catch { _ => "" }
        let err = stderr_task.wait().text() catch { _ => "" }
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
  let suffix = ".vbundle"
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
    scope.has_suffix(".vbundle") ||
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
fn print_bench_report(path : String, report : @runtime.BenchReport) -> Bool {
  let status = if report.failed == 0 { "ok" } else { "fail" }
  println("\{path}: \{status} (\{report.passed}/\{report.total})")
  for result in report.results {
    let name = match result.name {
      Some(n) => n
      None => "<unnamed>"
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
      result.per_us.to_string(),
    )
  }
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
    " + " +
    @codebase.resolve_index_root(entry) +
    "/index.vbundle (lock payload, " +
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
        " index_vbundle=" +
        index_root +
        "/index.vbundle",
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
        let index_vbundle_path = index_root + "/index.vbundle"
        let vbundle = load_index_vbundle_object(index_vbundle_path)
        let next_vbundle = clone_json_map(vbundle)
        let namespaces = match vbundle.get("namespaces") {
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
        next_vbundle["active_namespace"] = Json::string(namespace_name)
        next_vbundle["namespaces"] = Json::object(namespaces)
        match write_index_vbundle_object(index_vbundle_path, next_vbundle) {
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
