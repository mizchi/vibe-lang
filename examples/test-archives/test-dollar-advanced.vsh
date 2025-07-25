# Advanced dollar operator tests
let double x = x * 2
let add x y = x + y
let square x = x * x

# Basic dollar
double $ 21

# Nested dollar - right associative
double $ double $ 10

# Dollar with arithmetic expression
square $ 3 + 2

# Multiple dollar operators
add 1 $ add 2 $ add 3 4

# Dollar with higher precedence operations
add 10 $ double $ 5

# Complex expression
square $ double $ 2 + 3