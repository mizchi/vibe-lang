-- Echo command implementation

-- String join helper
rec strJoin sep items = 
  if List.null items { "" }
  else if List.null (List.cdr items) { List.car items }
  else {
    strConcat (List.car items) 
      (strConcat sep (strJoin sep (List.cdr items)))
  }

-- Echo function
let echo args = 
  let message = strJoin " " args in
  perform print message

-- Test
perform print "=== Testing echo ==="
echo ["Hello", "World"]
echo ["XS", "Shell", "Commands"]  
echo []