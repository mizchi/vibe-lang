-- Basic test suite
-- expect: true

-- Test arithmetic operations
let test1 = 2 + 2 = 4 in
let test2 = 3 * 4 = 12 in
let test3 = 10 - 5 = 5 in
let test4 = 20 / 4 = 5 in

-- Test string operations
let test5 = String.eq (String.concat "Hello, " "World!") "Hello, World!" in
let test6 = String.length "hello" = 5 in
let test7 = String.eq (Int.toString 42) "42" in
let test8 = String.toInt "123" = 123 in

-- Test lambda expressions
let test9 = (\x -> x) 10 = 10 in
let test10 = (\x y -> x + y) 3 4 = 7 in

-- Test conditionals
let test11 = (if true { 1 } else { 2 }) = 1 in
let test12 = (if false { 1 } else { 2 }) = 2 in

-- Test let bindings
let x = 10 in
let y = x + 5 in
let test13 = y = 15 in

-- Test lists
let lst = [1, 2, 3] in
let test14 = case lst of {
  [h, ...t] -> h = 1;
  _ -> false
} in

-- Test partial application
let add x y = x + y in
let add5 = add 5 in
let test15 = add5 3 = 8 in

-- All tests must pass
test1 && test2 && test3 && test4 && test5 && 
test6 && test7 && test8 && test9 && test10 && 
test11 && test12 && test13 && test14 && test15