use ./view.xsh {
  type StringView,
  type ArrayView,
  from_string,
  from_string_range,
  from_array,
  from_array_range
}
test "StringView basic range and methods" {
  let v = from_string_range("hello", 1, 4)
  assert(v.to_string() == "ell")
  assert(v.length() == 3)
  assert(v.start_offset() == 1)
  assert(not(v.is_empty()))
}
test "StringView clamps and subview" {
  let v = from_string_range("hello", -10, 99)
  assert(v.to_string() == "hello")
  let sub = v.view(1, 4)
  assert(sub.to_string() == "ell")
  assert(sub.start_offset() == 1)
}
test "StringView get" {
  let v = from_string("hello")
  match v.get(0) {
    Some(ch) => assert(ch == "h"),
    _ => assert(false)
  }
  match v.get(10) {
    Some(_) => assert(false),
    _ => assert(true)
  }
}
test "ArrayView basic range and methods" {
  let xs = [
    10,
    20,
    30,
    40
  ]
  let v = from_array_range(xs, 1, 3)
  assert(v.length() == 2)
  assert(v.start_offset() == 1)
  assert(not(v.is_empty()))
  let ys = v.to_array()
  assert(array_length(ys) == 2)
  assert(array_get(ys, 0) == 20)
  assert(array_get(ys, 1) == 30)
}
test "ArrayView get and subview" {
  let xs = [
    10,
    20,
    30,
    40
  ]
  let v = from_array(xs).view(1, 4)
  match v.get(1) {
    Some(value) => assert(value == 30),
    _ => assert(false)
  }
  match v.get(10) {
    Some(_) => assert(false),
    _ => assert(true)
  }
}
test "ArrayView empty view" {
  let xs = [
    1,
    2,
    3
  ]
  let v = from_array_range(xs, 10, 20)
  assert(v.is_empty())
  assert(v.length() == 0)
}
