// Int utilities - ported from MoonBit core/int

// Constants (tagged-int safe range for current runtime representation)
let int_max_value = 536870911
let int_min_value = -536870912

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

// Type member names: can be imported with `use <module-ref> { Int }`
export let Int::abs = (x: Int) -> Int { int_abs(x) }
export let Int::max = (a: Int, b: Int) -> Int { int_max(a, b) }
export let Int::min = (a: Int, b: Int) -> Int { int_min(a, b) }
export let Int::clamp = (x: Int, min_val: Int, max_val: Int) -> Int {
  int_clamp(x, min_val, max_val)
}
export let Int::signum = (x: Int) -> Int { int_signum(x) }
export let Int::is_even = (x: Int) -> Bool { int_is_even(x) }
export let Int::is_odd = (x: Int) -> Bool { int_is_odd(x) }
export let Int::is_positive = (x: Int) -> Bool { int_is_positive(x) }
export let Int::is_negative = (x: Int) -> Bool { int_is_negative(x) }
export let Int::is_zero = (x: Int) -> Bool { int_is_zero(x) }
export let Int::pow = (base: Int, exp: Int) -> Int { int_pow(base, exp) }
export let Int::gcd = (a: Int, b: Int) -> Int { int_gcd(a, b) }
export let Int::lcm = (a: Int, b: Int) -> Int { int_lcm(a, b) }
export let Int::factorial = (n: Int) -> Int { int_factorial(n) }
export let Int::fibonacci = (n: Int) -> Int { int_fibonacci(n) }

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
