-- expect: 1
case [1, 2, 3] of {
  [] -> 0;
  x :: xs ->
    let headSquared = x * x in
      headSquared
}