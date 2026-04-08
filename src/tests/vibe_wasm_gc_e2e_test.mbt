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

// TODO(B7): nested let rec closure self-ref needs mutable box for deferred init
// test "wasm-gc e2e: let rec factorial nested" { ... }
