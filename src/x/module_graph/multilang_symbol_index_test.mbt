///|
fn assert_ok_rows(
  result : Result[Array[GraphIrRow], String],
) -> Array[GraphIrRow] {
  match result {
    Ok(rows) => rows
    Err(err) => abort("row extraction failed: " + err)
  }
}

///|
fn ts_row(
  path : String,
  name : String,
  signature : String,
  start : Int,
  end : Int,
  type_terms : Array[String],
) -> GraphIrRow {
  new_graph_ir_row(
    "typescript",
    path,
    name,
    "function",
    signature,
    start,
    end,
    @core.git_blob_hash_string(path),
    type_terms,
    [],
    [],
    [],
  )
}

///|
test "multilang index supports language-aware symbol query" {
  let vibe_source =
    #|let id = (x: Int) -> Int { x }
  let vibe_rows = assert_ok_rows(
    extract_vibe_graph_ir_rows("/workspace/main.vibe", vibe_source),
  )
  let rows : Array[GraphIrRow] = []
  for row in vibe_rows {
    rows.push(row)
  }
  rows.push(
    ts_row("/workspace/main.ts", "id", "(x: string) => string", 0, 2, ["string"]),
  )
  let index = build_multilang_symbol_index(rows)
  assert_true(index.query_symbol("id").length() >= 2)
  assert_eq(index.query_symbol("id", language_id="vibe").length(), 1)
  assert_eq(index.query_symbol("id", language_id="typescript").length(), 1)
  assert_true(index.symbol_index.contains(multilang_symbol_key("vibe", "id")))
  assert_true(
    index.symbol_index.contains(multilang_symbol_key("typescript", "id")),
  )
}

///|
test "multilang index supports type queries across adapters" {
  let vibe_source =
    #|let map_id = (xs: Array[Int]) -> Array[Int] { xs }
  let vibe_rows = assert_ok_rows(
    extract_vibe_graph_ir_rows("/workspace/types.vibe", vibe_source),
  )
  let rows : Array[GraphIrRow] = []
  for row in vibe_rows {
    rows.push(row)
  }
  rows.push(
    ts_row(
      "/workspace/types.ts",
      "fetchName",
      "(id: string) => Promise[string]",
      10,
      20,
      ["string", "Promise"],
    ),
  )
  let index = build_multilang_symbol_index(rows)
  assert_true(index.query_type("Array", language_id="vibe").length() >= 1)
  assert_eq(index.query_type("Promise").length(), 1)
  assert_eq(index.query_type("string", language_id="typescript").length(), 1)
}

///|
test "multilang index upsert replaces row with same anchor" {
  let old_row = ts_row(
    "/workspace/upsert.ts",
    "mapId",
    "(x: number) => number",
    5,
    25,
    ["number"],
  )
  let new_row = ts_row(
    "/workspace/upsert.ts",
    "mapId",
    "(x: string) => string",
    5,
    25,
    ["string"],
  )
  let base = build_multilang_symbol_index([old_row])
  let next = base.upsert_rows([new_row])
  assert_eq(next.defs.length(), 1)
  assert_eq(next.query_type("number", language_id="typescript").length(), 0)
  assert_eq(next.query_type("string", language_id="typescript").length(), 1)
}
