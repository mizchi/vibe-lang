import {
  Int,
  max_value,
  min_value,
  abs,
  max,
  min,
  clamp,
  signum,
  is_even,
  is_odd,
  is_positive,
  is_negative,
  is_zero,
  pow,
  gcd,
  lcm,
  factorial,
  fibonacci
} from "./int.xsh"

let int_max_value = max_value
let int_min_value = min_value
let int_abs = abs
let int_max = max
let int_min = min
let int_clamp = clamp
let int_signum = signum
let int_is_even = is_even
let int_is_odd = is_odd
let int_is_positive = is_positive
let int_is_negative = is_negative
let int_is_zero = is_zero
let int_pow = pow
let int_gcd = gcd
let int_lcm = lcm
let int_factorial = factorial
let int_fibonacci = fibonacci

test "int_abs" {
  assert(eq(int_abs(5), 5))
  assert(eq(int_abs(-5), 5))
  assert(eq(int_abs(0), 0))
  assert(eq(int_abs(int_min_value), int_max_value))
}

test "int_max_min" {
  assert(eq(int_max(3, 7), 7))
  assert(eq(int_max(-1, -5), -1))
  assert(eq(int_min(3, 7), 3))
  assert(eq(int_min(-1, -5), -5))
}

test "int_clamp" {
  assert(eq(int_clamp(5, 0, 10), 5))
  assert(eq(int_clamp(-5, 0, 10), 0))
  assert(eq(int_clamp(15, 0, 10), 10))
}

test "int_signum" {
  assert(eq(int_signum(100), 1))
  assert(eq(int_signum(-100), -1))
  assert(eq(int_signum(0), 0))
}

test "int_is_even_odd" {
  assert(int_is_even(4))
  assert(not(int_is_even(5)))
  assert(int_is_odd(5))
  assert(not(int_is_odd(4)))
}

test "int_is_positive_negative_zero" {
  assert(int_is_positive(5))
  assert(not(int_is_positive(-5)))
  assert(int_is_negative(-5))
  assert(not(int_is_negative(5)))
  assert(int_is_zero(0))
  assert(not(int_is_zero(1)))
}

test "int_pow" {
  assert(eq(int_pow(2, 0), 1))
  assert(eq(int_pow(2, 1), 2))
  assert(eq(int_pow(2, 10), 1024))
  assert(eq(int_pow(3, 4), 81))
}

test "int_gcd" {
  assert(eq(int_gcd(12, 18), 6))
  assert(eq(int_gcd(17, 13), 1))
  assert(eq(int_gcd(100, 25), 25))
  assert(eq(int_gcd(-12, 18), 6))
}

test "int_lcm" {
  assert(eq(int_lcm(4, 6), 12))
  assert(eq(int_lcm(3, 5), 15))
  assert(eq(int_lcm(0, 5), 0))
  assert(eq(int_lcm(1073741824, 2), 1073741824))
}

test "int_factorial" {
  assert(eq(int_factorial(0), 1))
  assert(eq(int_factorial(1), 1))
  assert(eq(int_factorial(5), 120))
  assert(eq(int_factorial(10), 3628800))
}

test "int_fibonacci" {
  assert(eq(int_fibonacci(0), 0))
  assert(eq(int_fibonacci(1), 1))
  assert(eq(int_fibonacci(10), 55))
  assert(eq(int_fibonacci(15), 610))
}

test "int_short_aliases" {
  assert(eq(abs(-3), 3))
  assert(eq(clamp(99, 0, 8), 8))
  assert(is_even(10))
  assert(eq(pow(2, 8), 256))
}

test "int_type_members" {
  assert(eq(Int::abs(-3), 3))
  assert(eq(Int::pow(2, 8), 256))
  assert(Int::is_even(10))
  assert(eq(Int::gcd(12, 18), 6))
}

test "int_type_member_to_double" {
  let v = 7
  let d = v.to_double()
  assert(eq(double_to_int(d), 7))
}
