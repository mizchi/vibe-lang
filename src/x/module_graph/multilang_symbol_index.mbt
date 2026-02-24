///|
/// Language-agnostic symbol/type/signature row.
/// This is a normalized ingestion format for vibe and external frontends
/// (tree-sitter, compiler, LSP, etc.).
pub struct GraphIrRow {
  language_id : String
  path : String
  name : String
  kind : String
  signature : String
  start : Int
  end : Int
  module_hash : String
  type_terms : Array[String]
  refs : Array[String]
  calls : Array[String]
  imports : Array[String]
} derive(Show, Eq)

///|
pub fn new_graph_ir_row(
  language_id : String,
  path : String,
  name : String,
  kind : String,
  signature : String,
  start : Int,
  end : Int,
  module_hash : String,
  type_terms : Array[String],
  refs : Array[String],
  calls : Array[String],
  imports : Array[String],
) -> GraphIrRow {
  GraphIrRow::{
    language_id,
    path,
    name,
    kind,
    signature,
    start,
    end,
    module_hash,
    type_terms,
    refs,
    calls,
    imports,
  }
}

///|
/// Canonical definition stored in the shared multi-language index.
pub struct GraphIrDef {
  def_id : String
  anchor_id : String
  language_id : String
  path : String
  name : String
  kind : String
  signature : String
  start : Int
  end : Int
  module_hash : String
  type_terms : Array[String]
  refs : Array[String]
  calls : Array[String]
  imports : Array[String]
} derive(Show, Eq)

///|
/// Shared backend index keyed by language-aware symbol/type keys.
pub struct MultiLangSymbolIndex {
  defs : Map[String, GraphIrDef]
  anchor_to_def : Map[String, String]
  symbol_index : Map[String, Array[String]]
  type_index : Map[String, Array[String]]
} derive(Show, Eq)

///|
fn ml_sorted_unique_strings(values : Array[String]) -> Array[String] {
  let uniq : Map[String, Bool] = {}
  for value in values {
    if value.length() == 0 {
      continue
    }
    uniq[value] = true
  }
  let out : Array[String] = []
  for key, _ in uniq {
    out.push(key)
  }
  out.sort()
  out
}

///|
fn ml_join_with(parts : Array[String], sep : String) -> String {
  if parts.length() == 0 {
    return ""
  }
  let buf = StringBuilder::new()
  for i in 0..<parts.length() {
    if i > 0 {
      buf.write_string(sep)
    }
    buf.write_string(parts[i])
  }
  buf.to_string()
}

///|
fn ml_replace_all_delimiters(signature : String) -> String {
  let mut out = signature.replace_all(old="->", new=" ")
  out = out.replace_all(old="=>", new=" ")
  let delimiters = [
    "(", ")", "[", "]", "{", "}", ",", ";", ":", "|", "&", "<", ">", "=", "~", "?",
  ]
  for delim in delimiters {
    out = out.replace_all(old=delim, new=" ")
  }
  out
}

///|
fn ml_is_known_lower_type_atom(token : String) -> Bool {
  match token {
    "number"
    | "string"
    | "boolean"
    | "unknown"
    | "never"
    | "any"
    | "void"
    | "i32"
    | "i64"
    | "f32"
    | "f64" => true
    _ => false
  }
}

///|
fn ml_is_type_atom(token : String) -> Bool {
  if token.length() == 0 {
    return false
  }
  if token.has_prefix("'") || token.has_prefix("?") {
    return false
  }
  if ml_is_known_lower_type_atom(token) {
    return true
  }
  match token.get_char(0) {
    Some(ch) => ch.is_ascii_uppercase()
    None => false
  }
}

///|
fn ml_extract_type_terms_from_signature(signature : String) -> Array[String] {
  let normalized = ml_replace_all_delimiters(signature)
  let terms : Array[String] = []
  for part_view in normalized.split(" ") {
    let token = part_view.to_string()
    if token.length() == 0 {
      continue
    }
    if ml_is_type_atom(token) {
      terms.push(token)
    }
  }
  ml_sorted_unique_strings(terms)
}

///|
pub fn multilang_symbol_key(language_id : String, name : String) -> String {
  language_id + "::symbol::" + name
}

///|
pub fn multilang_type_key(language_id : String, type_term : String) -> String {
  language_id + "::type::" + type_term
}

///|
fn ml_row_anchor_raw(row : GraphIrRow) -> String {
  row.language_id +
  "|" +
  row.path +
  "|" +
  row.start.to_string() +
  "|" +
  row.end.to_string() +
  "|" +
  row.name +
  "|" +
  row.kind
}

///|
pub fn graph_ir_anchor_id(row : GraphIrRow) -> String {
  @core.git_blob_hash_string(ml_row_anchor_raw(row))
}

///|
pub fn graph_ir_def_id(row : GraphIrRow) -> String {
  let terms = ml_sorted_unique_strings(row.type_terms)
  let refs = ml_sorted_unique_strings(row.refs)
  let calls = ml_sorted_unique_strings(row.calls)
  let imports = ml_sorted_unique_strings(row.imports)
  let payload = ml_row_anchor_raw(row) +
    "|" +
    row.signature +
    "|" +
    row.module_hash +
    "|" +
    ml_join_with(terms, ",") +
    "|" +
    ml_join_with(refs, ",") +
    "|" +
    ml_join_with(calls, ",") +
    "|" +
    ml_join_with(imports, ",")
  @core.git_blob_hash_string(payload)
}

///|
fn ml_normalize_row(row : GraphIrRow) -> GraphIrDef {
  let terms = ml_sorted_unique_strings(row.type_terms)
  let refs = ml_sorted_unique_strings(row.refs)
  let calls = ml_sorted_unique_strings(row.calls)
  let imports = ml_sorted_unique_strings(row.imports)
  GraphIrDef::{
    def_id: graph_ir_def_id(row),
    anchor_id: graph_ir_anchor_id(row),
    language_id: row.language_id,
    path: row.path,
    name: row.name,
    kind: row.kind,
    signature: row.signature,
    start: row.start,
    end: row.end,
    module_hash: row.module_hash,
    type_terms: terms,
    refs,
    calls,
    imports,
  }
}

///|
fn ml_push_unique_string(values : Array[String], value : String) -> Unit {
  for existing in values {
    if existing == value {
      return
    }
  }
  values.push(value)
}

///|
fn ml_push_index_id(
  index_map : Map[String, Array[String]],
  key : String,
  def_id : String,
) -> Unit {
  match index_map.get(key) {
    Some(existing) => {
      ml_push_unique_string(existing, def_id)
      index_map[key] = existing
    }
    None => index_map[key] = [def_id]
  }
}

///|
fn ml_remove_index_id(
  index_map : Map[String, Array[String]],
  key : String,
  def_id : String,
) -> Unit {
  match index_map.get(key) {
    Some(existing) => {
      let next_ids : Array[String] = []
      for id in existing {
        if id != def_id {
          next_ids.push(id)
        }
      }
      if next_ids.length() == 0 {
        index_map.remove(key)
      } else {
        index_map[key] = next_ids
      }
    }
    None => ()
  }
}

///|
fn ml_def_type_terms_for_index(def : GraphIrDef) -> Array[String] {
  let terms : Array[String] = []
  for term in def.type_terms {
    terms.push(term)
  }
  terms.push(def.signature)
  ml_sorted_unique_strings(terms)
}

///|
fn ml_add_def_to_indexes(
  symbol_index : Map[String, Array[String]],
  type_index : Map[String, Array[String]],
  def : GraphIrDef,
) -> Unit {
  ml_push_index_id(
    symbol_index,
    multilang_symbol_key(def.language_id, def.name),
    def.def_id,
  )
  for term in ml_def_type_terms_for_index(def) {
    ml_push_index_id(
      type_index,
      multilang_type_key(def.language_id, term),
      def.def_id,
    )
  }
}

///|
fn ml_remove_def_from_indexes(
  symbol_index : Map[String, Array[String]],
  type_index : Map[String, Array[String]],
  def : GraphIrDef,
) -> Unit {
  ml_remove_index_id(
    symbol_index,
    multilang_symbol_key(def.language_id, def.name),
    def.def_id,
  )
  for term in ml_def_type_terms_for_index(def) {
    ml_remove_index_id(
      type_index,
      multilang_type_key(def.language_id, term),
      def.def_id,
    )
  }
}

///|
fn ml_sorted_def_ids(defs : Map[String, GraphIrDef]) -> Array[String] {
  let out : Array[String] = []
  for def_id, _ in defs {
    out.push(def_id)
  }
  out.sort()
  out
}

///|
fn ml_collect_defs_by_ids(
  defs : Map[String, GraphIrDef],
  ids : Array[String],
  out : Array[GraphIrDef],
  seen : Map[String, Bool],
  language_id : String,
) -> Unit {
  for def_id in ids {
    if seen.contains(def_id) {
      continue
    }
    match defs.get(def_id) {
      Some(def) =>
        if language_id.length() == 0 || def.language_id == language_id {
          seen[def_id] = true
          out.push(def)
        }
      None => ()
    }
  }
}

///|
pub fn build_multilang_symbol_index(
  rows : Array[GraphIrRow],
) -> MultiLangSymbolIndex {
  let empty = MultiLangSymbolIndex::{
    defs: {},
    anchor_to_def: {},
    symbol_index: {},
    type_index: {},
  }
  empty.upsert_rows(rows)
}

///|
pub fn MultiLangSymbolIndex::upsert_rows(
  self : MultiLangSymbolIndex,
  rows : Array[GraphIrRow],
) -> MultiLangSymbolIndex {
  let defs = self.defs.copy()
  let anchor_to_def = self.anchor_to_def.copy()
  let symbol_index = self.symbol_index.copy()
  let type_index = self.type_index.copy()
  for row in rows {
    let next_def = ml_normalize_row(row)
    match anchor_to_def.get(next_def.anchor_id) {
      Some(prev_id) =>
        if prev_id != next_def.def_id {
          match defs.get(prev_id) {
            Some(prev_def) =>
              ml_remove_def_from_indexes(symbol_index, type_index, prev_def)
            None => ()
          }
          defs.remove(prev_id)
        }
      None => ()
    }
    match defs.get(next_def.def_id) {
      Some(prev_def_same_id) =>
        ml_remove_def_from_indexes(symbol_index, type_index, prev_def_same_id)
      None => ()
    }
    defs[next_def.def_id] = next_def
    anchor_to_def[next_def.anchor_id] = next_def.def_id
    ml_add_def_to_indexes(symbol_index, type_index, next_def)
  }
  MultiLangSymbolIndex::{ defs, anchor_to_def, symbol_index, type_index }
}

///|
pub fn MultiLangSymbolIndex::query_symbol(
  self : MultiLangSymbolIndex,
  query : String,
  language_id? : String = "",
) -> Array[GraphIrDef] {
  let out : Array[GraphIrDef] = []
  let seen : Map[String, Bool] = {}
  if query.length() == 0 {
    ml_collect_defs_by_ids(
      self.defs,
      ml_sorted_def_ids(self.defs),
      out,
      seen,
      language_id,
    )
    return out
  }
  if language_id.length() > 0 {
    match self.symbol_index.get(multilang_symbol_key(language_id, query)) {
      Some(ids) =>
        ml_collect_defs_by_ids(self.defs, ids, out, seen, language_id)
      None => ()
    }
  } else {
    let suffix = "::symbol::" + query
    for key, ids in self.symbol_index {
      if key.has_suffix(suffix) {
        ml_collect_defs_by_ids(self.defs, ids, out, seen, "")
      }
    }
  }
  for def_id in ml_sorted_def_ids(self.defs) {
    match self.defs.get(def_id) {
      Some(def) =>
        if (language_id.length() == 0 || def.language_id == language_id) &&
          def.name.contains(query) {
          if not(seen.contains(def_id)) {
            seen[def_id] = true
            out.push(def)
          }
        }
      None => ()
    }
  }
  out
}

///|
pub fn MultiLangSymbolIndex::query_type(
  self : MultiLangSymbolIndex,
  query : String,
  language_id? : String = "",
) -> Array[GraphIrDef] {
  let out : Array[GraphIrDef] = []
  let seen : Map[String, Bool] = {}
  if query.length() == 0 {
    ml_collect_defs_by_ids(
      self.defs,
      ml_sorted_def_ids(self.defs),
      out,
      seen,
      language_id,
    )
    return out
  }
  if language_id.length() > 0 {
    match self.type_index.get(multilang_type_key(language_id, query)) {
      Some(ids) =>
        ml_collect_defs_by_ids(self.defs, ids, out, seen, language_id)
      None => ()
    }
  } else {
    let suffix = "::type::" + query
    for key, ids in self.type_index {
      if key.has_suffix(suffix) {
        ml_collect_defs_by_ids(self.defs, ids, out, seen, "")
      }
    }
  }
  for def_id in ml_sorted_def_ids(self.defs) {
    match self.defs.get(def_id) {
      Some(def) =>
        if language_id.length() == 0 || def.language_id == language_id {
          if def.signature.contains(query) {
            if not(seen.contains(def_id)) {
              seen[def_id] = true
              out.push(def)
              continue
            }
          }
          for term in def.type_terms {
            if term.contains(query) {
              if not(seen.contains(def_id)) {
                seen[def_id] = true
                out.push(def)
              }
              break
            }
          }
        }
      None => ()
    }
  }
  out
}

///|
pub fn MultiLangSymbolIndex::verify(
  self : MultiLangSymbolIndex,
) -> Array[String] {
  let issues : Array[String] = []
  for key, ids in self.symbol_index {
    for def_id in ids {
      if not(self.defs.contains(def_id)) {
        issues.push("symbol index missing def: " + key + " -> " + def_id)
      }
    }
  }
  for key, ids in self.type_index {
    for def_id in ids {
      if not(self.defs.contains(def_id)) {
        issues.push("type index missing def: " + key + " -> " + def_id)
      }
    }
  }
  for anchor_id, def_id in self.anchor_to_def {
    match self.defs.get(def_id) {
      Some(def) =>
        if def.anchor_id != anchor_id {
          issues.push("anchor mismatch: " + anchor_id + " -> " + def_id)
        }
      None =>
        issues.push("anchor points missing def: " + anchor_id + " -> " + def_id)
    }
  }
  issues
}

///|
/// vibe frontend adapter prototype for the shared IR row.
pub fn extract_vibe_graph_ir_rows(
  path : String,
  source : String,
) -> Result[Array[GraphIrRow], String] {
  let ast = @parser.parse_ast(source) catch {
    e => return Err("parse failed: " + e.to_string())
  }
  let types = @checker.type_check(ast) catch {
    e => return Err("typecheck failed: " + e.to_string())
  }
  let symbol_index = @frontend.build_symbol_index_for_module(path, ast, types)
  let module_hash = @core.content_address_hash_string(source)
  let rows : Array[GraphIrRow] = []
  for entry in symbol_index.entries {
    rows.push(GraphIrRow::{
      language_id: "vibe",
      path: entry.path,
      name: entry.name,
      kind: @frontend.symbol_kind_name(entry.kind),
      signature: entry.signature,
      start: entry.span.start,
      end: entry.span.end,
      module_hash,
      type_terms: ml_extract_type_terms_from_signature(entry.signature),
      refs: [],
      calls: [],
      imports: [],
    })
  }
  Ok(rows)
}
