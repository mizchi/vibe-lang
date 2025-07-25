# Advanced dollar operator tests with detailed output
let double x = x * 2
let add x y = x + y
let square x = x * x
let show label x = { print label; print x; x }

# Basic dollar
show "double $ 21 = " $ double $ 21

# Nested dollar - right associative
show "double $ double $ 10 = " $ double $ double $ 10

# Dollar with arithmetic expression
show "square $ 3 + 2 = " $ square $ 3 + 2

# Multiple dollar operators
show "add 1 $ add 2 $ add 3 4 = " $ add 1 $ add 2 $ add 3 4

# Dollar with higher precedence operations
show "add 10 $ double $ 5 = " $ add 10 $ double $ 5

# Complex expression
show "square $ double $ 2 + 3 = " $ square $ double $ 2 + 3