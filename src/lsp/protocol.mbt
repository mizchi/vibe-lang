///|
/// LSP Protocol types

///|
pub(all) struct LspPosition {
  line : Int
  character : Int
} derive(Show, Eq)

///|
pub(all) struct LspRange {
  start : LspPosition
  end : LspPosition
} derive(Show, Eq)

///|
pub(all) struct LspDiagnostic {
  range : LspRange
  severity : Int? // 1=Error, 2=Warning, 3=Info, 4=Hint
  source : String?
  message : String
} derive(Show, Eq)

///|
pub(all) struct LspTextDocumentIdentifier {
  uri : String
} derive(Show, Eq)

///|
pub(all) struct LspTextDocumentItem {
  uri : String
  language_id : String
  version : Int
  text : String
} derive(Show, Eq)

///|
pub(all) struct LspVersionedTextDocumentIdentifier {
  uri : String
  version : Int
} derive(Show, Eq)

///|
pub(all) struct LspTextDocumentContentChangeEvent {
  text : String
} derive(Show, Eq)

///|
pub fn position_to_json(pos : LspPosition) -> Json {
  let obj : Map[String, Json] = {}
  obj["line"] = Json::number(pos.line.to_double())
  obj["character"] = Json::number(pos.character.to_double())
  Json::object(obj)
}

///|
pub fn range_to_json(range : LspRange) -> Json {
  let obj : Map[String, Json] = {}
  obj["start"] = position_to_json(range.start)
  obj["end"] = position_to_json(range.end)
  Json::object(obj)
}

///|
pub fn diagnostic_to_json(diag : LspDiagnostic) -> Json {
  let obj : Map[String, Json] = {}
  obj["range"] = range_to_json(diag.range)
  match diag.severity {
    Some(s) => obj["severity"] = Json::number(s.to_double())
    None => ()
  }
  match diag.source {
    Some(s) => obj["source"] = Json::string(s)
    None => ()
  }
  obj["message"] = Json::string(diag.message)
  Json::object(obj)
}

///|
pub fn parse_text_document_item(json : Json?) -> LspTextDocumentItem? {
  match json {
    Some(Json::Object(obj)) => {
      let uri = match obj.get("uri") {
        Some(Json::String(s)) => s
        _ => return None
      }
      let language_id = match obj.get("languageId") {
        Some(Json::String(s)) => s
        _ => return None
      }
      let version = match obj.get("version") {
        Some(Json::Number(n, ..)) => n.to_int()
        _ => return None
      }
      let text = match obj.get("text") {
        Some(Json::String(s)) => s
        _ => return None
      }
      Some(LspTextDocumentItem::{ uri, language_id, version, text })
    }
    _ => None
  }
}

///|
pub fn parse_text_document_identifier(
  json : Json?,
) -> LspTextDocumentIdentifier? {
  match json {
    Some(Json::Object(obj)) =>
      match obj.get("uri") {
        Some(Json::String(uri)) => Some(LspTextDocumentIdentifier::{ uri, })
        _ => None
      }
    _ => None
  }
}

///|
pub fn parse_position(json : Json?) -> LspPosition? {
  match json {
    Some(Json::Object(obj)) => {
      let line = match obj.get("line") {
        Some(Json::Number(n, ..)) => n.to_int()
        _ => return None
      }
      let character = match obj.get("character") {
        Some(Json::Number(n, ..)) => n.to_int()
        _ => return None
      }
      Some(LspPosition::{ line, character })
    }
    _ => None
  }
}

///|
pub fn parse_versioned_text_document_identifier(
  json : Json?,
) -> LspVersionedTextDocumentIdentifier? {
  match json {
    Some(Json::Object(obj)) => {
      let uri = match obj.get("uri") {
        Some(Json::String(s)) => s
        _ => return None
      }
      let version = match obj.get("version") {
        Some(Json::Number(n, ..)) => n.to_int()
        _ => return None
      }
      Some(LspVersionedTextDocumentIdentifier::{ uri, version })
    }
    _ => None
  }
}

///|
pub fn parse_content_changes(
  json : Json?,
) -> Array[LspTextDocumentContentChangeEvent] {
  let changes : Array[LspTextDocumentContentChangeEvent] = []
  match json {
    Some(Json::Array(arr)) =>
      for item in arr {
        match item {
          Json::Object(obj) =>
            match obj.get("text") {
              Some(Json::String(text)) =>
                changes.push(LspTextDocumentContentChangeEvent::{ text, })
              _ => ()
            }
          _ => ()
        }
      }
    _ => ()
  }
  changes
}
