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
  buf.write_string("trait LocalEq\n")
  buf.write_string("trait LocalHash\n")
  buf.write_string("impl LocalEq for Int\n")
  buf.write_string("impl [T: LocalEq + Show] LocalHash for T\n")
  buf.write_string("let use_hash = [U: LocalHash](x: U) -> Int { 1 }\n")
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
  let db = @runtime.VibeDb::new()
  db.set_source(bench_type_path, gen_large_typecheck_source(400))
  db.types(bench_type_path) |> ignore
  b.bench(fn() { b.keep(db.types(bench_type_path).get_scheme("v399")) })
}

///|
test "bench: checker.db_init.cold" (b : @bench.T) {
  b.bench(fn() {
    let db = @runtime.VibeDb::new()
    b.keep(db.get_source("/missing"))
  })
}

///|
test "bench: checker.db_types.first_without_db_init" (b : @bench.T) {
  let db = @runtime.VibeDb::new()
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
    let db = @runtime.VibeDb::new()
    db.set_source(bench_type_path, source)
    b.keep(db.types(bench_type_path).get_scheme("v399"))
  })
}

///|
/// Generate a library module with `def_count` chained exported definitions.
/// `base` varies the initial value so source text changes between invocations.
fn gen_dep_module_source(
  prefix : String,
  def_count : Int,
  base : Int,
) -> String {
  let buf = StringBuilder::new()
  for i in 0..<def_count {
    let name = prefix + i.to_string()
    let prev = if i == 0 {
      base.to_string()
    } else {
      prefix + (i - 1).to_string()
    }
    buf.write_string("export let " + name + " = " + prev + " + 1\n")
  }
  buf.to_string()
}

///|
/// Set up a VibeDb with `dep_count` independent dependency modules,
/// each containing `defs_per_dep` chained definitions, plus a main
/// that imports the last definition from each.
fn setup_cross_module_db(
  dep_count : Int,
  defs_per_dep : Int,
) -> @runtime.VibeDb {
  let db = @runtime.VibeDb::new()
  for d in 0..<dep_count {
    let d_str = d.to_string()
    let path = "./dep" + d_str + ".vibe"
    db.set_source(
      path,
      gen_dep_module_source("d" + d_str + "_", defs_per_dep, 0),
    )
  }
  let main_buf = StringBuilder::new()
  for d in 0..<dep_count {
    let d_str = d.to_string()
    let last_name = "d" + d_str + "_" + (defs_per_dep - 1).to_string()
    main_buf.write_string(
      "import ./dep" + d_str + ".vibe { " + last_name + " }\n",
    )
  }
  main_buf.write_string("let result = ")
  for d in 0..<dep_count {
    let d_str = d.to_string()
    let last_name = "d" + d_str + "_" + (defs_per_dep - 1).to_string()
    if d > 0 {
      main_buf.write_string(" + ")
    }
    main_buf.write_string(last_name)
  }
  main_buf.write_string("\nresult\n")
  db.set_source("main", main_buf.to_string())
  db
}

///|
/// Set up a linear dependency chain: dep0 <- dep1 <- ... <- main
fn setup_chain_db(depth : Int, defs_per_link : Int) -> @runtime.VibeDb {
  let db = @runtime.VibeDb::new()
  // dep0: base module (no imports)
  db.set_source("./dep0.vibe", gen_dep_module_source("c0_", defs_per_link, 0))
  // dep1..depth-1: each imports last def from previous
  for i in 1..<depth {
    let i_str = i.to_string()
    let prev = (i - 1).to_string()
    let prev_last = "c" + prev + "_" + (defs_per_link - 1).to_string()
    let buf = StringBuilder::new()
    buf.write_string("import ./dep" + prev + ".vibe { " + prev_last + " }\n")
    let prefix = "c" + i_str + "_"
    for j in 0..<defs_per_link {
      let name = prefix + j.to_string()
      let prev_val = if j == 0 {
        prev_last
      } else {
        prefix + (j - 1).to_string()
      }
      buf.write_string("export let " + name + " = " + prev_val + " + 1\n")
    }
    db.set_source("./dep" + i_str + ".vibe", buf.to_string())
  }
  // main: imports from last dep
  let last = (depth - 1).to_string()
  let last_name = "c" + last + "_" + (defs_per_link - 1).to_string()
  db.set_source(
    "main",
    "import ./dep" +
    last +
    ".vibe { " +
    last_name +
    " }\nlet result = " +
    last_name +
    "\nresult\n",
  )
  db
}

///|
test "bench: checker.db_types.cross_module.cold" (b : @bench.T) {
  b.bench(fn() {
    let db = setup_cross_module_db(10, 50)
    b.keep(db.types("main").get_scheme("result"))
  })
}

///|
test "bench: checker.db_types.cross_module.hot" (b : @bench.T) {
  let db = setup_cross_module_db(10, 50)
  db.types("main") |> ignore
  b.bench(fn() { b.keep(db.types("main").get_scheme("result")) })
}

///|
test "bench: checker.db_types.cross_module.delta" (b : @bench.T) {
  let db = setup_cross_module_db(10, 50)
  db.types("main") |> ignore
  let src_a = gen_dep_module_source("d0_", 50, 0)
  let src_b = gen_dep_module_source("d0_", 50, 1)
  let mut toggle = false
  b.bench(fn() {
    db.set_source("./dep0.vibe", if toggle { src_a } else { src_b })
    toggle = not(toggle)
    b.keep(db.types("main").get_scheme("result"))
  })
}

///|
test "bench: checker.db_types.chain.cold" (b : @bench.T) {
  b.bench(fn() {
    let db = setup_chain_db(10, 20)
    b.keep(db.types("main").get_scheme("result"))
  })
}

///|
test "bench: checker.db_types.chain.hot" (b : @bench.T) {
  let db = setup_chain_db(10, 20)
  db.types("main") |> ignore
  b.bench(fn() { b.keep(db.types("main").get_scheme("result")) })
}
