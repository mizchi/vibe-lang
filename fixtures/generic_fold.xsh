// Generic fold with fixed-size array (simplified)
let fold3 = [A, B](f: (B, A) -> B, init: B, xs: Array[A]) -> B {
  f(f(f(init, xs[0]), xs[1]), xs[2])
}
let add = (acc: Int, x: Int) -> Int { acc + x }
let sum = fold3(add, 0, [1, 2, 3])
sum

__DATA__
{"last": "6"}
