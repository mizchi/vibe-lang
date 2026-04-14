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
  obj["severity"] = Json::string(diag.effective_severity().to_string())
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
  match diag.code {
    Some(code) => obj["code"] = Json::string(code)
    None => ()
  }
  Json::object(obj)
}

///|
fn check_report_json(source : String) -> String {
  let (diagnostics, error_count, warning_count) = check_source(source)
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
fn format_report_json(source : String) -> String {
  let formatted = @parser.format_script(source)
  let root : Map[String, Json] = {}
  root["ok"] = Json::boolean(true)
  root["formatted"] = Json::string(formatted)
  root["changed"] = Json::boolean(source != formatted)
  Json::object(root).stringify()
}

///|
fn response_error_json(message : String) -> String {
  let root : Map[String, Json] = {}
  root["ok"] = Json::boolean(false)
  root["error"] = Json::string(message)
  Json::object(root).stringify()
}

///|
fn response_diag_error_json(diag : @core.Diagnostic) -> String {
  let root : Map[String, Json] = {}
  root["ok"] = Json::boolean(false)
  root["error"] = Json::string(diag.message)
  root["diagnostics"] = Json::array([diagnostic_to_json(diag)])
  Json::object(root).stringify()
}

///|
fn check_project_report_json(request : String) -> String {
  let project = match parse_check_project_request(request) {
    Ok(value) => value
    Err(err) => return response_error_json(err)
  }
  let (diagnostics, error_count, warning_count) = check_project_input(project)
  let diag_json : Array[Json] = []
  for diag in diagnostics {
    diag_json.push(diagnostic_to_json(diag))
  }
  let root : Map[String, Json] = {}
  root["ok"] = Json::boolean(error_count == 0)
  root["error_count"] = Json::number(error_count.to_double())
  root["warning_count"] = Json::number(warning_count.to_double())
  root["diagnostics"] = Json::array(diag_json)
  root["entry"] = Json::string(project.entry)
  root["unsupported_imports"] = Json::boolean(false)
  Json::object(root).stringify()
}

///|
fn eval_value_type_name(value : @core.Value) -> String {
  match value {
    @core.Value::Int(_) => "Int"
    @core.Value::Float(_) => "Float"
    @core.Value::Double(_) => "Double"
    @core.Value::Bool(_) => "Bool"
    @core.Value::Char(_) => "Char"
    @core.Value::String(_) => "String"
    @core.Value::Path(_) => "Path"
    @core.Value::Unit => "Unit"
    @core.Value::Tuple(_) => "Tuple"
    @core.Value::Record(_) => "Record"
    @core.Value::Array(_) => "Array"
    @core.Value::Map(_) => "Map"
    @core.Value::Set(_) => "Set"
    @core.Value::Fn(_) => "Fn"
    @core.Value::ArrayBuilder(_) => "ArrayBuilder"
    @core.Value::MapBuilder(_) => "MapBuilder"
    @core.Value::StringBuilder(_) => "StringBuilder"
    @core.Value::Bytes(_) => "Bytes"
    @core.Value::PromptText(_) => "PromptText"
    @core.Value::Continuation(_) => "Continuation"
  }
}

///|
let eval_runtime_ref : Ref[@runtime.Runtime?] = @ref.new(None)

///|
let eval_hooks_ready : Ref[Bool] = @ref.new(false)

///|
fn ensure_eval_runtime_hooks() -> Unit {
  if eval_hooks_ready.val {
    return
  }
  eval_hooks_ready.val = true
  @runtime.set_parse_ast_hook(fn(
    source,
  ) -> (@core.Module, @core.Diagnostic?) raise Error {
    let ast = @parser.parse_ast(source) catch {
      e => return ({ stmts: [] }, Some(e.diagnostic()))
    }
    (ast, None)
  })
  @runtime.set_parse_cst_hook(@parser.parse_cst)
  @runtime.set_purity_for_let_hook(@checker.purity_for_let)
  @runtime.set_new_type_env_hook(fn() { @checker.TypeEnv::new() })
  @runtime.set_get_prelude_env_hook(fn() {
    try! @checker.get_prelude_only_env_for_module()
  })
  @runtime.set_type_check_with_env_hook(@checker.type_check_with_env)
  @runtime.mark_compiler_hooks_initialized()
  @runtime.set_init_runtime_type_env_hook(fn() {
    let env = @checker.TypeEnv::new()
    let _ = try! @checker.ensure_prelude_option(env)
    let _ = try! @checker.ensure_prelude_functions(env, {})
    @checker.ensure_builtin_modules(env, {})
    env
  })
  @runtime.set_prelude_ast_hook(@checker.prelude_ast)
  @runtime.set_collect_warnings_hook(@checker.collect_warnings)
}

///|
fn get_or_create_eval_runtime() -> @runtime.Runtime {
  ensure_eval_runtime_hooks()
  match eval_runtime_ref.val {
    Some(rt) => rt
    None => {
      let caps = @capability.CapabilitySet::new()
      let rt = @runtime.Runtime::new(caps)
      eval_runtime_ref.val = Some(rt)
      rt
    }
  }
}

///|
fn eval_report_json(request : String) -> String {
  let obj = match parse_request_object(request) {
    Ok(obj) => obj
    Err(err) => return response_error_json(err)
  }
  let source = match json_string_field(obj, "source") {
    Ok(s) => s
    Err(err) => return response_error_json(err)
  }
  let ast = @parser.parse_ast(source) catch {
    err => return response_diag_error_json(err.diagnostic())
  }
  let desugared = @frontend.rewrite_effect_handles(
    @frontend.desugar_method_calls(ast, {}),
  )
  let rt = get_or_create_eval_runtime()
  let eval_result = try? rt.eval_module(desugared)
  let result = match eval_result {
    Err(err) => {
      let root : Map[String, Json] = {}
      root["ok"] = Json::boolean(false)
      root["diagnostics"] = Json::array([
        diagnostic_to_json(@core.Diagnostic::{
          stage: "eval",
          message: err.to_string(),
          span: None,
          hint: None,
          note: None,
          severity: None,
          code: None,
        }),
      ])
      return Json::object(root).stringify()
    }
    Ok(r) => r
  }
  let root : Map[String, Json] = {}
  root["ok"] = Json::boolean(true)
  match result.last {
    Some(value) => {
      root["value"] = Json::string(value.to_string())
      root["value_type"] = Json::string(eval_value_type_name(value))
    }
    None => {
      root["value"] = Json::null()
      root["value_type"] = Json::string("Unit")
    }
  }
  root["diagnostics"] = Json::array([])
  Json::object(root).stringify()
}

///|
fn eval_reset_report_json(request : String) -> String {
  let _ = request
  eval_runtime_ref.val = None
  let root : Map[String, Json] = {}
  root["ok"] = Json::boolean(true)
  Json::object(root).stringify()
}
