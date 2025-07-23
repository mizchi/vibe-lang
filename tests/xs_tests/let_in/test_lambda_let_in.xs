-- expect: 20
-- Test: Lambda with let-in expression
let f = fn x =
  let doubled = x * 2 in
    doubled + 10
in f 5