import {
  double_abs,
  double_signum,
  double_is_nan,
  double_max,
  double_min,
  double_clamp,
  double_floor,
  double_ceil,
  double_round,
  double_trunc,
  double_fract,
  double_square,
  double_cube,
  double_lerp,
  double_approx_eq
} from "./double.xsh"

let double_int_max_value = 2147483647.0
let double_int_min_value = -2147483648.0

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

test "double_approx_eq boundary" {
  assert(double_approx_eq(1.0, 1.5, 0.5))
  assert(not(double_approx_eq(1.0, 1.500001, 0.5)))
}
