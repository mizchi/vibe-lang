-- expect: 55
let sumSquares = rec sumSquares n ->
  let isZero = n = 0 in
    if isZero { 0 }
    else {
      let square = n * n in
        square + sumSquares (n - 1)
    } in
sumSquares 5