// Higher-order function return type mismatch
let apply = [A, B](f: (A) -> B, x: A) -> B { f(x) }
let to_string = (x: Int) -> String { "num" }
apply(to_string, 42) + 1

__DATA__
{"error_contains": "Mismatch"}
