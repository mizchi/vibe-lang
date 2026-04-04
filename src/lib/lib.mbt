///|
extern "wasm" fn wasm_load8_u(offset : Int) -> Int =
  #|(func (param i32) (result i32) local.get 0 i32.load8_u)

///|
extern "wasm" fn wasm_store8(offset : Int, value : Int) =
  #|(func (param i32) (param i32) local.get 0 local.get 1 i32.store8)

///|
priv struct ProjectInput {
  entry : String
  files : Map[String, String]
}

///|
priv struct ModuleAnalysis {
  ast : @core.Module
  env : @checker.TypeEnv
  exports : Map[String, @core.Stmt]
  diagnostics : Array[@core.Diagnostic]
  warnings : Array[@core.Diagnostic]
}

///|
priv struct InitState {
  prelude : String?
  kv : Map[String, String]
}

///|
fn empty_init_state() -> InitState {
  InitState::{ prelude: None, kv: {} }
}

///|
let init_state_ref : Ref[InitState] = @ref.new(empty_init_state())

///|
fn clone_string_map(src : Map[String, String]) -> Map[String, String] {
  let out : Map[String, String] = {}
  for key, value in src {
    out[key] = value
  }
  out
}

///|
fn current_init_state() -> InitState {
  let current = init_state_ref.val
  InitState::{ prelude: current.prelude, kv: clone_string_map(current.kv) }
}

///|
fn replace_init_state(next_state : InitState) -> Unit {
  init_state_ref.val = InitState::{
    prelude: next_state.prelude,
    kv: clone_string_map(next_state.kv),
  }
}

///|
fn merge_init_kv_files(files : Map[String, String]) -> Map[String, String] {
  let init_state = current_init_state()
  let out = clone_string_map(init_state.kv)
  for path, source in files {
    out[path] = source
  }
  out
}

///|
fn entry_not_found_diagnostic(entry : String) -> @core.Diagnostic {
  @core.Diagnostic::{
    stage: "type",
    message: "entry not found in files: " + entry,
    span: None,
    hint: None,
    note: Some("check your import statements for entry '" + entry + "'"),
    severity: None,
    code: None,
  }
}

///|
fn path_not_found_diagnostic(path : String) -> @core.Diagnostic {
  @core.Diagnostic::{
    stage: "type",
    message: "path not found in files: " + path,
    span: None,
    hint: None,
    note: Some("referenced path: " + path),
    severity: None,
    code: None,
  }
}

///|
fn missing_import_diagnostic(
  from_path : String,
  import_path : String,
  span : @core.Span,
) -> @core.Diagnostic {
  @core.Diagnostic::{
    stage: "import",
    message: "missing import source: " + import_path,
    span: Some(span),
    hint: None,
    note: Some("from: " + from_path),
    severity: None,
    code: None,
  }
}

///|
fn missing_export_diagnostic(
  import_path : String,
  export_name : String,
  span : @core.Span,
) -> @core.Diagnostic {
  @core.Diagnostic::{
    stage: "import",
    message: "missing export: " + export_name,
    span: Some(span),
    hint: None,
    note: Some("import source: " + import_path),
    severity: None,
    code: None,
  }
}

///|
fn unsupported_import_ref_diagnostic(span : @core.Span) -> @core.Diagnostic {
  @core.Diagnostic::{
    stage: "import",
    message: "only path import is supported in wasm library mode",
    span: Some(span),
    hint: None,
    note: None,
    severity: None,
    code: None,
  }
}

///|
fn import_cycle_diagnostic(path : String) -> @core.Diagnostic {
  @core.Diagnostic::{
    stage: "import",
    message: "import cycle detected: " + path,
    span: None,
    hint: Some("break the cycle by removing or reorganizing imports"),
    note: Some("cycle involves module: " + path),
    severity: None,
    code: None,
  }
}

///|
fn project_paths(entry : String, files : Map[String, String]) -> Array[String] {
  let out : Array[String] = [entry]
  for path, _ in files {
    if path != entry {
      out.push(path)
    }
  }
  out
}

///|
fn resolve_import_path(base_path : String, import_path : String) -> String {
  if import_path.has_prefix("/") {
    @vibe_fs.normalize_path(import_path)
  } else {
    let base_dir = @vibe_fs.parent_path(base_path)
    let merged = if base_dir == "." || base_dir == "" {
      import_path
    } else {
      base_dir + "/" + import_path
    }
    @vibe_fs.normalize_path(merged)
  }
}

///|
fn resolve_import_source_path(
  files : Map[String, String],
  base_path : String,
  import_path : String,
) -> String? {
  let normalized = resolve_import_path(base_path, import_path)
  if files.contains(normalized) {
    Some(normalized)
  } else if files.contains(import_path) {
    Some(import_path)
  } else {
    None
  }
}

///|
fn supports_module_namespace_import(path : String) -> Bool {
  path.has_suffix(".xm")
}

///|
fn empty_module_analysis(diags : Array[@core.Diagnostic]) -> ModuleAnalysis {
  ModuleAnalysis::{
    ast: { stmts: [] },
    env: @checker.TypeEnv::new(),
    exports: {},
    diagnostics: diags,
    warnings: [],
  }
}

///|
fn apply_injected_prelude_to_env(env : @checker.TypeEnv) -> @checker.TypeEnv {
  let init_state = current_init_state()
  match init_state.prelude {
    Some(source) =>
      if source.trim() == "" {
        env
      } else {
        let ast = @parser.parse_ast(source) catch { _ => return env }
        let aliases : Map[String, @core.Ref] = {}
        @checker.type_check_with_env(env, ast, aliases) catch {
          _ => env
        }
      }
    None => env
  }
}

///|
fn prelude_env_or_empty() -> @checker.TypeEnv {
  let base = @checker.get_cached_prelude_env_for_module() catch {
    _ => @checker.TypeEnv::new()
  }
  apply_injected_prelude_to_env(base)
}

///|
fn prelude_only_env_or_empty() -> @checker.TypeEnv {
  let base = @checker.get_prelude_only_env_for_module() catch {
    _ => @checker.TypeEnv::new()
  }
  apply_injected_prelude_to_env(base)
}

///|
fn is_builtin_module_path(path : String) -> Bool {
  path.contains("/vibe/prelude/") && not(path.has_suffix("_test.vibe"))
}

///|
fn analyze_module(
  module_path : String,
  files : Map[String, String],
  cache : Map[String, ModuleAnalysis],
  visiting : Map[String, Bool],
) -> ModuleAnalysis {
  match cache.get(module_path) {
    Some(info) => return info
    None => ()
  }
  match visiting.get(module_path) {
    Some(true) => {
      let cycle_diag = import_cycle_diagnostic(module_path)
      let info = empty_module_analysis([cycle_diag])
      cache[module_path] = info
      return info
    }
    _ => ()
  }
  let source = match files.get(module_path) {
    Some(value) => value
    None => {
      let info = empty_module_analysis([path_not_found_diagnostic(module_path)])
      cache[module_path] = info
      return info
    }
  }
  let ast = @parser.parse_ast(source) catch {
    err => {
      let info = empty_module_analysis([err.diagnostic()])
      cache[module_path] = info
      return info
    }
  }
  visiting[module_path] = true
  let aliases : Map[String, @core.Ref] = {}
  let env = if is_builtin_module_path(module_path) {
    prelude_only_env_or_empty()
  } else {
    prelude_env_or_empty()
  }
  let local_diags : Array[@core.Diagnostic] = []
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::Import(spec~, source~, span~) =>
        match source {
          @core.ModuleRef::Path(path~) => {
            let raw_import_path = path
            let import_alias = @core.import_alias_name(raw_import_path)
            let resolved_path = match
              resolve_import_source_path(files, module_path, raw_import_path) {
              Some(value) => value
              None => {
                local_diags.push(
                  missing_import_diagnostic(module_path, raw_import_path, span),
                )
                continue
              }
            }
            aliases[import_alias] = @core.Ref::{
              name: resolved_path,
              hash_prefix: None,
            }
            let imported = analyze_module(resolved_path, files, cache, visiting)
            let module_namespace_ok = supports_module_namespace_import(
              resolved_path,
            )
            for item in spec.items {
              let source_name = item.name
              let target_name = match item.rename {
                Some(name) => name
                None => source_name
              }
              match item.kind {
                @core.ImportKind::Module => {
                  if not(module_namespace_ok) {
                    local_diags.push(@core.Diagnostic::{
                      stage: "import",
                      message: "module import is only supported for .xm source: " +
                      resolved_path,
                      span: Some(span),
                      hint: Some(
                        "import from `.xm` for multi-module files, or import explicit exported symbols from `.vibe`",
                      ),
                      note: None,
                      severity: None,
                      code: None,
                    })
                    continue
                  }
                  let source_prefix = source_name + "::"
                  let local_ns = match item.rename {
                    Some(rename_name) => rename_name
                    None => source_name
                  }
                  let target_prefix = local_ns + "::"
                  let mut imported_any = false
                  for exported_name, _ in imported.exports {
                    if exported_name.has_prefix(source_prefix) {
                      let suffix = exported_name.unsafe_substring(
                        start=source_prefix.length(),
                        end=exported_name.length(),
                      )
                      let target_name = target_prefix + suffix
                      match imported.env.get_scheme(exported_name) {
                        Some(scheme) => {
                          env.set_scheme(target_name, scheme)
                          imported_any = true
                        }
                        None => ()
                      }
                    }
                  }
                  if not(imported_any) {
                    local_diags.push(
                      missing_export_diagnostic(
                        resolved_path, source_name, span,
                      ),
                    )
                  }
                }
                @core.ImportKind::Value => {
                  if not(imported.exports.contains(source_name)) {
                    local_diags.push(
                      missing_export_diagnostic(
                        resolved_path, source_name, span,
                      ),
                    )
                    continue
                  }
                  match imported.env.get_scheme(source_name) {
                    Some(scheme) => env.set_scheme(target_name, scheme)
                    None =>
                      local_diags.push(
                        missing_export_diagnostic(
                          resolved_path, source_name, span,
                        ),
                      )
                  }
                }
                @core.ImportKind::Type => {
                  if not(imported.exports.contains(source_name)) {
                    local_diags.push(
                      missing_export_diagnostic(
                        resolved_path, source_name, span,
                      ),
                    )
                    continue
                  }
                  let mut imported_any = false
                  match imported.env.get_type_alias(source_name) {
                    Some(type_alias_entry) => {
                      env.set_type_alias(target_name, type_alias_entry)
                      imported_any = true
                    }
                    None => ()
                  }
                  match imported.env.get_enum_def(source_name) {
                    Some(enum_def) => {
                      env.set_enum_def(target_name, enum_def)
                      imported_any = true
                    }
                    None => ()
                  }
                  match imported.env.get_struct(source_name) {
                    Some(struct_def) => {
                      env.set_struct(target_name, struct_def)
                      imported_any = true
                    }
                    None => ()
                  }
                  if not(imported_any) {
                    local_diags.push(
                      missing_export_diagnostic(
                        resolved_path, source_name, span,
                      ),
                    )
                  }
                }
                @core.ImportKind::Trait => {
                  if not(imported.exports.contains(source_name)) {
                    local_diags.push(
                      missing_export_diagnostic(
                        resolved_path, source_name, span,
                      ),
                    )
                    continue
                  }
                  match imported.env.get_trait_info(source_name) {
                    Some(trait_info) =>
                      env.set_trait_info(target_name, trait_info)
                    None =>
                      local_diags.push(
                        missing_export_diagnostic(
                          resolved_path, source_name, span,
                        ),
                      )
                  }
                }
                @core.ImportKind::Struct => {
                  if not(imported.exports.contains(source_name)) {
                    local_diags.push(
                      missing_export_diagnostic(
                        resolved_path, source_name, span,
                      ),
                    )
                    continue
                  }
                  match imported.env.get_struct(source_name) {
                    Some(struct_def) => env.set_struct(target_name, struct_def)
                    None =>
                      local_diags.push(
                        missing_export_diagnostic(
                          resolved_path, source_name, span,
                        ),
                      )
                  }
                }
                @core.ImportKind::Effect | @core.ImportKind::Suberror => {
                  if not(imported.exports.contains(source_name)) {
                    local_diags.push(
                      missing_export_diagnostic(
                        resolved_path, source_name, span,
                      ),
                    )
                    continue
                  }
                  match imported.env.get_scheme(source_name) {
                    Some(scheme) => env.set_scheme(target_name, scheme)
                    None =>
                      local_diags.push(
                        missing_export_diagnostic(
                          resolved_path, source_name, span,
                        ),
                      )
                  }
                }
              }
            }
          }
          _ => local_diags.push(unsupported_import_ref_diagnostic(span))
        }
      _ => ()
    }
  }
  let desugared = @frontend.rewrite_effect_handles(
    @frontend.desugar_method_calls(ast, aliases),
  )
  let typed_env = @checker.type_check_with_env(env, desugared, aliases) catch {
    err => {
      local_diags.push(err.diagnostic())
      env
    }
  }
  let warnings = @checker.collect_warnings(ast)
  let info = ModuleAnalysis::{
    ast,
    env: typed_env,
    exports: @core.extract_exports(ast),
    diagnostics: local_diags,
    warnings,
  }
  cache[module_path] = info
  visiting[module_path] = false
  info
}

///|
fn analyze_project(
  project : ProjectInput,
) -> (Map[String, ModuleAnalysis], Array[String]) {
  let paths = project_paths(project.entry, project.files)
  let cache : Map[String, ModuleAnalysis] = {}
  let visiting : Map[String, Bool] = {}
  for path in paths {
    let _ = analyze_module(path, project.files, cache, visiting)
  }
  (cache, paths)
}

///|
fn collect_project_report(
  analyses : Map[String, ModuleAnalysis],
  paths : Array[String],
) -> (Array[@core.Diagnostic], Int, Int) {
  let errors : Array[@core.Diagnostic] = []
  let warnings : Array[@core.Diagnostic] = []
  for path in paths {
    match analyses.get(path) {
      Some(info) => {
        for diag in info.diagnostics {
          errors.push(diag)
        }
        for warning in info.warnings {
          warnings.push(warning)
        }
      }
      None => errors.push(path_not_found_diagnostic(path))
    }
  }
  let all_diags : Array[@core.Diagnostic] = []
  for diag in errors {
    all_diags.push(diag)
  }
  for warning in warnings {
    all_diags.push(warning)
  }
  (all_diags, errors.length(), warnings.length())
}

///|
fn first_project_error(
  analyses : Map[String, ModuleAnalysis],
  paths : Array[String],
  preferred_path : String,
) -> @core.Diagnostic? {
  match analyses.get(preferred_path) {
    Some(info) =>
      if info.diagnostics.length() > 0 {
        return Some(info.diagnostics[0])
      }
    None => return Some(path_not_found_diagnostic(preferred_path))
  }
  for path in paths {
    if path == preferred_path {
      continue
    }
    match analyses.get(path) {
      Some(info) =>
        if info.diagnostics.length() > 0 {
          return Some(info.diagnostics[0])
        }
      None => return Some(path_not_found_diagnostic(path))
    }
  }
  None
}

///|
fn check_project_input(
  project : ProjectInput,
) -> (Array[@core.Diagnostic], Int, Int) {
  if not(project.files.contains(project.entry)) {
    let diag = entry_not_found_diagnostic(project.entry)
    return ([diag], 1, 0)
  }
  let (analyses, paths) = analyze_project(project)
  collect_project_report(analyses, paths)
}

///|
fn check_source(source : String) -> (Array[@core.Diagnostic], Int, Int) {
  let entry = "<input>"
  let files : Map[String, String] = {}
  files[entry] = source
  let merged_files = merge_init_kv_files(files)
  check_project_input(ProjectInput::{ entry, files: merged_files })
}

///|
fn parse_request_object(request : String) -> Result[Map[String, Json], String] {
  let parsed : Json = @json.parse(request) catch {
    _ => return Err("invalid request json")
  }
  match parsed {
    Json::Object(obj) => Ok(obj)
    _ => Err("request must be json object")
  }
}

///|
fn json_optional_string_field(
  obj : Map[String, Json],
  name : String,
) -> Result[String?, String] {
  match obj.get(name) {
    Some(Json::String(value)) => Ok(Some(value))
    Some(_) => Err("field `" + name + "` must be string")
    None => Ok(None)
  }
}

///|
fn json_files_field(
  obj : Map[String, Json],
) -> Result[Map[String, String]?, String] {
  match obj.get("files") {
    None => Ok(None)
    Some(Json::Object(raw)) => {
      let out : Map[String, String] = {}
      for path, value in raw {
        match value {
          Json::String(source) => out[path] = source
          _ => return Err("field `files` must be object<string, string>")
        }
      }
      Ok(Some(out))
    }
    Some(_) => Err("field `files` must be object")
  }
}

///|
fn json_kv_field(
  obj : Map[String, Json],
) -> Result[Map[String, String]?, String] {
  match obj.get("kv") {
    None => Ok(None)
    Some(Json::Object(raw)) => {
      let out : Map[String, String] = {}
      for key, value in raw {
        match value {
          Json::String(raw_value) => out[key] = raw_value
          _ => return Err("field `kv` must be object<string, string>")
        }
      }
      Ok(Some(out))
    }
    Some(_) => Err("field `kv` must be object")
  }
}

///|
fn json_string_field(
  obj : Map[String, Json],
  name : String,
) -> Result[String, String] {
  match obj.get(name) {
    Some(Json::String(value)) => Ok(value)
    Some(_) => Err("field `" + name + "` must be string")
    None => Err("missing field: " + name)
  }
}

///|
fn parse_project_input_from_object(
  obj : Map[String, Json],
) -> Result[ProjectInput, String] {
  let files_opt = match json_files_field(obj) {
    Ok(value) => value
    Err(err) => return Err(err)
  }
  match files_opt {
    Some(files) => {
      let entry = match json_string_field(obj, "entry") {
        Ok(value) => value
        Err(err) => return Err(err)
      }
      let merged_files = merge_init_kv_files(files)
      if not(merged_files.contains(entry)) {
        return Err("entry not found in files: " + entry)
      }
      Ok(ProjectInput::{ entry, files: merged_files })
    }
    None => {
      let source = match json_string_field(obj, "source") {
        Ok(value) => value
        Err(err) => return Err(err)
      }
      let path = match json_optional_string_field(obj, "path") {
        Ok(Some(value)) => value
        Ok(None) => "<input>"
        Err(err) => return Err(err)
      }
      let files : Map[String, String] = {}
      files[path] = source
      let merged_files = merge_init_kv_files(files)
      Ok(ProjectInput::{ entry: path, files: merged_files })
    }
  }
}

///|
fn parse_ide_outline_request(
  request : String,
) -> Result[(ProjectInput, String), String] {
  let obj = match parse_request_object(request) {
    Ok(value) => value
    Err(err) => return Err(err)
  }
  let project = match parse_project_input_from_object(obj) {
    Ok(value) => value
    Err(err) => return Err(err)
  }
  let path = match json_optional_string_field(obj, "path") {
    Ok(Some(value)) => value
    Ok(None) => project.entry
    Err(err) => return Err(err)
  }
  if not(project.files.contains(path)) {
    return Err("path not found in files: " + path)
  }
  Ok((project, path))
}

///|
fn parse_ide_symbol_request(
  request : String,
  key : String,
) -> Result[(ProjectInput, String, String), String] {
  let obj = match parse_request_object(request) {
    Ok(value) => value
    Err(err) => return Err(err)
  }
  let project = match parse_project_input_from_object(obj) {
    Ok(value) => value
    Err(err) => return Err(err)
  }
  let value = match json_string_field(obj, key) {
    Ok(result) => result
    Err(err) => return Err(err)
  }
  let path = match json_optional_string_field(obj, "path") {
    Ok(Some(value)) => value
    Ok(None) => project.entry
    Err(err) => return Err(err)
  }
  if not(project.files.contains(path)) {
    return Err("path not found in files: " + path)
  }
  Ok((project, path, value))
}

///|
fn parse_check_project_request(
  request : String,
) -> Result[ProjectInput, String] {
  let obj = match parse_request_object(request) {
    Ok(value) => value
    Err(err) => return Err(err)
  }
  parse_project_input_from_object(obj)
}

///|
fn validate_injected_prelude(source : String) -> Result[Unit, String] {
  if source.trim() == "" {
    return Ok(())
  }
  let ast = @parser.parse_ast(source) catch {
    err =>
      return Err("field `prelude` parse error: " + err.diagnostic().message)
  }
  let env = @checker.get_cached_prelude_env_for_module() catch {
    _ => @checker.TypeEnv::new()
  }
  let aliases : Map[String, @core.Ref] = {}
  let _ = @checker.type_check_with_env(env, ast, aliases) catch {
    err => return Err("field `prelude` type error: " + err.diagnostic().message)
  }
  Ok(())
}

///|
fn parse_init_state_request(request : String) -> Result[InitState, String] {
  let obj = match parse_request_object(request) {
    Ok(value) => value
    Err(err) => return Err(err)
  }
  let prelude_raw = match json_optional_string_field(obj, "prelude") {
    Ok(value) => value
    Err(err) => return Err(err)
  }
  let prelude = match prelude_raw {
    Some(source) => if source.trim() == "" { None } else { Some(source) }
    None => None
  }
  let kv_opt = match json_kv_field(obj) {
    Ok(value) => value
    Err(err) => return Err(err)
  }
  let kv = match kv_opt {
    Some(value) => value
    None => {}
  }
  match prelude {
    Some(source) =>
      match validate_injected_prelude(source) {
        Ok(_) => ()
        Err(err) => return Err(err)
      }
    None => ()
  }
  Ok(InitState::{ prelude, kv })
}

///|
fn init_state_report_json(request : String) -> String {
  let next_state = match parse_init_state_request(request) {
    Ok(value) => value
    Err(err) => return response_error_json(err)
  }
  replace_init_state(next_state)
  let current = current_init_state()
  let root : Map[String, Json] = {}
  root["ok"] = Json::boolean(true)
  root["prelude"] = Json::boolean(current.prelude is Some(_))
  root["kv_count"] = Json::number(current.kv.length().to_double())
  Json::object(root).stringify()
}

///|
fn symbol_line_col(source : String?, span : @core.Span) -> (Int, Int) {
  match source {
    Some(value) => {
      let (pos, _, _) = @core.line_info(value, span.start)
      (pos.line, pos.column)
    }
    None => (0, 0)
  }
}

///|
fn symbol_line_text(source : String?, span : @core.Span) -> String {
  match source {
    Some(value) => {
      let (_, line_start, line_end) = @core.line_info(value, span.start)
      try value[line_start:line_end] catch {
        _ => ""
      } noraise {
        s => s.to_string()
      }
    }
    None => ""
  }
}

///|
fn symbol_entry_to_json(
  entry : @frontend.SymbolEntry,
  files : Map[String, String],
) -> Json {
  let source = files.get(entry.path)
  let (line, column) = symbol_line_col(source, entry.span)
  let obj : Map[String, Json] = {}
  obj["name"] = Json::string(entry.name)
  obj["kind"] = Json::string(@frontend.symbol_kind_name(entry.kind))
  obj["signature"] = Json::string(entry.signature)
  obj["path"] = Json::string(entry.path)
  obj["span"] = span_to_json(Some(entry.span))
  obj["line"] = Json::number(line.to_double())
  obj["column"] = Json::number(column.to_double())
  obj["line_text"] = Json::string(symbol_line_text(source, entry.span))
  Json::object(obj)
}

///|
fn build_symbol_index_for_paths(
  analyses : Map[String, ModuleAnalysis],
  paths : Array[String],
) -> @frontend.SymbolIndex {
  let entries : Array[@frontend.SymbolEntry] = []
  for path in paths {
    match analyses.get(path) {
      Some(info) => {
        let index = @frontend.build_symbol_index_for_module(
          path,
          info.ast,
          info.env,
        )
        for entry in index.entries {
          entries.push(entry)
        }
      }
      None => ()
    }
  }
  @frontend.build_symbol_index_from_entries(entries)
}

///|
fn ide_outline_report_json(request : String) -> String {
  let (project, path) = match parse_ide_outline_request(request) {
    Ok(value) => value
    Err(err) => return response_error_json(err)
  }
  if not(project.files.contains(path)) {
    return response_diag_error_json(path_not_found_diagnostic(path))
  }
  let (analyses, paths) = analyze_project(project)
  match first_project_error(analyses, paths, path) {
    Some(diag) => return response_diag_error_json(diag)
    None => ()
  }
  let info = match analyses.get(path) {
    Some(value) => value
    None => return response_diag_error_json(path_not_found_diagnostic(path))
  }
  let index = @frontend.build_symbol_index_for_module(path, info.ast, info.env)
  let symbols : Array[Json] = []
  for entry in index.entries {
    symbols.push(symbol_entry_to_json(entry, project.files))
  }
  let root : Map[String, Json] = {}
  root["ok"] = Json::boolean(true)
  root["path"] = Json::string(path)
  root["symbols"] = Json::array(symbols)
  Json::object(root).stringify()
}

///|
fn ide_peek_def_report_json(request : String) -> String {
  let (project, path, symbol) = match
    parse_ide_symbol_request(request, "symbol") {
    Ok(value) => value
    Err(err) => return response_error_json(err)
  }
  if not(project.files.contains(path)) {
    return response_diag_error_json(path_not_found_diagnostic(path))
  }
  let (analyses, paths) = analyze_project(project)
  match first_project_error(analyses, paths, path) {
    Some(diag) => return response_diag_error_json(diag)
    None => ()
  }
  let index = build_symbol_index_for_paths(analyses, paths)
  let matches = index.find_exact(symbol)
  let out : Array[Json] = []
  for entry in matches {
    out.push(symbol_entry_to_json(entry, project.files))
  }
  let root : Map[String, Json] = {}
  root["ok"] = Json::boolean(true)
  root["path"] = Json::string(path)
  root["symbol"] = Json::string(symbol)
  root["matches"] = Json::array(out)
  Json::object(root).stringify()
}

///|
fn ide_search_report_json(request : String) -> String {
  let (project, path, query) = match
    parse_ide_symbol_request(request, "query") {
    Ok(value) => value
    Err(err) => return response_error_json(err)
  }
  if not(project.files.contains(path)) {
    return response_diag_error_json(path_not_found_diagnostic(path))
  }
  let (analyses, paths) = analyze_project(project)
  match first_project_error(analyses, paths, path) {
    Some(diag) => return response_diag_error_json(diag)
    None => ()
  }
  let index = build_symbol_index_for_paths(analyses, paths)
  let matches = index.search(query)
  let out : Array[Json] = []
  for entry in matches {
    out.push(symbol_entry_to_json(entry, project.files))
  }
  let root : Map[String, Json] = {}
  root["ok"] = Json::boolean(true)
  root["path"] = Json::string(path)
  root["query"] = Json::string(query)
  root["matches"] = Json::array(out)
  Json::object(root).stringify()
}

///|
fn decode_utf8_from_memory(ptr : Int, len : Int) -> String? {
  if len < 0 || ptr < 0 {
    return None
  }
  let out = StringBuilder::new()
  let mut i = 0
  while i < len {
    let b0 = wasm_load8_u(ptr + i)
    if b0 < 0x80 {
      match Int::to_char(b0) {
        Some(ch) => out.write_char(ch)
        None => return None
      }
      i += 1
      continue
    }
    if (b0 & 0xe0) == 0xc0 {
      if i + 1 >= len {
        return None
      }
      let b1 = wasm_load8_u(ptr + i + 1)
      if (b1 & 0xc0) != 0x80 {
        return None
      }
      let code = ((b0 & 0x1f) << 6) | (b1 & 0x3f)
      match Int::to_char(code) {
        Some(ch) => out.write_char(ch)
        None => return None
      }
      i += 2
      continue
    }
    if (b0 & 0xf0) == 0xe0 {
      if i + 2 >= len {
        return None
      }
      let b1 = wasm_load8_u(ptr + i + 1)
      let b2 = wasm_load8_u(ptr + i + 2)
      if (b1 & 0xc0) != 0x80 || (b2 & 0xc0) != 0x80 {
        return None
      }
      let code = ((b0 & 0x0f) << 12) | ((b1 & 0x3f) << 6) | (b2 & 0x3f)
      match Int::to_char(code) {
        Some(ch) => out.write_char(ch)
        None => return None
      }
      i += 3
      continue
    }
    if (b0 & 0xf8) == 0xf0 {
      if i + 3 >= len {
        return None
      }
      let b1 = wasm_load8_u(ptr + i + 1)
      let b2 = wasm_load8_u(ptr + i + 2)
      let b3 = wasm_load8_u(ptr + i + 3)
      if (b1 & 0xc0) != 0x80 || (b2 & 0xc0) != 0x80 || (b3 & 0xc0) != 0x80 {
        return None
      }
      let code = ((b0 & 0x07) << 18) |
        ((b1 & 0x3f) << 12) |
        ((b2 & 0x3f) << 6) |
        (b3 & 0x3f)
      match Int::to_char(code) {
        Some(ch) => out.write_char(ch)
        None => return None
      }
      i += 4
      continue
    }
    return None
  }
  Some(out.to_string())
}

///|
fn write_utf8_to_memory(ptr : Int, cap : Int, text : String) -> Int {
  if ptr < 0 || cap < 0 {
    return -1
  }
  let mut offset = 0
  for _, ch in text {
    let code = Char::to_int(ch)
    if code <= 0x7f {
      if offset + 1 > cap {
        return -1
      }
      wasm_store8(ptr + offset, code)
      offset += 1
    } else if code <= 0x7ff {
      if offset + 2 > cap {
        return -1
      }
      wasm_store8(ptr + offset, 0xc0 + (code >> 6))
      wasm_store8(ptr + offset + 1, 0x80 + (code & 0x3f))
      offset += 2
    } else if code <= 0xffff {
      if offset + 3 > cap {
        return -1
      }
      wasm_store8(ptr + offset, 0xe0 + (code >> 12))
      wasm_store8(ptr + offset + 1, 0x80 + ((code >> 6) & 0x3f))
      wasm_store8(ptr + offset + 2, 0x80 + (code & 0x3f))
      offset += 3
    } else {
      if offset + 4 > cap {
        return -1
      }
      wasm_store8(ptr + offset, 0xf0 + (code >> 18))
      wasm_store8(ptr + offset + 1, 0x80 + ((code >> 12) & 0x3f))
      wasm_store8(ptr + offset + 2, 0x80 + ((code >> 6) & 0x3f))
      wasm_store8(ptr + offset + 3, 0x80 + (code & 0x3f))
      offset += 4
    }
  }
  offset
}

///|
fn run_utf8_transform(
  source_ptr : Int,
  source_len : Int,
  out_ptr : Int,
  out_cap : Int,
  transform : (String) -> String,
) -> Int {
  let source = match decode_utf8_from_memory(source_ptr, source_len) {
    Some(value) => value
    None => return -1
  }
  let result = transform(source)
  write_utf8_to_memory(out_ptr, out_cap, result)
}

///|
pub fn vibe_init(
  source_ptr : Int,
  source_len : Int,
  out_ptr : Int,
  out_cap : Int,
) -> Int {
  run_utf8_transform(
    source_ptr, source_len, out_ptr, out_cap, init_state_report_json,
  )
}

///|
pub fn vibe_check(
  source_ptr : Int,
  source_len : Int,
  out_ptr : Int,
  out_cap : Int,
) -> Int {
  run_utf8_transform(
    source_ptr, source_len, out_ptr, out_cap, check_report_json,
  )
}

///|
pub fn vibe_check_project(
  source_ptr : Int,
  source_len : Int,
  out_ptr : Int,
  out_cap : Int,
) -> Int {
  run_utf8_transform(
    source_ptr, source_len, out_ptr, out_cap, check_project_report_json,
  )
}

///|
pub fn vibe_format(
  source_ptr : Int,
  source_len : Int,
  out_ptr : Int,
  out_cap : Int,
) -> Int {
  run_utf8_transform(
    source_ptr, source_len, out_ptr, out_cap, format_report_json,
  )
}

///|
pub fn vibe_ide_outline(
  source_ptr : Int,
  source_len : Int,
  out_ptr : Int,
  out_cap : Int,
) -> Int {
  run_utf8_transform(
    source_ptr, source_len, out_ptr, out_cap, ide_outline_report_json,
  )
}

///|
pub fn vibe_ide_peek_def(
  source_ptr : Int,
  source_len : Int,
  out_ptr : Int,
  out_cap : Int,
) -> Int {
  run_utf8_transform(
    source_ptr, source_len, out_ptr, out_cap, ide_peek_def_report_json,
  )
}

///|
pub fn vibe_ide_search(
  source_ptr : Int,
  source_len : Int,
  out_ptr : Int,
  out_cap : Int,
) -> Int {
  run_utf8_transform(
    source_ptr, source_len, out_ptr, out_cap, ide_search_report_json,
  )
}

///|
pub fn vibe_eval(
  source_ptr : Int,
  source_len : Int,
  out_ptr : Int,
  out_cap : Int,
) -> Int {
  run_utf8_transform(source_ptr, source_len, out_ptr, out_cap, eval_report_json)
}

///|
pub fn vibe_eval_reset(
  source_ptr : Int,
  source_len : Int,
  out_ptr : Int,
  out_cap : Int,
) -> Int {
  run_utf8_transform(
    source_ptr, source_len, out_ptr, out_cap, eval_reset_report_json,
  )
}
