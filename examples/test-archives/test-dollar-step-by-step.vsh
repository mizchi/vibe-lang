# Step-by-step demonstration of $ operator

let double x = x * 2
let add x y = x + y

# Example 1: double $ add 3 2
# Step 1: add 3 2 = 5
add 3 2
# Step 2: double 5 = 10
double $ add 3 2

# Example 2: add 1 $ double $ add 2 3  
# Step 1: add 2 3 = 5
add 2 3
# Step 2: double 5 = 10
double $ add 2 3
# Step 3: add 1 10 = 11
add 1 $ double $ add 2 3