use ./list.xsh {
  List,
  list_empty,
  list_is_empty,
  list_singleton,
  list_length,
  list_head,
  list_of3,
  list_of5,
  list_reverse,
  list_map,
  list_sum,
  list_filter,
  list_append,
  list_nth,
  list_take,
  list_drop,
  list_contains_by,
  length,
  sum
}
test "list_empty" {
  let empty = list_empty()
  assert(list_is_empty(empty))
  assert(not(list_is_empty(list_singleton(1))))
}
test "list_singleton" {
  let xs = list_singleton(42)
  assert(eq(list_length(xs), 1))
  match list_head(xs) {
    Some(v) => assert(eq(v, 42)),
    _ => assert(false)
  }
}
test "list_length" {
  let empty = list_empty()
  assert(eq(list_length(empty), 0))
  assert(eq(list_length(list_of3(1, 2, 3)), 3))
  assert(eq(list_length(list_of5(1, 2, 3, 4, 5)), 5))
}
test "list_reverse" {
  let xs = list_of3(1, 2, 3)
  let rev = list_reverse(xs)
  match list_head(rev) {
    Some(v) => assert(eq(v, 3)),
    _ => assert(false)
  }
}
test "list_map" {
  let xs = list_of3(1, 2, 3)
  let doubled = list_map((x: Int) -> Int {
    x * 2
  }, xs)
  assert(eq(list_sum(doubled), 12))
}
test "list_map_generic" {
  let xs = list_of3("a", "bb", "ccc")
  let lengths = list_map((s: String) -> Int {
    string_length(s)
  }, xs)
  assert(eq(list_sum(lengths), 6))
}
test "list_fold" {
  let xs = list_of5(1, 2, 3, 4, 5)
  assert(eq(list_sum(xs), 15))
}
test "list_filter" {
  let xs = list_of5(1, 2, 3, 4, 5)
  let evens = list_filter((x: Int) -> Bool {
    x % 2 == 0
  }, xs)
  assert(eq(list_length(evens), 2))
  assert(eq(list_sum(evens), 6))
}
test "list_append" {
  let xs = list_of3(1, 2, 3)
  let ys = list_of3(4, 5, 6)
  let zs = list_append(xs, ys)
  assert(eq(list_length(zs), 6))
  assert(eq(list_sum(zs), 21))
}
test "list_nth" {
  let xs = list_of5(10, 20, 30, 40, 50)
  match list_nth(xs, 2) {
    Some(v) => assert(eq(v, 30)),
    _ => assert(false)
  }
  match list_nth(xs, 10) {
    None => assert(true),
    _ => assert(false)
  }
}
test "list_take" {
  let xs = list_of5(1, 2, 3, 4, 5)
  let taken = list_take(3, xs)
  assert(eq(list_length(taken), 3))
  assert(eq(list_sum(taken), 6))
}
test "list_drop" {
  let xs = list_of5(1, 2, 3, 4, 5)
  let dropped = list_drop(2, xs)
  assert(eq(list_length(dropped), 3))
  assert(eq(list_sum(dropped), 12))
}
test "list_contains_by" {
  let xs = list_of3("a", "bb", "ccc")
  let eq_string = (a: String, b: String) -> Bool {
    string_equals(a, b)
  }
  assert(list_contains_by(eq_string, "bb", xs))
  assert(not(list_contains_by(eq_string, "z", xs)))
}
test "list_type_members_and_method_style" {
  let xs = list_of3(1, 2, 3)
  assert(eq(xs.length(), 3))
  assert(eq(xs.sum(), 6))
}
