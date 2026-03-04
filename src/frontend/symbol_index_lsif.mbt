///|
fn json_int(value : Int) -> Json {
  Json::number(value.to_double())
}

///|
fn json_int_array(values : Array[Int]) -> Json {
  let arr : Array[Json] = []
  for value in values {
    arr.push(json_int(value))
  }
  Json::array(arr)
}

///|
fn next_id(counter : Ref[Int]) -> Int {
  let id = counter.val
  counter.val += 1
  id
}

///|
fn push_lsif_vertex(
  lines : Array[String],
  id : Int,
  label : String,
  payload : Map[String, Json],
) -> Unit {
  let obj : Map[String, Json] = {}
  obj["id"] = json_int(id)
  obj["type"] = Json::string("vertex")
  obj["label"] = Json::string(label)
  for key, value in payload {
    obj[key] = value
  }
  lines.push(Json::object(obj).stringify())
}

///|
fn push_lsif_edge_single(
  lines : Array[String],
  id : Int,
  label : String,
  out_v : Int,
  in_v : Int,
) -> Unit {
  let obj : Map[String, Json] = {}
  obj["id"] = json_int(id)
  obj["type"] = Json::string("edge")
  obj["label"] = Json::string(label)
  obj["outV"] = json_int(out_v)
  obj["inV"] = json_int(in_v)
  lines.push(Json::object(obj).stringify())
}

///|
fn push_lsif_edge_multi(
  lines : Array[String],
  id : Int,
  label : String,
  out_v : Int,
  in_vs : Array[Int],
  document? : Int = -1,
) -> Unit {
  let obj : Map[String, Json] = {}
  obj["id"] = json_int(id)
  obj["type"] = Json::string("edge")
  obj["label"] = Json::string(label)
  obj["outV"] = json_int(out_v)
  obj["inVs"] = json_int_array(in_vs)
  if document >= 0 {
    obj["document"] = json_int(document)
  }
  lines.push(Json::object(obj).stringify())
}

///|
fn path_to_uri(path : String) -> String {
  if path.has_prefix("file://") {
    path
  } else if path.has_prefix("/") {
    "file://" + path
  } else {
    "file:///" + path
  }
}

///|
fn lsif_language_id_for_path(path : String) -> String {
  let lower = path.to_lower()
  if lower.has_suffix(".vibe") {
    "vibe"
  } else if lower.has_suffix(".ts") || lower.has_suffix(".tsx") {
    "typescript"
  } else if lower.has_suffix(".js") || lower.has_suffix(".jsx") {
    "javascript"
  } else if lower.has_suffix(".py") {
    "python"
  } else {
    "vibe"
  }
}

///|
fn clamp_offset(offset : Int, source_len : Int) -> Int {
  if offset < 0 {
    0
  } else if offset > source_len {
    source_len
  } else {
    offset
  }
}

///|
fn build_line_starts(source : String) -> Array[Int] {
  let starts : Array[Int] = [0]
  for i, c in source {
    if c == '\n' && i + 1 <= source.length() {
      starts.push(i + 1)
    }
  }
  starts
}

///|
fn find_line_start_index(line_starts : Array[Int], offset : Int) -> Int {
  let mut low = 0
  let mut high = line_starts.length()
  while low < high {
    let mid = (low + high) / 2
    if line_starts[mid] <= offset {
      low = mid + 1
    } else {
      high = mid
    }
  }
  if low <= 0 {
    0
  } else {
    low - 1
  }
}

///|
fn line_col_from_line_starts(
  line_starts : Array[Int],
  source_len : Int,
  offset : Int,
) -> (Int, Int) {
  let off = clamp_offset(offset, source_len)
  let line_idx = find_line_start_index(line_starts, off)
  let line_start = line_starts[line_idx]
  (line_idx + 1, off - line_start + 1)
}

///|
fn zero_based(value : Int) -> Int {
  if value <= 0 {
    0
  } else {
    value - 1
  }
}

///|
fn sorted_index_paths(index : SymbolIndex) -> Array[String] {
  let seen : Map[String, Bool] = {}
  let paths : Array[String] = []
  for entry in index.entries {
    if not(seen.contains(entry.path)) {
      seen[entry.path] = true
      paths.push(entry.path)
    }
  }
  paths.sort()
  paths
}

///|
fn symbol_hover_signature(entry : SymbolEntry) -> String {
  symbol_kind_name(entry.kind) + " " + entry.name + " : " + entry.signature
}

///|
priv struct SourceDoc {
  document_id : Int
  source : String
  language_id : String
  line_starts : Array[Int]
}

///|
pub fn symbol_index_to_lsif_lines(
  index : SymbolIndex,
  source_of : (String) -> String?,
) -> Array[String] {
  let lines : Array[String] = []
  let counter : Ref[Int] = { val: 1 }
  let tool_info : Map[String, Json] = {}
  tool_info["name"] = Json::string("vibe")
  tool_info["version"] = Json::string("0.0.0")
  let metadata_payload : Map[String, Json] = {}
  metadata_payload["version"] = Json::string("0.6.0-next.7")
  metadata_payload["positionEncoding"] = Json::string("utf-16")
  metadata_payload["projectRoot"] = Json::string("file:///")
  metadata_payload["toolInfo"] = Json::object(tool_info)
  push_lsif_vertex(lines, next_id(counter), "metaData", metadata_payload)
  let project_payload : Map[String, Json] = {}
  project_payload["kind"] = Json::string("vibe")
  let project_id = next_id(counter)
  push_lsif_vertex(lines, project_id, "project", project_payload)
  let doc_ids : Array[Int] = []
  let docs : Map[String, SourceDoc] = {}
  for path in sorted_index_paths(index) {
    match source_of(path) {
      Some(source) => {
        let language_id = lsif_language_id_for_path(path)
        let document_payload : Map[String, Json] = {}
        document_payload["uri"] = Json::string(path_to_uri(path))
        document_payload["languageId"] = Json::string(language_id)
        let document_id = next_id(counter)
        push_lsif_vertex(lines, document_id, "document", document_payload)
        docs[path] = SourceDoc::{
          document_id,
          source,
          language_id,
          line_starts: build_line_starts(source),
        }
        doc_ids.push(document_id)
      }
      None => ()
    }
  }
  if doc_ids.length() > 0 {
    push_lsif_edge_multi(
      lines,
      next_id(counter),
      "contains",
      project_id,
      doc_ids,
    )
  }
  for entry in index.entries {
    match docs.get(entry.path) {
      Some(doc) => {
        let safe_end = if entry.span.end < entry.span.start {
          entry.span.start
        } else {
          entry.span.end
        }
        let (start_line, start_col) = line_col_from_line_starts(
          doc.line_starts,
          doc.source.length(),
          entry.span.start,
        )
        let (end_line, end_col) = line_col_from_line_starts(
          doc.line_starts,
          doc.source.length(),
          safe_end,
        )
        let range_payload : Map[String, Json] = {}
        range_payload["start"] = json_int(zero_based(start_line))
        range_payload["startCharacter"] = json_int(zero_based(start_col))
        range_payload["end"] = json_int(zero_based(end_line))
        range_payload["endCharacter"] = json_int(zero_based(end_col))
        let range_id = next_id(counter)
        push_lsif_vertex(lines, range_id, "range", range_payload)
        push_lsif_edge_single(
          lines,
          next_id(counter),
          "contains",
          doc.document_id,
          range_id,
        )
        let result_set_id = next_id(counter)
        push_lsif_vertex(lines, result_set_id, "resultSet", {})
        push_lsif_edge_single(
          lines,
          next_id(counter),
          "next",
          range_id,
          result_set_id,
        )
        let definition_id = next_id(counter)
        push_lsif_vertex(lines, definition_id, "definitionResult", {})
        push_lsif_edge_single(
          lines,
          next_id(counter),
          "textDocument/definition",
          result_set_id,
          definition_id,
        )
        push_lsif_edge_multi(
          lines,
          next_id(counter),
          "item",
          definition_id,
          [range_id],
          document=doc.document_id,
        )
        let hover_item : Map[String, Json] = {}
        hover_item["language"] = Json::string(doc.language_id)
        hover_item["value"] = Json::string(symbol_hover_signature(entry))
        let hover_result_obj : Map[String, Json] = {}
        hover_result_obj["contents"] = Json::array([Json::object(hover_item)])
        let hover_payload : Map[String, Json] = {}
        hover_payload["result"] = Json::object(hover_result_obj)
        let hover_id = next_id(counter)
        push_lsif_vertex(lines, hover_id, "hoverResult", hover_payload)
        push_lsif_edge_single(
          lines,
          next_id(counter),
          "textDocument/hover",
          result_set_id,
          hover_id,
        )
        let moniker_payload : Map[String, Json] = {}
        moniker_payload["kind"] = Json::string("export")
        moniker_payload["scheme"] = Json::string("vibe")
        moniker_payload["identifier"] = Json::string(
          entry.path + "::" + entry.name,
        )
        let moniker_id = next_id(counter)
        push_lsif_vertex(lines, moniker_id, "moniker", moniker_payload)
        push_lsif_edge_single(
          lines,
          next_id(counter),
          "moniker",
          result_set_id,
          moniker_id,
        )
      }
      None => ()
    }
  }
  lines
}
