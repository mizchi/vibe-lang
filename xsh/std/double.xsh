// Double utilities - ported from MoonBit core/double

// Constants
let double_max_value = 1.7976931348623157e308
let double_min_value = 2.2250738585072014e-308
let double_epsilon = 2.220446049250313e-16
let double_int_max_value = 2147483647.0
let double_int_min_value = -2147483648.0

// Absolute value
let double_abs = (x: Double) -> Double {
  if x < 0.0 { 0.0 - x } else { x }
}

// Sign of double: -1.0, 0.0, or 1.0
let double_signum = (x: Double) -> Double {
  if x < 0.0 { 0.0 - 1.0 }
  else if x > 0.0 { 1.0 }
  else { 0.0 }
}

// Check if NaN (x != x is only true for NaN)
let double_is_nan = (x: Double) -> Bool {
  not(x == x)
}

// Check if positive
let double_is_positive = (x: Double) -> Bool {
  x > 0.0
}

// Check if negative
let double_is_negative = (x: Double) -> Bool {
  x < 0.0
}

// Check if zero
let double_is_zero = (x: Double) -> Bool {
  x == 0.0
}

// Maximum of two doubles
let double_max = (a: Double, b: Double) -> Double {
  if a > b { a } else { b }
}

// Minimum of two doubles
let double_min = (a: Double, b: Double) -> Double {
  if a < b { a } else { b }
}

// Clamp value between min and max
let double_clamp = (x: Double, min_val: Double, max_val: Double) -> Double {
  if x < min_val { min_val }
  else if x > max_val { max_val }
  else { x }
}

// Floor - largest integer less than or equal to x
let double_floor = (x: Double) -> Double {
  if x >= double_int_max_value { double_int_max_value }
  else if x <= double_int_min_value { double_int_min_value }
  else {
    let i = double_to_int(x)
    let d = int_to_double(i)
    if d > x { int_to_double(i - 1) } else { d }
  }
}

// Ceiling - smallest integer greater than or equal to x
let double_ceil = (x: Double) -> Double {
  if x >= double_int_max_value { double_int_max_value }
  else if x <= double_int_min_value { double_int_min_value }
  else {
    let i = double_to_int(x)
    let d = int_to_double(i)
    if d < x { int_to_double(i + 1) } else { d }
  }
}

// Round to nearest integer (half away from zero)
let double_round = (x: Double) -> Double {
  if x >= 0.0 {
    double_floor(x + 0.5)
  } else {
    double_ceil(x - 0.5)
  }
}

// Truncate - remove fractional part
let double_trunc = (x: Double) -> Double {
  if x >= double_int_max_value { double_int_max_value }
  else if x <= double_int_min_value { double_int_min_value }
  else { int_to_double(double_to_int(x)) }
}

// Fractional part
let double_fract = (x: Double) -> Double {
  x - double_trunc(x)
}

// Square
let double_square = (x: Double) -> Double {
  x * x
}

// Cube
let double_cube = (x: Double) -> Double {
  x * x * x
}

// Linear interpolation (lerp)
let double_lerp = (a: Double, b: Double, t: Double) -> Double {
  a + (b - a) * t
}

// Approximately equal (within epsilon)
let double_approx_eq = (a: Double, b: Double, eps: Double) -> Bool {
  double_abs(a - b) < eps
}

// Tests
test "double_abs" {
  assert(eq(double_abs(3.5), 3.5))
  assert(eq(double_abs(-3.5), 3.5))
  assert(eq(double_abs(0.0), 0.0))
}

test "double_signum" {
  assert(eq(double_signum(5.0), 1.0))
  assert(eq(double_signum(-5.0), -1.0))
  assert(eq(double_signum(0.0), 0.0))
}

test "double_is_nan" {
  // Note: can't directly create NaN in xsh, so just test non-NaN
  assert(not(double_is_nan(1.0)))
  assert(not(double_is_nan(0.0)))
}

test "double_max_min" {
  assert(eq(double_max(3.0, 7.0), 7.0))
  assert(eq(double_min(3.0, 7.0), 3.0))
  assert(eq(double_max(-1.0, -5.0), -1.0))
  assert(eq(double_min(-1.0, -5.0), -5.0))
}

test "double_clamp" {
  assert(eq(double_clamp(5.0, 0.0, 10.0), 5.0))
  assert(eq(double_clamp(-5.0, 0.0, 10.0), 0.0))
  assert(eq(double_clamp(15.0, 0.0, 10.0), 10.0))
}

test "double_floor_ceil" {
  assert(eq(double_floor(3.7), 3.0))
  assert(eq(double_floor(-3.7), -4.0))
  assert(eq(double_ceil(3.2), 4.0))
  assert(eq(double_ceil(-3.2), -3.0))
}

test "double_round" {
  assert(eq(double_round(3.4), 3.0))
  assert(eq(double_round(3.5), 4.0))
  assert(eq(double_round(-3.4), -3.0))
  assert(eq(double_round(-3.5), -4.0))
}

test "double_trunc_fract" {
  assert(eq(double_trunc(3.7), 3.0))
  assert(eq(double_trunc(-3.7), -3.0))
  // fract test with tolerance
  let f = double_fract(3.75)
  assert(f > 0.74)
  assert(f < 0.76)
}

test "double_floor_ceil_trunc_saturate_int_range" {
  assert(eq(double_floor(1.0e20), double_int_max_value))
  assert(eq(double_ceil(1.0e20), double_int_max_value))
  assert(eq(double_trunc(1.0e20), double_int_max_value))
  assert(eq(double_floor(-1.0e20), double_int_min_value))
  assert(eq(double_ceil(-1.0e20), double_int_min_value))
  assert(eq(double_trunc(-1.0e20), double_int_min_value))
}

test "double_square_cube" {
  assert(eq(double_square(3.0), 9.0))
  assert(eq(double_cube(2.0), 8.0))
}

test "double_lerp" {
  assert(eq(double_lerp(0.0, 10.0, 0.5), 5.0))
  assert(eq(double_lerp(0.0, 10.0, 0.0), 0.0))
  assert(eq(double_lerp(0.0, 10.0, 1.0), 10.0))
}

// Export
export {
  double_max_value, double_min_value, double_epsilon,
  double_abs, double_signum, double_is_nan,
  double_is_positive, double_is_negative, double_is_zero,
  double_max, double_min, double_clamp,
  double_floor, double_ceil, double_round, double_trunc, double_fract,
  double_square, double_cube, double_lerp, double_approx_eq
}
