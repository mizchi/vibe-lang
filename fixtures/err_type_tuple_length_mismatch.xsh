// Tuple element type mismatch in pattern
let t = (1, "hello")
match t {
  (a, b) => a + b
  _ => 0
}

__DATA__
{"error_contains": "Mismatch"}
