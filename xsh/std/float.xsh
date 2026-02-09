// Float utilities - ported from MoonBit core/float

// Float equality check
export let float_eq = (a: Float, b: Float) -> Bool {
  a == b
}

// Absolute value
export let float_abs = (x: Float) -> Float {
  if x < 0.0f { 0.0f - x } else { x }
}

// Sign of float: -1.0f, 0.0f, or 1.0f
export let float_signum = (x: Float) -> Float {
  if x < 0.0f { 0.0f - 1.0f }
  else if x > 0.0f { 1.0f }
  else { 0.0f }
}

// Check if NaN (x != x is only true for NaN)
export let float_is_nan = (x: Float) -> Bool {
  not(x == x)
}

// Check if positive
export let float_is_positive = (x: Float) -> Bool {
  x > 0.0f
}

// Check if negative
export let float_is_negative = (x: Float) -> Bool {
  x < 0.0f
}

// Check if zero
export let float_is_zero = (x: Float) -> Bool {
  x == 0.0f
}

// Maximum of two floats
export let float_max = (a: Float, b: Float) -> Float {
  if a > b { a } else { b }
}

// Minimum of two floats
export let float_min = (a: Float, b: Float) -> Float {
  if a < b { a } else { b }
}

// Clamp value between min and max
export let float_clamp = (x: Float, min_val: Float, max_val: Float) -> Float {
  if x < min_val { min_val }
  else if x > max_val { max_val }
  else { x }
}

// Square
export let float_square = (x: Float) -> Float {
  x * x
}

// Linear interpolation (lerp)
export let float_lerp = (a: Float, b: Float, t: Float) -> Float {
  a + (b - a) * t
}

// Tests
test "float_abs" {
  assert(float_eq(float_abs(3.5f), 3.5f))
  assert(float_eq(float_abs(-3.5f), 3.5f))
  assert(float_eq(float_abs(0.0f), 0.0f))
}

test "float_signum" {
  assert(float_signum(5.0f) > 0.0f)
  assert(float_signum(-5.0f) < 0.0f)
  assert(float_eq(float_signum(0.0f), 0.0f))
}

test "float_is_nan" {
  // Note: can't directly create NaN in xsh, so just test non-NaN
  assert(not(float_is_nan(1.0f)))
  assert(not(float_is_nan(0.0f)))
}

test "float_max_min" {
  assert(float_eq(float_max(3.0f, 7.0f), 7.0f))
  assert(float_eq(float_min(3.0f, 7.0f), 3.0f))
}

test "float_clamp" {
  assert(float_eq(float_clamp(5.0f, 0.0f, 10.0f), 5.0f))
  assert(float_eq(float_clamp(-5.0f, 0.0f, 10.0f), 0.0f))
  assert(float_eq(float_clamp(15.0f, 0.0f, 10.0f), 10.0f))
}

test "float_square" {
  assert(float_eq(float_square(3.0f), 9.0f))
  assert(float_eq(float_square(0.0f), 0.0f))
}

test "float_lerp" {
  let result = float_lerp(0.0f, 10.0f, 0.5f)
  // Use tolerance check
  assert(result > 4.9f)
  assert(result < 5.1f)
}

// Export
