///|
test "fp double_to_string basic" {
  assert_eq(double_to_string(0.0), "0")
  assert_eq(double_to_string(1.0), "1")
  assert_eq(double_to_string(2.0), "2")
  assert_eq(double_to_string(10.0), "10")
  assert_eq(double_to_string(100.0), "100")
}

///|
test "fp double_to_string negative" {
  assert_eq(double_to_string(-1.0), "-1")
  assert_eq(double_to_string(-10.0), "-10")
  assert_eq(double_to_string(-0.5), "-0.5")
}

///|
test "fp double_to_string decimal" {
  assert_eq(double_to_string(0.5), "0.5")
  assert_eq(double_to_string(1.5), "1.5")
  assert_eq(double_to_string(0.25), "0.25")
  assert_eq(double_to_string(0.125), "0.125")
}

///|
test "fp double_to_string small" {
  assert_eq(double_to_string(0.001), "0.001")
  assert_eq(double_to_string(0.0001), "0.0001")
  assert_eq(double_to_string(0.00001), "0.00001")
  assert_eq(double_to_string(0.000001), "0.000001")
}

///|
test "fp double_to_string large" {
  assert_eq(double_to_string(1000.0), "1000")
  assert_eq(double_to_string(10000.0), "10000")
  assert_eq(double_to_string(100000.0), "100000")
  assert_eq(double_to_string(1000000.0), "1000000")
}

///|
test "fp double_to_string special" {
  assert_eq(double_to_string(1.0 / 0.0), "Infinity")
  assert_eq(double_to_string(-1.0 / 0.0), "-Infinity")
  assert_eq(double_to_string(0.0 / 0.0), "NaN")
}

///|
test "fp double_to_string pi" {
  let pi = 3.141592653589793
  let s = double_to_string(pi)
  // Should produce shortest representation
  assert_true(s.has_prefix("3.14159265358979"))
}

///|
test "fp double_to_string scientific notation small" {
  // Very small numbers should use scientific notation
  // 1e-10 = 0.0000000001
  let small = 0.0000000001
  let s = double_to_string(small)
  assert_true(s.contains("e-"))
}

///|
test "fp double_to_string scientific notation large" {
  // Very large numbers should use scientific notation
  // 1e25 = 10000000000000000000000000
  let large = 10000000000000000000000000.0
  let s = double_to_string(large)
  assert_true(s.contains("e+"))
}
