# Test comparison of $, |>, and parentheses

# Setup functions
let double x = x * 2
let inc x = x + 1
let square x = x * x
let add x y = x + y

# Test 1: Simple function application
# All three should give the same result (42)

# Using parentheses
inc (double 20)

# Using $
inc $ double 20

# Using |> 
20 |> double |> inc

# Test 2: Complex arithmetic expression
# All should give 13 (square of (2+1) = 9, plus 4 = 13)

# Using parentheses
add (square (add 1 2)) 4

# Using $
add (square $ add 1 2) 4

# Using mixed
add 1 2 |> square |> add 4

# Test 3: Triple composition
# All should give 17 (5 * 2 = 10, + 1 = 11, * 2 = 22)

# Parentheses
double (inc (double 5))

# Dollar
double $ inc $ double 5

# Pipeline
5 |> double |> inc |> double

# Test 4: Mixed operators
# Should be 84 ((10 * 2 + 1) * 2 = 42, * 2 = 84)
double $ 10 |> double |> inc |> double