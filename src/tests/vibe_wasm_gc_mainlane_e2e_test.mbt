///|
fn assert_gc_e2e_int_result(
  source : String,
  label : String,
  expected : Int,
) -> Unit raise {
  let (exit_code, output) = gc_e2e_compile_and_run(source, label)
  if exit_code != 0 {
    fail("[\{label}] exit code should be 0, got \{exit_code}: \{output}")
  }
  if !output.contains(expected.to_string()) {
    fail("[\{label}] output should contain \{expected}, got: \{output}")
  }
}

///|
test "wasm-gc mainlane: closure capture" {
  if gc_mainlane_should_skip("closure capture") {
    return
  }
  let src =
    #|let n = 5
    #|let add_n = (x: Int) -> Int { x + n }
    #|add_n(10)
  assert_gc_e2e_int_result(src, "mainlane_closure_capture", 15)
}

///|
test "wasm-gc mainlane: returned closure call" {
  if gc_mainlane_should_skip("returned closure call") {
    return
  }
  let src =
    #|let make_adder = (n: Int) -> (Int) -> Int {
    #|  (x: Int) -> Int { x + n }
    #|}
    #|let add5 = make_adder(5)
    #|add5(3)
  assert_gc_e2e_int_result(src, "mainlane_returned_closure_call", 8)
}

///|
test "wasm-gc mainlane: for-in runtime" {
  if gc_mainlane_should_skip("for-in runtime") {
    return
  }
  let src =
    #|let ys = for x in [1, 2, 3] {
    #|  x + 1
    #|}
    #|ys[2]
  assert_gc_e2e_int_result(src, "mainlane_for_in_runtime", 4)
}

///|
test "wasm-gc mainlane: string runtime" {
  if gc_mainlane_should_skip("string runtime") {
    return
  }
  let src =
    #|let s = String::concat("ab", "cd")
    #|String::length(s)
  assert_gc_e2e_int_result(src, "mainlane_string_runtime", 4)
}
