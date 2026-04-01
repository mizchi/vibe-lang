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
  #|let assert_true = (cond: Bool) -> Unit { __assert(cond) }
  #|let assert_eq = [T](a: T, b: T) -> Unit { __assert_eq(a, b) }
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
  #|let iter_length = [T](xs: Array[T]) -> Int { Array::length(xs) }
  #|let iter_get = [T](xs: Array[T], index: Int) -> T { Array::get(xs, index) }
  #|let Array::map = [T](xs: Array[T], f: (x: T) -> T) -> Array[T] {
  #|  {
  #|    let b = ArrayBuilder::new()
  #|    let rec go = (i: Int) -> Unit {
  #|      if i < Array::length(xs) {
  #|        ArrayBuilder::push(b, f(Array::get(xs, i)))
  #|        go(i + 1)
  #|      } else { }
  #|    }
  #|    go(0)
  #|    ArrayBuilder::freeze(b)
  #|  }
  #|}
  #|let Array::fold = [T](xs: Array[T], init: T, f: (acc: T, x: T) -> T) -> T {
  #|  let rec go = (i: Int, acc: T) -> T {
  #|    if i < Array::length(xs) {
  #|      go(i + 1, f(acc, Array::get(xs, i)))
  #|    } else {
  #|      acc
  #|    }
  #|  }
  #|  go(0, init)
  #|}
  #|let Array::filter = [T](xs: Array[T], pred: (x: T) -> Bool) -> Array[T] {
  #|  {
  #|    let b = ArrayBuilder::new()
  #|    let rec go = (i: Int) -> Unit {
  #|      if i < Array::length(xs) {
  #|        let v = Array::get(xs, i)
  #|        if pred(v) {
  #|          ArrayBuilder::push(b, v)
  #|        } else { }
  #|        go(i + 1)
  #|      } else { }
  #|    }
  #|    go(0)
  #|    ArrayBuilder::freeze(b)
  #|  }
  #|}
  #|let Array::foreach = [T](xs: Array[T], f: (x: T) -> Unit) -> Unit {
  #|  let rec go = (i: Int) -> Unit {
  #|    if i < Array::length(xs) {
  #|      f(Array::get(xs, i))
  #|      go(i + 1)
  #|    } else { }
  #|  }
  #|  go(0)
  #|}
  #|let Array::concat = [T](xs: Array[T], ys: Array[T]) -> Array[T] {
  #|  {
  #|    let b = ArrayBuilder::new()
  #|    let rec go1 = (i: Int) -> Unit {
  #|      if i < Array::length(xs) {
  #|        ArrayBuilder::push(b, Array::get(xs, i))
  #|        go1(i + 1)
  #|      } else { }
  #|    }
  #|    go1(0)
  #|    let rec go2 = (i: Int) -> Unit {
  #|      if i < Array::length(ys) {
  #|        ArrayBuilder::push(b, Array::get(ys, i))
  #|        go2(i + 1)
  #|      } else { }
  #|    }
  #|    go2(0)
  #|    ArrayBuilder::freeze(b)
  #|  }
  #|}
  #|let Array::any = [T](xs: Array[T], pred: (x: T) -> Bool) -> Bool {
  #|  let rec go = (i: Int) -> Bool {
  #|    if i < Array::length(xs) {
  #|      if pred(Array::get(xs, i)) { true } else { go(i + 1) }
  #|    } else { false }
  #|  }
  #|  go(0)
  #|}
  #|let Array::all = [T](xs: Array[T], pred: (x: T) -> Bool) -> Bool {
  #|  let rec go = (i: Int) -> Bool {
  #|    if i < Array::length(xs) {
  #|      if pred(Array::get(xs, i)) { go(i + 1) } else { false }
  #|    } else { true }
  #|  }
  #|  go(0)
  #|}
  #|let Array::find = [T](xs: Array[T], pred: (x: T) -> Bool) -> Option[T] {
  #|  let rec go = (i: Int) -> Option[T] {
  #|    if i < Array::length(xs) {
  #|      let v = Array::get(xs, i)
  #|      if pred(v) { Some(v) } else { go(i + 1) }
  #|    } else { None }
  #|  }
  #|  go(0)
  #|}
  #|let array_find_index = [T](xs: Array[T], pred: (x: T) -> Bool) -> Int {
  #|  let rec go = (i: Int) -> Int {
  #|    if i < Array::length(xs) {
  #|      if pred(Array::get(xs, i)) { i } else { go(i + 1) }
  #|    } else { 0 - 1 }
  #|  }
  #|  go(0)
  #|}
  #|let array_find_last_index = [T](xs: Array[T], pred: (x: T) -> Bool) -> Int {
  #|  let rec go = (i: Int) -> Int {
  #|    if i >= 0 {
  #|      if pred(Array::get(xs, i)) { i } else { go(i - 1) }
  #|    } else { 0 - 1 }
  #|  }
  #|  go(Array::length(xs) - 1)
  #|}
  #|let array_contains_by = [T](xs: Array[T], pred: (x: T) -> Bool) -> Bool {
  #|  let rec go = (i: Int) -> Bool {
  #|    if i < Array::length(xs) {
  #|      if pred(Array::get(xs, i)) { true } else { go(i + 1) }
  #|    } else { false }
  #|  }
  #|  go(0)
  #|}
  #|let Array::reverse = [T](xs: Array[T]) -> Array[T] {
  #|  {
  #|    let b = ArrayBuilder::new()
  #|    let len = Array::length(xs)
  #|    let rec go = (i: Int) -> Unit {
  #|      if i >= 0 {
  #|        ArrayBuilder::push(b, Array::get(xs, i))
  #|        go(i - 1)
  #|      } else { }
  #|    }
  #|    go(len - 1)
  #|    ArrayBuilder::freeze(b)
  #|  }
  #|}
  #|let rec Array::sort = (xs: Array[Num]) -> Array[Num] {
  #|  let len = Array::length(xs)
  #|  if len < 2 { xs } else {
  #|    let mid = div(len, 2)
  #|    let left = Array::sort(Array::slice(xs, 0, mid))
  #|    let right = Array::sort(Array::slice(xs, mid, len))
  #|    {
  #|      let b = ArrayBuilder::new()
  #|      let ll = Array::length(left)
  #|      let rl = Array::length(right)
  #|      let rec merge = (li: Int, ri: Int) -> Unit {
  #|        if li < ll {
  #|          if ri < rl {
  #|            if lt(Array::get(left, li), Array::get(right, ri)) {
  #|              ArrayBuilder::push(b, Array::get(left, li))
  #|              merge(li + 1, ri)
  #|            } else {
  #|              ArrayBuilder::push(b, Array::get(right, ri))
  #|              merge(li, ri + 1)
  #|            }
  #|          } else {
  #|            ArrayBuilder::push(b, Array::get(left, li))
  #|            merge(li + 1, ri)
  #|          }
  #|        } else {
  #|          if ri < rl {
  #|            ArrayBuilder::push(b, Array::get(right, ri))
  #|            merge(li, ri + 1)
  #|          } else { }
  #|        }
  #|      }
  #|      merge(0, 0)
  #|      ArrayBuilder::freeze(b)
  #|    }
  #|  }
  #|}
  #|let Array::contains = (xs: Array[Num], value: Num) -> Bool {
  #|  let rec go = (i: Int) -> Bool {
  #|    if i < Array::length(xs) {
  #|      if eq(Array::get(xs, i), value) { true } else { go(i + 1) }
  #|    } else { false }
  #|  }
  #|  go(0)
  #|}
  #|let Array::join = [T](xs: Array[T], sep: String) -> String { String::join(xs, sep) }
  #|let string_concat_all = (parts: Array[String]) -> String {
  #|  let sb = StringBuilder::new()
  #|  let rec go = (i: Int) -> Unit {
  #|    if i < Array::length(parts) {
  #|      StringBuilder::push(sb, Array::get(parts, i))
  #|      go(i + 1)
  #|    } else { }
  #|  }
  #|  go(0)
  #|  StringBuilder::freeze(sb)
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
  #|let Map::get_or = [K, V](m: Map[K, V], key: K, default: V) -> V {
  #|  if Map::has_key(m, key) { Map::get(m, key) } else { default }
  #|}
  #|let Map::map = [K, V](m: Map[K, V], f: (v: V) -> V) -> Map[K, V] {
  #|  {
  #|    let b = MapBuilder::new()
  #|    let keys = Map::keys(m)
  #|    let len = Array::length(keys)
  #|    let rec go = (i: Int) -> Unit {
  #|      if i < len {
  #|        let k = Array::get(keys, i)
  #|        MapBuilder::set(b, k, f(Map::get(m, k)))
  #|        go(i + 1)
  #|      } else { }
  #|    }
  #|    go(0)
  #|    MapBuilder::freeze(b)
  #|  }
  #|}
  #|let Map::filter = [K, V](m: Map[K, V], pred: (v: V) -> Bool) -> Map[K, V] {
  #|  {
  #|    let b = MapBuilder::new()
  #|    let keys = Map::keys(m)
  #|    let len = Array::length(keys)
  #|    let rec go = (i: Int) -> Unit {
  #|      if i < len {
  #|        let k = Array::get(keys, i)
  #|        let v = Map::get(m, k)
  #|        if pred(v) {
  #|          MapBuilder::set(b, k, v)
  #|        } else { }
  #|        go(i + 1)
  #|      } else { }
  #|    }
  #|    go(0)
  #|    MapBuilder::freeze(b)
  #|  }
  #|}
  #|let Map::size = [K, V](m: Map[K, V]) -> Int {
  #|  Array::length(Map::keys(m))
  #|}
  #|let Map::foreach = [K, V](m: Map[K, V], f: (key: K, value: V) -> Unit) -> Unit {
  #|  let keys = Map::keys(m)
  #|  let rec go = (i: Int) -> Unit {
  #|    if i < Array::length(keys) {
  #|      let k = Array::get(keys, i)
  #|      f(k, Map::get(m, k))
  #|      go(i + 1)
  #|    } else { }
  #|  }
  #|  go(0)
  #|}
  #|let Map::entries = [K, V](m: Map[K, V]) -> Array[(K, V)] {
  #|  let keys = Map::keys(m)
  #|  let b = ArrayBuilder::new()
  #|  let rec go = (i: Int) -> Unit {
  #|    if i < Array::length(keys) {
  #|      let k = Array::get(keys, i)
  #|      ArrayBuilder::push(b, (k, Map::get(m, k)))
  #|      go(i + 1)
  #|    } else { }
  #|  }
  #|  go(0)
  #|  ArrayBuilder::freeze(b)
  #|}
  #|let Map::merge = [K, V](a: Map[K, V], b: Map[K, V]) -> Map[K, V] {
  #|  {
  #|    let out = MapBuilder::new()
  #|    let ka = Map::keys(a)
  #|    let rec go1 = (i: Int) -> Unit {
  #|      if i < Array::length(ka) {
  #|        let k = Array::get(ka, i)
  #|        MapBuilder::set(out, k, Map::get(a, k))
  #|        go1(i + 1)
  #|      } else { }
  #|    }
  #|    go1(0)
  #|    let kb = Map::keys(b)
  #|    let rec go2 = (i: Int) -> Unit {
  #|      if i < Array::length(kb) {
  #|        let k = Array::get(kb, i)
  #|        MapBuilder::set(out, k, Map::get(b, k))
  #|        go2(i + 1)
  #|      } else { }
  #|    }
  #|    go2(0)
  #|    MapBuilder::freeze(out)
  #|  }
  #|}
  #|let where = [T](xs: Array[T], pred: (x: T) -> Bool) -> Array[T] {
  #|  {
  #|    let b = ArrayBuilder::new()
  #|    let rec go = (i: Int) -> Unit {
  #|      if i < Array::length(xs) {
  #|        let v = Array::get(xs, i)
  #|        if pred(v) {
  #|          ArrayBuilder::push(b, v)
  #|        } else { }
  #|        go(i + 1)
  #|      } else { }
  #|    }
  #|    go(0)
  #|    ArrayBuilder::freeze(b)
  #|  }
  #|}

///|
fn prelude_add_unbound_ref(
  name : String,
  bound : @core.WalkerScope,
  refs : Map[String, Bool],
) -> Unit {
  if not(bound.contains(name)) {
    refs[name] = true
  }
}

///|
fn prelude_backend_builtin_name(name : String) -> Bool {
  @core.is_builtin_name(name) ||
  name == "__add" ||
  name == "__sub" ||
  name == "__mul" ||
  name == "__div" ||
  name == "__eq" ||
  name == "__lt" ||
  name == "__assert" ||
  name == "__to_string" ||
  name == "Array::length" ||
  name == "Array::get" ||
  name == "Array::slice" ||
  name == "ArrayBuilder::new" ||
  name == "ArrayBuilder::push" ||
  name == "ArrayBuilder::freeze" ||
  name == "String::join" ||
  name == "StringBuilder::new" ||
  name == "StringBuilder::push" ||
  name == "StringBuilder::freeze" ||
  name == "Map::get" ||
  name == "Map::has_key" ||
  name == "Map::keys" ||
  name == "Set::new" ||
  name == "Set::add" ||
  name == "Set::contains" ||
  name == "Set::remove" ||
  name == "Set::size" ||
  name == "Set::to_array" ||
  name == "Set::from_array" ||
  name == "MapBuilder::new" ||
  name == "MapBuilder::set" ||
  name == "MapBuilder::freeze"
}

///|
fn prelude_stmt_value_name(stmt : @core.Stmt) -> String? {
  match stmt {
    @core.Stmt::Let(name~, ..)
    | @core.Stmt::ExportLet(name~, ..)
    | @core.Stmt::InternalExportLet(name~, ..)
    | @core.Stmt::LetMut(name~, ..) => Some(name)
    _ => None
  }
}

///|
fn prelude_partition_value_stmts(
  ast : @core.Module,
) -> (Array[@core.Stmt], Array[@core.Stmt]) {
  let value_names : Map[String, Bool] = {}
  let value_stmts : Array[@core.Stmt] = []
  for stmt in ast.stmts {
    match prelude_stmt_value_name(stmt) {
      Some(name) => {
        value_names[name] = true
        value_stmts.push(stmt)
      }
      None => ()
    }
  }
  let dep_graph : Map[String, Map[String, Bool]] = {}
  let builtin_dependent : Map[String, Bool] = {}
  for stmt in value_stmts {
    match prelude_stmt_value_name(stmt) {
      Some(name) => {
        let refs : Map[String, Bool] = {}
        @core.walk_stmt_refs(
          stmt,
          @core.WalkerScope::new(),
          refs,
          prelude_add_unbound_ref,
        )
        let deps : Map[String, Bool] = {}
        let mut needs_builtin = false
        for ref_name, _ in refs {
          if value_names.contains(ref_name) {
            deps[ref_name] = true
          } else if prelude_backend_builtin_name(ref_name) {
            needs_builtin = true
          }
        }
        dep_graph[name] = deps
        if needs_builtin {
          builtin_dependent[name] = true
        }
      }
      None => ()
    }
  }
  let mut changed = true
  while changed {
    changed = false
    for name, deps in dep_graph {
      if builtin_dependent.contains(name) {
        continue
      }
      let mut blocked = false
      for dep_name, _ in deps {
        if builtin_dependent.contains(dep_name) {
          blocked = true
          break
        }
      }
      if blocked {
        builtin_dependent[name] = true
        changed = true
      }
    }
  }
  let core_stmts : Array[@core.Stmt] = []
  let builtin_stmts : Array[@core.Stmt] = []
  for stmt in value_stmts {
    match prelude_stmt_value_name(stmt) {
      Some(name) =>
        if builtin_dependent.contains(name) {
          builtin_stmts.push(stmt)
        } else {
          core_stmts.push(stmt)
        }
      None => ()
    }
  }
  (core_stmts, builtin_stmts)
}

///|
pub fn prelude_core_value_stmts() -> Array[@core.Stmt] {
  let (core_stmts, _) = prelude_partition_value_stmts(prelude_ast())
  core_stmts
}

///|
pub fn prelude_builtin_value_stmts() -> Array[@core.Stmt] {
  let (_, builtin_stmts) = prelude_partition_value_stmts(prelude_ast())
  builtin_stmts
}

///|
let cached_prelude_ast : Ref[@core.Module?] = @ref.new(None)

///|
pub fn prelude_ast() -> @core.Module {
  match cached_prelude_ast.val {
    Some(ast) => ast
    None => {
      let ast = try! @parser.parse_ast(prelude_source)
      cached_prelude_ast.val = Some(ast)
      ast
    }
  }
}

///|
pub fn prelude_names() -> Array[String] {
  [
    "add", "sub", "mul", "div", "eq", "lt", "not", "and", "or", "assert", "assert_true",
    "to_string", "iter_require", "iter_length", "iter_get", "Array::map", "Array::fold",
    "Array::filter", "Array::foreach", "Array::concat", "Array::reverse", "Array::any",
    "Array::all", "Array::find", "assert_eq", "Array::sort", "Array::contains", "Array::join",
    "Map::get_or", "Map::map", "Map::filter", "where",
  ]
}
