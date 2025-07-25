# Test dollar operator - simple version
let double = fn x = x * 2
let even = fn x = (x % 2) == 0
let add = fn x y = x + y

# Basic test
double $ 21

# With arithmetic
add 1 $ 2 + 3

# Nested dollar operators  
double $ double $ 10

# Right associativity test
add 1 $ add 2 $ add 3 4