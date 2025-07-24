-- Simple test to verify test framework functionality

-- Define a simple assert function
let assert expr =
  if expr { true }
  else { ["TEST_ERROR", "Assertion failed"] } in

-- Test if assert works
let test1 = assert (1 = 1) in
let test2 = assert (1 = 2) in

-- Print results
let x = IO.print "Test 1 (should pass):" in
let y = IO.print test1 in
let z = IO.print "Test 2 (should fail):" in
IO.print test2