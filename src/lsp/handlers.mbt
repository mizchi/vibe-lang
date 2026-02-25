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
  capabilities["hoverProvider"] = Json::boolean(true)
  let completion_options : Map[String, Json] = {}
  completion_options["resolveProvider"] = Json::boolean(false)
  completion_options["triggerCharacters"] = Json::array([
    Json::string("."),
    Json::string(":"),
  ])
  capabilities["completionProvider"] = Json::object(completion_options)
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
fn symbol_hash(entry : @frontend.SymbolEntry) -> String {
  let key = entry.path +
    "|" +
    entry.span.start.to_string() +
    "|" +
    entry.span.end.to_string() +
    "|" +
    entry.name +
    "|" +
    @frontend.symbol_kind_name(entry.kind) +
    "|" +
    entry.signature
  @core.git_blob_hash_string(key)
}

///|
fn symbol_index_for_source(
  uri : String,
  source : String,
) -> @frontend.SymbolIndex? {
  let ast = @parser.parse_ast(source) catch { _ => return None }
  let env = (try? @checker.type_check(ast)).unwrap_or(@checker.TypeEnv::new())
  Some(@frontend.build_symbol_index_for_module(uri, ast, env))
}

///|
fn clamp_offset_for_source(source : String, offset : Int) -> Int {
  if source.length() == 0 {
    0
  } else if offset < 0 {
    0
  } else if offset > source.length() {
    source.length()
  } else {
    offset
  }
}

///|
fn source_ident_prefix_at(source : String, offset : Int) -> String {
  if source.length() == 0 {
    return ""
  }
  let chars = source.to_array()
  let mut i = clamp_offset_for_source(source, offset)
  if i > chars.length() {
    i = chars.length()
  }
  let mut start = i
  while start > 0 && is_ident_char(chars[start - 1]) {
    start -= 1
  }
  if i <= start {
    return ""
  }
  source.unsafe_substring(start~, end=i)
}

///|
fn source_ident_at(source : String, offset : Int) -> String? {
  if source.length() == 0 {
    return None
  }
  let chars = source.to_array()
  if chars.length() == 0 {
    return None
  }
  let mut anchor = clamp_offset_for_source(source, offset)
  if anchor >= chars.length() {
    anchor = chars.length() - 1
  }
  if not(is_ident_char(chars[anchor])) {
    if anchor > 0 && is_ident_char(chars[anchor - 1]) {
      anchor -= 1
    } else {
      return None
    }
  }
  let mut start = anchor
  let mut end = anchor + 1
  while start > 0 && is_ident_char(chars[start - 1]) {
    start -= 1
  }
  while end < chars.length() && is_ident_char(chars[end]) {
    end += 1
  }
  if end <= start {
    None
  } else {
    Some(source.unsafe_substring(start~, end~))
  }
}

///|
fn completion_kind(kind : @frontend.SymbolKind) -> Int {
  match kind {
    @frontend.SymbolKind::FnSym => 3
    @frontend.SymbolKind::ValueSym => 6
    @frontend.SymbolKind::TypeAliasSym => 7
    @frontend.SymbolKind::EnumSym => 13
    @frontend.SymbolKind::StructSym => 22
    @frontend.SymbolKind::TraitSym => 8
    @frontend.SymbolKind::CtorSym => 4
    @frontend.SymbolKind::ImplSym => 9
  }
}

///|
fn completion_item_json(entry : @frontend.SymbolEntry) -> Json {
  let hash = symbol_hash(entry)
  let obj : Map[String, Json] = {}
  obj["label"] = Json::string(entry.name)
  obj["kind"] = Json::number(completion_kind(entry.kind).to_double())
  obj["detail"] = Json::string(
    @frontend.symbol_kind_name(entry.kind) + " " + entry.signature,
  )
  obj["documentation"] = Json::string(
    "hash: " + @core.short_hash(hash) + " (" + hash + ")",
  )
  Json::object(obj)
}

///|
pub fn completion_items_json(
  uri : String,
  source : String,
  position : LspPosition,
) -> Json {
  let offset = position_to_offset(source, position)
  let prefix = source_ident_prefix_at(source, offset)
  let items : Array[Json] = []
  let seen : Map[String, Bool] = {}
  match symbol_index_for_source(uri, source) {
    Some(index) =>
      for entry in index.entries {
        if prefix.length() > 0 && not(entry.name.has_prefix(prefix)) {
          continue
        }
        if seen.contains(entry.name) {
          continue
        }
        seen[entry.name] = true
        items.push(completion_item_json(entry))
      }
    None => ()
  }
  Json::array(items)
}

///|
fn hover_entry_markdown(entry : @frontend.SymbolEntry) -> String {
  let hash = symbol_hash(entry)
  "```vibe\n" +
  entry.name +
  " : " +
  entry.signature +
  "\n```\n\nkind: `" +
  @frontend.symbol_kind_name(entry.kind) +
  "`\n\nhash: `" +
  hash +
  "`"
}

///|
pub fn hover_json(
  uri : String,
  source : String,
  position : LspPosition,
) -> Json {
  let offset = position_to_offset(source, position)
  let name = match source_ident_at(source, offset) {
    Some(v) => v
    None => return Json::null()
  }
  let index = match symbol_index_for_source(uri, source) {
    Some(v) => v
    None => return Json::null()
  }
  let matches = index.find_exact(name)
  if matches.length() == 0 {
    return Json::null()
  }
  let mut selected = matches[0]
  for entry in matches {
    if offset >= entry.span.start && offset <= entry.span.end {
      selected = entry
      break
    }
  }
  let contents : Map[String, Json] = {}
  contents["kind"] = Json::string("markdown")
  contents["value"] = Json::string(hover_entry_markdown(selected))
  let out : Map[String, Json] = {}
  out["contents"] = Json::object(contents)
  out["range"] = range_to_json(span_to_range(source, selected.span))
  Json::object(out)
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
    "import " + module_path + " { " + source_trait + " }\n"
  } else {
    "import " +
    module_path +
    " { " +
    source_trait +
    " as " +
    local_trait +
    " }\n"
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
  let module_path = "./vibe/builtin/builtin_traits.vibe"
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
