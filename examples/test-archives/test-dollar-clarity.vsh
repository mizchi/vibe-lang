# Test to demonstrate that $ is equivalent to parentheses

let double x = x * 2
let add x y = x + y

# These two should be exactly the same
add 1 $ double 2     # add 1 (double 2)
add 1 (double 2)     # add 1 (double 2)

# More complex example
add $ double 2 + 3   # add ((double 2) + 3)
add (double 2 + 3)   # add ((double 2) + 3)