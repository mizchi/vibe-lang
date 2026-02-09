// WASM primitive type aliases (builtin in type positions)
// i32 == Int, f32 == Float, f64 == Double

export type I32 = i32
export type F32 = f32
export type F64 = f64

export let i32_add = (a: i32, b: i32) -> i32 { a + b }
export let f64_id = (x: f64) -> f64 { x }
export let f32_id = (x: f32) -> f32 { x }

