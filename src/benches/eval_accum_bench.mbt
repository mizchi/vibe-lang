///|
/// Generate N incremental eval snippets that build on each other.
/// Each snippet defines a function and calls the previous one.
fn gen_eval_snippets(count : Int) -> Array[String] {
  let snippets : Array[String] = []
  // First: define a base function
  snippets.push("let f0 = (x: Int) -> Int { x + 1 }")
  // Each subsequent snippet defines a new function referencing the previous
  for i in 1..<count {
    let i_str = i.to_string()
    let prev = (i - 1).to_string()
    snippets.push(
      "let f" +
      i_str +
      " = (x: Int) -> Int { f" +
      prev +
      "(x) + " +
      i_str +
      " }",
    )
  }
  // Final snippet calls the last function
  let last = (count - 1).to_string()
  snippets.push("f" + last + "(0)")
  snippets
}

///|
/// Generate simple value accumulation snippets
fn gen_value_snippets(count : Int) -> Array[String] {
  let snippets : Array[String] = []
  snippets.push("let v0 = 1")
  for i in 1..<count {
    let i_str = i.to_string()
    let prev = (i - 1).to_string()
    snippets.push("let v" + i_str + " = v" + prev + " + " + i_str)
  }
  let last = (count - 1).to_string()
  snippets.push("v" + last)
  snippets
}

///|
fn new_bench_runtime() -> @runtime.Runtime {
  @runtime.Runtime::new(@capability.CapabilitySet::new())
}

///|
test "bench: eval_accum.fn.10" (b : @bench.T) {
  let snippets = gen_eval_snippets(10)
  b.bench(fn() {
    let rt = new_bench_runtime()
    for s in snippets {
      b.keep(try? rt.eval_script(s))
    }
  })
}

///|
test "bench: eval_accum.fn.50" (b : @bench.T) {
  let snippets = gen_eval_snippets(50)
  b.bench(fn() {
    let rt = new_bench_runtime()
    for s in snippets {
      b.keep(try? rt.eval_script(s))
    }
  })
}

///|
test "bench: eval_accum.fn.100" (b : @bench.T) {
  let snippets = gen_eval_snippets(100)
  b.bench(fn() {
    let rt = new_bench_runtime()
    for s in snippets {
      b.keep(try? rt.eval_script(s))
    }
  })
}

///|
test "bench: eval_accum.fn.200" (b : @bench.T) {
  let snippets = gen_eval_snippets(200)
  b.bench(fn() {
    let rt = new_bench_runtime()
    for s in snippets {
      b.keep(try? rt.eval_script(s))
    }
  })
}

///|
test "bench: eval_accum.val.10" (b : @bench.T) {
  let snippets = gen_value_snippets(10)
  b.bench(fn() {
    let rt = new_bench_runtime()
    for s in snippets {
      b.keep(try? rt.eval_script(s))
    }
  })
}

///|
test "bench: eval_accum.val.50" (b : @bench.T) {
  let snippets = gen_value_snippets(50)
  b.bench(fn() {
    let rt = new_bench_runtime()
    for s in snippets {
      b.keep(try? rt.eval_script(s))
    }
  })
}

///|
test "bench: eval_accum.val.100" (b : @bench.T) {
  let snippets = gen_value_snippets(100)
  b.bench(fn() {
    let rt = new_bench_runtime()
    for s in snippets {
      b.keep(try? rt.eval_script(s))
    }
  })
}

///|
test "bench: eval_accum.val.200" (b : @bench.T) {
  let snippets = gen_value_snippets(200)
  b.bench(fn() {
    let rt = new_bench_runtime()
    for s in snippets {
      b.keep(try? rt.eval_script(s))
    }
  })
}

///|
/// Measure the Nth eval step after accumulating N-1 definitions.
/// Shows how latency grows per-step as env grows.
test "bench: eval_accum.fn_step_at.10" (b : @bench.T) {
  let snippets = gen_eval_snippets(11)
  let rt = new_bench_runtime()
  // Pre-load first 10 snippets
  for i in 0..<10 {
    let _ = try? rt.eval_script(snippets[i])
  }
  let last = snippets[10]
  b.bench(fn() { b.keep(try? rt.eval_script(last)) })
}

///|
test "bench: eval_accum.fn_step_at.50" (b : @bench.T) {
  let snippets = gen_eval_snippets(51)
  let rt = new_bench_runtime()
  for i in 0..<50 {
    let _ = try? rt.eval_script(snippets[i])
  }
  let last = snippets[50]
  b.bench(fn() { b.keep(try? rt.eval_script(last)) })
}

///|
test "bench: eval_accum.fn_step_at.100" (b : @bench.T) {
  let snippets = gen_eval_snippets(101)
  let rt = new_bench_runtime()
  for i in 0..<100 {
    let _ = try? rt.eval_script(snippets[i])
  }
  let last = snippets[100]
  b.bench(fn() { b.keep(try? rt.eval_script(last)) })
}

///|
test "bench: eval_accum.fn_step_at.200" (b : @bench.T) {
  let snippets = gen_eval_snippets(201)
  let rt = new_bench_runtime()
  for i in 0..<200 {
    let _ = try? rt.eval_script(snippets[i])
  }
  let last = snippets[200]
  b.bench(fn() { b.keep(try? rt.eval_script(last)) })
}
