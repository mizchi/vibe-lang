///|
fn assert_gc_e2e(
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
test "wasm-gc e2e: return 42" {
  let src =
    #|let main = () -> Int { 42 }
    #|main()
  assert_gc_e2e(src, "return_42", 42)
}

///|
test "wasm-gc e2e: arithmetic" {
  let src =
    #|let main = () -> Int { let x = 1; let y = 2; x + y }
    #|main()
  assert_gc_e2e(src, "arithmetic", 3)
}

///|
test "wasm-gc e2e: if-else" {
  let src =
    #|let main = () -> Int { if true { 1 } else { 0 } }
    #|main()
  assert_gc_e2e(src, "if_else", 1)
}

///|
test "wasm-gc e2e: while loop" {
  let src =
    #|let main = () -> Int {
    #|  let mut sum = 0
    #|  let mut i = 1
    #|  while i <= 10 {
    #|    sum = sum + i
    #|    i = i + 1
    #|  }
    #|  sum
    #|}
    #|main()
  assert_gc_e2e(src, "while_loop", 55)
}

///|
test "wasm-gc e2e: function call" {
  let src =
    #|let add = (a: Int, b: Int) -> Int { a + b }
    #|let main = () -> Int { add(3, 4) }
    #|main()
  assert_gc_e2e(src, "function_call", 7)
}

///|
test "wasm-gc e2e: match expression" {
  let src =
    #|let f = (x: Int) -> Int {
    #|  match x {
    #|    0 => 10,
    #|    1 => 20,
    #|    _ => 30
    #|  }
    #|}
    #|f(1)
  assert_gc_e2e(src, "match_expression", 20)
}

///|
test "wasm-gc e2e: let mut and assign" {
  let src =
    #|let main = () -> Int {
    #|  let mut x = 10
    #|  x = x + 5
    #|  x
    #|}
    #|main()
  assert_gc_e2e(src, "let_mut_assign", 15)
}

///|
test "wasm-gc e2e: fibonacci iterative" {
  let src =
    #|let main = () -> Int {
    #|  let mut a = 0
    #|  let mut b = 1
    #|  let mut i = 0
    #|  while i < 10 {
    #|    let t = b
    #|    b = a + b
    #|    a = t
    #|    i = i + 1
    #|  }
    #|  a
    #|}
    #|main()
  assert_gc_e2e(src, "fibonacci_iterative", 55)
}

///|
test "wasm-gc e2e: closure no capture" {
  let src =
    #|let main = () -> Int {
    #|  let f = (x: Int) -> Int { x + 1 }
    #|  f(5)
    #|}
    #|main()
  assert_gc_e2e(src, "closure_no_capture", 6)
}

// Known GC codegen limitations (tracked in issue #41):
// - function-as-value: Gen(UnknownName) when let-binding a function then calling
// - higher-order function: Gen(UnknownName) for function parameter calls
// - mutable capture: ref cell returns stale value on second call (returns 1, expected 2)
// - enum constructors: Gen(UnknownName) for enum variant names in E2E path
