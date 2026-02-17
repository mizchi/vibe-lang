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
    "repl" => repl_cmd(cmd_args, syntax_mode, runtime_features, enable_llm~)
    "repl-stdin" =>
      repl_stdin_cmd(cmd_args, syntax_mode, runtime_features, enable_llm~)
    "repl-wasi" =>
      repl_wasi_cmd(cmd_args, syntax_mode, runtime_features, enable_llm~)
    "wasm-repl-stdin" => wasm_repl_stdin_cmd(cmd_args)
    "hash" => hash_cmd(cmd_args)
    "save" => save_cmd(cmd_args)
    "fetch" => fetch_cmd(cmd_args)
    "update-lock" => fetch_cmd(cmd_args)
    "explain-import" => explain_import_cmd(cmd_args)
    "expand" => expand_cmd(cmd_args)
    "ide" => ide_cmd(cmd_args)
    "lsif" => lsif_cmd(cmd_args)
    "index" => index_cmd(cmd_args)
    "lsp" => lsp_cmd(cmd_args)
    "help" => print_usage()
    _ => {
      println("unknown command: " + cmd)
      print_usage()
    }
  }
}

///|
fn print_usage() -> Unit {
  println("vibe <command> [args]")
  println("")
  println("commands:")
  println("  run <file>                 parse/type/eval a script")
  println("    demo: vibe run vibe/x/args/demo.vibe")
  println(
    "  eval [--db file] [--include file] [--inspect-scope] [--assert name:sig]... [--test-for name] [--run] [--export file] <expr...>  evaluate expression/script",
  )
  println("  test <file|dir...>         run test blocks in scripts")
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
    "  normalize [--write] <file...>  normalize declaration order + DCE (+fmt)",
  )
  println(
    "  compile [--wasm | --wasm-js-string | --wasm-gc | --component | --wit | --wit-component] [--no-dce] [--coverage] [--coverage-run-tests] [--debug-errors] [--wite|-O{0,1,2,3,4,s,z}] [-o out] <file>",
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
    "                                     --debug-errors keeps raise string literals in wasm (debug builds)",
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
  println("  repl                        interactive TUI shell")
  println(
    "  repl-stdin [--no-prompt] [--tty|--no-tty]  read-eval-print loop (stdin)",
  )
  println(
    "  repl-wasi [--no-prompt] [--tty|--no-tty]   wasi-friendly line repl",
  )
  println("  wasm-repl-stdin [--no-prompt] [-o dir]  compile each expr to WASM")
  println("  hash <file>                 compute normalized AST hash")
  println(
    "  save <file>                 save module to content-addressed store",
  )
  println(
    "  fetch <file>                resolve imports and sync lock payload (index.lock + index.vdb)",
  )
  println("  update-lock <file>          alias for fetch")
  println(
    "  explain-import <file>       visualize import ref normalization and lock lookup",
  )
  println("  ide <outline|peek-def|search> ...  symbol/type index queries")
  println("  lsif [-o out.lsif] <file>   emit LSIF via shared symbol index")
  println(
    "  index <build|query|verify|wal|ref> ...  advanced graph index (POC)",
  )
  println(
    "    ref: push|pull|push-delta|pull-delta <scope> <file>  git/bit distributed refs",
  )
  println("  lsp                         start LSP server (stdin/stdout)")
  println("  parser commands: --syntax vibe|posix (default: vibe)")
  println("  runtime flags: --unstable-async --unstable-threads")
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
    | "repl"
    | "repl-stdin"
    | "repl-wasi"
    | "wasm-repl-stdin"
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
          ) catch {
            e => abort("compile: " + e.user_message())
          }
          match @io.write_bytes_with(fs, resolved_out, wasm_bytes) {
            Ok(_) => ()
            Err(err) => abort("compile: " + err)
          }
          println("wrote " + resolved_out)
        }
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
    @runtime.ParserMode::XshMode =>
      match @loader.load_db(entry_path) {
        Err(err) => abort("run: " + err)
        Ok((db, entry)) => {
          let compiled = @runtime_compile.compile_module(db, entry) catch {
            e => abort("run: " + e.to_string())
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
          // Evaluate the converted module
          let result = rt.eval_module(converted_ast) catch {
            e => abort("run: " + e.to_string())
          }
          print_eval_result(result)
        }
      }
    @runtime.ParserMode::PosixMode => {
      let resolved = @loader.resolve_entry_path(entry_path)
      let source = @os_fs.read_file_to_string(resolved) catch {
        e => abort("run: " + e.to_string())
      }
      let rt = new_cli_runtime(features, enable_llm~)
      let result = rt.eval_script_with_mode(source, syntax_mode) catch {
        e => abort("run: " + e.to_string())
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
  let mut total_errors = 0
  for entry_path in args {
    match resolve_entry_artifacts(entry_path) {
      Err(err) => {
        println("check: \{entry_path}: \{err}")
        total_errors += 1
      }
      Ok((db, entry, _lock, _index, graph_head)) => {
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
        let _ = db.types(entry)
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
      @vibe_core.Stmt::Export(names~, ..)
      | @vibe_core.Stmt::ReExport(names~, ..) =>
        for name in names {
          entries[name] = true
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
fn finalize_render_stmt_fallback(stmt : @vibe_core.Stmt) -> String? {
  match stmt {
    @vibe_core.Stmt::Export(names~, ..) =>
      Some("export { " + finalize_render_name_list(names) + " }")
    @vibe_core.Stmt::ReExport(names~, source~, ..) =>
      Some(
        "export { " +
        finalize_render_name_list(names) +
        " } from " +
        finalize_render_module_ref(source),
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
  let dced = @runtime.dce_module_with_entry_names(
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
  let finalized_source = match finalize_render_source(source, kept_stmts) {
    Ok(v) => v
    Err(err) => abort(err)
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
fn test_cmd(
  args : Array[String],
  features : @runtime.RuntimeFeatureFlags,
) -> Unit {
  if args.length() == 0 {
    abort("test: expected <file|dir...>")
  }
  let entry_paths = resolve_test_entry_paths(args)
  if entry_paths.length() == 0 {
    abort("test: no test files found")
  }
  let mut failed = false
  let mut total = 0
  let mut passed = 0
  let mut failed_count = 0
  let file_count = entry_paths.length()
  for entry_path in entry_paths {
    match @loader.load_db(entry_path) {
      Err(err) => {
        println("[\{entry_path}] load error: \{err}")
        failed = true
      }
      Ok((db, entry)) => {
        let compiled = @runtime_compile.compile_module(db, entry) catch {
          e => {
            println("[\{entry_path}] compile error: \{e.to_string()}")
            failed = true
            continue
          }
        }
        let rt = new_runtime_with_features(features)
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
        // Convert the AST's import paths to hashes
        let converted_ast = @vibe_core.convert_imports_to_hash(compiled.ast, fn(
          path,
        ) {
          path_to_hash.get(path)
        })
        for name, target in compiled.aliases {
          rt.set_alias(name, target)
        }
        let report = rt.run_tests(converted_ast) catch {
          e => abort("[\{entry_path}] eval error: \{e.to_string()}")
        }
        if !print_test_report(entry_path, report) {
          failed = true
        }
        total += report.total
        passed += report.passed
        failed_count += report.failed
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
fn normalize_cmd(args : Array[String]) -> Unit {
  if args.length() == 0 {
    abort("normalize: expected <file...>")
  }
  let mut write = false
  let files : Array[String] = []
  for arg in args {
    match arg {
      "--write" | "-w" => write = true
      _ => files.push(arg)
    }
  }
  if files.length() == 0 {
    abort("normalize: expected <file...>")
  }
  if not(write) && files.length() > 1 {
    abort("normalize: use --write for multiple files")
  }
  for path in files {
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
    let normalized = match normalize_format_file_source(resolved) {
      Ok(v) => v
      Err(err) => abort("normalize: " + err)
    }
    let output = if write {
      apply_lock_annotations_for_format(resolved, normalized)
    } else {
      normalized
    }
    if write {
      @os_fs.write_string_to_file(resolved, output) catch {
        e => abort("normalize: " + e.to_string())
      }
    } else {
      println(output)
    }
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
    "/index.vdb (lock payload, " +
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
        " index_vdb=" +
        index_root +
        "/index.vdb",
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
    let key = def.path + "#" + def.name
    let managed = lock.module_refs.contains(key)
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
  let std_dir = @vibe_fs.normalize_path(vibe_root + "/std")
  let encoding_dir = @vibe_fs.normalize_path(vibe_root + "/encoding")
  let string_mod = @vibe_fs.normalize_path(std_dir + "/string.vibe")
  let base64 = @vibe_fs.normalize_path(encoding_dir + "/base64.vibe")
  if not(@os_fs.path_exists(std_dir)) || not(@os_fs.path_exists(encoding_dir)) {
    return false
  }
  let std_is_dir = @os_fs.is_dir(std_dir) catch { _ => false }
  if not(std_is_dir) {
    return false
  }
  let encoding_is_dir = @os_fs.is_dir(encoding_dir) catch { _ => false }
  if not(encoding_is_dir) {
    return false
  }
  @os_fs.path_exists(string_mod) && @os_fs.path_exists(base64)
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
        if copy_seed_tree_if_missing(seed_norm + "/std", root + "/vibe/std") {
          created.push("vibe/std/")
        }
        if copy_seed_tree_if_missing(
            seed_norm + "/encoding",
            root + "/vibe/encoding",
          ) {
          created.push("vibe/encoding/")
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
        let index_vdb_path = index_root + "/index.vdb"
        let vdb = load_index_vdb_object(index_vdb_path)
        let next_vdb = clone_json_map(vdb)
        let namespaces = match vdb.get("namespaces") {
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
        next_vdb["active_namespace"] = Json::string(namespace_name)
        next_vdb["namespaces"] = Json::object(namespaces)
        match write_index_vdb_object(index_vdb_path, next_vdb) {
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
