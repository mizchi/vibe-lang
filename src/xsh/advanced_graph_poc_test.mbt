///|
fn build_test_graph_index(source : String) -> AdvancedGraphIndex {
  let db = XshDb::new()
  let path = "/tmp/advanced_graph_poc_test_main.xsh"
  db.set_source(path, source)
  build_advanced_graph_index(
    db,
    [path],
    base_commit="deadbeef",
    created_at="2026-02-08T00:00:00Z",
  )
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
test "advanced graph poc remote delta payload smaller than full snapshot" {
  let base_buf = StringBuilder::new()
  for i in 0..<300 {
    base_buf.write_string("let v" + i.to_string() + " = " + i.to_string() + "\n")
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
    base_buf.write_string("let v" + i.to_string() + " = " + i.to_string() + "\n")
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
