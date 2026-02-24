///|
/// DCE Overhead Benchmark: Measure the cost of DCE analysis

///|
/// Small module (6 statements)
let overhead_small_source : String =
  #|let a = 1
  #|let b = 2
  #|let c = 3
  #|let helper = (x: Int) -> Int { x + 1 }
  #|let main_fn = (y: Int) -> Int { helper(y) }
  #|main_fn(5)

///|
/// Medium module (20 statements)
let overhead_medium_source : String =
  #|let unused_1 = 1
  #|let unused_2 = 2
  #|let unused_3 = 3
  #|let unused_4 = 4
  #|let unused_5 = 5
  #|let unused_6 = 6
  #|let unused_7 = 7
  #|let unused_8 = 8
  #|let unused_9 = 9
  #|let unused_10 = 10
  #|let unused_fn_1 = (x: Int) -> Int { x * 2 }
  #|let unused_fn_2 = (x: Int) -> Int { x * 3 }
  #|let unused_fn_3 = (x: Int) -> Int { x * 4 }
  #|let unused_fn_4 = (x: Int) -> Int { x * 5 }
  #|let unused_fn_5 = (x: Int) -> Int { x * 6 }
  #|let helper1 = (x: Int) -> Int { x + 1 }
  #|let helper2 = (x: Int) -> Int { helper1(x) + 1 }
  #|let helper3 = (x: Int) -> Int { helper2(x) + 1 }
  #|let main_fn = (y: Int) -> Int { helper3(y) }
  #|main_fn(5)

///|
/// Large module (50 statements)
let overhead_large_source : String =
  #|let u1 = 1
  #|let u2 = 2
  #|let u3 = 3
  #|let u4 = 4
  #|let u5 = 5
  #|let u6 = 6
  #|let u7 = 7
  #|let u8 = 8
  #|let u9 = 9
  #|let u10 = 10
  #|let u11 = 11
  #|let u12 = 12
  #|let u13 = 13
  #|let u14 = 14
  #|let u15 = 15
  #|let u16 = 16
  #|let u17 = 17
  #|let u18 = 18
  #|let u19 = 19
  #|let u20 = 20
  #|let uf1 = (x: Int) -> Int { x * 2 }
  #|let uf2 = (x: Int) -> Int { x * 3 }
  #|let uf3 = (x: Int) -> Int { x * 4 }
  #|let uf4 = (x: Int) -> Int { x * 5 }
  #|let uf5 = (x: Int) -> Int { x * 6 }
  #|let uf6 = (x: Int) -> Int { x * 7 }
  #|let uf7 = (x: Int) -> Int { x * 8 }
  #|let uf8 = (x: Int) -> Int { x * 9 }
  #|let uf9 = (x: Int) -> Int { x * 10 }
  #|let uf10 = (x: Int) -> Int { x * 11 }
  #|let uf11 = (x: Int) -> Int { x * 12 }
  #|let uf12 = (x: Int) -> Int { x * 13 }
  #|let uf13 = (x: Int) -> Int { x * 14 }
  #|let uf14 = (x: Int) -> Int { x * 15 }
  #|let uf15 = (x: Int) -> Int { x * 16 }
  #|let uf16 = (x: Int) -> Int { x * 17 }
  #|let uf17 = (x: Int) -> Int { x * 18 }
  #|let uf18 = (x: Int) -> Int { x * 19 }
  #|let uf19 = (x: Int) -> Int { x * 20 }
  #|let uf20 = (x: Int) -> Int { x * 21 }
  #|let h1 = (x: Int) -> Int { x + 1 }
  #|let h2 = (x: Int) -> Int { h1(x) + 1 }
  #|let h3 = (x: Int) -> Int { h2(x) + 1 }
  #|let h4 = (x: Int) -> Int { h3(x) + 1 }
  #|let h5 = (x: Int) -> Int { h4(x) + 1 }
  #|let h6 = (x: Int) -> Int { h5(x) + 1 }
  #|let h7 = (x: Int) -> Int { h6(x) + 1 }
  #|let h8 = (x: Int) -> Int { h7(x) + 1 }
  #|let main_fn = (y: Int) -> Int { h8(y) }
  #|main_fn(5)

///|
/// Benchmark: DCE analysis only (small module)
test "bench: dce.overhead.analysis.small" (b : @bench.T) {
  let db = @runtime.VibeDb::new()
  db.set_source("main", overhead_small_source)
  let compiled = try? @runtime_compile.compile_module(db, "main")
  match compiled {
    Ok(c) => {
      let bundled = @runtime.bundle_for_wasm_no_dce(db, "main", c.ast)
      b.bench(fn() { b.keep(@frontend.dce_module(bundled)) })
    }
    Err(_) => ()
  }
}

///|
/// Benchmark: DCE analysis only (medium module)
test "bench: dce.overhead.analysis.medium" (b : @bench.T) {
  let db = @runtime.VibeDb::new()
  db.set_source("main", overhead_medium_source)
  let compiled = try? @runtime_compile.compile_module(db, "main")
  match compiled {
    Ok(c) => {
      let bundled = @runtime.bundle_for_wasm_no_dce(db, "main", c.ast)
      b.bench(fn() { b.keep(@frontend.dce_module(bundled)) })
    }
    Err(_) => ()
  }
}

///|
/// Benchmark: DCE analysis only (large module)
test "bench: dce.overhead.analysis.large" (b : @bench.T) {
  let db = @runtime.VibeDb::new()
  db.set_source("main", overhead_large_source)
  let compiled = try? @runtime_compile.compile_module(db, "main")
  match compiled {
    Ok(c) => {
      let bundled = @runtime.bundle_for_wasm_no_dce(db, "main", c.ast)
      b.bench(fn() { b.keep(@frontend.dce_module(bundled)) })
    }
    Err(_) => ()
  }
}

///|
/// Benchmark: Full compile without DCE (medium module)
test "bench: dce.overhead.compile_no_dce.medium" (b : @bench.T) {
  let db = @runtime.VibeDb::new()
  db.set_source("main", overhead_medium_source)
  b.bench(fn() {
    b.keep(try? @runtime_compile.compile_module_wasm_no_dce(db, "main"))
  })
}

///|
/// Benchmark: Full compile with DCE (medium module)
test "bench: dce.overhead.compile_with_dce.medium" (b : @bench.T) {
  let db = @runtime.VibeDb::new()
  db.set_source("main", overhead_medium_source)
  b.bench(fn() { b.keep(try? @runtime_compile.compile_module_wasm(db, "main")) })
}

///|
/// Benchmark: Full compile without DCE (large module)
test "bench: dce.overhead.compile_no_dce.large" (b : @bench.T) {
  let db = @runtime.VibeDb::new()
  db.set_source("main", overhead_large_source)
  b.bench(fn() {
    b.keep(try? @runtime_compile.compile_module_wasm_no_dce(db, "main"))
  })
}

///|
/// Benchmark: Full compile with DCE (large module)
test "bench: dce.overhead.compile_with_dce.large" (b : @bench.T) {
  let db = @runtime.VibeDb::new()
  db.set_source("main", overhead_large_source)
  b.bench(fn() { b.keep(try? @runtime_compile.compile_module_wasm(db, "main")) })
}
