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

// Type member names: can be imported with `use <module-ref> { Float }`
export let Float::eq = (a: Float, b: Float) -> Bool {
  float_eq(a, b)
}
export let Float::abs = (x: Float) -> Float {
  float_abs(x)
}
export let Float::signum = (x: Float) -> Float {
  float_signum(x)
}
export let Float::is_nan = (x: Float) -> Bool {
  float_is_nan(x)
}
export let Float::is_positive = (x: Float) -> Bool {
  float_is_positive(x)
}
export let Float::is_negative = (x: Float) -> Bool {
  float_is_negative(x)
}
export let Float::is_zero = (x: Float) -> Bool {
  float_is_zero(x)
}
export let Float::max = (a: Float, b: Float) -> Float {
  float_max(a, b)
}
export let Float::min = (a: Float, b: Float) -> Float {
  float_min(a, b)
}
export let Float::clamp = (x: Float, min_val: Float, max_val: Float) -> Float {
  float_clamp(x, min_val, max_val)
}
export let Float::square = (x: Float) -> Float {
  float_square(x)
}
export let Float::lerp = (a: Float, b: Float, t: Float) -> Float {
  float_lerp(a, b, t)
}

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
