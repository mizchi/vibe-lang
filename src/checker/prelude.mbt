///|
let prelude_source : String =
  #|let add = (x: Num, y: Num) -> Num { __add(x, y) }
  #|let sub = (x: Num, y: Num) -> Num { __sub(x, y) }
  #|let mul = (x: Num, y: Num) -> Num { __mul(x, y) }
  #|let div = (x: Num, y: Num) -> Num { __div(x, y) }
  #|let eq = (x: Num, y: Num) -> Bool { __eq(x, y) }
  #|let lt = (x: Num, y: Num) -> Bool { __lt(x, y) }
  #|let not = (x: Bool) -> Bool { if x { false } else { true } }
  #|let and = (x: Bool, y: Bool) -> Bool { if x { y } else { false } }
  #|let or = (x: Bool, y: Bool) -> Bool { if x { true } else { y } }
  #|let assert = (cond: Bool) -> Unit { __assert(cond) }
  #|trait Show
  #|impl Show for Int
  #|impl Show for Float
  #|impl Show for Double
  #|impl Show for Bool
  #|impl Show for String
  #|let to_string = [T: Show](x: T) -> String { __to_string(x) }
  #|let array_map = (f: (x: Num) -> Num, xs: Array[Num]) -> Array[Num] {
  #|  do {
  #|    let b = array_builder()
  #|    let rec loop = (i: Int) -> Unit {
  #|      if i < array_length(xs) {
  #|        array_builder_push(b, f(array_get(xs, i)))
  #|        loop(i + 1)
  #|      } else { }
  #|    }
  #|    loop(0)
  #|    array_builder_freeze(b)
  #|  }
  #|}
  #|let array_fold = (f: (acc: Num, x: Num) -> Num, init: Num, xs: Array[Num]) -> Num {
  #|  let rec loop = (i: Int, acc: Num) -> Num {
  #|    if i < array_length(xs) {
  #|      loop(i + 1, f(acc, array_get(xs, i)))
  #|    } else {
  #|      acc
  #|    }
  #|  }
  #|  loop(0, init)
  #|}
  #|let array_filter = (pred: (x: Num) -> Bool, xs: Array[Num]) -> Array[Num] {
  #|  do {
  #|    let b = array_builder()
  #|    let rec loop = (i: Int) -> Unit {
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
  #|let array_foreach = (f: (x: Num) -> Unit, xs: Array[Num]) -> Unit {
  #|  let rec loop = (i: Int) -> Unit {
  #|    if i < array_length(xs) {
  #|      f(array_get(xs, i))
  #|      loop(i + 1)
  #|    } else { }
  #|  }
  #|  loop(0)
  #|}
  #|let array_concat = (xs: Array[Num], ys: Array[Num]) -> Array[Num] {
  #|  do {
  #|    let b = array_builder()
  #|    let rec loop1 = (i: Int) -> Unit {
  #|      if i < array_length(xs) {
  #|        array_builder_push(b, array_get(xs, i))
  #|        loop1(i + 1)
  #|      } else { }
  #|    }
  #|    loop1(0)
  #|    let rec loop2 = (i: Int) -> Unit {
  #|      if i < array_length(ys) {
  #|        array_builder_push(b, array_get(ys, i))
  #|        loop2(i + 1)
  #|      } else { }
  #|    }
  #|    loop2(0)
  #|    array_builder_freeze(b)
  #|  }
  #|}
  #|let array_any = (pred: (x: Num) -> Bool, xs: Array[Num]) -> Bool {
  #|  let rec loop = (i: Int) -> Bool {
  #|    if i < array_length(xs) {
  #|      if pred(array_get(xs, i)) { true } else { loop(i + 1) }
  #|    } else { false }
  #|  }
  #|  loop(0)
  #|}
  #|let array_all = (pred: (x: Num) -> Bool, xs: Array[Num]) -> Bool {
  #|  let rec loop = (i: Int) -> Bool {
  #|    if i < array_length(xs) {
  #|      if pred(array_get(xs, i)) { loop(i + 1) } else { false }
  #|    } else { true }
  #|  }
  #|  loop(0)
  #|}
  #|let array_find = (pred: (x: Num) -> Bool, xs: Array[Num]) -> Num {
  #|  let rec loop = (i: Int) -> Num {
  #|    if i < array_length(xs) {
  #|      let v = array_get(xs, i)
  #|      if pred(v) { v } else { loop(i + 1) }
  #|    } else { -1 }
  #|  }
  #|  loop(0)
  #|}
  #|let array_reverse = (xs: Array[Num]) -> Array[Num] {
  #|  do {
  #|    let b = array_builder()
  #|    let len = array_length(xs)
  #|    let rec loop = (i: Int) -> Unit {
  #|      if i >= 0 {
  #|        array_builder_push(b, array_get(xs, i))
  #|        loop(i - 1)
  #|      } else { }
  #|    }
  #|    loop(len - 1)
  #|    array_builder_freeze(b)
  #|  }
  #|}
  #|let where = (xs: Array[String], pred: (x: String) -> Bool) -> Array[String] {
  #|  do {
  #|    let b = array_builder()
  #|    let rec loop = (i: Int) -> Unit {
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

///|
pub fn prelude_ast() -> @core.Module {
  try! @parser.parse_ast(prelude_source)
}

///|
pub fn prelude_names() -> Array[String] {
  [
    "add", "sub", "mul", "div", "eq", "lt", "not", "and", "or", "assert", "to_string",
    "array_map", "array_fold", "array_filter", "array_foreach", "array_concat", "array_reverse",
    "array_any", "array_all", "array_find", "where",
  ]
}
