// Float utilities - ported from MoonBit core/float

let float_eq = (a: Float, b: Float) -> Bool {
  a == b
}

// Absolute value
let float_abs = (x: Float) -> Float {
  if x < 0.0f { 0.0f - x } else { x }
}

// Sign of float: -1.0f, 0.0f, or 1.0f
let float_signum = (x: Float) -> Float {
  if x < 0.0f { 0.0f - 1.0f }
  else if x > 0.0f { 1.0f }
  else { 0.0f }
}

// Check if NaN (x != x is only true for NaN)
let float_is_nan = (x: Float) -> Bool {
  not(x == x)
}

// Check if positive
let float_is_positive = (x: Float) -> Bool {
  x > 0.0f
}

// Check if negative
let float_is_negative = (x: Float) -> Bool {
  x < 0.0f
}

// Check if zero
let float_is_zero = (x: Float) -> Bool {
  x == 0.0f
}

// Maximum of two floats
let float_max = (a: Float, b: Float) -> Float {
  if a > b { a } else { b }
}

// Minimum of two floats
let float_min = (a: Float, b: Float) -> Float {
  if a < b { a } else { b }
}

// Clamp value between min and max
let float_clamp = (x: Float, min_val: Float, max_val: Float) -> Float {
  if x < min_val { min_val }
  else if x > max_val { max_val }
  else { x }
}

// Square
let float_square = (x: Float) -> Float {
  x * x
}

// Linear interpolation (lerp)
let float_lerp = (a: Float, b: Float, t: Float) -> Float {
  a + (b - a) * t
}

// Type member names: can be imported as `import { Float }`
export let Float::eq = float_eq
export let Float::abs = float_abs
export let Float::signum = float_signum
export let Float::is_nan = float_is_nan
export let Float::is_positive = float_is_positive
export let Float::is_negative = float_is_negative
export let Float::is_zero = float_is_zero
export let Float::max = float_max
export let Float::min = float_min
export let Float::clamp = float_clamp
export let Float::square = float_square
export let Float::lerp = float_lerp

// Short names (preferred): use with method-call desugar, e.g. x.abs()
export let eq = float_eq
export let abs = float_abs
export let signum = float_signum
export let is_nan = float_is_nan
export let is_positive = float_is_positive
export let is_negative = float_is_negative
export let is_zero = float_is_zero
export let max = float_max
export let min = float_min
export let clamp = float_clamp
export let square = float_square
export let lerp = float_lerp
