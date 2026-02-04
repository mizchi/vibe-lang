///|
test "bench: codegen.emit_module_wasm" (b : @bench.T) {
  let ast = @parser.parse_ast(sample_script)
  b.bench(fn() { b.keep(try? @codegen.emit_module_wasm(ast)) })
}

///|
test "bench: codegen.emit_module_wasm_js_string" (b : @bench.T) {
  let ast = @parser.parse_ast(sample_script)
  b.bench(fn() { b.keep(try? @codegen.emit_module_wasm_js_string(ast)) })
}
