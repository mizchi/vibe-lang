// Recursive call before function is defined
let recurse = [T](x: T) -> T {
  recurse(x)
}
recurse(42)

__DATA__
{"error_contains": "recurse"}
