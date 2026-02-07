// Recursive type that should fail
let rec = [T](x: T) -> T {
  rec(x)
}
rec(42)

__DATA__
{"last": "42", "todo": true}
