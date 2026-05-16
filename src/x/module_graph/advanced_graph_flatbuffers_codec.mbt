///|
fn fb_sorted_array_map_keys(map : Map[String, Array[String]]) -> Array[String] {
  let keys : Array[String] = []
  for key, _ in map {
    keys.push(key)
  }
  keys.sort()
  keys
}

///|
fn fb_sorted_def_keys(map : Map[String, AdvancedGraphDef]) -> Array[String] {
  let keys : Array[String] = []
  for key, _ in map {
    keys.push(key)
  }
  keys.sort()
  keys
}

///|
fn fb_intern_string(
  pool_values : Array[String],
  pool_index : Map[String, Int],
  value : String,
) -> Int {
  match pool_index.get(value) {
    Some(id) => id
    None => {
      let id = pool_values.length()
      pool_values.push(value)
      pool_index[value] = id
      id
    }
  }
}

///|
fn fb_collect_string_array(
  values : Array[String],
  pool_values : Array[String],
  pool_index : Map[String, Int],
) -> Unit {
  for value in values {
    ignore(fb_intern_string(pool_values, pool_index, value))
  }
}

///|
fn fb_collect_def_strings(
  def : AdvancedGraphDef,
  pool_values : Array[String],
  pool_index : Map[String, Int],
) -> Unit {
  ignore(fb_intern_string(pool_values, pool_index, def.language_id))
  ignore(fb_intern_string(pool_values, pool_index, def.def_id))
  ignore(fb_intern_string(pool_values, pool_index, def.name))
  ignore(fb_intern_string(pool_values, pool_index, def.kind))
  ignore(fb_intern_string(pool_values, pool_index, def.signature))
  ignore(fb_intern_string(pool_values, pool_index, def.path))
  ignore(fb_intern_string(pool_values, pool_index, def.module_hash))
}

///|
fn fb_collect_index_map_strings(
  entries : Map[String, Array[String]],
  pool_values : Array[String],
  pool_index : Map[String, Int],
) -> Unit {
  let keys = fb_sorted_array_map_keys(entries)
  for key in keys {
    ignore(fb_intern_string(pool_values, pool_index, key))
    match entries.get(key) {
      Some(values) => fb_collect_string_array(values, pool_values, pool_index)
      None => ()
    }
  }
}

///|
fn fb_collect_manifest_strings(
  manifest : AdvancedGraphManifest,
  pool_values : Array[String],
  pool_index : Map[String, Int],
) -> Unit {
  ignore(fb_intern_string(pool_values, pool_index, manifest.base_commit))
  ignore(fb_intern_string(pool_values, pool_index, manifest.created_at))
  fb_collect_string_array(manifest.features, pool_values, pool_index)
  fb_collect_string_array(manifest.chunk_roots, pool_values, pool_index)
  fb_collect_string_array(manifest.language_ids, pool_values, pool_index)
}

///|
fn fb_pool_index_or_abort(
  pool_index : Map[String, Int],
  value : String,
  context : String,
) -> Int {
  match pool_index.get(value) {
    Some(id) => id
    None =>
      abort("flatbuffers encode missing string[" + context + "]: " + value)
  }
}

///|
fn fb_build_string_offsets(
  builder : @flatbuffers.Builder,
  pool_values : Array[String],
) -> Array[Int] {
  let offsets : Array[Int] = []
  for value in pool_values {
    let sb = FbStringBuilder::new(builder)
    ignore(sb.set_value(value))
    sb.start()
    offsets.push(sb.end())
  }
  offsets
}

///|
fn fb_build_int_vector_from_strings(
  builder : @flatbuffers.Builder,
  pool_index : Map[String, Int],
  values : Array[String],
  context : String,
) -> Int {
  let out : Array[Int] = []
  for i, value in values {
    out.push(
      fb_pool_index_or_abort(
        pool_index,
        value,
        context + "[" + i.to_string() + "]",
      ),
    )
  }
  builder.create_int32_vector(out)
}

///|
fn fb_build_def_offsets(
  builder : @flatbuffers.Builder,
  defs : Map[String, AdvancedGraphDef],
  pool_index : Map[String, Int],
) -> Array[Int] {
  let offsets : Array[Int] = []
  for key in fb_sorted_def_keys(defs) {
    match defs.get(key) {
      Some(def) => {
        let db = FbDefBuilder::new(builder)
        db.start()
        ignore(
          db.add_def_id(
            fb_pool_index_or_abort(pool_index, def.def_id, "defs.def_id"),
          ),
        )
        ignore(
          db.add_name(fb_pool_index_or_abort(pool_index, def.name, "defs.name")),
        )
        ignore(
          db.add_kind(fb_pool_index_or_abort(pool_index, def.kind, "defs.kind")),
        )
        ignore(
          db.add_signature(
            fb_pool_index_or_abort(pool_index, def.signature, "defs.signature"),
          ),
        )
        ignore(
          db.add_path(fb_pool_index_or_abort(pool_index, def.path, "defs.path")),
        )
        ignore(db.add_start(def.start))
        ignore(db.add_end(def.end))
        ignore(
          db.add_module_hash(
            fb_pool_index_or_abort(
              pool_index,
              def.module_hash,
              "defs.module_hash",
            ),
          ),
        )
        ignore(
          db.add_language_id(
            fb_pool_index_or_abort(
              pool_index,
              def.language_id,
              "defs.language_id",
            ),
          ),
        )
        offsets.push(db.end())
      }
      None => ()
    }
  }
  offsets
}

///|
fn fb_build_index_entry_offsets(
  builder : @flatbuffers.Builder,
  entries : Map[String, Array[String]],
  pool_index : Map[String, Int],
  context : String,
) -> Array[Int] {
  let offsets : Array[Int] = []
  let keys = fb_sorted_array_map_keys(entries)
  for key in keys {
    match entries.get(key) {
      Some(values) => {
        let value_offset = fb_build_int_vector_from_strings(
          builder,
          pool_index,
          values,
          context + ".values." + key,
        )
        let eb = FbIndexEntryBuilder::new(builder)
        ignore(eb.set_values_offset(value_offset))
        eb.start()
        ignore(
          eb.add_key(
            fb_pool_index_or_abort(pool_index, key, context + ".key." + key),
          ),
        )
        offsets.push(eb.end())
      }
      None => ()
    }
  }
  offsets
}

///|
fn fb_string_from_pool(
  pool_values : Array[String],
  id : Int,
  context : String,
) -> Result[String, String] {
  if id < 0 || id >= pool_values.length() {
    return Err(
      context +
      ": string pool index out of range " +
      id.to_string() +
      " / " +
      pool_values.length().to_string(),
    )
  }
  Ok(pool_values[id])
}

///|
fn fb_decode_string_pool_from_index(
  root : FbIndex,
) -> Result[Array[String], String] {
  let pool_values : Array[String] = []
  for i in 0..<root.strings_length() {
    let table = match root.strings_table(i) {
      Some(v) => v
      None => return Err("index.strings[" + i.to_string() + "]: missing table")
    }
    let fb_value = FbString::{ table, }
    pool_values.push(fb_value.value())
  }
  Ok(pool_values)
}

///|
fn fb_decode_string_pool_from_delta(
  root : FbDelta,
) -> Result[Array[String], String] {
  let pool_values : Array[String] = []
  for i in 0..<root.strings_length() {
    let table = match root.strings_table(i) {
      Some(v) => v
      None => return Err("delta.strings[" + i.to_string() + "]: missing table")
    }
    let fb_value = FbString::{ table, }
    pool_values.push(fb_value.value())
  }
  Ok(pool_values)
}

///|
fn fb_decode_string_array_from_index_entry(
  entry : FbIndexEntry,
  pool_values : Array[String],
  context : String,
) -> Result[Array[String], String] {
  let out : Array[String] = []
  for i in 0..<entry.values_length() {
    let value = match
      fb_string_from_pool(
        pool_values,
        entry.values(i),
        context + "[" + i.to_string() + "]",
      ) {
      Ok(v) => v
      Err(err) => return Err(err)
    }
    out.push(value)
  }
  Ok(out)
}

///|
fn fb_decode_string_array_from_index_vector(
  len : Int,
  get : (Int) -> Int,
  pool_values : Array[String],
  context : String,
) -> Result[Array[String], String] {
  let out : Array[String] = []
  for i in 0..<len {
    let value = match
      fb_string_from_pool(
        pool_values,
        get(i),
        context + "[" + i.to_string() + "]",
      ) {
      Ok(v) => v
      Err(err) => return Err(err)
    }
    out.push(value)
  }
  Ok(out)
}

///|
fn fb_sorted_defs_for_delta(
  defs : Array[AdvancedGraphDef],
) -> Array[AdvancedGraphDef] {
  let out : Array[AdvancedGraphDef] = []
  for def in defs {
    let mut inserted = false
    for i in 0..<out.length() {
      if def.def_id < out[i].def_id {
        out.insert(i, def)
        inserted = true
        break
      }
    }
    if !inserted {
      out.push(def)
    }
  }
  out
}

///|
fn fb_sorted_unique_strings(values : Array[String]) -> Array[String] {
  let dedup : Map[String, Bool] = {}
  for value in values {
    dedup[value] = true
  }
  let out : Array[String] = []
  for key, _ in dedup {
    out.push(key)
  }
  out.sort()
  out
}

///|
fn advanced_graph_index_to_flatbuffer_bytes(
  index : AdvancedGraphIndex,
) -> Bytes {
  let pool_values : Array[String] = []
  let pool_index : Map[String, Int] = {}
  fb_collect_manifest_strings(index.manifest, pool_values, pool_index)
  for key in fb_sorted_def_keys(index.defs) {
    match index.defs.get(key) {
      Some(def) => fb_collect_def_strings(def, pool_values, pool_index)
      None => ()
    }
  }
  fb_collect_index_map_strings(index.symbol_index, pool_values, pool_index)
  fb_collect_index_map_strings(index.type_index, pool_values, pool_index)
  let builder = @flatbuffers.Builder::new()
  let features_offset = fb_build_int_vector_from_strings(
    builder,
    pool_index,
    index.manifest.features,
    "index.manifest.features",
  )
  let chunk_roots_offset = fb_build_int_vector_from_strings(
    builder,
    pool_index,
    index.manifest.chunk_roots,
    "index.manifest.chunk_roots",
  )
  let defs_offset = builder.create_offset_vector(
    fb_build_def_offsets(builder, index.defs, pool_index),
  )
  let symbol_index_offset = builder.create_offset_vector(
    fb_build_index_entry_offsets(
      builder,
      index.symbol_index,
      pool_index,
      "index.symbol_index",
    ),
  )
  let type_index_offset = builder.create_offset_vector(
    fb_build_index_entry_offsets(
      builder,
      index.type_index,
      pool_index,
      "index.type_index",
    ),
  )
  let strings_offset = builder.create_offset_vector(
    fb_build_string_offsets(builder, pool_values),
  )
  let language_ids_offset = fb_build_int_vector_from_strings(
    builder,
    pool_index,
    index.manifest.language_ids,
    "index.manifest.language_ids",
  )
  let root = FbIndexBuilder::new(builder)
  ignore(root.set_features_offset(features_offset))
  ignore(root.set_chunk_roots_offset(chunk_roots_offset))
  ignore(root.set_defs_offset(defs_offset))
  ignore(root.set_symbol_index_offset(symbol_index_offset))
  ignore(root.set_type_index_offset(type_index_offset))
  ignore(root.set_strings_offset(strings_offset))
  ignore(root.set_language_ids_offset(language_ids_offset))
  root.start()
  ignore(root.add_schema_version(index.manifest.schema_version))
  ignore(
    root.add_base_commit(
      fb_pool_index_or_abort(
        pool_index,
        index.manifest.base_commit,
        "index.manifest.base_commit",
      ),
    ),
  )
  ignore(
    root.add_created_at(
      fb_pool_index_or_abort(
        pool_index,
        index.manifest.created_at,
        "index.manifest.created_at",
      ),
    ),
  )
  let root_offset = root.end()
  builder.finish(root_offset)
  builder.to_bytes()
}

///|
fn advanced_graph_index_from_flatbuffer_bytes(
  payload : Bytes,
) -> Result[AdvancedGraphIndex, String] {
  let bb = @flatbuffers.ByteBuffer::from_bytes(payload)
  if !bb.verify() {
    return Err("index flatbuffer: invalid byte buffer")
  }
  let root = FbIndex::from_buffer(bb)
  let pool_values = match fb_decode_string_pool_from_index(root) {
    Ok(v) => v
    Err(err) => return Err("index flatbuffer: " + err)
  }
  let base_commit = match
    fb_string_from_pool(
      pool_values,
      root.base_commit(),
      "index.manifest.base_commit",
    ) {
    Ok(v) => v
    Err(err) => return Err("index flatbuffer: " + err)
  }
  let created_at = match
    fb_string_from_pool(
      pool_values,
      root.created_at(),
      "index.manifest.created_at",
    ) {
    Ok(v) => v
    Err(err) => return Err("index flatbuffer: " + err)
  }
  let features = match
    fb_decode_string_array_from_index_vector(
      root.features_length(),
      i => root.features(i),
      pool_values,
      "index.manifest.features",
    ) {
    Ok(v) => v
    Err(err) => return Err("index flatbuffer: " + err)
  }
  let chunk_roots = match
    fb_decode_string_array_from_index_vector(
      root.chunk_roots_length(),
      i => root.chunk_roots(i),
      pool_values,
      "index.manifest.chunk_roots",
    ) {
    Ok(v) => v
    Err(err) => return Err("index flatbuffer: " + err)
  }
  let language_ids = match
    fb_decode_string_array_from_index_vector(
      root.language_ids_length(),
      i => root.language_ids(i),
      pool_values,
      "index.manifest.language_ids",
    ) {
    Ok(v) => v
    Err(_) => ["vibe"]
  }
  let manifest = AdvancedGraphManifest::{
    schema_version: root.schema_version(),
    base_commit,
    created_at,
    features,
    chunk_roots,
    language_ids,
  }
  let defs : Map[String, AdvancedGraphDef] = {}
  for i in 0..<root.defs_length() {
    let table = match root.defs_table(i) {
      Some(v) => v
      None =>
        return Err(
          "index flatbuffer: defs[" + i.to_string() + "] missing table",
        )
    }
    let def_row = FbDef::{ table, }
    let def_id = match
      fb_string_from_pool(
        pool_values,
        def_row.def_id(),
        "index.defs[" + i.to_string() + "].def_id",
      ) {
      Ok(v) => v
      Err(err) => return Err("index flatbuffer: " + err)
    }
    let name = match
      fb_string_from_pool(
        pool_values,
        def_row.name(),
        "index.defs[" + i.to_string() + "].name",
      ) {
      Ok(v) => v
      Err(err) => return Err("index flatbuffer: " + err)
    }
    let kind = match
      fb_string_from_pool(
        pool_values,
        def_row.kind(),
        "index.defs[" + i.to_string() + "].kind",
      ) {
      Ok(v) => v
      Err(err) => return Err("index flatbuffer: " + err)
    }
    let signature = match
      fb_string_from_pool(
        pool_values,
        def_row.signature(),
        "index.defs[" + i.to_string() + "].signature",
      ) {
      Ok(v) => v
      Err(err) => return Err("index flatbuffer: " + err)
    }
    let path = match
      fb_string_from_pool(
        pool_values,
        def_row.path(),
        "index.defs[" + i.to_string() + "].path",
      ) {
      Ok(v) => v
      Err(err) => return Err("index flatbuffer: " + err)
    }
    let module_hash = match
      fb_string_from_pool(
        pool_values,
        def_row.module_hash(),
        "index.defs[" + i.to_string() + "].module_hash",
      ) {
      Ok(v) => v
      Err(err) => return Err("index flatbuffer: " + err)
    }
    let language_id = match
      fb_string_from_pool(
        pool_values,
        def_row.language_id(),
        "index.defs[" + i.to_string() + "].language_id",
      ) {
      Ok(v) => v
      Err(_) => "vibe"
    }
    defs[def_id] = AdvancedGraphDef::{
      language_id,
      def_id,
      name,
      kind,
      signature,
      path,
      start: def_row.start(),
      end: def_row.end(),
      module_hash,
    }
  }
  let symbol_index : Map[String, Array[String]] = {}
  for i in 0..<root.symbol_index_length() {
    let table = match root.symbol_index_table(i) {
      Some(v) => v
      None =>
        return Err(
          "index flatbuffer: symbol_index[" + i.to_string() + "] missing table",
        )
    }
    let entry = FbIndexEntry::{ table, }
    let key = match
      fb_string_from_pool(
        pool_values,
        entry.key(),
        "index.symbol_index[" + i.to_string() + "].key",
      ) {
      Ok(v) => v
      Err(err) => return Err("index flatbuffer: " + err)
    }
    let values = match
      fb_decode_string_array_from_index_entry(
        entry,
        pool_values,
        "index.symbol_index[" + i.to_string() + "].values",
      ) {
      Ok(v) => v
      Err(err) => return Err("index flatbuffer: " + err)
    }
    symbol_index[key] = values
  }
  let type_index : Map[String, Array[String]] = {}
  for i in 0..<root.type_index_length() {
    let table = match root.type_index_table(i) {
      Some(v) => v
      None =>
        return Err(
          "index flatbuffer: type_index[" + i.to_string() + "] missing table",
        )
    }
    let entry = FbIndexEntry::{ table, }
    let key = match
      fb_string_from_pool(
        pool_values,
        entry.key(),
        "index.type_index[" + i.to_string() + "].key",
      ) {
      Ok(v) => v
      Err(err) => return Err("index flatbuffer: " + err)
    }
    let values = match
      fb_decode_string_array_from_index_entry(
        entry,
        pool_values,
        "index.type_index[" + i.to_string() + "].values",
      ) {
      Ok(v) => v
      Err(err) => return Err("index flatbuffer: " + err)
    }
    type_index[key] = values
  }
  Ok(AdvancedGraphIndex::{ manifest, defs, symbol_index, type_index })
}

///|
fn advanced_graph_delta_to_flatbuffer_bytes(
  delta : AdvancedGraphDelta,
) -> Bytes {
  let pool_values : Array[String] = []
  let pool_index : Map[String, Int] = {}
  fb_collect_manifest_strings(delta.base_manifest, pool_values, pool_index)
  fb_collect_manifest_strings(delta.target_manifest, pool_values, pool_index)
  fb_collect_string_array(delta.removed_def_ids, pool_values, pool_index)
  for def in delta.upsert_defs {
    fb_collect_def_strings(def, pool_values, pool_index)
  }
  fb_collect_index_map_strings(delta.symbol_upserts, pool_values, pool_index)
  fb_collect_string_array(delta.symbol_removes, pool_values, pool_index)
  fb_collect_index_map_strings(delta.type_upserts, pool_values, pool_index)
  fb_collect_string_array(delta.type_removes, pool_values, pool_index)
  let builder = @flatbuffers.Builder::new()
  let base_features_offset = fb_build_int_vector_from_strings(
    builder,
    pool_index,
    delta.base_manifest.features,
    "delta.base.features",
  )
  let base_chunk_roots_offset = fb_build_int_vector_from_strings(
    builder,
    pool_index,
    delta.base_manifest.chunk_roots,
    "delta.base.chunk_roots",
  )
  let target_features_offset = fb_build_int_vector_from_strings(
    builder,
    pool_index,
    delta.target_manifest.features,
    "delta.target.features",
  )
  let target_chunk_roots_offset = fb_build_int_vector_from_strings(
    builder,
    pool_index,
    delta.target_manifest.chunk_roots,
    "delta.target.chunk_roots",
  )
  let removed_def_ids_offset = fb_build_int_vector_from_strings(
    builder,
    pool_index,
    delta.removed_def_ids,
    "delta.removed_def_ids",
  )
  let upsert_defs_map : Map[String, AdvancedGraphDef] = {}
  for def in delta.upsert_defs {
    upsert_defs_map[def.def_id] = def
  }
  let upsert_defs_offset = builder.create_offset_vector(
    fb_build_def_offsets(builder, upsert_defs_map, pool_index),
  )
  let symbol_upserts_offset = builder.create_offset_vector(
    fb_build_index_entry_offsets(
      builder,
      delta.symbol_upserts,
      pool_index,
      "delta.symbol_upserts",
    ),
  )
  let symbol_removes_offset = fb_build_int_vector_from_strings(
    builder,
    pool_index,
    delta.symbol_removes,
    "delta.symbol_removes",
  )
  let type_upserts_offset = builder.create_offset_vector(
    fb_build_index_entry_offsets(
      builder,
      delta.type_upserts,
      pool_index,
      "delta.type_upserts",
    ),
  )
  let type_removes_offset = fb_build_int_vector_from_strings(
    builder,
    pool_index,
    delta.type_removes,
    "delta.type_removes",
  )
  let strings_offset = builder.create_offset_vector(
    fb_build_string_offsets(builder, pool_values),
  )
  let base_language_ids_offset = fb_build_int_vector_from_strings(
    builder,
    pool_index,
    delta.base_manifest.language_ids,
    "delta.base.language_ids",
  )
  let target_language_ids_offset = fb_build_int_vector_from_strings(
    builder,
    pool_index,
    delta.target_manifest.language_ids,
    "delta.target.language_ids",
  )
  let root = FbDeltaBuilder::new(builder)
  ignore(root.set_base_features_offset(base_features_offset))
  ignore(root.set_base_chunk_roots_offset(base_chunk_roots_offset))
  ignore(root.set_target_features_offset(target_features_offset))
  ignore(root.set_target_chunk_roots_offset(target_chunk_roots_offset))
  ignore(root.set_removed_def_ids_offset(removed_def_ids_offset))
  ignore(root.set_upsert_defs_offset(upsert_defs_offset))
  ignore(root.set_symbol_upserts_offset(symbol_upserts_offset))
  ignore(root.set_symbol_removes_offset(symbol_removes_offset))
  ignore(root.set_type_upserts_offset(type_upserts_offset))
  ignore(root.set_type_removes_offset(type_removes_offset))
  ignore(root.set_strings_offset(strings_offset))
  ignore(root.set_base_language_ids_offset(base_language_ids_offset))
  ignore(root.set_target_language_ids_offset(target_language_ids_offset))
  root.start()
  ignore(root.add_schema_version(delta.schema_version))
  ignore(root.add_base_schema_version(delta.base_manifest.schema_version))
  ignore(
    root.add_base_base_commit(
      fb_pool_index_or_abort(
        pool_index,
        delta.base_manifest.base_commit,
        "delta.base.base_commit",
      ),
    ),
  )
  ignore(
    root.add_base_created_at(
      fb_pool_index_or_abort(
        pool_index,
        delta.base_manifest.created_at,
        "delta.base.created_at",
      ),
    ),
  )
  ignore(root.add_target_schema_version(delta.target_manifest.schema_version))
  ignore(
    root.add_target_base_commit(
      fb_pool_index_or_abort(
        pool_index,
        delta.target_manifest.base_commit,
        "delta.target.base_commit",
      ),
    ),
  )
  ignore(
    root.add_target_created_at(
      fb_pool_index_or_abort(
        pool_index,
        delta.target_manifest.created_at,
        "delta.target.created_at",
      ),
    ),
  )
  let root_offset = root.end()
  builder.finish(root_offset)
  builder.to_bytes()
}

///|
fn advanced_graph_delta_from_flatbuffer_bytes(
  payload : Bytes,
) -> Result[AdvancedGraphDelta, String] {
  let bb = @flatbuffers.ByteBuffer::from_bytes(payload)
  if !bb.verify() {
    return Err("delta flatbuffer: invalid byte buffer")
  }
  let root = FbDelta::from_buffer(bb)
  let pool_values = match fb_decode_string_pool_from_delta(root) {
    Ok(v) => v
    Err(err) => return Err("delta flatbuffer: " + err)
  }
  let base_commit = match
    fb_string_from_pool(
      pool_values,
      root.base_base_commit(),
      "delta.base.base_commit",
    ) {
    Ok(v) => v
    Err(err) => return Err("delta flatbuffer: " + err)
  }
  let base_created_at = match
    fb_string_from_pool(
      pool_values,
      root.base_created_at(),
      "delta.base.created_at",
    ) {
    Ok(v) => v
    Err(err) => return Err("delta flatbuffer: " + err)
  }
  let base_features = match
    fb_decode_string_array_from_index_vector(
      root.base_features_length(),
      i => root.base_features(i),
      pool_values,
      "delta.base.features",
    ) {
    Ok(v) => v
    Err(err) => return Err("delta flatbuffer: " + err)
  }
  let base_chunk_roots = match
    fb_decode_string_array_from_index_vector(
      root.base_chunk_roots_length(),
      i => root.base_chunk_roots(i),
      pool_values,
      "delta.base.chunk_roots",
    ) {
    Ok(v) => v
    Err(err) => return Err("delta flatbuffer: " + err)
  }
  let base_language_ids = match
    fb_decode_string_array_from_index_vector(
      root.base_language_ids_length(),
      i => root.base_language_ids(i),
      pool_values,
      "delta.base.language_ids",
    ) {
    Ok(v) => v
    Err(_) => ["vibe"]
  }
  let base_manifest = AdvancedGraphManifest::{
    schema_version: root.base_schema_version(),
    base_commit,
    created_at: base_created_at,
    features: base_features,
    chunk_roots: base_chunk_roots,
    language_ids: base_language_ids,
  }
  let target_commit = match
    fb_string_from_pool(
      pool_values,
      root.target_base_commit(),
      "delta.target.base_commit",
    ) {
    Ok(v) => v
    Err(err) => return Err("delta flatbuffer: " + err)
  }
  let target_created_at = match
    fb_string_from_pool(
      pool_values,
      root.target_created_at(),
      "delta.target.created_at",
    ) {
    Ok(v) => v
    Err(err) => return Err("delta flatbuffer: " + err)
  }
  let target_features = match
    fb_decode_string_array_from_index_vector(
      root.target_features_length(),
      i => root.target_features(i),
      pool_values,
      "delta.target.features",
    ) {
    Ok(v) => v
    Err(err) => return Err("delta flatbuffer: " + err)
  }
  let target_chunk_roots = match
    fb_decode_string_array_from_index_vector(
      root.target_chunk_roots_length(),
      i => root.target_chunk_roots(i),
      pool_values,
      "delta.target.chunk_roots",
    ) {
    Ok(v) => v
    Err(err) => return Err("delta flatbuffer: " + err)
  }
  let target_language_ids = match
    fb_decode_string_array_from_index_vector(
      root.target_language_ids_length(),
      i => root.target_language_ids(i),
      pool_values,
      "delta.target.language_ids",
    ) {
    Ok(v) => v
    Err(_) => ["vibe"]
  }
  let target_manifest = AdvancedGraphManifest::{
    schema_version: root.target_schema_version(),
    base_commit: target_commit,
    created_at: target_created_at,
    features: target_features,
    chunk_roots: target_chunk_roots,
    language_ids: target_language_ids,
  }
  let removed_def_ids = match
    fb_decode_string_array_from_index_vector(
      root.removed_def_ids_length(),
      i => root.removed_def_ids(i),
      pool_values,
      "delta.removed_def_ids",
    ) {
    Ok(v) => v
    Err(err) => return Err("delta flatbuffer: " + err)
  }
  let upsert_defs : Array[AdvancedGraphDef] = []
  for i in 0..<root.upsert_defs_length() {
    let table = match root.upsert_defs_table(i) {
      Some(v) => v
      None =>
        return Err(
          "delta flatbuffer: upsert_defs[" + i.to_string() + "] missing table",
        )
    }
    let def_row = FbDef::{ table, }
    let def_id = match
      fb_string_from_pool(
        pool_values,
        def_row.def_id(),
        "delta.upsert_defs[" + i.to_string() + "].def_id",
      ) {
      Ok(v) => v
      Err(err) => return Err("delta flatbuffer: " + err)
    }
    let name = match
      fb_string_from_pool(
        pool_values,
        def_row.name(),
        "delta.upsert_defs[" + i.to_string() + "].name",
      ) {
      Ok(v) => v
      Err(err) => return Err("delta flatbuffer: " + err)
    }
    let kind = match
      fb_string_from_pool(
        pool_values,
        def_row.kind(),
        "delta.upsert_defs[" + i.to_string() + "].kind",
      ) {
      Ok(v) => v
      Err(err) => return Err("delta flatbuffer: " + err)
    }
    let signature = match
      fb_string_from_pool(
        pool_values,
        def_row.signature(),
        "delta.upsert_defs[" + i.to_string() + "].signature",
      ) {
      Ok(v) => v
      Err(err) => return Err("delta flatbuffer: " + err)
    }
    let path = match
      fb_string_from_pool(
        pool_values,
        def_row.path(),
        "delta.upsert_defs[" + i.to_string() + "].path",
      ) {
      Ok(v) => v
      Err(err) => return Err("delta flatbuffer: " + err)
    }
    let module_hash = match
      fb_string_from_pool(
        pool_values,
        def_row.module_hash(),
        "delta.upsert_defs[" + i.to_string() + "].module_hash",
      ) {
      Ok(v) => v
      Err(err) => return Err("delta flatbuffer: " + err)
    }
    let language_id = match
      fb_string_from_pool(
        pool_values,
        def_row.language_id(),
        "delta.upsert_defs[" + i.to_string() + "].language_id",
      ) {
      Ok(v) => v
      Err(_) => "vibe"
    }
    upsert_defs.push(AdvancedGraphDef::{
      language_id,
      def_id,
      name,
      kind,
      signature,
      path,
      start: def_row.start(),
      end: def_row.end(),
      module_hash,
    })
  }
  let symbol_upserts : Map[String, Array[String]] = {}
  for i in 0..<root.symbol_upserts_length() {
    let table = match root.symbol_upserts_table(i) {
      Some(v) => v
      None =>
        return Err(
          "delta flatbuffer: symbol_upserts[" +
          i.to_string() +
          "] missing table",
        )
    }
    let entry = FbIndexEntry::{ table, }
    let key = match
      fb_string_from_pool(
        pool_values,
        entry.key(),
        "delta.symbol_upserts[" + i.to_string() + "].key",
      ) {
      Ok(v) => v
      Err(err) => return Err("delta flatbuffer: " + err)
    }
    let values = match
      fb_decode_string_array_from_index_entry(
        entry,
        pool_values,
        "delta.symbol_upserts[" + i.to_string() + "].values",
      ) {
      Ok(v) => v
      Err(err) => return Err("delta flatbuffer: " + err)
    }
    symbol_upserts[key] = values
  }
  let symbol_removes = match
    fb_decode_string_array_from_index_vector(
      root.symbol_removes_length(),
      i => root.symbol_removes(i),
      pool_values,
      "delta.symbol_removes",
    ) {
    Ok(v) => v
    Err(err) => return Err("delta flatbuffer: " + err)
  }
  let type_upserts : Map[String, Array[String]] = {}
  for i in 0..<root.type_upserts_length() {
    let table = match root.type_upserts_table(i) {
      Some(v) => v
      None =>
        return Err(
          "delta flatbuffer: type_upserts[" + i.to_string() + "] missing table",
        )
    }
    let entry = FbIndexEntry::{ table, }
    let key = match
      fb_string_from_pool(
        pool_values,
        entry.key(),
        "delta.type_upserts[" + i.to_string() + "].key",
      ) {
      Ok(v) => v
      Err(err) => return Err("delta flatbuffer: " + err)
    }
    let values = match
      fb_decode_string_array_from_index_entry(
        entry,
        pool_values,
        "delta.type_upserts[" + i.to_string() + "].values",
      ) {
      Ok(v) => v
      Err(err) => return Err("delta flatbuffer: " + err)
    }
    type_upserts[key] = values
  }
  let type_removes = match
    fb_decode_string_array_from_index_vector(
      root.type_removes_length(),
      i => root.type_removes(i),
      pool_values,
      "delta.type_removes",
    ) {
    Ok(v) => v
    Err(err) => return Err("delta flatbuffer: " + err)
  }
  Ok(AdvancedGraphDelta::{
    schema_version: root.schema_version(),
    base_manifest,
    target_manifest,
    removed_def_ids,
    upsert_defs: fb_sorted_defs_for_delta(upsert_defs),
    symbol_upserts,
    symbol_removes: fb_sorted_unique_strings(symbol_removes),
    type_upserts,
    type_removes: fb_sorted_unique_strings(type_removes),
  })
}
