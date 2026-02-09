///|
/// LSP method handlers

///|
pub fn handle_initialize(id : JsonRpcId?) -> JsonRpcResponse {
  let capabilities : Map[String, Json] = {}

  // Text document sync - full sync mode
  let sync_options : Map[String, Json] = {}
  sync_options["openClose"] = Json::boolean(true)
  sync_options["change"] = Json::number(1.0) // Full sync
  capabilities["textDocumentSync"] = Json::object(sync_options)
  capabilities["codeActionProvider"] = Json::boolean(true)
  let result : Map[String, Json] = {}
  result["capabilities"] = Json::object(capabilities)
  make_response(id, Json::object(result))
}

///|
pub fn handle_shutdown(id : JsonRpcId?) -> JsonRpcResponse {
  make_response(id, Json::null())
}

///|
/// Check document and return diagnostics
pub fn check_document(
  _uri : String,
  source : String,
) -> (Array[LspDiagnostic], Bool) {
  let diagnostics : Array[LspDiagnostic] = []

  // Parse
  let ast = @parser.parse_ast(source) catch {
    e => {
      let diag = e.diagnostic()
      diagnostics.push(to_lsp_diagnostic(diag, source))
      return (diagnostics, false)
    }
  }

  // Type check
  let type_result = Ok(@checker.type_check(ast)) catch { e => Err(e) }
  match type_result {
    Err(e) => {
      let diag = e.diagnostic()
      diagnostics.push(to_lsp_diagnostic(diag, source))
      (diagnostics, false)
    }
    Ok(_) => {
      let warnings = @checker.collect_warnings(ast)
      for warning in warnings {
        diagnostics.push(to_lsp_diagnostic(warning, source))
      }
      (diagnostics, true)
    }
  }
}

///|
fn is_ident_char(c : Char) -> Bool {
  (c >= 'A' && c <= 'Z') ||
  (c >= 'a' && c <= 'z') ||
  (c >= '0' && c <= '9') ||
  c == '_'
}

///|
fn leading_ident(s : String) -> String? {
  let sb = StringBuilder::new()
  let mut found = false
  for c in s.to_array() {
    if is_ident_char(c) {
      sb.write_char(c)
      found = true
    } else if found {
      break
    }
  }
  let ident = sb.to_string()
  if ident.length() == 0 {
    None
  } else {
    Some(ident)
  }
}

///|
fn extract_unknown_trait_name(message : String) -> String? {
  let marker = "unknown trait: "
  if not(message.contains(marker)) {
    return None
  }
  let mut tail = ""
  for part in message.split(marker) {
    tail = part.to_string()
  }
  leading_ident(tail)
}

///|
fn resolve_trait_import(local_trait : String) -> (String, String)? {
  match local_trait {
    "Eq" | "Ord" | "Show" | "Add" | "Sub" | "Mul" | "Div" | "Signed" =>
      Some((local_trait, local_trait))
    _ =>
      if local_trait.contains("Eq") {
        Some(("Eq", local_trait))
      } else if local_trait.contains("Ord") || local_trait.contains("Order") {
        Some(("Ord", local_trait))
      } else {
        None
      }
  }
}

///|
fn is_trait_imported(
  source : String,
  source_trait : String,
  local_trait : String,
  module_path : String,
) -> Bool {
  let ast = @parser.parse_ast(source) catch { _ => return false }
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::Import(spec~, source~, ..) => {
        let import_path = match source {
          @core.ModuleRef::Path(path~) => Some(path)
          @core.ModuleRef::Hash(_)
          | @core.ModuleRef::Version(_)
          | @core.ModuleRef::Symbol(_) => None
        }
        for item in spec.items {
          let trait_compatible = item.kind == @core.ImportKind::Value ||
            item.kind == @core.ImportKind::Trait
          if not(trait_compatible) {
            continue
          }
          let local_name = match item.rename {
            Some(rename) => rename
            None => item.name
          }
          if local_name == local_trait {
            return true
          }
          match import_path {
            Some(path) =>
              if path == module_path &&
                item.name == source_trait &&
                local_name == local_trait {
                return true
              }
            None => ()
          }
        }
      }
      _ => ()
    }
  }
  false
}

///|
fn import_insert_line(source : String) -> Int {
  let mut insert_line = 0
  let mut has_import = false
  let mut line_index = 0
  for line_view in source.split("\n") {
    let line = line_view.to_string().trim().to_string()
    if line.has_prefix("import ") {
      has_import = true
      insert_line = line_index + 1
      line_index += 1
      continue
    }
    if has_import && line.length() == 0 {
      insert_line = line_index + 1
      line_index += 1
      continue
    }
    if has_import {
      break
    }
    line_index += 1
  }
  insert_line
}

///|
fn make_trait_import_action(
  uri : String,
  source_trait : String,
  local_trait : String,
  module_path : String,
  insert_line : Int,
) -> Json {
  let import_stmt = if source_trait == local_trait {
    "import { " + source_trait + " } from \"" + module_path + "\"\n"
  } else {
    "import { " +
    source_trait +
    " as " +
    local_trait +
    " } from \"" +
    module_path +
    "\"\n"
  }
  let title = if source_trait == local_trait {
    "Import " + source_trait + " from " + module_path
  } else {
    "Import " + source_trait + " as " + local_trait + " from " + module_path
  }
  let pos : Map[String, Json] = {}
  pos["line"] = Json::number(insert_line.to_double())
  pos["character"] = Json::number(0.0)
  let range : Map[String, Json] = {}
  range["start"] = Json::object(pos)
  range["end"] = Json::object(pos)
  let edit_item : Map[String, Json] = {}
  edit_item["range"] = Json::object(range)
  edit_item["newText"] = Json::string(import_stmt)
  let edits : Array[Json] = [Json::object(edit_item)]
  let changes : Map[String, Json] = {}
  changes[uri] = Json::array(edits)
  let edit : Map[String, Json] = {}
  edit["changes"] = Json::object(changes)
  let action : Map[String, Json] = {}
  action["title"] = Json::string(title)
  action["kind"] = Json::string("quickfix")
  action["edit"] = Json::object(edit)
  Json::object(action)
}

///|
pub fn trait_import_code_actions(uri : String, source : String) -> Json {
  let module_path = "./xsh/std/trait_api.xsh"
  let (diagnostics, _) = check_document(uri, source)
  let insert_line = import_insert_line(source)
  let seen : Map[String, Bool] = {}
  let actions : Array[Json] = []
  for diag in diagnostics {
    match extract_unknown_trait_name(diag.message) {
      Some(local_trait) =>
        match resolve_trait_import(local_trait) {
          Some((source_trait, local_name)) => {
            let key = source_trait + "->" + local_name
            if seen.contains(key) {
              continue
            }
            if is_trait_imported(source, source_trait, local_name, module_path) {
              continue
            }
            seen[key] = true
            actions.push(
              make_trait_import_action(
                uri, source_trait, local_name, module_path, insert_line,
              ),
            )
          }
          None => ()
        }
      None => ()
    }
  }
  Json::array(actions)
}
