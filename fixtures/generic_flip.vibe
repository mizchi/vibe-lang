// Flip function arguments
let flip = [A, B, C](f: (A, B) -> C) -> (B, A) -> C {
  (b: B, a: A) -> C { f(a, b) }
}
let sub = (a: Int, b: Int) -> Int { a - b }
let flipped = flip(sub)
flipped(3, 10)

__DATA__
{"last": "7"}
