-- Echo command test

-- Join function
let rec joinArgs = \args ->
  match args {
    [] -> ""
    [x] -> x
    x :: xs -> strConcat x (strConcat " " (joinArgs xs))
  }

-- Echo function
let echo = \args ->
  let message = joinArgs args in
  perform print message

-- Tests
perform print "=== Testing echo ==="
let _ = echo ["Hello", "World"]
let _ = echo ["XS", "Shell", "Commands"]
let _ = echo []
Unit