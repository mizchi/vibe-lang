-- Simple rest pattern test

let result = case [1, 2, 3, 4, 5] of {
  x :: tail -> tail
} in

IO.print result