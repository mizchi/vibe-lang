// Match pattern type doesn't match scrutinee
let x = 42
match x {
  "hello" => 1
  _ => 0
}

__DATA__
{"error_contains": "Mismatch"}
