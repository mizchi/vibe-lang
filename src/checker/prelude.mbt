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
  #|let assert_eq = (a: Num, b: Num) -> Unit { __assert(eq(a, b)) }
  #|trait Show
  #|trait Iterable
  #|impl Show for Int
  #|impl Show for Float
  #|impl Show for Double
  #|impl Show for Bool
  #|impl Show for Char
  #|impl Show for String
  #|impl [T] Iterable for Array[T]
  #|let to_string = [T: Show](x: T) -> String { __to_string(x) }
  #|let iter_require = [C: Iterable](xs: C) -> C { xs }
  #|let iter_length = [T](xs: Array[T]) -> Int { array_length(xs) }
  #|let iter_get = [T](xs: Array[T], index: Int) -> T { array_get(xs, index) }
  #|let array_map = [T](xs: Array[T], f: (x: T) -> T) -> Array[T] {
  #|  {
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
  #|let array_fold = [T](xs: Array[T], init: T, f: (acc: T, x: T) -> T) -> T {
  #|  let rec loop = (i: Int, acc: T) -> T {
  #|    if i < array_length(xs) {
  #|      loop(i + 1, f(acc, array_get(xs, i)))
  #|    } else {
  #|      acc
  #|    }
  #|  }
  #|  loop(0, init)
  #|}
  #|let array_filter = [T](xs: Array[T], pred: (x: T) -> Bool) -> Array[T] {
  #|  {
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
  #|let array_foreach = [T](xs: Array[T], f: (x: T) -> Unit) -> Unit {
  #|  let rec loop = (i: Int) -> Unit {
  #|    if i < array_length(xs) {
  #|      f(array_get(xs, i))
  #|      loop(i + 1)
  #|    } else { }
  #|  }
  #|  loop(0)
  #|}
  #|let array_concat = [T](xs: Array[T], ys: Array[T]) -> Array[T] {
  #|  {
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
  #|let array_any = [T](xs: Array[T], pred: (x: T) -> Bool) -> Bool {
  #|  let rec loop = (i: Int) -> Bool {
  #|    if i < array_length(xs) {
  #|      if pred(array_get(xs, i)) { true } else { loop(i + 1) }
  #|    } else { false }
  #|  }
  #|  loop(0)
  #|}
  #|let array_all = [T](xs: Array[T], pred: (x: T) -> Bool) -> Bool {
  #|  let rec loop = (i: Int) -> Bool {
  #|    if i < array_length(xs) {
  #|      if pred(array_get(xs, i)) { loop(i + 1) } else { false }
  #|    } else { true }
  #|  }
  #|  loop(0)
  #|}
  #|let array_find = [T](xs: Array[T], pred: (x: T) -> Bool) -> Option[T] {
  #|  let rec loop = (i: Int) -> Option[T] {
  #|    if i < array_length(xs) {
  #|      let v = array_get(xs, i)
  #|      if pred(v) { Some(v) } else { loop(i + 1) }
  #|    } else { None }
  #|  }
  #|  loop(0)
  #|}
  #|let array_find_index = [T](xs: Array[T], pred: (x: T) -> Bool) -> Int {
  #|  let rec loop = (i: Int) -> Int {
  #|    if i < array_length(xs) {
  #|      if pred(array_get(xs, i)) { i } else { loop(i + 1) }
  #|    } else { 0 - 1 }
  #|  }
  #|  loop(0)
  #|}
  #|let array_find_last_index = [T](xs: Array[T], pred: (x: T) -> Bool) -> Int {
  #|  let rec loop = (i: Int) -> Int {
  #|    if i >= 0 {
  #|      if pred(array_get(xs, i)) { i } else { loop(i - 1) }
  #|    } else { 0 - 1 }
  #|  }
  #|  loop(array_length(xs) - 1)
  #|}
  #|let array_contains_by = [T](xs: Array[T], pred: (x: T) -> Bool) -> Bool {
  #|  let rec loop = (i: Int) -> Bool {
  #|    if i < array_length(xs) {
  #|      if pred(array_get(xs, i)) { true } else { loop(i + 1) }
  #|    } else { false }
  #|  }
  #|  loop(0)
  #|}
  #|let array_reverse = [T](xs: Array[T]) -> Array[T] {
  #|  {
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
  #|let rec array_sort = (xs: Array[Num]) -> Array[Num] {
  #|  let len = array_length(xs)
  #|  if len < 2 { xs } else {
  #|    let mid = div(len, 2)
  #|    let left = array_sort(array_slice(xs, 0, mid))
  #|    let right = array_sort(array_slice(xs, mid, len))
  #|    {
  #|      let b = array_builder()
  #|      let ll = array_length(left)
  #|      let rl = array_length(right)
  #|      let rec merge = (li: Int, ri: Int) -> Unit {
  #|        if li < ll {
  #|          if ri < rl {
  #|            if lt(array_get(left, li), array_get(right, ri)) {
  #|              array_builder_push(b, array_get(left, li))
  #|              merge(li + 1, ri)
  #|            } else {
  #|              array_builder_push(b, array_get(right, ri))
  #|              merge(li, ri + 1)
  #|            }
  #|          } else {
  #|            array_builder_push(b, array_get(left, li))
  #|            merge(li + 1, ri)
  #|          }
  #|        } else {
  #|          if ri < rl {
  #|            array_builder_push(b, array_get(right, ri))
  #|            merge(li, ri + 1)
  #|          } else { }
  #|        }
  #|      }
  #|      merge(0, 0)
  #|      array_builder_freeze(b)
  #|    }
  #|  }
  #|}
  #|let array_contains = (xs: Array[Num], value: Num) -> Bool {
  #|  let rec loop = (i: Int) -> Bool {
  #|    if i < array_length(xs) {
  #|      if eq(array_get(xs, i), value) { true } else { loop(i + 1) }
  #|    } else { false }
  #|  }
  #|  loop(0)
  #|}
  #|let array_join = [T](xs: Array[T], sep: String) -> String { string_join(xs, sep) }
  #|let string_concat_all = (parts: Array[String]) -> String {
  #|  let sb = string_builder()
  #|  let rec loop = (i: Int) -> Unit {
  #|    if i < array_length(parts) {
  #|      string_builder_push(sb, array_get(parts, i))
  #|      loop(i + 1)
  #|    } else { }
  #|  }
  #|  loop(0)
  #|  string_builder_freeze(sb)
  #|}
  #|let option_map = [T](opt: Option[T], f: (x: T) -> T) -> Option[T] {
  #|  match opt {
  #|    Some(x) => Some(f(x)),
  #|    None => None
  #|  }
  #|}
  #|let option_flat_map = [T](opt: Option[T], f: (x: T) -> Option[T]) -> Option[T] {
  #|  match opt {
  #|    Some(x) => f(x),
  #|    None => None
  #|  }
  #|}
  #|let option_or_else = [T](opt: Option[T], default: T) -> T {
  #|  match opt {
  #|    Some(x) => x,
  #|    None => default
  #|  }
  #|}
  #|let option_is_some = [T](opt: Option[T]) -> Bool {
  #|  match opt {
  #|    Some(_) => true,
  #|    None => false
  #|  }
  #|}
  #|let option_is_none = [T](opt: Option[T]) -> Bool {
  #|  match opt {
  #|    Some(_) => false,
  #|    None => true
  #|  }
  #|}
  #|let map_get_or = [K, V](m: Map[K, V], key: K, default: V) -> V {
  #|  if map_has_key(m, key) { map_get(m, key) } else { default }
  #|}
  #|let map_map = [K, V](m: Map[K, V], f: (v: V) -> V) -> Map[K, V] {
  #|  {
  #|    let b = map_builder()
  #|    let keys = map_keys(m)
  #|    let len = array_length(keys)
  #|    let rec loop = (i: Int) -> Unit {
  #|      if i < len {
  #|        let k = array_get(keys, i)
  #|        map_builder_set(b, k, f(map_get(m, k)))
  #|        loop(i + 1)
  #|      } else { }
  #|    }
  #|    loop(0)
  #|    map_builder_freeze(b)
  #|  }
  #|}
  #|let map_filter = [K, V](m: Map[K, V], pred: (v: V) -> Bool) -> Map[K, V] {
  #|  {
  #|    let b = map_builder()
  #|    let keys = map_keys(m)
  #|    let len = array_length(keys)
  #|    let rec loop = (i: Int) -> Unit {
  #|      if i < len {
  #|        let k = array_get(keys, i)
  #|        let v = map_get(m, k)
  #|        if pred(v) {
  #|          map_builder_set(b, k, v)
  #|        } else { }
  #|        loop(i + 1)
  #|      } else { }
  #|    }
  #|    loop(0)
  #|    map_builder_freeze(b)
  #|  }
  #|}
  #|let map_size = [K, V](m: Map[K, V]) -> Int {
  #|  array_length(map_keys(m))
  #|}
  #|let map_foreach = [K, V](m: Map[K, V], f: (key: K, value: V) -> Unit) -> Unit {
  #|  let keys = map_keys(m)
  #|  let rec loop = (i: Int) -> Unit {
  #|    if i < array_length(keys) {
  #|      let k = array_get(keys, i)
  #|      f(k, map_get(m, k))
  #|      loop(i + 1)
  #|    } else { }
  #|  }
  #|  loop(0)
  #|}
  #|let map_entries = [K, V](m: Map[K, V]) -> Array[(K, V)] {
  #|  let keys = map_keys(m)
  #|  let b = array_builder()
  #|  let rec loop = (i: Int) -> Unit {
  #|    if i < array_length(keys) {
  #|      let k = array_get(keys, i)
  #|      array_builder_push(b, (k, map_get(m, k)))
  #|      loop(i + 1)
  #|    } else { }
  #|  }
  #|  loop(0)
  #|  array_builder_freeze(b)
  #|}
  #|let map_merge = [K, V](a: Map[K, V], b: Map[K, V]) -> Map[K, V] {
  #|  {
  #|    let out = map_builder()
  #|    let ka = map_keys(a)
  #|    let rec loop1 = (i: Int) -> Unit {
  #|      if i < array_length(ka) {
  #|        let k = array_get(ka, i)
  #|        map_builder_set(out, k, map_get(a, k))
  #|        loop1(i + 1)
  #|      } else { }
  #|    }
  #|    loop1(0)
  #|    let kb = map_keys(b)
  #|    let rec loop2 = (i: Int) -> Unit {
  #|      if i < array_length(kb) {
  #|        let k = array_get(kb, i)
  #|        map_builder_set(out, k, map_get(b, k))
  #|        loop2(i + 1)
  #|      } else { }
  #|    }
  #|    loop2(0)
  #|    map_builder_freeze(out)
  #|  }
  #|}
  #|let where = [T](xs: Array[T], pred: (x: T) -> Bool) -> Array[T] {
  #|  {
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
    "iter_require", "iter_length", "iter_get", "array_map", "array_fold", "array_filter",
    "array_foreach", "array_concat", "array_reverse", "array_any", "array_all", "array_find",
    "assert_eq", "array_sort", "array_contains", "array_join", "map_get_or", "map_map",
    "map_filter", "where",
  ]
}
