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

///|
test "wasm-gc e2e: pipe operator" {
  let src =
    #|let double = (x: Int) -> Int { x + x }
    #|let main = () -> Int { 21 |> double() }
    #|main()
  assert_gc_e2e(src, "pipe_op", 42)
}

///|
test "wasm-gc e2e: MapBuilder new/freeze" {
  let src =
    #|let main = () -> Int {
    #|  let b = MapBuilder::new()
    #|  let m = MapBuilder::freeze(b)
    #|  let _ = m
    #|  30
    #|}
    #|main()
  assert_gc_e2e(src, "map_builder_simple", 30)
}

///|
test "wasm-gc e2e: MapBuilder set" {
  let src =
    #|let main = () -> Int {
    #|  let b = MapBuilder::new()
    #|  MapBuilder::set(b, "x", 10)
    #|  MapBuilder::set(b, "y", 20)
    #|  let m = MapBuilder::freeze(b)
    #|  let _ = m
    #|  30
    #|}
    #|main()
  assert_gc_e2e(src, "map_builder_set", 30)
}

///|
test "wasm-gc e2e: throw/handle error-only" {
  let src =
    #|let main = () -> Int {
    #|  handle {
    #|    throw("error")
    #|    0
    #|  } {
    #|    Error(e) => {
    #|      let _ = e
    #|      42
    #|    }
    #|  }
    #|}
    #|main()
  assert_gc_e2e(src, "throw_handle", 42)
}

///|
test "wasm-gc e2e: handle success path" {
  let src =
    #|let main = () -> Int {
    #|  handle {
    #|    99
    #|  } {
    #|    Error(e) => {
    #|      let _ = e
    #|      0
    #|    }
    #|  }
    #|}
    #|main()
  assert_gc_e2e(src, "handle_success", 99)
}

///|
test "wasm-gc e2e: ArrayBuilder push 3+ times (#64)" {
  let src =
    #|let main = () -> Int {
    #|  let b = ArrayBuilder::new()
    #|  ArrayBuilder::push(b, 10)
    #|  ArrayBuilder::push(b, 20)
    #|  ArrayBuilder::push(b, 30)
    #|  let arr = ArrayBuilder::freeze(b)
    #|  arr[0] + arr[1]
    #|}
    #|main()
  assert_gc_e2e(src, "ab_push_3", 30)
}

///|
test "wasm-gc e2e: let rec factorial top-level" {
  let src =
    #|let rec fact = (n: Int) -> Int {
    #|  if n <= 1 { 1 } else { n * fact(n - 1) }
    #|}
    #|fact(5)
  assert_gc_e2e(src, "let_rec_fact_top", 120)
}

// TODO(B7): nested let rec closure self-ref needs mutable box for deferred init
// test "wasm-gc e2e: let rec factorial nested" { ... }
