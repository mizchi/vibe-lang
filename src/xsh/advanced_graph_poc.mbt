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
/// Incremental transfer payload for remote sync simulation.
pub struct AdvancedGraphDelta {
  schema_version : Int
  base_manifest : AdvancedGraphManifest
  target_manifest : AdvancedGraphManifest
  removed_def_ids : Array[String]
  upsert_defs : Array[AdvancedGraphDef]
  symbol_upserts : Map[String, Array[String]]
  symbol_removes : Array[String]
  type_upserts : Map[String, Array[String]]
  type_removes : Array[String]
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
fn def_id_from_entry(entry : SymbolEntry) -> String {
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
    entry.signature
  @core.git_blob_hash_string(key)
}

///|
fn default_graph_features() -> Array[String] {
  ["symbols", "types", "refs", "imports"]
}

///|
fn advanced_graph_manifest_equal(
  left : AdvancedGraphManifest,
  right : AdvancedGraphManifest,
) -> Bool {
  left == right
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
    let def_id = def_id_from_entry(entry)
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
fn advanced_graph_index_keys(index : Map[String, Array[String]]) -> Array[String] {
  let keys : Array[String] = []
  for key, _ in index {
    keys.push(key)
  }
  keys.sort()
  keys
}

///|
fn sorted_defs_for_delta(defs : Array[AdvancedGraphDef]) -> Array[AdvancedGraphDef] {
  let out = defs.copy()
  out.sort_by(fn(a, b) {
    if a.def_id < b.def_id {
      -1
    } else if a.def_id > b.def_id {
      1
    } else {
      0
    }
  })
  out
}

///|
fn sorted_unique_strings(values : Array[String]) -> Array[String] {
  let seen : Map[String, Bool] = {}
  let out : Array[String] = []
  for value in values {
    if seen.contains(value) {
      continue
    }
    seen[value] = true
    out.push(value)
  }
  out.sort()
  out
}

///|
/// Compute a minimal-ish delta payload between two index snapshots.
pub fn advanced_graph_diff(
  base : AdvancedGraphIndex,
  target : AdvancedGraphIndex,
) -> AdvancedGraphDelta {
  let removed_def_ids : Array[String] = []
  let upsert_defs : Array[AdvancedGraphDef] = []
  for def_id, _ in base.defs {
    if not(target.defs.contains(def_id)) {
      removed_def_ids.push(def_id)
    }
  }
  for def_id, target_def in target.defs {
    match base.defs.get(def_id) {
      Some(base_def) =>
        if base_def != target_def {
          upsert_defs.push(target_def)
        }
      None => upsert_defs.push(target_def)
    }
  }

  let symbol_upserts : Map[String, Array[String]] = {}
  let symbol_removes : Array[String] = []
  for key in advanced_graph_index_keys(target.symbol_index) {
    match target.symbol_index.get(key) {
      Some(target_ids) =>
        match base.symbol_index.get(key) {
          Some(base_ids) =>
            if base_ids != target_ids {
              symbol_upserts[key] = target_ids
            }
          None => symbol_upserts[key] = target_ids
        }
      None => ()
    }
  }
  for key, _ in base.symbol_index {
    if not(target.symbol_index.contains(key)) {
      symbol_removes.push(key)
    }
  }

  let type_upserts : Map[String, Array[String]] = {}
  let type_removes : Array[String] = []
  for key in advanced_graph_index_keys(target.type_index) {
    match target.type_index.get(key) {
      Some(target_ids) =>
        match base.type_index.get(key) {
          Some(base_ids) =>
            if base_ids != target_ids {
              type_upserts[key] = target_ids
            }
          None => type_upserts[key] = target_ids
        }
      None => ()
    }
  }
  for key, _ in base.type_index {
    if not(target.type_index.contains(key)) {
      type_removes.push(key)
    }
  }

  AdvancedGraphDelta::{
    schema_version: 1,
    base_manifest: base.manifest,
    target_manifest: target.manifest,
    removed_def_ids: sorted_unique_strings(removed_def_ids),
    upsert_defs: sorted_defs_for_delta(upsert_defs),
    symbol_upserts,
    symbol_removes: sorted_unique_strings(symbol_removes),
    type_upserts,
    type_removes: sorted_unique_strings(type_removes),
  }
}

///|
/// Apply a delta payload to produce next snapshot.
pub fn apply_advanced_graph_delta(
  base : AdvancedGraphIndex,
  delta : AdvancedGraphDelta,
) -> AdvancedGraphIndex {
  let defs = base.defs.copy()
  let symbol_index = base.symbol_index.copy()
  let type_index = base.type_index.copy()

  for def_id in delta.removed_def_ids {
    defs.remove(def_id)
  }
  for def in delta.upsert_defs {
    defs[def.def_id] = def
  }

  for key in delta.symbol_removes {
    symbol_index.remove(key)
  }
  for key, ids in delta.symbol_upserts {
    symbol_index[key] = ids
  }

  for key in delta.type_removes {
    type_index.remove(key)
  }
  for key, ids in delta.type_upserts {
    type_index[key] = ids
  }

  let mut next_manifest = delta.target_manifest
  if not(advanced_graph_manifest_equal(delta.base_manifest, base.manifest)) {
    next_manifest = AdvancedGraphManifest::{
      schema_version: base.manifest.schema_version,
      base_commit: base.manifest.base_commit,
      created_at: base.manifest.created_at,
      features: base.manifest.features,
      chunk_roots: base.manifest.chunk_roots,
    }
  }
  AdvancedGraphIndex::{ manifest: next_manifest, defs, symbol_index, type_index }
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
/// Estimate one-way transfer time with RTT penalty.
/// - payload bytes are transferred once
/// - RTT penalty is multiplied by logical round trips
pub fn estimate_transfer_time_ms(
  payload_bytes : Int,
  bandwidth_mbps : Double,
  rtt_ms : Double,
  round_trips : Int,
) -> Double {
  let bw = if bandwidth_mbps <= 0.0 { 0.001 } else { bandwidth_mbps }
  let payload_ms = payload_bytes.to_double() * 8.0 / (bw * 1000000.0) * 1000.0
  payload_ms + rtt_ms * round_trips.to_double()
}

///|
fn advanced_graph_def_to_json(def : AdvancedGraphDef) -> Json {
  let item : Map[String, Json] = {}
  item["def_id"] = Json::string(def.def_id)
  item["name"] = Json::string(def.name)
  item["kind"] = Json::string(def.kind)
  item["signature"] = Json::string(def.signature)
  item["path"] = Json::string(def.path)
  item["start"] = ag_json_int(def.start)
  item["end"] = ag_json_int(def.end)
  item["module_hash"] = Json::string(def.module_hash)
  Json::object(item)
}

///|
fn parse_advanced_graph_def(
  item : Json,
  context : String,
) -> Result[AdvancedGraphDef, String] {
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
  let module_hash = match get_object_string_field(obj, "module_hash", context) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  Ok(AdvancedGraphDef::{
    def_id,
    name,
    kind,
    signature,
    path,
    start,
    end,
    module_hash,
  })
}

///|
fn advanced_graph_manifest_to_json(manifest : AdvancedGraphManifest) -> Json {
  let obj : Map[String, Json] = {}
  obj["schema_version"] = ag_json_int(manifest.schema_version)
  obj["base_commit"] = Json::string(manifest.base_commit)
  obj["created_at"] = Json::string(manifest.created_at)
  obj["features"] = json_string_array(manifest.features)
  obj["chunk_roots"] = json_string_array(manifest.chunk_roots)
  Json::object(obj)
}

///|
fn parse_advanced_graph_manifest(
  json : Json,
  context : String,
) -> Result[AdvancedGraphManifest, String] {
  let obj = match json {
    Json::Object(v) => v
    _ => return Err(context + ": must be object")
  }
  let schema_version = match get_object_int_field(obj, "schema_version", context) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let base_commit = match get_object_string_field(obj, "base_commit", context) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let created_at = match get_object_string_field(obj, "created_at", context) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let features = match get_object_field(obj, "features", context) {
    Ok(v) =>
      match parse_json_string_array(v, context + ".features") {
        Ok(items) => items
        Err(err) => return Err(err)
      }
    Err(err) => return Err(err)
  }
  let chunk_roots = match get_object_field(obj, "chunk_roots", context) {
    Ok(v) =>
      match parse_json_string_array(v, context + ".chunk_roots") {
        Ok(items) => items
        Err(err) => return Err(err)
      }
    Err(err) => return Err(err)
  }
  Ok(AdvancedGraphManifest::{
    schema_version,
    base_commit,
    created_at,
    features,
    chunk_roots,
  })
}

///|
pub fn AdvancedGraphIndex::to_json(self : AdvancedGraphIndex) -> Json {
  let defs_arr : Array[Json] = []
  for def_id in sorted_string_keys_def(self.defs) {
    match self.defs.get(def_id) {
      Some(def) => defs_arr.push(advanced_graph_def_to_json(def))
      None => ()
    }
  }

  let out : Map[String, Json] = {}
  out["manifest"] = advanced_graph_manifest_to_json(self.manifest)
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
    Ok(v) =>
      match parse_advanced_graph_manifest(v, "root.manifest") {
        Ok(parsed) => parsed
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
        let parsed = match parse_advanced_graph_def(item, context) {
          Ok(v) => v
          Err(err) => return Err(err)
        }
        defs[parsed.def_id] = parsed
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
    manifest,
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

///|
pub fn AdvancedGraphDelta::to_json(self : AdvancedGraphDelta) -> Json {
  let obj : Map[String, Json] = {}
  obj["schema_version"] = ag_json_int(self.schema_version)
  obj["base_manifest"] = advanced_graph_manifest_to_json(self.base_manifest)
  obj["target_manifest"] = advanced_graph_manifest_to_json(self.target_manifest)
  obj["removed_def_ids"] = json_string_array(self.removed_def_ids)
  let upsert_defs_json : Array[Json] = []
  for def in self.upsert_defs {
    upsert_defs_json.push(advanced_graph_def_to_json(def))
  }
  obj["upsert_defs"] = Json::array(upsert_defs_json)
  obj["symbol_upserts"] = map_string_array_to_json(self.symbol_upserts)
  obj["symbol_removes"] = json_string_array(self.symbol_removes)
  obj["type_upserts"] = map_string_array_to_json(self.type_upserts)
  obj["type_removes"] = json_string_array(self.type_removes)
  Json::object(obj)
}

///|
pub fn advanced_graph_delta_from_json(json : Json) -> Result[AdvancedGraphDelta, String] {
  let root = match json {
    Json::Object(obj) => obj
    _ => return Err("advanced graph delta json: root must be object")
  }
  let schema_version = match get_object_int_field(
    root,
    "schema_version",
    "delta.root",
  ) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let base_manifest = match get_object_field(root, "base_manifest", "delta.root") {
    Ok(v) =>
      match parse_advanced_graph_manifest(v, "delta.root.base_manifest") {
        Ok(m) => m
        Err(err) => return Err(err)
      }
    Err(err) => return Err(err)
  }
  let target_manifest = match
    get_object_field(root, "target_manifest", "delta.root") {
    Ok(v) =>
      match parse_advanced_graph_manifest(v, "delta.root.target_manifest") {
        Ok(m) => m
        Err(err) => return Err(err)
      }
    Err(err) => return Err(err)
  }
  let removed_def_ids = match
    get_object_field(root, "removed_def_ids", "delta.root") {
    Ok(v) =>
      match parse_json_string_array(v, "delta.root.removed_def_ids") {
        Ok(ids) => ids
        Err(err) => return Err(err)
      }
    Err(err) => return Err(err)
  }
  let upsert_defs = match get_object_field(root, "upsert_defs", "delta.root") {
    Ok(Json::Array(items)) => {
      let defs : Array[AdvancedGraphDef] = []
      for i, item in items {
        let context = "delta.root.upsert_defs[" + i.to_string() + "]"
        match parse_advanced_graph_def(item, context) {
          Ok(def) => defs.push(def)
          Err(err) => return Err(err)
        }
      }
      defs
    }
    Ok(_) => return Err("delta.root.upsert_defs: must be array")
    Err(err) => return Err(err)
  }
  let symbol_upserts = match
    get_object_field(root, "symbol_upserts", "delta.root") {
    Ok(v) =>
      match parse_string_array_map(v, "delta.root.symbol_upserts") {
        Ok(map) => map
        Err(err) => return Err(err)
      }
    Err(err) => return Err(err)
  }
  let symbol_removes = match
    get_object_field(root, "symbol_removes", "delta.root") {
    Ok(v) =>
      match parse_json_string_array(v, "delta.root.symbol_removes") {
        Ok(values) => values
        Err(err) => return Err(err)
      }
    Err(err) => return Err(err)
  }
  let type_upserts = match get_object_field(root, "type_upserts", "delta.root") {
    Ok(v) =>
      match parse_string_array_map(v, "delta.root.type_upserts") {
        Ok(map) => map
        Err(err) => return Err(err)
      }
    Err(err) => return Err(err)
  }
  let type_removes = match get_object_field(root, "type_removes", "delta.root") {
    Ok(v) =>
      match parse_json_string_array(v, "delta.root.type_removes") {
        Ok(values) => values
        Err(err) => return Err(err)
      }
    Err(err) => return Err(err)
  }
  Ok(AdvancedGraphDelta::{
    schema_version,
    base_manifest,
    target_manifest,
    removed_def_ids,
    upsert_defs: sorted_defs_for_delta(upsert_defs),
    symbol_upserts,
    symbol_removes: sorted_unique_strings(symbol_removes),
    type_upserts,
    type_removes: sorted_unique_strings(type_removes),
  })
}
