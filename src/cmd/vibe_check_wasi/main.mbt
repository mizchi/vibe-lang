///|
pub enum CheckInput {
  Source(String)
  File(String)
  Files(Array[String])
} derive(Eq, Show)

///|
pub enum CommandMode {
  Check
  Format
} derive(Eq, Show)

///|
pub struct CmdOptions {
  mode : CommandMode
  input : CheckInput
} derive(Eq, Show)

///|
struct CheckFileSummary {
  path : String
  resolved_path : String
  graph_head : String?
  error_count : Int
  warning_count : Int
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
pub fn parse_cmd_args(args : Array[String]) -> Result[CmdOptions, String] {
  let mut source : String? = None
  let files : Array[String] = []
  let mut mode = CommandMode::Check
  let mut mode_flag_count = 0
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--check" => {
        mode = CommandMode::Check
        mode_flag_count += 1
      }
      "--format" => {
        mode = CommandMode::Format
        mode_flag_count += 1
      }
      "--source" => {
        i += 1
        if i >= args.length() {
          return Err("check: missing source after --source")
        }
        if source is Some(_) {
          return Err("check: --source specified multiple times")
        }
        source = Some(args[i])
      }
      "--file" => {
        i += 1
        if i >= args.length() {
          return Err("check: missing path after --file")
        }
        files.push(args[i])
      }
      "-h" | "--help" => return Err("help")
      _ => files.push(arg)
    }
    i += 1
  }
  if mode_flag_count > 1 {
    return Err("check: choose either --check or --format")
  }
  match source {
    Some(src) =>
      if files.length() == 0 {
        Ok({ mode, input: CheckInput::Source(src) })
      } else {
        Err("check: --source and file input are exclusive")
      }
    None =>
      if files.length() == 0 {
        Err("check: expected --source <code> or <file>")
      } else if mode == CommandMode::Format && files.length() > 1 {
        Err("check: --format expects exactly one file input")
      } else if files.length() == 1 {
        Ok({ mode, input: CheckInput::File(files[0]) })
      } else {
        Ok({ mode, input: CheckInput::Files(files) })
      }
  }
}

///|
fn has_import_stmt(ast : @core.Module) -> Bool {
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::Import(..) => return true
      _ => ()
    }
  }
  false
}

///|
enum StdModuleLayer {
  TraitContract
  PurePrimitive
  PureData
  RefModel
  EffectBoundary
} derive(Eq, Show)

///|
fn std_layer_name(layer : StdModuleLayer) -> String {
  match layer {
    StdModuleLayer::TraitContract => "trait-contract"
    StdModuleLayer::PurePrimitive => "pure-primitive"
    StdModuleLayer::PureData => "pure-data"
    StdModuleLayer::RefModel => "ref-model"
    StdModuleLayer::EffectBoundary => "effect-boundary"
  }
}

///|
fn std_layer_for_path(path : String) -> StdModuleLayer? {
  let normalized = @vibe_fs.normalize_path(path)
  if (
      not(normalized.contains("/vibe/prelude/")) &&
      not(normalized.contains("/vibe/path/"))
    ) ||
    not(normalized.has_suffix(".vibe")) ||
    normalized.has_suffix("_test.vibe") ||
    normalized.has_suffix("_type_import_test.vibe") ||
    normalized.has_suffix("/test_import.vibe") {
    return None
  }
  if normalized.has_suffix("/vibe/prelude/builtin_traits.vibe") {
    return Some(StdModuleLayer::TraitContract)
  }
  if normalized.has_suffix("/vibe/prelude/bool.vibe") ||
    normalized.has_suffix("/vibe/prelude/cmp.vibe") ||
    normalized.has_suffix("/vibe/prelude/char.vibe") ||
    normalized.has_suffix("/vibe/prelude/int.vibe") ||
    normalized.has_suffix("/vibe/prelude/float.vibe") ||
    normalized.has_suffix("/vibe/prelude/double.vibe") ||
    normalized.has_suffix("/vibe/prelude/string.vibe") {
    return Some(StdModuleLayer::PurePrimitive)
  }
  if normalized.has_suffix("/vibe/prelude/array.vibe") ||
    normalized.has_suffix("/vibe/prelude/option.vibe") ||
    normalized.has_suffix("/vibe/prelude/result.vibe") ||
    normalized.has_suffix("/vibe/prelude/bytes.vibe") ||
    normalized.has_suffix("/vibe/prelude/threads/spec.vibe") {
    return Some(StdModuleLayer::PureData)
  }
  if normalized.has_suffix("/vibe/path/ref.vibe") {
    return Some(StdModuleLayer::RefModel)
  }
  if normalized.has_suffix("/vibe/prelude/io.vibe") ||
    normalized.has_suffix("/vibe/path/runtime.vibe") ||
    normalized.has_suffix("/vibe/path/index.vibe") ||
    normalized.has_suffix("/vibe/prelude/threads/runtime.vibe") ||
    normalized.has_suffix("/vibe/prelude/threads.vibe") {
    return Some(StdModuleLayer::EffectBoundary)
  }
  None
}

///|
fn std_layer_allows_import(
  source_layer : StdModuleLayer,
  imported_layer : StdModuleLayer,
) -> Bool {
  match source_layer {
    StdModuleLayer::TraitContract =>
      match imported_layer {
        StdModuleLayer::TraitContract => true
        _ => false
      }
    StdModuleLayer::PurePrimitive =>
      match imported_layer {
        StdModuleLayer::TraitContract | StdModuleLayer::PurePrimitive => true
        _ => false
      }
    StdModuleLayer::PureData =>
      match imported_layer {
        StdModuleLayer::TraitContract
        | StdModuleLayer::PurePrimitive
        | StdModuleLayer::PureData => true
        _ => false
      }
    StdModuleLayer::RefModel =>
      match imported_layer {
        StdModuleLayer::TraitContract
        | StdModuleLayer::PurePrimitive
        | StdModuleLayer::PureData
        | StdModuleLayer::RefModel => true
        _ => false
      }
    StdModuleLayer::EffectBoundary => true
  }
}

///|
fn std_collect_direct_import_paths(
  ast : @core.Module,
  base_dir : String,
) -> Array[String] {
  let imports : Array[String] = []
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::Import(source~, ..) | @core.Stmt::ReExport(source~, ..) =>
        match source {
          @core.ModuleRef::Path(path=raw_path) =>
            imports.push(@loader.resolve_import_path(base_dir, raw_path))
          _ => ()
        }
      _ => ()
    }
  }
  imports
}

///|
fn std_layering_violations_for_source(path : String, source : String) -> Array[String] {
  let source_layer = match std_layer_for_path(path) {
    Some(v) => v
    None => return []
  }
  let ast = @parser.parse_ast(source) catch { _ => return [] }
  let base_dir = @vibe_fs.parent_path(path)
  let imports = std_collect_direct_import_paths(ast, base_dir)
  let violations : Array[String] = []
  for import_path in imports {
    match std_layer_for_path(import_path) {
      Some(imported_layer) =>
        if not(std_layer_allows_import(source_layer, imported_layer)) {
          violations.push(
            "std layering violation: " +
            std_layer_name(source_layer) +
            " module " +
            path +
            " must not import " +
            std_layer_name(imported_layer) +
            " module " +
            import_path,
          )
        }
      None => ()
    }
  }
  violations
}

///|
fn push_layering_violation_diags(
  path : String,
  source : String,
  out : Array[@core.Diagnostic],
) -> Int {
  let violations = std_layering_violations_for_source(path, source)
  for msg in violations {
    out.push(@core.Diagnostic::{
      stage: "check",
      message: msg,
      span: None,
      hint: None,
      note: None,
    })
  }
  violations.length()
}

///|
fn check_ast_without_imports(
  ast : @core.Module,
) -> (Array[@core.Diagnostic], Int, Int) {
  let desugared = @frontend.desugar_method_calls(ast, {})
  let typed : Result[@checker.TypeEnv, @checker.TypeError] = try? @checker.type_check_with_aliases(
    desugared,
    {},
  )
  match typed {
    Ok(_) => {
      let warnings = @checker.collect_warnings(ast)
      (warnings, 0, warnings.length())
    }
    Err(err) => ([err.diagnostic()], 1, 0)
  }
}

///|
fn check_source(source : String) -> (Array[@core.Diagnostic], Int, Int) {
  let ast = @parser.parse_ast(source) catch {
    err => return ([err.diagnostic()], 1, 0)
  }
  check_ast_without_imports(ast)
}

///|
fn format_source(source : String) -> String {
  @parser.format_script(source)
}

///|
fn check_file(
  entry_path : String,
  fs : &@io.FileSystemAdapter,
) -> Result[(Array[@core.Diagnostic], Int, Int), String] {
  let resolved = @loader.resolve_entry_path_with_fs(entry_path, fs)
  let source = match @io.read_string_with(fs, resolved) {
    Ok(content) => content
    Err(err) => return Err("read failed: " + err)
  }
  let ast = @parser.parse_ast(source) catch {
    err => return Ok(([err.diagnostic()], 1, 0))
  }
  if not(has_import_stmt(ast)) {
    let (out, error_count, warning_count) = check_ast_without_imports(ast)
    let out2 : Array[@core.Diagnostic] = []
    for diag in out {
      out2.push(diag)
    }
    let layering_errors = push_layering_violation_diags(resolved, source, out2)
    return Ok((out2, error_count + layering_errors, warning_count))
  }
  let (db, entry) = match @loader.load_db_with_fs(entry_path, fs) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let _ = db.types(entry)
  let dep_imports = db.imports(entry)
  let diagnostics = db.diagnostics(entry)
  let warnings = db.warnings(entry)
  let out : Array[@core.Diagnostic] = []
  let mut dep_error_count = 0
  for imp in dep_imports {
    let dep_diags = db.diagnostics(imp.path)
    dep_error_count += dep_diags.length()
    for dep_diag in dep_diags {
      out.push(dep_diag)
    }
  }
  for diag in diagnostics {
    out.push(diag)
  }
  for warning in warnings {
    out.push(warning)
  }
  let layering_errors = push_layering_violation_diags(resolved, source, out)
  Ok((out, dep_error_count + diagnostics.length() + layering_errors, warnings.length()))
}

///|
fn format_file(
  entry_path : String,
  fs : &@io.FileSystemAdapter,
) -> Result[(String, String), String] {
  let resolved = @loader.resolve_entry_path_with_fs(entry_path, fs)
  let source = match @io.read_string_with(fs, resolved) {
    Ok(content) => content
    Err(err) => return Err("read failed: " + err)
  }
  Ok((source, format_source(source)))
}

///|
fn span_to_json(span : @core.Span?) -> Json {
  match span {
    Some(value) => {
      let obj : Map[String, Json] = {}
      obj["start"] = Json::number(value.start.to_double())
      obj["end"] = Json::number(value.end.to_double())
      Json::object(obj)
    }
    None => Json::null()
  }
}

///|
fn diagnostic_to_json(diag : @core.Diagnostic) -> Json {
  let obj : Map[String, Json] = {}
  obj["stage"] = Json::string(diag.stage)
  obj["message"] = Json::string(diag.message)
  obj["span"] = span_to_json(diag.span)
  match diag.hint {
    Some(hint) => obj["hint"] = Json::string(hint)
    None => ()
  }
  match diag.note {
    Some(note) => obj["note"] = Json::string(note)
    None => ()
  }
  Json::object(obj)
}

///|
fn annotate_diagnostic_with_path(
  diag : @core.Diagnostic,
  path : String,
) -> @core.Diagnostic {
  let path_note = "path: " + path
  let next_note = match diag.note {
    Some(note) => Some(path_note + "\n" + note)
    None => Some(path_note)
  }
  @core.Diagnostic::{
    stage: diag.stage,
    message: diag.message,
    span: diag.span,
    hint: diag.hint,
    note: next_note,
  }
}

///|
fn report_to_json(
  diagnostics : Array[@core.Diagnostic],
  error_count : Int,
  warning_count : Int,
  files : Array[CheckFileSummary],
) -> String {
  let diag_json : Array[Json] = []
  for diag in diagnostics {
    diag_json.push(diagnostic_to_json(diag))
  }
  let file_json : Array[Json] = []
  for file in files {
    let item : Map[String, Json] = {}
    item["path"] = Json::string(file.path)
    item["resolved_path"] = Json::string(file.resolved_path)
    match file.graph_head {
      Some(hash) => item["graph_head"] = Json::string(hash)
      None => item["graph_head"] = Json::null()
    }
    item["error_count"] = Json::number(file.error_count.to_double())
    item["warning_count"] = Json::number(file.warning_count.to_double())
    file_json.push(Json::object(item))
  }
  let root : Map[String, Json] = {}
  let parity : Map[String, Json] = {}
  parity["graph_head_available"] = Json::boolean(true)
  parity["human_readable_output"] = Json::boolean(false)
  parity["format_multi_file"] = Json::boolean(false)
  root["ok"] = Json::boolean(error_count == 0)
  root["error_count"] = Json::number(error_count.to_double())
  root["warning_count"] = Json::number(warning_count.to_double())
  root["diagnostics"] = Json::array(diag_json)
  root["files"] = Json::array(file_json)
  root["parity"] = Json::object(parity)
  Json::object(root).stringify()
}

///|
fn format_report_to_json(source : String, formatted : String) -> String {
  let root : Map[String, Json] = {}
  root["ok"] = Json::boolean(true)
  root["formatted"] = Json::string(formatted)
  root["changed"] = Json::boolean(source != formatted)
  Json::object(root).stringify()
}

///|
fn usage() -> Unit {
  println(
    "vibe_check_wasi [--check|--format] [--source <code> | --file <path> | <path>]",
  )
}

///|
fn main {
  let args = args_tail(@sys.get_cli_args(), 1)
  let options = match parse_cmd_args(args) {
    Ok(v) => v
    Err("help") => {
      usage()
      return
    }
    Err(err) => abort(err)
  }
  let fs = @io.default_fs_adapter()
  match options.mode {
    CommandMode::Check => {
      let (diagnostics, error_count, warning_count, files) = match options.input {
        CheckInput::Source(source) => {
          let (diagnostics, error_count, warning_count) = check_source(source)
          let empty_summaries : Array[CheckFileSummary] = []
          (diagnostics, error_count, warning_count, empty_summaries)
        }
        CheckInput::File(path) =>
          match check_file(path, fs) {
            Ok((diagnostics, error_count, warning_count)) => (
              diagnostics,
              error_count,
              warning_count,
              [CheckFileSummary::{
                path,
                resolved_path: @loader.resolve_entry_path_with_fs(path, fs),
                graph_head: @loader.resolve_entry_graph_head_with_fs(path, fs),
                error_count,
                warning_count,
              }],
            )
            Err(err) => abort("check: " + err)
          }
        CheckInput::Files(paths) => {
          let all_diags : Array[@core.Diagnostic] = []
          let summaries : Array[CheckFileSummary] = []
          let mut errors = 0
          let mut warnings = 0
          for path in paths {
            let resolved = @loader.resolve_entry_path_with_fs(path, fs)
            match check_file(path, fs) {
              Ok((diags, err_count, warn_count)) => {
                for diag in diags {
                  all_diags.push(annotate_diagnostic_with_path(diag, path))
                }
                summaries.push(CheckFileSummary::{
                  path,
                  resolved_path: resolved,
                  graph_head: @loader.resolve_entry_graph_head_with_fs(path, fs),
                  error_count: err_count,
                  warning_count: warn_count,
                })
                errors += err_count
                warnings += warn_count
              }
              Err(err) => {
                all_diags.push(@core.Diagnostic::{
                  stage: "check",
                  message: "check: " + path + ": " + err,
                  span: None,
                  hint: None,
                  note: None,
                })
                summaries.push(CheckFileSummary::{
                  path,
                  resolved_path: resolved,
                  graph_head: @loader.resolve_entry_graph_head_with_fs(path, fs),
                  error_count: 1,
                  warning_count: 0,
                })
                errors += 1
              }
            }
          }
          (all_diags, errors, warnings, summaries)
        }
      }
      println(report_to_json(diagnostics, error_count, warning_count, files))
    }
    CommandMode::Format => {
      let (source, formatted) = match options.input {
        CheckInput::Source(source) => (source, format_source(source))
        CheckInput::File(path) =>
          match format_file(path, fs) {
            Ok(value) => value
            Err(err) => abort("check: " + err)
          }
        CheckInput::Files(_) =>
          abort("check: --format expects exactly one file input")
      }
      println(format_report_to_json(source, formatted))
    }
  }
}
