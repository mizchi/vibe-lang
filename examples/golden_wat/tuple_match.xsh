// Golden test: Tuple pattern matching
let t = (1, 2, 3)
match t {
  (a, b, c) => a + b + c,
  _ => 0
}
