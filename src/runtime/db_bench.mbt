///|
/// Benchmark: VibeDb incremental type checking

///|
/// Helper to generate vibe source code
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
test "bench: VibeDb cold type check" (b : @bench.T) {
  let source = gen_source(100)
  b.bench(name="VibeDb cold type check (100 let bindings)", fn() {
    let db = VibeDb::new()
    db.set_source("test.vibe", source)
    db.types("test.vibe") |> ignore
  })
}

///|
/// Benchmark: Cache hit (same source, no change)
test "bench: VibeDb cache hit" (b : @bench.T) {
  let db = VibeDb::new()
  let source = gen_source(100)
  db.set_source("test.vibe", source)
  // Warm up cache
  db.types("test.vibe") |> ignore
  b.bench(name="VibeDb cache hit (100 let bindings)", fn() {
    for _ in 0..<100 {
      db.types("test.vibe") |> ignore
    }
  })
}

///|
/// Benchmark: Small change (modify last line)
test "bench: VibeDb incremental small change" (b : @bench.T) {
  let db = VibeDb::new()
  let base = gen_source(100)
  db.set_source("test.vibe", base)
  // Warm up cache
  db.types("test.vibe") |> ignore
  b.bench(name="VibeDb incremental (change last line, 100 bindings)", fn() {
    for i in 0..<50 {
      // Alternate between two sources (small change at end)
      let suffix = if i % 2 == 0 { "let z = 1\n" } else { "let z = 2\n" }
      db.set_source("test.vibe", base + suffix)
      db.types("test.vibe") |> ignore
    }
  })
}

///|
/// Benchmark: Unrelated file change
test "bench: VibeDb unrelated file change" (b : @bench.T) {
  let db = VibeDb::new()
  let main_source = gen_source(100)
  db.set_source("main.vibe", main_source)
  // Warm up cache for main file
  db.types("main.vibe") |> ignore
  b.bench(name="VibeDb unrelated file change (should skip main)", fn() {
    for i in 0..<50 {
      // Change an unrelated file
      db.set_source("other.vibe", "let y = " + i.to_string())
      // Query main file - should be cache hit
      db.types("main.vibe") |> ignore
    }
  })
}

///|
/// Benchmark: AST parsing cache hit
test "bench: VibeDb AST cache hit" (b : @bench.T) {
  let db = VibeDb::new()
  let source = gen_source(100)
  db.set_source("test.vibe", source)
  // Warm up
  db.ast("test.vibe") |> ignore
  b.bench(name="VibeDb AST cache hit (100 let bindings)", fn() {
    for _ in 0..<100 {
      db.ast("test.vibe") |> ignore
    }
  })
}

///|
/// Benchmark: CST parsing cache hit
test "bench: VibeDb CST cache hit" (b : @bench.T) {
  let db = VibeDb::new()
  let source = gen_source(100)
  db.set_source("test.vibe", source)
  // Warm up
  db.cst("test.vibe") |> ignore
  b.bench(name="VibeDb CST cache hit (100 let bindings)", fn() {
    for _ in 0..<100 {
      db.cst("test.vibe") |> ignore
    }
  })
}

///|
/// Benchmark: Full pipeline cold start
test "bench: VibeDb full pipeline cold" (b : @bench.T) {
  let source = gen_source(50)
  b.bench(name="VibeDb full pipeline cold (50 let bindings)", fn() {
    let db = VibeDb::new()
    db.set_source("test.vibe", source)
    db.cst("test.vibe") |> ignore
    db.ast("test.vibe") |> ignore
    db.types("test.vibe") |> ignore
    db.diagnostics("test.vibe") |> ignore
  })
}

///|
/// Benchmark: Compute intensive type checking
test "bench: VibeDb type check with functions" (b : @bench.T) {
  let source =
    #|let add = (a: Int, b: Int) -> Int { a + b }
    #|let mul = (a: Int, b: Int) -> Int { a * b }
    #|let compose = (f: (Int) -> Int, g: (Int) -> Int, x: Int) -> Int { f(g(x)) }
    #|let double = (x: Int) -> Int { x * 2 }
    #|let inc = (x: Int) -> Int { x + 1 }
    #|let result = compose(double, inc, 10)
    #|result
  b.bench(name="VibeDb type check with HOF", fn() {
    let db = VibeDb::new()
    db.set_source("test.vibe", source)
    db.types("test.vibe") |> ignore
  })
}

///|
/// Benchmark: Generic function type checking
test "bench: VibeDb generic type check" (b : @bench.T) {
  let source =
    #|let identity = [T](x: T) -> T { x }
    #|let apply = [A, B](f: (A) -> B, x: A) -> B { f(x) }
    #|let double = (x: Int) -> Int { x * 2 }
    #|apply(double, identity(21))
  b.bench(name="VibeDb generic type check", fn() {
    let db = VibeDb::new()
    db.set_source("test.vibe", source)
    db.types("test.vibe") |> ignore
  })
}

///|
/// Benchmark: Incremental with semantic equivalence
/// When recomputed value is the same, downstream should skip
test "bench: VibeDb semantic cache (same type result)" (b : @bench.T) {
  let db = VibeDb::new()
  // Two semantically equivalent sources (different comments/whitespace)
  let source1 = "let x = 1\nlet y = 2\n"
  let source2 = "let x = 1\n\nlet y = 2\n"
  db.set_source("test.vibe", source1)
  db.types("test.vibe") |> ignore
  b.bench(name="VibeDb semantic cache (whitespace change)", fn() {
    for i in 0..<50 {
      let source = if i % 2 == 0 { source1 } else { source2 }
      db.set_source("test.vibe", source)
      db.types("test.vibe") |> ignore
    }
  })
}

///|
/// Benchmark: Multi-file with import dependency
test "bench: VibeDb multi-file import" (b : @bench.T) {
  let db = VibeDb::new()
  // lib.vibe exports a function
  let lib_source =
    #|export let double = (x: Int) -> Int { x * 2 }
  db.set_source("/lib.vibe", lib_source)
  // main.vibe imports from lib
  let main_source =
    #|import /lib.vibe {  double  }
    #|double(21)
  db.set_source("/main.vibe", main_source)
  // Warm up
  db.types("/main.vibe") |> ignore
  b.bench(name="VibeDb import: lib unchanged, main queried", fn() {
    for _ in 0..<50 {
      // Query main without changing lib - should be cache hit
      db.types("/main.vibe") |> ignore
    }
  })
}

///|
/// Benchmark: Multi-file - changing imported module
test "bench: VibeDb multi-file import change" (b : @bench.T) {
  let db = VibeDb::new()
  let lib_source1 =
    #|export let double = (x: Int) -> Int { x * 2 }
  let lib_source2 =
    #|export let double = (x: Int) -> Int { x + x }
  db.set_source("/lib.vibe", lib_source1)
  let main_source =
    #|import /lib.vibe {  double  }
    #|double(21)
  db.set_source("/main.vibe", main_source)
  // Warm up
  db.types("/main.vibe") |> ignore
  b.bench(name="VibeDb import: lib changed, main recomputed", fn() {
    for i in 0..<20 {
      let lib = if i % 2 == 0 { lib_source1 } else { lib_source2 }
      db.set_source("/lib.vibe", lib)
      db.types("/main.vibe") |> ignore
    }
  })
}

///|
/// Benchmark: Compare cache hit vs miss ratio
test "bench: VibeDb cache efficiency" (b : @bench.T) {
  let db = VibeDb::new()
  let source = gen_source(100)
  db.set_source("test.vibe", source)
  // Warm up
  db.types("test.vibe") |> ignore
  // 90% cache hits, 10% cache misses
  b.bench(name="VibeDb 90% cache hit ratio", fn() {
    for i in 0..<100 {
      if i % 10 == 0 {
        // 10% of time: change source
        db.set_source("test.vibe", source + "// " + i.to_string() + "\n")
      }
      db.types("test.vibe") |> ignore
    }
  })
}
