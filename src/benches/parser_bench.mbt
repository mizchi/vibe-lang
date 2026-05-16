///|
test "bench: parser.parse_cst" (b : @bench.T) {
  b.bench(fn() { b.keep(@parser.parse_cst(sample_script)) })
}

///|
test "bench: parser.parse_ast" (b : @bench.T) {
  b.bench(fn() { b.keep(try? @parser.parse_ast(sample_script)) })
}

///|
/// Scaling probe for the full `load_sources_recursive` pipeline.
///
/// `vibe check` on a 16 k flat-decl module spends ~8 s in `load`, but a
/// micro-bench of `parser.parse_ast` alone scales linearly at <0.06 s
/// per 8 k decls — so the cost lives elsewhere in the loader. This
/// probe times each step independently:
///
///   parse_us           : `@parser.parse_ast`
///   content_hash_us    : `content_address_hash_string(source)`
///                        (called by db.set_source + db.set_preparsed_ast)
///   structural_hash_us : `HashedModule::new(ast)` → `ast.structural_hash`
///                        (the structural-equality key for AST inputs)
///   set_source_us      : `db.set_source(path, source)`
///   set_preparsed_us   : `db.set_preparsed_ast(path, source, ast)`
///   total_load_us      : sum of the above, the loader's hot path
///                        excluding I/O.
///
/// A doubling factor near 2× per size step means the step is O(N); a
/// factor approaching 4× means O(N²). Hidden behind `VIBE_PARSE_SCALING=1`
/// because the larger sizes can run for tens of seconds in release.
test "load pipeline scaling probe" {
  if @sys.get_env_var("VIBE_PARSE_SCALING") is None {
    return
  }
  let sizes = [1000, 2000, 4000, 8000, 16000]
  @runtime_compile.init_hooks()
  for n in sizes {
    let buf = StringBuilder::new()
    for i in 0..<n {
      buf.write_string("let v_")
      buf.write_string(i.to_string())
      buf.write_string(": Int = ")
      buf.write_string(i.to_string())
      buf.write_char('\n')
    }
    let source = buf.to_string()
    let path = "/tmp/scale_" + n.to_string() + ".vibe"

    // 1. parse_ast
    let t_parse = @bench.monotonic_clock_start()
    let ast = try! @parser.parse_ast(source)
    let parse_us = @bench.monotonic_clock_end(t_parse)

    // 2. content_address_hash_string (called twice per loader pass:
    //    once by db.set_source, once by db.set_preparsed_ast)
    let t_hash = @bench.monotonic_clock_start()
    let _ = @core.content_address_hash_string(source)
    let content_hash_us = @bench.monotonic_clock_end(t_hash)

    // 3. db.set_source — input register + a content hash on its own
    let db = @runtime.VibeDb::new()
    let t_set = @bench.monotonic_clock_start()
    db.set_source(path, source)
    let set_source_us = @bench.monotonic_clock_end(t_set)

    // 4. db.set_preparsed_ast — hash + HashedModule wrap (structural_hash) + 2 inputs
    let t_pp = @bench.monotonic_clock_start()
    db.set_preparsed_ast(path, source, ast)
    let set_preparsed_us = @bench.monotonic_clock_end(t_pp)

    // 5. build_symbol_index — walks every Stmt in the AST and builds
    //    per-symbol signatures; called from sync_graph_head_for_loaded_db
    //    on every check entry.
    let paths : Array[String] = [path]
    let t_sym = @bench.monotonic_clock_start()
    let _sym = @runtime_compile.build_symbol_index(db, paths, skip_types=true)
    let symbol_index_us = @bench.monotonic_clock_end(t_sym)

    // 6. build_advanced_graph_index — wraps build_symbol_index, then
    //    walks every entry and synthesises def-ids / symbol & type maps.
    let t_idx = @bench.monotonic_clock_start()
    let idx = @x_exp.build_advanced_graph_index(
      db, paths, base_commit="", created_at="", skip_types=true,
    )
    let graph_index_us = @bench.monotonic_clock_end(t_idx)

    // 7. Serialize the graph index to JSON + hash — also unconditional
    //    in sync_graph_head_for_loaded_db.
    let t_ser = @bench.monotonic_clock_start()
    let json_text = idx.to_json().stringify()
    let serialize_us = @bench.monotonic_clock_end(t_ser)
    let t_h = @bench.monotonic_clock_start()
    let _ = @core.git_blob_hash_string(json_text)
    let blob_hash_us = @bench.monotonic_clock_end(t_h)

    println(
      "[scale] N=" +
      n.to_string() +
      " parse_us=" +
      parse_us.to_int().to_string() +
      " content_hash_us=" +
      content_hash_us.to_int().to_string() +
      " set_source_us=" +
      set_source_us.to_int().to_string() +
      " set_preparsed_us=" +
      set_preparsed_us.to_int().to_string() +
      " symbol_index_us=" +
      symbol_index_us.to_int().to_string() +
      " graph_index_us=" +
      graph_index_us.to_int().to_string() +
      " serialize_us=" +
      serialize_us.to_int().to_string() +
      " blob_hash_us=" +
      blob_hash_us.to_int().to_string() +
      " json_bytes=" +
      json_text.length().to_string(),
    )
  }
}
