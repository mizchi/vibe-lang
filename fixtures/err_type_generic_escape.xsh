// Type parameter escaping scope
let make = [T]() -> T {
  let inner = () -> T { ??? }
  inner()
}

__DATA__
{"error_contains": "unknown", "todo": true}
