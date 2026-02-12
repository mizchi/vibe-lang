// Curried generic function
let curry = [A, B, C](f: (A, B) -> C) -> (A) -> (B) -> C {
  (a: A) -> (B) -> C {
    (b: B) -> C { f(a, b) }
  }
}
let add = (a: Int, b: Int) -> Int { a + b }
let curried = curry(add)
let add5 = curried(5)
add5(3)

__DATA__
{"last": "8"}
