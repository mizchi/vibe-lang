# Comparing $ and |> operators

let double x = x * 2
let add x y = x + y

# Test case 1: Same expression, different operators
# Expected: 44

# Using $
add 2 $ double 20

# Using |>
20 |> double |> add 2

# Using parentheses
add 2 (double 20)