let rec build = (n: Int, b: ArrayBuilder[Int]) -> ArrayBuilder[Int] {
  if eq(n, 0) {
    b
  } else {
    do {
      array_builder_push(b, n)
      build(sub(n, 1), b)
    }
  }
}

let result = do {
  let b = array_builder()
  let out = build(200, b)
  array_builder_freeze(out)
}
result
