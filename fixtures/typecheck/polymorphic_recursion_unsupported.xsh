let rec poly = [T](x: T, n: Int) -> T {
  if n == 0 {
    x
  } else {
    poly([x], n - 1)
  }
}
