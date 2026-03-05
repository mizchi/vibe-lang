///|
/// Detect language ID from file extension.
pub fn detect_language_id(path : String) -> String? {
  let lower = path.to_lower()
  if lower.has_suffix(".vibe") {
    Some("vibe")
  } else if lower.has_suffix(".ts") ||
    lower.has_suffix(".tsx") ||
    lower.has_suffix(".mts") ||
    lower.has_suffix(".cts") {
    Some("typescript")
  } else if lower.has_suffix(".js") ||
    lower.has_suffix(".jsx") ||
    lower.has_suffix(".mjs") ||
    lower.has_suffix(".cjs") {
    Some("javascript")
  } else if lower.has_suffix(".py") || lower.has_suffix(".pyi") {
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

///|
fn graph_ir_row_merge_key(row : GraphIrRow) -> String {
  row.language_id +
  "|" +
  row.path +
  "|" +
  row.name +
  "|" +
  row.start.to_string() +
  "|" +
  row.end.to_string()
}

///|
pub fn merge_graph_ir_rows(
  baseline_rows : Array[GraphIrRow],
  semantic_rows : Array[GraphIrRow],
) -> Array[GraphIrRow] {
  if semantic_rows.length() == 0 {
    return baseline_rows
  }
  let semantic_by_key : Map[String, GraphIrRow] = {}
  for row in semantic_rows {
    semantic_by_key[graph_ir_row_merge_key(row)] = row
  }
  let baseline_keys : Map[String, Bool] = {}
  let merged : Array[GraphIrRow] = []
  for row in baseline_rows {
    let key = graph_ir_row_merge_key(row)
    baseline_keys[key] = true
    match semantic_by_key.get(key) {
      Some(semantic_row) => merged.push(semantic_row)
      None => merged.push(row)
    }
  }
  let appended_keys : Map[String, Bool] = {}
  for row in semantic_rows {
    let key = graph_ir_row_merge_key(row)
    if baseline_keys.contains(key) || appended_keys.contains(key) {
      continue
    }
    merged.push(row)
    appended_keys[key] = true
  }
  merged
}

///|
pub fn extract_graph_ir_rows_with_semantic_provider(
  path : String,
  source : String,
  provider? : ((String, String, Array[GraphIrRow]) -> Result[
    Array[GraphIrRow],
    String,
  ])? = None,
) -> Result[Array[GraphIrRow], String] {
  match extract_graph_ir_rows_by_ext(path, source) {
    Ok(baseline_rows) =>
      match provider {
        Some(run_provider) =>
          match run_provider(path, source, baseline_rows) {
            Ok(semantic_rows) => Ok(
              merge_graph_ir_rows(baseline_rows, semantic_rows),
            )
            Err(err) => Err("semantic provider: " + err)
          }
        None => Ok(baseline_rows)
      }
    Err(err) => Err(err)
  }
}
