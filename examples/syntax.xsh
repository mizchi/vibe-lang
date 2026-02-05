import "test.xsh"
alias std = core#deadbeef
flake {
  inputs = { name = "xsh" }
}

enum Result[T] { Ok(T), Err }
type IntResult = Result[Int]

let add2 = fn (x: Int) -> Int { add(x, 2) }
let rec fact = fn (n: Int) -> Int {
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

let labeled = fn (x: Int, y~: String, z?: Bool) { y }
let label_call = labeled(1, y="ok")

let effectful = fn (s: String) -> Int with {Error} { string_length(s) }
let effectful_call = fn (s: String) -> Int with {Error} { effectful(s) }
let effect_apply = fn (f: fn (x: Int) -> Int with {e}, x: Int) -> Int with {e} { f(x) }
let effectful_int = fn (x: Int) -> Int with {Error} { x }
let effectful_apply = fn (x: Int) -> Int with {Error} { effect_apply(effectful_int, x) }

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
