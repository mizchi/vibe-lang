///|
let prelude_source : String =
  #|let add = fn (x: Num, y: Num) -> Num { __add(x, y) }
  #|let sub = fn (x: Num, y: Num) -> Num { __sub(x, y) }
  #|let mul = fn (x: Num, y: Num) -> Num { __mul(x, y) }
  #|let div = fn (x: Num, y: Num) -> Num { __div(x, y) }
  #|let eq = fn (x: Num, y: Num) -> Bool { __eq(x, y) }
  #|let lt = fn (x: Num, y: Num) -> Bool { __lt(x, y) }
  #|let not = fn (x: Bool) -> Bool { if x { false } else { true } }
  #|let and = fn (x: Bool, y: Bool) -> Bool { if x { y } else { false } }
  #|let or = fn (x: Bool, y: Bool) -> Bool { if x { true } else { y } }
  #|let assert = fn (cond: Bool) -> Unit { __assert(cond) }
  #|let array_map = fn (f: fn (x: Num) -> Num, xs: Array[Num]) -> Array[Num] {
  #|  do {
  #|    let b = array_builder()
  #|    let rec loop = fn (i: Int) -> Unit {
  #|      if i < array_length(xs) {
  #|        array_builder_push(b, f(array_get(xs, i)))
  #|        loop(i + 1)
  #|      } else { }
  #|    }
  #|    loop(0)
  #|    array_builder_freeze(b)
  #|  }
  #|}
  #|let array_fold = fn (f: fn (acc: Num, x: Num) -> Num, init: Num, xs: Array[Num]) -> Num {
  #|  let rec loop = fn (i: Int, acc: Num) -> Num {
  #|    if i < array_length(xs) {
  #|      loop(i + 1, f(acc, array_get(xs, i)))
  #|    } else {
  #|      acc
  #|    }
  #|  }
  #|  loop(0, init)
  #|}
  #|let array_filter = fn (pred: fn (x: Num) -> Bool, xs: Array[Num]) -> Array[Num] {
  #|  do {
  #|    let b = array_builder()
  #|    let rec loop = fn (i: Int) -> Unit {
  #|      if i < array_length(xs) {
  #|        let v = array_get(xs, i)
  #|        if pred(v) {
  #|          array_builder_push(b, v)
  #|        } else { }
  #|        loop(i + 1)
  #|      } else { }
  #|    }
  #|    loop(0)
  #|    array_builder_freeze(b)
  #|  }
  #|}
  #|let array_foreach = fn (f: fn (x: Num) -> Unit, xs: Array[Num]) -> Unit {
  #|  let rec loop = fn (i: Int) -> Unit {
  #|    if i < array_length(xs) {
  #|      f(array_get(xs, i))
  #|      loop(i + 1)
  #|    } else { }
  #|  }
  #|  loop(0)
  #|}
  #|let array_concat = fn (xs: Array[Num], ys: Array[Num]) -> Array[Num] {
  #|  do {
  #|    let b = array_builder()
  #|    let rec loop1 = fn (i: Int) -> Unit {
  #|      if i < array_length(xs) {
  #|        array_builder_push(b, array_get(xs, i))
  #|        loop1(i + 1)
  #|      } else { }
  #|    }
  #|    loop1(0)
  #|    let rec loop2 = fn (i: Int) -> Unit {
  #|      if i < array_length(ys) {
  #|        array_builder_push(b, array_get(ys, i))
  #|        loop2(i + 1)
  #|      } else { }
  #|    }
  #|    loop2(0)
  #|    array_builder_freeze(b)
  #|  }
  #|}
  #|let array_reverse = fn (xs: Array[Num]) -> Array[Num] {
  #|  do {
  #|    let b = array_builder()
  #|    let len = array_length(xs)
  #|    let rec loop = fn (i: Int) -> Unit {
  #|      if i >= 0 {
  #|        array_builder_push(b, array_get(xs, i))
  #|        loop(i - 1)
  #|      } else { }
  #|    }
  #|    loop(len - 1)
  #|    array_builder_freeze(b)
  #|  }
  #|}

///|
pub fn prelude_ast() -> @core.Module {
  try! @parser.parse_ast(prelude_source)
}

///|
pub fn prelude_names() -> Array[String] {
  [
    "add", "sub", "mul", "div", "eq", "lt", "not", "and", "or", "assert", "array_map",
    "array_fold", "array_filter", "array_foreach", "array_concat", "array_reverse",
  ]
}
