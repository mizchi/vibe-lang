///|
/// End-to-end gate for the Perceus RC (linear-memory) backend on a real wasm
/// engine (wasmtime). The in-tree interpreter in `vibe_wasm_eval_test.mbt` is
/// lenient about wasm stack discipline; wasmtime enforces the spec, so this
/// gate is what actually proves the RC-instrumented wasm is valid and produces
/// correct results. (It already caught an invalid `block`/`br_if` ordering in
/// the rc_dup/rc_drop emitters.)
///
/// Native-only: it shells out to `wasmtime` via libc `system`. Skipped unless
/// `VIBE_WASM_RC_E2E=1` is set; run it with the `test-wasm-rc-e2e` task
/// (`moon test --target native`).

///|
fn rc_e2e_should_skip(test_name : String) -> Bool {
  if gc_e2e_env_truthy("VIBE_WASM_RC_E2E") {
    false
  } else {
    println("[rc e2e] skipped \{test_name} (set VIBE_WASM_RC_E2E=1)")
    true
  }
}

///|
/// Compile `source` with the linear backend + Perceus RC, run it on wasmtime
/// via `--invoke _start`, and return (exit_code, trimmed_output).
fn rc_e2e_compile_and_run(
  source : String,
  label : String,
) -> (Int, String) raise {
  let db = VibeDb::new()
  db.set_source("main", source)
  let wasm = try
    @runtime_compile.compile_module_wasm(db, "main", enable_rc=true)
  catch {
    e => fail("[\{label}] compile error: \{e.to_string()}")
  } noraise {
    b => b
  }
  if wasm.length() < 8 {
    fail("[\{label}] wasm too small: \{wasm.length()}")
  }
  let wasm_path = "/tmp/vibe_rc_e2e_\{label}.wasm"
  let out_path = "/tmp/vibe_rc_e2e_\{label}.out"
  @os_fs.write_bytes_to_file(wasm_path, wasm) catch {
    e => fail("[\{label}] write wasm failed: \{e.to_string()}")
  }
  let exit_code = gc_e2e_system_cmd(
    "wasmtime run --invoke _start " + wasm_path + " > " + out_path + " 2>&1",
  )
  let output = @os_fs.read_file_to_string(out_path) catch { _ => "" }
  let _ = try? @os_fs.remove_file(wasm_path)
  let _ = try? @os_fs.remove_file(out_path)
  (exit_code, output.trim().to_owned())
}

///|
fn assert_rc_e2e_int(
  source : String,
  label : String,
  expected : Int,
) -> Unit raise {
  let (exit_code, output) = rc_e2e_compile_and_run(source, label)
  if exit_code != 0 {
    fail("[\{label}] exit code should be 0, got \{exit_code}: \{output}")
  }
  if !output.contains(expected.to_string()) {
    fail("[\{label}] output should contain \{expected}, got: \{output}")
  }
}

///|
test "rc e2e: heap tuple field access" {
  if rc_e2e_should_skip("heap tuple field access") {
    return
  }
  assert_rc_e2e_int("let t = (3, 4)\nt.0 + t.1", "tuple", 7)
}

///|
test "rc e2e: while loop allocating per iteration" {
  if rc_e2e_should_skip("while loop") {
    return
  }
  let src =
    #|let f = () -> Int {
    #|  let mut s = 0
    #|  let mut i = 0
    #|  while i < 5 {
    #|    let t = (i, i + 1)
    #|    s = s + t.0
    #|    i = i + 1
    #|  }
    #|  s
    #|}
    #|f()
  assert_rc_e2e_int(src, "while_loop", 10)
}

///|
test "rc e2e: for-in loop over array" {
  if rc_e2e_should_skip("for-in loop") {
    return
  }
  let src =
    #|let f = () -> Int {
    #|  let xs = [10, 20, 30]
    #|  let mut sum = 0
    #|  for x in xs {
    #|    let t = (x, x + 1)
    #|    sum = sum + t.0
    #|  }
    #|  sum
    #|}
    #|f()
  assert_rc_e2e_int(src, "for_in", 60)
}

///|
test "rc e2e: if/else branch-local heap" {
  if rc_e2e_should_skip("if/else branch") {
    return
  }
  let src =
    #|let f = (c: Bool) -> Int {
    #|  let mut s = 0
    #|  if c {
    #|    let t = (1, 2)
    #|    s = s + t.0
    #|  } else {
    #|    s = s + 5
    #|  }
    #|  s
    #|}
    #|f(true)
  assert_rc_e2e_int(src, "if_else", 1)
}

///|
test "rc e2e: match arm-local heap" {
  if rc_e2e_should_skip("match arm") {
    return
  }
  let src =
    #|let f = (n: Int) -> Int {
    #|  let mut s = 0
    #|  match n {
    #|    0 => { let t = (7, 8); s = s + t.0 }
    #|    _ => { s = s + 9 }
    #|  }
    #|  s
    #|}
    #|f(0)
  assert_rc_e2e_int(src, "match_arm", 7)
}

///|
test "rc e2e: closure capturing heap" {
  if rc_e2e_should_skip("closure") {
    return
  }
  let src =
    #|let make = (n: Int) -> (Int) -> Int {
    #|  (x: Int) -> Int { x + n }
    #|}
    #|let add5 = make(5)
    #|add5(3)
  assert_rc_e2e_int(src, "closure", 8)
}

///|
test "rc e2e: closure capturing heap value" {
  if rc_e2e_should_skip("closure capturing heap") {
    return
  }
  // The closure captures a heap tuple; its env (and the captured tuple) must be
  // reclaimed without corrupting the computed result.
  let src =
    #|let f = () -> Int {
    #|  let t = (3, 4)
    #|  let g = (x: Int) -> Int { x + t.0 + t.1 }
    #|  g(10)
    #|}
    #|f()
  assert_rc_e2e_int(src, "closure_heap_capture", 17)
}

///|
test "rc e2e: array allocation and index" {
  if rc_e2e_should_skip("array") {
    return
  }
  assert_rc_e2e_int("let a = [1, 2, 3]\nArray::get(a, 2)", "array", 3)
}

///|
test "rc e2e: discarded statement-expr heap" {
  if rc_e2e_should_skip("discarded stmt") {
    return
  }
  let src =
    #|let mk = () -> (Int, Int) {
    #|  (1, 2)
    #|}
    #|let f = () -> Int {
    #|  mk()
    #|  mk()
    #|  let r = mk()
    #|  r.0
    #|}
    #|f()
  assert_rc_e2e_int(src, "discard", 1)
}

///|
test "rc e2e: loop stress reuses heap without corruption" {
  if rc_e2e_should_skip("loop stress") {
    return
  }
  // Many per-iteration allocations: with RC + free-list the heap is reused and
  // the checksum stays correct. A reuse-while-live bug would corrupt the sum.
  let src =
    #|let f = () -> Int {
    #|  let mut acc = 0
    #|  let mut i = 0
    #|  while i < 1000 {
    #|    let t = (i, i * 2)
    #|    acc = acc + t.1 - t.0
    #|    i = i + 1
    #|  }
    #|  acc
    #|}
    #|f()
  // sum_{i=0}^{999} (2i - i) = sum i = 999*1000/2 = 499500
  assert_rc_e2e_int(src, "loop_stress", 499500)
}
