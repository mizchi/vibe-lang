// WASM primitive type aliases (builtin in type positions)
// i32 == Int, f32 == Float, f64 == Double

export type I32 = i32
export type F32 = f32
export type F64 = f64

export let i32_add = (a: i32, b: i32) -> i32 { a + b }
export let f64_id = (x: f64) -> f64 { x }
export let f32_id = (x: f32) -> f32 { x }

test "i32_add" {
  assert(eq(i32_add(40, 2), 42))
}

test "f64_id" {
  assert(eq(f64_id(1.25), 1.25))
}

test "f32_id" {
  assert(eq(f32_id(2.5f), 2.5f))
}

test "I32 alias works" {
  let id = (x: I32) -> I32 { x }
  assert(eq(id(7), 7))
}

test "F64 alias works" {
  let id = (x: F64) -> F64 { x }
  assert(eq(id(3.5), 3.5))
}

test "F32 alias works" {
  let id = (x: F32) -> F32 { x }
  assert(eq(id(4.5f), 4.5f))
}
