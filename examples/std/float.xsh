// Float utilities - ported from MoonBit core/float

// Float equality check (using double conversion)
let float_eq = (a: Float, b: Float) -> Bool {
  float_to_double(a) == float_to_double(b)
}

// Absolute value
let float_abs = (x: Float) -> Float {
  if float_to_double(x) < 0.0 {
    double_to_float(0.0 - float_to_double(x))
  } else {
    x
  }
}

// Sign of float: -1.0f, 0.0f, or 1.0f
let float_signum = (x: Float) -> Float {
  let xd = float_to_double(x)
  if xd < 0.0 { double_to_float(0.0 - 1.0) }
  else if xd > 0.0 { double_to_float(1.0) }
  else { double_to_float(0.0) }
}

// Check if NaN (x != x is only true for NaN)
let float_is_nan = (x: Float) -> Bool {
  let xd = float_to_double(x)
  not(xd == xd)
}

// Check if positive
let float_is_positive = (x: Float) -> Bool {
  float_to_double(x) > 0.0
}

// Check if negative
let float_is_negative = (x: Float) -> Bool {
  float_to_double(x) < 0.0
}

// Check if zero
let float_is_zero = (x: Float) -> Bool {
  float_to_double(x) == 0.0
}

// Maximum of two floats
let float_max = (a: Float, b: Float) -> Float {
  if float_to_double(a) > float_to_double(b) { a } else { b }
}

// Minimum of two floats
let float_min = (a: Float, b: Float) -> Float {
  if float_to_double(a) < float_to_double(b) { a } else { b }
}

// Clamp value between min and max
let float_clamp = (x: Float, min_val: Float, max_val: Float) -> Float {
  let xd = float_to_double(x)
  let mind = float_to_double(min_val)
  let maxd = float_to_double(max_val)
  if xd < mind { min_val }
  else if xd > maxd { max_val }
  else { x }
}

// Square
let float_square = (x: Float) -> Float {
  double_to_float(float_to_double(x) * float_to_double(x))
}

// Linear interpolation (lerp)
let float_lerp = (a: Float, b: Float, t: Float) -> Float {
  let ad = float_to_double(a)
  let bd = float_to_double(b)
  let td = float_to_double(t)
  double_to_float(ad + (bd - ad) * td)
}

// Tests
test "float_abs" {
  assert(float_eq(float_abs(3.5f), 3.5f))
  assert(float_eq(float_abs(-3.5f), 3.5f))
  assert(float_eq(float_abs(0.0f), 0.0f))
}

test "float_signum" {
  assert(float_to_double(float_signum(5.0f)) > 0.0)
  assert(float_to_double(float_signum(-5.0f)) < 0.0)
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
  let expected = 5.0
  let actual = float_to_double(result)
  // Use tolerance check
  assert(actual > 4.9)
  assert(actual < 5.1)
}

// Export
export {
  float_eq,
  float_abs, float_signum, float_is_nan,
  float_is_positive, float_is_negative, float_is_zero,
  float_max, float_min, float_clamp,
  float_square, float_lerp
}
