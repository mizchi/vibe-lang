///|
let bench_symbol_path = "/bench/symbol_index.vibe"

///|
fn gen_symbol_index_source(def_count : Int) -> String {
  let buf = StringBuilder::new()
  buf.write_string("enum BenchOption[T] { BenchSome(T); BenchNone }\n")
  buf.write_string("type BenchId = Int\n")
  buf.write_string("struct BenchRow { id: Int; name: String }\n")
  buf.write_string("trait BenchTrait\n")
  for i in 0..<def_count {
    let i_str = i.to_string()
    buf.write_string(
      "let bench_fn_" + i_str + " = (x: Int) -> Int { x + " + i_str + " }\n",
    )
  }
  buf.write_string("let bench_value = bench_fn_0(1)\n")
  buf.to_string()
}

///|
fn gen_symbol_index_xsh_query_source(def_count : Int) -> String {
  let buf = StringBuilder::new()
  buf.write_string("enum BenchOption[T] { BenchSome(T); BenchNone }\n")
  buf.write_string("trait BenchEq\n")
  buf.write_string("trait BenchShow\n")
  for i in 0..<def_count {
    let i_str = i.to_string()
    if i % 2 == 0 {
      buf.write_string(
        "let bench_trait_fn_" +
        i_str +
        " = [T: BenchEq + BenchShow](x: T) -> T { x }\n",
      )
    } else {
      buf.write_string(
        "let bench_effect_fn_" +
        i_str +
        " = (x: Int) -> Int with {Error} { x + " +
        i_str +
        " }\n",
      )
    }
  }
  buf.write_string("let bench_xsh_value = BenchSome(42)\n")
  buf.to_string()
}

///|
fn bench_parse(source : String) -> @core.Module {
  try @parser.parse_ast(source) catch {
    e => abort("parse failed: " + e.to_string())
  } noraise {
    ast => ast
  }
}

///|
fn bench_type_check(ast : @core.Module) -> @checker.TypeEnv {
  try @checker.type_check(ast) catch {
    e => abort("type check failed: " + e.to_string())
  } noraise {
    env => env
  }
}

///|
test "bench: symbol_index.build_module_index" (b : @bench.T) {
  let source = gen_symbol_index_source(1000)
  let ast = bench_parse(source)
  let env = bench_type_check(ast)
  b.bench(fn() {
    let index = @xsh.build_symbol_index_for_module(bench_symbol_path, ast, env)
    b.keep(index.entries.length())
  })
}

///|
test "bench: symbol_index.emit_lsif" (b : @bench.T) {
  let source = gen_symbol_index_source(1000)
  let ast = bench_parse(source)
  let env = bench_type_check(ast)
  let index = @xsh.build_symbol_index_for_module(bench_symbol_path, ast, env)
  b.bench(fn() {
    let lines = @xsh.symbol_index_to_lsif_lines(index, fn(path) {
      if path == bench_symbol_path {
        Some(source)
      } else {
        None
      }
    })
    b.keep(lines.length())
  })
}

///|
test "bench: symbol_index.query_xsh_constructor_exact" (b : @bench.T) {
  let source = gen_symbol_index_xsh_query_source(600)
  let ast = bench_parse(source)
  let env = bench_type_check(ast)
  let index = @xsh.build_symbol_index_for_module(bench_symbol_path, ast, env)
  b.bench(fn() {
    let hits = index.find_exact("BenchSome")
    b.keep(hits.length())
  })
}

///|
test "bench: symbol_index.query_xsh_trait_bound_signature" (b : @bench.T) {
  let source = gen_symbol_index_xsh_query_source(600)
  let ast = bench_parse(source)
  let env = bench_type_check(ast)
  let index = @xsh.build_symbol_index_for_module(bench_symbol_path, ast, env)
  b.bench(fn() {
    let hits = index.search("BenchEq + BenchShow")
    b.keep(hits.length())
  })
}

///|
test "bench: symbol_index.query_xsh_effect_signature" (b : @bench.T) {
  let source = gen_symbol_index_xsh_query_source(600)
  let ast = bench_parse(source)
  let env = bench_type_check(ast)
  let index = @xsh.build_symbol_index_for_module(bench_symbol_path, ast, env)
  b.bench(fn() {
    let hits = index.search("with {Error}")
    b.keep(hits.length())
  })
}
