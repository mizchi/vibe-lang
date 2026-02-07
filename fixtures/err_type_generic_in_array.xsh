// Array of generic functions - works with monomorphization
let identity = [T](x: T) -> T { x }
let arr = [identity, identity]
arr[0](42)

__DATA__
{"last": "42"}
