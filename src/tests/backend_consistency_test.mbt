///|
/// Compare direct interpreter (eval_script) vs compiled interpreter
/// (compile_module + run_compiled) for features beyond WASM evaluator scope.
fn assert_interp_compiled_same(script : String) -> Unit raise {
  // Compiled interpreter path
  let db = VibeDb::new()
  db.set_source("main", script)
  let compiled = try compile_module(db, "main") catch {
    e => fail("compile error: " + e.to_string())
  } noraise {
    c => c
  }
  let rt_compiled = Runtime::new(@capability.CapabilitySet::new())
  let compiled_result = try
    @runtime_compile.run_compiled(rt_compiled, compiled)
  catch {
    e => fail("compiled eval error: " + e.to_string())
  } noraise {
    r => r
  }
  let compiled_value = match compiled_result.last {
    Some(v) => v
    None => @core.Value::Unit
  }
  // Direct interpreter path
  let rt_direct = Runtime::new(@capability.CapabilitySet::new())
  let direct_result = try rt_direct.eval_script(script) catch {
    e => fail("direct eval error: " + e.to_string())
  } noraise {
    r => r
  }
  let direct_value = match direct_result.last {
    Some(v) => v
    None => @core.Value::Unit
  }
  assert_eq(compiled_value, direct_value)
}

///|
test "interp vs compiled: user-defined functions" {
  assert_interp_compiled_same(
    "let double = (x: Int) -> Int { mul(x, 2) }\ndouble(5)",
  )
  assert_interp_compiled_same(
    "let inc = (x: Int) -> Int { add(x, 1) }\nlet dec = (x: Int) -> Int { sub(x, 1) }\nadd(inc(3), dec(3))",
  )
}

///|
test "interp vs compiled: recursion" {
  let sum_script =
    #|let rec sum = (n: Int) -> Int {
    #|  if eq(n, 0) { 0 } else { add(n, sum(sub(n, 1))) }
    #|}
    #|sum(10)
  assert_interp_compiled_same(sum_script)
  let fib_script =
    #|let rec fib = (n: Int) -> Int {
    #|  if lt(n, 2) { n } else { add(fib(sub(n, 1)), fib(sub(n, 2))) }
    #|}
    #|fib(10)
  assert_interp_compiled_same(fib_script)
}

///|
test "interp vs compiled: higher-order functions" {
  assert_interp_compiled_same(
    "let apply = (f: (Int) -> Int, x: Int) -> Int { f(x) }\nlet inc = (x: Int) -> Int { add(x, 1) }\napply(inc, 7)",
  )
}

///|
test "interp vs compiled: pipe operator" {
  assert_interp_compiled_same(
    "let inc = (a: Int) -> Int { add(a, 1) }\n2 |> inc",
  )
  assert_interp_compiled_same(
    "let inc = (a: Int) -> Int { add(a, 1) }\n2 |> inc |> inc",
  )
  assert_interp_compiled_same("5 |> add(3)")
}

///|
test "interp vs compiled: string interpolation" {
  assert_interp_compiled_same("let x = 42\n\"value is \\{x}\"")
  assert_interp_compiled_same(
    "let a = 1\nlet b = 2\n\"\\{a} + \\{b} = \\{add(a, b)}\"",
  )
}

///|
test "interp vs compiled: mutable variables" {
  let script =
    #|let mut x = 0
    #|x = add(x, 1)
    #|x = add(x, 2)
    #|x
  assert_interp_compiled_same(script)
}

///|
test "interp vs compiled: while loop" {
  let script =
    #|let mut i = 0
    #|let mut acc = 0
    #|while lt(i, 5) {
    #|  acc = add(acc, i)
    #|  i = add(i, 1)
    #|}
    #|acc
  assert_interp_compiled_same(script)
}

///|
test "interp vs compiled: match with constructor patterns" {
  assert_interp_compiled_same("match Some(42) { Some(v) => v, None => 0 }")
  assert_interp_compiled_same("match None { Some(v) => v, None => sub(0, 1) }")
}

///|
test "interp vs compiled: nested function calls" {
  assert_interp_compiled_same(
    "let square = (x: Int) -> Int { mul(x, x) }\nlet sum_sq = (a: Int, b: Int) -> Int { add(square(a), square(b)) }\nsum_sq(3, 4)",
  )
}

///|
test "interp vs compiled: complex match with functions" {
  let script =
    #|let rec classify = (n: Int) -> String {
    #|  match n {
    #|    0 => "zero",
    #|    v if lt(v, 0) => "negative",
    #|    v if lt(100, v) => "large",
    #|    _ => "small"
    #|  }
    #|}
  assert_interp_compiled_same(script + "\nclassify(0)")
  assert_interp_compiled_same(script + "\nclassify(sub(0, 5))")
  assert_interp_compiled_same(script + "\nclassify(200)")
  assert_interp_compiled_same(script + "\nclassify(50)")
}

///|
test "interp vs compiled: arithmetic edge cases" {
  assert_interp_compiled_same("sub(0, 0)")
  assert_interp_compiled_same("mul(1000000, 1000)")
  assert_interp_compiled_same("div(100, 7)")
  assert_interp_compiled_same("mul(sub(0, 1), sub(0, 1))")
  assert_interp_compiled_same("add(sub(0, 1), sub(0, 2))")
}

///|
test "interp vs compiled: boolean short-circuit-like patterns" {
  assert_interp_compiled_same("if true { 1 } else { div(1, 0) }")
  assert_interp_compiled_same("if false { div(1, 0) } else { 2 }")
}

///|
test "interp vs compiled: array builtins" {
  assert_interp_compiled_same("let a = [1, 2, 3]\narray_length(a)")
  assert_interp_compiled_same("let a = [10, 20, 30]\narray_get(a, 1)")
}

///|
test "interp vs compiled: string builtins" {
  assert_interp_compiled_same("string_length(\"hello\")")
  assert_interp_compiled_same("string_concat(\"foo\", \"bar\")")
}
