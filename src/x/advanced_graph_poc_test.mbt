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
  build_test_graph_index_at("/tmp/advanced_graph_poc_test_main.xsh", source)
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
  let path = "/tmp/advanced_graph_hash_main.xsh"
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
  let index_a = build_test_graph_index_at("/tmp/path_a.xsh", source)
  let index_b = build_test_graph_index_at("/tmp/path_b.xsh", source)
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
