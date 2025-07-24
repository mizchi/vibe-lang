-- Test automatic type embedding

-- Simple value binding without type annotation
let x = 42

-- Function without type annotation
let add = fn x y -> x + y

-- Recursive function without return type
rec factorial n =
  if (eq n 0) {
    1
  } else {
    n * (factorial (n - 1))
  }

-- View the definitions to see embedded types
view x
view add
view factorial