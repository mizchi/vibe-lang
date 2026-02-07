// Option utilities - ported from MoonBit core/option

// Check if Option is Some
let is_some = (opt: Option[Int]) -> Bool {
  match opt { Some(_) => true, _ => false }
}

// Check if Option is None
let is_none = (opt: Option[Int]) -> Bool {
  match opt { None => true, _ => false }
}

// Unwrap with default value
let unwrap_or = (opt: Option[Int], default: Int) -> Int {
  match opt { Some(v) => v, _ => default }
}

// Map over Option
let option_map = (opt: Option[Int], f: (x: Int) -> Int) -> Option[Int] {
  match opt { Some(v) => Some(f(v)), _ => None }
}

// Flatten Option[Option[Int]] to Option[Int]
let option_flatten = (opt: Option[Option[Int]]) -> Option[Int] {
  match opt { Some(inner) => inner, _ => None }
}

// FlatMap (bind) for Option
let option_flatmap = (opt: Option[Int], f: (x: Int) -> Option[Int]) -> Option[Int] {
  match opt { Some(v) => f(v), _ => None }
}

// Filter Option by predicate
let option_filter = (opt: Option[Int], pred: (x: Int) -> Bool) -> Option[Int] {
  match opt {
    Some(v) => if pred(v) { Some(v) } else { None },
    _ => None
  }
}

// Zip two Options - returns sum if both Some, else None
// (Note: true zip returning tuple needs better generics support)
let option_zip_sum = (a: Option[Int], b: Option[Int]) -> Option[Int] {
  match (a, b) {
    (Some(x), Some(y)) => Some(x + y),
    _ => None
  }
}

// Tests
test "is_some" {
  assert(is_some(Some(42)))
  assert(not(is_some(None)))
}

test "is_none" {
  assert(is_none(None))
  assert(not(is_none(Some(1))))
}

test "unwrap_or" {
  assert(eq(unwrap_or(Some(10), 0), 10))
  assert(eq(unwrap_or(None, 99), 99))
}

test "option_map" {
  let doubled = option_map(Some(5), (x: Int) -> Int { x * 2 })
  assert(eq(unwrap_or(doubled, 0), 10))

  let none_mapped = option_map(None, (x: Int) -> Int { x * 2 })
  assert(is_none(none_mapped))
}

test "option_flatten" {
  assert(eq(unwrap_or(option_flatten(Some(Some(42))), 0), 42))
  assert(is_none(option_flatten(Some(None))))
  assert(is_none(option_flatten(None)))
}

test "option_flatmap" {
  let safe_div = (x: Int) -> Option[Int] {
    if x == 0 { None } else { Some(100 / x) }
  }
  assert(eq(unwrap_or(option_flatmap(Some(5), safe_div), 0), 20))
  assert(is_none(option_flatmap(Some(0), safe_div)))
  assert(is_none(option_flatmap(None, safe_div)))
}

test "option_filter" {
  let is_even = (x: Int) -> Bool { x % 2 == 0 }
  assert(eq(unwrap_or(option_filter(Some(4), is_even), 0), 4))
  assert(is_none(option_filter(Some(3), is_even)))
  assert(is_none(option_filter(None, is_even)))
}

test "option_zip_sum" {
  let zipped = option_zip_sum(Some(1), Some(2))
  assert(eq(unwrap_or(zipped, 0), 3))
  assert(is_none(option_zip_sum(None, Some(1))))
  assert(is_none(option_zip_sum(Some(1), None)))
}

// Export all public functions
export {
  is_some, is_none, unwrap_or, option_map, option_flatten,
  option_flatmap, option_filter, option_zip_sum
}
