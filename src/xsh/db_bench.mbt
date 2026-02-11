///|
/// Benchmark: XshDb incremental type checking

///|
/// Helper to generate xsh source code
fn gen_source(n : Int) -> String {
  let buf = StringBuilder::new()
  for i in 0..<n {
    buf.write_string("let x")
    buf.write_string(i.to_string())
    buf.write_string(" = ")
    buf.write_string(i.to_string())
    buf.write_string("\n")
  }
  buf.to_string()
}

///|
/// Benchmark: Cold type check (first computation)
test "bench: XshDb cold type check" (b : @bench.T) {
  let source = gen_source(100)
  b.bench(name="XshDb cold type check (100 let bindings)", fn() {
    let db = XshDb::new()
    db.set_source("test.xsh", source)
    db.types("test.xsh") |> ignore
  })
}

///|
/// Benchmark: Cache hit (same source, no change)
test "bench: XshDb cache hit" (b : @bench.T) {
  let db = XshDb::new()
  let source = gen_source(100)
  db.set_source("test.xsh", source)
  // Warm up cache
  db.types("test.xsh") |> ignore
  b.bench(name="XshDb cache hit (100 let bindings)", fn() {
    for _ in 0..<100 {
      db.types("test.xsh") |> ignore
    }
  })
}

///|
/// Benchmark: Small change (modify last line)
test "bench: XshDb incremental small change" (b : @bench.T) {
  let db = XshDb::new()
  let base = gen_source(100)
  db.set_source("test.xsh", base)
  // Warm up cache
  db.types("test.xsh") |> ignore
  b.bench(name="XshDb incremental (change last line, 100 bindings)", fn() {
    for i in 0..<50 {
      // Alternate between two sources (small change at end)
      let suffix = if i % 2 == 0 { "let z = 1\n" } else { "let z = 2\n" }
      db.set_source("test.xsh", base + suffix)
      db.types("test.xsh") |> ignore
    }
  })
}

///|
/// Benchmark: Unrelated file change
test "bench: XshDb unrelated file change" (b : @bench.T) {
  let db = XshDb::new()
  let main_source = gen_source(100)
  db.set_source("main.xsh", main_source)
  // Warm up cache for main file
  db.types("main.xsh") |> ignore
  b.bench(name="XshDb unrelated file change (should skip main)", fn() {
    for i in 0..<50 {
      // Change an unrelated file
      db.set_source("other.xsh", "let y = " + i.to_string())
      // Query main file - should be cache hit
      db.types("main.xsh") |> ignore
    }
  })
}

///|
/// Benchmark: AST parsing cache hit
test "bench: XshDb AST cache hit" (b : @bench.T) {
  let db = XshDb::new()
  let source = gen_source(100)
  db.set_source("test.xsh", source)
  // Warm up
  db.ast("test.xsh") |> ignore
  b.bench(name="XshDb AST cache hit (100 let bindings)", fn() {
    for _ in 0..<100 {
      db.ast("test.xsh") |> ignore
    }
  })
}

///|
/// Benchmark: CST parsing cache hit
test "bench: XshDb CST cache hit" (b : @bench.T) {
  let db = XshDb::new()
  let source = gen_source(100)
  db.set_source("test.xsh", source)
  // Warm up
  db.cst("test.xsh") |> ignore
  b.bench(name="XshDb CST cache hit (100 let bindings)", fn() {
    for _ in 0..<100 {
      db.cst("test.xsh") |> ignore
    }
  })
}

///|
/// Benchmark: Full pipeline cold start
test "bench: XshDb full pipeline cold" (b : @bench.T) {
  let source = gen_source(50)
  b.bench(name="XshDb full pipeline cold (50 let bindings)", fn() {
    let db = XshDb::new()
    db.set_source("test.xsh", source)
    db.cst("test.xsh") |> ignore
    db.ast("test.xsh") |> ignore
    db.types("test.xsh") |> ignore
    db.diagnostics("test.xsh") |> ignore
  })
}

///|
/// Benchmark: Compute intensive type checking
test "bench: XshDb type check with functions" (b : @bench.T) {
  let source =
    #|let add = (a: Int, b: Int) -> Int { a + b }
    #|let mul = (a: Int, b: Int) -> Int { a * b }
    #|let compose = (f: (Int) -> Int, g: (Int) -> Int, x: Int) -> Int { f(g(x)) }
    #|let double = (x: Int) -> Int { x * 2 }
    #|let inc = (x: Int) -> Int { x + 1 }
    #|let result = compose(double, inc, 10)
    #|result
  b.bench(name="XshDb type check with HOF", fn() {
    let db = XshDb::new()
    db.set_source("test.xsh", source)
    db.types("test.xsh") |> ignore
  })
}

///|
/// Benchmark: Generic function type checking
test "bench: XshDb generic type check" (b : @bench.T) {
  let source =
    #|let identity = [T](x: T) -> T { x }
    #|let apply = [A, B](f: (A) -> B, x: A) -> B { f(x) }
    #|let double = (x: Int) -> Int { x * 2 }
    #|apply(double, identity(21))
  b.bench(name="XshDb generic type check", fn() {
    let db = XshDb::new()
    db.set_source("test.xsh", source)
    db.types("test.xsh") |> ignore
  })
}

///|
/// Benchmark: Incremental with semantic equivalence
/// When recomputed value is the same, downstream should skip
test "bench: XshDb semantic cache (same type result)" (b : @bench.T) {
  let db = XshDb::new()
  // Two semantically equivalent sources (different comments/whitespace)
  let source1 = "let x = 1\nlet y = 2\n"
  let source2 = "let x = 1\n\nlet y = 2\n"
  db.set_source("test.xsh", source1)
  db.types("test.xsh") |> ignore
  b.bench(name="XshDb semantic cache (whitespace change)", fn() {
    for i in 0..<50 {
      let source = if i % 2 == 0 { source1 } else { source2 }
      db.set_source("test.xsh", source)
      db.types("test.xsh") |> ignore
    }
  })
}

///|
/// Benchmark: Multi-file with import dependency
test "bench: XshDb multi-file import" (b : @bench.T) {
  let db = XshDb::new()
  // lib.xsh exports a function
  let lib_source =
    #|export let double = (x: Int) -> Int { x * 2 }
  db.set_source("/lib.xsh", lib_source)
  // main.xsh imports from lib
  let main_source =
    #|use /lib.xsh {  double  }
    #|double(21)
  db.set_source("/main.xsh", main_source)
  // Warm up
  db.types("/main.xsh") |> ignore
  b.bench(name="XshDb import: lib unchanged, main queried", fn() {
    for _ in 0..<50 {
      // Query main without changing lib - should be cache hit
      db.types("/main.xsh") |> ignore
    }
  })
}

///|
/// Benchmark: Multi-file - changing imported module
test "bench: XshDb multi-file import change" (b : @bench.T) {
  let db = XshDb::new()
  let lib_source1 =
    #|export let double = (x: Int) -> Int { x * 2 }
  let lib_source2 =
    #|export let double = (x: Int) -> Int { x + x }
  db.set_source("/lib.xsh", lib_source1)
  let main_source =
    #|use /lib.xsh {  double  }
    #|double(21)
  db.set_source("/main.xsh", main_source)
  // Warm up
  db.types("/main.xsh") |> ignore
  b.bench(name="XshDb import: lib changed, main recomputed", fn() {
    for i in 0..<20 {
      let lib = if i % 2 == 0 { lib_source1 } else { lib_source2 }
      db.set_source("/lib.xsh", lib)
      db.types("/main.xsh") |> ignore
    }
  })
}

///|
/// Benchmark: Compare cache hit vs miss ratio
test "bench: XshDb cache efficiency" (b : @bench.T) {
  let db = XshDb::new()
  let source = gen_source(100)
  db.set_source("test.xsh", source)
  // Warm up
  db.types("test.xsh") |> ignore
  // 90% cache hits, 10% cache misses
  b.bench(name="XshDb 90% cache hit ratio", fn() {
    for i in 0..<100 {
      if i % 10 == 0 {
        // 10% of time: change source
        db.set_source("test.xsh", source + "// " + i.to_string() + "\n")
      }
      db.types("test.xsh") |> ignore
    }
  })
}
