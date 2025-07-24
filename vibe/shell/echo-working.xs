-- Echo command implementation

-- String concatenation helper
let strJoin sep items = 
  let rec loop lst = case lst of {
    [] -> "";
    [x] -> x;
    [h, ...t] -> strConcat h (strConcat sep (loop t))
  } in
  loop items

-- Echo function
let echo args = 
  let message = strJoin " " args in
  perform print message

-- Test the echo function
perform print "=== Testing echo ==="
let test1 = echo ["Hello", "World"] in
let test2 = echo ["XS", "Shell", "Commands"] in
let test3 = echo [] in
Unit