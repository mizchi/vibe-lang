// Generic predicate test (simplified - no dynamic array)
let any = [A](pred: (A) -> Bool, xs: Array[A]) -> Bool {
  if pred(xs[0]) { true }
  else if pred(xs[1]) { true }
  else if pred(xs[2]) { true }
  else { false }
}
let is_even = (x: Int) -> Bool { x % 2 == 0 }
any(is_even, [1, 3, 5])

__DATA__
{"last": "false"}
