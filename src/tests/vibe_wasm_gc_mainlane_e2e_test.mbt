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
test "wasm-gc mainlane: string for-in char codes" {
  if gc_mainlane_should_skip("string for-in char codes") {
    return
  }
  // 'a'=97 + 'b'=98 + 'c'=99 = 294
  let src =
    #|let main = () -> Int {
    #|  let mut sum = 0
    #|  for c in "abc" {
    #|    sum = sum + c
    #|  }
    #|  sum
    #|}
    #|main()
  assert_gc_e2e_int_result(src, "mainlane_string_for_in_char_codes", 294)
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

///|
test "wasm-gc mainlane: call in if branch" {
  if gc_mainlane_should_skip("call in if branch") {
    return
  }
  // Regression: calling a top-level function inside an if branch crashes codegen.
  // See: function call inside if-then/else body causes abort in compile_function_gc.
  let src =
    #|let g: (Int) -> Int = (n) -> { n + 1 }
    #|let f: (Int) -> Int = (n) -> { if n > 0 { g(n) } else { 0 } }
    #|f(3)
  assert_gc_e2e_int_result(src, "mainlane_call_in_if_branch", 4)
}

///|
test "wasm-gc mainlane: recursive function" {
  if gc_mainlane_should_skip("recursive function") {
    return
  }
  let src =
    #|let fib: (Int) -> Int = (n) -> {
    #|  if n <= 1 { n } else { fib(n - 1) + fib(n - 2) }
    #|}
    #|fib(10)
  assert_gc_e2e_int_result(src, "mainlane_recursive_function", 55)
}

///|
test "wasm-gc mainlane: nested recursive helper captures outer local" {
  if gc_mainlane_should_skip("nested recursive helper captures outer local") {
    return
  }
  let src =
    #|let sum_range = (n: Int) -> Int {
    #|  let rec helper: (Int, Int) -> Int = (i, acc) -> {
    #|    if i > n { acc } else { helper(i + 1, acc + i) }
    #|  }
    #|  helper(1, 0)
    #|}
    #|sum_range(100)
  assert_gc_e2e_int_result(
    src, "mainlane_nested_recursive_helper_capture", 5050,
  )
}
