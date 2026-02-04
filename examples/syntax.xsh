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

let labeled = fn (x: Int, y~: String, z?: Bool) { y }
let label_call = labeled(1, y="ok")

let block_value = {
  let x = 1
  add(x, 2)
}

let match_value = match Ok(1) { Ok(v) => v, Err => 0 }
let match_tuple = match pair { (a, b) => add(a, b), _ => 0 }
let match_record = match record_value { record { a: v } => v, _ => 0 }
let match_guard = match 1 { v if lt(v, 2) => 1, _ => 0 }

let if_value = if true { 1 } else { 2 }

let built_array = do {
  let b = array_builder()
  array_builder_push(b, 1)
  array_builder_push(b, 2)
  array_builder_freeze(b)
}

test "basic" { assert(eq(add(1, 2), 3)) }
