# Test dollar operator
print $ 42

# With arithmetic
print $ 1 + 2

# Nested dollar operators
print $ double $ 21

# Complex expression
map double $ filter even $ [1, 2, 3, 4, 5]