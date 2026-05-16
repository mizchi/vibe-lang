///|
/// POC index manifest that mirrors `refs/bit/index/*` root metadata.
pub struct AdvancedGraphManifest {
  schema_version : Int
  base_commit : String
  created_at : String
  features : Array[String]
  chunk_roots : Array[String]
  language_ids : Array[String]
} derive(Debug, Eq)

///|
/// Flattened definition node for symbol/type lookup.
pub struct AdvancedGraphDef {
  language_id : String
  def_id : String
  name : String
  kind : String
  signature : String
  path : String
  start : Int
  end : Int
  module_hash : String
} derive(Debug, Eq)

///|
/// Single-file sidecar index POC.
pub struct AdvancedGraphIndex {
  manifest : AdvancedGraphManifest
  defs : Map[String, AdvancedGraphDef]
  symbol_index : Map[String, Array[String]]
  type_index : Map[String, Array[String]]
} derive(Debug, Eq)

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
} derive(Debug, Eq)

///|
/// Symbol/type query result used for remote lookup + lazy fetch planning.
pub struct AdvancedGraphRemoteQueryResult {
  query : String
  lane : String
  hits : Array[AdvancedGraphDef]
  requested_module_hashes : Array[String]
  missing_module_hashes : Array[String]
} derive(Debug, Eq)

///|
pub struct AdvancedGraphWalStats {
  record_count : Int
  byte_size : Int
} derive(Debug, Eq)

///|
pub struct AdvancedGraphWalLoadResult {
  index : AdvancedGraphIndex
  wal_stats : AdvancedGraphWalStats
  compacted : Bool
} derive(Debug, Eq)

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
/// O(1) append into a `(key -> [def_id])` index, deferring dedup + sort
/// to `index_map_finalize`.
///
/// The previous `push_index_id` ran `push_unique_string` (linear scan)
/// and `existing.sort()` (O(K log K)) on every insert. When N decls
/// share a signature — which is the common case for `type_index` on
/// real codebases: a flat module with N `let _: Int = …` lines puts all
/// N entries under the same `Int` bucket — that turned a single build
/// into O(N² log N). For N = 16 000 we observed 8.3 s in
/// `build_advanced_graph_index` alone (≈97 % of `vibe check`'s `load`
/// stage); see PR description for the per-stage scaling table.
///
/// During a fresh build each entry produces a fresh def_id (keyed by
/// path|span|name|kind|signature, which is unique per entry), so the
/// dedup never actually triggered. We can append blindly and sort once
/// at the end without changing the public byte representation.
fn index_map_append(
  index_map : Map[String, Array[String]],
  key : String,
  def_id : String,
) -> Unit {
  match index_map.get(key) {
    Some(existing) => existing.push(def_id)
    None => index_map[key] = [def_id]
  }
}

///|
/// Sort + dedup every bucket in `index_map`. Call this once after a
/// build/update loop that used `index_map_append`; the resulting JSON /
/// FlatBuffer serialization is identical to what the old
/// per-insertion `sort()` produced.
fn index_map_finalize(index_map : Map[String, Array[String]]) -> Unit {
  for key, values in index_map {
    if values.length() <= 1 {
      continue
    }
    values.sort()
    let deduped : Array[String] = []
    let mut prev = ""
    let mut have_prev = false
    for v in values {
      if !have_prev || v != prev {
        deduped.push(v)
        prev = v
        have_prev = true
      }
    }
    if deduped.length() != values.length() {
      index_map[key] = deduped
    }
  }
}

///|
fn remove_index_id(
  index_map : Map[String, Array[String]],
  key : String,
  def_id : String,
) -> Unit {
  match index_map.get(key) {
    Some(ids) => {
      let out : Array[String] = []
      for id in ids {
        if id != def_id {
          out.push(id)
        }
      }
      if out.length() == 0 {
        index_map.remove(key)
      } else {
        index_map[key] = out
      }
    }
    None => ()
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
fn module_hash_for_path(
  db : @runtime.VibeDb,
  path : String,
  cache : Map[String, String],
) -> String {
  match cache.get(path) {
    Some(cached) => cached
    None => {
      let hash = @core.hash_module(db.ast(path))
      cache[path] = hash
      hash
    }
  }
}

///|
fn def_id_from_entry(entry : @frontend.SymbolEntry) -> String {
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
/// Stable semantic identifier that ignores path/span rebinding.
pub fn advanced_graph_semantic_id(def : AdvancedGraphDef) -> String {
  let key = def.module_hash +
    "|" +
    def.name +
    "|" +
    def.kind +
    "|" +
    def.signature
  @core.git_blob_hash_string(key)
}

///|
fn graph_def_from_entry(
  db : @runtime.VibeDb,
  entry : @frontend.SymbolEntry,
  hash_cache : Map[String, String],
) -> AdvancedGraphDef {
  let module_hash = module_hash_for_path(db, entry.path, hash_cache)
  let def_id = def_id_from_entry(entry)
  AdvancedGraphDef::{
    language_id: "vibe",
    def_id,
    name: entry.name,
    kind: @frontend.symbol_kind_name(entry.kind),
    signature: entry.signature,
    path: entry.path,
    start: entry.span.start,
    end: entry.span.end,
    module_hash,
  }
}

///|
fn remove_def_from_indexes(
  symbols : Map[String, Array[String]],
  types : Map[String, Array[String]],
  def : AdvancedGraphDef,
) -> Unit {
  remove_index_id(
    symbols,
    multilang_symbol_key(def.language_id, def.name),
    def.def_id,
  )
  remove_index_id(
    types,
    multilang_type_key(def.language_id, def.signature),
    def.def_id,
  )
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
  db : @runtime.VibeDb,
  paths : Array[String],
  base_commit? : String = "",
  created_at? : String = "",
  skip_types? : Bool = false,
) -> AdvancedGraphIndex {
  let symbol_index = @runtime_compile.build_symbol_index(db, paths, skip_types~)
  let defs : Map[String, AdvancedGraphDef] = {}
  let symbols : Map[String, Array[String]] = {}
  let types : Map[String, Array[String]] = {}
  let hash_cache : Map[String, String] = {}
  for entry in symbol_index.entries {
    let node = graph_def_from_entry(db, entry, hash_cache)
    defs[node.def_id] = node
    index_map_append(
      symbols,
      multilang_symbol_key(node.language_id, node.name),
      node.def_id,
    )
    index_map_append(
      types,
      multilang_type_key(node.language_id, node.signature),
      node.def_id,
    )
  }
  index_map_finalize(symbols)
  index_map_finalize(types)
  let manifest = AdvancedGraphManifest::{
    schema_version: 1,
    base_commit,
    created_at,
    features: default_graph_features(),
    chunk_roots: ["inline://chunk0"],
    language_ids: ["vibe"],
  }
  AdvancedGraphIndex::{
    manifest,
    defs,
    symbol_index: symbols,
    type_index: types,
  }
}

///|
/// Build POC sidecar index from language-agnostic IR rows.
pub fn build_advanced_graph_index_from_ir(
  rows : Array[GraphIrRow],
  base_commit? : String = "",
  created_at? : String = "",
) -> AdvancedGraphIndex {
  let defs : Map[String, AdvancedGraphDef] = {}
  let symbols : Map[String, Array[String]] = {}
  let types : Map[String, Array[String]] = {}
  let lang_set : Map[String, Bool] = {}
  for row in rows {
    let ir_def = ml_normalize_row(row)
    let node = AdvancedGraphDef::{
      language_id: row.language_id,
      def_id: ir_def.def_id,
      name: row.name,
      kind: row.kind,
      signature: row.signature,
      path: row.path,
      start: row.start,
      end: row.end,
      module_hash: row.module_hash,
    }
    defs[node.def_id] = node
    index_map_append(
      symbols,
      multilang_symbol_key(node.language_id, node.name),
      node.def_id,
    )
    index_map_append(
      types,
      multilang_type_key(node.language_id, node.signature),
      node.def_id,
    )
    lang_set[row.language_id] = true
  }
  index_map_finalize(symbols)
  index_map_finalize(types)
  let language_ids : Array[String] = []
  for lang, _ in lang_set {
    language_ids.push(lang)
  }
  language_ids.sort()
  let manifest = AdvancedGraphManifest::{
    schema_version: 1,
    base_commit,
    created_at,
    features: default_graph_features(),
    chunk_roots: ["inline://chunk0"],
    language_ids,
  }
  AdvancedGraphIndex::{
    manifest,
    defs,
    symbol_index: symbols,
    type_index: types,
  }
}

///|
/// Incrementally update index for changed paths only.
/// Unchanged paths retain existing defs/index entries.
pub fn update_advanced_graph_index_incremental(
  base : AdvancedGraphIndex,
  db : @runtime.VibeDb,
  changed_paths : Array[String],
  base_commit? : String = "",
  created_at? : String = "",
) -> AdvancedGraphIndex {
  if changed_paths.length() == 0 {
    return base
  }
  let changed : Map[String, Bool] = {}
  for path in changed_paths {
    changed[path] = true
  }
  let defs = base.defs.copy()
  let symbols = base.symbol_index.copy()
  let types = base.type_index.copy()
  for def_id, def in base.defs {
    if changed.contains(def.path) {
      defs.remove(def_id)
      remove_def_from_indexes(symbols, types, def)
    }
  }
  let next_entries = @runtime_compile.build_symbol_index(db, changed_paths)
  let hash_cache : Map[String, String] = {}
  for entry in next_entries.entries {
    let node = graph_def_from_entry(db, entry, hash_cache)
    defs[node.def_id] = node
    index_map_append(
      symbols,
      multilang_symbol_key(node.language_id, node.name),
      node.def_id,
    )
    index_map_append(
      types,
      multilang_type_key(node.language_id, node.signature),
      node.def_id,
    )
  }
  // After bulk-replacing the entries for the changed paths, sort+dedup
  // every affected bucket so the resulting JSON / FlatBuffer ordering
  // matches the from-scratch build.
  index_map_finalize(symbols)
  index_map_finalize(types)
  let next_base_commit = if base_commit.length() > 0 {
    base_commit
  } else {
    base.manifest.base_commit
  }
  let next_created_at = if created_at.length() > 0 {
    created_at
  } else {
    base.manifest.created_at
  }
  let next_manifest = AdvancedGraphManifest::{
    schema_version: base.manifest.schema_version,
    base_commit: next_base_commit,
    created_at: next_created_at,
    features: base.manifest.features,
    chunk_roots: base.manifest.chunk_roots,
    language_ids: base.manifest.language_ids,
  }
  AdvancedGraphIndex::{
    manifest: next_manifest,
    defs,
    symbol_index: symbols,
    type_index: types,
  }
}

///|
pub fn AdvancedGraphIndex::query_symbol(
  self : AdvancedGraphIndex,
  query : String,
  language_id? : String,
) -> Array[AdvancedGraphDef] {
  let out : Array[AdvancedGraphDef] = []
  let seen : Map[String, Bool] = {}
  if query.length() == 0 {
    let ids = sorted_string_keys_def(self.defs)
    collect_defs_by_ids(self.defs, ids, seen, out)
    return out
  }
  let key = match language_id {
    Some(lang) => multilang_symbol_key(lang, query)
    None => query
  }
  let lang_prefix = match language_id {
    Some(lang) => lang + "::symbol::"
    None => ""
  }
  match self.symbol_index.get(key) {
    Some(ids) => collect_defs_by_ids(self.defs, ids, seen, out)
    None => ()
  }
  for name, ids in self.symbol_index {
    if name == key {
      continue
    }
    if lang_prefix.length() > 0 && !name.has_prefix(lang_prefix) {
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
  language_id? : String,
) -> Array[AdvancedGraphDef] {
  let out : Array[AdvancedGraphDef] = []
  let seen : Map[String, Bool] = {}
  if query.length() == 0 {
    let ids = sorted_string_keys_def(self.defs)
    collect_defs_by_ids(self.defs, ids, seen, out)
    return out
  }
  let key = match language_id {
    Some(lang) => multilang_type_key(lang, query)
    None => query
  }
  let lang_prefix = match language_id {
    Some(lang) => lang + "::type::"
    None => ""
  }
  match self.type_index.get(key) {
    Some(ids) => collect_defs_by_ids(self.defs, ids, seen, out)
    None => ()
  }
  for sig, ids in self.type_index {
    if sig == key {
      continue
    }
    if lang_prefix.length() > 0 && !sig.has_prefix(lang_prefix) {
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
      if !self.defs.contains(def_id) {
        issues.push("symbol index missing def: " + symbol + " -> " + def_id)
      }
    }
  }
  for sig, ids in self.type_index {
    for def_id in ids {
      if !self.defs.contains(def_id) {
        issues.push("type index missing def: " + sig + " -> " + def_id)
      }
    }
  }
  for def_id, def in self.defs {
    let symbol_key = multilang_symbol_key(def.language_id, def.name)
    let mut has_symbol_link = false
    match self.symbol_index.get(symbol_key) {
      Some(ids) =>
        for id in ids {
          if id == def_id {
            has_symbol_link = true
            break
          }
        }
      None => ()
    }
    if !has_symbol_link {
      issues.push(
        "def missing symbol link: " + def_id + " (" + symbol_key + ")",
      )
    }
    let type_key = multilang_type_key(def.language_id, def.signature)
    let mut has_type_link = false
    match self.type_index.get(type_key) {
      Some(ids) =>
        for id in ids {
          if id == def_id {
            has_type_link = true
            break
          }
        }
      None => ()
    }
    if !has_type_link {
      issues.push("def missing type link: " + def_id + " (" + type_key + ")")
    }
  }
  issues
}

///|
/// Build a deduplicated set of module hashes contained in this index.
pub fn AdvancedGraphIndex::collect_module_hashes(
  self : AdvancedGraphIndex,
) -> Map[String, Bool] {
  let hashes : Map[String, Bool] = {}
  for _, def in self.defs {
    hashes[def.module_hash] = true
  }
  hashes
}

///|
/// Collect defs that belong to any of the requested module hashes.
pub fn AdvancedGraphIndex::collect_defs_by_module_hashes(
  self : AdvancedGraphIndex,
  module_hashes : Array[String],
) -> Array[AdvancedGraphDef] {
  let wanted : Map[String, Bool] = {}
  for hash in module_hashes {
    wanted[hash] = true
  }
  let out : Array[AdvancedGraphDef] = []
  for def_id in sorted_string_keys_def(self.defs) {
    match self.defs.get(def_id) {
      Some(def) => if wanted.contains(def.module_hash) { out.push(def) }
      None => ()
    }
  }
  out
}

///|
fn remote_query_from_hits(
  local_index : AdvancedGraphIndex,
  query : String,
  lane : String,
  hits : Array[AdvancedGraphDef],
) -> AdvancedGraphRemoteQueryResult {
  let local_hashes = local_index.collect_module_hashes()
  let requested_hashes : Array[String] = []
  for def in hits {
    requested_hashes.push(def.module_hash)
  }
  let requested_module_hashes = sorted_unique_strings(requested_hashes)
  let missing_module_hashes : Array[String] = []
  for hash in requested_module_hashes {
    if !local_hashes.contains(hash) {
      missing_module_hashes.push(hash)
    }
  }
  AdvancedGraphRemoteQueryResult::{
    query,
    lane,
    hits,
    requested_module_hashes,
    missing_module_hashes,
  }
}

///|
/// Query remote symbol index and compute missing module hashes for lazy fetch.
pub fn advanced_graph_remote_query_symbol(
  local_index : AdvancedGraphIndex,
  remote_index : AdvancedGraphIndex,
  query : String,
) -> AdvancedGraphRemoteQueryResult {
  remote_query_from_hits(
    local_index,
    query,
    "symbol",
    remote_index.query_symbol(query),
  )
}

///|
/// Query remote type index and compute missing module hashes for lazy fetch.
pub fn advanced_graph_remote_query_type(
  local_index : AdvancedGraphIndex,
  remote_index : AdvancedGraphIndex,
  query : String,
) -> AdvancedGraphRemoteQueryResult {
  remote_query_from_hits(
    local_index,
    query,
    "type",
    remote_index.query_type(query),
  )
}

///|
fn advanced_graph_index_keys(
  index : Map[String, Array[String]],
) -> Array[String] {
  let keys : Array[String] = []
  for key, _ in index {
    keys.push(key)
  }
  keys.sort()
  keys
}

///|
fn sorted_defs_for_delta(
  defs : Array[AdvancedGraphDef],
) -> Array[AdvancedGraphDef] {
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
    if !target.defs.contains(def_id) {
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
    if !target.symbol_index.contains(key) {
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
    if !target.type_index.contains(key) {
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
  if !advanced_graph_manifest_equal(delta.base_manifest, base.manifest) {
    next_manifest = AdvancedGraphManifest::{
      schema_version: base.manifest.schema_version,
      base_commit: base.manifest.base_commit,
      created_at: base.manifest.created_at,
      features: base.manifest.features,
      chunk_roots: base.manifest.chunk_roots,
      language_ids: base.manifest.language_ids,
    }
  }
  AdvancedGraphIndex::{
    manifest: next_manifest,
    defs,
    symbol_index,
    type_index,
  }
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
fn parse_json_string_array(
  json : Json,
  context : String,
) -> Result[Array[String], String] {
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
fn sorted_json_object_keys(obj : Map[String, Json]) -> Array[String] {
  let keys : Array[String] = []
  for key, _ in obj {
    keys.push(key)
  }
  keys.sort()
  keys
}

///|
fn json_to_cbor_value(json : Json) -> @cbor.CborValue {
  match json {
    Json::Null => @cbor.vnull()
    Json::True => @cbor.vbool(true)
    Json::False => @cbor.vbool(false)
    Json::Number(value, ..) => {
      let int_value = value.to_int()
      if int_value.to_double() == value {
        @cbor.vint(int_value.to_int64())
      } else {
        @cbor.vdouble(value)
      }
    }
    Json::String(value) => @cbor.vstring(value)
    Json::Array(items) => {
      let out : Array[@cbor.CborValue] = []
      for item in items {
        out.push(json_to_cbor_value(item))
      }
      @cbor.varray(out)
    }
    Json::Object(obj) => {
      let out : Array[(@cbor.CborValue, @cbor.CborValue)] = []
      for key in sorted_json_object_keys(obj) {
        match obj.get(key) {
          Some(value) =>
            out.push((@cbor.vstring(key), json_to_cbor_value(value)))
          None => ()
        }
      }
      @cbor.vmap(out)
    }
  }
}

///|
fn cbor_value_to_json(
  value : @cbor.CborValue,
  context : String,
) -> Result[Json, String] {
  match value {
    @cbor.CborValue::VNull => Ok(Json::null())
    @cbor.CborValue::VUndefined => Ok(Json::null())
    @cbor.CborValue::VBool(v) => Ok(Json::boolean(v))
    @cbor.CborValue::VInt(v) => Ok(Json::number(v.to_double()))
    @cbor.CborValue::VUInt(v) => Ok(Json::number(v.to_double()))
    @cbor.CborValue::VDouble(v) => Ok(Json::number(v))
    @cbor.CborValue::VString(v) => Ok(Json::string(v))
    @cbor.CborValue::VBytes(_) => Err(context + ": cbor bytes unsupported")
    @cbor.CborValue::VArray(items) => {
      let out : Array[Json] = []
      for i, item in items {
        let parsed = match
          cbor_value_to_json(item, context + "[" + i.to_string() + "]") {
          Ok(v) => v
          Err(err) => return Err(err)
        }
        out.push(parsed)
      }
      Ok(Json::array(out))
    }
    @cbor.CborValue::VMap(entries) => {
      let obj : Map[String, Json] = {}
      for i, entry in entries {
        let key = match entry.0 {
          @cbor.CborValue::VString(v) => v
          _ =>
            return Err(
              context + "[" + i.to_string() + "]: cbor map key must be string",
            )
        }
        let parsed = match cbor_value_to_json(entry.1, context + "." + key) {
          Ok(v) => v
          Err(err) => return Err(err)
        }
        obj[key] = parsed
      }
      Ok(Json::object(obj))
    }
    @cbor.CborValue::VTag(_, inner) => cbor_value_to_json(inner, context)
  }
}

///|
fn json_to_cbor_bytes(json : Json) -> Bytes {
  @cbor.encode(json_to_cbor_value(json))
}

///|
fn json_from_cbor_bytes(payload : Bytes) -> Result[Json, String] {
  let decoded = @cbor.decode(payload) catch {
    _ => return Err("decode cbor failed")
  }
  cbor_value_to_json(decoded, "root")
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
  item["language_id"] = Json::string(def.language_id)
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
  let language_id = match get_object_string_field(obj, "language_id", context) {
    Ok(v) => v
    Err(_) => "vibe"
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
    language_id,
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
  obj["language_ids"] = json_string_array(manifest.language_ids)
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
  let schema_version = match
    get_object_int_field(obj, "schema_version", context) {
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
  let language_ids = match get_object_field(obj, "language_ids", context) {
    Ok(v) =>
      match parse_json_string_array(v, context + ".language_ids") {
        Ok(items) => items
        Err(err) => return Err(err)
      }
    Err(_) => ["vibe"]
  }
  Ok(AdvancedGraphManifest::{
    schema_version,
    base_commit,
    created_at,
    features,
    chunk_roots,
    language_ids,
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
pub fn advanced_graph_index_from_json(
  json : Json,
) -> Result[AdvancedGraphIndex, String] {
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
  Ok(AdvancedGraphIndex::{ manifest, defs, symbol_index, type_index })
}

///|
pub fn AdvancedGraphIndex::to_cbor_bytes(self : AdvancedGraphIndex) -> Bytes {
  json_to_cbor_bytes(self.to_json())
}

///|
pub fn advanced_graph_index_from_cbor_bytes(
  payload : Bytes,
) -> Result[AdvancedGraphIndex, String] {
  let parsed = match json_from_cbor_bytes(payload) {
    Ok(v) => v
    Err(err) => return Err("index cbor: " + err)
  }
  advanced_graph_index_from_json(parsed)
}

///|
pub fn AdvancedGraphIndex::to_flexbuffer_bytes(
  self : AdvancedGraphIndex,
) -> Bytes {
  advanced_graph_index_to_flatbuffer_bytes(self)
}

///|
pub fn advanced_graph_index_from_flexbuffer_bytes(
  payload : Bytes,
) -> Result[AdvancedGraphIndex, String] {
  advanced_graph_index_from_flatbuffer_bytes(payload)
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
pub fn read_advanced_graph_index(
  path : String,
) -> Result[AdvancedGraphIndex, String] {
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
pub fn advanced_graph_delta_from_json(
  json : Json,
) -> Result[AdvancedGraphDelta, String] {
  let root = match json {
    Json::Object(obj) => obj
    _ => return Err("advanced graph delta json: root must be object")
  }
  let schema_version = match
    get_object_int_field(root, "schema_version", "delta.root") {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let base_manifest = match
    get_object_field(root, "base_manifest", "delta.root") {
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
  let type_upserts = match
    get_object_field(root, "type_upserts", "delta.root") {
    Ok(v) =>
      match parse_string_array_map(v, "delta.root.type_upserts") {
        Ok(map) => map
        Err(err) => return Err(err)
      }
    Err(err) => return Err(err)
  }
  let type_removes = match
    get_object_field(root, "type_removes", "delta.root") {
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

///|
pub fn AdvancedGraphDelta::to_cbor_bytes(self : AdvancedGraphDelta) -> Bytes {
  json_to_cbor_bytes(self.to_json())
}

///|
pub fn advanced_graph_delta_from_cbor_bytes(
  payload : Bytes,
) -> Result[AdvancedGraphDelta, String] {
  let parsed = match json_from_cbor_bytes(payload) {
    Ok(v) => v
    Err(err) => return Err("delta cbor: " + err)
  }
  advanced_graph_delta_from_json(parsed)
}

///|
pub fn AdvancedGraphDelta::to_flexbuffer_bytes(
  self : AdvancedGraphDelta,
) -> Bytes {
  advanced_graph_delta_to_flatbuffer_bytes(self)
}

///|
pub fn advanced_graph_delta_from_flexbuffer_bytes(
  payload : Bytes,
) -> Result[AdvancedGraphDelta, String] {
  advanced_graph_delta_from_flatbuffer_bytes(payload)
}

///|
priv struct AdvancedGraphWalRecord {
  line_no : Int
  delta : AdvancedGraphDelta
}

///|
fn advanced_graph_wal_record_to_json(delta : AdvancedGraphDelta) -> Json {
  let obj : Map[String, Json] = {}
  obj["record_version"] = ag_json_int(1)
  obj["record_kind"] = Json::string("delta")
  obj["delta"] = delta.to_json()
  Json::object(obj)
}

///|
fn parse_advanced_graph_wal_record(
  record : Json,
  line_no : Int,
) -> Result[AdvancedGraphDelta, String] {
  let context = "wal line " + line_no.to_string()
  let root = match record {
    Json::Object(obj) => obj
    _ => return Err(context + ": record must be object")
  }
  if !root.contains("record_kind") {
    return match advanced_graph_delta_from_json(record) {
      Ok(delta) => Ok(delta)
      Err(err) => Err(context + ": " + err)
    }
  }
  let record_version = match
    get_object_int_field(root, "record_version", context) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  if record_version != 1 {
    return Err(
      context + ": unsupported record_version: " + record_version.to_string(),
    )
  }
  let record_kind = match
    get_object_string_field(root, "record_kind", context) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  if record_kind != "delta" {
    return Err(context + ": unsupported record_kind: " + record_kind)
  }
  let delta_json = match get_object_field(root, "delta", context) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  match advanced_graph_delta_from_json(delta_json) {
    Ok(delta) => Ok(delta)
    Err(err) => Err(context + ": " + err)
  }
}

///|
fn read_advanced_graph_wal_content(wal_path : String) -> Result[String, String] {
  if !@os_fs.path_exists(wal_path) {
    return Ok("")
  }
  let content = @os_fs.read_file_to_string(wal_path) catch {
    e => return Err("wal read: " + e.to_string())
  }
  Ok(content)
}

///|
fn parse_advanced_graph_wal_records(
  content : String,
) -> Result[Array[AdvancedGraphWalRecord], String] {
  let records : Array[AdvancedGraphWalRecord] = []
  let mut line_no = 0
  for line_view in content.split("\n") {
    line_no += 1
    let line = line_view.to_owned().trim().to_owned()
    if line.length() == 0 {
      continue
    }
    let parsed = @json.parse(line) catch {
      e =>
        return Err(
          "wal line " + line_no.to_string() + ": parse json: " + e.to_string(),
        )
    }
    let delta = match parse_advanced_graph_wal_record(parsed, line_no) {
      Ok(v) => v
      Err(err) => return Err(err)
    }
    records.push(AdvancedGraphWalRecord::{ line_no, delta })
  }
  Ok(records)
}

///|
pub fn append_advanced_graph_deltas_jsonl(
  wal_path : String,
  deltas : Array[AdvancedGraphDelta],
) -> Result[Unit, String] {
  if deltas.length() == 0 {
    return Ok(())
  }
  let content = match read_advanced_graph_wal_content(wal_path) {
    Ok(v) => v
    Err(err) => return Err("wal append read: " + err)
  }
  let buf = StringBuilder::new()
  if content.length() > 0 {
    buf.write_string(content)
    if !content.has_suffix("\n") {
      buf.write_char('\n')
    }
  }
  for delta in deltas {
    buf.write_string(advanced_graph_wal_record_to_json(delta).stringify())
    buf.write_char('\n')
  }
  @os_fs.write_string_to_file(wal_path, buf.to_string()) catch {
    e => return Err("wal append write: " + e.to_string())
  }
  Ok(())
}

///|
pub fn append_advanced_graph_delta_jsonl(
  wal_path : String,
  delta : AdvancedGraphDelta,
) -> Result[Unit, String] {
  append_advanced_graph_deltas_jsonl(wal_path, [delta])
}

///|
pub fn read_advanced_graph_delta_jsonl(
  wal_path : String,
) -> Result[Array[AdvancedGraphDelta], String] {
  let content = match read_advanced_graph_wal_content(wal_path) {
    Ok(v) => v
    Err(err) => return Err("wal read records: " + err)
  }
  let records = match parse_advanced_graph_wal_records(content) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let deltas : Array[AdvancedGraphDelta] = []
  for record in records {
    deltas.push(record.delta)
  }
  Ok(deltas)
}

///|
pub fn advanced_graph_wal_stats(
  wal_path : String,
) -> Result[AdvancedGraphWalStats, String] {
  let content = match read_advanced_graph_wal_content(wal_path) {
    Ok(v) => v
    Err(err) => return Err("wal stats: " + err)
  }
  if content.length() == 0 {
    return Ok(AdvancedGraphWalStats::{ record_count: 0, byte_size: 0 })
  }
  let mut count = 0
  for line_view in content.split("\n") {
    let line = line_view.to_owned().trim().to_owned()
    if line.length() > 0 {
      count += 1
    }
  }
  Ok(AdvancedGraphWalStats::{ record_count: count, byte_size: content.length() })
}

///|
pub fn replay_advanced_graph_delta_jsonl(
  base : AdvancedGraphIndex,
  wal_path : String,
) -> Result[AdvancedGraphIndex, String] {
  let content = match read_advanced_graph_wal_content(wal_path) {
    Ok(v) => v
    Err(err) => return Err("wal replay read: " + err)
  }
  if content.length() == 0 {
    return Ok(base)
  }
  let records = match parse_advanced_graph_wal_records(content) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let mut state = base
  for record in records {
    if !advanced_graph_manifest_equal(
          record.delta.base_manifest,
          state.manifest,
        ) {
      return Err(
        "wal line " + record.line_no.to_string() + ": base manifest mismatch",
      )
    }
    state = apply_advanced_graph_delta(state, record.delta)
  }
  Ok(state)
}

///|
pub fn load_advanced_graph_index_with_wal(
  snapshot_path : String,
  wal_path : String,
) -> Result[AdvancedGraphIndex, String] {
  let base = match read_advanced_graph_index(snapshot_path) {
    Ok(v) => v
    Err(err) => return Err("load snapshot: " + err)
  }
  replay_advanced_graph_delta_jsonl(base, wal_path)
}

///|
pub fn compact_advanced_graph_snapshot_wal(
  snapshot_path : String,
  wal_path : String,
) -> Result[AdvancedGraphIndex, String] {
  let latest = match
    load_advanced_graph_index_with_wal(snapshot_path, wal_path) {
    Ok(v) => v
    Err(err) => return Err("compact wal load: " + err)
  }
  match write_advanced_graph_index(snapshot_path, latest) {
    Ok(_) => ()
    Err(err) => return Err("compact wal snapshot write: " + err)
  }
  @os_fs.write_string_to_file(wal_path, "") catch {
    e => return Err("compact wal clear: " + e.to_string())
  }
  Ok(latest)
}

///|
pub fn load_advanced_graph_index_with_wal_compaction(
  snapshot_path : String,
  wal_path : String,
  compact_record_threshold : Int,
) -> Result[AdvancedGraphWalLoadResult, String] {
  if compact_record_threshold <= 0 {
    return Err("load wal compaction: threshold must be > 0")
  }
  let wal_stats = match advanced_graph_wal_stats(wal_path) {
    Ok(v) => v
    Err(err) => return Err("load wal compaction: " + err)
  }
  let index = match
    load_advanced_graph_index_with_wal(snapshot_path, wal_path) {
    Ok(v) => v
    Err(err) => return Err("load wal compaction: " + err)
  }
  if wal_stats.record_count >= compact_record_threshold &&
    wal_stats.record_count > 0 {
    match write_advanced_graph_index(snapshot_path, index) {
      Ok(_) => ()
      Err(err) => return Err("load wal compaction: write snapshot: " + err)
    }
    @os_fs.write_string_to_file(wal_path, "") catch {
      e => return Err("load wal compaction: clear wal: " + e.to_string())
    }
    return Ok(AdvancedGraphWalLoadResult::{
      index,
      wal_stats: AdvancedGraphWalStats::{ record_count: 0, byte_size: 0 },
      compacted: true,
    })
  }
  Ok(AdvancedGraphWalLoadResult::{ index, wal_stats, compacted: false })
}
