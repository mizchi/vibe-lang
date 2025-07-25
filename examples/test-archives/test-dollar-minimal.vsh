# Test dollar operator - minimal version
let double x = x * 2

# Basic dollar
double $ 21

# Nested dollar
double $ double $ 10

# Dollar with expression
double $ 2 + 3