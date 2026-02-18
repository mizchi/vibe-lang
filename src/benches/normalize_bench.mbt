///|
fn gen_normalize_large_source(def_count : Int) -> String {
  let buf = StringBuilder::new()
  for i in 0..<def_count {
    let i_str = i.to_string()
    let prev = if i == 0 { "0" } else { "v" + (i - 1).to_string() }
    buf.write_string(
      "let f" + i_str + " = (x: Int) -> Int { x + " + i_str + " }\n",
    )
    buf.write_string("let v" + i_str + " = f" + i_str + "(" + prev + ")\n")
  }
  buf.write_string("v" + (def_count - 1).to_string() + "\n")
  buf.to_string()
}

///|
fn normalize_bench_parse(source : String) -> @core.Module {
  try @parser.parse_ast(source) catch {
    e => abort("parse failed: " + e.to_string())
  } noraise {
    ast => ast
  }
}

///|
test "bench: normalize.module.small" (b : @bench.T) {
  let ast = normalize_bench_parse(sample_script)
  b.bench(fn() { b.keep(@core.normalize_module(ast)) })
}

///|
test "bench: normalize.module.large" (b : @bench.T) {
  let ast = normalize_bench_parse(gen_normalize_large_source(400))
  b.bench(fn() { b.keep(@core.normalize_module(ast)) })
}

///|
test "bench: normalize.canonical_sort.large" (b : @bench.T) {
  let ast = normalize_bench_parse(gen_normalize_large_source(400))
  b.bench(fn() { b.keep(@core.canonical_sort_stmts(ast.stmts)) })
}

///|
test "bench: normalize.hash_module.small" (b : @bench.T) {
  let ast = normalize_bench_parse(sample_script)
  let normalized = @core.normalize_module(ast)
  b.bench(fn() { b.keep(@core.hash_module(normalized)) })
}

///|
test "bench: normalize.hash_module.large" (b : @bench.T) {
  let ast = normalize_bench_parse(gen_normalize_large_source(400))
  let normalized = @core.normalize_module(ast)
  b.bench(fn() { b.keep(@core.hash_module(normalized)) })
}

///|
test "bench: normalize.serialize.large" (b : @bench.T) {
  let ast = normalize_bench_parse(gen_normalize_large_source(400))
  let normalized = @core.normalize_module(ast)
  b.bench(fn() { b.keep(@core.serialize_module(normalized)) })
}

///|
test "bench: normalize.git_blob_hash.large" (b : @bench.T) {
  let ast = normalize_bench_parse(gen_normalize_large_source(400))
  let normalized = @core.normalize_module(ast)
  let json = @core.serialize_module(normalized)
  b.bench(fn() { b.keep(@core.git_blob_hash_string(json)) })
}

///|
test "bench: normalize.sha1_x_crypto.large" (b : @bench.T) {
  let ast = normalize_bench_parse(gen_normalize_large_source(400))
  let normalized = @core.normalize_module(ast)
  let json = @core.serialize_module(normalized)
  let bytes = @utf8.encode(json)
  b.bench(fn() {
    let hasher = @bit.Sha1State::new()
    hasher.update(bytes)
    b.keep(hasher.finish().to_hex())
  })
}

///|
test "bench: normalize.utf8_encode.large" (b : @bench.T) {
  let ast = normalize_bench_parse(gen_normalize_large_source(400))
  let normalized = @core.normalize_module(ast)
  let json = @core.serialize_module(normalized)
  b.bench(fn() { b.keep(@utf8.encode(json)) })
}

///|
test "bench: normalize.sha1_update_string.large" (b : @bench.T) {
  let ast = normalize_bench_parse(gen_normalize_large_source(400))
  let normalized = @core.normalize_module(ast)
  let json = @core.serialize_module(normalized)
  // Use update_string to skip utf8.encode allocation
  let header = "blob " + json.length().to_string() + "\u0000"
  b.bench(fn() {
    let hasher = @bit.Sha1State::new()
    hasher.update_string(header)
    hasher.update_string(json)
    b.keep(hasher.finish().to_hex())
  })
}

///|
test "bench: normalize.full_pipeline.large" (b : @bench.T) {
  // parse → normalize → canonical_sort → serialize → hash (full pipeline)
  let source = gen_normalize_large_source(400)
  let ast = normalize_bench_parse(source)
  b.bench(fn() {
    let normalized = @core.normalize_module(ast)
    let sorted = @core.Module::{
      stmts: @core.canonical_sort_stmts(normalized.stmts),
    }
    let json = @core.serialize_module(sorted)
    b.keep(@core.git_blob_hash_string(json))
  })
}
