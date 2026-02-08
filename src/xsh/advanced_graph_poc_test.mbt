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
