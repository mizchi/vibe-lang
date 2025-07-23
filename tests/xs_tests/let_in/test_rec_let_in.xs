-- expect: 120
let factorial = rec factorial n ->
  let isZero = n = 0 in
    if isZero { 1 }
    else { n * factorial (n - 1) } in
factorial 5