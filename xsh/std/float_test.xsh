import {
  float_eq,
  float_abs,
  float_signum,
  float_is_nan,
  float_max,
  float_min,
  float_clamp,
  float_square,
  float_lerp
} from "./float.xsh"

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
