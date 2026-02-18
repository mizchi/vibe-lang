///|
/// Detect language ID from file extension.
pub fn detect_language_id(path : String) -> String? {
  let lower = path.to_lower()
  if lower.has_suffix(".vibe") {
    Some("vibe")
  } else if lower.has_suffix(".ts") || lower.has_suffix(".tsx") {
    Some("typescript")
  } else if lower.has_suffix(".js") || lower.has_suffix(".jsx") {
    Some("javascript")
  } else if lower.has_suffix(".py") {
    Some("python")
  } else {
    None
  }
}

///|
/// Extract GraphIrRows by dispatching to the correct language extractor.
pub fn extract_graph_ir_rows_by_ext(
  path : String,
  source : String,
) -> Result[Array[GraphIrRow], String] {
  match detect_language_id(path) {
    Some("vibe") => extract_vibe_graph_ir_rows(path, source)
    Some("typescript") | Some("javascript") =>
      Ok(extract_typescript_graph_ir_rows(path, source))
    Some("python") => Ok(extract_python_graph_ir_rows(path, source))
    Some(lang) => Err("unsupported language: " + lang)
    None => Err("unable to detect language for: " + path)
  }
}
