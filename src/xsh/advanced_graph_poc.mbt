///|
/// POC index manifest that mirrors `refs/bit/index/*` root metadata.
pub struct AdvancedGraphManifest {
  schema_version : Int
  base_commit : String
  created_at : String
  features : Array[String]
  chunk_roots : Array[String]
} derive(Show, Eq)

///|
/// Flattened definition node for symbol/type lookup.
pub struct AdvancedGraphDef {
  def_id : String
  name : String
  kind : String
  signature : String
  path : String
  start : Int
  end : Int
  module_hash : String
} derive(Show, Eq)

///|
/// Single-file sidecar index POC.
pub struct AdvancedGraphIndex {
  manifest : AdvancedGraphManifest
  defs : Map[String, AdvancedGraphDef]
  symbol_index : Map[String, Array[String]]
  type_index : Map[String, Array[String]]
} derive(Show, Eq)

///|
fn ag_json_int(value : Int) -> Json {
  Json::number(value.to_double())
}

///|
fn json_string_array(values : Array[String]) -> Json {
  let out : Array[Json] = []
  for value in values {
    out.push(Json::string(value))
  }
  Json::array(out)
}

///|
fn sorted_string_keys_bool(map : Map[String, Bool]) -> Array[String] {
  let keys : Array[String] = []
  for key, _ in map {
    keys.push(key)
  }
  keys.sort()
  keys
}

///|
fn sorted_string_keys_def(map : Map[String, AdvancedGraphDef]) -> Array[String] {
  let keys : Array[String] = []
  for key, _ in map {
    keys.push(key)
  }
  keys.sort()
  keys
}

///|
fn push_unique_string(values : Array[String], value : String) -> Unit {
  for existing in values {
    if existing == value {
      return
    }
  }
  values.push(value)
}

///|
fn push_index_id(
  index_map : Map[String, Array[String]],
  key : String,
  def_id : String,
) -> Unit {
  match index_map.get(key) {
    Some(existing) => {
      push_unique_string(existing, def_id)
      index_map[key] = existing
    }
    None => index_map[key] = [def_id]
  }
}

///|
fn collect_defs_by_ids(
  defs : Map[String, AdvancedGraphDef],
  ids : Array[String],
  seen : Map[String, Bool],
  out : Array[AdvancedGraphDef],
) -> Unit {
  for def_id in ids {
    if seen.contains(def_id) {
      continue
    }
    seen[def_id] = true
    match defs.get(def_id) {
      Some(def) => out.push(def)
      None => ()
    }
  }
}

///|
fn module_hash_for_path(db : XshDb, path : String) -> String {
  match db.get_source(path) {
    Some(source) => @core.git_blob_hash_string(source)
    None => @core.git_blob_hash_string(path)
  }
}

///|
fn def_id_from_entry(entry : SymbolEntry, module_hash : String) -> String {
  let key = entry.path +
    "|" +
    entry.span.start.to_string() +
    "|" +
    entry.span.end.to_string() +
    "|" +
    entry.name +
    "|" +
    symbol_kind_name(entry.kind) +
    "|" +
    entry.signature +
    "|" +
    module_hash
  @core.git_blob_hash_string(key)
}

///|
fn default_graph_features() -> Array[String] {
  ["symbols", "types", "refs", "imports"]
}

///|
/// Build POC sidecar index from the existing shared symbol index backend.
pub fn build_advanced_graph_index(
  db : XshDb,
  paths : Array[String],
  base_commit? : String = "",
  created_at? : String = "",
) -> AdvancedGraphIndex {
  let symbol_index = build_symbol_index(db, paths)
  let defs : Map[String, AdvancedGraphDef] = {}
  let symbols : Map[String, Array[String]] = {}
  let types : Map[String, Array[String]] = {}
  for entry in symbol_index.entries {
    let module_hash = module_hash_for_path(db, entry.path)
    let def_id = def_id_from_entry(entry, module_hash)
    let node = AdvancedGraphDef::{
      def_id,
      name: entry.name,
      kind: symbol_kind_name(entry.kind),
      signature: entry.signature,
      path: entry.path,
      start: entry.span.start,
      end: entry.span.end,
      module_hash,
    }
    defs[def_id] = node
    push_index_id(symbols, entry.name, def_id)
    push_index_id(types, entry.signature, def_id)
  }
  let manifest = AdvancedGraphManifest::{
    schema_version: 1,
    base_commit,
    created_at,
    features: default_graph_features(),
    chunk_roots: ["inline://chunk0"],
  }
  AdvancedGraphIndex::{ manifest, defs, symbol_index: symbols, type_index: types }
}

///|
pub fn AdvancedGraphIndex::query_symbol(
  self : AdvancedGraphIndex,
  query : String,
) -> Array[AdvancedGraphDef] {
  let out : Array[AdvancedGraphDef] = []
  let seen : Map[String, Bool] = {}
  if query.length() == 0 {
    let ids = sorted_string_keys_def(self.defs)
    collect_defs_by_ids(self.defs, ids, seen, out)
    return out
  }
  match self.symbol_index.get(query) {
    Some(ids) => collect_defs_by_ids(self.defs, ids, seen, out)
    None => ()
  }
  for name, ids in self.symbol_index {
    if name == query {
      continue
    }
    if name.contains(query) {
      collect_defs_by_ids(self.defs, ids, seen, out)
    }
  }
  out
}

///|
pub fn AdvancedGraphIndex::query_type(
  self : AdvancedGraphIndex,
  query : String,
) -> Array[AdvancedGraphDef] {
  let out : Array[AdvancedGraphDef] = []
  let seen : Map[String, Bool] = {}
  if query.length() == 0 {
    let ids = sorted_string_keys_def(self.defs)
    collect_defs_by_ids(self.defs, ids, seen, out)
    return out
  }
  match self.type_index.get(query) {
    Some(ids) => collect_defs_by_ids(self.defs, ids, seen, out)
    None => ()
  }
  for sig, ids in self.type_index {
    if sig == query {
      continue
    }
    if sig.contains(query) {
      collect_defs_by_ids(self.defs, ids, seen, out)
    }
  }
  out
}

///|
/// Validate cross-reference consistency for the POC index.
pub fn AdvancedGraphIndex::verify(self : AdvancedGraphIndex) -> Array[String] {
  let issues : Array[String] = []
  for symbol, ids in self.symbol_index {
    for def_id in ids {
      if not(self.defs.contains(def_id)) {
        issues.push("symbol index missing def: " + symbol + " -> " + def_id)
      }
    }
  }
  for sig, ids in self.type_index {
    for def_id in ids {
      if not(self.defs.contains(def_id)) {
        issues.push("type index missing def: " + sig + " -> " + def_id)
      }
    }
  }
  for def_id, def in self.defs {
    let mut has_symbol_link = false
    match self.symbol_index.get(def.name) {
      Some(ids) =>
        for id in ids {
          if id == def_id {
            has_symbol_link = true
            break
          }
        }
      None => ()
    }
    if not(has_symbol_link) {
      issues.push("def missing symbol link: " + def_id + " (" + def.name + ")")
    }
    let mut has_type_link = false
    match self.type_index.get(def.signature) {
      Some(ids) =>
        for id in ids {
          if id == def_id {
            has_type_link = true
            break
          }
        }
      None => ()
    }
    if not(has_type_link) {
      issues.push("def missing type link: " + def_id + " (" + def.signature + ")")
    }
  }
  issues
}

///|
fn map_string_array_to_json(map : Map[String, Array[String]]) -> Json {
  let obj : Map[String, Json] = {}
  let keys : Map[String, Bool] = {}
  for key, _ in map {
    keys[key] = true
  }
  let ordered_keys = sorted_string_keys_bool(keys)
  for key in ordered_keys {
    match map.get(key) {
      Some(values) => obj[key] = json_string_array(values)
      None => ()
    }
  }
  Json::object(obj)
}

///|
fn parse_json_string_array(json : Json, context : String) -> Result[Array[String], String] {
  match json {
    Json::Array(items) => {
      let out : Array[String] = []
      for item in items {
        match item {
          Json::String(value) => out.push(value)
          _ => return Err(context + ": expected string array")
        }
      }
      Ok(out)
    }
    _ => Err(context + ": expected array")
  }
}

///|
fn get_object_field(
  obj : Map[String, Json],
  key : String,
  context : String,
) -> Result[Json, String] {
  match obj.get(key) {
    Some(value) => Ok(value)
    None => Err(context + ": missing field `" + key + "`")
  }
}

///|
fn get_object_string_field(
  obj : Map[String, Json],
  key : String,
  context : String,
) -> Result[String, String] {
  match get_object_field(obj, key, context) {
    Ok(Json::String(value)) => Ok(value)
    Ok(_) => Err(context + ": `" + key + "` must be string")
    Err(err) => Err(err)
  }
}

///|
fn get_object_int_field(
  obj : Map[String, Json],
  key : String,
  context : String,
) -> Result[Int, String] {
  match get_object_field(obj, key, context) {
    Ok(Json::Number(value, ..)) => Ok(value.to_int())
    Ok(_) => Err(context + ": `" + key + "` must be number")
    Err(err) => Err(err)
  }
}

///|
fn parse_string_array_map(
  json : Json,
  context : String,
) -> Result[Map[String, Array[String]], String] {
  match json {
    Json::Object(obj) => {
      let out : Map[String, Array[String]] = {}
      for key, value in obj {
        match parse_json_string_array(value, context + "." + key) {
          Ok(items) => out[key] = items
          Err(err) => return Err(err)
        }
      }
      Ok(out)
    }
    _ => Err(context + ": expected object")
  }
}

///|
pub fn AdvancedGraphIndex::to_json(self : AdvancedGraphIndex) -> Json {
  let manifest_obj : Map[String, Json] = {}
  manifest_obj["schema_version"] = ag_json_int(self.manifest.schema_version)
  manifest_obj["base_commit"] = Json::string(self.manifest.base_commit)
  manifest_obj["created_at"] = Json::string(self.manifest.created_at)
  manifest_obj["features"] = json_string_array(self.manifest.features)
  manifest_obj["chunk_roots"] = json_string_array(self.manifest.chunk_roots)

  let defs_arr : Array[Json] = []
  for def_id in sorted_string_keys_def(self.defs) {
    match self.defs.get(def_id) {
      Some(def) => {
        let item : Map[String, Json] = {}
        item["def_id"] = Json::string(def.def_id)
        item["name"] = Json::string(def.name)
        item["kind"] = Json::string(def.kind)
        item["signature"] = Json::string(def.signature)
        item["path"] = Json::string(def.path)
        item["start"] = ag_json_int(def.start)
        item["end"] = ag_json_int(def.end)
        item["module_hash"] = Json::string(def.module_hash)
        defs_arr.push(Json::object(item))
      }
      None => ()
    }
  }

  let out : Map[String, Json] = {}
  out["manifest"] = Json::object(manifest_obj)
  out["defs"] = Json::array(defs_arr)
  out["symbol_index"] = map_string_array_to_json(self.symbol_index)
  out["type_index"] = map_string_array_to_json(self.type_index)
  Json::object(out)
}

///|
pub fn advanced_graph_index_from_json(json : Json) -> Result[AdvancedGraphIndex, String] {
  let root = match json {
    Json::Object(obj) => obj
    _ => return Err("advanced graph json: root must be object")
  }
  let manifest = match get_object_field(root, "manifest", "root") {
    Ok(Json::Object(obj)) => obj
    Ok(_) => return Err("root.manifest: must be object")
    Err(err) => return Err(err)
  }
  let schema_version = match get_object_int_field(
    manifest,
    "schema_version",
    "root.manifest",
  ) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let base_commit = match get_object_string_field(
    manifest,
    "base_commit",
    "root.manifest",
  ) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let created_at = match get_object_string_field(
    manifest,
    "created_at",
    "root.manifest",
  ) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let features = match get_object_field(manifest, "features", "root.manifest") {
    Ok(v) =>
      match parse_json_string_array(v, "root.manifest.features") {
        Ok(items) => items
        Err(err) => return Err(err)
      }
    Err(err) => return Err(err)
  }
  let chunk_roots = match get_object_field(
    manifest,
    "chunk_roots",
    "root.manifest",
  ) {
    Ok(v) =>
      match parse_json_string_array(v, "root.manifest.chunk_roots") {
        Ok(items) => items
        Err(err) => return Err(err)
      }
    Err(err) => return Err(err)
  }

  let defs_json = match get_object_field(root, "defs", "root") {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let defs : Map[String, AdvancedGraphDef] = {}
  match defs_json {
    Json::Array(items) =>
      for i, item in items {
        let context = "root.defs[" + i.to_string() + "]"
        let obj = match item {
          Json::Object(o) => o
          _ => return Err(context + ": must be object")
        }
        let def_id = match get_object_string_field(obj, "def_id", context) {
          Ok(v) => v
          Err(err) => return Err(err)
        }
        let name = match get_object_string_field(obj, "name", context) {
          Ok(v) => v
          Err(err) => return Err(err)
        }
        let kind = match get_object_string_field(obj, "kind", context) {
          Ok(v) => v
          Err(err) => return Err(err)
        }
        let signature = match get_object_string_field(obj, "signature", context) {
          Ok(v) => v
          Err(err) => return Err(err)
        }
        let path = match get_object_string_field(obj, "path", context) {
          Ok(v) => v
          Err(err) => return Err(err)
        }
        let start = match get_object_int_field(obj, "start", context) {
          Ok(v) => v
          Err(err) => return Err(err)
        }
        let end = match get_object_int_field(obj, "end", context) {
          Ok(v) => v
          Err(err) => return Err(err)
        }
        let module_hash = match
          get_object_string_field(obj, "module_hash", context) {
          Ok(v) => v
          Err(err) => return Err(err)
        }
        defs[def_id] = AdvancedGraphDef::{
          def_id,
          name,
          kind,
          signature,
          path,
          start,
          end,
          module_hash,
        }
      }
    _ => return Err("root.defs: must be array")
  }

  let symbol_index = match get_object_field(root, "symbol_index", "root") {
    Ok(v) =>
      match parse_string_array_map(v, "root.symbol_index") {
        Ok(m) => m
        Err(err) => return Err(err)
      }
    Err(err) => return Err(err)
  }
  let type_index = match get_object_field(root, "type_index", "root") {
    Ok(v) =>
      match parse_string_array_map(v, "root.type_index") {
        Ok(m) => m
        Err(err) => return Err(err)
      }
    Err(err) => return Err(err)
  }

  Ok(AdvancedGraphIndex::{
    manifest: AdvancedGraphManifest::{
      schema_version,
      base_commit,
      created_at,
      features,
      chunk_roots,
    },
    defs,
    symbol_index,
    type_index,
  })
}

///|
pub fn write_advanced_graph_index(
  path : String,
  index : AdvancedGraphIndex,
) -> Result[Unit, String] {
  @os_fs.write_string_to_file(path, index.to_json().stringify()) catch {
    e => return Err("write index: " + e.to_string())
  }
  Ok(())
}

///|
pub fn read_advanced_graph_index(path : String) -> Result[AdvancedGraphIndex, String] {
  let content = @os_fs.read_file_to_string(path) catch {
    e => return Err("read index: " + e.to_string())
  }
  let parsed = @json.parse(content) catch {
    e => return Err("parse index json: " + e.to_string())
  }
  advanced_graph_index_from_json(parsed)
}
