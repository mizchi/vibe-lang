///|
let prelude_source : String =
  #|let add = fn (x: Int, y: Int) -> Int { __add(x, y) }
  #|let sub = fn (x: Int, y: Int) -> Int { __sub(x, y) }
  #|let mul = fn (x: Int, y: Int) -> Int { __mul(x, y) }
  #|let div = fn (x: Int, y: Int) -> Int { __div(x, y) }
  #|let eq = fn (x: Int, y: Int) -> Bool { __eq(x, y) }
  #|let lt = fn (x: Int, y: Int) -> Bool { __lt(x, y) }
  #|let not = fn (x: Bool) -> Bool { if x { false } else { true } }
  #|let and = fn (x: Bool, y: Bool) -> Bool { if x { y } else { false } }
  #|let or = fn (x: Bool, y: Bool) -> Bool { if x { true } else { y } }
  #|let assert = fn (cond: Bool) -> Unit { __assert(cond) }

///|
fn prelude_ast() -> Module {
  try! parse_ast(prelude_source)
}

///|
pub fn prelude_names() -> Array[String] {
  ["add", "sub", "mul", "div", "eq", "lt", "not", "and", "or", "assert"]
}
