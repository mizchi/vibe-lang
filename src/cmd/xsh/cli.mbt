///|
/// CLI entry logic for xsh
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
  let runtime_features = @xsh_lib.RuntimeFeatureFlags::new(
    parsed.unstable_async,
    parsed.unstable_threads,
  )
  if command_requires_parser(cmd) {
    match ensure_cli_parser_mode_supported(syntax_mode, cmd) {
      Ok(_) => ()
      Err(msg) => abort(msg)
    }
  }
  match cmd {
    "run" => run_cmd(cmd_args, syntax_mode, runtime_features)
    "eval" => eval_cmd(cmd_args, syntax_mode, runtime_features)
    "test" => test_cmd(cmd_args, runtime_features)
    "check" => check_cmd(cmd_args)
    "finalize" => finalize_cmd(cmd_args)
    "apply" => apply_cmd(cmd_args)
    "symbols" => symbols_cmd(cmd_args)
    "history" => history_cmd(cmd_args)
    "write_file" => write_file_cmd(cmd_args)
    "fmt" => fmt_cmd(cmd_args)
    "normalize" => normalize_cmd(cmd_args)
    "compile" => compile_cmd(cmd_args)
    "bench" => bench_cmd(cmd_args, syntax_mode, runtime_features)
    "bench-file" => bench_file_cmd(cmd_args, runtime_features)
    "repl" => repl_cmd(cmd_args, syntax_mode, runtime_features)
    "repl-stdin" => repl_stdin_cmd(cmd_args, syntax_mode, runtime_features)
    "repl-wasi" => repl_wasi_cmd(cmd_args, syntax_mode, runtime_features)
    "wasm-repl-stdin" => wasm_repl_stdin_cmd(cmd_args)
    "hash" => hash_cmd(cmd_args)
    "save" => save_cmd(cmd_args)
    "fetch" => fetch_cmd(cmd_args)
    "update-lock" => fetch_cmd(cmd_args)
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
  println("xsh <command> [args]")
  println("")
  println("commands:")
  println("  run <file>                 parse/type/eval a script")
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
  println("  history reset              reset scratch namespace history/db")
  println(
    "  write_file [--entry file] [--no-deps] [--dry-run] [--json] <selector> <out-file>  materialize selector",
  )
  println("  fmt [--dry-run] <file...>  normalize + format scripts")
  println(
    "  normalize [--write] <file...>  normalize declaration order + DCE (+fmt)",
  )
  println(
    "  compile [--wasm | --wasm-js-string | --wasm-gc | --component | --wit | --wit-component] [--no-dce] [--coverage] [--coverage-run-tests] [--debug-errors] [--wite|-O{0,1,2,3,s,z}] [-o out] <file>",
  )
  println(
    "                                     emit to dist/ (or -o path). Formats: IR, Core WASM, Component WASM",
  )
  println(
    "                                     --coverage is test-only (set XSH_TEST_COVERAGE=1)",
  )
  println(
    "                                     --coverage-run-tests executes top-level test blocks in coverage mode",
  )
  println(
    "                                     --debug-errors keeps raise string literals in wasm (debug builds)",
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
  println("  fetch <file>                resolve imports and write index.lock")
  println("  update-lock <file>          alias for fetch")
  println("  ide <outline|peek-def|search> ...  symbol/type index queries")
  println("  lsif [-o out.lsif] <file>   emit LSIF via shared symbol index")
  println(
    "  index <build|query|verify|wal|ref> ...  advanced graph index (POC)",
  )
  println(
    "    ref: push|pull|push-delta|pull-delta <scope> <file>  git/bit distributed refs",
  )
  println("  lsp                         start LSP server (stdin/stdout)")
  println("  parser commands: --syntax xsh|posix (default: xsh)")
  println("  runtime flags: --unstable-async --unstable-threads")
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
  features : @xsh_lib.RuntimeFeatureFlags,
) -> @xsh_lib.Runtime {
  @xsh_lib.Runtime::new_with_features(
    @capability.CapabilitySet::developer(),
    features,
  )
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
fn coverage_point_kind_name(kind : @xsh_lib.WasmCoveragePointKind) -> String {
  match kind {
    @xsh_lib.WasmCoveragePointKind::Line => "line"
    @xsh_lib.WasmCoveragePointKind::BranchIfThen => "branch_if_then"
    @xsh_lib.WasmCoveragePointKind::BranchIfElse => "branch_if_else"
    @xsh_lib.WasmCoveragePointKind::BranchMatchArm => "branch_match_arm"
  }
}

///|
fn coverage_point_json(
  source : String,
  point : @xsh_lib.WasmCoveragePoint,
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
  coverage : @xsh_lib.WasmCoverageArtifact,
) -> Unit {
  let points : Array[Json] = []
  for point in coverage.points {
    points.push(coverage_point_json(source, point))
  }
  let obj : Map[String, Json] = {}
  obj["format"] = Json::string("xsh-wasm-coverage-v1")
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
  match @sys.get_env_var("XSH_TEST_COVERAGE") {
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
    Err("compile: --coverage is test-only (set XSH_TEST_COVERAGE=1)")
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
          let compiled = @xsh_lib.compile_module(db, entry) catch {
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
            let coverage = @xsh_lib.compile_module_wasm_with_coverage(
              db,
              entry,
              no_dce=opts.no_dce,
              opt_level=opts.opt_level,
              run_tests=opts.coverage_run_tests,
              debug_errors=opts.debug_errors,
            ) catch {
              e => abort("compile: " + e.to_string())
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
            let wasm_bytes = @xsh_lib.compile_module_wasm_with_opt_level(
              db,
              entry,
              no_dce=opts.no_dce,
              opt_level=opts.opt_level,
              debug_errors=opts.debug_errors,
            ) catch {
              e => abort("compile: " + e.to_string())
            }
            match @io.write_bytes_with(fs, resolved_out, wasm_bytes) {
              Ok(_) => ()
              Err(err) => abort("compile: " + err)
            }
            println("wrote " + resolved_out)
          }
        CompileMode::WasmJsString =>
          if opts.coverage {
            let coverage = @xsh_lib.compile_module_wasm_js_string_with_coverage(
              db,
              entry,
              no_dce=opts.no_dce,
              opt_level=opts.opt_level,
              run_tests=opts.coverage_run_tests,
              debug_errors=opts.debug_errors,
            ) catch {
              e => abort("compile: " + e.to_string())
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
            let wasm_bytes = @xsh_lib.compile_module_wasm_js_string_with_opt_level(
              db,
              entry,
              no_dce=opts.no_dce,
              opt_level=opts.opt_level,
              debug_errors=opts.debug_errors,
            ) catch {
              e => abort("compile: " + e.to_string())
            }
            match @io.write_bytes_with(fs, resolved_out, wasm_bytes) {
              Ok(_) => ()
              Err(err) => abort("compile: " + err)
            }
            println("wrote " + resolved_out)
          }
        CompileMode::WasmGc => {
          let wasm_bytes = @xsh_lib.compile_module_wasm_gc_with_opt_level(
            db,
            entry,
            no_dce=opts.no_dce,
            opt_level=opts.opt_level,
          ) catch {
            e => abort("compile: " + e.to_string())
          }
          match @io.write_bytes_with(fs, resolved_out, wasm_bytes) {
            Ok(_) => ()
            Err(err) => abort("compile: " + err)
          }
          println("wrote " + resolved_out)
        }
        CompileMode::Component => {
          let wasm_bytes = @xsh_lib.compile_module_component_with_opt_level(
            db,
            entry,
            opt_level=opts.opt_level,
          ) catch {
            e => abort("compile: " + e.to_string())
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
          let wit_str = @xsh_lib.generate_module_wit(
            db, entry, package_name, world_name,
          ) catch {
            e => abort("compile: " + e.to_string())
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
          let wit_str = @xsh_lib.generate_module_component_wit(
            db, entry, package_name, world_name,
          ) catch {
            e => abort("compile: " + e.to_string())
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
  syntax_mode : @xsh_lib.ParserMode,
  features : @xsh_lib.RuntimeFeatureFlags,
) -> Unit {
  if args.length() != 1 {
    abort("run: expected <file>")
  }
  let entry_path = args[0]
  match syntax_mode {
    @xsh_lib.ParserMode::XshMode =>
      match @loader.load_db(entry_path) {
        Err(err) => abort("run: " + err)
        Ok((db, entry)) => {
          let compiled = @xsh_lib.compile_module(db, entry) catch {
            e => abort("run: " + e.to_string())
          }
          let rt = new_runtime_with_features(features)
          rt.set_type_env(compiled.type_env)
          // Build path-to-hash mapping and load imported modules into runtime cache
          let path_to_hash : Map[String, String] = {}
          load_imports_into_runtime(rt, db, entry, path_to_hash)
          // Also add mappings for raw paths from the AST
          let base_dir = @xsh_fs.parent_path(entry)
          for stmt in compiled.ast.stmts {
            match stmt {
              @xsh_core.Stmt::Import(source~, ..) =>
                match source {
                  @xsh_core.ModuleRef::Path(path=raw_path) => {
                    // Resolve the path to find the hash
                    let resolved = @loader.resolve_import_path(
                      base_dir, raw_path,
                    )
                    match path_to_hash.get(resolved) {
                      Some(hash) => path_to_hash[raw_path] = hash
                      None => ()
                    }
                  }
                  @xsh_core.ModuleRef::Hash(_)
                  | @xsh_core.ModuleRef::Version(_)
                  | @xsh_core.ModuleRef::Symbol(_) => ()
                }
              _ => ()
            }
          }
          // Convert the AST's import paths to hashes
          let converted_ast = @xsh_core.convert_imports_to_hash(compiled.ast, fn(
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
    @xsh_lib.ParserMode::PosixMode => {
      let resolved = @loader.resolve_entry_path(entry_path)
      let source = @os_fs.read_file_to_string(resolved) catch {
        e => abort("run: " + e.to_string())
      }
      let rt = new_runtime_with_features(features)
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
  rt : @xsh_lib.Runtime,
  db : @xsh_lib.XshDb,
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
fn finalize_collect_export_names(ast : @xsh_core.Module) -> Array[String] {
  let entries : Map[String, Bool] = {}
  for stmt in ast.stmts {
    match stmt {
      @xsh_core.Stmt::ExportLet(name~, ..)
      | @xsh_core.Stmt::ExportEnumDef(name~, ..)
      | @xsh_core.Stmt::ExportTypeAlias(name~, ..)
      | @xsh_core.Stmt::ExportStructDef(name~, ..) => entries[name] = true
      @xsh_core.Stmt::TraitDef(name~, exported~, ..) =>
        if exported {
          entries[name] = true
        }
      @xsh_core.Stmt::Export(names~, ..)
      | @xsh_core.Stmt::ReExport(names~, ..) =>
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
fn finalize_stmt_is_library_side_effect(stmt : @xsh_core.Stmt) -> Bool {
  match stmt {
    @xsh_core.Stmt::Expr(..)
    | @xsh_core.Stmt::Assign(..)
    | @xsh_core.Stmt::IndexAssign(..)
    | @xsh_core.Stmt::LetPat(..) => true
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
fn finalize_render_module_ref(source : @xsh_core.ModuleRef) -> String {
  match source {
    @xsh_core.ModuleRef::Path(path~) => path
    @xsh_core.ModuleRef::Hash(hash~) => "#" + hash
    @xsh_core.ModuleRef::Version(name~) => "version@" + name
    @xsh_core.ModuleRef::Symbol(name~) => "symbol@" + name
  }
}

///|
fn finalize_render_stmt_fallback(stmt : @xsh_core.Stmt) -> String? {
  match stmt {
    @xsh_core.Stmt::Export(names~, ..) =>
      Some("export { " + finalize_render_name_list(names) + " }")
    @xsh_core.Stmt::ReExport(names~, source~, ..) =>
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
  stmts : Array[@xsh_core.Stmt],
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
  stmts : Array[@xsh_core.Stmt],
  library_mode : Bool,
) -> Array[@xsh_core.Stmt] {
  let out : Array[@xsh_core.Stmt] = []
  for stmt in stmts {
    match stmt {
      @xsh_core.Stmt::Test(..) | @xsh_core.Stmt::Bench(..) => ()
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
  ast : @xsh_core.Module,
  library_mode : Bool,
) -> Array[@xsh_core.Stmt] {
  let extra_entries = finalize_collect_export_names(ast)
  let prefiltered = finalize_prefilter_stmts(ast.stmts, library_mode)
  let dced = @xsh_lib.dce_module_with_entry_names(
    @xsh_core.Module::{ stmts: prefiltered },
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
  features : @xsh_lib.RuntimeFeatureFlags,
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
        let compiled = @xsh_lib.compile_module(db, entry) catch {
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
        let base_dir = @xsh_fs.parent_path(entry)
        for stmt in compiled.ast.stmts {
          match stmt {
            @xsh_core.Stmt::Import(source~, ..) =>
              match source {
                @xsh_core.ModuleRef::Path(path=raw_path) => {
                  let resolved = @loader.resolve_import_path(base_dir, raw_path)
                  match path_to_hash.get(resolved) {
                    Some(hash) => path_to_hash[raw_path] = hash
                    None => ()
                  }
                }
                @xsh_core.ModuleRef::Hash(_)
                | @xsh_core.ModuleRef::Version(_)
                | @xsh_core.ModuleRef::Symbol(_) => ()
              }
            _ => ()
          }
        }
        // Convert the AST's import paths to hashes
        let converted_ast = @xsh_core.convert_imports_to_hash(compiled.ast, fn(
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
fn load_bench_cases(
  path : String,
  start_case_index : Int,
) -> Result[Array[BenchCase], String] {
  let source = @os_fs.read_file_to_string(path) catch {
    e => return Err("read failed: " + e.to_string())
  }
  parse_bench_case_source(source, start_case_index)
}

///|
enum BenchBackend {
  Interpreter
  Wasm
} derive(Show, Eq)

///|
struct BenchSourceCase {
  name : String?
  body_source : String
} derive(Show, Eq)

///|
struct BenchSourcePlan {
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
fn is_wasm_unsupported_compile_error(message : String) -> Bool {
  message.contains("compile wasm error: Gen(Unsupported(") ||
  message.contains("compile: Gen(Unsupported(")
}

///|
fn wasm_bench_report_has_only_unsupported_compile_failures(
  report : WasmBenchReport,
) -> Bool {
  if report.failed == 0 || report.passed > 0 {
    return false
  }
  for failure in report.failures {
    if not(is_wasm_unsupported_compile_error(failure.error)) {
      return false
    }
  }
  true
}

///|
fn bench_backend_name(backend : BenchBackend) -> String {
  match backend {
    BenchBackend::Interpreter => "interpreter"
    BenchBackend::Wasm => "wasm"
  }
}

///|
fn parse_bench_backend(value : String) -> BenchBackend? {
  match value.trim().to_string().to_lower() {
    "interpreter" | "interp" => Some(BenchBackend::Interpreter)
    "wasm" => Some(BenchBackend::Wasm)
    _ => None
  }
}

///|
fn parse_bench_backend_or_abort(value : String) -> BenchBackend {
  match parse_bench_backend(value) {
    Some(v) => v
    None =>
      abort(
        "bench: invalid --backend: " + value + " (expected wasm|interpreter)",
      )
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
fn run_bench_case(
  case_item : BenchCase,
  count : Int,
  warmup : Int,
  syntax_mode : @xsh_lib.ParserMode,
  features : @xsh_lib.RuntimeFeatureFlags,
) -> (Double, Double) {
  let rt = new_runtime_with_features(features)
  for _ in 0..<warmup {
    let _ = rt.eval_script_with_mode(case_item.expr, syntax_mode) catch {
      e => abort("bench: " + case_item.name + ": " + e.to_string())
    }
  }
  let start = @env.now()
  for _ in 0..<count {
    let _ = rt.eval_script_with_mode(case_item.expr, syntax_mode) catch {
      e => abort("bench: " + case_item.name + ": " + e.to_string())
    }
  }
  let end = @env.now()
  let elapsed_ms = (end - start).to_double()
  let per_us = elapsed_ms * 1000.0 / count.to_double()
  (elapsed_ms, per_us)
}

///|
fn bench_expr_cmd(
  args : Array[String],
  syntax_mode : @xsh_lib.ParserMode,
  features : @xsh_lib.RuntimeFeatureFlags,
) -> Unit {
  let mut count = 20000
  let mut warmup = 1000
  let mut expr : String? = None
  let cases : Array[BenchCase] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-n" | "--n" => {
        if i + 1 >= args.length() {
          abort("bench: missing value for --n")
        }
        count = @strconv.parse_int(args[i + 1]) catch {
          e => abort("bench: invalid --n: " + e.to_string())
        }
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
      "-e" | "--expr" => {
        if i + 1 >= args.length() {
          abort("bench: missing value for --expr")
        }
        expr = Some(args[i + 1])
        i += 2
      }
      "--case" => {
        if i + 1 >= args.length() {
          abort("bench: missing value for --case")
        }
        match parse_bench_case_arg(args[i + 1], cases.length() + 1) {
          Ok(case_item) => cases.push(case_item)
          Err(msg) => abort("bench: invalid --case: " + msg)
        }
        i += 2
      }
      "--cases" => {
        if i + 1 >= args.length() {
          abort("bench: missing value for --cases")
        }
        let case_path = args[i + 1]
        let loaded = match load_bench_cases(case_path, cases.length() + 1) {
          Ok(items) => items
          Err(msg) => abort("bench: " + case_path + ": " + msg)
        }
        for case_item in loaded {
          cases.push(case_item)
        }
        i += 2
      }
      "-b" | "--backend" => {
        if i + 1 >= args.length() {
          abort("bench: missing value for --backend")
        }
        let backend = parse_bench_backend_or_abort(args[i + 1])
        match backend {
          BenchBackend::Interpreter => ()
          BenchBackend::Wasm =>
            abort(
              "bench: --backend wasm is not supported in legacy expr mode; pass <file|dir...> or use --backend interpreter",
            )
        }
        i += 2
      }
      _ => abort("bench: unknown arg " + arg)
    }
  }
  if count <= 0 {
    abort("bench: --n must be > 0")
  }
  if warmup < 0 {
    abort("bench: --warmup must be >= 0")
  }
  match expr {
    Some(expr_text) => cases.push({ name: "expr", expr: expr_text })
    None =>
      if cases.length() == 0 {
        cases.push({ name: "expr", expr: "add(1,2)" })
      }
  }
  let multi_case = cases.length() > 1
  let mut total_ms = 0.0
  for case_item in cases {
    let (elapsed_ms, per_us) = run_bench_case(
      case_item, count, warmup, syntax_mode, features,
    )
    total_ms += elapsed_ms
    if elapsed_ms <= 0.0 {
      println(
        "bench: " +
        case_item.name +
        ": elapsed_ms=0; increase --n for measurable time",
      )
    }
    if multi_case || case_item.name != "expr" {
      println(
        "bench: name=\"" +
        case_item.name +
        "\" expr=\"" +
        case_item.expr +
        "\" count=" +
        count.to_string() +
        " total_ms=" +
        elapsed_ms.to_string() +
        " per_us=" +
        per_us.to_string(),
      )
    } else {
      println(
        "bench: expr=\"" +
        case_item.expr +
        "\" count=" +
        count.to_string() +
        " total_ms=" +
        elapsed_ms.to_string() +
        " per_us=" +
        per_us.to_string(),
      )
    }
  }
  if multi_case {
    println(
      "bench: cases=" +
      cases.length().to_string() +
      " total_ms=" +
      total_ms.to_string(),
    )
  }
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
      "-e" | "--expr" | "--case" | "--cases" => return true
      "-n" | "--n" | "--warmup" | "-b" | "--backend" =>
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
  syntax_mode : @xsh_lib.ParserMode,
  features : @xsh_lib.RuntimeFeatureFlags,
) -> Unit {
  let expr_mode = bench_uses_expr_mode(args)
  if expr_mode {
    let backend = resolve_bench_backend(args, BenchBackend::Interpreter)
    match backend {
      BenchBackend::Interpreter => ()
      BenchBackend::Wasm =>
        abort(
          "bench: --backend wasm is not supported in legacy expr mode; pass <file|dir...> or use --backend interpreter",
        )
    }
    bench_expr_cmd(args, syntax_mode, features)
  } else {
    let backend = resolve_bench_backend(args, BenchBackend::Wasm)
    match syntax_mode {
      @xsh_lib.ParserMode::PosixMode =>
        abort(
          "bench: --syntax posix is supported only with --expr/--case/--cases",
        )
      @xsh_lib.ParserMode::XshMode => ()
    }
    bench_blocks_cmd(args, features, backend)
  }
}

///|
fn bench_blocks_cmd(
  args : Array[String],
  features : @xsh_lib.RuntimeFeatureFlags,
  backend : BenchBackend,
) -> Unit {
  let mut count = 1000
  let mut warmup = 10
  let paths : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-n" | "--n" => {
        if i + 1 >= args.length() {
          abort("bench: missing value for --n")
        }
        count = @strconv.parse_int(args[i + 1]) catch {
          e => abort("bench: invalid --n: " + e.to_string())
        }
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
  if count <= 0 {
    abort("bench: --n must be > 0")
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
  let mut failed = false
  let mut total = 0
  let mut passed = 0
  let mut failed_count = 0
  let mut used_interpreter_fallback = false
  let file_count = entry_paths.length()
  for entry_path in entry_paths {
    let resolved_entry_path = @loader.resolve_entry_path(entry_path)
    match backend {
      BenchBackend::Interpreter =>
        match
          run_bench_blocks_interpreter_entry(
            resolved_entry_path, count, warmup, features,
          ) {
          Err(err) => {
            println("[\{entry_path}] \{err}")
            failed = true
          }
          Ok(report) => {
            if !print_bench_report(entry_path, report) {
              failed = true
            }
            total += report.total
            passed += report.passed
            failed_count += report.failed
          }
        }
      BenchBackend::Wasm =>
        match run_bench_blocks_wasm_entry(resolved_entry_path, count, warmup) {
          Err(err) =>
            if is_wasm_unsupported_compile_error(err) {
              used_interpreter_fallback = true
              println(
                "[\{entry_path}] wasm backend unsupported, fallback to interpreter: \{err}",
              )
              match
                run_bench_blocks_interpreter_entry(
                  resolved_entry_path, count, warmup, features,
                ) {
                Err(interp_err) => {
                  println("[\{entry_path}] \{interp_err}")
                  failed = true
                }
                Ok(report) => {
                  if !print_bench_report(entry_path, report) {
                    failed = true
                  }
                  total += report.total
                  passed += report.passed
                  failed_count += report.failed
                }
              }
            } else {
              println("[\{entry_path}] \{err}")
              failed = true
            }
          Ok(report) =>
            if wasm_bench_report_has_only_unsupported_compile_failures(report) {
              used_interpreter_fallback = true
              let reason = if report.failures.length() > 0 {
                report.failures[0].error
              } else {
                "unsupported wasm compile error"
              }
              println(
                "[\{entry_path}] wasm backend unsupported, fallback to interpreter: \{reason}",
              )
              match
                run_bench_blocks_interpreter_entry(
                  resolved_entry_path, count, warmup, features,
                ) {
                Err(interp_err) => {
                  println("[\{entry_path}] \{interp_err}")
                  failed = true
                }
                Ok(interp_report) => {
                  if !print_bench_report(entry_path, interp_report) {
                    failed = true
                  }
                  total += interp_report.total
                  passed += interp_report.passed
                  failed_count += interp_report.failed
                }
              }
            } else {
              if !print_wasm_bench_report(entry_path, report) {
                failed = true
              }
              total += report.total
              passed += report.passed
              failed_count += report.failed
            }
        }
    }
  }
  let backend_name = if backend == BenchBackend::Wasm &&
    used_interpreter_fallback {
    "wasm+interpreter-fallback"
  } else {
    bench_backend_name(backend)
  }
  println(
    "summary: files=\{file_count} backend=\{backend_name} total=\{total} passed=\{passed} failed=\{failed_count}",
  )
  if failed {
    abort("bench: failures detected")
  }
}

///|
fn run_bench_blocks_interpreter_entry(
  entry_path : String,
  count : Int,
  warmup : Int,
  features : @xsh_lib.RuntimeFeatureFlags,
) -> Result[@xsh_lib.BenchReport, String] {
  let (db, entry) = match @loader.load_db(entry_path) {
    Err(err) => return Err("load error: " + err)
    Ok(v) => v
  }
  let compiled = @xsh_lib.compile_module(db, entry) catch {
    e => return Err("compile error: " + e.to_string())
  }
  let rt = new_runtime_with_features(features)
  rt.set_type_env(compiled.type_env)
  let path_to_hash : Map[String, String] = {}
  load_imports_into_runtime(rt, db, entry, path_to_hash)
  let base_dir = @xsh_fs.parent_path(entry)
  for stmt in compiled.ast.stmts {
    match stmt {
      @xsh_core.Stmt::Import(source~, ..) =>
        match source {
          @xsh_core.ModuleRef::Path(path=raw_path) => {
            let resolved = @loader.resolve_import_path(base_dir, raw_path)
            match path_to_hash.get(resolved) {
              Some(hash) => path_to_hash[raw_path] = hash
              None => ()
            }
          }
          @xsh_core.ModuleRef::Hash(_)
          | @xsh_core.ModuleRef::Version(_)
          | @xsh_core.ModuleRef::Symbol(_) => ()
        }
      _ => ()
    }
  }
  let converted_ast = @xsh_core.convert_imports_to_hash(compiled.ast, fn(path) {
    path_to_hash.get(path)
  })
  for name, target in compiled.aliases {
    rt.set_alias(name, target)
  }
  let report = rt.run_benches(converted_ast, count, warmup) catch {
    e => return Err("eval error: " + e.to_string())
  }
  Ok(report)
}

///|
fn module_source_from_stmt_spans(
  source : String,
  stmts : Array[@xsh_core.Stmt],
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
  let prelude_stmts : Array[@xsh_core.Stmt] = []
  let cases : Array[BenchSourceCase] = []
  for stmt in ast.stmts {
    match stmt {
      @xsh_core.Stmt::Bench(name~, body~, span~) => {
        let _ = body
        let stmt_source = source_slice_by_span(source, span.start, span.end)
        let body_source = bench_stmt_body_source(stmt_source)
        cases.push({ name, body_source })
      }
      _ => prelude_stmts.push(stmt)
    }
  }
  let prelude_source = module_source_from_stmt_spans(source, prelude_stmts)
  Ok(BenchSourcePlan::{ prelude_source, cases })
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
  prelude_source : String,
  body_source : String,
  iterations : Int,
) -> String {
  let out = StringBuilder::new()
  let iter_name = "xsh_bench_iter_internal"
  if prelude_source.length() > 0 {
    out.write_string(prelude_source)
    if not(prelude_source.has_suffix("\n")) {
      out.write_char('\n')
    }
  }
  out.write_string("do {\n")
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
  out.write_string("0\n")
  out.to_string()
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
  // xsh-generated core wasm currently uses exception tags; enable by default.
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
  let mut dir = if is_dir { path } else { @xsh_fs.parent_path(path) }
  for _ in 0..<64 {
    let marker = dir + "/moon.mod.json"
    if is_existing_file(marker) {
      return dir
    }
    let parent = @xsh_fs.parent_path(dir)
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
  let use_submodule = match @sys.get_env_var("XSH_USE_WASMTIME_SUBMODULE") {
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
      "XSH_USE_WASMTIME_SUBMODULE=1 but deps/wasmtime binary is not built. run: just build-wasmtime-submodule",
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
  let wasm_flags = match @sys.get_env_var("XSH_WASMTIME_WASM_FLAGS") {
    Some(raw) => split_env_flags(raw)
    None => []
  }
  let wasm_flags = with_default_bench_wasm_flags(wasm_flags)
  let wasi_flags = match @sys.get_env_var("XSH_WASMTIME_WASI_FLAGS") {
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
  cmd.write_string(" --invoke run ")
  cmd.write_string(shell_quote_command_arg(wasm_path))
  cmd.to_string()
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
fn compile_bench_script_to_wasm(
  source_path : String,
  wasm_path : String,
  source : String,
) -> Result[Int, String] {
  @os_fs.write_string_to_file(source_path, source) catch {
    e => return Err("write source failed: " + e.to_string())
  }
  let (db, entry) = match @loader.load_db(source_path) {
    Err(err) => return Err("load error: " + err)
    Ok(v) => v
  }
  let wasm_bytes = @xsh_lib.compile_module_wasm_with_opt_level(
    db,
    entry,
    no_dce=true,
    opt_level=Some("-Oz"),
  ) catch {
    e => {
      let primary_err = e.to_string()
      if primary_err.contains("Optimize(") {
        @xsh_lib.compile_module_wasm_with_opt_level(
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
              e2.to_string() +
              ")",
            )
        }
      } else {
        return Err("compile wasm error: " + primary_err)
      }
    }
  }
  @os_fs.write_bytes_to_file(wasm_path, wasm_bytes) catch {
    e => return Err("write wasm failed: " + e.to_string())
  }
  Ok(wasm_bytes.length())
}

///|
fn run_wasm_case_measure(
  runner : BenchWasmRunner,
  source_path : String,
  wasm_path : String,
  source : String,
  count : Int,
) -> Result[(Double, Double, Int), String] {
  let wasm_bytes = match
    compile_bench_script_to_wasm(source_path, wasm_path, source) {
    Ok(bytes) => bytes
    Err(err) => return Err(err)
  }
  let start = @env.now()
  match run_wasmtime_bench_module(runner, wasm_path) {
    Ok(_) => ()
    Err(err) => return Err(err)
  }
  let end = @env.now()
  let elapsed_ms = (end - start).to_double()
  let per_us = elapsed_ms * 1000.0 / count.to_double()
  Ok((elapsed_ms, per_us, wasm_bytes))
}

///|
fn run_wasm_bench_case(
  runner : BenchWasmRunner,
  entry_path : String,
  case_index : Int,
  case_name : String?,
  case_body_source : String,
  prelude_source : String,
  count : Int,
  warmup : Int,
) -> Result[WasmBenchResult, WasmBenchFailure] {
  let parent_dir = @xsh_fs.parent_path(entry_path)
  let prefix = parent_dir +
    "/.xsh_bench_case_" +
    @env.now().to_string() +
    "_" +
    case_index.to_string()
  let warm_source_path = prefix + "_warm.xsh"
  let warm_wasm_path = prefix + "_warm.wasm"
  let run_source_path = prefix + "_run.xsh"
  let run_wasm_path = prefix + "_run.wasm"
  let warm_source = build_bench_case_loop_script(
    prelude_source, case_body_source, warmup,
  )
  let run_source = build_bench_case_loop_script(
    prelude_source, case_body_source, count,
  )
  let measured = if warmup > 0 {
    match
      compile_bench_script_to_wasm(
        warm_source_path, warm_wasm_path, warm_source,
      ) {
      Ok(_) =>
        match run_wasmtime_bench_module(runner, warm_wasm_path) {
          Ok(_) =>
            run_wasm_case_measure(
              runner, run_source_path, run_wasm_path, run_source, count,
            )
          Err(err) => Err("warmup run failed: " + err)
        }
      Err(err) => Err("warmup compile failed: " + err)
    }
  } else {
    run_wasm_case_measure(
      runner, run_source_path, run_wasm_path, run_source, count,
    )
  }
  remove_file_if_exists(warm_wasm_path)
  remove_file_if_exists(warm_source_path)
  remove_file_if_exists(run_wasm_path)
  remove_file_if_exists(run_source_path)
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
  let source = @os_fs.read_file_to_string(entry_path) catch {
    e => return Err("read error: " + e.to_string())
  }
  let plan = match extract_bench_source_plan(source) {
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
  features : @xsh_lib.RuntimeFeatureFlags,
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
      let rt = new_runtime_with_features(features)
      for _ in 0..<warmup {
        let compiled = match compile_entry(path) {
          Err(err) => abort("bench-file: " + err)
          Ok(v) => v
        }
        let _ = rt.run_compiled(compiled) catch {
          e => abort("bench-file: " + e.to_string())
        }
      }
      let start = @env.now()
      for _ in 0..<count {
        let compiled = match compile_entry(path) {
          Err(err) => abort("bench-file: " + err)
          Ok(v) => v
        }
        let _ = rt.run_compiled(compiled) catch {
          e => abort("bench-file: " + e.to_string())
        }
      }
      let end = @env.now()
      let elapsed_ms = (end - start).to_double()
      let per_us = elapsed_ms * 1000.0 / count.to_double()
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

///|
fn repl_cmd(
  args : Array[String],
  syntax_mode : @xsh_lib.ParserMode,
  features : @xsh_lib.RuntimeFeatureFlags,
) -> Unit {
  if args.length() != 0 {
    abort("repl: no args supported")
  }
  let rt = new_runtime_with_features(features)
  let (namespace_name, scratch_db_path) = match resolve_scratch_db_path() {
    Ok(v) => v
    Err(err) => abort("repl: " + err)
  }
  let restored_source = match load_eval_db_source(scratch_db_path) {
    Ok(v) => v
    Err(err) => abort("repl: " + err)
  }
  if restored_source.trim().length() > 0 {
    let _ = rt.eval_script_with_mode(restored_source, syntax_mode) catch {
      e => abort("repl: failed to restore namespace db: " + e.to_string())
    }
  }
  let (initial_cols, initial_rows) = @tui.get_terminal_size()
  let (app, cleanup) = @tui.init_vnode_terminal(
    initial_cols, initial_rows, @tui.print_raw,
  )
  let width = Ref::new(initial_cols)
  let height = Ref::new(initial_rows)
  let outputs : Array[String] = []
  let history : Array[String] = []
  let xsh_names : Array[String] = @checker.prelude_names()
  let history_idx = Ref::new(-1)
  let history_draft = Ref::new("")
  let completion_session = @editor.CompletionSession::new()
  let completion_request_id : Ref[Int] = Ref::new(0)
  let last_popup_rect : Ref[OverlayRect?] = Ref::new(None)
  let completion_anchor : Ref[CompletionAnchor?] = Ref::new(None)
  let cleaned = Ref::new(false)
  fn cleanup_once() -> Unit {
    if cleaned.val {
      return
    }
    cleaned.val = true
    cleanup()
  }

  let input_rows = Ref::new(repl_input_rows_for_height(initial_rows))
  let input_editor = @editor.EditorState::new_with_kind(
    "",
    input_rows.val,
    @editor.HighlightKind::Plain,
  )
  let scratch_source_ref = Ref::new(restored_source)
  fn set_input_text(text : String) -> Unit {
    input_editor.set_text("")
    if text.length() > 0 {
      input_editor.replace_selection(text)
    }
  }

  fn push_unique(list : Array[String], value : String) -> Unit {
    for existing in list {
      if existing == value {
        return
      }
    }
    list.push(value)
  }

  fn collect_shell_commands() -> Array[String] {
    let out : Array[String] = []
    match @sys.get_env_var("PATH") {
      None => ()
      Some(path) =>
        for dir_view in path.split(":") {
          let dir = dir_view.to_string()
          let entries = @os_fs.read_dir(dir) catch { _ => [] }
          for name in entries {
            let full_path = dir + "/" + name
            let is_file = @os_fs.is_file(full_path) catch { _ => false }
            if is_file {
              push_unique(out, name)
            }
          }
        }
    }
    out
  }

  let shell_commands = collect_shell_commands()
  let xsh_builtins = ["sh", "path", "addr", "exit"]
  let xsh_keywords = [
    "let", "rec", "if", "match", "do", "record", "test", "import", "true", "false",
  ]
  fn completion_visible() -> Bool {
    completion_session.is_visible() &&
    completion_session.get_items().length() > 0
  }

  fn current_view_state() -> ReplViewState {
    {
      width: width.val,
      height: height.val,
      input_rows: input_rows.val,
      outputs,
      history_len: history.length(),
    }
  }

  fn clear_rect(rect : OverlayRect) -> Unit {
    if rect.width <= 0 || rect.height <= 0 {
      return
    }
    let blank = " ".repeat(rect.width)
    for i = 0; i < rect.height; i = i + 1 {
      @tui.print_raw(@render.ansi_move_to(rect.row + i, rect.col) + blank)
    }
  }

  fn pad_to_width(text : String, width : Int) -> String {
    if width <= 0 {
      ""
    } else {
      let w = @core.string_display_width(text)
      if w >= width {
        text
      } else {
        text + " ".repeat(width - w)
      }
    }
  }

  fn completion_overlay(
    view : ReplViewState,
  ) -> (String?, OverlayRect?, CompletionAnchor?) {
    if not(completion_visible()) {
      return (None, None, None)
    }
    let items = completion_session.get_items()
    if items.length() == 0 {
      return (None, None, None)
    }
    let view_width = if view.width > 1 { view.width } else { 1 }
    let content_start = editor_content_start_col(input_editor)
    let screen_col = if content_start < view_width { content_start } else { 0 }
    let content_width = view_width - screen_col
    if content_width <= 1 {
      return (None, None, None)
    }
    let max_rows = 8
    let selected = completion_session.get_selected_index()
    let mut max_label_width = 0
    for item in items {
      let w = @core.string_display_width(item.label)
      if w > max_label_width {
        max_label_width = w
      }
    }
    let base_width = max_label_width + 1
    let cell_width = if base_width > content_width {
      content_width
    } else {
      base_width
    }
    if cell_width <= 0 {
      return (None, None, None)
    }
    let col_gap = 2
    let total_cell = cell_width + col_gap
    let cols = if total_cell <= content_width {
      let count = (content_width + col_gap) / total_cell
      if count > 0 {
        count
      } else {
        1
      }
    } else {
      1
    }
    let total_rows = (items.length() + cols - 1) / cols
    let preferred_rows = if total_rows > max_rows {
      max_rows
    } else {
      total_rows
    }
    if preferred_rows <= 0 {
      return (None, None, None)
    }
    let input_origin = repl_input_origin_row(view)
    let anchor_row = input_origin + view.input_rows - 1
    let available_below = view.height - footer_rows() - (anchor_row + 1)
    let available_above = anchor_row - header_rows()
    let anchor = pick_completion_anchor(
      completion_anchor.val,
      available_above,
      available_below,
    )
    let mut screen_row = 0
    let mut visible_rows = 0
    let mut chosen_anchor : CompletionAnchor? = None
    match anchor {
      Some(CompletionAnchor::Below) => {
        let v = if preferred_rows > available_below {
          available_below
        } else {
          preferred_rows
        }
        screen_row = anchor_row + 1
        visible_rows = v
        chosen_anchor = Some(CompletionAnchor::Below)
      }
      Some(CompletionAnchor::Above) => {
        let v = if preferred_rows > available_above {
          available_above
        } else {
          preferred_rows
        }
        screen_row = anchor_row - v
        visible_rows = v
        chosen_anchor = Some(CompletionAnchor::Above)
      }
      None => return (None, None, None)
    }
    if visible_rows <= 0 {
      return (None, None, None)
    }
    let selected_row = if selected >= 0 { selected / cols } else { 0 }
    let start_row = if total_rows <= visible_rows {
      0
    } else {
      let half = visible_rows / 2
      let s = selected_row - half
      if s < 0 {
        0
      } else if s + visible_rows > total_rows {
        total_rows - visible_rows
      } else {
        s
      }
    }
    let row_nodes : Array[@tui.TuiNode] = []
    let mut r = 0
    while r < visible_rows {
      let row_idx = start_row + r
      let cells : Array[@tui.TuiNode] = []
      let mut c = 0
      while c < cols {
        let idx = row_idx * cols + c
        let is_selected = idx == selected
        if idx < items.length() {
          let prefix = if is_selected { ">" } else { " " }
          let cell_text = pad_to_width(
            truncate_text(prefix + items[idx].label, cell_width),
            cell_width,
          )
          let fg = if is_selected { "white" } else { "rgb(170,170,170)" }
          cells.push(@tui.text(cell_text, fg~, bold=is_selected))
        } else {
          cells.push(@tui.text(" ".repeat(cell_width)))
        }
        if c < cols - 1 {
          cells.push(@tui.text(" ".repeat(col_gap), fg="rgb(90,90,90)"))
        }
        c += 1
      }
      row_nodes.push(@tui.row(cells))
      r += 1
    }
    let node = @tui.column(row_nodes)
    let overlay = @vnode.render_overlay_at(screen_col, screen_row, node)
    let rect : OverlayRect = {
      row: screen_row,
      col: screen_col,
      width: content_width,
      height: visible_rows,
    }
    (Some(overlay), Some(rect), chosen_anchor)
  }

  fn do_render() -> Unit {
    let view = current_view_state()
    let (overlay, next_rect, next_anchor) = completion_overlay(view)
    let mut need_clear = false
    match (last_popup_rect.val, next_rect) {
      (Some(prev), Some(next)) =>
        if not(prev.eq(next)) {
          clear_rect(prev)
          need_clear = true
        }
      (Some(prev), None) => {
        clear_rect(prev)
        need_clear = true
      }
      _ => ()
    }
    if need_clear {
      app.clear_prev_buffer()
    }
    @tui.print_raw(app.render_frame(render_repl_view(view, input_editor)))
    match overlay {
      Some(overlay_text) => @tui.print_raw(overlay_text)
      None => ()
    }
    last_popup_rect.val = next_rect
    completion_anchor.val = next_anchor
    let (cursor_row, cursor_col) = repl_cursor_pos(view, input_editor)
    @tui.print_raw(
      @render.ansi_move_to(cursor_row, cursor_col) + @render.ansi_show_cursor(),
    )
  }

  fn push_output_line(line : String) -> Unit {
    outputs.push(line)
  }

  fn run_command(cmd : String) -> Bool {
    let trimmed = cmd.trim().to_string()
    if trimmed.length() == 0 {
      return true
    }
    match trimmed {
      ":q" | ":quit" | ":exit" | "exit" => return false
      _ => ()
    }
    push_output_line("> " + trimmed)
    let result = rt.eval_script_with_mode(trimmed, syntax_mode) catch {
      e => {
        push_output_line("error: " + e.to_string())
        return true
      }
    }
    match result.last {
      Some(value) => push_output_line("last: " + value.to_string())
      None => ()
    }
    for effect in result.effects {
      match effect {
        @xsh_lib.Effect::PosixDesugar(message) =>
          push_output_line("note: " + message)
        _ => push_output_line("effect: " + effect.to_string())
      }
    }
    scratch_source_ref.val = append_eval_db_source(
      scratch_source_ref.val,
      trimmed,
    )
    match write_eval_db_source(scratch_db_path, scratch_source_ref.val) {
      Ok(_) => ()
      Err(err) => {
        push_output_line("error: failed to persist namespace db: " + err)
        return true
      }
    }
    match extract_let_name(trimmed) {
      Some(name) => {
        push_unique(xsh_names, name)
        match rt.get_addr(name) {
          Some(addr) =>
            push_output_line("addr: " + name + "#" + short_hash(addr))
          None => ()
        }
      }
      None => ()
    }
    true
  }

  fn update_completion() -> Unit {
    let next_id = completion_request_id.val + 1
    completion_request_id.val = next_id
    let req = input_editor.completion_request(next_id)
    if is_in_fn_param_context(req.line_text, req.col) {
      completion_session.clear()
      return
    }
    let context = detect_completion_context(req.line_text, req.col)
    let method_info = detect_method_completion(req.line_text, req.col)
    let pipe_info = detect_pipe_completion(req.line_text, req.col)
    let prefix = match method_info {
      Some(info) => info.prefix
      None =>
        match pipe_info {
          Some(info) => info.prefix
          None => req.prefix
        }
    }
    let receiver_name = match method_info {
      Some(info) => Some(info.receiver)
      None =>
        match pipe_info {
          Some(info) => Some(info.receiver)
          None => None
        }
    }
    let env = rt.type_env()
    let receiver_ty = match receiver_name {
      Some(name) => env.get(name)
      None => None
    }
    fn accepts_receiver(name : String) -> Bool {
      match receiver_ty {
        None => true
        Some(rty) =>
          match env.get(name) {
            Some(@xsh_core.Type::Func(params~, ..)) => {
              let mut found = false
              let mut ok = false
              for param in params {
                if @xsh_core.ParamLabel::is_positional(param.label) {
                  found = true
                  ok = @checker.completion_param_matches(env, rty, param.ty)
                  break
                }
              }
              found && ok
            }
            _ => false
          }
      }
    }

    let method_like = method_info is Some(_) || pipe_info is Some(_)
    if prefix.length() == 0 && not(method_like) {
      completion_session.clear()
      return
    }
    completion_session.set_request(req)
    let items : Array[String] = []
    match context {
      CompletionContext::Shell => {
        let mut idx = history.length() - 1
        while idx >= 0 {
          let entry = history[idx]
          if entry.has_prefix(prefix) {
            push_unique(items, entry)
          }
          idx -= 1
        }
        for item in shell_commands {
          if item.has_prefix(prefix) {
            push_unique(items, item)
          }
        }
      }
      CompletionContext::XshLetName =>
        for name in xsh_names {
          if name.has_prefix(prefix) {
            push_unique(items, name)
          }
        }
      CompletionContext::XshLetExpr | CompletionContext::XshExpr => {
        if not(method_like) {
          for item in xsh_keywords {
            if item.has_prefix(prefix) {
              push_unique(items, item)
            }
          }
        }
        for item in xsh_builtins {
          if item.has_prefix(prefix) && accepts_receiver(item) {
            push_unique(items, item)
          }
        }
        for name in xsh_names {
          if name.has_prefix(prefix) && accepts_receiver(name) {
            push_unique(items, name)
          }
        }
      }
    }
    let response : @editor.CompletionResponse = {
      id: req.id,
      items: items.map(fn(item) {
        let insert_text = match method_info {
          Some(info) =>
            if req.prefix.contains(".") {
              info.receiver + "." + item
            } else {
              item
            }
          None => item
        }
        @editor.CompletionItem::{
          label: item,
          insert_text,
          detail: None,
          documentation: None,
        }
      }),
      is_incomplete: false,
    }
    let _ = completion_session.apply_response(response)
    if items.length() == 1 && items[0] == req.prefix {
      completion_session.hide()
    }
  }

  fn apply_completion() -> Bool {
    match completion_session.get_selected_item() {
      Some(item) => {
        input_editor.replace_current_word(item.insert_text)
        update_completion()
        true
      }
      None => false
    }
  }

  fn set_history_entry(idx : Int) -> Unit {
    let pos = history.length() - 1 - idx
    let value = history[pos]
    set_input_text(value)
  }

  fn history_prev() -> Unit {
    if history.length() == 0 {
      return
    }
    if history_idx.val == -1 {
      history_draft.val = input_editor.get_text()
    }
    if history_idx.val + 1 < history.length() {
      history_idx.val = history_idx.val + 1
      set_history_entry(history_idx.val)
    }
  }

  fn history_next() -> Unit {
    if history_idx.val <= 0 {
      if history_idx.val == 0 {
        history_idx.val = -1
        set_input_text(history_draft.val)
      }
      return
    }
    history_idx.val = history_idx.val - 1
    set_history_entry(history_idx.val)
  }

  fn handle_resize(new_width : Int, new_height : Int) -> Unit {
    width.val = new_width
    height.val = new_height
    app.resize(new_width, new_height)
    let next_rows = repl_input_rows_for_height(new_height)
    if next_rows != input_rows.val {
      input_rows.val = next_rows
      input_editor.set_height(next_rows)
    }
    do_render()
  }

  fn handle_key(input : String) -> Unit {
    if input.length() == 0 {
      return
    }
    if input.length() > 1 &&
      input[0].to_int() != 0x1b &&
      @tui.is_printable_string(input) {
      input_editor.replace_selection(input)
      history_idx.val = -1
      update_completion()
      do_render()
      return
    }
    let event = @tui.parse_input(input)
    if event.is_ctrl_c() {
      cleanup_once()
      return
    }
    match event {
      @tui.InputEvent::Resize(new_width, new_height) => {
        handle_resize(new_width, new_height)
        return
      }
      @tui.InputEvent::Key(key_event) => {
        let mut should_update_completion = false
        match key_event {
          @tui.KeyEvent::Special(@tui.SpecialKey::Up, _) =>
            if completion_visible() {
              completion_session.select_prev()
              do_render()
              return
            } else {
              history_prev()
              update_completion()
              do_render()
              return
            }
          @tui.KeyEvent::Special(@tui.SpecialKey::Down, _) =>
            if completion_visible() {
              completion_session.select_next()
              do_render()
              return
            } else {
              history_next()
              update_completion()
              do_render()
              return
            }
          @tui.KeyEvent::Special(@tui.SpecialKey::Tab, _) => {
            if completion_visible() {
              if apply_completion() {
                do_render()
                return
              }
            } else {
              update_completion()
            }
            do_render()
            return
          }
          @tui.KeyEvent::Special(@tui.SpecialKey::BackTab, _) => {
            if completion_visible() {
              completion_session.select_prev()
            }
            do_render()
            return
          }
          @tui.KeyEvent::Special(@tui.SpecialKey::Enter, _) => {
            if completion_visible() && apply_completion() {
              do_render()
              return
            }
            let ok = run_command(input_editor.get_text())
            if !ok {
              cleanup_once()
              return
            }
            let input_value = input_editor.get_text().trim().to_string()
            if input_value.length() > 0 {
              history.push(input_value)
            }
            set_input_text("")
            history_idx.val = -1
            update_completion()
            do_render()
            return
          }
          @tui.KeyEvent::Special(@tui.SpecialKey::Escape, _) => {
            completion_session.hide()
            do_render()
            return
          }
          @tui.KeyEvent::Special(@tui.SpecialKey::Backspace, _) =>
            should_update_completion = true
          @tui.KeyEvent::Char(_, @tui.KeyModifier::None)
          | @tui.KeyEvent::Char(_, @tui.KeyModifier::Shift) =>
            should_update_completion = true
          _ => ()
        }
        @editor.handle_key_event(input_editor, key_event)
        if should_update_completion {
          update_completion()
        }
        history_idx.val = -1
        do_render()
      }
      _ => ()
    }
  }

  do_render()
  push_output_line("namespace: " + namespace_name + " db=" + scratch_db_path)
  do_render()
  @tui.start_keypress_listener(handle_key)
  cleanup_once()
}

///|
fn repl_stdin_cmd(
  args : Array[String],
  syntax_mode : @xsh_lib.ParserMode,
  features : @xsh_lib.RuntimeFeatureFlags,
) -> Unit {
  run_eval_line_repl_with_prompt(
    args, "repl-stdin", "xsh> ", syntax_mode, features,
  )
}

///|
fn repl_wasi_cmd(
  args : Array[String],
  syntax_mode : @xsh_lib.ParserMode,
  features : @xsh_lib.RuntimeFeatureFlags,
) -> Unit {
  run_eval_line_repl_with_prompt(
    args, "repl-wasi", "wasi> ", syntax_mode, features,
  )
}

///|
fn print_line_repl_tty_mode(mode : LineReplIoMode) -> Unit {
  match mode {
    LineReplIoMode::Tty =>
      println(
        "note: --tty mode is enabled (line backend; PTY is not enabled yet)",
      )
    LineReplIoMode::Plain => ()
  }
}

///|
fn run_eval_line_repl_with_prompt(
  args : Array[String],
  cmd_name : String,
  prompt : String,
  syntax_mode : @xsh_lib.ParserMode,
  features : @xsh_lib.RuntimeFeatureFlags,
) -> Unit {
  let options = match parse_line_repl_options(args, cmd_name, prompt) {
    Ok(opts) => opts
    Err(msg) => abort(msg)
  }
  let (namespace_name, scratch_db_path) = match resolve_scratch_db_path() {
    Ok(v) => v
    Err(err) => abort(cmd_name + ": " + err)
  }
  async fn repl_loop() {
    let rt = new_runtime_with_features(features)
    let mut scratch_source = match load_eval_db_source(scratch_db_path) {
      Ok(v) => v
      Err(err) => {
        println("error: " + err)
        return
      }
    }
    if scratch_source.trim().length() > 0 {
      let _ = rt.eval_script_with_mode(scratch_source, syntax_mode) catch {
        e => {
          println("error: failed to restore namespace db: " + e.to_string())
          return
        }
      }
    }
    let input = @stdio.stdin
    print_line_repl_tty_mode(options.io_mode)
    println("namespace: " + namespace_name + " db=" + scratch_db_path)
    if options.prompt_enabled {
      @stdio.stdout.write(options.prompt)
    }
    while input.read_until("\n") is Some(line) {
      let trimmed = line.trim()
      if trimmed.is_empty() {
        if options.prompt_enabled {
          @stdio.stdout.write(options.prompt)
        }
        continue
      }
      let line_str = trimmed.to_string()
      match line_str {
        ":q" | ":quit" | ":exit" | "exit" => break
        _ => {
          let result = rt.eval_script_with_mode(line_str, syntax_mode) catch {
            e => {
              println("error: " + e.to_string())
              if options.prompt_enabled {
                @stdio.stdout.write(options.prompt)
              }
              continue
            }
          }
          print_eval_result(result)
          match extract_let_name(line_str) {
            Some(name) =>
              match rt.get_addr(name) {
                Some(addr) => println("addr: " + name + "#" + short_hash(addr))
                None => ()
              }
            None => ()
          }
          scratch_source = append_eval_db_source(scratch_source, line_str)
          match write_eval_db_source(scratch_db_path, scratch_source) {
            Ok(_) => ()
            Err(err) => println("error: failed to persist namespace db: " + err)
          }
        }
      }
      if options.prompt_enabled {
        @stdio.stdout.write(options.prompt)
      }
    }
  }

  @async.run_async_main(repl_loop)
}

///|
/// WASM REPL: compile each expression to WASM and output to file
fn wasm_repl_stdin_cmd(args : Array[String]) -> Unit {
  let mut prompt_enabled = true
  let mut out_dir = "/tmp"
  let mut counter = 0
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--no-prompt" => {
        prompt_enabled = false
        i += 1
      }
      "-o" | "--out-dir" => {
        if i + 1 >= args.length() {
          abort("wasm-repl-stdin: missing output directory after " + arg)
        }
        out_dir = args[i + 1]
        i += 2
      }
      _ => abort("wasm-repl-stdin: unknown arg " + arg)
    }
  }
  // Ensure output directory exists
  if not(@os_fs.path_exists(out_dir)) {
    @os_fs.create_dir(out_dir) catch {
      e =>
        abort("wasm-repl-stdin: failed to create output dir: " + e.to_string())
    }
  }
  async fn repl_loop() {
    let prompt = "wasm> "
    let input = @stdio.stdin
    if prompt_enabled {
      @stdio.stdout.write(prompt)
    }
    while input.read_until("\n") is Some(line) {
      let trimmed = line.trim()
      if trimmed.is_empty() {
        if prompt_enabled {
          @stdio.stdout.write(prompt)
        }
        continue
      }
      let line_str = trimmed.to_string()
      match line_str {
        ":q" | ":quit" | ":exit" | "exit" => break
        _ => {
          // Create a temporary source for compilation
          let db = @xsh_lib.XshDb::new()
          let tmp_path = "/tmp/wasm_repl_" + counter.to_string() + ".xsh"
          db.set_source(tmp_path, line_str)
          // Compile to WASM
          let wasm_bytes = @xsh_lib.compile_module_wasm(db, tmp_path) catch {
            e => {
              println("error: " + e.to_string())
              if prompt_enabled {
                @stdio.stdout.write(prompt)
              }
              continue
            }
          }
          // Write WASM to file
          let out_path = out_dir + "/expr_" + counter.to_string() + ".wasm"
          @os_fs.write_bytes_to_file(out_path, wasm_bytes) catch {
            e => {
              println("error writing file: " + e.to_string())
              if prompt_enabled {
                @stdio.stdout.write(prompt)
              }
              continue
            }
          }
          println(
            "wrote " +
            out_path +
            " (" +
            wasm_bytes.length().to_string() +
            " bytes)",
          )
          counter += 1
        }
      }
      if prompt_enabled {
        @stdio.stdout.write(prompt)
      }
    }
  }

  @async.run_async_main(repl_loop)
}

///|
fn print_eval_result(result : @xsh_lib.EvalResult) -> Unit {
  match result.last {
    Some(value) => println("last: " + value.to_string())
    None => ()
  }
  for effect in result.effects {
    match effect {
      @xsh_lib.Effect::PosixDesugar(message) => println("note: " + message)
      _ => println("effect: " + effect.to_string())
    }
  }
}

///|
fn load_eval_db_source(path : String) -> Result[String, String] {
  if not(@os_fs.path_exists(path)) {
    return Ok("")
  }
  let is_file = @os_fs.is_file(path) catch { _ => false }
  if not(is_file) {
    return Err("db path is not a file: " + path)
  }
  let source = @os_fs.read_file_to_string(path) catch {
    e => return Err("failed to read db `" + path + "`: " + e.to_string())
  }
  Ok(source)
}

///|
struct EvalScopeSymbol {
  name : String
  kind : String
  signature : String
  path : String
  def_id : String
} derive(Show, Eq)

///|
fn eval_scope_symbol_id_from_entry(entry : @xsh_lib.SymbolEntry) -> String {
  let key = entry.path +
    "|" +
    entry.span.start.to_string() +
    "|" +
    entry.span.end.to_string() +
    "|" +
    entry.name +
    "|" +
    @xsh_lib.symbol_kind_name(entry.kind) +
    "|" +
    entry.signature
  @xsh_core.git_blob_hash_string(key)
}

///|
fn collect_eval_scope_symbols(
  path : String,
  source : String,
) -> Array[EvalScopeSymbol] {
  if source.trim().to_string().length() == 0 {
    return []
  }
  let db = @xsh_lib.XshDb::new()
  db.set_source(path, source)
  let index = @xsh_lib.build_symbol_index(db, [path])
  let out : Array[EvalScopeSymbol] = []
  for entry in index.entries {
    if entry.path != path {
      continue
    }
    out.push({
      name: entry.name,
      kind: @xsh_lib.symbol_kind_name(entry.kind),
      signature: entry.signature,
      path: entry.path,
      def_id: eval_scope_symbol_id_from_entry(entry),
    })
  }
  out
}

///|
fn eval_scope_symbols_json(scope : Array[EvalScopeSymbol]) -> Json {
  let symbols : Array[Json] = []
  for symbol in scope {
    let obj : Map[String, Json] = {}
    obj["name"] = Json::string(symbol.name)
    obj["kind"] = Json::string(symbol.kind)
    obj["signature"] = Json::string(symbol.signature)
    obj["path"] = Json::string(symbol.path)
    obj["hash"] = Json::string(symbol.def_id)
    obj["short_hash"] = Json::string(short_hash(symbol.def_id))
    symbols.push(Json::object(obj))
  }
  let out : Map[String, Json] = {}
  out["ok"] = Json::boolean(true)
  out["symbols"] = Json::array(symbols)
  Json::object(out)
}

///|
fn eval_scope_signature_for_name(
  scope : Array[EvalScopeSymbol],
  name : String,
) -> String? {
  for symbol in scope {
    if symbol.name == name {
      return Some(symbol.signature)
    }
  }
  None
}

///|
fn validate_eval_type_assertions(
  assertions : Array[EvalTypeAssertion],
  scope : Array[EvalScopeSymbol],
) -> Result[Unit, String] {
  for assertion in assertions {
    let actual = match eval_scope_signature_for_name(scope, assertion.name) {
      Some(signature) => signature
      None => return Err("assert symbol not found: " + assertion.name)
    }
    if actual != assertion.expected_signature {
      return Err(
        "assert type mismatch: " +
        assertion.name +
        " expected `" +
        assertion.expected_signature +
        "` actual `" +
        actual +
        "`",
      )
    }
  }
  Ok(())
}

///|
fn clone_json_map(src : Map[String, Json]) -> Map[String, Json] {
  let out : Map[String, Json] = {}
  for key, value in src {
    out[key] = value
  }
  out
}

///|
fn default_scratch_ns_name() -> String {
  "scratch"
}

///|
fn workspace_probe_entry_path() -> String {
  @xsh_fs.normalize_path(@io.current_dir_or_root() + "/__scratch__.xsh")
}

///|
fn current_workspace_index_root() -> String {
  @codebase.resolve_index_root(workspace_probe_entry_path())
}

///|
fn default_ns_db_rel_path(ns_name : String) -> String {
  ".xsh/namespaces/" + ns_name + ".db"
}

///|
fn load_index_xdb_object(path : String) -> Map[String, Json] {
  let obj : Map[String, Json] = {}
  if not(@os_fs.path_exists(path)) {
    return obj
  }
  let source = @os_fs.read_file_to_string(path) catch { _ => return obj }
  let parsed : Json = @json.parse(source) catch { _ => return obj }
  match parsed {
    Json::Object(current) => {
      for key, value in current {
        obj[key] = value
      }
      obj
    }
    _ => obj
  }
}

///|
fn write_index_xdb_object(
  index_xdb_path : String,
  obj : Map[String, Json],
) -> Result[Unit, String] {
  @os_fs.write_string_to_file(
    index_xdb_path,
    Json::object(obj).stringify() + "\n",
  ) catch {
    e => return Err("write index.xdb: " + e.to_string())
  }
  Ok(())
}

///|
fn resolve_active_ns_name_from_index_xdb(xdb : Map[String, Json]) -> String {
  match xdb.get("active_namespace") {
    Some(Json::String(name)) =>
      if name.trim().to_string().length() > 0 {
        name.trim().to_string()
      } else {
        default_scratch_ns_name()
      }
    _ => default_scratch_ns_name()
  }
}

///|
fn resolve_ns_db_rel_path_from_index_xdb(
  xdb : Map[String, Json],
  ns_name : String,
) -> String {
  match xdb.get("namespaces") {
    Some(Json::Object(namespaces)) =>
      match namespaces.get(ns_name) {
        Some(Json::Object(ns_obj)) =>
          match ns_obj.get("db_path") {
            Some(Json::String(path)) =>
              if path.trim().to_string().length() > 0 {
                path.trim().to_string()
              } else {
                default_ns_db_rel_path(ns_name)
              }
            _ => default_ns_db_rel_path(ns_name)
          }
        _ => default_ns_db_rel_path(ns_name)
      }
    _ => default_ns_db_rel_path(ns_name)
  }
}

///|
fn to_absolute_db_path(index_root : String, db_path : String) -> String {
  if db_path.has_prefix("/") {
    @xsh_fs.normalize_path(db_path)
  } else {
    @xsh_fs.normalize_path(index_root + "/" + db_path)
  }
}

///|
fn resolve_scratch_db_path_for_index_root(
  index_root : String,
) -> Result[(String, String), String] {
  match @sys.get_env_var("XSH_SCRATCH_DB_PATH") {
    Some(path) =>
      if path.trim().to_string().length() == 0 {
        Err("XSH_SCRATCH_DB_PATH must not be empty")
      } else {
        Ok((default_scratch_ns_name(), @loader.resolve_entry_path(path)))
      }
    None => {
      let xsh_dir = find_xsh_dir(index_root + "/index.xsh")
      let index_xdb_path = index_root + "/index.xdb"
      let xdb = load_index_xdb_object(index_xdb_path)
      let ns_name = resolve_active_ns_name_from_index_xdb(xdb)
      let db_rel = resolve_ns_db_rel_path_from_index_xdb(xdb, ns_name)
      let db_path = to_absolute_db_path(index_root, db_rel)
      let next_xdb = clone_json_map(xdb)
      next_xdb["active_namespace"] = Json::string(ns_name)
      let namespaces = match xdb.get("namespaces") {
        Some(Json::Object(current)) => clone_json_map(current)
        _ => {}
      }
      let ns_obj = match namespaces.get(ns_name) {
        Some(Json::Object(current)) => clone_json_map(current)
        _ => {}
      }
      let db_path_in_xdb = if db_path.has_prefix(xsh_dir) {
        default_ns_db_rel_path(ns_name)
      } else {
        db_path
      }
      ns_obj["db_path"] = Json::string(db_path_in_xdb)
      ns_obj["updated_at"] = Json::string(@env.now().to_string())
      namespaces[ns_name] = Json::object(ns_obj)
      next_xdb["namespaces"] = Json::object(namespaces)
      match write_index_xdb_object(index_xdb_path, next_xdb) {
        Ok(_) => ()
        Err(err) => return Err(err)
      }
      Ok((ns_name, db_path))
    }
  }
}

///|
fn eval_include_base_dir(options : EvalCmdOptions) -> String {
  match options.db_path {
    Some(path) => @xsh_fs.parent_path(@loader.resolve_entry_path(path))
    None => "."
  }
}

///|
fn path_last_segment(path : String) -> String {
  let parts : Array[String] = []
  for part in path.split("/") {
    let text = part.to_string()
    if text.length() > 0 {
      parts.push(text)
    }
  }
  if parts.length() == 0 {
    ""
  } else {
    parts[parts.length() - 1]
  }
}

///|
fn parse_include_hash_alias(source : String) -> String? {
  let trimmed = source.trim().to_string()
  if trimmed.has_prefix("hash:") {
    let hash = trimmed
      .unsafe_substring(start=5, end=trimmed.length())
      .trim()
      .to_string()
    if hash.length() == 0 {
      None
    } else {
      Some(hash)
    }
  } else {
    let parsed : Json = @json.parse(trimmed) catch { _ => return None }
    match parsed {
      Json::Object(obj) =>
        match obj.get("hash") {
          Some(Json::String(hash)) => {
            let normalized = hash.trim().to_string()
            if normalized.length() == 0 {
              None
            } else {
              Some(normalized)
            }
          }
          _ => None
        }
      _ => None
    }
  }
}

///|
fn load_git_blob_source_from_objects_dir(
  objects_dir : String,
  hash : String,
) -> Result[String, String] {
  if not(@os_fs.path_exists(objects_dir)) {
    return Err("git objects dir not found: " + objects_dir)
  }
  let git_dir = @xsh_fs.parent_path(objects_dir)
  let fs = @osfs.OsFs::new()
  let db = @gitlib.ObjectDb::load_lazy(fs, git_dir) catch {
    e =>
      return Err(
        "failed to load git object db `" + objects_dir + "`: " + e.to_string(),
      )
  }
  let id = @bit.ObjectId::from_hex(hash) catch {
    e => return Err("invalid object hash `" + hash + "`: " + e.to_string())
  }
  let obj = db.get(fs, id) catch {
    e =>
      return Err("failed to read git object `" + hash + "`: " + e.to_string())
  }
  match obj {
    Some(pack_obj) => Ok(@utf8.decode_lossy(pack_obj.data[:]))
    None => Err("git object not found: " + hash)
  }
}

///|
fn try_load_hash_source_from_root(root : String, hash : String) -> String? {
  let codebase = @codebase.Codebase::new(root)
  match codebase.read_object(hash) {
    Some(content) => return Some(content)
    None => ()
  }
  let objects_dir = @xsh_fs.normalize_path(root + "/.git/objects")
  match load_git_blob_source_from_objects_dir(objects_dir, hash) {
    Ok(content) => Some(content)
    Err(_) => None
  }
}

///|
fn load_eval_include_source(
  include_spec : String,
  base_dir : String,
  include_lib_dir : String,
) -> Result[String, String] {
  let path = resolve_eval_include_path(base_dir, include_spec, include_lib_dir)
  if not(@os_fs.path_exists(path)) {
    return Err("include not found: " + include_spec + " -> " + path)
  }
  let is_file = @os_fs.is_file(path) catch { _ => false }
  if not(is_file) {
    return Err("include path is not a file: " + include_spec + " -> " + path)
  }
  let source = @os_fs.read_file_to_string(path) catch {
    e =>
      return Err(
        "failed to read include `" +
        include_spec +
        "` (" +
        path +
        "): " +
        e.to_string(),
      )
  }
  match parse_include_hash_alias(source) {
    Some(hash) => {
      let roots : Array[String] = []
      let include_parent = @xsh_fs.parent_path(path)
      if path_last_segment(include_parent) == "xsh" {
        roots.push(@xsh_fs.parent_path(include_parent))
      }
      if roots.length() == 0 || roots[0] != include_lib_dir {
        roots.push(include_lib_dir)
      }
      for root in roots {
        match try_load_hash_source_from_root(root, hash) {
          Some(content) => return Ok(content)
          None => ()
        }
      }
      Err(
        "hash alias `" +
        include_spec +
        "` unresolved: object `" +
        hash +
        "` not found in local stores",
      )
    }
    None => Ok(source)
  }
}

///|
fn append_eval_db_source(base_source : String, expr : String) -> String {
  let trimmed = expr.trim().to_string()
  if trimmed.length() == 0 {
    return base_source
  }
  let out = StringBuilder::new()
  if base_source.length() > 0 {
    out.write_string(base_source)
    if not(base_source.has_suffix("\n")) {
      out.write_char('\n')
    }
  }
  out.write_string(trimmed)
  if not(trimmed.has_suffix("\n")) {
    out.write_char('\n')
  }
  out.to_string()
}

///|
fn eval_tests_dir_path(db_path : String) -> String {
  if db_path.has_suffix(".db") && db_path.length() > 3 {
    db_path.unsafe_substring(start=0, end=db_path.length() - 3) + ".tests"
  } else {
    db_path + ".tests"
  }
}

///|
fn is_test_target_safe_char(ch : Char) -> Bool {
  (ch >= 'a' && ch <= 'z') ||
  (ch >= 'A' && ch <= 'Z') ||
  (ch >= '0' && ch <= '9') ||
  ch == '_' ||
  ch == '-'
}

///|
fn sanitize_eval_test_target(target : String) -> String {
  let out = StringBuilder::new()
  for _, ch in target {
    if is_test_target_safe_char(ch) {
      out.write_char(ch)
    } else {
      out.write_char('_')
    }
  }
  let value = out.to_string()
  if value.length() == 0 {
    "unnamed"
  } else {
    value
  }
}

///|
fn eval_test_file_path(db_path : String, target : String) -> String {
  eval_tests_dir_path(db_path) +
  "/" +
  sanitize_eval_test_target(target) +
  "_test.xsh"
}

///|
fn eval_test_cache_dir_path(db_path : String) -> String {
  eval_tests_dir_path(db_path) + "/.cache"
}

///|
fn eval_test_cache_file_path(db_path : String, target : String) -> String {
  eval_test_cache_dir_path(db_path) +
  "/" +
  sanitize_eval_test_target(target) +
  ".ok"
}

///|
fn load_eval_test_cache_hash(db_path : String, target : String) -> String? {
  let cache_path = eval_test_cache_file_path(db_path, target)
  if not(@os_fs.path_exists(cache_path)) {
    return None
  }
  let is_file = @os_fs.is_file(cache_path) catch { _ => false }
  if not(is_file) {
    return None
  }
  let source = @os_fs.read_file_to_string(cache_path) catch { _ => return None }
  let hash = source.trim().to_string()
  if hash.length() == 0 {
    None
  } else {
    Some(hash)
  }
}

///|
fn write_eval_test_cache_hash(
  db_path : String,
  target : String,
  closure_hash : String,
) -> Result[Unit, String] {
  write_eval_db_source(
    eval_test_cache_file_path(db_path, target),
    closure_hash + "\n",
  )
}

///|
fn clear_eval_test_cache_hash(db_path : String, target : String) -> Unit {
  let cache_path = eval_test_cache_file_path(db_path, target)
  if @os_fs.path_exists(cache_path) {
    ignore(@os_fs.remove_file(cache_path) catch { _ => () })
  }
}

///|
fn eval_test_dep_snapshot_hash(
  test_source : String,
  target : String,
  dep_snapshot : Map[String, String],
) -> String {
  let sorted = dep_snapshot.to_array()
  sorted.sort_by((a, b) => {
    let (a_name, _) = a
    let (b_name, _) = b
    String::compare(a_name, b_name)
  })
  let out = StringBuilder::new()
  out.write_string("target:")
  out.write_string(target)
  out.write_char('\n')
  for item in sorted {
    let (name, addr) = item
    out.write_string(name)
    out.write_char(':')
    out.write_string(addr)
    out.write_char('\n')
  }
  out.write_string("tests:")
  out.write_string(@xsh_core.git_blob_hash_string(test_source))
  out.write_char('\n')
  @xsh_core.git_blob_hash_string(out.to_string())
}

///|
fn eval_test_closure_hash_from_runtime(
  rt : @xsh_lib.Runtime,
  syntax_mode : @xsh_lib.ParserMode,
  test_source : String,
  target : String,
) -> Result[String?, String] {
  let target_addr = match rt.get_addr(target) {
    Some(addr) => addr
    None =>
      match rt.get_hash(target) {
        Some(addr) => addr
        None => return Ok(None)
      }
  }
  let dep_snapshot = rt.collect_script_test_dep_snapshot_with_mode(
    test_source, syntax_mode,
  ) catch {
    e => return Err("failed to analyze test deps: " + e.to_string())
  }
  let deps = match dep_snapshot {
    Some(snapshot) => snapshot.copy()
    None => {}
  }
  deps[target] = target_addr
  Ok(Some(eval_test_dep_snapshot_hash(test_source, target, deps)))
}

///|
fn eval_test_target_is_pure(rt : @xsh_lib.Runtime, target : String) -> Bool {
  match rt.type_env().get_purity(target) {
    Some(v) => v
    None => false
  }
}

///|
fn run_eval_sidecar_tests(
  db_source : String,
  test_source : String,
  include_sources : Array[String],
  syntax_mode : @xsh_lib.ParserMode,
  features : @xsh_lib.RuntimeFeatureFlags,
) -> Result[@xsh_lib.TestReport, String] {
  let rt = new_runtime_with_features(features)
  for include_source in include_sources {
    if include_source.trim().to_string().length() == 0 {
      continue
    }
    let _ = rt.eval_script_with_mode(include_source, syntax_mode) catch {
      e => return Err("failed to restore include for --run: " + e.to_string())
    }
  }
  if db_source.trim().to_string().length() > 0 {
    let _ = rt.eval_script_with_mode(db_source, syntax_mode) catch {
      e => return Err("failed to restore db for --run: " + e.to_string())
    }
  }
  let report = rt.run_script_tests_with_mode(test_source, syntax_mode) catch {
    e => return Err("failed to run sidecar tests: " + e.to_string())
  }
  Ok(report)
}

///|
fn write_eval_test_source(
  db_path : String,
  target : String,
  expr : String,
) -> Result[String, String] {
  let test_path = eval_test_file_path(db_path, target)
  let current = match load_eval_db_source(test_path) {
    Ok(source) => source
    Err(err) => return Err(err)
  }
  let next = append_eval_db_source(current, expr)
  match write_eval_db_source(test_path, next) {
    Ok(_) => Ok(test_path)
    Err(err) => Err(err)
  }
}

///|
fn write_eval_db_source(path : String, source : String) -> Result[Unit, String] {
  let parent = @xsh_fs.parent_path(path)
  if parent != "." && parent.length() > 0 && not(@os_fs.path_exists(parent)) {
    @os_fs.create_dir(parent) catch {
      e =>
        return Err("failed to create db dir `" + parent + "`: " + e.to_string())
    }
  }
  @os_fs.write_string_to_file(path, source) catch {
    e => return Err("failed to write db `" + path + "`: " + e.to_string())
  }
  Ok(())
}

///|
fn write_eval_export(path : String, source : String) -> Result[Unit, String] {
  let parent = @xsh_fs.parent_path(path)
  if parent != "." && parent.length() > 0 && not(@os_fs.path_exists(parent)) {
    @os_fs.create_dir(parent) catch {
      e =>
        return Err(
          "failed to create export dir `" + parent + "`: " + e.to_string(),
        )
    }
  }
  @os_fs.write_string_to_file(path, source) catch {
    e => return Err("failed to write export `" + path + "`: " + e.to_string())
  }
  Ok(())
}

///|
fn eval_cmd(
  args : Array[String],
  syntax_mode : @xsh_lib.ParserMode,
  features : @xsh_lib.RuntimeFeatureFlags,
) -> Unit {
  let options = match parse_eval_cmd_options(args, "eval") {
    Ok(opts) => opts
    Err(msg) => abort(msg)
  }
  let rt = new_runtime_with_features(features)
  let (namespace_name, db_path) = match options.db_path {
    Some(path) => ("explicit", @loader.resolve_entry_path(path))
    None =>
      match resolve_scratch_db_path() {
        Ok(v) => v
        Err(err) => abort("eval: " + err)
      }
  }
  let mut next_source = ""
  let include_base_dir = eval_include_base_dir(options)
  let include_lib_dir = resolve_xsh_lib_dir(@io.current_dir_or_root())
  let include_sources : Array[String] = []
  let mut eval_test_sidecar_path : String? = None
  for include_spec in options.include_paths {
    let include_source = match
      load_eval_include_source(include_spec, include_base_dir, include_lib_dir) {
      Ok(source) => source
      Err(err) => abort("eval: " + err)
    }
    include_sources.push(include_source)
    if include_source.trim().length() > 0 {
      let _ = rt.eval_script_with_mode(include_source, syntax_mode) catch {
        e =>
          abort(
            "eval: failed to load include `" +
            include_spec +
            "`: " +
            e.to_string(),
          )
      }
    }
  }
  let source = match load_eval_db_source(db_path) {
    Ok(content) => content
    Err(err) => abort("eval: " + err)
  }
  next_source = source
  if source.trim().length() > 0 {
    let _ = rt.eval_script_with_mode(source, syntax_mode) catch {
      e =>
        abort("eval: failed to restore db `" + db_path + "`: " + e.to_string())
    }
  }
  match options.expr {
    Some(expr) => {
      let result = rt.eval_script_with_mode(expr, syntax_mode) catch {
        e => abort("eval: " + e.to_string())
      }
      print_eval_result(result)
      match extract_let_name(expr) {
        Some(name) =>
          match rt.get_addr(name) {
            Some(addr) => println("addr: " + name + "#" + short_hash(addr))
            None => ()
          }
        None => ()
      }
      match options.test_target {
        Some(target) =>
          match write_eval_test_source(db_path, target, expr) {
            Ok(path) => {
              eval_test_sidecar_path = Some(path)
              println(
                "test stored: target=" +
                target +
                " path=" +
                path +
                " db=" +
                db_path,
              )
            }
            Err(err) => abort("eval: " + err)
          }
        None => {
          next_source = append_eval_db_source(next_source, expr)
          match write_eval_db_source(db_path, next_source) {
            Ok(_) => ()
            Err(err) => abort("eval: " + err)
          }
        }
      }
    }
    None => ()
  }
  if options.test_run {
    let target = match options.test_target {
      Some(v) => v
      None => abort("eval: --run requires --test-for")
    }
    let test_path = match eval_test_sidecar_path {
      Some(path) => path
      None => eval_test_file_path(db_path, target)
    }
    let test_source = match load_eval_db_source(test_path) {
      Ok(v) => v
      Err(err) => abort("eval: " + err)
    }
    if test_source.trim().to_string().length() == 0 {
      abort("eval: no tests found for --test-for `" + target + "`")
    }
    let pure_target = eval_test_target_is_pure(rt, target)
    if not(pure_target) {
      clear_eval_test_cache_hash(db_path, target)
    }
    let closure_hash = if pure_target {
      match
        eval_test_closure_hash_from_runtime(
          rt, syntax_mode, test_source, target,
        ) {
        Ok(value) => value
        Err(err) => abort("eval: " + err)
      }
    } else {
      None
    }
    let mut should_run = true
    match closure_hash {
      Some(hash) =>
        match load_eval_test_cache_hash(db_path, target) {
          Some(cached_hash) =>
            if cached_hash == hash {
              println(
                test_path +
                ": cache hit (pure, closure=" +
                short_hash(hash) +
                ")",
              )
              should_run = false
            }
          None => ()
        }
      None => ()
    }
    if should_run {
      let report = match
        run_eval_sidecar_tests(
          next_source, test_source, include_sources, syntax_mode, features,
        ) {
        Ok(v) => v
        Err(err) => abort("eval: " + err)
      }
      if not(print_test_report(test_path, report)) {
        clear_eval_test_cache_hash(db_path, target)
        abort("eval: test-for failed: " + target)
      }
      match closure_hash {
        Some(hash) =>
          match write_eval_test_cache_hash(db_path, target, hash) {
            Ok(_) => ()
            Err(err) => abort("eval: " + err)
          }
        None => clear_eval_test_cache_hash(db_path, target)
      }
    }
  }
  let scope_symbols = collect_eval_scope_symbols(db_path, next_source)
  match validate_eval_type_assertions(options.assertions, scope_symbols) {
    Ok(_) => ()
    Err(err) => abort("eval: " + err)
  }
  if options.inspect_scope {
    println(eval_scope_symbols_json(scope_symbols).stringify())
  }
  match options.export_path {
    Some(path) => {
      if next_source.trim().length() == 0 {
        abort("eval: no source to export")
      }
      match write_eval_export(path, next_source) {
        Ok(_) => ()
        Err(err) => abort("eval: " + err)
      }
      println("exported: " + path)
    }
    None => ()
  }
  if namespace_name != "explicit" {
    println("namespace: " + namespace_name + " db=" + db_path)
  }
}

///|
fn print_test_report(path : String, report : @xsh_lib.TestReport) -> Bool {
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
fn print_bench_report(path : String, report : @xsh_lib.BenchReport) -> Bool {
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
fn compile_entry(
  entry_path : String,
) -> Result[@xsh_lib.CompiledModule, String] {
  match @loader.load_db(entry_path) {
    Err(err) => Err(err)
    Ok((db, entry)) => {
      let compiled = @xsh_lib.compile_module(db, entry) catch {
        e => return Err(e.to_string())
      }
      Ok(compiled)
    }
  }
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
  let bundle = @xsh_core.normalize_with_imports(prelude_ast, fn(_import_path) {
    None
  })
  let prelude_hash = bundle.main_hash
  let prelude_module = match bundle.modules.get(prelude_hash) {
    Some(m) => m
    None => @xsh_core.normalize_module(prelude_ast)
  }
  let prelude_json = @xsh_core.serialize_module(prelude_module)
  (prelude_hash, prelude_json)
}

///|
fn sync_prelude_to_codebase(
  entry : String,
  lock : @codebase.LockData,
) -> @codebase.LockData {
  let (prelude_hash, prelude_json) = normalized_prelude_object()
  let xsh_dir = find_xsh_dir(entry)
  let codebase = @codebase.Codebase::new(xsh_dir)
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
    "updated index.lock: " +
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
        " index_xdb=" +
        index_root +
        "/index.xdb",
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
  let scratch_names : Map[String, Bool] = {}
  for candidate in scratch_candidates {
    scratch_names[candidate.def.name] = true
  }
  let index_names : Map[String, Bool] = {}
  for _, def in index.defs {
    index_names[def.name] = true
  }
  let rows : Array[SymbolsRow] = []
  for _, def in index.defs {
    let key = def.path + "#" + def.name
    let managed = lock.module_refs.contains(key)
    let status = if scratch_names.contains(def.name) {
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
        let index_xdb_path = index_root + "/index.xdb"
        let xdb = load_index_xdb_object(index_xdb_path)
        let next_xdb = clone_json_map(xdb)
        let namespaces = match xdb.get("namespaces") {
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
        next_xdb["active_namespace"] = Json::string(namespace_name)
        next_xdb["namespaces"] = Json::object(namespaces)
        match write_index_xdb_object(index_xdb_path, next_xdb) {
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
enum WriteFileSelector {
  Name(String)
  NameHash(String, String)
  Hash(String)
} derive(Show, Eq)

///|
struct WriteFileCmdOptions {
  entry_path : String?
  selector_text : String
  out_path : String
  no_deps : Bool
  dry_run : Bool
  output_json : Bool
} derive(Show, Eq)

///|
struct WriteFileDef {
  def_id : String
  name : String
  kind : String
  signature : String
  path : String
  start : Int
  end : Int
  module_hash : String
} derive(Show, Eq)

///|
struct WriteFileCandidate {
  def : WriteFileDef
  origin : String
} derive(Show, Eq)

///|
fn first_char_index(text : String, target : Char) -> Int? {
  for i, c in text {
    if c == target {
      return Some(i)
    }
  }
  None
}

///|
fn parse_write_file_selector(raw : String) -> Result[WriteFileSelector, String] {
  let trimmed = raw.trim().to_string()
  if trimmed.length() == 0 {
    return Err("write_file: selector must not be empty")
  }
  if trimmed.has_prefix("#") {
    let hash = trimmed
      .unsafe_substring(start=1, end=trimmed.length())
      .trim()
      .to_string()
    if hash.length() == 0 {
      return Err("write_file: selector hash must not be empty")
    }
    return Ok(WriteFileSelector::Hash(hash))
  }
  match first_char_index(trimmed, '#') {
    Some(idx) => {
      let name = trimmed.unsafe_substring(start=0, end=idx).trim().to_string()
      let hash = trimmed
        .unsafe_substring(start=idx + 1, end=trimmed.length())
        .trim()
        .to_string()
      if name.length() == 0 {
        return Err("write_file: selector name must not be empty")
      }
      if hash.length() == 0 {
        return Err("write_file: selector hash must not be empty")
      }
      Ok(WriteFileSelector::NameHash(name, hash))
    }
    None => Ok(WriteFileSelector::Name(trimmed))
  }
}

///|
fn parse_write_file_cmd_args(
  args : Array[String],
) -> Result[WriteFileCmdOptions, String] {
  let mut entry_path : String? = None
  let mut no_deps = false
  let mut dry_run = false
  let mut output_json = false
  let positional : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if arg == "--entry" {
      i += 1
      if i >= args.length() {
        return Err("write_file: missing path after --entry")
      }
      entry_path = Some(args[i])
      i += 1
      continue
    }
    if arg.has_prefix("--entry=") {
      let path = arg.unsafe_substring(start=8, end=arg.length())
      if path.trim().to_string().length() == 0 {
        return Err("write_file: --entry path must not be empty")
      }
      entry_path = Some(path)
      i += 1
      continue
    }
    if arg == "--no-deps" {
      no_deps = true
      i += 1
      continue
    }
    if arg == "--dry-run" {
      dry_run = true
      i += 1
      continue
    }
    if arg == "--json" {
      output_json = true
      i += 1
      continue
    }
    if arg.has_prefix("--") {
      return Err("write_file: unknown option: " + arg)
    }
    positional.push(arg)
    i += 1
  }
  if positional.length() != 2 {
    return Err(
      "write_file: expected [--entry file] [--no-deps] [--dry-run] [--json] <selector> <out-file>",
    )
  }
  Ok({
    entry_path,
    selector_text: positional[0],
    out_path: positional[1],
    no_deps,
    dry_run,
    output_json,
  })
}

///|
fn write_file_def_id_from_symbol_entry(entry : @xsh_lib.SymbolEntry) -> String {
  let key = entry.path +
    "|" +
    entry.span.start.to_string() +
    "|" +
    entry.span.end.to_string() +
    "|" +
    entry.name +
    "|" +
    @xsh_lib.symbol_kind_name(entry.kind) +
    "|" +
    entry.signature
  @xsh_core.git_blob_hash_string(key)
}

///|
fn write_file_graph_def_from_symbol_entry(
  db : @xsh_lib.XshDb,
  entry : @xsh_lib.SymbolEntry,
) -> WriteFileDef {
  {
    def_id: write_file_def_id_from_symbol_entry(entry),
    name: entry.name,
    kind: @xsh_lib.symbol_kind_name(entry.kind),
    signature: entry.signature,
    path: entry.path,
    start: entry.span.start,
    end: entry.span.end,
    module_hash: @xsh_core.hash_module(db.ast(entry.path)),
  }
}

///|
fn write_file_def_from_index_def(def : @x_exp.AdvancedGraphDef) -> WriteFileDef {
  {
    def_id: def.def_id,
    name: def.name,
    kind: def.kind,
    signature: def.signature,
    path: def.path,
    start: def.start,
    end: def.end,
    module_hash: def.module_hash,
  }
}

///|
fn write_file_candidates_from_index(
  index : @x_exp.AdvancedGraphIndex,
) -> Array[WriteFileCandidate] {
  let out : Array[WriteFileCandidate] = []
  for _, def in index.defs {
    out.push({ def: write_file_def_from_index_def(def), origin: "index" })
  }
  out
}

///|
fn write_file_candidate_label(candidate : WriteFileCandidate) -> String {
  candidate.origin +
  ":" +
  candidate.def.name +
  "\t" +
  candidate.def.path +
  "#" +
  short_hash(candidate.def.def_id)
}

///|
fn write_file_result_json(
  candidate : WriteFileCandidate,
  out_path : String,
  no_deps : Bool,
  dry_run : Bool,
) -> Json {
  let obj : Map[String, Json] = {}
  obj["status"] = Json::string("ok")
  obj["dry_run"] = Json::boolean(dry_run)
  obj["origin"] = Json::string(candidate.origin)
  obj["kind"] = Json::string(candidate.def.kind)
  obj["name"] = Json::string(candidate.def.name)
  obj["path"] = Json::string(candidate.def.path)
  obj["hash"] = Json::string(candidate.def.def_id)
  obj["short_hash"] = Json::string(short_hash(candidate.def.def_id))
  obj["signature"] = Json::string(candidate.def.signature)
  obj["module_hash"] = Json::string(candidate.def.module_hash)
  obj["out_path"] = Json::string(out_path)
  obj["no_deps"] = Json::boolean(no_deps)
  Json::object(obj)
}

///|
fn write_file_ambiguous_error(
  prefix : String,
  matches : Array[WriteFileCandidate],
) -> String {
  let buf = StringBuilder::new()
  buf.write_string(prefix)
  buf.write_string("\nUse `name#hash` or `#hash` selector.")
  for candidate in matches {
    buf.write_string("\n  - " + write_file_candidate_label(candidate))
  }
  buf.to_string()
}

///|
fn write_file_filter_name(
  candidates : Array[WriteFileCandidate],
  name : String,
) -> Array[WriteFileCandidate] {
  let out : Array[WriteFileCandidate] = []
  for candidate in candidates {
    if candidate.def.name == name {
      out.push(candidate)
    }
  }
  out
}

///|
fn write_file_filter_hash(
  candidates : Array[WriteFileCandidate],
  hash_prefix : String,
  name? : String = "",
) -> Array[WriteFileCandidate] {
  let out : Array[WriteFileCandidate] = []
  for candidate in candidates {
    if not(candidate.def.def_id.has_prefix(hash_prefix)) {
      continue
    }
    if name.length() > 0 && candidate.def.name != name {
      continue
    }
    out.push(candidate)
  }
  out
}

///|
fn write_file_resolve_single(
  matches : Array[WriteFileCandidate],
  not_found_message : String,
  ambiguous_message : String,
) -> Result[WriteFileCandidate, String] {
  if matches.length() == 0 {
    return Err(not_found_message)
  }
  if matches.length() > 1 {
    return Err(write_file_ambiguous_error(ambiguous_message, matches))
  }
  Ok(matches[0])
}

///|
fn write_file_resolve_candidate(
  selector : WriteFileSelector,
  scratch_candidates : Array[WriteFileCandidate],
  index_candidates : Array[WriteFileCandidate],
) -> Result[WriteFileCandidate, String] {
  match selector {
    WriteFileSelector::Name(name) => {
      let scratch_matches = write_file_filter_name(scratch_candidates, name)
      if scratch_matches.length() > 1 {
        return Err(
          write_file_ambiguous_error(
            "write_file: scratch selector is ambiguous for `" + name + "`",
            scratch_matches,
          ),
        )
      }
      if scratch_matches.length() == 1 {
        return Ok(scratch_matches[0])
      }
      let index_matches = write_file_filter_name(index_candidates, name)
      write_file_resolve_single(
        index_matches,
        "write_file: selector not found: `" + name + "`",
        "write_file: selector is ambiguous for `" + name + "`",
      )
    }
    WriteFileSelector::NameHash(name, hash_prefix) => {
      let combined : Array[WriteFileCandidate] = []
      for candidate in scratch_candidates {
        combined.push(candidate)
      }
      for candidate in index_candidates {
        combined.push(candidate)
      }
      let matches = write_file_filter_hash(combined, hash_prefix, name~)
      write_file_resolve_single(
        matches,
        "write_file: selector not found: `" + name + "#" + hash_prefix + "`",
        "write_file: selector is ambiguous for `" +
        name +
        "#" +
        hash_prefix +
        "`",
      )
    }
    WriteFileSelector::Hash(hash_prefix) => {
      let combined : Array[WriteFileCandidate] = []
      for candidate in scratch_candidates {
        combined.push(candidate)
      }
      for candidate in index_candidates {
        combined.push(candidate)
      }
      let matches = write_file_filter_hash(combined, hash_prefix)
      write_file_resolve_single(
        matches,
        "write_file: selector not found: `#" + hash_prefix + "`",
        "write_file: selector is ambiguous for `#" + hash_prefix + "`",
      )
    }
  }
}

///|
fn graph_head_from_index_xdb(xdb : Map[String, Json]) -> String? {
  match xdb.get("graph_head") {
    Some(Json::String(hash)) => {
      let normalized = hash.trim().to_string()
      if normalized.length() == 0 {
        None
      } else {
        Some(normalized)
      }
    }
    _ => None
  }
}

///|
fn load_graph_index_from_index_root(
  index_root : String,
) -> Result[@x_exp.AdvancedGraphIndex?, String] {
  let index_xdb_path = index_root + "/index.xdb"
  let xdb = load_index_xdb_object(index_xdb_path)
  let graph_head = match graph_head_from_index_xdb(xdb) {
    Some(hash) => hash
    None => return Ok(None)
  }
  let xsh_dir = find_xsh_dir(index_root + "/index.xsh")
  let codebase = @codebase.Codebase::new(xsh_dir)
  let graph_source = match codebase.read_object(graph_head) {
    Some(source) => source
    None =>
      return Err(
        "write_file: graph head object not found: " +
        graph_head +
        " in " +
        xsh_dir,
      )
  }
  let graph_json : Json = @json.parse(graph_source) catch {
    e => return Err("write_file: graph head parse failed: " + e.to_string())
  }
  match @x_exp.advanced_graph_index_from_json(graph_json) {
    Ok(index) => Ok(Some(index))
    Err(err) => Err("write_file: graph head decode failed: " + err)
  }
}

///|
fn load_scratch_write_file_candidates(
  index_root : String,
) -> Result[Array[WriteFileCandidate], String] {
  let (_, scratch_db_path) = match
    resolve_scratch_db_path_for_index_root(index_root) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  if not(@os_fs.path_exists(scratch_db_path)) {
    return Ok([])
  }
  let source = match load_eval_db_source(scratch_db_path) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  if source.trim().to_string().length() == 0 {
    return Ok([])
  }
  let _ = @parser.parse_ast(source) catch {
    e => return Err("write_file: scratch db parse failed: " + e.to_string())
  }
  let db = @xsh_lib.XshDb::new()
  db.set_source(scratch_db_path, source)
  let symbol_index = @xsh_lib.build_symbol_index(db, [scratch_db_path])
  let out : Array[WriteFileCandidate] = []
  for entry in symbol_index.entries {
    let def = write_file_graph_def_from_symbol_entry(db, entry)
    out.push({ def, origin: "scratch" })
  }
  Ok(out)
}

///|
fn read_write_file_source(path : String) -> Result[String, String] {
  let resolved = @loader.resolve_entry_path(path)
  if not(@os_fs.path_exists(resolved)) {
    return Err("write_file: source path not found: " + resolved)
  }
  let is_file = @os_fs.is_file(resolved) catch { _ => false }
  if not(is_file) {
    return Err("write_file: source path is not a file: " + resolved)
  }
  let source = @os_fs.read_file_to_string(resolved) catch {
    e =>
      return Err(
        "write_file: failed to read `" + resolved + "`: " + e.to_string(),
      )
  }
  Ok(source)
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
fn write_file_source_exports_name(source : String, name : String) -> Bool {
  let ast = @parser.parse_ast(source) catch {
    _ =>
      return source.contains("export { " + name + " }") ||
        source.contains("export {" + name + "}")
  }
  for stmt in ast.stmts {
    match stmt {
      @xsh_core.Stmt::ExportLet(name=export_name, ..) =>
        if export_name == name {
          return true
        }
      @xsh_core.Stmt::ExportEnumDef(name=export_name, ..) =>
        if export_name == name {
          return true
        }
      @xsh_core.Stmt::ExportTypeAlias(name=export_name, ..) =>
        if export_name == name {
          return true
        }
      @xsh_core.Stmt::ExportStructDef(name=export_name, ..) =>
        if export_name == name {
          return true
        }
      @xsh_core.Stmt::TraitDef(name=trait_name, exported~, ..) =>
        if exported && trait_name == name {
          return true
        }
      @xsh_core.Stmt::Export(names~, ..) =>
        for export_name in names {
          if export_name == name {
            return true
          }
        }
      @xsh_core.Stmt::ReExport(names~, ..) =>
        for export_name in names {
          if export_name == name {
            return true
          }
        }
      _ => ()
    }
  }
  false
}

///|
fn ensure_write_file_export(source : String, name : String) -> String {
  if write_file_source_exports_name(source, name) {
    return source
  }
  let buf = StringBuilder::new()
  buf.write_string(source)
  if source.length() > 0 && not(source.has_suffix("\n")) {
    buf.write_char('\n')
  }
  buf.write_string("export { " + name + " }\n")
  buf.to_string()
}

///|
fn materialize_write_file_source(
  source : String,
  def : WriteFileDef,
  no_deps : Bool,
) -> Result[String, String] {
  if not(no_deps) {
    return Ok(source)
  }
  let snippet = source_slice_by_span(source, def.start, def.end)
  if snippet.trim().to_string().length() == 0 {
    return Err(
      "write_file: empty selector span for " + def.path + "#" + def.name,
    )
  }
  if snippet.has_suffix("\n") {
    Ok(snippet)
  } else {
    Ok(snippet + "\n")
  }
}

///|
fn write_file_cmd(args : Array[String]) -> Unit {
  let options = match parse_write_file_cmd_args(args) {
    Ok(v) => v
    Err(err) => abort(err)
  }
  let selector = match parse_write_file_selector(options.selector_text) {
    Ok(v) => v
    Err(err) => abort(err)
  }
  let (index_root, index_candidates) = match options.entry_path {
    Some(entry_path) => {
      let resolved_entry = @loader.resolve_entry_path(entry_path)
      let index = match resolve_entry_artifacts(resolved_entry) {
        Ok((_, _, _, index, _)) => index
        Err(err) => abort("write_file: " + err)
      }
      (
        @codebase.resolve_index_root(resolved_entry),
        write_file_candidates_from_index(index),
      )
    }
    None => {
      let root = current_workspace_index_root()
      let candidates = match load_graph_index_from_index_root(root) {
        Ok(Some(index)) => write_file_candidates_from_index(index)
        Ok(None) => []
        Err(err) => abort(err)
      }
      (root, candidates)
    }
  }
  let scratch_candidates = match
    load_scratch_write_file_candidates(index_root) {
    Ok(v) => v
    Err(err) => abort("write_file: " + err)
  }
  let selected = match
    write_file_resolve_candidate(selector, scratch_candidates, index_candidates) {
    Ok(v) => v
    Err(err) => abort(err)
  }
  let source = match read_write_file_source(selected.def.path) {
    Ok(v) => v
    Err(err) => abort(err)
  }
  let materialized = match
    materialize_write_file_source(source, selected.def, options.no_deps) {
    Ok(v) => v
    Err(err) => abort(err)
  }
  let out_source = ensure_write_file_export(materialized, selected.def.name)
  if options.dry_run {
    if options.output_json {
      println(
        write_file_result_json(
          selected,
          options.out_path,
          options.no_deps,
          true,
        ).stringify(),
      )
    } else {
      println(
        "write_file(dry-run): " +
        write_file_candidate_label(selected) +
        " -> " +
        options.out_path +
        " no_deps=" +
        options.no_deps.to_string(),
      )
    }
    return
  }
  match write_eval_export(options.out_path, out_source) {
    Ok(_) => ()
    Err(err) => abort("write_file: " + err)
  }
  if options.output_json {
    println(
      write_file_result_json(selected, options.out_path, options.no_deps, false).stringify(),
    )
  } else {
    println(
      "write_file: " +
      write_file_candidate_label(selected) +
      " -> " +
      options.out_path +
      " no_deps=" +
      options.no_deps.to_string(),
    )
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
  let hash = @xsh_core.hash_module(ast)
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
  let base_dir = @xsh_fs.parent_path(path)
  let source = @os_fs.read_file_to_string(path) catch {
    e => abort("save: " + e.to_string())
  }
  let ast = @parser.parse_ast(source) catch {
    e => abort("save: " + e.diagnostic().render(file_arg, source))
  }
  // Build import resolver
  let resolve_import = fn(import_path : String) -> @xsh_core.Module? {
    let resolved = if import_path.has_prefix("/") {
      import_path
    } else {
      @xsh_fs.normalize_path(base_dir + "/" + import_path)
    }
    let import_source = @os_fs.read_file_to_string(resolved) catch {
      _ => return None
    }
    let parsed = @parser.parse_ast(import_source) catch { _ => return None }
    Some(parsed)
  }
  // Normalize with all imports resolved to hashes
  let bundle = @xsh_core.normalize_with_imports(ast, resolve_import)
  // Save all modules in the bundle
  let mut saved_count = 0
  for hash, normalized in bundle.modules {
    let json = @xsh_core.serialize_module(normalized)
    if use_git {
      save_module_to_git(json, hash)
    } else {
      save_module_to_xsh(path, json, hash)
    }
    saved_count += 1
  }
  // Update paths.json for the main module
  if not(use_git) {
    let base_dir = find_xsh_dir(path)
    let codebase = @codebase.Codebase::new(base_dir)
    let _ = codebase.upsert_path_mapping(file_arg, bundle.main_hash) catch {
      e => abort("save: update paths: " + e.to_string())
    }
  }
  // Print result
  let main_short = @xsh_core.short_hash(bundle.main_hash)
  println("saved: \{file_arg} -> \{main_short} (\{saved_count} module(s))")
}

///|
fn save_module_to_xsh(base_path : String, json : String, hash : String) -> Unit {
  let base_dir = find_xsh_dir(base_path)
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
fn find_xsh_dir(path : String) -> String {
  // Look for .xsh directory, or create one in current directory
  let base = @xsh_fs.parent_path(path)
  let xsh_dir = base + "/.xsh"
  if @os_fs.path_exists(xsh_dir) {
    return xsh_dir
  }
  // Create .xsh directory
  @os_fs.create_dir(xsh_dir) catch {
    _ => {
      // Try current directory
      let cwd_xsh = ".xsh"
      if not(@os_fs.path_exists(cwd_xsh)) {
        @os_fs.create_dir(cwd_xsh) catch {
          e => abort("save: mkdir .xsh: " + e.to_string())
        }
      }
      return cwd_xsh
    }
  }
  xsh_dir
}

///|
/// expand <hash|path> [--depth N] [--json] [--source]
/// Expand a module from storage with its dependencies
fn expand_cmd(args : Array[String]) -> Unit {
  if args.length() == 0 {
    println("usage: xsh expand <hash|path> [--depth N] [--json] [--source]")
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
  // Find .xsh directory from target path
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
  let xsh_dir = find_xsh_dir_from(base_dir)
  let codebase = @codebase.Codebase::new(xsh_dir)
  // Resolve target to hash
  let main_hash = resolve_target_to_hash(target, codebase)
  let load_module = fn(hash : String) -> @xsh_core.Module? {
    let json = match codebase.read_object(hash) {
      Some(v) => v
      None => return None
    }
    let m = @xsh_core.deserialize_module(json) catch { _ => return None }
    Some(m)
  }
  // Expand the module
  let bundle = @xsh_core.expand_module(main_hash, load_module, depth)
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
      println("    \"" + hash + "\": " + @xsh_core.serialize_module(m) + comma)
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
          let short = @xsh_core.short_hash(hash)
          println("// --- Module: " + short + " ---")
          // Use JSON format for now since format_ast is not available
          let json = @xsh_core.serialize_module(m)
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
fn resolve_hash_prefix(prefix : String, xsh_dir : String) -> String {
  if prefix.length() == 40 {
    return prefix
  }
  // Search for matching hash in objects directory
  let objects_dir = xsh_dir + "/objects"
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
fn find_xsh_dir_from(start : String) -> String {
  // Search for .xsh directory starting from given directory
  let mut dir = if start == "" { "." } else { start }
  for _ in 0..<10 {
    let xsh_path = dir + "/.xsh"
    if @os_fs.path_exists(xsh_path) {
      return xsh_path
    }
    dir = dir + "/.."
  }
  abort("expand: .xsh directory not found (searched from: " + start + ")")
}

///|
fn zero_pad_number(value : Int, width : Int) -> String {
  let raw = value.to_string()
  if raw.length() >= width {
    return raw
  }
  let buf = StringBuilder::new()
  for _ in 0..<(width - raw.length()) {
    buf.write_char('0')
  }
  buf.write_string(raw)
  buf.to_string()
}

///|
fn symbol_line_col(source : String, span : @xsh_core.Span) -> (Int, Int) {
  let (pos, _, _) = @xsh_core.line_info(source, span.start)
  (pos.line, pos.column)
}

///|
fn symbol_line_text(source : String, span : @xsh_core.Span) -> String {
  let (_, line_start, line_end) = @xsh_core.line_info(source, span.start)
  try source[line_start:line_end] catch {
    _ => ""
  } noraise {
    s => s.to_string()
  }
}

///|
fn print_ide_outline_entry(
  entry : @xsh_lib.SymbolEntry,
  source : String,
) -> Unit {
  let (line, _) = symbol_line_col(source, entry.span)
  println(
    "L" +
    zero_pad_number(line, 3) +
    " | " +
    @xsh_lib.symbol_kind_name(entry.kind) +
    " " +
    entry.name +
    " : " +
    entry.signature,
  )
}

///|
fn ide_outline_cmd(args : Array[String]) -> Unit {
  if args.length() != 1 {
    abort("ide outline: expected <file>")
  }
  match @loader.load_db_with_paths(args[0]) {
    Ok((db, entry, _)) => {
      let index = @xsh_lib.build_symbol_index(db, [entry])
      if index.entries.length() == 0 {
        println("No symbols found in " + entry)
        return
      }
      println("Outline: " + entry)
      for symbol in index.entries {
        match db.get_source(symbol.path) {
          Some(source) => print_ide_outline_entry(symbol, source)
          None => ()
        }
      }
    }
    Err(err) => abort("ide outline: " + err)
  }
}

///|
fn print_ide_search_entry(
  entry : @xsh_lib.SymbolEntry,
  source : String,
) -> Unit {
  let (line, column) = symbol_line_col(source, entry.span)
  println(
    entry.path +
    ":" +
    line.to_string() +
    ":" +
    column.to_string() +
    "  " +
    @xsh_lib.symbol_kind_name(entry.kind) +
    " " +
    entry.name +
    " : " +
    entry.signature,
  )
}

///|
fn ide_peek_def_cmd(args : Array[String]) -> Unit {
  if args.length() != 2 {
    abort("ide peek-def: expected <symbol> <entry-file>")
  }
  let symbol = args[0]
  let entry_file = args[1]
  match @loader.load_db_with_paths(entry_file) {
    Ok((db, _, paths)) => {
      let index = @xsh_lib.build_symbol_index(db, paths)
      let matches = index.find_exact(symbol)
      if matches.length() == 0 {
        println("No symbols found matching `" + symbol + "`")
        return
      }
      println(
        "Found " +
        matches.length().to_string() +
        " symbols matching `" +
        symbol +
        "`:",
      )
      for entry in matches {
        match db.get_source(entry.path) {
          Some(source) => {
            let (line, column) = symbol_line_col(source, entry.span)
            println("")
            println(
              @xsh_lib.symbol_kind_name(entry.kind) +
              " " +
              entry.name +
              " at " +
              entry.path +
              ":" +
              line.to_string() +
              ":" +
              column.to_string(),
            )
            let snippet = symbol_line_text(source, entry.span)
            if snippet.length() > 0 {
              println(snippet)
            }
          }
          None => ()
        }
      }
    }
    Err(err) => abort("ide peek-def: " + err)
  }
}

///|
fn ide_search_cmd(args : Array[String]) -> Unit {
  if args.length() != 2 {
    abort("ide search: expected <query> <entry-file>")
  }
  let query = args[0]
  let entry_file = args[1]
  match @loader.load_db_with_paths(entry_file) {
    Ok((db, _, paths)) => {
      let index = @xsh_lib.build_symbol_index(db, paths)
      let matches = index.search(query)
      if matches.length() == 0 {
        println("No symbols found for query `" + query + "`")
        return
      }
      println(
        "Found " +
        matches.length().to_string() +
        " symbols for query `" +
        query +
        "`:",
      )
      for entry in matches {
        match db.get_source(entry.path) {
          Some(source) => print_ide_search_entry(entry, source)
          None => ()
        }
      }
    }
    Err(err) => abort("ide search: " + err)
  }
}

///|
fn ide_cmd(args : Array[String]) -> Unit {
  if args.length() == 0 {
    abort("ide: expected subcommand (outline|peek-def|search)")
  }
  let sub = args[0]
  let sub_args = args_tail(args, 1)
  match sub {
    "outline" => ide_outline_cmd(sub_args)
    "peek-def" => ide_peek_def_cmd(sub_args)
    "search" => ide_search_cmd(sub_args)
    _ => abort("ide: unknown subcommand: " + sub)
  }
}

///|
fn lsif_lines_to_text(lines : Array[String]) -> String {
  let buf = StringBuilder::new()
  for i in 0..<lines.length() {
    if i > 0 {
      buf.write_char('\n')
    }
    buf.write_string(lines[i])
  }
  buf.to_string()
}

///|
fn lsif_cmd(args : Array[String]) -> Unit {
  let entries : Array[String] = []
  let mut out_path : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if arg == "-o" || arg == "--out" {
      i += 1
      if i >= args.length() {
        abort("lsif: missing output path after " + arg)
      }
      out_path = Some(args[i])
      i += 1
      continue
    }
    entries.push(arg)
    i += 1
  }
  if entries.length() != 1 {
    abort("lsif: expected <entry-file>")
  }
  match @loader.load_db_with_paths(entries[0]) {
    Ok((db, _, paths)) => {
      let index = @xsh_lib.build_symbol_index(db, paths)
      let lines = @xsh_lib.symbol_index_to_lsif_lines(index, fn(path) {
        db.get_source(path)
      })
      match out_path {
        Some(path) => {
          let text = lsif_lines_to_text(lines)
          @os_fs.write_string_to_file(path, text) catch {
            e => abort("lsif: " + e.to_string())
          }
          println(
            "wrote " + path + " (" + lines.length().to_string() + " lines)",
          )
        }
        None =>
          for line in lines {
            println(line)
          }
      }
    }
    Err(err) => abort("lsif: " + err)
  }
}

///|
fn index_load_file(path : String) -> @x_exp.AdvancedGraphIndex {
  match @x_exp.read_advanced_graph_index(path) {
    Ok(index) => index
    Err(err) => abort("index: " + err)
  }
}

///|
enum IndexWalAction {
  Stats(String)
  Append(String, String, String)
  Replay(String, String, String)
  Compact(String, String)
}

///|
enum IndexRefAction {
  PushIndex(String, String)
  PullIndex(String, String)
  PushDelta(String, String)
  PullDelta(String, String)
}

///|
fn parse_index_wal_args(args : Array[String]) -> Result[IndexWalAction, String] {
  if args.length() == 0 {
    return Err("index wal: expected subcommand (stats|append|replay|compact)")
  }
  let sub = args[0]
  let sub_args = args_tail(args, 1)
  match sub {
    "stats" =>
      if sub_args.length() != 1 {
        Err("index wal stats: expected <wal-file>")
      } else {
        Ok(IndexWalAction::Stats(sub_args[0]))
      }
    "append" =>
      if sub_args.length() != 3 {
        Err(
          "index wal append: expected <wal-file> <base-index-file> <target-index-file>",
        )
      } else {
        Ok(IndexWalAction::Append(sub_args[0], sub_args[1], sub_args[2]))
      }
    "replay" => {
      let mut out_path = "dist/advanced-graph-index.replayed.json"
      let mut snapshot_path : String? = None
      let mut wal_path : String? = None
      let mut i = 0
      while i < sub_args.length() {
        let arg = sub_args[i]
        match arg {
          "-o" | "--out" => {
            i += 1
            if i >= sub_args.length() {
              return Err("index wal replay: missing output path after " + arg)
            }
            out_path = sub_args[i]
          }
          _ =>
            match snapshot_path {
              None => snapshot_path = Some(arg)
              Some(_) =>
                match wal_path {
                  None => wal_path = Some(arg)
                  Some(_) =>
                    return Err("index wal replay: unexpected extra arg: " + arg)
                }
            }
        }
        i += 1
      }
      let snapshot_path = match snapshot_path {
        Some(v) => v
        None =>
          return Err("index wal replay: expected <snapshot-file> <wal-file>")
      }
      let wal_path = match wal_path {
        Some(v) => v
        None =>
          return Err("index wal replay: expected <snapshot-file> <wal-file>")
      }
      Ok(IndexWalAction::Replay(snapshot_path, wal_path, out_path))
    }
    "compact" =>
      if sub_args.length() != 2 {
        Err("index wal compact: expected <snapshot-file> <wal-file>")
      } else {
        Ok(IndexWalAction::Compact(sub_args[0], sub_args[1]))
      }
    _ => Err("index wal: unknown subcommand: " + sub)
  }
}

///|
fn index_wal_cmd(args : Array[String]) -> Unit {
  let action = match parse_index_wal_args(args) {
    Ok(v) => v
    Err(err) => abort(err)
  }
  match action {
    IndexWalAction::Stats(wal_path) => {
      let stats = match @x_exp.advanced_graph_wal_stats(wal_path) {
        Ok(v) => v
        Err(err) => abort("index wal stats: " + err)
      }
      println(
        "index wal stats: records=" +
        stats.record_count.to_string() +
        " bytes=" +
        stats.byte_size.to_string(),
      )
    }
    IndexWalAction::Append(wal_path, base_path, target_path) => {
      let base = index_load_file(base_path)
      let target = index_load_file(target_path)
      let delta = @x_exp.advanced_graph_diff(base, target)
      match @x_exp.append_advanced_graph_delta_jsonl(wal_path, delta) {
        Ok(_) =>
          println(
            "index wal append: wrote 1 record to " +
            wal_path +
            " (upsert_defs=" +
            delta.upsert_defs.length().to_string() +
            ", removed_defs=" +
            delta.removed_def_ids.length().to_string() +
            ")",
          )
        Err(err) => abort("index wal append: " + err)
      }
    }
    IndexWalAction::Replay(snapshot_path, wal_path, out_path) => {
      if out_path.has_prefix("dist/") {
        ensure_dist_dir()
      }
      let index = match
        @x_exp.load_advanced_graph_index_with_wal(snapshot_path, wal_path) {
        Ok(v) => v
        Err(err) => abort("index wal replay: " + err)
      }
      match @x_exp.write_advanced_graph_index(out_path, index) {
        Ok(_) =>
          println(
            "index wal replay: wrote " +
            out_path +
            " (" +
            index.defs.length().to_string() +
            " defs)",
          )
        Err(err) => abort("index wal replay: " + err)
      }
    }
    IndexWalAction::Compact(snapshot_path, wal_path) => {
      let latest = match
        @x_exp.compact_advanced_graph_snapshot_wal(snapshot_path, wal_path) {
        Ok(v) => v
        Err(err) => abort("index wal compact: " + err)
      }
      println(
        "index wal compact: wrote " +
        snapshot_path +
        " (" +
        latest.defs.length().to_string() +
        " defs), cleared " +
        wal_path,
      )
    }
  }
}

///|
fn parse_index_ref_args(args : Array[String]) -> Result[IndexRefAction, String] {
  if args.length() != 3 {
    return Err(
      "index ref: expected <push|pull|push-delta|pull-delta> <scope> <file>",
    )
  }
  let action = args[0]
  let scope = args[1]
  let path = args[2]
  match action {
    "push" => Ok(IndexRefAction::PushIndex(scope, path))
    "pull" => Ok(IndexRefAction::PullIndex(scope, path))
    "push-delta" => Ok(IndexRefAction::PushDelta(scope, path))
    "pull-delta" => Ok(IndexRefAction::PullDelta(scope, path))
    _ =>
      Err(
        "index ref: unknown action: " +
        action +
        " (expected push|pull|push-delta|pull-delta)",
      )
  }
}

///|
fn read_advanced_graph_delta_file(path : String) -> @x_exp.AdvancedGraphDelta {
  let content = @os_fs.read_file_to_string(path) catch {
    e => abort("index ref: read delta file: " + e.to_string())
  }
  let json = @json.parse(content) catch {
    e => abort("index ref: parse delta json: " + e.to_string())
  }
  match @x_exp.advanced_graph_delta_from_json(json) {
    Ok(v) => v
    Err(err) => abort("index ref: decode delta: " + err)
  }
}

///|
fn write_advanced_graph_delta_file(
  path : String,
  delta : @x_exp.AdvancedGraphDelta,
) -> Unit {
  @os_fs.write_string_to_file(path, delta.to_json().stringify()) catch {
    e => abort("index ref: write delta file: " + e.to_string())
  }
}

///|
fn index_ref_cmd(args : Array[String]) -> Unit {
  let action = match parse_index_ref_args(args) {
    Ok(v) => v
    Err(err) => abort(err)
  }
  let git_dir = find_git_dir()
  match action {
    IndexRefAction::PushIndex(scope, index_path) => {
      let index = index_load_file(index_path)
      let hash = match
        @x_exp.write_advanced_graph_index_to_git_ref(git_dir, scope, index) {
        Ok(v) => v
        Err(err) => abort("index ref push: " + err)
      }
      println(
        "index ref push: refs/bit/index/" +
        scope +
        "/graph/head -> " +
        short_hash(hash),
      )
    }
    IndexRefAction::PullIndex(scope, out_path) => {
      let index = match
        @x_exp.read_advanced_graph_index_from_git_ref(git_dir, scope) {
        Ok(v) => v
        Err(err) => abort("index ref pull: " + err)
      }
      if out_path.has_prefix("dist/") {
        ensure_dist_dir()
      }
      match @x_exp.write_advanced_graph_index(out_path, index) {
        Ok(_) =>
          println(
            "index ref pull: wrote " +
            out_path +
            " (" +
            index.defs.length().to_string() +
            " defs)",
          )
        Err(err) => abort("index ref pull: " + err)
      }
    }
    IndexRefAction::PushDelta(scope, delta_path) => {
      let delta = read_advanced_graph_delta_file(delta_path)
      let hash = match
        @x_exp.write_advanced_graph_delta_to_git_ref(git_dir, scope, delta) {
        Ok(v) => v
        Err(err) => abort("index ref push-delta: " + err)
      }
      println(
        "index ref push-delta: refs/bit/index/" +
        scope +
        "/graph/wal_head -> " +
        short_hash(hash),
      )
    }
    IndexRefAction::PullDelta(scope, out_path) => {
      let delta = match
        @x_exp.read_advanced_graph_delta_from_git_ref(git_dir, scope) {
        Ok(v) => v
        Err(err) => abort("index ref pull-delta: " + err)
      }
      if out_path.has_prefix("dist/") {
        ensure_dist_dir()
      }
      write_advanced_graph_delta_file(out_path, delta)
      println("index ref pull-delta: wrote " + out_path)
    }
  }
}

///|
fn print_graph_def_entry(def : @x_exp.AdvancedGraphDef) -> Unit {
  println(
    def.path +
    "@" +
    def.start.to_string() +
    ".." +
    def.end.to_string() +
    "  " +
    def.kind +
    " " +
    def.name +
    " : " +
    def.signature +
    "  #" +
    short_hash(def.def_id),
  )
}

///|
fn write_index_xdb_graph_head(
  index_root : String,
  graph_head : String,
  function_tracking : Json,
) -> Result[Unit, String] {
  let index_xdb_path = index_root + "/index.xdb"
  let xdb_obj = load_index_xdb_object(index_xdb_path)
  xdb_obj["graph_head"] = Json::string(graph_head)
  xdb_obj["function_tracking"] = function_tracking
  write_index_xdb_object(index_xdb_path, xdb_obj)
}

///|
fn sync_graph_head_for_loaded_db(
  db : @xsh_lib.XshDb,
  entry : String,
  paths : Array[String],
  base_commit : String,
) -> Result[(@x_exp.AdvancedGraphIndex, String), String] {
  let index = @x_exp.build_advanced_graph_index(
    db,
    paths,
    base_commit~,
    created_at=@env.now().to_string(),
  )
  let index_json = index.to_json().stringify()
  let graph_head = @xsh_core.git_blob_hash_string(index_json)
  let index_root = @codebase.resolve_index_root(entry)
  let xsh_dir = find_xsh_dir(index_root + "/index.xsh")
  let codebase = @codebase.Codebase::new(xsh_dir)
  let _ = codebase.write_object(graph_head, index_json) catch {
    e => return Err("sync graph snapshot object: " + e.to_string())
  }
  let index_xdb_path = index_root + "/index.xdb"
  let xdb_obj = load_index_xdb_object(index_xdb_path)
  let function_tracking = compute_function_tracking_json(
    db, paths, index, xdb_obj,
  )
  match write_index_xdb_graph_head(index_root, graph_head, function_tracking) {
    Ok(_) => ()
    Err(err) => return Err(err)
  }
  Ok((index, graph_head))
}

///|
fn resolve_entry_artifacts(
  entry_path : String,
) -> Result[
  (
    @xsh_lib.XshDb,
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
  let (db, entry, paths) = match @loader.load_db_with_paths(resolved) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let (index, graph_head) = match
    sync_graph_head_for_loaded_db(db, entry, paths, "") {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  Ok((db, entry, synced_lock, index, graph_head))
}

///|
fn index_build_cmd(args : Array[String]) -> Unit {
  let mut out_path = "dist/advanced-graph-index.json"
  let mut base_commit = ""
  let mut entry : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-o" | "--out" => {
        i += 1
        if i >= args.length() {
          abort("index build: missing output path after " + arg)
        }
        out_path = args[i]
      }
      "--base-commit" => {
        i += 1
        if i >= args.length() {
          abort("index build: missing value after --base-commit")
        }
        base_commit = args[i]
      }
      _ =>
        match entry {
          Some(_) => abort("index build: unexpected extra arg: " + arg)
          None => entry = Some(arg)
        }
    }
    i += 1
  }
  let entry_path = match entry {
    Some(path) => path
    None => abort("index build: expected <entry-file>")
  }
  if out_path.has_prefix("dist/") {
    ensure_dist_dir()
  }
  match @loader.load_db_with_paths(entry_path) {
    Ok((db, entry, paths)) => {
      let (index, graph_head) = match
        sync_graph_head_for_loaded_db(db, entry, paths, base_commit) {
        Ok(v) => v
        Err(err) => abort("index build: " + err)
      }
      match @x_exp.write_advanced_graph_index(out_path, index) {
        Ok(_) =>
          println(
            "index build: wrote " +
            out_path +
            " (" +
            index.defs.length().to_string() +
            " defs), index.xdb graph_head=" +
            short_hash(graph_head),
          )
        Err(err) => abort("index build: " + err)
      }
    }
    Err(err) => abort("index build: " + err)
  }
}

///|
fn index_query_cmd(args : Array[String]) -> Unit {
  if args.length() != 3 {
    abort("index query: expected <symbol|type> <query> <index-file>")
  }
  let lane = args[0]
  let query = args[1]
  let index_path = args[2]
  let index = index_load_file(index_path)
  let matches = match lane {
    "symbol" => index.query_symbol(query)
    "type" => index.query_type(query)
    _ => abort("index query: unknown lane: " + lane)
  }
  if matches.length() == 0 {
    println("index query: no matches")
    return
  }
  println(
    "index query: " +
    matches.length().to_string() +
    " matches for `" +
    query +
    "`",
  )
  for def in matches {
    print_graph_def_entry(def)
  }
}

///|
fn index_verify_cmd(args : Array[String]) -> Unit {
  if args.length() != 1 {
    abort("index verify: expected <index-file>")
  }
  let index = index_load_file(args[0])
  let issues = index.verify()
  if issues.length() == 0 {
    println("index verify: ok (" + index.defs.length().to_string() + " defs)")
    return
  }
  for issue in issues {
    println("index verify: " + issue)
  }
  abort("index verify: failed (" + issues.length().to_string() + " issues)")
}

///|
fn index_cmd(args : Array[String]) -> Unit {
  if args.length() == 0 {
    abort("index: expected subcommand (build|query|verify|wal|ref)")
  }
  let sub = args[0]
  let sub_args = args_tail(args, 1)
  match sub {
    "build" => index_build_cmd(sub_args)
    "query" => index_query_cmd(sub_args)
    "verify" => index_verify_cmd(sub_args)
    "wal" => index_wal_cmd(sub_args)
    "ref" => index_ref_cmd(sub_args)
    _ => abort("index: unknown subcommand: " + sub)
  }
}

///|
/// LSP server command - reads JSON-RPC from stdin, writes to stdout
fn lsp_cmd(_args : Array[String]) -> Unit {
  // Run LSP server asynchronously
  @async.run_async_main(lsp_main_loop)
}

///|
/// Main LSP loop - reads Content-Length framed messages from stdin
async fn lsp_main_loop() -> Unit {
  let server = @lsp.LspServer::new()
  let stdin = @stdio.stdin
  let stdout = @stdio.stdout

  // Simple Content-Length based message reader
  while true {
    // Read Content-Length header
    match stdin.read_until("\n") {
      None => break
      Some(header_line) => {
        let header_str = header_line.to_string()
        if not(header_str.has_prefix("Content-Length:")) {
          continue
        }
        // Parse content length
        let len_part = header_str[15:].to_string()
        let len_str = trim_whitespace(len_part)
        let content_length = @strconv.parse_int(len_str) catch { _ => continue }

        // Skip empty line after headers
        let _ = stdin.read_until("\n")

        // Read content bytes
        let content = stdin.read_exactly(content_length)
        let json : Json = @json.parse(content.to_string()) catch {
          _ => continue
        }

        // Handle message
        let (response, notifications) = server.handle_message(json)

        // Send notifications first
        for notif in notifications {
          let msg = notif.stringify()
          let header = "Content-Length: " +
            msg.length().to_string() +
            "\r\n\r\n"
          stdout.write(header)
          stdout.write(msg)
        }

        // Send response
        match response {
          Some(resp) => {
            let json_str = @lsp.response_to_json(resp).stringify()
            let header = "Content-Length: " +
              json_str.length().to_string() +
              "\r\n\r\n"
            stdout.write(header)
            stdout.write(json_str)
          }
          None => ()
        }

        // Check for exit
        if server.is_exit_requested() {
          break
        }
      }
    }
  }
}

///|
fn trim_whitespace(s : String) -> String {
  let buf = StringBuilder::new()
  for c in s {
    if c != ' ' && c != '\t' && c != '\r' && c != '\n' {
      buf.write_char(c)
    }
  }
  buf.to_string()
}
