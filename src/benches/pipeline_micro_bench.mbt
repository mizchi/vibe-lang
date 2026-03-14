///|
/// Micro-benchmark: full compile pipeline (parse → check → codegen)
/// Used to identify which stage dominates for various input sizes.

///|
let micro_small_script : String =
  #|let x = 1 + 2
  #|x

///|
let micro_medium_script : String =
  #|let add = (x: Int, y: Int) -> Int { x + y }
  #|let sub = (x: Int, y: Int) -> Int { x - y }
  #|let mul = (x: Int, y: Int) -> Int { x * y }
  #|let fib = (n: Int) -> Int {
  #|  if n < 2 { n } else { add(fib(sub(n, 1)), fib(sub(n, 2))) }
  #|}
  #|fib(10)

///|
let micro_string_heavy_script : String =
  #|let s = "hello world this is a test"
  #|let a = String::substring(s, 0, 5)
  #|let b = String::substring(s, 6, 11)
  #|let c = String::concat(a, b)
  #|let d = String::length(c)
  #|d

///|
let micro_match_script : String =
  #|enum Shape { Circle(Int); Rect(Int, Int); Point }
  #|let area = (s: Shape) -> Int {
  #|  match s {
  #|    Circle(r) => mul(mul(r, r), 3)
  #|    Rect(w, h) => mul(w, h)
  #|    Point => 0
  #|  }
  #|}
  #|area(Circle(5))

///|
let micro_closure_script : String =
  #|let make_adder = (x: Int) -> (y: Int) -> Int { (y: Int) -> Int { add(x, y) } }
  #|let add5 = make_adder(5)
  #|let add10 = make_adder(10)
  #|add(add5(1), add10(2))

///|
test "bench: pipeline.parse.small" (b : @bench.T) {
  b.bench(fn() { b.keep(try? @parser.parse_ast(micro_small_script)) })
}

///|
test "bench: pipeline.parse.medium" (b : @bench.T) {
  b.bench(fn() { b.keep(try? @parser.parse_ast(micro_medium_script)) })
}

///|
test "bench: pipeline.codegen.small" (b : @bench.T) {
  let ast = @parser.parse_ast(micro_small_script)
  b.bench(fn() { b.keep(try? @codegen.emit_module_wasm(ast)) })
}

///|
test "bench: pipeline.codegen.medium" (b : @bench.T) {
  let ast = @parser.parse_ast(micro_medium_script)
  b.bench(fn() { b.keep(try? @codegen.emit_module_wasm(ast)) })
}

///|
test "bench: pipeline.codegen.string_heavy" (b : @bench.T) {
  let ast = @parser.parse_ast(micro_string_heavy_script)
  b.bench(fn() { b.keep(try? @codegen.emit_module_wasm(ast)) })
}

///|
test "bench: pipeline.codegen.match" (b : @bench.T) {
  let ast = @parser.parse_ast(micro_match_script)
  b.bench(fn() { b.keep(try? @codegen.emit_module_wasm(ast)) })
}

///|
test "bench: pipeline.codegen.closure" (b : @bench.T) {
  let ast = @parser.parse_ast(micro_closure_script)
  b.bench(fn() { b.keep(try? @codegen.emit_module_wasm(ast)) })
}

///|
test "bench: pipeline.full.small" (b : @bench.T) {
  b.bench(fn() {
    try @parser.parse_ast(micro_small_script) catch {
      _ => ()
    } noraise {
      ast => b.keep(try? @codegen.emit_module_wasm(ast))
    }
  })
}

///|
test "bench: pipeline.full.medium" (b : @bench.T) {
  b.bench(fn() {
    try @parser.parse_ast(micro_medium_script) catch {
      _ => ()
    } noraise {
      ast => b.keep(try? @codegen.emit_module_wasm(ast))
    }
  })
}
