// Non-exhaustive match detected
let x = 1
match x {
  1 => "one"
  2 => "two"
}

__DATA__
{"error_contains": "NonExhaustive"}
