///|
fn eval_cmd(
  args : Array[String],
  features : @runtime.RuntimeFeatureFlags,
  enable_llm~ : Bool,
) -> Unit {
  let mut db_path : String? = None
  let include_paths : Array[String] = []
  let mut inspect_scope = false
  let positional : Array[String] = []
  let mut i = 0
  while i < args.length() {
    match args[i] {
      "--db" => {
        if i + 1 >= args.length() {
          abort("eval: --db requires a path argument")
        }
        db_path = Some(args[i + 1])
        i += 2
      }
      "--include" => {
        if i + 1 >= args.length() {
          abort("eval: --include requires a path argument")
        }
        include_paths.push(args[i + 1])
        i += 2
      }
      "--inspect-scope" => {
        inspect_scope = true
        i += 1
      }
      _ =>
        if args[i].has_prefix("--db=") {
          db_path = Some(
            args[i].unsafe_substring(start=5, end=args[i].length()),
          )
          i += 1
        } else {
          positional.push(args[i])
          i += 1
        }
    }
  }
  // Resolve db path
  let resolved_db_path = match db_path {
    Some(p) => @loader.resolve_entry_path(p)
    None => {
      let (_, scratch_db) = match resolve_scratch_db_path() {
        Ok(v) => v
        Err(err) => abort("eval: " + err)
      }
      scratch_db
    }
  }
  // Load existing db source
  let mut source = match load_eval_db_source(resolved_db_path) {
    Ok(s) => s
    Err(err) => abort("eval: " + err)
  }
  // Include files
  for path in include_paths {
    let resolved = @loader.resolve_entry_path(path)
    let file_source = @os_fs.read_file_to_string(resolved) catch {
      e => abort("eval: failed to read include file: " + e.to_string())
    }
    source = append_eval_db_source(source, file_source)
  }
  // Handle --inspect-scope
  if inspect_scope {
    let symbols = collect_eval_scope_symbols(resolved_db_path, source)
    for sym in symbols {
      println(sym.kind + " " + sym.name + " : " + sym.signature)
    }
    return
  }
  // Get expression to eval
  if positional.length() == 0 {
    abort("eval: missing expression argument")
  }
  let expr = positional[0]
  ignore(features)
  ignore(enable_llm)
  // Build source with expression and result expression
  let combined_source = repl_build_compiled_source(source, expr)
  // Compile and run
  async fn eval_run() {
    let cache = CliEntryDbCache::new()
    let source_path = "/tmp/vibe-eval-" + vibe_getpid().to_string() + ".vibe"
    let wasm_path = "/tmp/vibe-eval-" + vibe_getpid().to_string() + ".wasm"
    defer remove_file_if_exists(source_path)
    defer remove_file_if_exists(wasm_path)
    let exec = match
      run_compiled_repl_line_with_cache(
        cache, source_path, wasm_path, source, expr,
      ) {
      Ok(v) => v
      Err(err) => {
        println("error: " + err)
        return
      }
    }
    // Print result
    match exec.display_override {
      Some(display) => println("last: " + display)
      None => repl_print_wasm_run_value(exec.value, fn(s) { println(s) })
    }
    // Persist db state
    let next_source = exec.next_source
    match write_eval_db_source(resolved_db_path, next_source) {
      Ok(_) => ()
      Err(err) => println("error: failed to persist db: " + err)
    }
  }
  @async.run_async_main(eval_run)
}
