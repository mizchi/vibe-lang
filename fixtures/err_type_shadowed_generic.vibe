// Type parameter shadowing in nested function
let outer = [T](x: T) -> T {
  let inner = [T](y: T) -> T { y }
  inner(x)
}
outer(42)

__DATA__
{"last": "42"}
