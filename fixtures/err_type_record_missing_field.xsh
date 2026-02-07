// Record pattern mismatch
let p = record { a: 1 }
match p {
  record { a: x, b: y } => x + y
  _ => 0
}

__DATA__
{"error_contains": "Mismatch", "todo": true}
