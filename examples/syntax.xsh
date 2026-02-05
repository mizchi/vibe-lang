import "test.xsh"
alias std = core#deadbeef
flake {
  inputs = { name = "xsh" }
}

enum Result[T] { Ok(T), Err }
type IntResult = Result[Int]

let add2 = (x: Int) -> Int { add(x, 2) }
let rec fact = (n: Int) -> Int {
  if lt(n, 2) { 1 } else { mul(n, fact(sub(n, 1))) }
}

let pair = (1, 2)
let record_value = record { a: 1, b: 2 }
let array_value = [1, 2, 3]
let map_value = map { a: 1, "b": 2 }
let pipe_basic = 1 |> add(2) |> mul(3)
let pipe_ident = "hello" |> string_length
let float_value = 1.25f
let float_sum = add(float_value, 2.0f)
let path_value = path("examples/syntax.xsh")

let labeled = (x: Int, y~: String, z?: Bool) { y }
let label_call = labeled(1, y="ok")

let effectful = (s: String) -> Int with {Error} { string_length(s) }
let effectful_call = (s: String) -> Int with {Error} { effectful(s) }
let effect_apply = (f: (x: Int) -> Int with {e}, x: Int) -> Int with {e} { f(x) }
let effectful_int = (x: Int) -> Int with {Error} { x }
let effectful_apply = (x: Int) -> Int with {Error} { effect_apply(effectful_int, x) }

let block_value = {
  let x = 1
  add(x, 2)
}

let match_value = match Ok(1) { Ok(v) => v, Err => 0 }
let match_tuple = match pair { (a, b) => add(a, b), _ => 0 }
let match_record = match record_value { record { a: v } => v, _ => 0 }
let match_guard = match 1 { v if lt(v, 2) => 1, _ => 0 }
let match_literal_int = match 2 { 1 => 10, 2 => 20, _ => 0 }
let match_literal_str = match "ok" { "ok" => 1, _ => 0 }
let match_literal_float = match 1.5f { 1.5f => 1, _ => 0 }
let match_literal_double = match 1.5 { 1.5 => 1, _ => 0 }
let match_literal_bool = match true { true => 1, _ => 0 }

let if_value = if true { 1 } else { 2 }

let built_array = do {
  let b = array_builder()
  array_builder_push(b, 1)
  array_builder_push(b, 2)
  array_builder_freeze(b)
}

test "basic" { assert(eq(add(1, 2), 3)) }
test "fact" { assert(eq(fact(5), 120)) }
test "pipe" { assert(eq(pipe_basic, 9)) }
test "pipe ident" { assert(eq(pipe_ident, 5)) }
test "float" { assert(eq(float_sum, 3.25f)) }
test "match value" { assert(eq(match_value, 1)) }
test "match tuple" { assert(eq(match_tuple, 3)) }
test "match record" { assert(eq(match_record, 1)) }
test "match guard" { assert(eq(match_guard, 1)) }
test "match literal int" { assert(eq(match_literal_int, 20)) }
test "match literal str" { assert(eq(match_literal_str, 1)) }
test "match literal float" { assert(eq(match_literal_float, 1)) }
test "match literal double" { assert(eq(match_literal_double, 1)) }
test "match literal bool" { assert(eq(match_literal_bool, 1)) }
test "if value" { assert(eq(if_value, 1)) }
test "block value" { assert(eq(block_value, 3)) }
test "built array" { assert(eq(array_length(built_array), 2)) }
test "int_to_double" { assert(eq(int_to_double(42), 42.0)) }
test "double_to_int" { assert(eq(double_to_int(3.14), 3)) }
test "int_to_float" { assert(eq(int_to_float(42), 42.0f)) }
test "float_to_int" { assert(eq(float_to_int(3.14f), 3)) }
test "float_to_double" { assert(eq(float_to_double(1.5f), 1.5)) }
test "double_to_float" { assert(eq(double_to_float(1.5), 1.5f)) }
test "array_concat" {
  let a = array_concat([1, 2], [3, 4])
  assert(eq(array_length(a), 4))
  assert(eq(array_get(a, 0), 1))
  assert(eq(array_get(a, 3), 4))
}
test "array_reverse" {
  let r = array_reverse([1, 2, 3])
  assert(eq(array_get(r, 0), 3))
  assert(eq(array_get(r, 2), 1))
}
test "map_keys" {
  let m = map { a: 1, b: 2 }
  let k = map_keys(m)
  assert(eq(array_length(k), 2))
}
test "map_has_key" {
  let m = map { x: 10 }
  assert(map_has_key(m, "x"))
  assert(not(map_has_key(m, "y")))
}
test "array_slice" {
  let s = array_slice([10, 20, 30, 40], 1, 3)
  assert(eq(array_length(s), 2))
  assert(eq(array_get(s, 0), 20))
  assert(eq(array_get(s, 1), 30))
}
let mut counter = 0
while counter < 5 {
  counter = counter + 1
}
test "while_basic" { assert(eq(counter, 5)) }
test "let_mut_assign" {
  let mut x = 10
  x = x + 5
  assert(eq(x, 15))
}
test "while_sum" {
  let mut sum = 0
  let mut i = 1
  while i <= 10 {
    sum = sum + i
    i = i + 1
  }
  assert(eq(sum, 55))
}
test "let_tuple_destr" {
  let (a, b) = (10, 20)
  assert(eq(a + b, 30))
}
test "let_record_destr" {
  let record { x: v, y: w } = record { x: 42, y: 7 }
  assert(eq(v + w, 49))
}
test "string_interp_basic" {
  let name = "world"
  let msg = "hello \(name)!"
  assert(string_equals(msg, "hello world!"))
}
test "string_interp_int" {
  let n = 42
  let msg = "value: \(n)"
  assert(string_equals(msg, "value: 42"))
}
test "string_interp_expr" {
  let msg = "sum: \(add(1, 2))"
  assert(string_equals(msg, "sum: 3"))
}

// line comment test
test "line_comment" {
  // this is a comment
  let x = 1 // inline comment
  assert(eq(x, 1))
}

test "array_any" {
  assert(array_any((x: Int) -> Bool { x > 3 }, [1, 2, 4]))
  assert(not(array_any((x: Int) -> Bool { x > 5 }, [1, 2, 3])))
}
test "array_all" {
  assert(array_all((x: Int) -> Bool { x > 0 }, [1, 2, 3]))
  assert(not(array_all((x: Int) -> Bool { x > 1 }, [1, 2, 3])))
}
test "array_find" {
  assert(eq(array_find((x: Int) -> Bool { x > 2 }, [1, 2, 3, 4]), 3))
  assert(eq(array_find((x: Int) -> Bool { x > 10 }, [1, 2, 3]), -1))
}

test "cmp_neq" { assert(1 != 2) }
test "cmp_gt" { assert(3 > 2) }
test "cmp_gte" { assert(3 >= 3) }
test "cmp_lte" { assert(2 <= 3) }

// arrow function syntax
test "arrow_fn_basic" {
  let double = (x: Int) -> Int { x + x }
  assert(eq(double(5), 10))
}
test "arrow_fn_no_ret_type" {
  let inc = (x: Int) { x + 1 }
  assert(eq(inc(3), 4))
}
test "arrow_fn_multi_params" {
  let add2 = (x: Int, y: Int) -> Int { x + y }
  assert(eq(add2(3, 4), 7))
}
test "arrow_fn_in_hof" {
  let xs = array_map((x: Int) -> Int { x * 2 }, [1, 2, 3])
  assert(eq(array_get(xs, 0), 2))
  assert(eq(array_get(xs, 2), 6))
}
test "arrow_fn_in_hof_no_ret" {
  let xs = array_map((x: Int) { x * 2 }, [1, 2, 3])
  assert(eq(array_get(xs, 0), 2))
  assert(eq(array_get(xs, 2), 6))
}
