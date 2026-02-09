// Option utilities - trait/generic-oriented std API

export trait Eq
impl Eq for Int
impl Eq for Float
impl Eq for Double
impl Eq for Bool
impl Eq for String
impl [T: Eq] Eq for Option[T]

let option_is_some = [T](opt: Option[T]) -> Bool {
  match opt { Some(_) => true, _ => false }
}

let option_is_none = [T](opt: Option[T]) -> Bool {
  not(option_is_some(opt))
}

let option_unwrap_or = [T](opt: Option[T], default: T) -> T {
  match opt { Some(v) => v, _ => default }
}

let option_unwrap_or_else = [T](opt: Option[T], fallback: () -> T) -> T {
  match opt { Some(v) => v, _ => fallback() }
}

let option_map = [A, B](opt: Option[A], f: (x: A) -> B) -> Option[B] {
  match opt { Some(v) => Some(f(v)), _ => None }
}

let option_map_or = [A, B](opt: Option[A], default: B, f: (x: A) -> B) -> B {
  match opt { Some(v) => f(v), _ => default }
}

let option_flatten = [T](opt: Option[Option[T]]) -> Option[T] {
  match opt { Some(inner) => inner, _ => None }
}

let option_flatmap = [A, B](opt: Option[A], f: (x: A) -> Option[B]) -> Option[B] {
  match opt { Some(v) => f(v), _ => None }
}

let option_filter = [T](opt: Option[T], pred: (x: T) -> Bool) -> Option[T] {
  match opt {
    Some(v) => if pred(v) { Some(v) } else { None },
    _ => None
  }
}

let option_zip = [A, B](a: Option[A], b: Option[B]) -> Option[(A, B)] {
  match (a, b) {
    (Some(x), Some(y)) => Some((x, y)),
    _ => None
  }
}

let option_and = [A, B](a: Option[A], b: Option[B]) -> Option[B] {
  match a { Some(_) => b, _ => None }
}

let option_or = [T](a: Option[T], b: Option[T]) -> Option[T] {
  match a { Some(_) => a, _ => b }
}

let option_or_else = [T](a: Option[T], fallback: () -> Option[T]) -> Option[T] {
  match a { Some(_) => a, _ => fallback() }
}

let option_equals = [T: Eq](a: Option[T], b: Option[T]) -> Bool {
  match (a, b) {
    (Some(x), Some(y)) => x == y,
    (None, None) => true,
    _ => false
  }
}

// Short names (preferred): use with method-call desugar, e.g. opt.unwrap_or(0)
export let is_some = [T](opt: Option[T]) -> Bool { option_is_some(opt) }
export let is_none = [T](opt: Option[T]) -> Bool { option_is_none(opt) }
export let unwrap_or = [T](opt: Option[T], default: T) -> T { option_unwrap_or(opt, default) }
export let unwrap_or_else = [T](opt: Option[T], fallback: () -> T) -> T {
  option_unwrap_or_else(opt, fallback)
}
// NOTE: `map` is currently a reserved keyword, so this short API uses `map_opt`.
export let map_opt = [A, B](opt: Option[A], f: (x: A) -> B) -> Option[B] {
  option_map(opt, f)
}
export let map_or = [A, B](opt: Option[A], default: B, f: (x: A) -> B) -> B {
  option_map_or(opt, default, f)
}
export let flatten = [T](opt: Option[Option[T]]) -> Option[T] { option_flatten(opt) }
export let flatmap = [A, B](opt: Option[A], f: (x: A) -> Option[B]) -> Option[B] {
  option_flatmap(opt, f)
}
export let filter = [T](opt: Option[T], pred: (x: T) -> Bool) -> Option[T] {
  option_filter(opt, pred)
}
export let zip = [A, B](a: Option[A], b: Option[B]) -> Option[(A, B)] { option_zip(a, b) }
export let and = [A, B](a: Option[A], b: Option[B]) -> Option[B] { option_and(a, b) }
export let or = [T](a: Option[T], b: Option[T]) -> Option[T] { option_or(a, b) }
export let or_else = [T](a: Option[T], fallback: () -> Option[T]) -> Option[T] {
  option_or_else(a, fallback)
}
export let equals = [T: Eq](a: Option[T], b: Option[T]) -> Bool { option_equals(a, b) }

export let zip_sum = (a: Option[Int], b: Option[Int]) -> Option[Int] {
  match option_zip(a, b) {
    Some((x, y)) => Some(x + y),
    _ => None
  }
}

test "option_is_some_none" {
  assert(option_is_some(Some(42)))
  assert(option_is_none(None))
}

test "option_unwrap_or_generic" {
  assert(eq(option_unwrap_or(Some(10), 0), 10))
  assert(eq(option_unwrap_or(None, 99), 99))
  assert(string_equals(option_unwrap_or(Some("ok"), "ng"), "ok"))
}

test "option_map_generic" {
  let doubled = option_map(Some(5), (x: Int) -> Int { x * 2 })
  assert(eq(option_unwrap_or(doubled, 0), 10))

  let lengths = option_map(Some("xyz"), (s: String) -> Int { string_length(s) })
  assert(eq(option_unwrap_or(lengths, 0), 3))
}

test "option_flatten_flatmap" {
  assert(eq(option_unwrap_or(option_flatten(Some(Some(42))), 0), 42))
  assert(option_is_none(option_flatten(Some(None))))

  let safe_div = (x: Int) -> Option[Int] {
    if x == 0 { None } else { Some(100 / x) }
  }
  assert(eq(option_unwrap_or(option_flatmap(Some(5), safe_div), 0), 20))
  assert(option_is_none(option_flatmap(Some(0), safe_div)))
}

test "option_filter" {
  let is_even = (x: Int) -> Bool { x % 2 == 0 }
  assert(eq(option_unwrap_or(option_filter(Some(4), is_even), 0), 4))
  assert(option_is_none(option_filter(Some(3), is_even)))
  assert(option_is_none(option_filter(None, is_even)))
}

test "option_zip" {
  match option_zip(Some(1), Some("ok")) {
    Some((n, s)) => {
      assert(eq(n, 1))
      assert(string_equals(s, "ok"))
    },
    _ => assert(false)
  }
  assert(option_is_none(option_zip(None, Some(1))))
}

test "option_equals" {
  assert(option_equals(Some(1), Some(1)))
  assert(not(option_equals(Some(1), Some(2))))
  assert(option_equals(None, None))
}

test "option_unwrap_or_else" {
  let fallback = () -> Int { 99 }
  assert(eq(option_unwrap_or_else(Some(10), fallback), 10))
  assert(eq(option_unwrap_or_else(None, fallback), 99))
}

test "option_or_and" {
  assert(option_is_some(option_or(Some(1), Some(2))))
  assert(option_is_some(option_or(None, Some(2))))
  assert(option_is_none(option_or(None, None)))

  assert(option_is_some(option_and(Some(1), Some("ok"))))
  assert(option_is_none(option_and(None, Some("ok"))))
}

test "option_or_else" {
  let fallback_some = () -> Option[Int] { Some(42) }
  let fallback_none = () -> Option[Int] { None }
  assert(eq(option_unwrap_or(option_or_else(Some(1), fallback_some), 0), 1))
  assert(eq(option_unwrap_or(option_or_else(None, fallback_some), 0), 42))
  assert(option_is_none(option_or_else(None, fallback_none)))
}

test "option_map_or" {
  let len = (s: String) -> Int { string_length(s) }
  assert(eq(option_map_or(Some("abc"), 0, len), 3))
  assert(eq(option_map_or(None, 7, len), 7))
}

test "option_zip_sum" {
  let zipped = zip_sum(Some(1), Some(2))
  assert(eq(option_unwrap_or(zipped, 0), 3))
  assert(option_is_none(zip_sum(None, Some(1))))
}

test "option_short_aliases" {
  let len = (s: String) -> Int { string_length(s) }
  let mapped = map_opt(Some("xy"), len)
  assert(eq(unwrap_or(mapped, 0), 2))
  assert(eq(map_or(None, 9, len), 9))
  assert(equals(or(Some(1), None), Some(1)))
}

