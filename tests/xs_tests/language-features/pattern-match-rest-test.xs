-- Test rest pattern matching

-- Helper function to sum a list
let sum = rec sum lst =
  case lst of {
    [] -> 0
    x :: rest -> x + (sum rest)
  } in

-- Helper function to get first n elements
let takeN = rec takeN n lst =
  case [n, lst] of {
    [0, _] -> []
    [_, []] -> []
    [n, x :: rest] -> x :: (takeN (n - 1) rest)
  } in

-- Test empty list pattern
let test1 = case [] of {
  [] -> "empty"
  rest -> "has rest"
} in

-- Test single element with rest
let test2 = case [1, 2, 3, 4, 5] of {
  x :: rest -> [x, rest]
} in

-- Test multiple fixed elements with rest
let test3 = case [1, 2, 3, 4, 5] of {
  a :: b :: rest -> [a, b, rest]
} in

-- Test sum function
let test4 = sum [1, 2, 3, 4, 5] in

-- Test take-n function
let test5 = takeN 3 [1, 2, 3, 4, 5] in

-- Print results
let dummy1 = IO.print "Test 1 (empty list):" in
let dummy2 = IO.print test1 in
let dummy3 = IO.print "\nTest 2 (x :: rest with [1,2,3,4,5]):" in
let dummy4 = IO.print test2 in
let dummy5 = IO.print "\nTest 3 (a :: b :: rest with [1,2,3,4,5]):" in
let dummy6 = IO.print test3 in
let dummy7 = IO.print "\nTest 4 (sum [1,2,3,4,5]):" in
let dummy8 = IO.print test4 in
let dummy9 = IO.print "\nTest 5 (takeN 3 [1,2,3,4,5]):" in
let dummy10 = IO.print test5 in

IO.print "\nRest pattern tests completed!"