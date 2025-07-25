# Testing the philosophy of $ vs |>

# Helper functions
let double x = x * 2
let inc x = x + 1
let show x = x  # identity for now
let println x = x  # just return for testing

# Case 1: When $ is unnecessary
# Bad: Using $ for simple application
println $ "hello"     # Just use: println "hello"
double $ 5           # Just use: double 5

# Case 2: When |> is unnecessary  
# Bad: Using |> for single transformation
5 |> double          # Just use: double 5
x |> show           # Just use: show x

# Case 3: When $ shines
# Good: Avoiding nested parentheses
println $ "Result: " ++ show $ double $ inc 5
# vs
println ("Result: " ++ show (double (inc 5)))

# Case 4: When |> shines
# Good: Data transformation pipeline
[1, 2, 3, 4, 5]
  |> filter even      # [2, 4]
  |> map double       # [4, 8]
  |> sum             # 12

# Case 5: Natural combination
# Good: $ for the final application, |> for the pipeline
println $ [1, 2, 3]
  |> map double
  |> filter (greaterThan 4)
  |> length

# Case 6: Function composition with $
# Building new functions
let processNumber = show $ double $ inc
# This creates a function: x -> show(double(inc(x)))

# Case 7: Conditional results with $
let result = process $ if condition { 
  expensiveComputation 
} else { 
  cachedValue 
}