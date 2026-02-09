// Double utilities - ported from MoonBit core/double

// Constants
export let double_max_value = 1.7976931348623157e308
export let double_min_value = 2.2250738585072014e-308
export let double_epsilon = 2.220446049250313e-16
let double_int_max_value = 2147483647.0
let double_int_min_value = -2147483648.0

// Absolute value
export let double_abs = (x: Double) -> Double {
  if x < 0.0 { 0.0 - x } else { x }
}

// Sign of double: -1.0, 0.0, or 1.0
export let double_signum = (x: Double) -> Double {
  if x < 0.0 { 0.0 - 1.0 }
  else if x > 0.0 { 1.0 }
  else { 0.0 }
}

// Check if NaN (x != x is only true for NaN)
export let double_is_nan = (x: Double) -> Bool {
  not(x == x)
}

// Check if positive
export let double_is_positive = (x: Double) -> Bool {
  x > 0.0
}

// Check if negative
export let double_is_negative = (x: Double) -> Bool {
  x < 0.0
}

// Check if zero
export let double_is_zero = (x: Double) -> Bool {
  x == 0.0
}

// Maximum of two doubles
export let double_max = (a: Double, b: Double) -> Double {
  if a > b { a } else { b }
}

// Minimum of two doubles
export let double_min = (a: Double, b: Double) -> Double {
  if a < b { a } else { b }
}

// Clamp value between min and max
export let double_clamp = (x: Double, min_val: Double, max_val: Double) -> Double {
  if x < min_val { min_val }
  else if x > max_val { max_val }
  else { x }
}

// Floor - largest integer less than or equal to x
export let double_floor = (x: Double) -> Double {
  if x >= double_int_max_value { double_int_max_value }
  else if x <= double_int_min_value { double_int_min_value }
  else {
    let i = double_to_int(x)
    let d = int_to_double(i)
    if d > x { int_to_double(i - 1) } else { d }
  }
}

// Ceiling - smallest integer greater than or equal to x
export let double_ceil = (x: Double) -> Double {
  if x >= double_int_max_value { double_int_max_value }
  else if x <= double_int_min_value { double_int_min_value }
  else {
    let i = double_to_int(x)
    let d = int_to_double(i)
    if d < x { int_to_double(i + 1) } else { d }
  }
}

// Round to nearest integer (half away from zero)
export let double_round = (x: Double) -> Double {
  if x >= 0.0 {
    double_floor(x + 0.5)
  } else {
    double_ceil(x - 0.5)
  }
}

// Truncate - remove fractional part
export let double_trunc = (x: Double) -> Double {
  if x >= double_int_max_value { double_int_max_value }
  else if x <= double_int_min_value { double_int_min_value }
  else { int_to_double(double_to_int(x)) }
}

// Fractional part
export let double_fract = (x: Double) -> Double {
  x - double_trunc(x)
}

// Square
export let double_square = (x: Double) -> Double {
  x * x
}

// Cube
export let double_cube = (x: Double) -> Double {
  x * x * x
}

// Linear interpolation (lerp)
export let double_lerp = (a: Double, b: Double, t: Double) -> Double {
  a + (b - a) * t
}

// Approximately equal (within epsilon)
export let double_approx_eq = (a: Double, b: Double, eps: Double) -> Bool {
  double_abs(a - b) <= eps
}
