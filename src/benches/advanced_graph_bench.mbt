///|
let bench_graph_path = "/bench/advanced_graph.xsh"

///|
fn gen_advanced_graph_source(
  def_count : Int,
  mutate_i : Int?,
  extra_defs : Int,
) -> String {
  let buf = StringBuilder::new()
  buf.write_string("type BenchId = Int\n")
  buf.write_string("struct BenchRow { id: Int; name: String }\n")
  for i in 0..<def_count {
    let i_str = i.to_string()
    let add_value = match mutate_i {
      Some(v) => if v == i { (i + 1).to_string() } else { i_str }
      None => i_str
    }
    buf.write_string(
      "let needle_fn_" +
      i_str +
      " = (x: Int) -> Int { x + " +
      add_value +
      " }\n",
    )
  }
  for i in 0..<extra_defs {
    let i_str = i.to_string()
    buf.write_string(
      "let extra_fn_" + i_str + " = (x: Int) -> Int { x + " + i_str + " }\n",
    )
  }
  buf.write_string(
    "let target = needle_fn_" + (def_count - 1).to_string() + "(1)\n",
  )
  buf.to_string()
}

///|
fn build_graph_index_from_source(
  source : String,
  base_commit : String,
) -> @x_exp.AdvancedGraphIndex {
  let db = @xsh.XshDb::new()
  db.set_source(bench_graph_path, source)
  @x_exp.build_advanced_graph_index(
    db,
    [bench_graph_path],
    base_commit~,
    created_at="2026-02-08T00:00:00Z",
  )
}

///|
fn parse_graph_index_json(source : String) -> @x_exp.AdvancedGraphIndex {
  let parsed = @json.parse(source) catch {
    e => abort("json parse failed: " + e.to_string())
  }
  match @x_exp.advanced_graph_index_from_json(parsed) {
    Ok(index) => index
    Err(err) => abort("graph index decode failed: " + err)
  }
}

///|
fn parse_graph_delta_json(source : String) -> @x_exp.AdvancedGraphDelta {
  let parsed = @json.parse(source) catch {
    e => abort("json parse failed: " + e.to_string())
  }
  match @x_exp.advanced_graph_delta_from_json(parsed) {
    Ok(delta) => delta
    Err(err) => abort("graph delta decode failed: " + err)
  }
}

///|
fn parse_graph_index_cbor(payload : Bytes) -> @x_exp.AdvancedGraphIndex {
  match @x_exp.advanced_graph_index_from_cbor_bytes(payload) {
    Ok(index) => index
    Err(err) => abort("graph index cbor decode failed: " + err)
  }
}

///|
fn parse_graph_delta_cbor(payload : Bytes) -> @x_exp.AdvancedGraphDelta {
  match @x_exp.advanced_graph_delta_from_cbor_bytes(payload) {
    Ok(delta) => delta
    Err(err) => abort("graph delta cbor decode failed: " + err)
  }
}

///|
fn parse_graph_index_flexbuffer(payload : Bytes) -> @x_exp.AdvancedGraphIndex {
  match @x_exp.advanced_graph_index_from_flexbuffer_bytes(payload) {
    Ok(index) => index
    Err(err) => abort("graph index flexbuffer decode failed: " + err)
  }
}

///|
fn parse_graph_delta_flexbuffer(payload : Bytes) -> @x_exp.AdvancedGraphDelta {
  match @x_exp.advanced_graph_delta_from_flexbuffer_bytes(payload) {
    Ok(delta) => delta
    Err(err) => abort("graph delta flexbuffer decode failed: " + err)
  }
}

///|
test "bench: graph_build.current_symbol_index_cold" (b : @bench.T) {
  let source = gen_advanced_graph_source(600, None, 0)
  b.bench(fn() {
    let db = @xsh.XshDb::new()
    db.set_source(bench_graph_path, source)
    let index = @xsh.build_symbol_index(db, [bench_graph_path])
    b.keep(index.entries.length())
  })
}

///|
test "bench: graph_build.advanced_graph_index_cold" (b : @bench.T) {
  let source = gen_advanced_graph_source(600, None, 0)
  b.bench(fn() {
    let db = @xsh.XshDb::new()
    db.set_source(bench_graph_path, source)
    let index = @x_exp.build_advanced_graph_index(
      db,
      [bench_graph_path],
      base_commit="bench",
      created_at="2026-02-08T00:00:00Z",
    )
    b.keep(index.defs.length())
  })
}

///|
test "bench: graph_search.current_cli_like" (b : @bench.T) {
  let source = gen_advanced_graph_source(600, None, 0)
  b.bench(fn() {
    let db = @xsh.XshDb::new()
    db.set_source(bench_graph_path, source)
    let index = @xsh.build_symbol_index(db, [bench_graph_path])
    let matches = index.search("needle_fn_599")
    b.keep(matches.length())
  })
}

///|
test "bench: graph_search.graph_snapshot_query" (b : @bench.T) {
  let source = gen_advanced_graph_source(600, None, 0)
  let index = build_graph_index_from_source(source, "base")
  b.bench(fn() {
    let matches = index.query_symbol("needle_fn_599")
    b.keep(matches.length())
  })
}

///|
test "bench: graph_search.graph_json_load_query" (b : @bench.T) {
  let source = gen_advanced_graph_source(600, None, 0)
  let index = build_graph_index_from_source(source, "base")
  let snapshot_json = index.to_json().stringify()
  b.bench(fn() {
    let loaded = parse_graph_index_json(snapshot_json)
    let matches = loaded.query_symbol("needle_fn_599")
    b.keep(matches.length())
  })
}

///|
test "bench: graph_search.graph_cbor_load_query" (b : @bench.T) {
  let source = gen_advanced_graph_source(600, None, 0)
  let index = build_graph_index_from_source(source, "base")
  let snapshot_cbor = index.to_cbor_bytes()
  b.bench(fn() {
    let loaded = parse_graph_index_cbor(snapshot_cbor)
    let matches = loaded.query_symbol("needle_fn_599")
    b.keep(matches.length())
  })
}

///|
test "bench: graph_search.graph_flexbuffer_load_query" (b : @bench.T) {
  let source = gen_advanced_graph_source(600, None, 0)
  let index = build_graph_index_from_source(source, "base")
  let snapshot_flex = index.to_flexbuffer_bytes()
  b.bench(fn() {
    let loaded = parse_graph_index_flexbuffer(snapshot_flex)
    let matches = loaded.query_symbol("needle_fn_599")
    b.keep(matches.length())
  })
}

///|
test "bench: graph_remote.apply_full_snapshot" (b : @bench.T) {
  let source = gen_advanced_graph_source(600, Some(320), 4)
  let target = build_graph_index_from_source(source, "target")
  let full_payload = target.to_json().stringify()
  b.bench(fn() {
    let loaded = parse_graph_index_json(full_payload)
    b.keep(loaded.defs.length())
  })
}

///|
test "bench: graph_remote.apply_full_snapshot_cbor" (b : @bench.T) {
  let source = gen_advanced_graph_source(600, Some(320), 4)
  let target = build_graph_index_from_source(source, "target")
  let full_payload = target.to_cbor_bytes()
  b.bench(fn() {
    let loaded = parse_graph_index_cbor(full_payload)
    b.keep(loaded.defs.length())
  })
}

///|
test "bench: graph_remote.apply_full_snapshot_flexbuffer" (b : @bench.T) {
  let source = gen_advanced_graph_source(600, Some(320), 4)
  let target = build_graph_index_from_source(source, "target")
  let full_payload = target.to_flexbuffer_bytes()
  b.bench(fn() {
    let loaded = parse_graph_index_flexbuffer(full_payload)
    b.keep(loaded.defs.length())
  })
}

///|
test "bench: graph_remote.apply_delta" (b : @bench.T) {
  let base_source = gen_advanced_graph_source(600, None, 0)
  let target_source = gen_advanced_graph_source(600, Some(320), 4)
  let base = build_graph_index_from_source(base_source, "base")
  let target = build_graph_index_from_source(target_source, "target")
  let delta = @x_exp.advanced_graph_diff(base, target)
  let delta_payload = delta.to_json().stringify()
  b.bench(fn() {
    let loaded_delta = parse_graph_delta_json(delta_payload)
    let applied = @x_exp.apply_advanced_graph_delta(base, loaded_delta)
    b.keep(applied.defs.length())
  })
}

///|
test "bench: graph_remote.apply_delta_cbor" (b : @bench.T) {
  let base_source = gen_advanced_graph_source(600, None, 0)
  let target_source = gen_advanced_graph_source(600, Some(320), 4)
  let base = build_graph_index_from_source(base_source, "base")
  let target = build_graph_index_from_source(target_source, "target")
  let delta = @x_exp.advanced_graph_diff(base, target)
  let delta_payload = delta.to_cbor_bytes()
  b.bench(fn() {
    let loaded_delta = parse_graph_delta_cbor(delta_payload)
    let applied = @x_exp.apply_advanced_graph_delta(base, loaded_delta)
    b.keep(applied.defs.length())
  })
}

///|
test "bench: graph_remote.apply_delta_flexbuffer" (b : @bench.T) {
  let base_source = gen_advanced_graph_source(600, None, 0)
  let target_source = gen_advanced_graph_source(600, Some(320), 4)
  let base = build_graph_index_from_source(base_source, "base")
  let target = build_graph_index_from_source(target_source, "target")
  let delta = @x_exp.advanced_graph_diff(base, target)
  let delta_payload = delta.to_flexbuffer_bytes()
  b.bench(fn() {
    let loaded_delta = parse_graph_delta_flexbuffer(delta_payload)
    let applied = @x_exp.apply_advanced_graph_delta(base, loaded_delta)
    b.keep(applied.defs.length())
  })
}

///|
test "bench: graph_remote.remote_query_symbol_only" (b : @bench.T) {
  let base_source = gen_advanced_graph_source(600, None, 0)
  let target_source = gen_advanced_graph_source(600, Some(320), 4)
  let local_index = build_graph_index_from_source(base_source, "base")
  let remote_index = build_graph_index_from_source(target_source, "target")
  b.bench(fn() {
    let result = @x_exp.advanced_graph_remote_query_symbol(
      local_index, remote_index, "extra_fn_3",
    )
    b.keep(result.hits.length())
  })
}

///|
test "bench: graph_remote.remote_query_symbol_lazy_fetch" (b : @bench.T) {
  let base_source = gen_advanced_graph_source(600, None, 0)
  let target_source = gen_advanced_graph_source(600, Some(320), 4)
  let local_index = build_graph_index_from_source(base_source, "base")
  let remote_index = build_graph_index_from_source(target_source, "target")
  b.bench(fn() {
    let result = @x_exp.advanced_graph_remote_query_symbol(
      local_index, remote_index, "extra_fn_3",
    )
    let fetched = remote_index.collect_defs_by_module_hashes(
      result.missing_module_hashes,
    )
    b.keep(result.hits.length() + fetched.length())
  })
}
