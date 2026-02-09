// Int utilities - ported from MoonBit core/int

// Constants
let int_max_value = 2147483647
// Note: -2147483648 is rejected with an overflow parse error
// Use int_max_value + 1 with negation trick
let int_min_value = 0 - 2147483647 - 1

// Absolute value (saturates at int_max_value for int_min_value)
let int_abs = (x: Int) -> Int {
  // Saturate at max to avoid overflow for min_value.
  if x == int_min_value { int_max_value }
  else if x < 0 { 0 - x }
  else { x }
}

// Maximum of two integers
let int_max = (a: Int, b: Int) -> Int {
  if a > b { a } else { b }
}

// Minimum of two integers
let int_min = (a: Int, b: Int) -> Int {
  if a < b { a } else { b }
}

// Clamp value between min and max
let int_clamp = (x: Int, min_val: Int, max_val: Int) -> Int {
  if x < min_val { min_val }
  else if x > max_val { max_val }
  else { x }
}

// Sign of integer: -1, 0, or 1
let int_signum = (x: Int) -> Int {
  if x < 0 { -1 }
  else if x > 0 { 1 }
  else { 0 }
}

// Check if integer is even
let int_is_even = (x: Int) -> Bool {
  x % 2 == 0
}

// Check if integer is odd
let int_is_odd = (x: Int) -> Bool {
  x % 2 != 0
}

// Check if integer is positive
let int_is_positive = (x: Int) -> Bool {
  x > 0
}

// Check if integer is negative
let int_is_negative = (x: Int) -> Bool {
  x < 0
}

// Check if integer is zero
let int_is_zero = (x: Int) -> Bool {
  x == 0
}

// Power function (non-negative exponent)
let rec int_pow = (base: Int, exp: Int) -> Int {
  if exp <= 0 { 1 }
  else if exp == 1 { base }
  else if exp % 2 == 0 {
    let half = int_pow(base, exp / 2)
    half * half
  } else {
    base * int_pow(base, exp - 1)
  }
}

// Greatest Common Divisor (Euclidean algorithm)
let rec int_gcd = (a: Int, b: Int) -> Int {
  let abs_a = int_abs(a)
  let abs_b = int_abs(b)
  if abs_b == 0 { abs_a }
  else { int_gcd(abs_b, abs_a % abs_b) }
}

// Least Common Multiple
let int_lcm = (a: Int, b: Int) -> Int {
  if a == 0 || b == 0 { 0 }
  else {
    let g = int_gcd(a, b)
    let scaled = a / g
    int_abs(scaled * b)
  }
}

// Factorial
let rec int_factorial = (n: Int) -> Int {
  if n <= 1 { 1 }
  else { n * int_factorial(n - 1) }
}

// Fibonacci
let int_fibonacci = (n: Int) -> Int {
  let rec fib = (a: Int, b: Int, count: Int) -> Int {
    if count <= 0 { a }
    else { fib(b, a + b, count - 1) }
  }
  fib(0, 1, n)
}

export let Int::to_double = (x: Int) -> Double {
  int_to_double(x)
}

// Short names (preferred): use with method-call desugar, e.g. x.abs()
export let max_value = int_max_value
export let min_value = int_min_value
export let abs = (x: Int) -> Int { int_abs(x) }
export let max = (a: Int, b: Int) -> Int { int_max(a, b) }
export let min = (a: Int, b: Int) -> Int { int_min(a, b) }
export let clamp = (x: Int, min_val: Int, max_val: Int) -> Int {
  int_clamp(x, min_val, max_val)
}
export let signum = (x: Int) -> Int { int_signum(x) }
export let is_even = (x: Int) -> Bool { int_is_even(x) }
export let is_odd = (x: Int) -> Bool { int_is_odd(x) }
export let is_positive = (x: Int) -> Bool { int_is_positive(x) }
export let is_negative = (x: Int) -> Bool { int_is_negative(x) }
export let is_zero = (x: Int) -> Bool { int_is_zero(x) }
export let pow = (base: Int, exp: Int) -> Int { int_pow(base, exp) }
export let gcd = (a: Int, b: Int) -> Int { int_gcd(a, b) }
export let lcm = (a: Int, b: Int) -> Int { int_lcm(a, b) }
export let factorial = (n: Int) -> Int { int_factorial(n) }
export let fibonacci = (n: Int) -> Int { int_fibonacci(n) }

// Tests
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

test "int_type_member_to_double" {
  let v = 7
  let d = v.to_double()
  assert(eq(double_to_int(d), 7))
}
