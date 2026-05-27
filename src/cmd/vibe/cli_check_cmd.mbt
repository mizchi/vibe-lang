///|
/// Per-CLI-invocation cache mapping a resolved index root to its
/// `VibeDb`. Short-lived `vibe` invocations construct this via
/// `CliEntryDbCache::new()` and rely on natural GC at process exit; the
/// session-http worker is long-lived and constructs via
/// `CliEntryDbCache::with_capacity(n)` to evict the least-recently-used
/// root once `by_root` exceeds the cap, so a single worker doesn't grow
/// unbounded across many projects.
struct CliEntryDbCache {
  by_root : Map[String, @runtime.VibeDb]
  access_order : Array[String]
  capacity : Int
}

///|
fn CliEntryDbCache::new() -> CliEntryDbCache {
  { by_root: {}, access_order: [], capacity: 0 }
}

///|
fn CliEntryDbCache::with_capacity(capacity : Int) -> CliEntryDbCache {
  { by_root: {}, access_order: [], capacity }
}

///|
fn CliEntryDbCache::touch_access_order(
  self : CliEntryDbCache,
  root : String,
) -> Unit {
  if self.capacity <= 0 {
    return
  }
  let mut i = 0
  while i < self.access_order.length() {
    if self.access_order[i] == root {
      let _ = self.access_order.remove(i)
      break
    }
    i += 1
  }
  self.access_order.push(root)
}

///|
fn CliEntryDbCache::evict_if_needed(self : CliEntryDbCache) -> Unit {
  if self.capacity <= 0 {
    return
  }
  while self.access_order.length() > self.capacity {
    let oldest = self.access_order.remove(0)
    self.by_root.remove(oldest)
  }
}

///|
fn CliEntryDbCache::db_for_resolved_entry(
  self : CliEntryDbCache,
  resolved_entry : String,
) -> @runtime.VibeDb {
  let root = @codebase.resolve_index_root(resolved_entry)
  self.touch_access_order(root)
  match self.by_root.get(root) {
    Some(db) => db
    None => {
      let db = @runtime.VibeDb::new()
      self.by_root[root] = db
      self.evict_if_needed()
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
} derive(Eq, Debug)

///|
struct CliSessionRequest {
  kind : CliSessionRequestKind
  path : String?
} derive(Eq, Debug)

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
          let dep_index = @vibe_core.LineIndex::build(dep_source)
          for dep_diag in dep_diags {
            messages.push(dep_diag.render_with_index(imp.path, dep_index))
          }
        }
      }
      // Build the entry's line index once; reused for every diagnostic
      // and warning render. Without this, each `render(.., source)` walks
      // `source` from offset 0 to find line/column, turning N warnings on
      // an N-line file into O(N²).
      let entry_index = @vibe_core.LineIndex::build(source)
      let diags = db.diagnostics(entry)
      for diag in diags {
        messages.push(diag.render_with_index(entry_path, entry_index))
      }
      let warnings = db.warnings(entry)
      for warning in warnings {
        messages.push(warning.render_with_index(entry_path, entry_index))
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
  if has_help_flag(args) {
    print_check_help()
    return
  }
  let (args, profile_path) = match extract_profile_flag(args) {
    Ok(v) => v
    Err(msg) => abort("check: " + msg)
  }
  let (check_args, profile_tsv, builtin_contract) = match
    split_check_cmd_args(args) {
    Ok(v) => v
    Err(msg) => abort(msg)
  }
  if check_args.length() == 0 {
    abort("check: expected <file...>")
  }
  with_profile(profile_path, fn() {
    check_cmd_body(
      check_args, profile_tsv, builtin_contract,
    )
  })
}

///|
fn check_cmd_body(
  check_args : Array[String],
  profile_tsv : String?,
  builtin_contract : String,
) -> Unit {
  @runtime_compile.init_hooks()
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
  // Builtin contract verification
  if builtin_contract != "ignore" {
    let checker_names = @checker.checker_declared_builtin_names()
    let report = @runtime_compile.verify_builtin_contract(checker_names)
    let contract_messages = @runtime_compile.format_builtin_contract_report(
      report, builtin_contract,
    )
    for msg in contract_messages {
      println(msg)
    }
    if builtin_contract == "error" && report.missing_handlers.length() > 0 {
      total_errors += report.missing_handlers.length()
    }
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
    println("check: \{total_errors} error(s) found")
    c_exit(1)
  }
}

///|
/// Return an exit message when check finds errors, or None for success.
fn check_failure_message(total_errors : Int) -> String? {
  if total_errors > 0 {
    Some("check: \{total_errors} error(s) found")
  } else {
    None
  }
}

///|
fn split_check_cmd_args(
  args : Array[String],
) -> Result[(Array[String], String?, String), String] {
  let filtered : Array[String] = []
  let mut profile_tsv : String? = None
  let mut builtin_contract : String = "ignore"
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if arg == "--profile-tsv" {
      i += 1
      if i >= args.length() {
        return Err("check: missing path after --profile-tsv")
      }
      profile_tsv = Some(args[i])
    } else if arg.has_prefix("--builtin-contract=") {
      let value = arg["--builtin-contract=".length():].to_owned()
      if value == "warn" || value == "error" || value == "ignore" {
        builtin_contract = value
      } else {
        return Err(
          "check: invalid --builtin-contract value: " +
          value +
          " (expected warn|error|ignore)",
        )
      }
    } else if arg == "--builtin-contract" {
      i += 1
      if i >= args.length() {
        return Err("check: missing value after --builtin-contract")
      }
      let value = args[i]
      if value == "warn" || value == "error" || value == "ignore" {
        builtin_contract = value
      } else {
        return Err(
          "check: invalid --builtin-contract value: " +
          value +
          " (expected warn|error|ignore)",
        )
      }
    } else {
      filtered.push(arg)
    }
    i += 1
  }
  Ok((filtered, profile_tsv, builtin_contract))
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
        if !rendered.has_suffix("\n") {
          out.write_char('\n')
        }
      }
      None => {
        let span = stmt.span()
        let snippet = source_slice_by_span(source, span.start, span.end)
        if snippet.trim().to_owned().length() == 0 {
          continue
        }
        out.write_string(snippet)
        if !snippet.has_suffix("\n") {
          out.write_char('\n')
        }
      }
    }
  }
  let result = out.to_string()
  if result.trim().to_owned().length() == 0 {
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
  let source = match load_scratch_db_source(db_path) {
    Ok(v) => v
    Err(err) => abort("finalize: " + err)
  }
  if source.trim().to_owned().length() == 0 {
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
  if !options.dry_run {
    match write_scratch_db_source(db_path, finalized_source) {
      Ok(_) => ()
      Err(err) => abort("finalize: " + err)
    }
    match options.export_path {
      Some(path) =>
        match write_output_source(path, finalized_source) {
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
