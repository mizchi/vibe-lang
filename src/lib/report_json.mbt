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
