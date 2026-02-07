// Map with wrong key type
let m: Map[String, Int] = {}
m[42] = 1

__DATA__
{"error_contains": "Mismatch", "todo": true}
