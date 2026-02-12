let double_abs = (x: Double) -> Double {
  if x < 0.0 {
    0.0 - x
  } else {
    x
  }
}
export let abs: (Double) -> Double = double_abs
let double_max = (a: Double, b: Double) -> Double {
  if a > b {
    a
  } else {
    b
  }
}
export let max: (Double, Double) -> Double = double_max
let double_min = (a: Double, b: Double) -> Double {
  if a < b {
    a
  } else {
    b
  }
}
export let min: (Double, Double) -> Double = double_min
let double_cube = (x: Double) -> Double {
  x * x * x
}
export let cube: (Double) -> Double = double_cube
let double_lerp = (a: Double, b: Double, t: Double) -> Double {
  a + (b - a) * t
}
export let lerp: (Double, Double, Double) -> Double = double_lerp
let double_clamp = (x: Double, min_val: Double, max_val: Double) -> Double {
  if x < min_val {
    min_val
  }
  else if x > max_val {
    max_val
  }
  else {
    x
  }
}
export let clamp: (Double, Double, Double) -> Double = double_clamp
let double_is_nan = (x: Double) -> Bool {
  not(x == x)
}
export let is_nan: (Double) -> Bool = double_is_nan
let double_signum = (x: Double) -> Double {
  if x < 0.0 {
    -1.0
  }
  else if x > 0.0 {
    1.0
  }
  else {
    0.0
  }
}
export let signum: (Double) -> Double = double_signum
let double_square = (x: Double) -> Double {
  x * x
}
export let square: (Double) -> Double = double_square
let double_int_max: Int = 536870911
let double_int_min: Int = __neg(536870912)
let double_approx_eq = (a: Double, b: Double, eps: Double) -> Bool {
  double_abs(a - b) <= eps
}
export let approx_eq: (Double, Double, Double) -> Bool = double_approx_eq
let double_int_max_value: Double = int_to_double(double_int_max)
let double_int_min_value: Double = int_to_double(double_int_min)
let double_to_int_saturating = (x: Double) -> Int {
  if x >= double_int_max_value {
    double_int_max
  }
  else if x <= double_int_min_value {
    double_int_min
  }
  else {
    double_to_int(x)
  }
}
let double_ceil = (x: Double) -> Double {
  if x >= double_int_max_value {
    double_int_max_value
  } else {
    let i = double_to_int_saturating(x)
    let d = int_to_double(i)
    if d < x {
      int_to_double(i + 1)
    } else {
      d
    }
  }
}
export let ceil: (Double) -> Double = double_ceil
let double_floor = (x: Double) -> Double {
  if x <= double_int_min_value {
    double_int_min_value
  } else {
    let i = double_to_int_saturating(x)
    let d = int_to_double(i)
    if d > x {
      int_to_double(i - 1)
    } else {
      d
    }
  }
}
export let floor: (Double) -> Double = double_floor
let double_round = (x: Double) -> Double {
  if x >= 0.0 {
    double_floor(x + 0.5)
  } else {
    double_ceil(x - 0.5)
  }
}
export let round: (Double) -> Double = double_round
let double_trunc = (x: Double) -> Double {
  int_to_double(double_to_int_saturating(x))
}
export let trunc: (Double) -> Double = double_trunc
let double_fract = (x: Double) -> Double {
  x - double_trunc(x)
}
export let fract: (Double) -> Double = double_fract
export let Double::abs = (x: Double) -> Double {
  double_abs(x)
}
export let Double::max = (a: Double, b: Double) -> Double {
  double_max(a, b)
}
export let Double::min = (a: Double, b: Double) -> Double {
  double_min(a, b)
}
// Type member names: can be imported with `use <module-ref> { Double }`
export let Double::ceil = (x: Double) -> Double {
  double_ceil(x)
}
export let Double::cube = (x: Double) -> Double {
  double_cube(x)
}
export let Double::lerp = (a: Double, b: Double, t: Double) -> Double {
  double_lerp(a, b, t)
}
export let Double::clamp = (x: Double, min_val: Double, max_val: Double) -> Double {
  double_clamp(x, min_val, max_val)
}
export let Double::floor = (x: Double) -> Double {
  double_floor(x)
}
export let Double::fract = (x: Double) -> Double {
  double_fract(x)
}
export let Double::round = (x: Double) -> Double {
  double_round(x)
}
export let Double::trunc = (x: Double) -> Double {
  double_trunc(x)
}
export let Double::is_nan = (x: Double) -> Bool {
  double_is_nan(x)
}
export let Double::signum = (x: Double) -> Double {
  double_signum(x)
}
export let Double::square = (x: Double) -> Double {
  double_square(x)
}
export let Double::approx_eq = (a: Double, b: Double, eps: Double) -> Bool {
  double_approx_eq(a, b, eps)
}
