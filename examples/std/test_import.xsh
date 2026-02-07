// Test importing std modules
import { int_abs, int_max, int_min } from "./int.xsh"
import { is_some, unwrap_or } from "./option.xsh"

// Use imported functions
let a = int_abs(-100)
let b = int_max(10, 20)
let c = unwrap_or(Some(5), 0)

// Expected: 100 + 20 + 5 = 125
a + b + c
