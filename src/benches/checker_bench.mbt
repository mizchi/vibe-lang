///|
let bench_type_path = "/bench/typechecker.vibe"

///|
fn gen_large_typecheck_source(def_count : Int) -> String {
  let buf = StringBuilder::new()
  buf.write_string("let identity = [T](x: T) -> T { x }\n")
  for i in 0..<def_count {
    let i_str = i.to_string()
    let prev = if i == 0 { "0" } else { "v" + (i - 1).to_string() }
    buf.write_string(
      "let f" + i_str + " = (x: Int) -> Int { identity(x) + " + i_str + " }\n",
    )
    buf.write_string("let v" + i_str + " = f" + i_str + "(" + prev + ")\n")
  }
  buf.write_string("v" + (def_count - 1).to_string() + "\n")
  buf.to_string()
}

///|
fn gen_trait_bound_source(call_count : Int) -> String {
  let buf = StringBuilder::new()
  buf.write_string("trait Eq\n")
  buf.write_string("trait Hash\n")
  buf.write_string("impl Eq for Int\n")
  buf.write_string("impl [T: Eq + Show] Hash for T\n")
  buf.write_string("let use_hash = [U: Hash](x: U) -> Int { 1 }\n")
  for i in 0..<call_count {
    let i_str = i.to_string()
    let prev = if i == 0 { "1" } else { "h" + (i - 1).to_string() }
    buf.write_string("let h" + i_str + " = use_hash(" + prev + ")\n")
  }
  buf.write_string("h" + (call_count - 1).to_string() + "\n")
  buf.to_string()
}

///|
fn checker_bench_parse(source : String) -> @core.Module {
  try @parser.parse_ast(source) catch {
    e => abort("parse failed: " + e.to_string())
  } noraise {
    ast => ast
  }
}

///|
fn checker_bench_type_check(ast : @core.Module) -> @checker.TypeEnv {
  try @checker.type_check(ast) catch {
    e => abort("type check failed: " + e.to_string())
  } noraise {
    env => env
  }
}

///|
test "bench: checker.type_check.small" (b : @bench.T) {
  let ast = checker_bench_parse(sample_script)
  b.bench(fn() { b.keep(checker_bench_type_check(ast)) })
}

///|
test "bench: checker.type_check.large" (b : @bench.T) {
  let ast = checker_bench_parse(gen_large_typecheck_source(400))
  b.bench(fn() { b.keep(checker_bench_type_check(ast)) })
}

///|
test "bench: checker.type_check.trait_bounds" (b : @bench.T) {
  let ast = checker_bench_parse(gen_trait_bound_source(200))
  b.bench(fn() { b.keep(checker_bench_type_check(ast)) })
}

///|
test "bench: checker.db_types.hot" (b : @bench.T) {
  let db = @xsh.XshDb::new()
  db.set_source(bench_type_path, gen_large_typecheck_source(400))
  db.types(bench_type_path) |> ignore
  b.bench(fn() { b.keep(db.types(bench_type_path).get_scheme("v399")) })
}

///|
test "bench: checker.db_init.cold" (b : @bench.T) {
  b.bench(fn() {
    let db = @xsh.XshDb::new()
    b.keep(db.get_source("/missing"))
  })
}

///|
test "bench: checker.db_types.first_without_db_init" (b : @bench.T) {
  let db = @xsh.XshDb::new()
  let source = gen_large_typecheck_source(400)
  let mut idx = 0
  b.bench(fn() {
    let path = "/bench/typechecker-" + idx.to_string() + ".vibe"
    idx += 1
    db.set_source(path, source)
    b.keep(db.types(path).get_scheme("v399"))
  })
}

///|
test "bench: checker.db_types.cold" (b : @bench.T) {
  let source = gen_large_typecheck_source(400)
  b.bench(fn() {
    let db = @xsh.XshDb::new()
    db.set_source(bench_type_path, source)
    b.keep(db.types(bench_type_path).get_scheme("v399"))
  })
}
