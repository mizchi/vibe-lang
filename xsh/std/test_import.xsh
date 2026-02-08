// Test importing std modules
import { int_abs, int_pow } from "./int.xsh"
import { is_some, unwrap_or } from "./option.xsh"

// Use imported functions
let a = int_abs(-100)
let b = int_pow(2, 4)
let c = unwrap_or(Some(5), 0)

// Expected: 100 + 16 + 5 = 121
a + b + c
