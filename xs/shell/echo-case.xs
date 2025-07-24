-- Echo command implementation using case

-- String join helper using case
rec strJoin sep items = case items of {
  [] -> "";
  [x] -> x;
  xs -> String.concat (List.car xs) (String.concat sep (strJoin sep (List.cdr xs)))
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