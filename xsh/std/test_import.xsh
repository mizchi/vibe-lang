// Test importing std modules
import { bool_to_int } from "./bool.xsh"
import { abs, clamp } from "./float.xsh"

// Use imported functions
let a = bool_to_int(true)
let b = abs(-3.5f)
let c = clamp(10.0f, 0.0f, 4.0f)

// Expected: true
eq(a, 1) && b > 3.4f && c == 4.0f
