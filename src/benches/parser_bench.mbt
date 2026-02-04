///|
test "bench: parser.parse_cst" (b : @bench.T) {
  b.bench(fn() { b.keep(@parser.parse_cst(sample_script)) })
}

///|
test "bench: parser.parse_ast" (b : @bench.T) {
  b.bench(fn() { b.keep(try? @parser.parse_ast(sample_script)) })
}
