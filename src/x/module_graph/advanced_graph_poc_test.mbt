///|
fn build_test_graph_index_at(
  path : String,
  source : String,
) -> AdvancedGraphIndex {
  let db = @xsh.XshDb::new()
  db.set_source(path, source)
  build_advanced_graph_index(
    db,
    [path],
    base_commit="deadbeef",
    created_at="2026-02-08T00:00:00Z",
  )
}

///|
fn build_test_graph_index(source : String) -> AdvancedGraphIndex {
  build_test_graph_index_at("/tmp/advanced_graph_poc_test_main.vibe", source)
}

///|
fn remove_file_if_exists(path : String) -> Unit {
  if @os_fs.path_exists(path) {
    @os_fs.remove_file(path) catch {
      _ => ()
    }
  }
}

///|
fn build_graph_index_for_wal(
  db : @xsh.XshDb,
  path : String,
  source : String,
  base_commit : String,
  created_at : String,
) -> AdvancedGraphIndex {
  db.set_source(path, source)
  build_advanced_graph_index(db, [path], base_commit~, created_at~)
}

///|
test "advanced graph poc builds symbol/type indices" {
  let source =
    #|type UserId = Int
    #|let add = (x: Int, y: Int) -> Int { x + y }
    #|let id = (x: UserId) -> UserId { x }
  let index = build_test_graph_index(source)
  assert_eq(index.manifest.base_commit, "deadbeef")
  assert_true(index.manifest.features.length() >= 2)
  let add_defs = index.query_symbol("add")
  assert_eq(add_defs.length(), 1)
  assert_true(add_defs[0].signature.contains("Int"))
  let int_defs = index.query_type("Int")
  assert_true(int_defs.length() >= 2)
  let issues = index.verify()
  assert_eq(issues.length(), 0)
}

///|
test "advanced graph poc module hash uses normalized ast hash" {
  let path = "/tmp/advanced_graph_hash_main.vibe"
  let source =
    #|let id = (x: Int) -> Int { x }
    #|let add = (x: Int, y: Int) -> Int { x + y }
  let db = @xsh.XshDb::new()
  db.set_source(path, source)
  let expected = @core.hash_module(db.ast(path))
  let index = build_advanced_graph_index(
    db,
    [path],
    base_commit="deadbeef",
    created_at="2026-02-08T00:00:00Z",
  )
  let defs = index.query_symbol("id")
  assert_eq(defs.length(), 1)
  assert_eq(defs[0].module_hash, expected)
}

///|
test "advanced graph poc semantic id stable across path rebinding" {
  let source =
    #|let map_id = (xs: Array[Int]) -> Array[Int] { xs }
  let index_a = build_test_graph_index_at("/tmp/path_a.vibe", source)
  let index_b = build_test_graph_index_at("/tmp/path_b.vibe", source)
  let a_defs = index_a.query_symbol("map_id")
  let b_defs = index_b.query_symbol("map_id")
  assert_eq(a_defs.length(), 1)
  assert_eq(b_defs.length(), 1)
  assert_true(a_defs[0].def_id != b_defs[0].def_id)
  assert_eq(
    advanced_graph_semantic_id(a_defs[0]),
    advanced_graph_semantic_id(b_defs[0]),
  )
}

///|
test "advanced graph poc json roundtrip" {
  let source =
    #|let map_id = (xs: Array[Int]) -> Array[Int] { xs }
  let index = build_test_graph_index(source)
  let json = index.to_json()
  let restored = match advanced_graph_index_from_json(json) {
    Ok(v) => v
    Err(err) => fail("json roundtrip failed: " + err)
  }
  assert_eq(restored.query_symbol("map_id").length(), 1)
  assert_true(restored.query_type("Array[Int]").length() >= 1)
  assert_eq(restored.verify().length(), 0)
}

///|
test "advanced graph poc cbor roundtrip" {
  let source =
    #|let map_id = (xs: Array[Int]) -> Array[Int] { xs }
  let index = build_test_graph_index(source)
  let payload = index.to_cbor_bytes()
  let restored = match advanced_graph_index_from_cbor_bytes(payload) {
    Ok(v) => v
    Err(err) => fail("cbor roundtrip failed: " + err)
  }
  assert_eq(restored.query_symbol("map_id").length(), 1)
  assert_true(restored.query_type("Array[Int]").length() >= 1)
  assert_eq(restored.verify().length(), 0)
}

///|
test "advanced graph poc flexbuffer roundtrip" {
  let source =
    #|let map_id = (xs: Array[Int]) -> Array[Int] { xs }
  let index = build_test_graph_index(source)
  let payload = index.to_flexbuffer_bytes()
  let restored = match advanced_graph_index_from_flexbuffer_bytes(payload) {
    Ok(v) => v
    Err(err) => fail("flexbuffer roundtrip failed: " + err)
  }
  assert_eq(restored.query_symbol("map_id").length(), 1)
  assert_true(restored.query_type("Array[Int]").length() >= 1)
  assert_eq(restored.verify().length(), 0)
}

///|
test "advanced graph poc verify detects missing defs" {
  let manifest_obj : Map[String, Json] = {}
  manifest_obj["schema_version"] = Json::number(1.0)
  manifest_obj["base_commit"] = Json::string("demo")
  manifest_obj["created_at"] = Json::string("2026-02-08T00:00:00Z")
  manifest_obj["features"] = Json::array([
    Json::string("symbols"),
    Json::string("types"),
  ])
  manifest_obj["chunk_roots"] = Json::array([])
  let symbol_obj : Map[String, Json] = {}
  symbol_obj["orphan"] = Json::array([Json::string("missing-def-id")])
  let root_obj : Map[String, Json] = {}
  root_obj["manifest"] = Json::object(manifest_obj)
  root_obj["defs"] = Json::array([])
  root_obj["symbol_index"] = Json::object(symbol_obj)
  root_obj["type_index"] = Json::object({})
  let broken = match advanced_graph_index_from_json(Json::object(root_obj)) {
    Ok(v) => v
    Err(err) => fail("broken index parse failed: " + err)
  }
  let issues = broken.verify()
  assert_true(issues.length() >= 1)
  assert_true(issues[0].contains("missing def"))
}

///|
test "advanced graph poc diff/apply roundtrip" {
  let base_source =
    #|let keep = (x: Int) -> Int { x }
    #|let removed = 1
  let next_source =
    #|let keep = (x: Int) -> Int { x + 1 }
    #|let added = 2
  let base = build_test_graph_index(base_source)
  let next = build_test_graph_index(next_source)
  let delta = advanced_graph_diff(base, next)
  let applied = apply_advanced_graph_delta(base, delta)
  assert_eq(applied.query_symbol("added").length(), 1)
  assert_eq(applied.query_symbol("removed").length(), 0)
  assert_true(applied.query_symbol("keep")[0].signature.contains("Int"))
  assert_eq(applied.verify().length(), 0)
}

///|
test "advanced graph poc incremental update no-op for empty changed paths" {
  let source =
    #|let id = (x: Int) -> Int { x }
  let base = build_test_graph_index(source)
  let untouched = update_advanced_graph_index_incremental(
    base,
    @xsh.XshDb::new(),
    [],
  )
  assert_eq(untouched.to_json().stringify(), base.to_json().stringify())
}

///|
test "advanced graph poc incremental update matches full rebuild" {
  let path_a = "/tmp/advanced_graph_inc_a.vibe"
  let path_b = "/tmp/advanced_graph_inc_b.vibe"
  let base_a =
    #|let keep_a = (x: Int) -> Int { x }
    #|let removed_a = 1
  let next_a =
    #|let keep_a = (x: Int) -> Int { x + 1 }
    #|let added_a = 2
  let source_b =
    #|let keep_b = (x: Int) -> Int { x * 2 }
  let db = @xsh.XshDb::new()
  db.set_source(path_a, base_a)
  db.set_source(path_b, source_b)
  let base = build_advanced_graph_index(
    db,
    [path_a, path_b],
    base_commit="base",
    created_at="2026-02-08T00:00:00Z",
  )
  db.set_source(path_a, next_a)
  let incremental = update_advanced_graph_index_incremental(
    base,
    db,
    [path_a],
    base_commit="next",
    created_at="2026-02-08T00:00:01Z",
  )
  let full = build_advanced_graph_index(
    db,
    [path_a, path_b],
    base_commit="next",
    created_at="2026-02-08T00:00:01Z",
  )
  assert_eq(incremental.verify().length(), 0)
  assert_eq(full.verify().length(), 0)
  assert_eq(incremental.to_json().stringify(), full.to_json().stringify())
}

///|
test "advanced graph poc delta cbor/flexbuffer roundtrip" {
  let base_source =
    #|let keep = (x: Int) -> Int { x }
    #|let removed = 1
  let next_source =
    #|let keep = (x: Int) -> Int { x + 1 }
    #|let added = 2
  let base = build_test_graph_index(base_source)
  let next = build_test_graph_index(next_source)
  let delta = advanced_graph_diff(base, next)
  let cbor_payload = delta.to_cbor_bytes()
  let cbor_delta = match advanced_graph_delta_from_cbor_bytes(cbor_payload) {
    Ok(v) => v
    Err(err) => fail("delta cbor roundtrip failed: " + err)
  }
  let cbor_applied = apply_advanced_graph_delta(base, cbor_delta)
  assert_eq(cbor_applied.query_symbol("added").length(), 1)
  assert_eq(cbor_applied.query_symbol("removed").length(), 0)
  assert_eq(cbor_applied.verify().length(), 0)
  let flex_payload = delta.to_flexbuffer_bytes()
  let flex_delta = match
    advanced_graph_delta_from_flexbuffer_bytes(flex_payload) {
    Ok(v) => v
    Err(err) => fail("delta flexbuffer roundtrip failed: " + err)
  }
  let flex_applied = apply_advanced_graph_delta(base, flex_delta)
  assert_eq(flex_applied.query_symbol("added").length(), 1)
  assert_eq(flex_applied.query_symbol("removed").length(), 0)
  assert_eq(flex_applied.verify().length(), 0)
}

///|
test "advanced graph poc remote delta payload smaller than full snapshot" {
  let base_buf = StringBuilder::new()
  for i in 0..<300 {
    base_buf.write_string(
      "let v" + i.to_string() + " = " + i.to_string() + "\n",
    )
  }
  let next_buf = StringBuilder::new()
  for i in 0..<300 {
    let value = if i == 120 { "121" } else { i.to_string() }
    next_buf.write_string("let v" + i.to_string() + " = " + value + "\n")
  }
  next_buf.write_string("let v_extra = 1\n")
  let base_source = base_buf.to_string()
  let next_source = next_buf.to_string()
  let base = build_test_graph_index(base_source)
  let next = build_test_graph_index(next_source)
  let delta = advanced_graph_diff(base, next)
  let restored_delta = match advanced_graph_delta_from_json(delta.to_json()) {
    Ok(v) => v
    Err(err) => fail("delta json roundtrip failed: " + err)
  }
  let full_bytes = next.to_json().stringify().length()
  let delta_bytes = restored_delta.to_json().stringify().length()
  assert_true(delta_bytes < full_bytes)
  let applied = apply_advanced_graph_delta(base, restored_delta)
  let matches = applied.query_symbol("v_extra")
  let mut found = false
  for def in matches {
    if def.name == "v_extra" {
      found = true
      break
    }
  }
  assert_true(found)
}

///|
test "advanced graph poc remote network profiles favor delta" {
  let base_buf = StringBuilder::new()
  for i in 0..<600 {
    base_buf.write_string(
      "let v" + i.to_string() + " = " + i.to_string() + "\n",
    )
  }
  let next_buf = StringBuilder::new()
  for i in 0..<600 {
    let value = if i == 320 { "321" } else { i.to_string() }
    next_buf.write_string("let v" + i.to_string() + " = " + value + "\n")
  }
  next_buf.write_string("let v_extra = 1\n")
  let base = build_test_graph_index(base_buf.to_string())
  let next = build_test_graph_index(next_buf.to_string())
  let delta = advanced_graph_diff(base, next)
  let full_bytes = next.to_json().stringify().length()
  let delta_bytes = delta.to_json().stringify().length()
  assert_true(delta_bytes < full_bytes)
  let lan_full = estimate_transfer_time_ms(full_bytes, 1000.0, 2.0, 1)
  let lan_delta = estimate_transfer_time_ms(delta_bytes, 1000.0, 2.0, 1)
  assert_true(lan_delta < lan_full)
  let ci_full = estimate_transfer_time_ms(full_bytes, 100.0, 30.0, 1)
  let ci_delta = estimate_transfer_time_ms(delta_bytes, 100.0, 30.0, 1)
  assert_true(ci_delta < ci_full)
  let mobile_full = estimate_transfer_time_ms(full_bytes, 10.0, 80.0, 1)
  let mobile_delta = estimate_transfer_time_ms(delta_bytes, 10.0, 80.0, 1)
  assert_true(mobile_delta < mobile_full)
}

///|
test "advanced graph poc remote query reports missing module hashes" {
  let base_source =
    #|let keep = (x: Int) -> Int { x }
  let target_source =
    #|let keep = (x: Int) -> Int { x + 1 }
    #|let v_extra = 1
  let local_index = build_test_graph_index(base_source)
  let remote = build_test_graph_index(target_source)
  let result = advanced_graph_remote_query_symbol(
    local_index, remote, "v_extra",
  )
  assert_eq(result.query, "v_extra")
  assert_eq(result.lane, "symbol")
  assert_eq(result.hits.length(), 1)
  assert_true(result.requested_module_hashes.length() >= 1)
  assert_true(result.missing_module_hashes.length() >= 1)
  let fetched = remote.collect_defs_by_module_hashes(
    result.missing_module_hashes,
  )
  let mut found_extra = false
  for def in fetched {
    if def.name == "v_extra" {
      found_extra = true
      break
    }
  }
  assert_true(found_extra)
}

///|
test "advanced graph poc wal jsonl replay roundtrip" {
  let path = "/tmp/advanced_graph_wal_replay_main.vibe"
  let wal_path = "/tmp/advanced_graph_replay.wal.jsonl"
  remove_file_if_exists(wal_path)
  let db = @xsh.XshDb::new()
  let base_source =
    #|let value = 1
    #|let keep = (x: Int) -> Int { x }
  let next_source =
    #|let value = 2
    #|let keep = (x: Int) -> Int { x }
    #|let added = 3
  let next2_source =
    #|let value = 2
    #|let keep = (x: Int) -> Int { x + 1 }
    #|let added = 3
  let base = build_graph_index_for_wal(
    db, path, base_source, "b0", "2026-02-08T00:00:00Z",
  )
  let next = build_graph_index_for_wal(
    db, path, next_source, "b1", "2026-02-08T00:00:01Z",
  )
  let next2 = build_graph_index_for_wal(
    db, path, next2_source, "b2", "2026-02-08T00:00:02Z",
  )
  let d1 = advanced_graph_diff(base, next)
  let d2 = advanced_graph_diff(next, next2)
  match append_advanced_graph_delta_jsonl(wal_path, d1) {
    Ok(_) => ()
    Err(err) => fail("wal append d1 failed: " + err)
  }
  match append_advanced_graph_delta_jsonl(wal_path, d2) {
    Ok(_) => ()
    Err(err) => fail("wal append d2 failed: " + err)
  }
  let replayed = match replay_advanced_graph_delta_jsonl(base, wal_path) {
    Ok(v) => v
    Err(err) => fail("wal replay failed: " + err)
  }
  assert_eq(replayed.to_json().stringify(), next2.to_json().stringify())
  remove_file_if_exists(wal_path)
}

///|
test "advanced graph poc snapshot plus wal load and compact" {
  let path = "/tmp/advanced_graph_wal_snapshot_main.vibe"
  let snapshot_path = "/tmp/advanced_graph_snapshot.json"
  let wal_path = "/tmp/advanced_graph_snapshot.wal.jsonl"
  remove_file_if_exists(snapshot_path)
  remove_file_if_exists(wal_path)
  let db = @xsh.XshDb::new()
  let base_source =
    #|let value = 1
    #|let keep = (x: Int) -> Int { x }
  let next_source =
    #|let value = 2
    #|let keep = (x: Int) -> Int { x + 1 }
    #|let added = 3
  let base = build_graph_index_for_wal(
    db, path, base_source, "s0", "2026-02-08T00:00:00Z",
  )
  let next = build_graph_index_for_wal(
    db, path, next_source, "s1", "2026-02-08T00:00:01Z",
  )
  let delta = advanced_graph_diff(base, next)
  match write_advanced_graph_index(snapshot_path, base) {
    Ok(_) => ()
    Err(err) => fail("write snapshot failed: " + err)
  }
  match append_advanced_graph_delta_jsonl(wal_path, delta) {
    Ok(_) => ()
    Err(err) => fail("append wal failed: " + err)
  }
  let loaded = match
    load_advanced_graph_index_with_wal(snapshot_path, wal_path) {
    Ok(v) => v
    Err(err) => fail("load with wal failed: " + err)
  }
  assert_eq(loaded.to_json().stringify(), next.to_json().stringify())
  let compacted = match
    compact_advanced_graph_snapshot_wal(snapshot_path, wal_path) {
    Ok(v) => v
    Err(err) => fail("compact wal failed: " + err)
  }
  assert_eq(compacted.to_json().stringify(), next.to_json().stringify())
  let stored = match read_advanced_graph_index(snapshot_path) {
    Ok(v) => v
    Err(err) => fail("read compacted snapshot failed: " + err)
  }
  assert_eq(stored.to_json().stringify(), next.to_json().stringify())
  let wal_content = @os_fs.read_file_to_string(wal_path) catch {
    e => fail("read compacted wal failed: " + e.to_string())
  }
  assert_eq(wal_content.length(), 0)
  remove_file_if_exists(snapshot_path)
  remove_file_if_exists(wal_path)
}

///|
test "advanced graph poc wal batch append and stats" {
  let path = "/tmp/advanced_graph_wal_batch_main.vibe"
  let wal_path = "/tmp/advanced_graph_batch.wal.jsonl"
  remove_file_if_exists(wal_path)
  let db = @xsh.XshDb::new()
  let base_source =
    #|let v = 1
  let next_source =
    #|let v = 2
    #|let added = 1
  let next2_source =
    #|let v = 3
    #|let added = 1
  let base = build_graph_index_for_wal(
    db, path, base_source, "w0", "2026-02-08T00:00:00Z",
  )
  let next = build_graph_index_for_wal(
    db, path, next_source, "w1", "2026-02-08T00:00:01Z",
  )
  let next2 = build_graph_index_for_wal(
    db, path, next2_source, "w2", "2026-02-08T00:00:02Z",
  )
  let d1 = advanced_graph_diff(base, next)
  let d2 = advanced_graph_diff(next, next2)
  match append_advanced_graph_deltas_jsonl(wal_path, [d1, d2]) {
    Ok(_) => ()
    Err(err) => fail("batch append wal failed: " + err)
  }
  let stats = match advanced_graph_wal_stats(wal_path) {
    Ok(v) => v
    Err(err) => fail("wal stats failed: " + err)
  }
  assert_eq(stats.record_count, 2)
  assert_true(stats.byte_size > 0)
  let deltas = match read_advanced_graph_delta_jsonl(wal_path) {
    Ok(v) => v
    Err(err) => fail("wal read records failed: " + err)
  }
  assert_eq(deltas.length(), 2)
  let replayed = match replay_advanced_graph_delta_jsonl(base, wal_path) {
    Ok(v) => v
    Err(err) => fail("wal replay failed: " + err)
  }
  assert_eq(replayed.to_json().stringify(), next2.to_json().stringify())
  remove_file_if_exists(wal_path)
}

///|
test "advanced graph poc wal load with threshold compaction" {
  let path = "/tmp/advanced_graph_wal_compact_main.vibe"
  let snapshot_path = "/tmp/advanced_graph_wal_threshold_snapshot.json"
  let wal_path = "/tmp/advanced_graph_wal_threshold.wal.jsonl"
  remove_file_if_exists(snapshot_path)
  remove_file_if_exists(wal_path)
  let db = @xsh.XshDb::new()
  let base_source =
    #|let v = 1
  let next_source =
    #|let v = 2
    #|let added = 1
  let base = build_graph_index_for_wal(
    db, path, base_source, "c0", "2026-02-08T00:00:00Z",
  )
  let next = build_graph_index_for_wal(
    db, path, next_source, "c1", "2026-02-08T00:00:01Z",
  )
  let delta = advanced_graph_diff(base, next)
  match write_advanced_graph_index(snapshot_path, base) {
    Ok(_) => ()
    Err(err) => fail("write snapshot failed: " + err)
  }
  match append_advanced_graph_delta_jsonl(wal_path, delta) {
    Ok(_) => ()
    Err(err) => fail("append wal failed: " + err)
  }
  let no_compact = match
    load_advanced_graph_index_with_wal_compaction(snapshot_path, wal_path, 2) {
    Ok(v) => v
    Err(err) => fail("load wal without compact failed: " + err)
  }
  assert_false(no_compact.compacted)
  assert_eq(no_compact.wal_stats.record_count, 1)
  assert_eq(no_compact.index.to_json().stringify(), next.to_json().stringify())
  let compacted = match
    load_advanced_graph_index_with_wal_compaction(snapshot_path, wal_path, 1) {
    Ok(v) => v
    Err(err) => fail("load wal with compact failed: " + err)
  }
  assert_true(compacted.compacted)
  assert_eq(compacted.wal_stats.record_count, 0)
  assert_eq(compacted.index.to_json().stringify(), next.to_json().stringify())
  let wal_content = @os_fs.read_file_to_string(wal_path) catch {
    e => fail("read wal content failed: " + e.to_string())
  }
  assert_eq(wal_content.length(), 0)
  remove_file_if_exists(snapshot_path)
  remove_file_if_exists(wal_path)
}
