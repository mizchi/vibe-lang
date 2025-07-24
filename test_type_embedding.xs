-- Test type embedding
let x = 42
let double = fn n -> n * 2
rec factorial n = if (eq n 0) { 1 } else { n * (factorial (n - 1)) }