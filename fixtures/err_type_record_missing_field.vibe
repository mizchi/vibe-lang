// Record pattern with extra field not in value
let p = record { a: 1 }
match p {
  record { a: x, b: y } => x + y
  _ => 0
}

__DATA__
{"error_contains": "missing field"}
