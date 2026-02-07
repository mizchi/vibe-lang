// Nested generic type mismatch
let my_map = [A, B](f: (A) -> B, xs: Array[A]) -> Array[B] {
  [f(xs[0])]
}
let double = (x: Int) -> Int { x * 2 }
my_map(double, ["hello"])

__DATA__
{"error_contains": "Mismatch"}
