// WASM opcode-style primitives for low-level xsh code.
// Naming rule: wasm `i32.add` -> xsh `i32_add` (dot is replaced with `_`).
//
// Comparison operators follow wasm style and return i32 (0 or 1), not Bool.

let i32_from_bool = (b: Bool) -> i32 {
  if b { 1 } else { 0 }
}

// i32 numeric ops
export let i32_add = (a: i32, b: i32) -> i32 { a + b }
export let i32_sub = (a: i32, b: i32) -> i32 { a - b }
export let i32_mul = (a: i32, b: i32) -> i32 { a * b }
export let i32_div_s = (a: i32, b: i32) -> i32 { a / b }
export let i32_rem_s = (a: i32, b: i32) -> i32 { a % b }

// i32 bitwise ops
export let i32_and = (a: i32, b: i32) -> i32 { a & b }
export let i32_or = (a: i32, b: i32) -> i32 { a | b }
export let i32_xor = (a: i32, b: i32) -> i32 { a ^ b }
export let i32_shl = (a: i32, b: i32) -> i32 { a << b }
export let i32_shr_s = (a: i32, b: i32) -> i32 { a >> b }

// i32 compare ops (return i32 0/1)
export let i32_eqz = (x: i32) -> i32 { i32_from_bool(x == 0) }
export let i32_eq = (a: i32, b: i32) -> i32 { i32_from_bool(a == b) }
export let i32_ne = (a: i32, b: i32) -> i32 { i32_from_bool(a != b) }
export let i32_lt_s = (a: i32, b: i32) -> i32 { i32_from_bool(a < b) }
export let i32_le_s = (a: i32, b: i32) -> i32 { i32_from_bool(a <= b) }
export let i32_gt_s = (a: i32, b: i32) -> i32 { i32_from_bool(a > b) }
export let i32_ge_s = (a: i32, b: i32) -> i32 { i32_from_bool(a >= b) }

// f32 numeric ops
export let f32_add = (a: f32, b: f32) -> f32 { a + b }
export let f32_sub = (a: f32, b: f32) -> f32 { a - b }
export let f32_mul = (a: f32, b: f32) -> f32 { a * b }
export let f32_div = (a: f32, b: f32) -> f32 { a / b }

// f32 compare ops (return i32 0/1)
export let f32_eq = (a: f32, b: f32) -> i32 { i32_from_bool(a == b) }
export let f32_ne = (a: f32, b: f32) -> i32 { i32_from_bool(a != b) }
export let f32_lt = (a: f32, b: f32) -> i32 { i32_from_bool(a < b) }
export let f32_le = (a: f32, b: f32) -> i32 { i32_from_bool(a <= b) }
export let f32_gt = (a: f32, b: f32) -> i32 { i32_from_bool(a > b) }
export let f32_ge = (a: f32, b: f32) -> i32 { i32_from_bool(a >= b) }

// f64 numeric ops
export let f64_add = (a: f64, b: f64) -> f64 { a + b }
export let f64_sub = (a: f64, b: f64) -> f64 { a - b }
export let f64_mul = (a: f64, b: f64) -> f64 { a * b }
export let f64_div = (a: f64, b: f64) -> f64 { a / b }

// f64 compare ops (return i32 0/1)
export let f64_eq = (a: f64, b: f64) -> i32 { i32_from_bool(a == b) }
export let f64_ne = (a: f64, b: f64) -> i32 { i32_from_bool(a != b) }
export let f64_lt = (a: f64, b: f64) -> i32 { i32_from_bool(a < b) }
export let f64_le = (a: f64, b: f64) -> i32 { i32_from_bool(a <= b) }
export let f64_gt = (a: f64, b: f64) -> i32 { i32_from_bool(a > b) }
export let f64_ge = (a: f64, b: f64) -> i32 { i32_from_bool(a >= b) }

// conversion ops
export let f64_promote_f32 = (x: f32) -> f64 { float_to_double(x) }
export let f32_demote_f64 = (x: f64) -> f32 { double_to_float(x) }
export let f32_convert_i32_s = (x: i32) -> f32 { int_to_float(x) }
export let f64_convert_i32_s = (x: i32) -> f64 { int_to_double(x) }
export let i32_trunc_f32_s = (x: f32) -> i32 { float_to_int(x) }
export let i32_trunc_f64_s = (x: f64) -> i32 { double_to_int(x) }

test "i32 arithmetic and bitwise" {
  assert(eq(i32_add(40, 2), 42))
  assert(eq(i32_sub(50, 8), 42))
  assert(eq(i32_mul(6, 7), 42))
  assert(eq(i32_div_s(126, 3), 42))
  assert(eq(i32_rem_s(128, 43), 42))
  assert(eq(i32_and(46, 43), 42))
  assert(eq(i32_or(34, 10), 42))
  assert(eq(i32_xor(47, 5), 42))
}

test "i32 shift and compare" {
  assert(eq(i32_shl(21, 1), 42))
  assert(eq(i32_shr_s(-84, 1), -42))
  assert(eq(i32_eqz(0), 1))
  assert(eq(i32_eq(1, 1), 1))
  assert(eq(i32_ne(1, 2), 1))
  assert(eq(i32_lt_s(1, 2), 1))
  assert(eq(i32_le_s(2, 2), 1))
  assert(eq(i32_gt_s(3, 2), 1))
  assert(eq(i32_ge_s(3, 3), 1))
}

test "f32 operations" {
  assert(eq(f32_add(40.0f, 2.0f), 42.0f))
  assert(eq(f32_sub(50.0f, 8.0f), 42.0f))
  assert(eq(f32_mul(6.0f, 7.0f), 42.0f))
  assert(eq(f32_div(84.0f, 2.0f), 42.0f))
  assert(eq(f32_eq(1.0f, 1.0f), 1))
  assert(eq(f32_ne(1.0f, 2.0f), 1))
  assert(eq(f32_lt(1.0f, 2.0f), 1))
  assert(eq(f32_le(2.0f, 2.0f), 1))
  assert(eq(f32_gt(3.0f, 2.0f), 1))
  assert(eq(f32_ge(3.0f, 3.0f), 1))
}

test "f64 operations" {
  assert(eq(f64_add(40.0, 2.0), 42.0))
  assert(eq(f64_sub(50.0, 8.0), 42.0))
  assert(eq(f64_mul(6.0, 7.0), 42.0))
  assert(eq(f64_div(84.0, 2.0), 42.0))
  assert(eq(f64_eq(1.0, 1.0), 1))
  assert(eq(f64_ne(1.0, 2.0), 1))
  assert(eq(f64_lt(1.0, 2.0), 1))
  assert(eq(f64_le(2.0, 2.0), 1))
  assert(eq(f64_gt(3.0, 2.0), 1))
  assert(eq(f64_ge(3.0, 3.0), 1))
}

test "conversion operations" {
  assert(eq(f64_promote_f32(1.5f), 1.5))
  assert(eq(f32_demote_f64(1.5), 1.5f))
  assert(eq(f32_convert_i32_s(42), 42.0f))
  assert(eq(f64_convert_i32_s(42), 42.0))
  assert(eq(i32_trunc_f32_s(42.9f), 42))
  assert(eq(i32_trunc_f64_s(42.9), 42))
}
