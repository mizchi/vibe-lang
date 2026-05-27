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
    #|let sum2 = (a: Int, b: Int) -> Int { a + b }
    #|let main = () -> Int { sum2(3, 4) }
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
    #|enum Outcome { Success(Int); Failure }
    #|let main = () -> Int {
    #|  let r = Success(42)
    #|  match r {
    #|    Success(n) => n
    #|    Failure => 0
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
test "wasm-gc e2e: Array::fold" {
  let src =
    #|let arr = [1, 2, 3, 4, 5]
    #|let sum = Array::fold(arr, 0, (acc: Int, x: Int) -> Int { acc + x })
    #|sum
  assert_gc_e2e(src, "array_fold", 15)
}

///|
test "wasm-gc e2e: let-else success path" {
  let src =
    #|let extract = (x: Int) -> Int {
    #|  let Some(v) = Some(x) else { 0 }
    #|  v * 2
    #|}
    #|extract(21)
  assert_gc_e2e(src, "let_else_success", 42)
}

///|
test "wasm-gc e2e: generic list iter_get" {
  let src =
    #|enum List[T] { Nil; Cons(T, List[T]) }
    #|impl [T] Iterable for List[T]
    #|let list_of3 = [T](a: T, b: T, c: T) -> List[T] {
    #|  Cons(a, Cons(b, Cons(c, Nil)))
    #|}
    #|let rec list_iter_get = [T](xs: List[T], index: Int) -> T {
    #|  match xs {
    #|    Cons(h, t) => if index == 0 { h } else { list_iter_get(t, index - 1) },
    #|    Nil => list_iter_get(xs, index)
    #|  }
    #|}
    #|let List::iter_get = [T](xs: List[T], index: Int) -> T { list_iter_get(xs, index) }
    #|let main = () -> Int {
    #|  List::iter_get(list_of3(1, 2, 3), 1)
    #|}
    #|main()
  assert_gc_e2e(src, "generic_list_iter_get", 2)
}

///|
test "wasm-gc e2e: generic iterator fold over list" {
  let src =
    #|enum List[T] { Nil; Cons(T, List[T]) }
    #|impl [T] Iterable for List[T]
    #|let list_of3 = [T](a: T, b: T, c: T) -> List[T] {
    #|  Cons(a, Cons(b, Cons(c, Nil)))
    #|}
    #|let rec list_length = [T](xs: List[T]) -> Int {
    #|  match xs {
    #|    Nil => 0,
    #|    Cons(_, t) => 1 + list_length(t)
    #|  }
    #|}
    #|let rec list_iter_get = [T](xs: List[T], index: Int) -> T {
    #|  match xs {
    #|    Cons(h, t) => if index == 0 { h } else { list_iter_get(t, index - 1) },
    #|    Nil => list_iter_get(xs, index)
    #|  }
    #|}
    #|let List::iter_get = [T](xs: List[T], index: Int) -> T { list_iter_get(xs, index) }
    #|let List::iter_length = [T](xs: List[T]) -> Int { list_length(xs) }
    #|let Iterator::fold = [C: Iterable, T, B](xs: C, init: B, f: (acc: B, x: T) -> B) -> B {
    #|  let len = xs|>iter_length
    #|  let mut i = 0
    #|  let mut acc = init
    #|  while i < len {
    #|    acc = f(acc, xs|>iter_get(i))
    #|    i = i + 1
    #|  }
    #|  acc
    #|}
    #|let main = () -> Int {
    #|  Iterator::fold(list_of3(1, 2, 3), 0, (acc: Int, x: Int) -> Int { acc + x })
    #|}
    #|main()
  assert_gc_e2e(src, "generic_iterator_fold_list", 6)
}

///|
test "wasm-gc e2e: generic iterator map over list" {
  let src =
    #|enum List[T] { Nil; Cons(T, List[T]) }
    #|impl [T] Iterable for List[T]
    #|let list_of3 = [T](a: T, b: T, c: T) -> List[T] {
    #|  Cons(a, Cons(b, Cons(c, Nil)))
    #|}
    #|let rec list_iter_get = [T](xs: List[T], index: Int) -> T {
    #|  match xs {
    #|    Cons(h, t) => if index == 0 { h } else { list_iter_get(t, index - 1) },
    #|    Nil => list_iter_get(xs, index)
    #|  }
    #|}
    #|let rec list_length = [T](xs: List[T]) -> Int {
    #|  match xs {
    #|    Nil => 0,
    #|    Cons(_, t) => 1 + list_length(t)
    #|  }
    #|}
    #|let List::iter_get = [T](xs: List[T], index: Int) -> T { list_iter_get(xs, index) }
    #|let List::iter_length = [T](xs: List[T]) -> Int { list_length(xs) }
    #|let Iterator::r#map = [C: Iterable, A, B](xs: C, f: (x: A) -> B) -> Array[B] {
    #|  let len = xs|>iter_length
    #|  {
    #|    let acc = ArrayBuilder::new()
    #|    let mut i = 0
    #|    while i < len {
    #|      ArrayBuilder::push(acc, f(xs|>iter_get(i)))
    #|      i = i + 1
    #|    }
    #|    ArrayBuilder::freeze(acc)
    #|  }
    #|}
    #|let main = () -> Int {
    #|  let doubled = Iterator::r#map(list_of3(1, 2, 3), (x: Int) -> Int { x * 2 })
    #|  Array::get(doubled, 2)
    #|}
    #|main()
  assert_gc_e2e(src, "generic_iterator_map_list", 6)
}

///|
test "wasm-gc e2e: generic iterator filter over list" {
  let src =
    #|enum List[T] { Nil; Cons(T, List[T]) }
    #|impl [T] Iterable for List[T]
    #|let list_of4 = [T](a: T, b: T, c: T, d: T) -> List[T] {
    #|  Cons(a, Cons(b, Cons(c, Cons(d, Nil))))
    #|}
    #|let rec list_iter_get = [T](xs: List[T], index: Int) -> T {
    #|  match xs {
    #|    Cons(h, t) => if index == 0 { h } else { list_iter_get(t, index - 1) },
    #|    Nil => list_iter_get(xs, index)
    #|  }
    #|}
    #|let rec list_length = [T](xs: List[T]) -> Int {
    #|  match xs {
    #|    Nil => 0,
    #|    Cons(_, t) => 1 + list_length(t)
    #|  }
    #|}
    #|let List::iter_get = [T](xs: List[T], index: Int) -> T { list_iter_get(xs, index) }
    #|let List::iter_length = [T](xs: List[T]) -> Int { list_length(xs) }
    #|let Iterator::filter = [C: Iterable, T](xs: C, pred: (x: T) -> Bool) -> Array[T] {
    #|  let len = xs|>iter_length
    #|  {
    #|    let acc = ArrayBuilder::new()
    #|    let mut i = 0
    #|    while i < len {
    #|      let value = xs|>iter_get(i)
    #|      if pred(value) {
    #|        ArrayBuilder::push(acc, value)
    #|      }
    #|      i = i + 1
    #|    }
    #|    ArrayBuilder::freeze(acc)
    #|  }
    #|}
    #|let main = () -> Int {
    #|  let evens = Iterator::filter(list_of4(1, 2, 3, 4), (x: Int) -> Bool { x % 2 == 0 })
    #|  Array::get(evens, 1)
    #|}
    #|main()
  assert_gc_e2e(src, "generic_iterator_filter_list", 4)
}

///|
test "wasm-gc e2e: generic iterator flatmap over list" {
  let src =
    #|enum List[T] { Nil; Cons(T, List[T]) }
    #|impl [T] Iterable for List[T]
    #|let list_of3 = [T](a: T, b: T, c: T) -> List[T] {
    #|  Cons(a, Cons(b, Cons(c, Nil)))
    #|}
    #|let rec list_iter_get = [T](xs: List[T], index: Int) -> T {
    #|  match xs {
    #|    Cons(h, t) => if index == 0 { h } else { list_iter_get(t, index - 1) },
    #|    Nil => list_iter_get(xs, index)
    #|  }
    #|}
    #|let rec list_length = [T](xs: List[T]) -> Int {
    #|  match xs {
    #|    Nil => 0,
    #|    Cons(_, t) => 1 + list_length(t)
    #|  }
    #|}
    #|let List::iter_get = [T](xs: List[T], index: Int) -> T { list_iter_get(xs, index) }
    #|let List::iter_length = [T](xs: List[T]) -> Int { list_length(xs) }
    #|let Iterator::flatmap = [C: Iterable, A, B](xs: C, f: (x: A) -> Array[B]) -> Array[B] {
    #|  let len = xs|>iter_length
    #|  {
    #|    let acc = ArrayBuilder::new()
    #|    let mut i = 0
    #|    while i < len {
    #|      let chunk = f(xs|>iter_get(i))
    #|      let chunk_len = Array::length(chunk)
    #|      let mut j = 0
    #|      while j < chunk_len {
    #|        ArrayBuilder::push(acc, Array::get(chunk, j))
    #|        j = j + 1
    #|      }
    #|      i = i + 1
    #|    }
    #|    ArrayBuilder::freeze(acc)
    #|  }
    #|}
    #|let main = () -> Int {
    #|  let duplicated = Iterator::flatmap(list_of3(1, 3, 5), (x: Int) -> Array[Int] { [x, x + 1] })
    #|  Array::get(duplicated, 5)
    #|}
    #|main()
  assert_gc_e2e(src, "generic_iterator_flatmap_list", 6)
}

///|
test "wasm-gc e2e: generic iterator filter over trio" {
  let src =
    #|enum Trio[T] { Trio(T, T, T) }
    #|impl [T] Iterable for Trio[T]
    #|let trio_of3 = [T](a: T, b: T, c: T) -> Trio[T] { Trio(a, b, c) }
    #|let Trio::iter_length = [T](_xs: Trio[T]) -> Int { 3 }
    #|let Trio::iter_get = [T](xs: Trio[T], index: Int) -> T {
    #|  match xs {
    #|    Trio(a, b, c) => if index == 0 { a } else if index == 1 { b } else { c }
    #|  }
    #|}
    #|let Iterator::filter = [C: Iterable, T](xs: C, pred: (x: T) -> Bool) -> Array[T] {
    #|  let len = xs|>iter_length
    #|  {
    #|    let acc = ArrayBuilder::new()
    #|    let mut i = 0
    #|    while i < len {
    #|      let value = xs|>iter_get(i)
    #|      if pred(value) {
    #|        ArrayBuilder::push(acc, value)
    #|      }
    #|      i = i + 1
    #|    }
    #|    ArrayBuilder::freeze(acc)
    #|  }
    #|}
    #|let main = () -> Int {
    #|  let evens = Iterator::filter(trio_of3(1, 2, 4), (x: Int) -> Bool { x % 2 == 0 })
    #|  Array::get(evens, 1)
    #|}
    #|main()
  assert_gc_e2e(src, "generic_iterator_filter_trio", 4)
}

///|
test "wasm-gc e2e: generic iterator flatmap over trio" {
  let src =
    #|enum Trio[T] { Trio(T, T, T) }
    #|impl [T] Iterable for Trio[T]
    #|let trio_of3 = [T](a: T, b: T, c: T) -> Trio[T] { Trio(a, b, c) }
    #|let Trio::iter_length = [T](_xs: Trio[T]) -> Int { 3 }
    #|let Trio::iter_get = [T](xs: Trio[T], index: Int) -> T {
    #|  match xs {
    #|    Trio(a, b, c) => if index == 0 { a } else if index == 1 { b } else { c }
    #|  }
    #|}
    #|let Iterator::flatmap = [C: Iterable, A, B](xs: C, f: (x: A) -> Array[B]) -> Array[B] {
    #|  let len = xs|>iter_length
    #|  {
    #|    let acc = ArrayBuilder::new()
    #|    let mut i = 0
    #|    while i < len {
    #|      let chunk = f(xs|>iter_get(i))
    #|      let chunk_len = Array::length(chunk)
    #|      let mut j = 0
    #|      while j < chunk_len {
    #|        ArrayBuilder::push(acc, Array::get(chunk, j))
    #|        j = j + 1
    #|      }
    #|      i = i + 1
    #|    }
    #|    ArrayBuilder::freeze(acc)
    #|  }
    #|}
    #|let main = () -> Int {
    #|  let duplicated = Iterator::flatmap(trio_of3(1, 3, 5), (x: Int) -> Array[Int] { [x, x + 1] })
    #|  Array::get(duplicated, 5)
    #|}
    #|main()
  assert_gc_e2e(src, "generic_iterator_flatmap_trio", 6)
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
test "wasm-gc e2e: Map::get with string keys" {
  let src =
    #|let main = () -> Int {
    #|  let b = MapBuilder::new()
    #|  MapBuilder::set(b, "x", 10)
    #|  MapBuilder::set(b, "y", 20)
    #|  let m = MapBuilder::freeze(b)
    #|  let vx = Map::get(m, "x")
    #|  let vy = Map::get(m, "y")
    #|  vx + vy
    #|}
    #|main()
  assert_gc_e2e(src, "map_get_string_keys", 30)
}

///|
test "wasm-gc e2e: Map::has_key with string keys" {
  let src =
    #|let main = () -> Int {
    #|  let b = MapBuilder::new()
    #|  MapBuilder::set(b, "k", 42)
    #|  let m = MapBuilder::freeze(b)
    #|  if Map::has_key(m, "k") { 1 } else { 0 }
    #|}
    #|main()
  assert_gc_e2e(src, "map_has_key_string", 1)
}

///|
test "wasm-gc e2e: Map::get not found with has_key guard" {
  let src =
    #|let main = () -> Int {
    #|  let b = MapBuilder::new()
    #|  MapBuilder::set(b, "a", 99)
    #|  let m = MapBuilder::freeze(b)
    #|  if Map::has_key(m, "missing") { Map::get(m, "missing") } else { -1 }
    #|}
    #|main()
  assert_gc_e2e(src, "map_get_not_found", -1)
}

///|
test "wasm-gc e2e: MapBuilder::set overwrites existing key" {
  let src =
    #|let main = () -> Int {
    #|  let b = MapBuilder::new()
    #|  MapBuilder::set(b, "k", 10)
    #|  MapBuilder::set(b, "k", 42)
    #|  let m = MapBuilder::freeze(b)
    #|  Map::get(m, "k")
    #|}
    #|main()
  assert_gc_e2e(src, "map_set_overwrite", 42)
}

///|
test "wasm-gc e2e: Map::get with int keys" {
  let src =
    #|let main = () -> Int {
    #|  let b = MapBuilder::new()
    #|  MapBuilder::set(b, 1, 100)
    #|  MapBuilder::set(b, 2, 200)
    #|  MapBuilder::set(b, 3, 300)
    #|  let m = MapBuilder::freeze(b)
    #|  Map::get(m, 2)
    #|}
    #|main()
  assert_gc_e2e(src, "map_get_int_keys", 200)
}

///|
test "wasm-gc e2e: Map::keys" {
  let src =
    #|let main = () -> Int {
    #|  let b = MapBuilder::new()
    #|  MapBuilder::set(b, "a", 1)
    #|  MapBuilder::set(b, "b", 2)
    #|  MapBuilder::set(b, "c", 3)
    #|  let m = MapBuilder::freeze(b)
    #|  let keys = Map::keys(m)
    #|  Array::length(keys)
    #|}
    #|main()
  assert_gc_e2e(src, "map_keys", 3)
}

///|
test "wasm-gc e2e: Map::has_key with int keys" {
  let src =
    #|let main = () -> Int {
    #|  let b = MapBuilder::new()
    #|  MapBuilder::set(b, 10, 100)
    #|  MapBuilder::set(b, 20, 200)
    #|  let m = MapBuilder::freeze(b)
    #|  let has10 = Map::has_key(m, 10)
    #|  let has99 = Map::has_key(m, 99)
    #|  if has10 && not(has99) { 1 } else { 0 }
    #|}
    #|main()
  assert_gc_e2e(src, "map_has_key_int", 1)
}

///|
test "wasm-gc e2e: Map::get arithmetic on results" {
  let src =
    #|let main = () -> Int {
    #|  let b = MapBuilder::new()
    #|  MapBuilder::set(b, "x", 10)
    #|  MapBuilder::set(b, "y", 20)
    #|  let m = MapBuilder::freeze(b)
    #|  let vx = Map::get(m, "x")
    #|  let vy = Map::get(m, "y")
    #|  vx * vy
    #|}
    #|main()
  assert_gc_e2e(src, "map_get_arithmetic", 200)
}

///|
test "wasm-gc e2e: map literal index sugar" {
  let src =
    #|let m = map { "a": 10, "b": 20, "c": 30 }
    #|let v = m["b"]
    #|v
  assert_gc_e2e(src, "map_literal_index", 20)
}

///|
test "wasm-gc e2e: throw/handle error-only" {
  let src =
    #|let main = () -> Int {
    #|  handle {
    #|    throw("error")
    #|    0
    #|  } with Error {
    #|    Throw(e) => {
    #|      let _ = e
    #|      42
    #|    };
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
    #|  } with Error {
    #|    Throw(e) => {
    #|      let _ = e
    #|      0
    #|    };
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

///|
test "wasm-gc e2e: let rec nested helper captures outer local (#273)" {
  let src =
    #|let sum_range = (n: Int) -> Int {
    #|  let rec helper: (Int, Int) -> Int = (i, acc) -> {
    #|    if i > n { acc } else { helper(i + 1, acc + i) }
    #|  }
    #|  helper(1, 0)
    #|}
    #|sum_range(100)
  assert_gc_e2e(src, "let_rec_nested_capture", 5050)
}

///|
test "wasm-gc e2e: return from inside while loop" {
  // `return` must escape the function frame, not just the loop. If
  // return were wrongly desugared into `break`, the function would
  // fall through to the trailing `-1`.
  let src =
    #|let find_first_neg: (Array[Int]) -> Int = (arr) -> {
    #|  let mut i = 0
    #|  while i < Array::length(arr) {
    #|    if Array::get(arr, i) < 0 {
    #|      return i
    #|    }
    #|    i = i + 1
    #|  }
    #|  -1
    #|}
    #|find_first_neg([1, 2, -3, 4])
  assert_gc_e2e(src, "return_from_while", 2)
}

///|
test "wasm-gc e2e: return at function tail (equivalent to tail expr)" {
  let src =
    #|let twice: (Int) -> Int = (n) -> {
    #|  return n * 2
    #|}
    #|twice(21)
  assert_gc_e2e(src, "return_tail", 42)
}

///|
test "wasm-gc e2e: mut struct field — write then read" {
  // ADR-0052: `mut` field becomes a wasm-gc struct.set / struct.get.
  let src =
    #|struct Counter {
    #|  mut count: Int
    #|}
    #|let main: () -> Int = () -> {
    #|  let c = Counter::{ count: 7 }
    #|  c.count = 42
    #|  c.count
    #|}
    #|main()
  assert_gc_e2e(src, "mut_field_set_get", 42)
}

///|
test "wasm-gc e2e: mut struct field — compound update" {
  let src =
    #|struct Counter {
    #|  mut count: Int
    #|}
    #|let bump = (c: Counter) -> Unit {
    #|  c.count = c.count + 1
    #|}
    #|let main: () -> Int = () -> {
    #|  let c = Counter::{ count: 10 }
    #|  bump(c)
    #|  bump(c)
    #|  bump(c)
    #|  c.count
    #|}
    #|main()
  assert_gc_e2e(src, "mut_field_compound", 13)
}

///|
/// FixedArray parity on wasm-gc. Lowers to `array.new` / `array.get` /
/// `array.set` directly, so storage is i64 cells (no 30-bit tag
/// truncation like linear's `Array::push` / `Array::get`).
test "wasm-gc e2e: FixedArray::make + set + get roundtrip" {
  let src =
    #|let main = () -> Int {
    #|  let arr = FixedArray::make(4, 0)
    #|  FixedArray::set(arr, 0, 100)
    #|  FixedArray::set(arr, 1, 200)
    #|  FixedArray::set(arr, 2, 300)
    #|  FixedArray::set(arr, 3, 400)
    #|  FixedArray::get(arr, 2)
    #|}
    #|main()
  assert_gc_e2e(src, "fixedarray_basic", 300)
}

///|
test "wasm-gc e2e: FixedArray::length matches make size" {
  let src =
    #|let main = () -> Int {
    #|  let arr = FixedArray::make(42, 0)
    #|  FixedArray::length(arr)
    #|}
    #|main()
  assert_gc_e2e(src, "fixedarray_length", 42)
}

///|
test "wasm-gc e2e: FixedArray::unsafe_set behaves like set" {
  let src =
    #|let main = () -> Int {
    #|  let arr = FixedArray::make(3, 7)
    #|  FixedArray::unsafe_set(arr, 1, 99)
    #|  FixedArray::get(arr, 0) + FixedArray::get(arr, 1) + FixedArray::get(arr, 2)
    #|}
    #|main()
  // 7 + 99 + 7 = 113
  assert_gc_e2e(src, "fixedarray_unsafe_set", 113)
}

///|
test "wasm-gc e2e: FixedArray::blit copies a range across arrays" {
  let src =
    #|let main = () -> Int {
    #|  let src = FixedArray::make(5, 0)
    #|  FixedArray::set(src, 0, 11)
    #|  FixedArray::set(src, 1, 22)
    #|  FixedArray::set(src, 2, 33)
    #|  FixedArray::set(src, 3, 44)
    #|  FixedArray::set(src, 4, 55)
    #|  let dst = FixedArray::make(5, 0)
    #|  FixedArray::blit(dst, 1, src, 2, 3)
    #|  FixedArray::get(dst, 1) + FixedArray::get(dst, 2) + FixedArray::get(dst, 3) + FixedArray::get(dst, 0)
    #|}
    #|main()
  // dst becomes [0, 33, 44, 55, 0]; sum[1..3] + dst[0] = 132 + 0 = 132
  assert_gc_e2e(src, "fixedarray_blit", 132)
}

///|
test "wasm-gc e2e: FixedArray default value initialises all cells" {
  let src =
    #|let main = () -> Int {
    #|  let arr = FixedArray::make(5, 9)
    #|  FixedArray::get(arr, 0) + FixedArray::get(arr, 4)
    #|}
    #|main()
  assert_gc_e2e(src, "fixedarray_default", 18)
}

///|
test "wasm-gc e2e: ADR-0052 — non-mut field assignment is rejected" {
  // The checker must reject `r.field = e` when `field` was not
  // declared `mut`. We use the e2e harness's compile path (which
  // funnels through the checker) and assert that compilation fails.
  let db = VibeDb::new()
  let src =
    #|struct Counter {
    #|  count: Int
    #|}
    #|let main: () -> Int = () -> {
    #|  let c = Counter::{ count: 0 }
    #|  c.count = 5
    #|  c.count
    #|}
    #|main()
  db.set_source("main", src)
  let result = try? @runtime_compile.compile_module_wasm_gc(db, "main")
  match result {
    Ok(_) => fail("expected compile error for non-mut field assignment")
    Err(_) => () // expected
  }
}
