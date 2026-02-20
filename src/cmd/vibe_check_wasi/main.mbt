///|
pub enum CheckInput {
  Source(String)
  File(String)
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
  let mut file : String? = None
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
        if file is Some(_) {
          return Err("check: file input specified multiple times")
        }
        file = Some(args[i])
      }
      "-h" | "--help" => return Err("help")
      _ =>
        if file is None {
          file = Some(arg)
        } else {
          return Err("check: too many input files")
        }
    }
    i += 1
  }
  if mode_flag_count > 1 {
    return Err("check: choose either --check or --format")
  }
  match (source, file) {
    (Some(src), None) => Ok({ mode, input: CheckInput::Source(src) })
    (None, Some(path)) => Ok({ mode, input: CheckInput::File(path) })
    (None, None) => Err("check: expected --source <code> or <file>")
    (Some(_), Some(_)) => Err("check: --source and file input are exclusive")
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
    return Ok(check_ast_without_imports(ast))
  }
  let (db, entry) = match @loader.load_db_with_fs(entry_path, fs) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let _ = db.types(entry)
  let diagnostics = db.diagnostics(entry)
  let warnings = db.warnings(entry)
  let out : Array[@core.Diagnostic] = []
  for diag in diagnostics {
    out.push(diag)
  }
  for warning in warnings {
    out.push(warning)
  }
  Ok((out, diagnostics.length(), warnings.length()))
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
fn report_to_json(
  diagnostics : Array[@core.Diagnostic],
  error_count : Int,
  warning_count : Int,
) -> String {
  let diag_json : Array[Json] = []
  for diag in diagnostics {
    diag_json.push(diagnostic_to_json(diag))
  }
  let root : Map[String, Json] = {}
  root["ok"] = Json::boolean(error_count == 0)
  root["error_count"] = Json::number(error_count.to_double())
  root["warning_count"] = Json::number(warning_count.to_double())
  root["diagnostics"] = Json::array(diag_json)
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
      let (diagnostics, error_count, warning_count) = match options.input {
        CheckInput::Source(source) => check_source(source)
        CheckInput::File(path) =>
          match check_file(path, fs) {
            Ok(v) => v
            Err(err) => abort("check: " + err)
          }
      }
      println(report_to_json(diagnostics, error_count, warning_count))
    }
    CommandMode::Format => {
      let (source, formatted) = match options.input {
        CheckInput::Source(source) => (source, format_source(source))
        CheckInput::File(path) =>
          match format_file(path, fs) {
            Ok(value) => value
            Err(err) => abort("check: " + err)
          }
      }
      println(format_report_to_json(source, formatted))
    }
  }
}
