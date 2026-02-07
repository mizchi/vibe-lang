// Let without initializer - parser should reject
let x: Int
x + 1

__DATA__
{"error_contains": "Unexpected"}
