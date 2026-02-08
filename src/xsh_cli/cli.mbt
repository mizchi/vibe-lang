///|
/// CLI entry logic for xsh
pub fn run(args : Array[String]) -> Unit {
  if args.length() <= 1 {
    print_usage()
    return
  }
  let cmd = args[1]
  let raw_cmd_args = args_tail(args, 2)
  let (syntax_mode, cmd_args) = match parse_cli_syntax_args(raw_cmd_args, cmd) {
    Ok(v) => v
    Err(msg) => abort(msg)
  }
  if command_requires_parser(cmd) {
    match ensure_cli_parser_mode_supported(syntax_mode, cmd) {
      Ok(_) => ()
      Err(msg) => abort(msg)
    }
  }
  match cmd {
    "run" => run_cmd(cmd_args, syntax_mode)
    "test" => test_cmd(cmd_args)
    "check" => check_cmd(cmd_args)
    "fmt" => fmt_cmd(cmd_args)
    "compile" => compile_cmd(cmd_args)
    "bench" => bench_cmd(cmd_args, syntax_mode)
    "bench-file" => bench_file_cmd(cmd_args)
    "repl" => repl_cmd(cmd_args, syntax_mode)
    "repl-stdin" => repl_stdin_cmd(cmd_args, syntax_mode)
    "repl-wasi" => repl_wasi_cmd(cmd_args, syntax_mode)
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
  println("  test <file|dir...>         run test blocks in scripts")
  println("  check <file...>            parse/type check scripts")
  println("  fmt [--write] <file...>    format scripts via CST")
  println(
    "  compile [--wasm | --wasm-js-string | --wasm-gc | --component | --wit | --wit-component] [-o out] <file>",
  )
  println(
    "                                     emit to dist/ (or -o path). Formats: IR, Core WASM, Component WASM",
  )
  println("  bench [--n N] [--warmup N] [--expr EXPR]")
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
  println("  fetch <file>                resolve imports and write xsh.lock")
  println("  update-lock <file>          alias for fetch")
  println("  ide <outline|peek-def|search> ...  symbol/type index queries")
  println("  lsif [-o out.lsif] <file>   emit LSIF via shared symbol index")
  println("  index <build|query|verify> ...  advanced graph index (POC)")
  println("  lsp                         start LSP server (stdin/stdout)")
  println("  parser commands: --syntax xsh|posix (default: xsh)")
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
fn command_requires_parser(cmd : String) -> Bool {
  match cmd {
    "run"
    | "test"
    | "check"
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
enum CompileMode {
  Ir
  Wasm
  WasmJsString
  WasmGc
  Component
  Wit
  WitComponent
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
fn ensure_dist_dir() -> Unit {
  if not(@os_fs.path_exists("dist")) {
    @os_fs.create_dir("dist") catch {
      e => abort("compile: failed to create dist/: " + e.to_string())
    }
  }
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
fn compile_cmd(args : Array[String]) -> Unit {
  let mut mode = CompileMode::Ir
  let mut out_path : String? = None
  let mut entry_path : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--wasm" => {
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
      "--wit" => {
        mode = CompileMode::Wit
        i += 1
      }
      "--wit-component" => {
        mode = CompileMode::WitComponent
        i += 1
      }
      "-o" | "--out" => {
        if i + 1 >= args.length() {
          abort("compile: missing output path after " + arg)
        }
        out_path = Some(args[i + 1])
        i += 2
      }
      _ => {
        if entry_path is None {
          entry_path = Some(arg)
        } else {
          abort("compile: too many input files")
        }
        i += 1
      }
    }
  }
  match entry_path {
    None => abort("compile: missing <file>")
    Some(path) =>
      match load_db(path) {
        Err(err) => abort("compile: " + err)
        Ok((db, entry)) => {
          // Resolve output path with default to dist/
          let resolved_out = match out_path {
            Some(p) => p
            None => {
              ensure_dist_dir()
              default_output_path(path, mode)
            }
          }
          match mode {
            CompileMode::Ir => {
              let compiled = @xsh_lib.compile_module(db, entry) catch {
                e => abort("compile: " + e.to_string())
              }
              @os_fs.write_string_to_file(resolved_out, compiled.ir) catch {
                e => abort("compile: " + e.to_string())
              }
              println("wrote " + resolved_out)
            }
            CompileMode::Wasm => {
              let wasm_bytes = @xsh_lib.compile_module_wasm(db, entry) catch {
                e => abort("compile: " + e.to_string())
              }
              @os_fs.write_bytes_to_file(resolved_out, wasm_bytes) catch {
                e => abort("compile: " + e.to_string())
              }
              println("wrote " + resolved_out)
            }
            CompileMode::WasmJsString => {
              let wasm_bytes = @xsh_lib.compile_module_wasm_js_string(db, entry) catch {
                e => abort("compile: " + e.to_string())
              }
              @os_fs.write_bytes_to_file(resolved_out, wasm_bytes) catch {
                e => abort("compile: " + e.to_string())
              }
              println("wrote " + resolved_out)
            }
            CompileMode::WasmGc => {
              let wasm_bytes = @xsh_lib.compile_module_wasm_gc(db, entry) catch {
                e => abort("compile: " + e.to_string())
              }
              @os_fs.write_bytes_to_file(resolved_out, wasm_bytes) catch {
                e => abort("compile: " + e.to_string())
              }
              println("wrote " + resolved_out)
            }
            CompileMode::Component => {
              let wasm_bytes = @xsh_lib.compile_module_component(db, entry) catch {
                e => abort("compile: " + e.to_string())
              }
              @os_fs.write_bytes_to_file(resolved_out, wasm_bytes) catch {
                e => abort("compile: " + e.to_string())
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
              @os_fs.write_string_to_file(resolved_out, wit_str) catch {
                e => abort("compile: " + e.to_string())
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
              @os_fs.write_string_to_file(resolved_out, wit_str) catch {
                e => abort("compile: " + e.to_string())
              }
              println("wrote " + resolved_out)
            }
          }
        }
      }
  }
}

///|
fn run_cmd(args : Array[String], syntax_mode : @xsh_lib.ParserMode) -> Unit {
  if args.length() != 1 {
    abort("run: expected <file>")
  }
  let entry_path = args[0]
  match syntax_mode {
    @xsh_lib.ParserMode::XshMode =>
      match load_db(entry_path) {
        Err(err) => abort("run: " + err)
        Ok((db, entry)) => {
          let compiled = @xsh_lib.compile_module(db, entry) catch {
            e => abort("run: " + e.to_string())
          }
          let rt = @xsh_lib.Runtime::new(@capability.CapabilitySet::developer())
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
                    let resolved = resolve_import_path(base_dir, raw_path)
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
      let resolved = resolve_entry_path(entry_path)
      let source = @os_fs.read_file_to_string(resolved) catch {
        e => abort("run: " + e.to_string())
      }
      let rt = @xsh_lib.Runtime::new(@capability.CapabilitySet::developer())
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
    let resolved = resolve_entry_path(entry_path)
    let source = @os_fs.read_file_to_string(resolved) catch {
      e => {
        println("check: \{entry_path}: \{e}")
        total_errors += 1
        continue
      }
    }
    match load_db(entry_path) {
      Err(err) => {
        println("check: \{entry_path}: \{err}")
        total_errors += 1
      }
      Ok((db, entry)) => {
        let _ = db.types(entry)
        let diags = db.diagnostics(entry)
        for diag in diags {
          println(diag.render(entry_path, source))
        }
        if diags.length() == 0 {
          println("\{entry_path}: ok")
        }
        total_errors += diags.length()
      }
    }
  }
  if total_errors > 0 {
    abort("check: \{total_errors} error(s) found")
  }
}

///|
fn test_cmd(args : Array[String]) -> Unit {
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
    match load_db(entry_path) {
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
        let rt = @xsh_lib.Runtime::new(@capability.CapabilitySet::developer())
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
                  let resolved = resolve_import_path(base_dir, raw_path)
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
fn fmt_cmd(args : Array[String]) -> Unit {
  if args.length() == 0 {
    abort("fmt: expected <file...>")
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
    abort("fmt: expected <file...>")
  }
  if not(write) && files.length() > 1 {
    abort("fmt: use --write for multiple files")
  }
  for path in files {
    let src = @os_fs.read_file_to_string(path) catch {
      e => abort("fmt: " + e.to_string())
    }
    let formatted = @parser.format_script(src)
    if write {
      @os_fs.write_string_to_file(path, formatted) catch {
        e => abort("fmt: " + e.to_string())
      }
    } else {
      println(formatted)
    }
  }
}

///|
fn bench_cmd(args : Array[String], syntax_mode : @xsh_lib.ParserMode) -> Unit {
  let mut count = 20000
  let mut warmup = 1000
  let mut expr = "add(1,2)"
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
        expr = args[i + 1]
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
  let rt = @xsh_lib.Runtime::new(@capability.CapabilitySet::developer())
  for _ in 0..<warmup {
    let _ = rt.eval_script_with_mode(expr, syntax_mode) catch {
      e => abort("bench: " + e.to_string())
    }

  }
  let start = @env.now()
  for _ in 0..<count {
    let _ = rt.eval_script_with_mode(expr, syntax_mode) catch {
      e => abort("bench: " + e.to_string())
    }

  }
  let end = @env.now()
  let elapsed_ms = (end - start).to_double()
  let per_us = elapsed_ms * 1000.0 / count.to_double()
  if elapsed_ms <= 0.0 {
    println("bench: elapsed_ms=0; increase --n for measurable time")
  }
  println(
    "bench: expr=\"" +
    expr +
    "\" count=" +
    count.to_string() +
    " total_ms=" +
    elapsed_ms.to_string() +
    " per_us=" +
    per_us.to_string(),
  )
}

///|
fn bench_file_cmd(args : Array[String]) -> Unit {
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
      let rt = @xsh_lib.Runtime::new(@capability.CapabilitySet::developer())
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
fn repl_cmd(args : Array[String], syntax_mode : @xsh_lib.ParserMode) -> Unit {
  if args.length() != 0 {
    abort("repl: no args supported")
  }
  let rt = @xsh_lib.Runtime::new(@capability.CapabilitySet::developer())
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
      push_output_line("effect: " + effect.to_string())
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
  @tui.start_keypress_listener(handle_key)
  cleanup_once()
}

///|
fn repl_stdin_cmd(
  args : Array[String],
  syntax_mode : @xsh_lib.ParserMode,
) -> Unit {
  run_eval_line_repl_with_prompt(args, "repl-stdin", "xsh> ", syntax_mode)
}

///|
fn repl_wasi_cmd(
  args : Array[String],
  syntax_mode : @xsh_lib.ParserMode,
) -> Unit {
  run_eval_line_repl_with_prompt(args, "repl-wasi", "wasi> ", syntax_mode)
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
) -> Unit {
  let options = match parse_line_repl_options(args, cmd_name, prompt) {
    Ok(opts) => opts
    Err(msg) => abort(msg)
  }
  async fn repl_loop() {
    let rt = @xsh_lib.Runtime::new(@capability.CapabilitySet::developer())
    let input = @stdio.stdin
    print_line_repl_tty_mode(options.io_mode)
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
    println("effect: " + effect.to_string())
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
fn compile_entry(
  entry_path : String,
) -> Result[@xsh_lib.CompiledModule, String] {
  match load_db(entry_path) {
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
struct LockData {
  path_refs : Map[String, String]
  version_refs : Map[String, String]
  symbol_refs : Map[String, String]
} derive(Show, Eq)

///|
fn empty_lock_data() -> LockData {
  { path_refs: {}, version_refs: {}, symbol_refs: {} }
}

///|
fn normalize_lock_hash(hash : String) -> String {
  if hash.has_prefix("#") && hash.length() > 1 {
    hash.unsafe_substring(start=1, end=hash.length())
  } else {
    hash
  }
}

///|
fn parse_lock_path_map(
  json : Json?,
  base_dir : String,
) -> Result[Map[String, String], String] {
  let out : Map[String, String] = {}
  match json {
    None => Ok(out)
    Some(Json::Object(entries)) => {
      for key, value in entries {
        match value {
          Json::String(hash) => {
            let normalized = if key.has_prefix("/") {
              @xsh_fs.normalize_path(key)
            } else {
              @xsh_fs.normalize_path(base_dir + "/" + key)
            }
            out[normalized] = normalize_lock_hash(hash)
          }
          _ => return Err("xsh.lock: path.\{key} must be a string hash")
        }
      }
      Ok(out)
    }
    Some(_) => Err("xsh.lock: `path` must be an object")
  }
}

///|
fn parse_lock_ref_map(
  json : Json?,
  field_name : String,
) -> Result[Map[String, String], String] {
  let out : Map[String, String] = {}
  match json {
    None => Ok(out)
    Some(Json::Object(entries)) => {
      for key, value in entries {
        match value {
          Json::String(hash) => out[key] = normalize_lock_hash(hash)
          _ =>
            return Err("xsh.lock: \{field_name}.\{key} must be a string hash")
        }
      }
      Ok(out)
    }
    Some(_) => Err("xsh.lock: `\{field_name}` must be an object")
  }
}

///|
fn parse_lock_data(
  content : String,
  base_dir : String,
) -> Result[LockData, String] {
  if content.trim().to_string().length() == 0 {
    return Ok(empty_lock_data())
  }
  let json : Json = @json.parse(content) catch {
    e => return Err("xsh.lock: invalid JSON: " + e.to_string())
  }
  match json {
    Json::Object(obj) => {
      let path_refs = match parse_lock_path_map(obj.get("path"), base_dir) {
        Ok(v) => v
        Err(err) => return Err(err)
      }
      let version_refs = match
        parse_lock_ref_map(obj.get("version"), "version") {
        Ok(v) => v
        Err(err) => return Err(err)
      }
      let symbol_refs = match parse_lock_ref_map(obj.get("symbol"), "symbol") {
        Ok(v) => v
        Err(err) => return Err(err)
      }
      Ok({ path_refs, version_refs, symbol_refs })
    }
    _ => Err("xsh.lock: top-level JSON must be an object")
  }
}

///|
fn write_json_string_literal(text : String, buf : StringBuilder) -> Unit {
  buf.write_char('"')
  for c in text {
    match c {
      '"' => buf.write_string("\\\"")
      '\\' => buf.write_string("\\\\")
      '\n' => buf.write_string("\\n")
      '\r' => buf.write_string("\\r")
      '\t' => buf.write_string("\\t")
      _ => buf.write_char(c)
    }
  }
  buf.write_char('"')
}

///|
fn split_path_parts(path : String) -> Array[String] {
  let parts : Array[String] = []
  for part in path.split("/") {
    let s = part.to_string()
    if s.length() > 0 {
      parts.push(s)
    }
  }
  parts
}

///|
fn relativize_lock_path(base_dir : String, target_path : String) -> String {
  let base = @xsh_fs.normalize_path(base_dir)
  let target = @xsh_fs.normalize_path(target_path)
  if not(base.has_prefix("/")) || not(target.has_prefix("/")) {
    return target
  }
  let base_parts = split_path_parts(base)
  let target_parts = split_path_parts(target)
  let mut common = 0
  while common < base_parts.length() &&
        common < target_parts.length() &&
        base_parts[common] == target_parts[common] {
    common += 1
  }
  let rel_buf = StringBuilder::new()
  let mut wrote = false
  for _ in common..<base_parts.length() {
    if wrote {
      rel_buf.write_char('/')
    }
    rel_buf.write_string("..")
    wrote = true
  }
  for i in common..<target_parts.length() {
    if wrote {
      rel_buf.write_char('/')
    }
    rel_buf.write_string(target_parts[i])
    wrote = true
  }
  let rel = rel_buf.to_string()
  if rel.length() == 0 {
    "."
  } else if rel.has_prefix("..") {
    rel
  } else {
    "./" + rel
  }
}

///|
fn write_lock_map_json(
  map : Map[String, String],
  buf : StringBuilder,
  base_dir : String?,
) -> Unit {
  buf.write_char('{')
  let mut first = true
  for key, value in map {
    if first {
      first = false
    } else {
      buf.write_char(',')
    }
    let rendered_key = match base_dir {
      Some(base) => relativize_lock_path(base, key)
      None => key
    }
    write_json_string_literal(rendered_key, buf)
    buf.write_char(':')
    write_json_string_literal(value, buf)
  }
  buf.write_char('}')
}

///|
fn lock_data_to_json(lock : LockData, lock_base_dir : String) -> String {
  let buf = StringBuilder::new()
  buf.write_char('{')
  write_json_string_literal("path", buf)
  buf.write_char(':')
  write_lock_map_json(lock.path_refs, buf, Some(lock_base_dir))
  buf.write_char(',')
  write_json_string_literal("version", buf)
  buf.write_char(':')
  write_lock_map_json(lock.version_refs, buf, None)
  buf.write_char(',')
  write_json_string_literal("symbol", buf)
  buf.write_char(':')
  write_lock_map_json(lock.symbol_refs, buf, None)
  buf.write_char('}')
  buf.to_string()
}

///|
fn lock_file_path(entry : String) -> String {
  @xsh_fs.parent_path(entry) + "/xsh.lock"
}

///|
fn load_lock_data(lock_path : String) -> Result[LockData, String] {
  if not(@os_fs.path_exists(lock_path)) {
    return Ok(empty_lock_data())
  }
  let base_dir = @xsh_fs.parent_path(lock_path)
  let content = @os_fs.read_file_to_string(lock_path) catch {
    e => return Err("failed to read xsh.lock: " + e.to_string())
  }
  parse_lock_data(content, base_dir)
}

///|
fn write_lock_data(lock_path : String, lock : LockData) -> Result[Unit, String] {
  let base_dir = @xsh_fs.parent_path(lock_path)
  let content = lock_data_to_json(lock, base_dir)
  @os_fs.write_string_to_file(lock_path, content) catch {
    e => return Err("failed to write xsh.lock: " + e.to_string())
  }
  Ok(())
}

///|
fn clone_lock_map(src : Map[String, String]) -> Map[String, String] {
  let out : Map[String, String] = {}
  for key, value in src {
    out[key] = value
  }
  out
}

///|
fn apply_lock_to_db(
  db : @xsh_lib.XshDb,
  entry : String,
) -> Result[LockData, String] {
  db.require_path_lock(true)
  let lock_path = lock_file_path(entry)
  let lock = match load_lock_data(lock_path) {
    Ok(data) => data
    Err(err) => return Err(err)
  }
  for path, hash in lock.path_refs {
    db.set_path_ref(path, hash)
  }
  for name, hash in lock.version_refs {
    db.set_version_ref(name, hash)
  }
  for name, hash in lock.symbol_refs {
    db.set_symbol_ref(name, hash)
  }
  Ok(lock)
}

///|
fn collect_lock_path_refs(
  path : String,
  out : Map[String, String],
  visited : Map[String, Bool],
  stack : Array[String],
) -> Result[Unit, String] {
  let norm = @xsh_fs.normalize_path(path)
  for i, p in stack {
    if p == norm {
      let cycle_path = StringBuilder::new()
      for j = i; j < stack.length(); j = j + 1 {
        cycle_path.write_string(stack[j])
        cycle_path.write_string(" -> ")
      }
      cycle_path.write_string(norm)
      return Err("import cycle detected: " + cycle_path.to_string())
    }
  }
  if visited.contains(norm) {
    return Ok(())
  }
  stack.push(norm)
  visited[norm] = true
  let source = @os_fs.read_file_to_string(norm) catch {
    e => {
      let _ = stack.pop()
      return Err("io: " + e.to_string())
    }
  }
  out[norm] = @xsh_core.git_blob_hash_string(source)
  let ast = @parser.parse_ast(source) catch {
    e => {
      let _ = stack.pop()
      return Err("parse: " + e.to_string())
    }
  }
  let base = @xsh_fs.parent_path(norm)
  for stmt in ast.stmts {
    match stmt {
      @xsh_core.Stmt::Import(source~, ..) =>
        match source {
          @xsh_core.ModuleRef::Path(path~) => {
            let resolved = resolve_import_path(base, path)
            match collect_lock_path_refs(resolved, out, visited, stack) {
              Ok(_) => ()
              Err(err) => {
                let _ = stack.pop()
                return Err(err)
              }
            }
          }
          @xsh_core.ModuleRef::Hash(..)
          | @xsh_core.ModuleRef::Version(..)
          | @xsh_core.ModuleRef::Symbol(..) => ()
        }
      _ => ()
    }
  }
  let _ = stack.pop()
  Ok(())
}

///|
fn fetch_cmd(args : Array[String]) -> Unit {
  if args.length() != 1 {
    abort("fetch: expected <file>")
  }
  let entry = resolve_entry_path(args[0])
  let lock_path = lock_file_path(entry)
  let current = match load_lock_data(lock_path) {
    Ok(lock) => lock
    Err(err) => abort("fetch: " + err)
  }
  let path_refs : Map[String, String] = {}
  let visited : Map[String, Bool] = {}
  let stack : Array[String] = []
  match collect_lock_path_refs(entry, path_refs, visited, stack) {
    Ok(_) => ()
    Err(err) => abort("fetch: " + err)
  }
  let merged_path_refs = clone_lock_map(current.path_refs)
  for path, hash in path_refs {
    merged_path_refs[path] = hash
  }
  let next_lock : LockData = {
    path_refs: merged_path_refs,
    version_refs: current.version_refs,
    symbol_refs: current.symbol_refs,
  }
  match write_lock_data(lock_path, next_lock) {
    Ok(_) => ()
    Err(err) => abort("fetch: " + err)
  }
  println(
    "updated xsh.lock: " +
    lock_path +
    " (" +
    merged_path_refs.length().to_string() +
    " path refs)",
  )
}

///|
fn load_db(entry_path : String) -> Result[(@xsh_lib.XshDb, String), String] {
  match load_db_with_paths(entry_path) {
    Ok((db, entry, _)) => Ok((db, entry))
    Err(err) => Err(err)
  }
}

///|
fn load_db_with_paths(
  entry_path : String,
) -> Result[(@xsh_lib.XshDb, String, Array[String]), String] {
  let db = @xsh_lib.XshDb::new()
  let entry = resolve_entry_path(entry_path)
  match apply_lock_to_db(db, entry) {
    Ok(_) => ()
    Err(err) => return Err(err)
  }
  let visited : Map[String, Bool] = {}
  match load_sources_recursive(db, entry, visited) {
    Ok(_) => {
      let paths : Array[String] = []
      for path, _ in visited {
        paths.push(path)
      }
      paths.sort()
      Ok((db, entry, paths))
    }
    Err(err) => Err(err)
  }
}

///|
fn resolve_entry_path(path : String) -> String {
  if path.has_prefix("/") {
    @xsh_fs.normalize_path(path)
  } else {
    let cwd = match @env.current_dir() {
      Some(dir) => dir
      None => "/"
    }
    @xsh_fs.normalize_path(cwd + "/" + path)
  }
}

///|
fn load_sources_recursive(
  db : @xsh_lib.XshDb,
  path : String,
  visited : Map[String, Bool],
) -> Result[Unit, String] {
  // Use stack-based approach for cycle detection
  let stack : Array[String] = []
  load_sources_recursive_impl(db, path, visited, stack)
}

///|
fn load_sources_recursive_impl(
  db : @xsh_lib.XshDb,
  path : String,
  visited : Map[String, Bool],
  stack : Array[String],
) -> Result[Unit, String] {
  let norm = @xsh_fs.normalize_path(path)
  // Check for cycle: if norm is already in current stack, we have a cycle
  for i, p in stack {
    if p == norm {
      // Build cycle path for error message
      let cycle_path = StringBuilder::new()
      for j = i; j < stack.length(); j = j + 1 {
        cycle_path.write_string(stack[j])
        cycle_path.write_string(" -> ")
      }
      cycle_path.write_string(norm)
      return Err("import cycle detected: " + cycle_path.to_string())
    }
  }
  // If already visited (and not in stack), we've already processed this module
  if visited.contains(norm) {
    return Ok(())
  }
  // Add to stack for cycle detection
  stack.push(norm)
  visited.set(norm, true)
  let source = @os_fs.read_file_to_string(norm) catch {
    e => {
      // Pop from stack before returning error
      let _ = stack.pop()
      return Err("io: " + e.to_string())
    }
  }
  db.set_source(norm, source)
  let ast = @parser.parse_ast(source) catch {
    e => {
      // Pop from stack before returning error
      let _ = stack.pop()
      return Err("parse: " + e.to_string())
    }
  }
  let base = @xsh_fs.parent_path(norm)
  for stmt in ast.stmts {
    match stmt {
      @xsh_core.Stmt::Import(source~, ..) =>
        match source {
          @xsh_core.ModuleRef::Path(path~) => {
            let resolved = resolve_import_path(base, path)
            match load_sources_recursive_impl(db, resolved, visited, stack) {
              Ok(_) => ()
              Err(err) => {
                // Pop from stack before returning error
                let _ = stack.pop()
                return Err(err)
              }
            }
          }
          @xsh_core.ModuleRef::Hash(..)
          | @xsh_core.ModuleRef::Version(..)
          | @xsh_core.ModuleRef::Symbol(..) => ()
        }
      _ => ()
    }
  }
  // Pop from stack after successful processing
  let _ = stack.pop()
  Ok(())
}

///|
fn resolve_import_path(base : String, import_path : String) -> String {
  if import_path.has_prefix("/") {
    @xsh_fs.normalize_path(import_path)
  } else {
    @xsh_fs.normalize_path(base + "/" + import_path)
  }
}

///|
fn hash_cmd(args : Array[String]) -> Unit {
  if args.length() != 1 {
    abort("hash: expected <file>")
  }
  let path = resolve_entry_path(args[0])
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
  let path = resolve_entry_path(file_arg)
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
    let paths_file = base_dir + "/paths.json"
    let mappings = load_path_mappings(paths_file)
    update_path_mapping(mappings, file_arg, bundle.main_hash)
    let mappings_json = @xsh_core.serialize_path_mappings(mappings)
    @os_fs.write_string_to_file(paths_file, mappings_json) catch {
      e => abort("save: write paths: " + e.to_string())
    }
  }
  // Print result
  let main_short = @xsh_core.short_hash(bundle.main_hash)
  println("saved: \{file_arg} -> \{main_short} (\{saved_count} module(s))")
}

///|
fn save_module_to_xsh(base_path : String, json : String, hash : String) -> Unit {
  let base_dir = find_xsh_dir(base_path)
  let obj_dir = @xsh_core.object_dir_from_hash(base_dir, hash)
  let obj_path = @xsh_core.object_path_from_hash(base_dir, hash)
  // Create directories if needed
  let objects_dir = base_dir + "/objects"
  if not(@os_fs.path_exists(objects_dir)) {
    @os_fs.create_dir(objects_dir) catch {
      e => abort("save: mkdir objects: " + e.to_string())
    }
  }
  if not(@os_fs.path_exists(obj_dir)) {
    @os_fs.create_dir(obj_dir) catch {
      e => abort("save: mkdir: " + e.to_string())
    }
  }
  // Write blob (skip if already exists - content-addressed)
  if not(@os_fs.path_exists(obj_path)) {
    @os_fs.write_string_to_file(obj_path, json) catch {
      e => abort("save: write: " + e.to_string())
    }
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
fn load_path_mappings(path : String) -> Array[@xsh_core.PathMapping] {
  if not(@os_fs.path_exists(path)) {
    return []
  }
  let json = @os_fs.read_file_to_string(path) catch { _ => return [] }
  @xsh_core.parse_path_mappings(json) catch {
    _ => []
  }
}

///|
fn update_path_mapping(
  mappings : Array[@xsh_core.PathMapping],
  path : String,
  hash : String,
) -> Unit {
  // Remove existing entry for this path if any
  let mut found = false
  for i, m in mappings {
    if m.path == path {
      mappings[i] = @xsh_core.PathMapping::{ path, hash }
      found = true
      break
    }
  }
  if not(found) {
    mappings.push(@xsh_core.PathMapping::{ path, hash })
  }
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
  // Resolve target to hash
  let main_hash = resolve_target_to_hash(target, xsh_dir)
  let load_module = fn(hash : String) -> @xsh_core.Module? {
    let obj_path = @xsh_core.object_path_from_hash(xsh_dir, hash)
    let json = @os_fs.read_file_to_string(obj_path) catch { _ => return None }
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
fn resolve_target_to_hash(target : String, xsh_dir : String) -> String {
  // If it looks like a hash (40 hex chars or prefix), use it directly
  if is_hash_like(target) {
    return resolve_hash_prefix(target, xsh_dir)
  }
  // Otherwise, try to look up as a path in paths.json
  let paths_file = xsh_dir + "/paths.json"
  let mappings = load_path_mappings(paths_file)
  for m in mappings {
    if m.path == target || m.path.has_suffix(target) {
      return m.hash
    }
  }
  abort("expand: cannot resolve target: " + target)
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
  match load_db_with_paths(args[0]) {
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
  match load_db_with_paths(entry_file) {
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
  match load_db_with_paths(entry_file) {
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
  match load_db_with_paths(entries[0]) {
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
fn index_load_file(path : String) -> @xsh_lib.AdvancedGraphIndex {
  match @xsh_lib.read_advanced_graph_index(path) {
    Ok(index) => index
    Err(err) => abort("index: " + err)
  }
}

///|
fn print_graph_def_entry(def : @xsh_lib.AdvancedGraphDef) -> Unit {
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
  match load_db_with_paths(entry_path) {
    Ok((db, _, paths)) => {
      let index = @xsh_lib.build_advanced_graph_index(
        db,
        paths,
        base_commit=base_commit,
        created_at=@env.now().to_string(),
      )
      match @xsh_lib.write_advanced_graph_index(out_path, index) {
        Ok(_) =>
          println(
            "index build: wrote " +
            out_path +
            " (" +
            index.defs.length().to_string() +
            " defs)",
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
    println(
      "index verify: ok (" + index.defs.length().to_string() + " defs)",
    )
    return
  }
  for issue in issues {
    println("index verify: " + issue)
  }
  abort(
    "index verify: failed (" + issues.length().to_string() + " issues)",
  )
}

///|
fn index_cmd(args : Array[String]) -> Unit {
  if args.length() == 0 {
    abort("index: expected subcommand (build|query|verify)")
  }
  let sub = args[0]
  let sub_args = args_tail(args, 1)
  match sub {
    "build" => index_build_cmd(sub_args)
    "query" => index_query_cmd(sub_args)
    "verify" => index_verify_cmd(sub_args)
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
