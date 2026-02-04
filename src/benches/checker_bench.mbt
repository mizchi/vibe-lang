///|
test "bench: checker.type_check" (b : @bench.T) {
  let ast = @parser.parse_ast(sample_script)
  b.bench(fn() { b.keep(try? @checker.type_check(ast)) })
}
