# Simple demonstration of $ operator
# $ is syntactic sugar for parentheses

let double x = x * 2
let add x y = x + y

# Without $: double (add 3 2)
# With $:    double $ add 3 2
double $ add 3 2  # Result: 10

# Right associative
add 1 $ double $ 5  # add 1 (double 5) = 11