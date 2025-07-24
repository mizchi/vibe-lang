-- Test partial application simple version

-- Function with regular parameters
let add = fn x -> fn y -> x + y

-- Partial application
let add5 = add 5

-- Use it
let result = add5 3
print result