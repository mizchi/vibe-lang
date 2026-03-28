///|
fn assert_gc_e2e(source : String, label : String, expected : Int) -> Unit raise {
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

///|
test "wasm-gc e2e: enum nullary match" {
  let src =
    #|enum Color { Red; Blue; Green }
    #|let main = () -> Int {
    #|  let c = Red
    #|  match c {
    #|    Red => 1
    #|    Blue => 2
    #|    Green => 3
    #|  }
    #|}
    #|main()
  assert_gc_e2e(src, "enum_nullary_match", 1)
}

///|
test "wasm-gc e2e: enum with payload" {
  let src =
    #|enum Result { Ok(Int); Err }
    #|let main = () -> Int {
    #|  let r = Ok(42)
    #|  match r {
    #|    Ok(n) => n
    #|    Err => 0
    #|  }
    #|}
    #|main()
  assert_gc_e2e(src, "enum_with_payload", 42)
}

///|
test "wasm-gc e2e: enum qualified constructor" {
  let src =
    #|enum Wrap { Val(Int); Empty }
    #|let main = () -> Int {
    #|  let x = Wrap::Val(10)
    #|  match x {
    #|    Wrap::Val(n) => n
    #|    Wrap::Empty => 0
    #|  }
    #|}
    #|main()
  assert_gc_e2e(src, "enum_qualified", 10)
}

///|
test "wasm-gc e2e: enum multiple variants same arity" {
  let src =
    #|enum AB { A(Int); B(Int) }
    #|let main = () -> Int {
    #|  let x = B(99)
    #|  match x {
    #|    A(n) => n
    #|    B(n) => n + 1
    #|  }
    #|}
    #|main()
  assert_gc_e2e(src, "enum_same_arity", 100)
}

// Known GC codegen limitations (tracked in issue #41):
// - function-as-value: Gen(UnknownName) when let-binding a function then calling
// - higher-order function: Gen(UnknownName) for function parameter calls
// - mutable capture: ref cell returns stale value on second call (returns 1, expected 2)

///|
test "wasm-gc e2e: bytes new push get" {
  let src =
    #|let main = () -> Int {
    #|  let b = Bytes::new()
    #|  Bytes::push(b, 42)
    #|  Bytes::push(b, 99)
    #|  Bytes::get(b, 1)
    #|}
    #|main()
  assert_gc_e2e(src, "bytes_new_push_get", 99)
}

///|
test "wasm-gc e2e: bytes from_array length" {
  let src =
    #|let main = () -> Int {
    #|  let b = Bytes::from_array([10, 20, 30])
    #|  Bytes::length(b)
    #|}
    #|main()
  assert_gc_e2e(src, "bytes_from_array_length", 3)
}

///|
test "wasm-gc e2e: bytes set" {
  let src =
    #|let main = () -> Int {
    #|  let b = Bytes::from_array([1, 2, 3])
    #|  Bytes::set(b, 1, 42)
    #|  Bytes::get(b, 1)
    #|}
    #|main()
  assert_gc_e2e(src, "bytes_set", 42)
}
