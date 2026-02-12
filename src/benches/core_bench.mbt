///|
test "bench: core.git_blob_hash_string" (b : @bench.T) {
  b.bench(fn() { b.keep(@core.git_blob_hash_string(sample_script)) })
}

///|
test "bench: core.module_ref_from_hash" (b : @bench.T) {
  b.bench(fn() {
    let hash = @core.git_blob_hash_string(sample_script)
    b.keep(@core.module_ref_from_hash(hash))
  })
}

///|
test "bench: core.resolve_qualified" (b : @bench.T) {
  let aliases = sample_aliases()
  b.bench(fn() { b.keep(@core.resolve_qualified("math.add", aliases)) })
}

///|
test "bench: core.import_alias_name" (b : @bench.T) {
  b.bench(fn() { b.keep(@core.import_alias_name("path/to/mod.vibe")) })
}
