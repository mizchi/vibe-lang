let float_eq = (a: Float, b: Float) -> Bool {
  a == b
}


export let eq: (Float, Float) -> Bool = float_eq
// Clamp value between min and max
export let Float::eq = (a: Float, b: Float) -> Bool {
  float_eq(a, b)
}
let float_abs = (x: Float) -> Float {
  if x < 0.0f {
    0.0f - x
  } else {
    x
  }
}


export let abs: (Float) -> Float = float_abs
let float_max = (a: Float, b: Float) -> Float {
  if a > b {
    a
  } else {
    b
  }
}


export let max: (Float, Float) -> Float = float_max
let float_min = (a: Float, b: Float) -> Float {
  if a < b {
    a
  } else {
    b
  }
}


export let min: (Float, Float) -> Float = float_min
export let Float::abs = (x: Float) -> Float {
  float_abs(x)
}
export let Float::max = (a: Float, b: Float) -> Float {
  float_max(a, b)
}
export let Float::min = (a: Float, b: Float) -> Float {
  float_min(a, b)
}
let float_lerp = (a: Float, b: Float, t: Float) -> Float {
  a + (b - a) * t
}


export let lerp: (Float, Float, Float) -> Float = float_lerp
export let Float::lerp = (a: Float, b: Float, t: Float) -> Float {
  float_lerp(a, b, t)
}


let float_clamp = (x: Float, min_val: Float, max_val: Float) -> Float {
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


export let clamp: (Float, Float, Float) -> Float = float_clamp
export let Float::clamp = (x: Float, min_val: Float, max_val: Float) -> Float {
  float_clamp(x, min_val, max_val)
}
let float_is_nan = (x: Float) -> Bool {
  not(x == x)
}


export let is_nan: (Float) -> Bool = float_is_nan
let float_signum = (x: Float) -> Float {
  if x < 0.0f {
    0.0f - 1.0f
  }
  else if x > 0.0f {
    1.0f
  }
  else {
    0.0f
  }
}


export let signum: (Float) -> Float = float_signum
let float_square = (x: Float) -> Float {
  x * x
}


export let square: (Float) -> Float = float_square
// Linear interpolation (lerp)
export let Float::is_nan = (x: Float) -> Bool {
  float_is_nan(x)
}
// Square
export let Float::signum = (x: Float) -> Float {
  float_signum(x)
}
export let Float::square = (x: Float) -> Float {
  float_square(x)
}
let float_is_zero = (x: Float) -> Bool {
  x == 0.0f
}


export let is_zero: (Float) -> Bool = float_is_zero
export let Float::is_zero = (x: Float) -> Bool {
  float_is_zero(x)
}
let float_is_negative = (x: Float) -> Bool {
  x < 0.0f
}


export let is_negative: (Float) -> Bool = float_is_negative
let float_is_positive = (x: Float) -> Bool {
  x > 0.0f
}


export let is_positive: (Float) -> Bool = float_is_positive
// Type member names: can be imported with `use <module-ref> { Float }`
export let Float::is_negative = (x: Float) -> Bool {
  float_is_negative(x)
}
// Linear interpolation (lerp)
export let Float::is_positive = (x: Float) -> Bool {
  float_is_positive(x)
}
