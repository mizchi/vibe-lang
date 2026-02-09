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
