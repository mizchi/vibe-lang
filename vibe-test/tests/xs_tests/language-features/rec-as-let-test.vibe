-- Test rec with let binding

let factorial = rec factorial n =
  if eq n 0 {
    1
  } else {
    n * (factorial (n - 1))
  } in

IO.print (factorial 5)