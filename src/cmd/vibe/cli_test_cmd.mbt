///|
struct CompiledTestCase {
  name : String?
  body : @vibe_core.Module
} derive(Debug, Eq)

///|
struct CliTestFailure {
  name : String?
  error : String
} derive(Debug, Eq)

///|
struct CliTestReport {
  total : Int
  passed : Int
  failed : Int
  failures : Array[CliTestFailure]
} derive(Debug, Eq)

///|
impl Show for CliTestReport with output(self, logger) {
  logger.write_string(Debug::to_repr(self).to_string())
}

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
/// Return the module-qualifier prefix of a stmt's binding name, if any.
/// For `Stmt::Let(name="Math::abs", ...)` → `Some("Math")`; otherwise `None`.
/// The parser lowers `module Math { export let abs = ... }` into bare
/// `Let(name="Math::abs", ...)` stmts, dropping the wrapper; the test
/// batch-source renderer needs to re-inject that wrapper so the sliced
/// source text (which is the *inner* `export let abs = ...`) parses back
/// into the same qualified binding.
fn compiled_test_stmt_module_prefix(stmt : @vibe_core.Stmt) -> String? {
  let name = match stmt {
    @vibe_core.Stmt::Let(name~, ..) => name
    @vibe_core.Stmt::ExportLet(name~, ..) => name
    @vibe_core.Stmt::InternalExportLet(name~, ..) => name
    @vibe_core.Stmt::LetMut(name~, ..) => name
    _ => return None
  }
  let idx = name.find("::")
  match idx {
    Some(i) => {
      let prefix = name.substring(start=0, end=i)
      if prefix.length() == 0 || prefix.contains("::") {
        None
      } else {
        Some(prefix)
      }
    }
    None => None
  }
}

///|
fn render_stmt_snippets(
  source : String,
  stmts : Array[@vibe_core.Stmt],
) -> String {
  let out = StringBuilder::new()
  // Dedupe by (start, end) span: `derive(EqualityTrait, ...)` on an enum or
  // struct definition produces multiple AST stmts (the data decl plus one
  // synthetic `TraitImpl` per derive) that all share the *same* source span.
  // Naively emitting each would produce duplicate `enum Color { ... }` lines
  // in the generated batch source and trigger a spurious "duplicate type"
  // checker error.
  let seen_spans : Map[String, Bool] = {}
  // Group consecutive stmts that share a `Name::member` qualifier prefix so
  // they can be re-wrapped in `module Name { ... }`. Without this, the
  // source-sliced text loses the module wrapper and the inner `export let
  // abs = ...` re-parses as a bare `abs` binding, making `Math::abs(...)`
  // unresolvable in test bodies.
  let mut i = 0
  let n = stmts.length()
  while i < n {
    let stmt = stmts[i]
    let span = stmt.span()
    let span_key = span.start.to_string() + "-" + span.end.to_string()
    if seen_spans.contains(span_key) {
      i = i + 1
      continue
    }
    let prefix = compiled_test_stmt_module_prefix(stmt)
    match prefix {
      Some(mod_name) => {
        // Scan forward to collect all consecutive stmts sharing the same
        // module prefix. Intervening stmts from other modules break the run.
        let group_start = i
        let mut group_end = i
        while group_end < n {
          let peek = stmts[group_end]
          match compiled_test_stmt_module_prefix(peek) {
            Some(p) if p == mod_name => group_end = group_end + 1
            _ => break
          }
        }
        out.write_string("module ")
        out.write_string(mod_name)
        out.write_string(" {\n")
        let mut j = group_start
        while j < group_end {
          let inner = stmts[j]
          let inner_span = inner.span()
          let inner_key = inner_span.start.to_string() +
            "-" +
            inner_span.end.to_string()
          if seen_spans.contains(inner_key) {
            j = j + 1
            continue
          }
          seen_spans[inner_key] = true
          let snippet = source_slice_by_span(
            source,
            inner_span.start,
            inner_span.end,
          )
          if snippet.trim().to_string().length() == 0 {
            j = j + 1
            continue
          }
          out.write_string("  ")
          out.write_string(snippet)
          if not(snippet.has_suffix("\n")) {
            out.write_char('\n')
          }
          j = j + 1
        }
        out.write_string("}\n")
        i = group_end
      }
      None => {
        seen_spans[span_key] = true
        let snippet = source_slice_by_span(source, span.start, span.end)
        if snippet.trim().to_string().length() == 0 {
          i = i + 1
          continue
        }
        out.write_string(snippet)
        if not(snippet.has_suffix("\n")) {
          out.write_char('\n')
        }
        i = i + 1
      }
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
    // Function bindings must stay at top level to avoid closure-capture errors
    // when the compiled test wrapper wraps the body in a lambda.
    @vibe_core.Stmt::Let(expr=@vibe_core.Expr::Fn(..), ..) => false
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
  out.write_string(
    "export let _start = () -> Int with { Error, Fs, Process, Env, Stdout, Stdin, Net, Async, Threads, Llm } {\n",
  )
  out.write_string("__vibe_compiled_test_case()\n")
  out.write_string("}\n")
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
  out.write_string(
    "export let _start = () -> Int with { Error, Fs, Process, Env, Stdout, Stdin, Net, Async, Threads, Llm } {\n",
  )
  out.write_string("let mut __test_failures = 0\n")
  for i = 0; i < body_sources.length(); i = i + 1 {
    let i_str = i.to_string()
    out.write_string(
      "let __test_result_" +
      i_str +
      " = handle { __test_" +
      i_str +
      "() } with Error { Throw(_e) => 1 }\n",
    )
    out.write_string(
      "if __test_result_" +
      i_str +
      " != 0 { __test_failures = __test_failures + 1 }\n",
    )
  }
  out.write_string("__test_failures\n")
  out.write_string("}\n")
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
  use_node_runner : Bool,
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
    http_host_imports=use_node_runner,
    fs_host_imports=use_node_runner,
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
  let (use_http_host_runner, use_fs_host_runner) = detect_exec_host_runner_requirements(
    db, entry,
  )
  let use_node_runner = use_http_host_runner || use_fs_host_runner
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
  // ADR-0026: Pure test result cache — skip execution when all tests are
  // effect-free and source hashes match.
  let current_hashes = collect_source_hash_cache(db, entry, true)
  let pure_cache_result = pure_test_cache_lookup(
    db, entry, ast, cases, current_hashes,
  )
  match pure_cache_result {
    Some(report) => {
      println(
        entry +
        ": cached (" +
        report.total.to_string() +
        "/" +
        report.total.to_string() +
        " pure)",
      )
      return CompiledTestAttempt::Success(report)
    }
    None => ()
  }
  let runner = match resolve_bench_wasm_runner(entry) {
    Ok(v) => v
    // Tooling unavailability (e.g. wasmtime not found) must NOT degrade to a
    // skip in #266's TestFileOutcome::Skipped path — that would silently
    // green-light a broken environment in CI / local gating. Return an
    // explicit Error so the file ends up in TestFileOutcome::Errored and the
    // process exits with a failure code.
    Err(err) => return CompiledTestAttempt::Error(err)
  }
  let (test_cache_dir, cached_batch_wasm_path, cached_batch_hash_path) = compiled_test_batch_cache_paths(
    entry, use_node_runner,
  )
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
  let http_runner = match use_node_runner {
    true =>
      match resolve_http_host_runner(entry) {
        Ok(v) => Some(v)
        // Same as resolve_bench_wasm_runner above: a missing host runner
        // (e.g. node not in PATH) is an environment problem, not an
        // unsupported test feature, and must surface as Errored so the
        // process fails instead of silently skipping.
        Err(err) => return CompiledTestAttempt::Error(err)
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
          stamp, runner, http_runner, use_node_runner, stop_on_first_failure,
        )
      }
      Ok(v) => v
    }
    let batch_wasm_bytes = compile_module_wasm_for_exec(
      batch_db,
      batch_entry,
      http_host_imports=use_node_runner,
      fs_host_imports=use_node_runner,
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
          stamp, runner, http_runner, use_node_runner, stop_on_first_failure,
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
      runner, http_runner, use_node_runner, stop_on_first_failure,
    )
  } else {
    // ADR-0026: Save pure test result cache on success
    pure_test_cache_save(db, entry, ast, cases, current_hashes)
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
  use_node_runner : Bool,
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
      cache, runner, http_runner, use_node_runner, source_path, wasm_path, case_source,
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
/// Outcome of running a single test file. Skipped is used for cases the
/// compiled backend cannot attempt at all (e.g. unsupported host imports);
/// these should not count as failures and should not cause CI wrappers like
/// the selfhost bootstrap gate to fail. See issue #266.
enum TestFileOutcome {
  Done(CliTestReport)
  Skipped(String)
  Errored(String)
}

///|
fn run_test_file_with_backend_with_cache(
  cache : CliEntryDbCache,
  entry_path : String,
  features : @runtime.RuntimeFeatureFlags,
) -> TestFileOutcome {
  ignore(features)
  // Runtime import failures are detected from compiled failure reports, so
  // ordinary failing tests keep the compiled per-case reporting path.
  let stop_on_first_failure = false
  match
    run_test_file_compiled_with_cache(cache, entry_path, stop_on_first_failure) {
    CompiledTestAttempt::Success(report) => {
      if report.failed > 0 &&
        compiled_report_has_runtime_import_failures(report) {
        return TestFileOutcome::Skipped(
          "compiled test backend unsupported: runtime imports are not available in compiled mode",
        )
      }
      TestFileOutcome::Done(report)
    }
    CompiledTestAttempt::Unsupported(err) =>
      TestFileOutcome::Skipped("compiled test backend unsupported: " + err)
    CompiledTestAttempt::Error(err) => TestFileOutcome::Errored(err)
  }
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
fn test_cmd(
  args : Array[String],
  features : @runtime.RuntimeFeatureFlags,
) -> Unit {
  @runtime_compile.init_hooks()
  if has_help_flag(args) {
    print_test_help()
    return
  }
  if args.length() == 0 {
    abort("test: expected <file|dir...>")
  }
  // Parse --jobs, --report-json, --no-cache flags
  let mut jobs = 0
  let mut report_json = false
  let mut no_cache = false
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
    } else if arg == "--no-cache" {
      no_cache = true
    } else {
      path_args.push(arg)
    }
    i += 1
  }
  if no_cache {
    @sys.set_env_var("VIBE_NO_TEST_CACHE", "1")
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
  let mut skipped_count = 0
  let file_count = entry_paths.length()
  let cache = CliEntryDbCache::new()
  let use_session_http = cli_use_session_http()
  for entry_path in entry_paths {
    let outcome = if use_session_http {
      match run_test_file_via_session(entry_path, features) {
        Ok(v) => TestFileOutcome::Done(v)
        Err(_) =>
          run_test_file_with_backend_with_cache(cache, entry_path, features)
      }
    } else {
      run_test_file_with_backend_with_cache(cache, entry_path, features)
    }
    match outcome {
      TestFileOutcome::Done(report) => {
        if !print_cli_test_report(entry_path, report) {
          failed = true
        }
        total += report.total
        passed += report.passed
        failed_count += report.failed
      }
      TestFileOutcome::Skipped(reason) => {
        println("\{entry_path}: skipped (\{reason})")
        skipped_count += 1
      }
      TestFileOutcome::Errored(err) => {
        println("[\{entry_path}] \{err}")
        failed = true
      }
    }
  }
  println(
    "summary: files=\{file_count} total=\{total} passed=\{passed} failed=\{failed_count} skipped=\{skipped_count}",
  )
  if failed {
    // Use c_exit(1) instead of abort() so the process terminates cleanly
    // instead of sending SIGABRT, which on Linux generates a noisy core
    // dump and causes CI wrappers like `timeout` to report confusing
    // "command dumped core" messages even though the failure is a normal
    // test-suite exit. See issue #266.
    println("test: failures detected")
    c_exit(1)
  }
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
fn[T] test_entry_selection_sort(
  items : Array[T],
  compare : (T, T) -> Int,
) -> Unit {
  let n = items.length()
  if n < 2 {
    return
  }
  for i in 0..<(n - 1) {
    let mut min_index = i
    for j in (i + 1)..<n {
      if compare(items[j], items[min_index]) < 0 {
        min_index = j
      }
    }
    if min_index != i {
      let tmp = items[i]
      items[i] = items[min_index]
      items[min_index] = tmp
    }
  }
}

///|
fn sort_test_entry_paths_for_batching(paths : Array[String]) -> Unit {
  test_entry_selection_sort(paths, compare_test_entry_batch_path)
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
  test_entry_selection_sort(units, compare_test_entry_batch_unit)
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
    let mut skipped_count = 0
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
            let file_skipped = parse_report_json_int(json, "skipped")
            let file_elapsed_ms = parse_report_json_int(json, "elapsed_ms")
            total += file_total
            passed += file_passed
            failed_count += file_failed
            if file_skipped > 0 {
              skipped_count += file_skipped
            }
            if file_elapsed_ms > 0 {
              merged_batch_weights[test_batch_weight_cache_key(path)] = file_elapsed_ms
            }
            if file_skipped > 0 && file_total == 0 && file_failed == 0 {
              let reason = parse_report_json_string(json, "reason")
              if reason.length() > 0 {
                println("\{path}: skipped (\{reason})")
              } else {
                println("\{path}: skipped")
              }
            } else {
              let status = if file_failed == 0 { "ok" } else { "fail" }
              println("\{path}: \{status} (\{file_passed}/\{file_total})")
            }
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
      "summary: files=\{file_count} total=\{total} passed=\{passed} failed=\{failed_count} skipped=\{skipped_count}",
    )
    if any_failed {
      // Use c_exit(1) instead of abort() to avoid SIGABRT + core dump on
      // Linux. See the sequential path and issue #266.
      println("test: failures detected")
      c_exit(1)
    }
  })
}
