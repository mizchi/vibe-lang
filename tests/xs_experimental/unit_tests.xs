-- Unit tests using test framework style
-- expect: true

-- Helper function to check if value is an error
let isError value = case value of {
  ["TEST_ERROR", msg] -> true;
  _ -> false
} in

-- Simple equality assertion for integers
let assertEqInt actual expected =
  if actual = expected { true }
  else {
    ["TEST_ERROR", String.concat 
      (String.concat "Expected: " (Int.toString expected))
      (String.concat ", but got: " (Int.toString actual))]
  } in

-- Simple equality assertion for strings
let assertEqStr actual expected =
  if String.eq actual expected { true }
  else {
    ["TEST_ERROR", String.concat 
      (String.concat "Expected: \"" (String.concat expected "\""))
      (String.concat ", but got: \"" (String.concat actual "\""))]
  } in

-- Basic assertion
let assert expr =
  if expr { true }
  else { ["TEST_ERROR", "Assertion failed"] } in

-- Test runner
let runTest name testFn =
  let result = testFn () in
    if isError result {
      let dummy = IO.print (String.concat "✗ " (String.concat name (String.concat ": " (case result of { ["TEST_ERROR", msg] -> msg; _ -> "" })))) in false
    } else {
      let dummy = IO.print (String.concat "✓ " name) in true
    } in

-- Test 1: Basic arithmetic
let test1 = runTest "basic arithmetic" (\() ->
  let r1 = assertEqInt (2 + 2) 4 in
    if isError r1 { r1 }
    else {
      let r2 = assertEqInt (3 * 4) 12 in
        if isError r2 { r2 }
        else { assertEqInt (10 - 5) 5 }
    }) in

-- Test 2: String operations
let test2 = runTest "string operations" (\() ->
  let r1 = assertEqStr (String.concat "Hello, " "World!") "Hello, World!" in
    if isError r1 { r1 }
    else {
      let r2 = assertEqInt (String.length "hello") 5 in
        if isError r2 { r2 }
        else { assertEqStr (Int.toString 42) "42" }
    }) in

-- Test 3: Lambda expressions
let test3 = runTest "lambda expressions" (\() ->
  let r1 = assertEqInt ((\x -> x) 10) 10 in
    if isError r1 { r1 }
    else { assertEqInt ((\x y -> x + y) 3 4) 7 }) in

-- Test 4: Conditionals
let test4 = runTest "conditionals" (\() ->
  let r1 = assertEqInt (if true { 1 } else { 2 }) 1 in
    if isError r1 { r1 }
    else { assertEqInt (if false { 1 } else { 2 }) 2 }) in

-- Test 5: Let bindings
let test5 = runTest "let bindings" (\() ->
  let x = 10 in
  let y = x + 5 in
    assertEqInt y 15) in

-- Test 6: List operations
let test6 = runTest "list operations" (\() ->
  let list1 = [1, 2, 3] in
  let list2 = cons 0 list1 in
    case list2 of {
      [0, 1, 2, 3] -> true;
      _ -> ["TEST_ERROR", "List construction failed"]
    }) in

-- Test 7: Partial application
let test7 = runTest "partial application" (\() ->
  let add x y = x + y in
  let add5 = add 5 in
    assertEqInt (add5 3) 8) in

-- Test 8: Higher-order functions
let test8 = runTest "higher-order functions" (\() ->
  let applyTwice f x = f (f x) in
  let inc x = x + 1 in
    assertEqInt (applyTwice inc 5) 7) in

-- Summary
let passed = (if test1 { 1 } else { 0 }) +
             (if test2 { 1 } else { 0 }) +
             (if test3 { 1 } else { 0 }) +
             (if test4 { 1 } else { 0 }) +
             (if test5 { 1 } else { 0 }) +
             (if test6 { 1 } else { 0 }) +
             (if test7 { 1 } else { 0 }) +
             (if test8 { 1 } else { 0 }) in
let dummy = IO.print (String.concat "\nTotal: 8 tests, " (String.concat (Int.toString passed) " passed")) in
  passed = 8