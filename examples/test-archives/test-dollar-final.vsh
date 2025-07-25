# Final test to demonstrate $ operator as parentheses replacement

let double x = x * 2
let add x y = x + y
# For simplicity, we'll avoid string operations in this test

# Test 1: Basic parentheses replacement
# Without $: double (add 3 2)
# With $:    double $ add 3 2
double $ add 3 2  # Result: 10

# Test 2: Right associativity  
# f $ g $ h x  is  f (g (h x))
add 1 $ double $ add 2 3  # Result: add 1 (double (add 2 3)) = add 1 (double 5) = add 1 10 = 11

# Test 3: With expressions
# sqrt $ x² + y²
let x = 3
let y = 4  
add 0 $ x * x + y * y  # Result: add 0 (3*3 + 4*4) = add 0 (9 + 16) = add 0 25 = 25