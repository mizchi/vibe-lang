-- Simple test of echo functionality
-- Direct test without imports
rec joinArgs args =
  match args {
    [] -> ""
    [x] -> x
    x :: xs -> strConcat x (strConcat " " (joinArgs xs))
  }

let echo = fn args ->
  let message = joinArgs args in
  perform print message

-- Test
perform print "=== Testing echo ==="
echo ["Hello", "World"]
echo ["XS", "Shell", "Commands"]
echo []