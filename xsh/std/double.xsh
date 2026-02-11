// Double utilities - ported from MoonBit core/double

let double_int_max = 536870911
let double_int_min = -536870912
let double_int_max_value = int_to_double(double_int_max)
let double_int_min_value = int_to_double(double_int_min)

let double_to_int_saturating = (x: Double) -> Int {
  if x >= double_int_max_value { double_int_max }
  else if x <= double_int_min_value { double_int_min }
  else { double_to_int(x) }
}

// Absolute value
let double_abs = (x: Double) -> Double {
  if x < 0.0 { 0.0 - x } else { x }
}

// Sign of double: -1.0, 0.0, or 1.0
let double_signum = (x: Double) -> Double {
  if x < 0.0 { -1.0 }
  else if x > 0.0 { 1.0 }
  else { 0.0 }
}

// Check if NaN (x != x is only true for NaN)
let double_is_nan = (x: Double) -> Bool {
  not(x == x)
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
  if x <= double_int_min_value {
    double_int_min_value
  } else {
    let i = double_to_int_saturating(x)
    let d = int_to_double(i)
    if d > x { int_to_double(i - 1) } else { d }
  }
}

// Ceiling - smallest integer greater than or equal to x
let double_ceil = (x: Double) -> Double {
  if x >= double_int_max_value {
    double_int_max_value
  } else {
    let i = double_to_int_saturating(x)
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
  int_to_double(double_to_int_saturating(x))
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
  double_abs(a - b) <= eps
}

// Type member names: can be imported as `import { Double }`
export let Double::abs = (x: Double) -> Double {
  double_abs(x)
}
export let Double::signum = (x: Double) -> Double {
  double_signum(x)
}
export let Double::is_nan = (x: Double) -> Bool {
  double_is_nan(x)
}
export let Double::max = (a: Double, b: Double) -> Double {
  double_max(a, b)
}
export let Double::min = (a: Double, b: Double) -> Double {
  double_min(a, b)
}
export let Double::clamp = (x: Double, min_val: Double, max_val: Double) -> Double {
  double_clamp(x, min_val, max_val)
}
export let Double::floor = (x: Double) -> Double {
  double_floor(x)
}
export let Double::ceil = (x: Double) -> Double {
  double_ceil(x)
}
export let Double::round = (x: Double) -> Double {
  double_round(x)
}
export let Double::trunc = (x: Double) -> Double {
  double_trunc(x)
}
export let Double::fract = (x: Double) -> Double {
  double_fract(x)
}
export let Double::square = (x: Double) -> Double {
  double_square(x)
}
export let Double::cube = (x: Double) -> Double {
  double_cube(x)
}
export let Double::lerp = (a: Double, b: Double, t: Double) -> Double {
  double_lerp(a, b, t)
}
export let Double::approx_eq = (a: Double, b: Double, eps: Double) -> Bool {
  double_approx_eq(a, b, eps)
}

// Short names (preferred): use with method-call desugar, e.g. x.floor()
export let abs = double_abs
export let signum = double_signum
export let is_nan = double_is_nan
export let max = double_max
export let min = double_min
export let clamp = double_clamp
export let floor = double_floor
export let ceil = double_ceil
export let round = double_round
export let trunc = double_trunc
export let fract = double_fract
export let square = double_square
export let cube = double_cube
export let lerp = double_lerp
export let approx_eq = double_approx_eq
