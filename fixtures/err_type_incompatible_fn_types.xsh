// Incompatible function types
let apply = (f: (Int) -> String, x: Int) -> String { f(x) }
let g = (x: Int) -> Int { x }
apply(g, 42)

__DATA__
{"error_contains": "Mismatch"}
