// Test importing std modules
import { bool_to_int } from "./bool.xsh"
import { float_abs, float_clamp } from "./float.xsh"

// Use imported functions
let a = bool_to_int(true)
let b = float_abs(-3.5f)
let c = float_clamp(10.0f, 0.0f, 4.0f)

// Expected: true
eq(a, 1) && b > 3.4f && c == 4.0f
