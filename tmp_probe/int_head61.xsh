// Int utilities - ported from MoonBit core/int

// Constants
let int_max_value = 2147483647
// Note: -2147483648 is rejected with an overflow parse error
// Use int_max_value + 1 with negation trick
let int_min_value = 0 - 2147483647 - 1

// Absolute value
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
