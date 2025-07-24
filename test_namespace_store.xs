-- Test NamespaceStore integration in shell

-- Define a simple function
let add x y = x + y

-- Use the function
add 5 3

-- Define another function that uses add
let double x = add x x

-- Test the dependency
double 10