let compose = [A, B, C](f: (B) -> C, g: (A) -> B) -> (A) -> C {
  (x: A) -> C { f(g(x)) }
}
let double = (x: Int) -> Int { x * 2 }
let inc = (x: Int) -> Int { x + 1 }
let double_then_inc = compose(inc, double)
double_then_inc(10)

__DATA__
{"last": "21"}
