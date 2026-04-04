///|
/// Diagnostic conversion utilities

///|
/// Convert source position to LSP line/character
pub fn span_to_range(source : String, span : @core.Span) -> LspRange {
  let start_pos = offset_to_position(source, span.start)
  let end_pos = offset_to_position(source, span.end)
  LspRange::{ start: start_pos, end: end_pos }
}

///|
fn offset_to_position(source : String, offset : Int) -> LspPosition {
  let mut line = 0
  let mut col = 0
  let mut pos = 0
  let chars = source.to_array()
  while pos < offset && pos < chars.length() {
    if chars[pos] == '\n' {
      line += 1
      col = 0
    } else {
      col += 1
    }
    pos += 1
  }
  LspPosition::{ line, character: col }
}

///|
fn position_to_offset(source : String, pos : LspPosition) -> Int {
  if pos.line < 0 || pos.character < 0 {
    return 0
  }
  let mut line = 0
  let mut col = 0
  let mut idx = 0
  let chars = source.to_array()
  while idx < chars.length() {
    if line == pos.line && col == pos.character {
      return idx
    }
    if chars[idx] == '\n' {
      line += 1
      col = 0
      idx += 1
      if line > pos.line {
        return idx
      }
      continue
    }
    if line == pos.line {
      col += 1
    }
    idx += 1
  }
  chars.length()
}

///|
/// Convert vibe Diagnostic to LSP Diagnostic
pub fn to_lsp_diagnostic(
  diag : @core.Diagnostic,
  source : String,
) -> LspDiagnostic {
  let range = match diag.span {
    Some(span) => span_to_range(source, span)
    None =>
      LspRange::{
        start: LspPosition::{ line: 0, character: 0 },
        end: LspPosition::{ line: 0, character: 0 },
      }
  }
  let severity = Some(diag.severity_level())
  LspDiagnostic::{
    range,
    severity,
    source: Some("vibe"),
    message: diag.message,
  }
}

///|
/// Create publish diagnostics notification JSON
pub fn publish_diagnostics_json(
  uri : String,
  diagnostics : Array[LspDiagnostic],
) -> Json {
  let diag_arr : Array[Json] = []
  for d in diagnostics {
    diag_arr.push(diagnostic_to_json(d))
  }
  let params : Map[String, Json] = {}
  params["uri"] = Json::string(uri)
  params["diagnostics"] = Json::array(diag_arr)
  notification_to_json("textDocument/publishDiagnostics", Json::object(params))
}
