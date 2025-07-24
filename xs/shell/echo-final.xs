-- Echo command implementation using XS syntax

-- String join with separator
let strJoin = rec strJoin sep items ->
  if List.null items { "" }
  else if List.null (List.cdr items) { List.car items }
  else {
    strConcat (List.car items) 
      (strConcat sep (strJoin sep (List.cdr items)))
  } in

-- Echo function
let echo args = 
  let message = strJoin " " args in
  perform print message in

-- Test the echo function
perform print "=== Testing echo ==="
let r1 = echo ["Hello", "World"] in
let r2 = echo ["XS", "Shell", "Commands"] in  
let r3 = echo [] in
Unit