// Generic with nested types
let wrap = [T](x: T) -> Array[T] { [x] }
let unwrap = [T](xs: Array[T]) -> T { xs[0] }
unwrap(wrap(42))

__DATA__
{"last": "42"}
